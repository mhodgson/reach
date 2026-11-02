defmodule Reach.Effects.ConditionalDefinitionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Reach.{Effects, IR, Project}

  setup do
    Effects.ensure_cache()
    :ets.delete_all_objects(:reach_classify_cache)
    :ok
  end

  test "compiled Credo UI emits a warning while source-only conditional definitions stay unknown" do
    start_supervised!(Credo.CLI.Output.Shell)

    output =
      capture_io(:stderr, fn -> Credo.CLI.Output.UI.warn("reach-conditional-ui-control") end)

    beam = Credo.CLI.Output.UI |> :code.which() |> to_string()

    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(String.to_charlist(beam), [:abstract_code])

    warn = Enum.find(forms, &match?({:function, _, :warn, 1, _}, &1))
    path = Path.join(Mix.Project.deps_path(), "credo/lib/credo/cli/output/ui.ex")
    project = Project.from_sources([path], plugins: [])

    parents =
      Map.new(for {_id, node} <- project.nodes, child <- node.children, do: {child.id, node})

    definitions =
      for {_id, n} <- project.nodes,
          n.type == :function_def and n.meta[:name] == :warn,
          do: %{
            id: n.id,
            module: inspect(n.meta[:module]),
            arity: n.meta[:arity],
            ancestors: ancestry(n, parents)
          }

    delegates =
      for {_id, n} <- project.nodes,
          n.type == :call and n.meta[:function] == :defdelegate,
          do: %{
            id: n.id,
            owner: inspect(n.meta[:owner_module]),
            kind: inspect(n.meta[:kind]),
            ancestors: ancestry(n, parents)
          }

    IO.puts(
      "CONDITIONAL_UI_PROOF=" <>
        Jason.encode!(%{
          mix_env: Mix.env(),
          beam: beam,
          compiled_source: Credo.CLI.Output.UI.module_info(:compile)[:source] |> to_string(),
          beam_sha256: Base.encode16(:crypto.hash(:sha256, File.read!(beam)), case: :lower),
          source_sha256: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower),
          output: output,
          compiled_warn: inspect(warn, limit: :infinity),
          definitions: definitions,
          delegates: delegates,
          effect: effect(Credo.CLI.Output.UI, :warn, 1)
        })
    )

    assert output =~ "reach-conditional-ui-control"
    assert effect(Credo.CLI.Output.UI, :warn, 1) == :unknown
  end

  test "either conditional branch ordering preserves unknown rather than selecting a no-op body" do
    for {module, first, second} <- [
          {ConditionalProof.Left, "def call(value, mode \\\\ :default), do: {value, mode}",
           "defdelegate call(value, mode \\\\ :default), to: UnknownConditionalTarget"},
          {ConditionalProof.Right,
           "defdelegate call(value, mode \\\\ :default), to: UnknownConditionalTarget",
           "def call(value, mode \\\\ :default), do: {value, mode}"}
        ] do
      source = """
      defmodule #{inspect(module)} do
        if System.get_env("REACH_UNPROVED_CONDITION") do
          #{first}
        else
          #{second}
        end
        def stable(value), do: if(is_nil(value), do: 0, else: value)
        def persist(path, opts \\\\ []), do: File.write!(path, inspect(opts))
      end
      """

      project_source(source)

      for name <- [module, Module.concat([module |> Module.split() |> List.last()])],
          arity <- [1, 2] do
        assert effect(name, :call, arity) == :unknown
        assert effect(name, :persist, arity) == :write
      end

      assert effect(module, :stable, 1) == :pure
    end
  end

  test "a conditional local no-op cannot mask an actual IO delegate" do
    project_source("""
    defmodule ConditionalProof.IOBranch do
      if System.get_env("REACH_UNPROVED_CONDITION") do
        def emit(value), do: value
      else
        defdelegate emit(value), to: IO, as: :puts
      end
    end
    """)

    assert effect(ConditionalProof.IOBranch, :emit, 1) == :unknown
    assert Effects.classify(IR.from_string!("IO.puts(:value)", plugins: []) |> hd(), []) == :io
  end

  defp ancestry(node, parents) do
    case Map.get(parents, node.id) do
      nil -> []
      parent -> [Atom.to_string(parent.type) | ancestry(parent, parents)]
    end
  end

  defp effect(module, name, arity) do
    args = Enum.map_join(List.duplicate("nil", arity), ",", & &1)

    IR.from_string!("#{inspect(module)}.#{name}(#{args})", plugins: [])
    |> hd()
    |> Effects.classify([])
  end

  defp project_source(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-conditional-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: [])
  end
end
