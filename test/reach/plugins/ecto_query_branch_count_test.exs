defmodule Reach.EctoQueryBranchCountTest do
  use ExUnit.Case, async: true

  alias Reach.{IR, Project}
  alias Reach.Check.{Candidates, Changed}
  alias Reach.Plugins.Ecto

  @source """
  defmodule QueryBranchProof do
    import Ecto.Query, only: [where: 3, from: 2, select: 3]
    def query(q) do
      where(q, [r], r.a == 1 and r.b == 2 or r.c == 3 and r.d == 4 or
        r.e == 5 and r.f == 6 or r.g == 7 and r.h == 8 or r.i == 9)
    end
    def from_query(q) do
      from(r in q, where: r.a == 1 and r.b == 2 or r.c == 3 and r.d == 4 or
        r.e == 5 and r.f == 6 or r.g == 7 and r.h == 8 or r.i == 9)
    end
    def caller(q), do: {query(q), from_query(q), runtime_branchy(q, true, false)}
    def runtime_branchy(q, a, b) do
      where(q, [r], r.a == 1 and ^(a and b or a and b or a and b or a and b or a))
    end
    def queryable(q, a, b), do: where(if(a and b, do: q, else: q), [r], r.a == 1)
    def pinned(q, a, b), do: where(q, [r], r.a == ^(a and b))
    def unknown(q, a, b), do: where(q, [r], opaque(a and b))
    def nested(q, a, b), do: where(q, [r], opaque(fn -> a or b end))
    def pinned_child(q, a, b), do: where(q, [r], r.a == 1 and ^(a and b))
    def pinned_if(q, a, b), do: where(q, [r], r.a == 1 or ^(if(a or b, do: true, else: false)))
    def nested_dsl(q, a, b), do: where(q, [r], r.a == 1 and opaque_dsl(do: a or b))
    def nested_child(q, a, b), do: where(q, [r], r.a == 1 and opaque(fn -> a or b end))
    def select_data(q, a, b), do: select(q, [r], a and b)
    def remote(q), do: Ecto.Query.where(q, [r], r.a == 1 and r.b == 2)
    def ordinary(a, b), do: a and b
    def guarded(a, b) when a and b, do: :ok
    def pure_branch(a), do: if(a, do: :yes, else: :no)
  end
  defmodule WrongQueryImport do
    import Other.Query, only: [where: 3, from: 2, select: 3]
    def wrong(q, a, b), do: where(q, [], a and b)
    def wrong_from(q, a, b), do: from(q, where: a or b)
  end
  defmodule LocalQueryNames do
    def where(q, _, expr), do: {q, expr}
    def from(q, expr), do: {q, expr}
    def local(q, a, b), do: where(q, [], a and b)
    def local_from(q, a, b), do: from(q, where: a or b)
  end
  """

  test "resolved where predicates are data rather than runtime branches in public IR" do
    functions = functions(IR.from_string!(@source, plugins: [Ecto]))
    query = Map.fetch!(functions, :query)
    assert Enum.any?(IR.all_nodes(query), &(&1.meta[:module] == Elixir.Ecto.Query))
    assert Changed.branch_count(query) == 0
  end

  test "runtime arguments and unresolved contexts retain branches" do
    functions = functions(IR.from_string!(@source, plugins: [Ecto]))

    for name <- [
          :pinned,
          :unknown,
          :nested,
          :ordinary,
          :guarded,
          :pure_branch,
          :wrong,
          :wrong_from,
          :local,
          :local_from
        ] do
      assert Changed.branch_count(Map.fetch!(functions, name)) == 1, inspect(name)
    end

    assert Changed.branch_count(Map.fetch!(functions, :queryable)) == 2
  end

  test "data operators exclude only themselves while runtime descendants remain branches" do
    functions = functions(IR.from_string!(@source, plugins: [Ecto]))

    for {name, count} <- [
          pinned_child: 1,
          pinned_if: 2,
          nested_dsl: 1,
          nested_child: 1,
          select_data: 1,
          remote: 0
        ] do
      assert Changed.branch_count(Map.fetch!(functions, name)) == count, inspect(name)
    end

    nodes = Map.fetch!(functions, :pinned_child) |> IR.all_nodes()
    booleans = Enum.filter(nodes, &(&1.type == :binary_op and &1.meta[:operator] == :and))
    assert Enum.map(booleans, & &1.meta[:operator_semantics]) == [:data, nil]
    assert Enum.any?(nodes, &(&1.type == :pin))
  end

  test "without the DSL plugin ordinary operator semantics stay executable" do
    functions = functions(IR.from_string!(@source, plugins: []))
    assert Changed.branch_count(Map.fetch!(functions, :query)) == 8
    assert Changed.branch_count(Map.fetch!(functions, :from_query)) == 8
    assert Changed.branch_count(Map.fetch!(functions, :pinned_child)) == 2
  end

  test "resolved from predicates are data rather than runtime branches in public IR" do
    functions = functions(IR.from_string!(@source, plugins: [Ecto]))
    assert Changed.branch_count(Map.fetch!(functions, :from_query)) == 0
  end

  test "Project and Candidates omit SQL where predicate extraction" do
    assert_query_candidate(:query, 0)
  end

  test "Project and Candidates omit SQL from predicate extraction" do
    assert_query_candidate(:from_query, 0)
  end

  test "runtime branches inside a pin still produce extraction candidates" do
    assert_query_candidate(:runtime_branchy, 8)
  end

  test "query annotations preserve every operand call and source span" do
    source = """
    defmodule PreservedQueryFacts do
      import Ecto.Query, only: [where: 3]
      def run(q, flag) do
        where(q, [r], r.id == 1 and ^(if flag, do: Repo.update(:first), else: Repo.update(:second)))
        |> Repo.all()
      end
    end
    """

    plain = IR.from_string!(source, file: "preserved.ex", plugins: []) |> IR.all_nodes()
    lowered = IR.from_string!(source, file: "preserved.ex", plugins: [Ecto]) |> IR.all_nodes()

    facts = fn nodes ->
      Enum.map(nodes, fn node ->
        {node.id, node.type, Map.delete(node.meta, :operator_semantics),
         Enum.map(node.children, & &1.id), node.source_span}
      end)
    end

    assert facts.(lowered) == facts.(plain)
    assert Enum.any?(lowered, &(&1.meta[:operator_semantics] == :data))
    calls = Enum.filter(lowered, &(&1.type == :call and &1.meta[:module] == Repo))
    assert Enum.map(calls, & &1.meta.function) == [:all, :update, :update]
    assert Enum.map(calls, &Reach.Effects.classify(&1, [Ecto])) == [:read, :write, :write]
  end

  defp assert_query_candidate(name, branches) do
    dir = Path.join(System.tmp_dir!(), "query-branch-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "query.ex")
    File.write!(path, @source)
    project = Project.from_sources([path], plugins: [Ecto])
    function = Map.fetch!(functions(Map.values(project.nodes)), name)
    result = Candidates.run(project, [], top: 100)

    candidate =
      Enum.find(
        result.candidates,
        &(&1.kind == :extract_pure_region and
            &1.target == "QueryBranchProof.#{name}/#{function.meta.arity}")
      )

    assert Changed.branch_count(function) == branches

    inspect_candidates =
      Reach.Inspect.Candidates.find(
        project,
        {QueryBranchProof, name, function.meta.arity},
        function
      )

    inspect_candidate = Enum.find(inspect_candidates, &(&1.kind == :extract_pure_region))

    hotspot =
      Reach.Map.Analysis.section_data(project, :hotspots, %{top: 100}, nil)
      |> Enum.find(&(&1.display_function == "QueryBranchProof.#{name}/#{function.meta.arity}"))

    if branches == 0 do
      assert is_nil(hotspot)
      assert is_nil(candidate)
      assert is_nil(inspect_candidate)
    else
      assert hotspot.branches == branches
      assert candidate.branches == branches
      assert inspect_candidate.branches == branches
    end
  end

  defp functions(nodes) do
    nodes
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :function_def))
    |> Map.new(&{&1.meta.name, &1})
  end
end
