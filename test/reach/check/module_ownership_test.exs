defmodule Reach.Check.ModuleOwnershipTest do
  use ExUnit.Case, async: true

  test "calls retain lexical module owners, avoiding invented cycles and retaining real ones" do
    dir = Path.join(System.tmp_dir!(), "reach-owners-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    sources = [
      {"outer.ex",
       """
       defmodule Lexical.Outer do
         defmodule Data do
           def read, do: Lexical.Leaf.read()
         end
         def run, do: Lexical.Runner.run()
       end
       """},
      {"runner.ex",
       """
       defmodule Lexical.Runner do
         def run, do: Lexical.Outer.Data.read()
       end
       defmodule Lexical.Leaf do
         def read, do: :ok
       end
       """},
      {"cycle.ex",
       """
       defmodule Lexical.C do
         def run, do: Lexical.D.run()
       end
       defmodule Lexical.D do
         def run, do: Lexical.C.run()
       end
       """}
    ]

    paths =
      for {file, source} <- sources do
        path = Path.join([dir, "lib", file])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, source)
        path
      end

    project = Reach.Project.from_sources(paths, plugins: [])

    config = [
      layers: [
        entry: ["Lexical.Outer"],
        data: ["Lexical.Outer.Data"],
        runner: ["Lexical.Runner"],
        leaf: ["Lexical.Leaf"],
        c: ["Lexical.C"],
        d: ["Lexical.D"]
      ]
    ]

    graph = Reach.Check.Architecture.layer_graph(project, config)
    edges = MapSet.new(graph.edges, &{&1.caller, &1.callee})

    assert edges ==
             MapSet.new([
               {Lexical.Outer, Lexical.Runner},
               {Lexical.Outer.Data, Lexical.Leaf},
               {Lexical.Runner, Lexical.Outer.Data},
               {Lexical.C, Lexical.D},
               {Lexical.D, Lexical.C}
             ])

    result = Reach.Check.Candidates.run(project, [], top: 1000)

    cycles =
      for candidate <- result.candidates, candidate.kind == :break_cycle, do: candidate.modules

    assert cycles == [["Lexical.C", "Lexical.D"]]
  end
end
