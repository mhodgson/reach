defmodule Reach.Check.Smells do
  @moduledoc """
  Runs structural and performance smell checks over a loaded project.
  """

  alias Reach.{Config, Plugin}
  alias Reach.Project.TermStore
  alias Reach.Smell.{DSLGuard, Registry, Source, SourceRunner, Suppressions}

  @doc """
  Runs the smell checks. With `term_store: :persistent_term`, source files are
  parsed once into the shared store and the checks run side by side.
  """
  def run(project, config \\ [], opts \\ []) do
    config = Config.normalize(config)

    {pattern_checks, checks} =
      Enum.split_with(Reach.Smell.Registry.checks(project, config), &pattern_check?/1)

    runs = [
      fn -> SourceRunner.run(project, pattern_checks) end
      | Enum.map(checks, fn check -> fn -> run_check(check, project, config) end end)
    ]

    findings =
      if TermStore.store?(opts) and Source.share_asts(project, opts) == :ok do
        runs
        |> Task.async_stream(& &1.(), ordered: true, timeout: :infinity)
        |> Enum.flat_map(fn {:ok, found} -> found end)
      else
        Enum.flat_map(runs, & &1.())
      end

    plugin_checks = project |> Map.get(:plugins, []) |> Plugin.smell_checks() |> MapSet.new()

    plugin_kinds =
      (pattern_checks ++ checks)
      |> Enum.filter(&MapSet.member?(plugin_checks, &1))
      |> Enum.flat_map(&Registry.kinds/1)
      |> MapSet.new()

    findings
    |> DSLGuard.filter(project, config, plugin_kinds)
    |> Suppressions.filter(project, config)
  end

  def analyze(project), do: run(project)

  defp pattern_check?(check) do
    Code.ensure_loaded?(check) and function_exported?(check, :__reach_pattern_check__, 0)
  end

  defp run_check(check, project, config) do
    if function_exported?(check, :run, 2),
      do: check.run(project, config),
      else: check.run(project)
  end
end
