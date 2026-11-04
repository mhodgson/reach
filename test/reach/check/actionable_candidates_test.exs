defmodule Reach.Check.ActionableCandidatesTest do
  use ExUnit.Case, async: true

  test "recommendations distinguish cache ownership and useful regions from already separated code" do
    dir = Path.join(System.tmp_dir!(), "reach-actionable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "examples.ex")

    File.write!(path, """
    defmodule ActionableExamples do
      defp load!(path), do: File.read!(path)
      def cached(path) do
        case :persistent_term.get({__MODULE__, :model}, nil) do
          nil ->
            model = load!(Application.app_dir(:reach, path))
            :persistent_term.put({__MODULE__, :model}, model)
            model
          model -> model
        end
      end
      def extra_write(path) do
        case :persistent_term.get(:extra, nil) do
          nil ->
            value = File.read!(path)
            :persistent_term.put(:extra, value)
            File.write!(path, value)
            value
          value -> value
        end
      end
      def embedded(path) do
        case :persistent_term.get(:other, nil) do
          nil ->
            model = if path == "", do: "empty", else: File.read!(path)
            :persistent_term.put(:other, model)
            model
          model -> model
        end
      end
      def argument_decision(path) do
        case :persistent_term.get(:arg, nil) do
          nil ->
            model = File.read!(if path == "", do: "default", else: path)
            :persistent_term.put(:arg, model)
            model
          model -> model
        end
      end
      def rebound(key) do
        case :persistent_term.get(key, nil) do
          nil ->
            key = File.read!(key)
            :persistent_term.put(key, key)
            key
          model -> model
        end
      end
      def callback(items, path) do
        value = case items do
          [] -> "empty"
          _ -> Enum.reduce(items, path, &File.write!/2)
        end
        File.write!(path, value)
        value
      end
      def caption?(x), do: byte_size(x) > 4 and byte_size(x) < 70 and x != "none"
      def useful(x, path) do
        value = case x do
          "" -> "empty"
          _ -> x
        end
        File.write!(path, value)
        value
      end
      def tiny(x, path) do
        if x == "notice", do: File.write!(path, "notice")
        value = case x do
          "" -> "empty"
          _ -> x
        end
        File.write!(path, value)
      end
      def larger(x, path) do
        value = case x do
          "" -> "empty"
          _ -> x
        end
        File.write!(path, value)
        value = case x do
          "" -> case path do
            "" -> "missing"
            _ -> path
          end
          _ -> x
        end
        File.write!(path, value)
      end
      def coordinator(path) do
        value = File.read!(path)
        File.write!(path, value)
      end
      def mixed(path) do
        source = File.read!(path)
        value = case source do
          "" -> "empty"
          _ -> source
        end
        File.write!(path, value)
      end
      def overwritten(x, path) do
        value = if x == "", do: "empty", else: x
        value = File.read!(path)
        File.write!(path, value)
      end
      def unrelated(x, path) do
        value = if x == "", do: "empty", else: x
        text = value <> "!"
        File.write!(path, "constant")
        text
      end
      def tuple_unrelated(x, path) do
        value = if x == "", do: "empty", else: x
        {value, File.write!(path, "constant")}
      end
      def membership(flag, values, pid) do
        value = case flag do
          true -> 1 in values
          _ -> false
        end
        send(pid, value)
      end
      def inspected_path(path) do
        case :persistent_term.get(:inspected, nil) do
          nil ->
            model = File.read!(inspect(path))
            :persistent_term.put(:inspected, model)
            model
          model -> model
        end
      end
      def callers(x, path), do: {cached(path), extra_write(path), embedded(path), caption?(x), useful(x, path), overwritten(x, path), argument_decision(path), rebound(path), callback([], path), unrelated(x, path), tuple_unrelated(x, path), membership(true, [], self()), inspected_path(path), tiny(x, path), larger(x, path), coordinator(path), mixed(path)}
    end
    """)

    erlang_path = Path.join(dir, "actionable_erlang.erl")

    File.write!(erlang_path, """
    -module(actionable_erlang).
    -export([caller/2, run/2, cached/2, either/2]).
    either(A, B) -> A orelse B.
    caller(X, Pid) -> {run(X, Pid), cached(X, Pid)}.
    run(X, Pid) ->
      V = case X of a -> Pid ! hello; _ -> ok end,
      erlang:send(Pid, V).
    cached(Flag, Path) ->
      case persistent_term:get(model, nil) of
        nil ->
          V = file:read_file(Flag andalso Path),
          persistent_term:put(model, V),
          V;
        V -> V
      end.
    """)

    project = Reach.Project.from_sources([path, erlang_path], plugins: [])

    result =
      Reach.Check.Candidates.run(project,
        candidates: [thresholds: [branchy_function_branches: 1]],
        top: 1000
      )

    targets = fn kind -> for c <- result.candidates, c.kind == kind, do: c.target end

    refute Enum.any?(
             result.candidates,
             &(&1.kind == :extract_pure_region and &1.target == ":actionable_erlang.run/2")
           )

    erlang_function =
      Enum.find_value(project.nodes, fn {_id, node} ->
        if node.type == :function_def and node.meta[:name] == :run, do: node
      end)

    erlang_config =
      Reach.Config.normalize(candidates: [thresholds: [branchy_function_branches: 1]])

    erlang_inspected =
      Reach.Inspect.Candidates.find(
        project,
        {:actionable_erlang, :run, 2},
        erlang_function,
        erlang_config.candidates
      )

    refute Enum.any?(erlang_inspected, &(&1.kind == :extract_pure_region))

    refute ":actionable_erlang.cached/2" in targets.(:isolate_effects)

    for {name, expected} <- [cached: 2, either: 1] do
      function =
        Enum.find_value(project.nodes, fn {_id, node} ->
          if node.type == :function_def and node.meta[:name] == name and
               node.meta[:module] == :actionable_erlang,
             do: node
        end)

      assert Reach.Check.Changed.branch_count(function) == expected
    end

    actual = {
      "ActionableExamples.cached/1" in targets.(:isolate_effects),
      "ActionableExamples.extra_write/1" in targets.(:isolate_effects),
      "ActionableExamples.embedded/1" in targets.(:isolate_effects),
      "ActionableExamples.caption?/1" in targets.(:extract_pure_region),
      "ActionableExamples.useful/2" in targets.(:extract_pure_region)
    }

    assert actual == {false, false, false, false, true}

    region_config =
      Reach.Config.normalize(candidates: [thresholds: [branchy_function_branches: 2]])

    region_result = Reach.Check.Candidates.run(project, region_config, top: 1000)

    for {name, expected} <- [tiny: false, larger: true] do
      mfa = {ActionableExamples, name, 2}

      function =
        Enum.find_value(project.nodes, fn {_id, node} ->
          if node.type == :function_def and
               {node.meta[:module], node.meta[:name], node.meta[:arity]} == mfa,
             do: node
        end)

      target = "ActionableExamples.#{name}/2"

      assert Enum.any?(
               region_result.candidates,
               &(&1.kind == :extract_pure_region and &1.target == target)
             ) == expected

      inspected = Reach.Inspect.Candidates.find(project, mfa, function, region_config.candidates)
      assert Enum.any?(inspected, &(&1.kind == :extract_pure_region)) == expected
    end

    refute "ActionableExamples.coordinator/1" in targets.(:isolate_effects)
    assert "ActionableExamples.mixed/1" in targets.(:isolate_effects)

    mixed =
      Enum.find(
        result.candidates,
        &(&1.kind == :isolate_effects and &1.target == "ActionableExamples.mixed/1")
      )

    assert mixed.region.output == :value
    assert mixed.region.branches == 1

    for name <- [:coordinator, :extra_write, :embedded, :rebound] do
      function =
        Enum.find_value(project.nodes, fn {_id, node} ->
          if node.type == :function_def and node.meta[:module] == ActionableExamples and
               node.meta[:name] == name,
             do: node
        end)

      assert Reach.Check.Architecture.concrete_effects(function, []) |> Enum.sort() == [
               :read,
               :write
             ]

      refute Reach.Evidence.Refactoring.read_through_cache?(function, [])
    end

    stream =
      Stream.map([1], fn n ->
        send(self(), :membership_executed)
        n
      end)

    assert 1 in stream
    assert_received :membership_executed
    refute "ActionableExamples.membership/3" in targets.(:extract_pure_region)
    refute "ActionableExamples.inspected_path/1" in targets.(:isolate_effects)
    refute "ActionableExamples.argument_decision/1" in targets.(:isolate_effects)
    refute "ActionableExamples.rebound/1" in targets.(:isolate_effects)
    refute "ActionableExamples.callback/2" in targets.(:extract_pure_region)
    refute "ActionableExamples.tuple_unrelated/2" in targets.(:extract_pure_region)
    refute "ActionableExamples.unrelated/2" in targets.(:extract_pure_region)
    refute "ActionableExamples.overwritten/2" in targets.(:extract_pure_region)

    for {name, arity, kind, expected} <- [
          {:cached, 1, :isolate_effects, false},
          {:coordinator, 1, :isolate_effects, false},
          {:mixed, 1, :isolate_effects, true},
          {:caption?, 1, :extract_pure_region, false},
          {:useful, 2, :extract_pure_region, true}
        ] do
      mfa = {ActionableExamples, name, arity}

      {_id, function} =
        Enum.find(project.nodes, fn {_id, node} ->
          node.type == :function_def and
            {node.meta[:module], node.meta[:name], node.meta[:arity]} == mfa
        end)

      config = Reach.Config.normalize(candidates: [thresholds: [branchy_function_branches: 1]])
      inspected = Reach.Inspect.Candidates.find(project, mfa, function, config.candidates)
      assert Enum.any?(inspected, &(&1.kind == kind)) == expected
    end
  end
end
