defmodule Reach.Smell.Checks.RedundantComputation do
  @moduledoc "Detects duplicate pure calls within the same function."

  use Reach.Smell.Check

  alias Reach.Effects
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Smell.Finding

  @type_check_fns [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_exception,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_map_key,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_struct,
    :is_tuple,
    :byte_size,
    :bit_size,
    :tuple_size,
    :map_size
  ]

  @compiler_directives [
    :import,
    :alias,
    :require,
    :use,
    :doc,
    :moduledoc,
    :typedoc,
    :spec,
    :callback,
    :macrocallback,
    :impl,
    :type,
    :typep,
    :opaque,
    :behaviour,
    :defstruct,
    :defdelegate,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :unquote,
    :quote
  ]

  @pattern_operators [:|, :{}, :@, :"::", :<<>>, :size]

  def run(project) do
    project
    |> Helpers.function_defs()
    |> Enum.flat_map(&findings(&1, project.plugins))
  end

  defp findings(func, plugins) do
    func
    |> collect_sequential_blocks(plugins)
    |> Enum.flat_map(&find_redundant_in_block/1)
  end

  defp find_redundant_in_block(block_calls) do
    {findings, _calls} =
      Enum.reduce(block_calls, {[], %{}}, fn
        {:bind, name}, {findings, calls} ->
          calls =
            Map.reject(calls, fn {_key, call} ->
              Enum.any?(call.children, &match?(%{type: :var, meta: %{name: ^name}}, &1))
            end)

          {findings, calls}

        node, {findings, calls} ->
          key = {node.meta[:module], node.meta[:function], node.meta[:arity]}
          previous = Map.get(calls, key)
          next = if previous, do: maybe_redundant_call(previous, node), else: []
          {Enum.reverse(next, findings), Map.put(calls, key, node)}
      end)

    Enum.reverse(findings)
  end

  defp collect_sequential_blocks(%{type: type, children: children}, plugins)
       when type in [:comprehension, :try] do
    Enum.flat_map(children, &collect_sequential_blocks(&1, plugins))
  end

  defp collect_sequential_blocks(node, plugins) do
    calls = collect_block_calls(node, [], plugins) |> Enum.reverse()
    nested = nested_blocks(node, plugins)
    if calls != [], do: [calls | nested], else: nested
  end

  defp nested_blocks(node, plugins) do
    (node.children || [])
    |> Enum.flat_map(fn child ->
      case child.type do
        type when type in [:case, :fn] ->
          child.children
          |> Enum.filter(&(&1.type == :clause))
          |> Enum.flat_map(&collect_sequential_blocks(&1, plugins))

        type when type in [:clause, :comprehension, :try] ->
          collect_sequential_blocks(child, plugins)

        _ ->
          nested_blocks(child, plugins)
      end
    end)
  end

  defp formatting_call?(%{meta: %{function: :to_string, module: Kernel}}), do: true
  defp formatting_call?(%{meta: %{function: :to_string, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, kind: :local}}), do: true
  defp formatting_call?(%{meta: %{function: :inspect, module: Kernel}}), do: true
  defp formatting_call?(_node), do: false

  defp stateful_helper?(%{meta: %{module: Reach.IR.Counter, function: :next}}), do: true
  defp stateful_helper?(_node), do: false

  @excluded_fns MapSet.new(
                  @type_check_fns ++
                    @compiler_directives ++
                    @pattern_operators ++
                    [:__aliases__, :get]
                )

  @excluded_kinds MapSet.new([:attribute, :field_access, :binary_size])

  defp redundancy_candidate?(node, plugins) do
    eligible_call?(node) and pure_source_call?(node, plugins)
  end

  defp eligible_call?(node) do
    node.type == :call and node.meta[:function] != nil and node.source_span != nil and
      node.meta[:function] not in @excluded_fns and
      node.meta[:kind] not in @excluded_kinds and node.meta[:module] != Access
  end

  defp pure_source_call?(node, plugins) do
    not generated_source_call?(node) and Effects.pure?(node, plugins) and
      not formatting_call?(node) and
      not stateful_helper?(node)
  end

  defp generated_source_call?(%{meta: %{origin: %{generated?: true}}}), do: true
  defp generated_source_call?(_node), do: false

  defp collect_block_calls(%{type: type}, acc, _plugins)
       when type in [:case, :fn, :comprehension, :try],
       do: acc

  defp collect_block_calls(%{type: :match, children: [pattern, value]}, acc, plugins) do
    acc = collect_block_calls(value, acc, plugins)
    Enum.reduce(defined_names(pattern), acc, fn name, acc -> [{:bind, name} | acc] end)
  end

  defp collect_block_calls(node, acc, plugins) do
    acc = if redundancy_candidate?(node, plugins), do: [node | acc], else: acc

    node.children
    |> Enum.reject(&(&1.type in [:case, :fn, :clause, :comprehension, :try]))
    |> Enum.reduce(acc, &collect_block_calls(&1, &2, plugins))
  end

  defp defined_names(%{type: :pin}), do: []

  defp defined_names(%{type: :call, meta: %{function: :"::"}, children: [value, _specifier]}),
    do: defined_names(value)

  defp defined_names(%{type: :var, meta: %{binding_role: :definition, name: name}}),
    do: [name]

  defp defined_names(node), do: Enum.flat_map(node.children, &defined_names/1)

  defp maybe_redundant_call(left, right) do
    if same_args?(left, right) and left.source_span[:start_line] != right.source_span[:start_line] do
      [
        Finding.new(
          kind: :redundant_computation,
          message:
            "#{IRHelpers.call_name(left)} called twice with same args (line #{left.source_span[:start_line]} and #{right.source_span[:start_line]})",
          location: Helpers.location(right)
        )
      ]
    else
      []
    end
  end

  defp same_args?(left, right) do
    length(left.children) == length(right.children) and left.children != [] and
      Enum.zip(left.children, right.children)
      |> Enum.all?(fn {left_child, right_child} -> same_node?(left_child, right_child) end)
  end

  defp same_node?(%{type: :var, meta: left}, %{type: :var, meta: right}),
    do: left[:name] == right[:name]

  defp same_node?(%{type: :literal, meta: left}, %{type: :literal, meta: right}),
    do: left[:value] == right[:value]

  defp same_node?(_left, _right), do: false
end
