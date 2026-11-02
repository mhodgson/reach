defmodule Reach.Test.QueueSourceInference.Workers do
  def enqueue(run, opts \\ []) do
    with {:ok, job} <- run.worker.new(Keyword.put(opts, :id, run.id)) do
      File.write!(run.path, inspect(job))
      {:ok, job}
    end
  end
end

defmodule Reach.Test.QueueSourceInference.Store do
  alias Reach.Test.QueueSourceInference.Workers

  @spec queue(map(), boolean()) :: map()
  def queue(run, true), do: %{id: run.id, outcome: :dry_run}

  def queue(run, false) do
    case Workers.enqueue(run) do
      {:ok, _job} -> %{id: run.id, outcome: :queued}
      other -> %{id: run.id, outcome: :failed, reason: inspect(other)}
    end
  end
end

defmodule Reach.Test.QueueSourceInference.Command do
  alias Reach.Test.QueueSourceInference.Store
  def run(runs, currents, dry_run), do: Enum.map(runs, &queue(&1.id, currents[&1.id], dry_run))
  defp queue(id, nil, _dry_run), do: %{id: id, outcome: :missing}
  defp queue(_id, run, dry_run), do: Store.queue(run, dry_run)
end

defmodule Reach.Test.QueueSourceInference.Consumer do
  alias Reach.Test.QueueSourceInference.Command
  def run(runs, currents, dry_run), do: Command.run(runs, currents, dry_run)
end

defmodule Reach.Test.QueueSourceInference.PureStore do
  @spec queue(map(), boolean()) :: map()
  def queue(run, true), do: Map.put(run, :outcome, :dry_run)
  def queue(run, false), do: Map.put(run, :outcome, :ready)
end

defmodule Reach.Test.QueueSourceInference.KnownWriter do
  @spec persist(map(), keyword()) :: map()
  def persist(run, opts \\ []) do
    File.write!(run.path, inspect(opts))
    run
  end
end
