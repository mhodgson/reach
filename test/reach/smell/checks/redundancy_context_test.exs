defmodule Reach.Smell.RedundancyContextTest do
  use ExUnit.Case, async: false

  alias Reach.{Effects, IR, Project}
  alias Reach.Smell.Checks.RedundantComputation
  alias Reach.Test.RedundancyEffects.{Desk, Judge, Requests}

  setup do
    Effects.ensure_cache()
    :ets.delete_all_objects(:reach_classify_cache)
    :ok
  end

  for {module, function, effect} <- [
        {Requests, :for_party, :read},
        {Judge, :model, :read},
        {Desk, :source_cancelled?, :unknown}
      ] do
    test "redundancy respects project effects for #{function}" do
      path = Path.expand("../../../support/redundancy_effect_fixtures.ex", __DIR__)
      project = Project.from_sources([path], plugins: [Reach.Plugins.Ecto])

      node =
        Enum.find(Map.values(project.nodes), fn node ->
          node.type == :call and node.meta[:function] == unquote(function) and
            node.meta[:owner_module] == unquote(module)
        end)

      assert node
      explicit = Effects.classify_with_provenance(node, project.plugins)
      assert explicit.effect == unquote(effect)

      findings = RedundantComputation.run(project)

      refute Enum.any?(
               findings,
               &String.starts_with?(&1.message, "#{unquote(function)} called twice")
             )
    end
  end

  test "separate comprehension bindings differ while one body retains pure duplicates" do
    source = """
    defmodule LexicalKeys do
      def key(ref), do: Map.get(ref, :id)
      def run(roles, issuers) do
        roles = for ref <- roles, do: key(ref)
        issuers = for ref <- issuers, do: key(ref)
        {roles, issuers}
      end
      def same_body(refs) do
        for ref <- refs do
          first = key(ref)
          second = key(ref)
          {first, second}
        end
      end
      def same_binding(ref) do
        first = key(ref)
        second = key(ref)
        {first, second}
      end
    end
    """

    path = Path.join(System.tmp_dir!(), "reach-lexical-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert Enum.any?(
             IR.from_string!(source, plugins: []) |> IR.all_nodes(),
             &(&1.type == :comprehension)
           )

    project = Project.from_sources([path], plugins: Reach.Plugin.detect())
    findings = RedundantComputation.run(project)
    assert Enum.map(findings, & &1.location) |> Enum.sort() == ["#{path}:11", "#{path}:17"]
  end
end
