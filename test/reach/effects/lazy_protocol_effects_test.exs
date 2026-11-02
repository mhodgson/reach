defmodule Reach.Effects.LazyProtocolTest do
  use ExUnit.Case, async: false
  alias Reach.{Effects, IR}
  alias Reach.Smell.Checks.RedundantComputation
  alias Reach.Test.ProtocolFormattingValue

  setup do
    Effects.ensure_cache()
    :ets.delete_all_objects(:reach_classify_cache)
    :ok
  end

  test "get_lazy preserves conditional callback effects and pure precision" do
    project =
      project_source("""
      defmodule LazyDefaults do
        def read(opts), do: Keyword.get_lazy(opts, :mode, &default_mode/0)
        def write(opts), do: Keyword.get_lazy(opts, :mode, fn -> File.write!("unused", "data") end)
        def dynamic(opts, callback), do: Keyword.get_lazy(opts, :mode, callback)
        def pure(opts), do: Keyword.get_lazy(opts, :mode, fn -> :use end)
        defp default_mode, do: Application.get_env(:reach, :mode, :use)
        def repeated(opts) do
          read(opts)
          read(opts)
          pure(opts)
          pure(opts)
        end
      end
      """)

    findings = RedundantComputation.run(project)
    IO.inspect(Enum.map(findings, & &1.message), label: "lazy default smell facts")
    assert Enum.any?(findings, &String.starts_with?(&1.message, "pure called twice"))
    refute Enum.any?(findings, &String.starts_with?(&1.message, "read called twice"))
    assert effect(project, LazyDefaults, :read, 1) == :read
    assert effect(project, LazyDefaults, :write, 1) == :write
    assert effect(project, LazyDefaults, :dynamic, 2) == :unknown
    assert effect(project, LazyDefaults, :pure, 1) == :pure
  end

  test "get_lazy only invokes the fallback when absent" do
    path = temp_path()

    callback = fn ->
      File.write!(path, "called")
      :fallback
    end

    assert Keyword.get_lazy([key: :present], :key, callback) == :present
    refute File.exists?(path)
    assert Keyword.get_lazy([], :key, callback) == :fallback
    assert File.read!(path) == "called"

    for source <- [
          "Keyword.get_lazy(opts, :key, callback)",
          "Keyword.get_lazy(opts, :key, fn -> Unknown.run() end)"
        ] do
      assert Effects.classify(call(source), []) == :unknown
    end

    assert Effects.classify(call("Keyword.get_lazy(opts, :key, fn -> :ok end)"), []) == :pure

    assert Effects.classify(
             call("Keyword.get_lazy(opts, :key, fn -> Application.get_env(:reach, :mode) end)"),
             []
           ) == :read
  end

  test "compiled callbacks and returned closures retain their execution distinction" do
    assert Effects.classify(
             call("Keyword.get_lazy(opts, :key, &Reach.Test.CompiledLazyDefault.read/0)"),
             []
           ) == :read

    assert Effects.classify(
             call(
               "Keyword.get_lazy(opts, :key, fn -> fn -> File.write!(\"unused\", \"data\") end end)"
             ),
             []
           ) == :pure

    assert Effects.classify(
             call(
               "Keyword.get_lazy(opts, :key, fn _arg -> File.write!(\"unused\", \"data\") end)"
             ),
             []
           ) == :unknown
  end

  test "other get_lazy names do not execute their callback arguments" do
    project =
      project_source("""
      defmodule OtherDefaults do
        def get_lazy(_opts, _key, _callback), do: :ok
        def run(opts), do: get_lazy(opts, :key, fn -> File.write!("unused", "data") end)
      end
      """)

    assert effect(project, OtherDefaults, :run, 1) == :pure
  end

  test "arbitrary formatting protocols really write and can raise" do
    path = temp_path()
    value = %ProtocolFormattingValue{path: path}
    assert Kernel.to_string(value) == "status"
    assert File.read!(path) == "called"

    assert_raise ArgumentError, "protocol conversion failed", fn ->
      Kernel.to_string(%{value | raise?: true})
    end

    assert File.read!(path) == "calledcalled"

    for source <- ["Kernel.to_string(value)", "String.Chars.to_string(value)"] do
      assert Effects.classify(call(source), []) == :unknown
    end

    for source <- [
          "Kernel.to_string(123)",
          "Kernel.to_string(:ok)",
          "String.Chars.to_string(1.5)",
          "Kernel.to_string(\"fixed\")"
        ] do
      assert Effects.classify(call(source), []) == :pure
    end
  end

  test "actual interpolation IR cannot make arbitrary formatting redundant" do
    source = ~S'''
    defmodule ProtocolCodes do
      require Logger
      def code({:http_status, status}), do: "http_#{status}"
      def code(reason) when is_atom(reason), do: Atom.to_string(reason)
      def code(_reason), do: "error"
      def number, do: "http_#{123}"
      def repeated(reason) do
        Logger.warning("formatting failed", code: code(reason))
        %{code: code(reason)}
      end
    end
    '''

    project = project_source(source)

    conversions =
      Map.values(project.nodes)
      |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :to_string))

    IO.inspect(
      Enum.map(
        conversions,
        &{&1.meta, Enum.map(&1.children, fn c -> c.type end),
         Effects.classify(&1, project.plugins)}
      ),
      label: "actual formatting IR",
      limit: :infinity
    )

    findings = RedundantComputation.run(project)
    IO.inspect(Enum.map(findings, & &1.message), label: "formatting smell facts")
    refute Enum.any?(findings, &String.starts_with?(&1.message, "code called twice"))
    assert effect(project, ProtocolCodes, :code, 1) == :unknown
    assert effect(project, ProtocolCodes, :number, 0) == :pure

    refute Enum.any?(
             RedundantComputation.run(project),
             &String.starts_with?(&1.message, "code called twice")
           )
  end

  test "primitive formatting precision stays safe" do
    for source <- [
          "Kernel.to_string(123)",
          "Kernel.to_string(:ok)",
          "String.Chars.to_string(1.5)",
          "Kernel.to_string(\"fixed\")"
        ] do
      assert Effects.classify(call(source), []) == :pure
    end
  end

  test "local to_string implementation retains source write effects" do
    project =
      project_source("""
      defmodule LocalFormatting do
        import Kernel, except: [to_string: 1]
        def to_string(value) do
          File.write!(value.path, "called")
          "value"
        end
        def run(value), do: to_string(value)
      end
      """)

    assert effect(project, LocalFormatting, :run, 1) == :write
  end

  defmodule Override do
    @behaviour Reach.Plugin
    def analyze(_, _), do: []
    def classify_effect(%{meta: %{module: Kernel, function: :to_string}}), do: :write
    def classify_effect(%{meta: %{module: Keyword, function: :get_lazy, arity: 3}}), do: :write
    def classify_effect(_), do: nil
  end

  test "plugins retain precedence over builtin callback and formatting rules" do
    assert Effects.classify(call("Kernel.to_string(123)"), [Override]) == :write

    assert Effects.classify(call("Keyword.get_lazy(opts, :key, fn -> :ok end)"), [Override]) ==
             :write
  end

  defp project_source(source) do
    path = temp_path() <> ".ex"
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    Reach.Project.from_sources([path])
  end

  defp effect(project, module, name, arity) do
    args = Enum.map_join(List.duplicate("nil", arity), ",", & &1)
    Effects.classify(call("#{inspect(module)}.#{name}(#{args})"), project.plugins)
  end

  defp call(source), do: IR.from_string!(source, plugins: []) |> hd()

  defp temp_path do
    path =
      Path.join(System.tmp_dir!(), "reach-lazy-protocol-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    path
  end
end
