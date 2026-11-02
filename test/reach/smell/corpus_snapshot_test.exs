defmodule Reach.Smell.CorpusSnapshotTest do
  use ExUnit.Case, async: false

  alias Reach.Test.SmellCorpus

  @max_concurrency 2

  @tag timeout: 240_000
  test "pinned Hex packages match their accepted smell snapshots" do
    mismatches =
      SmellCorpus.packages()
      |> Task.async_stream(&scan_package/1,
        max_concurrency: @max_concurrency,
        ordered: false,
        timeout: 180_000
      )
      |> Enum.flat_map(fn
        {:ok, {package, identities}} ->
          expected = SmellCorpus.snapshot(package)

          if expected == identities,
            do: [],
            else: [%{package: package.name, expected: expected, actual: identities}]

        {:exit, reason} ->
          [%{failed_task: inspect(reason)}]
      end)

    if mismatches != [], do: IO.puts("CORPUS_MISMATCHES=" <> Jason.encode!(mismatches))
    assert mismatches == []
  end

  defp scan_package(package), do: {package, SmellCorpus.identities(package)}
end
