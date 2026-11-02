defmodule Reach.EctoFieldContextTest do
  use ExUnit.Case, async: false

  alias Reach.{Effects, IR}
  alias Reach.Plugins.Ecto

  test "known query expression fields retain read-only SELECT inference and origin" do
    source = """
    defmodule QueryFields do
      import Ecto.Query, only: [from: 2, select: 3, where: 3, order_by: 3]
      def read(column) do
        from(row in Row, select: field(row, ^column), where: field(row, :id) > 0)
        |> select([row], field(row, ^column))
        |> order_by([row], asc: field(row, ^column))
        |> Repo.all()
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Ecto], file: "fields.ex") |> IR.all_nodes()
    fields = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :field))
    assert length(fields) == 4
    assert Enum.all?(fields, &(Effects.classify(&1, [Ecto]) == :pure))
    assert Enum.all?(fields, &(&1.meta.origin.plugin == Ecto))
    assert Enum.all?(fields, &(&1.source_span.file == "fields.ex"))
    project = project(source)

    call =
      Enum.find(
        Map.values(project.nodes),
        &(&1.meta[:module] == QueryFields and &1.meta[:function] == :read)
      )

    assert Effects.classify(call, [Ecto]) == :read
  end

  test "queryables interpolation and ordinary calls retain effects in query-then-write order" do
    source = """
    defmodule QueryWrites do
      import Ecto.Query, only: [from: 2, select: 3]
      def field(a, b) do
        IO.puts(a)
        Repo.update(b)
      end
      def run do
        query = from(row in field(:queryable, :value), select: field(row, :id))
        query |> select([row], ^field(:runtime, :value)) |> Repo.all()
        Repo.update(:after_read)
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Ecto]) |> IR.all_nodes()
    fields = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :field))
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :pure)) == 1
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :write)) == 2
    repo_calls = Enum.filter(nodes, &(&1.type == :call and &1.meta[:module] == Repo))
    assert Enum.map(repo_calls, & &1.meta.function) == [:update, :all, :update]
    project = project(source)

    runtime_field =
      Enum.find(
        Map.values(project.nodes),
        &(&1.meta[:kind] == :local and &1.meta[:function] == :field)
      )

    assert Effects.classify(runtime_field, [Ecto]) == :write
    functions = Map.values(project.nodes) |> Enum.filter(&(&1.type == :function_def))
    run = Enum.find(functions, &(&1.meta[:module] == QueryWrites and &1.meta[:name] == :run))
    field = Enum.find(functions, &(&1.meta[:module] == QueryWrites and &1.meta[:name] == :field))
    assert Reach.Check.Architecture.concrete_effects(run, [Ecto]) == [:read, :write]
    assert Reach.Check.Architecture.concrete_effects(field, [Ecto]) == [:io, :write]
  end

  test "schema declarations unknown helpers nested DSL and unsupported calls stay conservative" do
    source = """
    defmodule ConservativeFields do
      use Ecto.Schema
      schema "rows" do
        field(:literal, :string)
        for name <- [:dynamic], do: field(name, :string)
      end
      def unknown(row), do: from(row, select: field(row, :id))
      def known(row) do
        Ecto.Query.select(Row, [row], opaque(field(row, :id)))
        Ecto.Query.select(Row, [row], unknown_dsl(do: field(row, :id)))
      end
      def mutate(row) do
        Repo.transaction(fn ->
          Repo.all(Ecto.Query.select(Row, [row], field(row, :id)))
          Repo.update(row)
        end)
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Ecto]) |> IR.all_nodes()
    fields = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :field))
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :pure)) == 1
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :write)) == 5
    tx = Enum.find(nodes, &(&1.meta[:module] == Repo and &1.meta[:function] == :transaction))
    assert Effects.classify(tx, [Ecto]) == :write
  end

  test "the seven recorded query shapes lower only bound field expressions" do
    source = """
    defmodule SevenQueryShapes do
      import Ecto.Query, only: [from: 2, select: 3, where: 3, order_by: 3]
      def selectors(query, column) do
        query |> select([row], field(row, ^column)) |> order_by([row], asc: field(row, ^column))
      end
      def joined(column) do
        from(a in Assignment, join: r in Role, on: r.id == a.role_id, select: field(r, ^column))
      end
      def blockers(query, column, id, statuses) do
        query |> where([row], field(row, ^column) == ^id and row.status in ^statuses)
      end
      def children(query, column, ids) do
        query |> where([row], field(row, ^column) in ^ids)
      end
      def references(ids, column, codes) do
        from(reference in Reference, where: reference.id in ^ids or field(reference, ^column) in ^codes,
          select: map(reference, [:id]))
      end
      def resource_id(column) do
        from(identifier in Identifier, select: field(identifier, ^column), limit: 1)
      end
      def nullable(query, clauses) do
        Enum.reduce(clauses, query, fn
          {column, nil}, query -> where(query, [row], is_nil(field(row, ^column)))
          {column, value}, query -> where(query, [row], field(row, ^column) == ^value)
        end)
      end
    end
    """

    nodes = IR.from_string!(source, plugins: [Ecto]) |> IR.all_nodes()
    fields = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :field))
    assert length(fields) == 9
    assert Enum.all?(fields, &(Effects.classify(&1, [Ecto]) == :pure))
  end

  test "two-element tuples lower both positions without descending into ordinary calls" do
    source = """
    Ecto.Query.select(Row, [row], {field(row, :id), field(row, :name)})
    Ecto.Query.select(Row, [row], {opaque(field(row, :id)), field(row, :name)})
    """

    nodes = IR.from_string!(source, plugins: [Ecto]) |> IR.all_nodes()
    fields = Enum.filter(nodes, &(&1.type == :call and &1.meta[:function] == :field))
    assert length(fields) == 4
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :pure)) == 3
    assert Enum.count(fields, &(Effects.classify(&1, [Ecto]) == :write)) == 1
  end

  defp project(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-ecto-field-#{System.unique_integer([:positive])}.ex")

    File.write!(
      path,
      source <> "\ndefmodule FieldConsumer do\n def run(x), do: QueryFields.read(x)\nend\n"
    )

    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path], plugins: [Ecto])
  end
end
