defmodule Reach.Effects.QueueSourceInferenceTest do
  use ExUnit.Case, async: false
  alias Reach.{Effects, IR}
  alias Reach.Test.QueueSourceInference.{Command, Store, Workers, PureStore, KnownWriter}

  setup do
    Effects.ensure_cache()
    :ets.delete_all_objects(:reach_classify_cache)
    :ok
  end

  test "source-only dry-run and writing clauses do not infer a pure helper" do
    source = """
    defmodule QueueOnly.Store do
      def queue(run, true), do: %{id: run.id}
      def queue(run, false) do
        File.write!(run.path, "queued")
        %{id: run.id}
      end
    end
    defmodule QueueOnly.Command do
      alias QueueOnly.Store
      def run(runs, dry_run), do: Enum.map(runs, &queue(&1.id, &1, dry_run))
      defp queue(id, nil, _dry_run), do: %{id: id}
      defp queue(_id, run, dry_run), do: Store.queue(run, dry_run)
    end
    defmodule QueueOnly.Consumer do
      def run(runs), do: QueueOnly.Command.run(runs, false)
    end
    """

    project = project_source(source)
    assert effect(project, QueueOnly.Command, :queue, 3) == :write
    assert effect(project, QueueOnly.Consumer, :run, 1) == :write
    assert Effects.classify(call("Store.queue(nil, false)"), []) == :write
  end

  test "compiled map-return hint cannot publish pure across an unresolved source writer chain" do
    path = Path.expand("../../support/queue_source_inference_fixtures.ex", __DIR__)
    project = Reach.Project.from_sources([path], plugins: [])
    definitions = Map.values(project.nodes) |> Enum.filter(&(&1.type == :function_def))

    for {module, name, arity, clauses} <- [
          {Command, :queue, 3, 2},
          {Store, :queue, 2, 2},
          {Workers, :enqueue, 2, 1}
        ] do
      matching =
        Enum.filter(
          definitions,
          &(&1.meta[:module] == module and &1.meta[:name] == name and &1.meta[:arity] == arity)
        )

      assert length(matching) == 1
      assert length(hd(matching).children) == clauses
    end

    results =
      for {module, name, arity} <- [
            {Command, :queue, 3},
            {Command, :run, 3},
            {Store, :queue, 2},
            {Workers, :enqueue, 2}
          ] do
        {inspect(module), name, arity, effect(project, module, name, arity)}
      end

    IO.inspect(results, label: "queue source inference", limit: :infinity)
    assert effect(project, Command, :queue, 3) != :pure
    assert effect(project, Command, :run, 3) != :pure
    assert effect(project, Store, :queue, 2) != :pure
    assert effect(project, Workers, :enqueue, 2) != :pure
  end

  test "pending source summaries override prewarmed compiled hints and cover defaults and aliases" do
    store_call = call("#{inspect(Store)}.queue(nil, false)")
    writer_call = call("#{inspect(KnownWriter)}.persist(nil, [])")
    assert %{effect: :pure, source: :typespec} = Effects.classify_with_provenance(store_call, [])
    assert %{effect: :pure, source: :typespec} = Effects.classify_with_provenance(writer_call, [])
    path = Path.expand("../../support/queue_source_inference_fixtures.ex", __DIR__)
    project = Reach.Project.from_sources([path], plugins: [])

    assert %{effect: :unknown, source: :local_inference} =
             Effects.classify_with_provenance(store_call, [])

    for name <- [inspect(Workers), "Workers"], arity <- [1, 2] do
      args = Enum.map_join(1..arity, ",", fn _ -> "nil" end)

      assert %{effect: :unknown, source: :local_inference} =
               Effects.classify_with_provenance(call("#{name}.enqueue(#{args})"), [])
    end

    assert effect(project, PureStore, :queue, 2) == :pure

    assert %{effect: :pure, source: :local_inference} =
             Effects.classify_with_provenance(call("PureStore.queue(nil, false)"), [])

    for name <- [inspect(KnownWriter), "KnownWriter"], arity <- [1, 2] do
      args = Enum.map_join(1..arity, ",", fn _ -> "nil" end)

      assert %{effect: :write, source: :local_inference} =
               Effects.classify_with_provenance(call("#{name}.persist(#{args})"), [])
    end
  end

  defmodule WriteOverride do
    @behaviour Reach.Plugin
    def analyze(_, _), do: []
    def classify_effect(%{type: :call, meta: %{module: Store, function: :queue}}), do: :write
    def classify_effect(_), do: nil
  end

  test "explicit plugins retain precedence over pending source summaries" do
    path = Path.expand("../../support/queue_source_inference_fixtures.ex", __DIR__)
    Reach.Project.from_sources([path], plugins: [])
    node = call("#{inspect(Store)}.queue(nil, false)")
    assert Effects.classify(node, []) == :unknown

    assert %{effect: :write, source: :plugin, classifier: WriteOverride} =
             Effects.classify_with_provenance(node, [WriteOverride])

    assert Effects.classify(node, []) == :unknown
  end

  defp call(source), do: IR.from_string!(source, plugins: []) |> hd()

  defp project_source(source) do
    path =
      Path.join(System.tmp_dir!(), "reach-queue-source-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path], plugins: [])
  end

  defp effect(project, module, name, arity) do
    node =
      Map.values(project.nodes)
      |> Enum.find(
        &(&1.type == :function_def and &1.meta[:module] == module and &1.meta[:name] == name and
            &1.meta[:arity] == arity)
      )

    assert node

    call =
      Enum.find(Map.values(project.nodes), fn candidate ->
        candidate.type == :call and candidate.meta[:function] == name and
          candidate.meta[:arity] == arity and
          (candidate.meta[:module] == module or
             (candidate.meta[:kind] == :local and candidate.meta[:owner_module] == module))
      end) ||
        IR.from_string!(
          "#{inspect(module)}.#{name}(#{Enum.map_join(1..arity, ",", fn _ -> "nil" end)})",
          plugins: []
        )
        |> hd()

    Effects.classify(call, [])
  end
end
