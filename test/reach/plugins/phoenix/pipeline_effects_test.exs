defmodule Reach.Plugins.Phoenix.PipelineArityTest do
  use ExUnit.Case, async: true

  alias Reach.{Effects, IR}
  alias Reach.Plugins.Phoenix

  test "real router pipeline DSL remains a compile-time write" do
    [node] = IR.from_string!("pipeline :browser do\n plug :accepts, [\"html\"]\nend")
    assert Phoenix.classify_effect(node) == :write
    assert Effects.classify(node, [Phoenix]) == :write
  end

  test "impossible pipeline DSL arities remain unresolved without a definition" do
    for source <- ["pipeline()", "pipeline(:name)", "pipeline(:one, :two, :three)"] do
      [node] = IR.from_string!(source)
      assert Phoenix.classify_effect(node) == nil
      assert Effects.classify(node, [Phoenix]) == :unknown
    end
  end
end

defmodule Reach.Plugins.Phoenix.PipelineInferenceTest do
  # Project inference shares named ETS effect caches with other inference tests.
  use ExUnit.Case, async: false

  alias Reach.Effects
  alias Reach.Plugins.Phoenix

  setup do
    for cache <- [:reach_classify_cache, :reach_dependency_effect_cache],
        :ets.whereis(cache) != :undefined do
      :ets.delete_all_objects(cache)
    end

    :ok
  end

  for {name, body, expected} <- [
        {PurePipelineHelper, "42", :pure},
        {WritePipelineHelper, "File.write!(\"path\", \"data\")", :write},
        {IOPipelineHelper, "IO.puts(\"message\")", :io},
        {UnknownPipelineHelper, "UnknownService.run()", :unknown}
      ] do
    test "local pipeline helper in #{inspect(name)} keeps #{expected} effect" do
      project =
        project("""
        defmodule #{inspect(unquote(name))} do
          def run, do: pipeline()
          defp pipeline, do: #{unquote(body)}
        end
        """)

      call =
        Enum.find(Map.values(project.nodes), fn node ->
          node.type == :call and node.meta[:kind] == :local and
            node.meta[:owner_module] == unquote(name) and node.meta[:function] == :pipeline
        end)

      assert call
      assert Effects.classify(call, [Phoenix]) == unquote(expected)
    end
  end

  test "router project retains the pipeline DSL effect" do
    project =
      project("""
      defmodule PipelineArityRouter do
        use Phoenix.Router
        pipeline :browser do
          plug :accepts, ["html"]
        end
      end
      """)

    call =
      Enum.find(Map.values(project.nodes), fn node ->
        node.type == :call and node.meta[:function] == :pipeline
      end)

    assert call
    assert Effects.classify(call, [Phoenix]) == :write
  end

  defp project(source) do
    path = Path.join(System.tmp_dir!(), "reach-pipeline-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm!(path) end)
    Reach.Project.from_sources([path], plugins: [Phoenix])
  end
end
