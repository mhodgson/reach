defmodule Reach.Smell.Source do
  @moduledoc false

  alias Reach.Project.TermStore

  @elixir_extensions ~w(.ex .exs)

  def module_files(project) do
    project.nodes
    |> Enum.flat_map(fn
      {_id, %{type: :module_def, source_span: source_span}} -> [source_span && source_span[:file]]
      _entry -> []
    end)
    |> Enum.filter(&elixir_file?/1)
    |> Enum.uniq()
  end

  def elixir_file?(file) when is_binary(file), do: Path.extname(file) in @elixir_extensions
  def elixir_file?(_file), do: false

  def cached_ast(file) do
    key = {:reach_smell_ast, file}

    case Process.get(key) || TermStore.lookup({__MODULE__, :ast, file}) do
      nil ->
        ast =
          file
          |> File.read!()
          |> Sourceror.parse_string!()

        Process.put(key, ast)
        ast

      ast ->
        ast
    end
  end

  def cached_zipper(file) do
    key = {:reach_smell_zipper, file}

    case Process.get(key) do
      nil ->
        zipper =
          file
          |> cached_ast()
          |> Sourceror.Zipper.zip()

        Process.put(key, zipper)
        zipper

      zipper ->
        zipper
    end
  end

  @doc """
  Parses every module file once, side by side, into `Reach.Project.TermStore`
  so checks in other processes read the same ASTs. Returns `:ok` when every
  readable file was stored.
  """
  def share_asts(project, opts) do
    project
    |> module_files()
    |> Enum.filter(&File.regular?/1)
    |> Task.async_stream(&share_ast(&1, opts), ordered: false, timeout: :infinity)
    |> Enum.all?(&match?({:ok, true}, &1))
    |> if(do: :ok, else: :partial)
  end

  defp share_ast(file, opts) do
    ast = file |> File.read!() |> Sourceror.parse_string!()
    :erlang.garbage_collect()
    {:memory, bytes} = Process.info(self(), :memory)
    match?({:stored, _key}, TermStore.put(ast, {__MODULE__, :ast, file}, bytes, opts))
  rescue
    # Unparseable files stay unshared; each check handles them as before.
    _error in [File.Error, MatchError, SyntaxError, TokenMissingError] -> true
  end
end
