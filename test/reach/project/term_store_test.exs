defmodule Reach.Project.TermStoreTest do
  use ExUnit.Case, async: true

  alias Reach.Project.TermStore

  test "keeps the term on the heap unless the store is enabled" do
    term = %{graph: [1, 2, 3]}

    assert TermStore.put(term, {__MODULE__, :off}, 0, []) == {:kept, term}
    assert TermStore.keep(term, {__MODULE__, :off}, 0, []) == term
    refute TermStore.store?([])
    assert TermStore.store?(term_store: :persistent_term)
  end

  test "keeps the term on the heap when the literal reserve cannot hold it" do
    term = %{graph: [1, 2, 3]}
    too_big = TermStore.literal_free_bytes() + 1

    assert TermStore.put(term, {__MODULE__, :big}, too_big, term_store: :persistent_term) ==
             {:kept, term}
  end

  test "reports the free literal reserve" do
    assert is_integer(TermStore.literal_free_bytes())
    assert TermStore.literal_free_bytes() >= 0
  end

  test "resolves both kinds of handle" do
    key = {TermStore, {__MODULE__, :resolve}}
    :persistent_term.put(key, :stored_value)

    assert TermStore.resolve({:stored, key}) == :stored_value
    assert TermStore.resolve({:kept, :heap_value}) == :heap_value
  after
    :persistent_term.erase({TermStore, {__MODULE__, :resolve}})
  end
end
