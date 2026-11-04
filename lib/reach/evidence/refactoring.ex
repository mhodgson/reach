defmodule Reach.Evidence.Refactoring do
  @moduledoc "Structural evidence for actionable refactoring recommendations."

  alias Reach.{Effects, Frontend, IR}
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.IR.Node

  @pure_binary_ops [
    :+,
    :-,
    :*,
    :/,
    :div,
    :rem,
    :++,
    :--,
    :<>,
    :and,
    :or,
    :&&,
    :||,
    :andalso,
    :orelse,
    :xor,
    :band,
    :bor,
    :bxor,
    :bsl,
    :bsr,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :"=:=",
    :"=/=",
    :"/=",
    :"=<"
  ]
  @pure_unary_ops [:not, :!, :+, :-, :bnot]
  @data_nodes [:literal, :var, :tuple, :list, :cons, :map, :map_field, :case, :clause]

  def read_through_cache?(func, plugins) do
    with [%Node{children: clause}] <- func.children,
         true <- Enum.all?(Enum.drop(clause, -1), &data_key?/1),
         %Node{type: :case, children: [get, miss, hit]} <- List.last(clause),
         %{meta: %{module: :persistent_term, function: :get, arity: 2}} <- get,
         [key, %Node{type: :literal, meta: %{value: nil}}] <- arguments(get),
         true <- data_key?(key),
         %Node{children: [%Node{type: :literal, meta: %{value: nil}}, body]} <- miss,
         %Node{type: :block, children: [binding, put, returned]} <- body,
         %Node{type: :match, children: [value, %Node{type: :call} = load]} <- binding,
         :read <- Effects.classify(load, plugins),
         true <- Enum.all?(IR.all_nodes(load), &(Effects.classify(&1, plugins) in [:pure, :read])),
         true <- Enum.all?(IR.all_nodes(load), &straight_line?(&1, plugins)),
         false <- Enum.any?(IR.all_nodes(key), &same_variable?(&1, value)),
         %{meta: %{module: :persistent_term, function: :put, arity: 2}} <- put,
         [stored_key, stored_value] <- arguments(put),
         true <- same_data?(key, stored_key),
         true <- same_variable?(value, stored_value) and same_variable?(value, returned),
         %Node{children: [pattern, cached]} <- hit do
      same_variable?(pattern, cached)
    else
      _ -> false
    end
  end

  def pure_region(%Node{source_span: %{file: file}} = func, plugins) when is_binary(file) do
    # Other frontends need evidence for their own operator and value semantics.
    if Path.extname(file) in Frontend.source_extensions() and
         Frontend.language_from_path(file) in [:elixir, :erlang],
       do: beam_region(func, plugins)
  end

  def pure_region(_, _), do: nil

  defp beam_region(func, plugins) do
    func.children
    |> Enum.flat_map(fn clause ->
      case List.last(clause.children) do
        %Node{type: :block, children: expressions} ->
          expressions
          |> Enum.with_index()
          |> Enum.map(fn {expression, index} ->
            assigned_region(expression, Enum.drop(expressions, index + 1), plugins)
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end
    end)
    |> Enum.max_by(& &1.branches, fn -> nil end)
  end

  defp assigned_region(
         %Node{type: :match, children: [%Node{type: :var} = output, %Node{type: :case} = region]},
         following,
         plugins
       ) do
    nodes = IR.all_nodes(region)

    if following != [] and
         Enum.all?(nodes, &pure_expression?/1) and
         Enum.all?(nodes, &closed_branch?/1) and
         effectful_consumer?(hd(following), output, plugins) do
      %{
        file: region.source_span && region.source_span.file,
        line: region.source_span && region.source_span.start_line,
        branches: Enum.count(nodes, &IRHelpers.execution_branch?/1),
        inputs:
          for(%Node{type: :var, meta: %{name: name}} <- nodes, name != :_, do: name)
          |> Enum.uniq()
          |> Enum.sort(),
        output: output.meta[:name]
      }
    end
  end

  defp assigned_region(_, _, _), do: nil

  defp closed_branch?(%Node{type: :clause, children: children}) do
    children
    |> Enum.drop(-1)
    |> Enum.all?(fn
      %Node{type: :literal} -> true
      %Node{type: :var, meta: %{name: :_}} -> true
      _ -> false
    end)
  end

  defp closed_branch?(%Node{type: :binary_op, meta: %{operator: :!}}), do: false

  defp closed_branch?(%Node{type: type})
       when type in [:call, :fn, :match, :comprehension, :receive, :try], do: false

  defp closed_branch?(_), do: true

  defp pure_expression?(%Node{type: :binary_op, meta: %{operator: op}}),
    do: op in @pure_binary_ops

  defp pure_expression?(%Node{type: :unary_op, meta: %{operator: op}}), do: op in @pure_unary_ops
  defp pure_expression?(%Node{type: type}), do: type in @data_nodes

  defp straight_line?(%Node{type: :call, meta: %{kind: :local, function: :@}}, _plugins), do: true

  defp straight_line?(%Node{type: :call, meta: %{kind: kind}} = node, plugins),
    do: kind in [:local, :remote] and Effects.classify(node, plugins) == :read

  defp straight_line?(%Node{type: :binary_op} = node, _plugins),
    do: pure_expression?(node) and not IRHelpers.execution_branch?(node)

  defp straight_line?(%Node{type: :unary_op} = node, _plugins), do: pure_expression?(node)

  defp straight_line?(%Node{type: type}, _plugins),
    do: type in [:literal, :var, :tuple, :list, :cons, :map, :map_field]

  defp effectful_consumer?(%Node{type: :call} = call, output, plugins) do
    args = arguments(call)

    Effects.classify(call, plugins) in [:read, :write, :io, :send, :receive] and
      Enum.all?(args, &data_key?/1) and Enum.any?(args, &uses_variable?(&1, output))
  end

  defp effectful_consumer?(_, _, _), do: false

  defp uses_variable?(node, variable),
    do:
      not Enum.any?(IR.all_nodes(node), fn
        %Node{type: :match, children: [left, _right]} -> same_variable?(left, variable)
        _ -> false
      end) and Enum.any?(IR.all_nodes(node), &same_variable?(&1, variable))

  defp arguments(%Node{children: children, meta: %{arity: arity}}),
    do: Enum.take(children, -arity)

  defp same_variable?(%Node{type: :var, meta: %{name: name}}, %Node{
         type: :var,
         meta: %{name: name}
       }),
       do: name != :_

  defp same_variable?(_, _), do: false

  defp data_key?(%Node{type: type, children: children})
       when type in [:literal, :var, :tuple, :list],
       do: Enum.all?(children, &data_key?/1)

  defp data_key?(_), do: false

  defp same_data?(left, right), do: data_signature(left) == data_signature(right)

  defp data_signature(node),
    do:
      {node.type, Map.take(node.meta, [:value, :name]),
       Enum.map(node.children, &data_signature/1)}
end
