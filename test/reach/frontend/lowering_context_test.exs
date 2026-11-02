defmodule Reach.LoweringContextTest do
  use ExUnit.Case, async: true
  alias Reach.IR

  defmodule Hook do
    @behaviour Reach.Plugin
    def analyze(_, _), do: []

    def lower_elixir_ast(_ast, opts) do
      case opts[:callee] do
        %{module: Ecto.Query, kind: :remote, function: :select, arity: 3} ->
          send(self(), {:context, opts})
          :ignore

        %{function: :change_import} ->
          Process.put(:reach_import_map, %{{:select, 3} => ChangedImport})
          :ignore

        %{function: :change_alias} ->
          Process.put(:reach_alias_map, %{Q => ChangedAlias})
          :ignore

        _ ->
          :ignore
      end
    end
  end

  test "local imports and remote aliases expose additive context without changing emitted calls" do
    source = """
    defmodule LowerContext do
      import Ecto.Query, only: [select: 3]
      alias Ecto.Query, as: Q
      def run(row) do
        select(Row, [row], row.id)
        Q.select(Row, [row], row.id)
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Hook], file: "hook.ex") |> IR.all_nodes()
    calls = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :select))

    assert Enum.map(calls, &Map.take(&1.meta, [:kind, :module, :function, :arity])) ==
             List.duplicate(%{module: Ecto.Query, kind: :remote, function: :select, arity: 3}, 2)

    for _ <- 1..2 do
      assert_received {:context, opts}
      assert opts[:file] == "hook.ex"
      assert opts[:module] == LowerContext
    end
  end

  test "non-lowered emission still resolves after argument translation" do
    source = """
    defmodule LowerOrdering do
      import Ecto.Query, only: [select: 3]
      alias Ecto.Query, as: Q
      def run do
        select(change_import(), [], :value)
        Q.select(change_alias(), [], :value)
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Hook]) |> IR.all_nodes()
    calls = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :select))
    assert Enum.map(calls, & &1.meta.module) == [ChangedImport, ChangedAlias]
    assert_received {:context, first}
    assert first[:callee].module == Ecto.Query
    assert_received {:context, second}
    assert second[:callee].module == Ecto.Query
  end
end
