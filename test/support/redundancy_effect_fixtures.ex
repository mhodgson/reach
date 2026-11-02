defmodule Reach.Test.RedundancyEffects.Repo do
  @spec get_by(atom(), keyword()) :: map() | nil
  def get_by(_schema, party_id: id) do
    case :ets.lookup(:redundancy_requests, id) do
      [{^id, request}] -> request
      [] -> nil
    end
  end

  @spec update!(map()) :: map()
  def update!(request) do
    updated = Map.put(request, :status, :decided)
    :ets.insert(:redundancy_requests, {request.id, updated})
    updated
  end
end

defmodule Reach.Test.RedundancyEffects.Requests do
  @spec for_party(integer()) :: map() | nil
  def for_party(id),
    do:
      Reach.Test.RedundancyEffects.Repo.get_by(Reach.Test.RedundancyEffects.Request, party_id: id)

  def settle(id) do
    before = for_party(id)
    Reach.Test.RedundancyEffects.Repo.update!(before)
    after_write = for_party(id)
    {before, after_write}
  end
end

defmodule Reach.Test.RedundancyEffects.Judge do
  @spec model(keyword()) :: String.t()
  def model(opts), do: Keyword.get(opts, :model) || configured_model()
  defp configured_model, do: Application.get_env(:reach, :judge_model, "default")

  def record(opts) do
    first = model(opts)
    second = model(opts)
    {first, second}
  end
end

defmodule Reach.Test.RedundancyEffects.Live do
  @spec cancelled?(map()) :: boolean()
  def cancelled?(latest) do
    String.downcase(to_string(latest["status"])) in ["cancelled"] or
      latest["intent"] == "cancellation"
  end
end

defmodule Reach.Test.RedundancyEffects.Desk do
  alias Reach.Test.RedundancyEffects.Live

  @spec source_cancelled?(map() | nil) :: boolean()
  def source_cancelled?(%{} = source), do: Live.cancelled?(source["latest"])
  def source_cancelled?(nil), do: false

  def describe(source, awaiting?) do
    cancel_requested? = awaiting? and source_cancelled?(source)
    answerable? = awaiting? and not source_cancelled?(source)
    {cancel_requested?, answerable?}
  end
end
