defmodule Reach.Project.TermStore do
  @moduledoc """
  Keeps large, read-only analysis terms out of process heaps for one-shot runs.

  A project's dependence graphs are built once and then only read. Held on a
  process heap, every full garbage collection copies them, so a run's peak
  memory is several times the size of the data it keeps. A term stored in
  `:persistent_term` lives in the VM's literal area instead: reading it copies
  nothing and no collection ever copies it.

  Stored terms stay until the VM exits, so only short-lived commands such as
  the `mix reach.*` tasks turn this on (`term_store: :persistent_term`).

  The literal area is a fixed reserve set by the `+MIscs` emulator flag
  (1 GB by default). Running out of it crashes the VM, so a term is stored only
  while enough of the reserve is free; otherwise it stays on the heap and the
  run continues with higher memory use. Raising the reserve (for example
  `ERL_FLAGS="+MIscs 16384"`) costs address space, not memory.
  """

  @headroom_bytes 1_073_741_824

  @doc """
  Returns `term`, moved into the literal area when `opts` enable the store and
  `size_bytes` fits in the free reserve with headroom to spare.
  """
  @spec keep(term(), term(), non_neg_integer(), keyword()) :: term()
  def keep(term, key, size_bytes, opts), do: term |> put(key, size_bytes, opts) |> resolve()

  @doc """
  Stores `term` like `keep/4` but returns a small handle instead of the term,
  for a worker to send back without its reply carrying the term itself.
  """
  @spec put(term(), term(), non_neg_integer(), keyword()) :: {:stored, term()} | {:kept, term()}
  def put(term, key, size_bytes, opts) do
    if store?(opts) and fits?(size_bytes) do
      full_key = {__MODULE__, key}
      :persistent_term.put(full_key, term)
      {:stored, full_key}
    else
      {:kept, term}
    end
  end

  @doc "The term behind a handle from `put/4`."
  @spec resolve({:stored, term()} | {:kept, term()}) :: term()
  def resolve({:stored, full_key}), do: :persistent_term.get(full_key)
  def resolve({:kept, term}), do: term

  @doc "Whether `opts` ask for terms to be kept in the literal area."
  @spec store?(keyword()) :: boolean()
  def store?(opts), do: Keyword.get(opts, :term_store) == :persistent_term

  @doc "Bytes of the literal area reserve not yet in use, or 0 when unknown."
  @spec literal_free_bytes() :: non_neg_integer()
  def literal_free_bytes do
    with {:literal_mmap, info} <-
           List.keyfind(:erlang.system_info({:allocator, :erts_mmap}), :literal_mmap, 0),
         sizes when is_list(sizes) <- get_in(info, [:supercarrier, :sizes]),
         total when is_integer(total) <- sizes[:total],
         used when is_integer(used) <- sizes[:used] do
      max(total - used, 0)
    else
      _ -> 0
    end
  end

  defp fits?(size_bytes), do: literal_free_bytes() >= size_bytes + @headroom_bytes
end
