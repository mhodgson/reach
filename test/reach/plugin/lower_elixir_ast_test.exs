defmodule Reach.Plugin.LowerElixirASTTest do
  use ExUnit.Case, async: true

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.Source.{Origin, Span}

  defmodule LoweringPlugin do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_all_nodes, _opts), do: []

    @impl true
    def lower_elixir_ast({:dsl_if, meta, [condition, body]}, opts) do
      span = %Span{file: opts[:file], start_line: meta[:line], start_col: meta[:column] || 1}

      ast =
        {:if,
         [
           line: meta[:line],
           column: meta[:column],
           reach: %Origin{
             language: :test_dsl,
             kind: :if,
             label: "dsl_if",
             span: span,
             plugin: __MODULE__,
             generated?: true
           }
         ], [condition, [do: body]]}

      {:ok, ast}
    end

    def lower_elixir_ast({:dsl_data, meta, [left, right]}, opts) do
      origin = %Origin{
        language: :test_dsl,
        kind: :operator,
        label: "dsl_data",
        span: Span.from_meta(meta, opts[:file]),
        plugin: __MODULE__,
        generated?: false
      }

      {:ok, {:and, Keyword.merge(meta, operator_semantics: :data, reach: origin), [left, right]}}
    end

    def lower_elixir_ast(_ast, _opts), do: :ignore
  end

  test "plugins lower local Elixir AST before IR translation" do
    source = """
    defmodule Demo do
      def render(assigns) do
        dsl_if(assigns.ok, :visible)
      end
    end
    """

    assert {:ok, nodes} =
             ElixirFrontend.parse(source, file: "demo.ex", plugins: [LoweringPlugin])

    lowered_case =
      nodes
      |> flatten()
      |> Enum.find(&(&1.type == :case and &1.meta[:origin]))

    assert lowered_case.meta.origin.label == "dsl_if"
    assert lowered_case.meta.origin.language == :test_dsl
    assert lowered_case.source_span.file == "demo.ex"
    assert lowered_case.source_span.start_line == 3
  end

  test "ast_to_graph applies plugin lowering" do
    ast =
      Code.string_to_quoted!(
        """
        defmodule Demo do
          def render(assigns) do
            dsl_if(assigns.ok, :visible)
          end
        end
        """,
        columns: true
      )

    assert {:ok, graph} = Reach.ast_to_graph(ast, file: "demo.ex", plugins: [LoweringPlugin])

    lowered_case =
      graph
      |> Reach.nodes()
      |> Enum.find(&(&1.type == :case and &1.meta[:origin]))

    assert lowered_case.meta.origin.label == "dsl_if"
    assert lowered_case.source_span.file == "demo.ex"
  end

  test "data operator lowering retains operands origin and spans without annotating descendants" do
    source = "dsl_data(left(), right() or fallback())"

    assert {:ok, [operator]} =
             ElixirFrontend.parse(source, file: "data.ex", plugins: [LoweringPlugin])

    assert operator.type == :binary_op
    assert operator.meta.operator == :and
    assert operator.meta.operator_semantics == :data
    assert operator.meta.origin.label == "dsl_data"
    assert operator.meta.origin.plugin == LoweringPlugin
    assert operator.source_span == Span.to_map(operator.meta.origin.span)
    assert operator.source_span.start_line == 1
    assert operator.source_span.start_col == 1
    assert [left, right] = operator.children
    assert left.meta.function == :left
    assert left.source_span.start_col == 10
    assert right.type == :binary_op
    assert right.meta.operator == :or
    refute Map.has_key?(right.meta, :operator_semantics)
    assert Enum.map(right.children, & &1.meta.function) == [:right, :fallback]
    assert Reach.Check.Changed.branch_count(operator) == 1
  end

  defp flatten(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &flatten/1)
  defp flatten(%{children: children} = node), do: [node | flatten(children)]
end
