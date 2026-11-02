defmodule Reach.Smell.ClockAndBindingTest do
  # Each case resets the shared classification ETS table.
  use ExUnit.Case, async: false

  alias Reach.{Effects, IR, Project}
  alias Reach.Smell.Checks.RedundantComputation

  setup do
    Effects.ensure_cache()
    :ets.delete_all_objects(:reach_classify_cache)
    :ok
  end

  test "supported UTC clock arities read state while conversion stays pure" do
    for expression <- [
          "DateTime.utc_now()",
          "DateTime.utc_now(:second)",
          "DateTime.utc_now(:second, Calendar.ISO)"
        ] do
      [node] = IR.from_string!(expression, plugins: [])
      assert Effects.classify(node, []) == :read
    end

    [conversion] = IR.from_string!("DateTime.to_unix(datetime)", plugins: [])
    assert Effects.classify(conversion, []) == :pure
  end

  test "credential completion clock defaults are not redundant" do
    project =
      project("""
      defmodule CompletionClocks do
        def complete(token_set, opts) do
          %{
            last_activity_at: now(opts),
            last_successful_auth_at: token_set.refreshed_at || now(opts),
            last_refresh_attempt_at: token_set.refreshed_at || now(opts)
          }
        end
        defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now(:second))
        def convert(datetime), do: DateTime.to_unix(datetime)
        def deterministic(datetime) do
          first = convert(datetime)
          second = convert(datetime)
          {first, second}
        end
      end
      """)

    findings = RedundantComputation.run(project)
    refute Enum.any?(findings, &String.starts_with?(&1.message, "now called twice"))
    assert Enum.any?(findings, &String.starts_with?(&1.message, "convert called twice"))
  end

  test "matching another round invalidates rebound document and pair arguments" do
    project =
      project("""
      defmodule PairingRounds do
        def rounds(a, b, pairs, by) do
          {pairs, b} = round(a, b, pairs, by, &(&1.type == &2.type))
          a = unpaired(a, pairs)
          {pairs, b} = round(a, b, pairs, by, nil)
          {pairs, unpaired(a, pairs), b}
        end
        defp unpaired(documents, pairs) do
          paired = MapSet.new(pairs, &elem(&1, 0))
          Enum.reject(documents, &MapSet.member?(paired, &1.index))
        end
        defp round(_a, b, pairs, _by, _same), do: {pairs ++ [{0, 0}], b}
      end
      """)

    refute Enum.any?(
             RedundantComputation.run(project),
             &String.starts_with?(&1.message, "unpaired called twice")
           )
  end

  test "argument rebinding differs from assigning another call result" do
    project =
      project("""
      defmodule BindingKeys do
        def key(value), do: Map.get(value, :id)
        def unchanged(value) do
          a = key(value)
          b = key(value)
          {a, b}
        end
        def rebound(value, other) do
          a = key(value)
          value = other
          b = key(value)
          {a, b}
        end
        def same_value_rebound(value) do
          a = key(value)
          value = value
          b = key(value)
          {a, b}
        end
        def rhs_before_binding(value) do
          value = key(value)
          b = key(value)
          {value, b}
        end
        def pinned(value) do
          a = key(value)
          ^value = value
          b = key(value)
          {a, b}
        end
      end
      """)

    lines = Enum.map(RedundantComputation.run(project), &line/1) |> Enum.sort()
    assert lines == [5, 28]
  end

  test "shadowed comprehension documents and nested loops keep independent bindings" do
    project =
      project("""
      defmodule DocumentLoops do
        def key(doc), do: Map.get(doc, :start)
        def keep?(doc, mains), do: doc in mains
        def documents(reading, first_notices, agent_mains) do
          starts = for doc <- reading.documents, do: key(doc)
          restored = for doc <- first_notices, keep?(doc, agent_mains), do: key(doc)
          mains = agent_mains ++ restored
          others = for doc <- first_notices, keep?(doc, mains), do: key(doc)
          added = for doc <- reading.documents, keep?(doc, mains), do: key(doc)
          {starts, others, added}
        end
        def shadow(doc, rows) do
          first = key(doc)
          nested = for doc <- rows do
            before = key(doc)
            doc = %{start: 42}
            after_rebind = key(doc)
            {before, after_rebind}
          end
          last = key(doc)
          {first, nested, last}
        end
        def nested(rows) do
          for row <- rows do
            for doc <- row do
              first = key(doc)
              last = key(doc)
              {first, last}
            end
          end
        end
      end
      """)

    lines = Enum.map(RedundantComputation.run(project), &line/1) |> Enum.sort()
    assert lines == [20, 27]
  end

  test "try-local bindings preserve outer facts and body duplicates" do
    project =
      project("""
      defmodule TryKeys do
        def key(value), do: Map.get(value, :id)
        def outer(value, other) do
          first = key(value)
          try do
            value = other
            value
          after
            :ok
          end
          second = key(value)
          {first, second}
        end
        def inside(value, other) do
          try do
            value = other
            first = key(value)
            second = key(value)
            {first, second}
          after
            :ok
          end
        end
      end
      """)

    messages = Enum.map(RedundantComputation.run(project), & &1.message) |> Enum.sort()

    assert messages == [
             "key called twice with same args (line 17 and 18)",
             "key called twice with same args (line 4 and 11)"
           ]
  end

  test "receive-after and assigned with bodies cannot rebind outer arguments" do
    project =
      project("""
      defmodule OtherScopes do
        def key(value), do: Map.get(value, :id)
        def received(value, other) do
          first = key(value)
          receive do
            :ignored -> :ok
          after
            0 ->
              value = other
              value
          end
          second = key(value)
          {first, second}
        end
        def assigned(value, other) do
          first = key(value)
          result = with :ok <- :ok do
            value = other
            value
          end
          second = key(value)
          {first, result, second}
        end
      end
      """)

    messages = Enum.map(RedundantComputation.run(project), & &1.message) |> Enum.sort()

    assert messages == [
             "key called twice with same args (line 16 and 21)",
             "key called twice with same args (line 4 and 12)"
           ]
  end

  test "bitstring size references are reads while segment variables bind" do
    project =
      project("""
      defmodule BinaryBindings do
        def key(value), do: {:key, value}
        def size_reference(n, bytes) do
          first = key(n)
          <<part::binary-size(n)>> = bytes
          second = key(n)
          {first, part, second}
        end
        def rebound_part(part, n, bytes) do
          first = key(part)
          <<part::binary-size(n)>> = bytes
          second = key(part)
          {first, second}
        end
      end
      """)

    assert Enum.map(RedundantComputation.run(project), & &1.message) == [
             "key called twice with same args (line 4 and 6)"
           ]
  end

  defp project(source) do
    path = Path.join(System.tmp_dir!(), "reach-bindings-#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Project.from_sources([path], plugins: Reach.Plugin.detect())
  end

  defp line(finding),
    do: finding.location |> String.split(":") |> List.last() |> String.to_integer()
end
