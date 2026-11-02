defmodule Reach.Evidence.NilParameterTest do
  use ExUnit.Case, async: true

  alias Reach.Evidence.NilParameter
  alias Reach.Project

  defmodule DataOperators do
    @behaviour Reach.Plugin

    @impl true
    def analyze(_nodes, _opts), do: []

    @impl true
    def lower_elixir_ast({name, meta, [left, right]}, _opts)
        when name in [:data_and, :data_or] do
      operator = if name == :data_and, do: :and, else: :or
      {:ok, {operator, Keyword.put(meta, :operator_semantics, :data), [left, right]}}
    end

    def lower_elixir_ast(_ast, _opts), do: :ignore
  end

  for function <- [:sql_and, :sql_or, :sql_not, :sql_pinned] do
    @sql_function function
    test "SQL #{@sql_function} does not suppress a runtime interpolation use" do
      assert_unsafe_sql_use(@sql_function)
    end
  end

  defp assert_unsafe_sql_use(function) do
    source = """
    defmodule SQLNilPaths do
      import Ecto.Query, only: [where: 3, from: 2]
      def caller do
        sql_and(nil)
        sql_or(nil)
        sql_not(nil)
        sql_pinned(nil)
      end
      def sql_and(token), do: where(Row, [row], false and ^(Map.get(token, :id) == 1))
      def sql_or(token), do: from(row in Row, where: true or ^(Map.get(token, :id) == 1))
      def sql_not(token), do: where(Row, [row], not (true or ^(Map.get(token, :id) == 1)))
      def sql_pinned(token), do: where(Row, [row], not is_nil(^token) and ^(Map.get(token, :id) == 1))
    end
    """

    project = project(source, plugins: [Reach.Plugins.Ecto])
    nodes = Map.values(project.nodes)
    assert Enum.count(nodes, &(&1.meta[:operator_semantics] == :data)) == 4
    assert Enum.any?(nodes, &(&1.type == :call and &1.meta[:module] == Elixir.Ecto.Query))
    fact = NilParameter.collect_project(project) |> Enum.find(&(&1.function == function))
    assert [%{safe?: false, target: {Map, :get, 2}}] = fact.uses
  end

  test "runtime conditional and short circuit guards inside SQL pins retain their own paths" do
    facts =
      collect(
        """
        defmodule PinnedNilPaths do
          import Ecto.Query, only: [where: 3]
          def caller do
            guarded(nil)
            excluded(nil)
            ordinary_and(nil)
            ordinary_or(nil)
          end
          def guarded(token) do
            where(Row, [row], false and ^(if is_map(token), do: Map.get(token, :id), else: nil))
          end
          def excluded(token) do
            where(Row, [row], true or ^(not is_nil(token) and Map.get(token, :id)))
          end
          def ordinary_and(token), do: not is_nil(token) and Map.get(token, :id)
          def ordinary_or(token), do: is_nil(token) or Map.get(token, :id)
        end
        """,
        plugins: [Reach.Plugins.Ecto]
      )

    guarded = Enum.find(facts, &(&1.function == :guarded))
    assert [%{safe?: true, dominating_guards: [_ | _]}] = guarded.uses

    for function <- [:excluded, :ordinary_and, :ordinary_or] do
      assert [%{safe?: true, dominating_guards: [_ | _]}] =
               Enum.find(facts, &(&1.function == function)).uses
    end
  end

  test "annotated conditions including negation cannot establish truth or nonnil guarantees" do
    facts =
      collect(
        """
        defmodule DataNilConditions do
          def caller do
            data_condition(nil)
            negated_condition(nil)
            runtime_condition(nil)
          end
          def data_condition(token) do
            if data_and(not is_nil(token), true), do: Map.get(token, :id)
          end
          def negated_condition(token) do
            if not data_or(is_nil(token), false), do: Map.get(token, :id)
          end
          def runtime_condition(token) do
            if not is_nil(token) and true, do: Map.get(token, :id)
          end
        end
        """,
        plugins: [DataOperators]
      )

    for function <- [:data_condition, :negated_condition] do
      fact = Enum.find(facts, &(&1.function == function))
      assert [%{safe?: false, dominating_guards: []}] = fact.uses
    end

    assert [%{safe?: true, dominating_guards: [_ | _]}] =
             Enum.find(facts, &(&1.function == :runtime_condition)).uses
  end

  test "annotated short circuit syntax cannot guard its right operand" do
    facts =
      collect(
        """
        defmodule DataNilGuards do
          def caller do
            data_and_use(nil)
            data_or_use(nil)
            guarded_runtime_child(nil)
          end
          def data_and_use(token), do: data_and(not is_nil(token), Map.get(token, :id))
          def data_or_use(token), do: data_or(is_nil(token), Map.get(token, :id))
          def guarded_runtime_child(token) do
            data_and(false, if(is_map(token), do: Map.get(token, :id), else: nil))
          end
        end
        """,
        plugins: [DataOperators]
      )

    for function <- [:data_and_use, :data_or_use] do
      fact = Enum.find(facts, &(&1.function == function))
      assert [%{safe?: false, dominating_guards: []}] = fact.uses
    end

    child = Enum.find(facts, &(&1.function == :guarded_runtime_child))
    assert [%{safe?: true, dominating_guards: [_ | _]}] = child.uses
  end

  test "records nil call sites and unguarded field uses" do
    facts =
      collect("""
      defmodule NilUse do
        def caller, do: read(nil)
        def read(token), do: token.name
      end
      """)

    assert [fact] = Enum.filter(facts, &(&1.function == :read))
    assert fact.parameter == :token
    assert fact.parameter_index == 0
    assert [%{kind: :nil_argument, line: 2}] = fact.nil_sources
    assert [%{safe?: false, line: 3, operation: operation}] = fact.uses
    assert operation =~ "token.name"
  end

  test "treats a final wildcard clause as a total nil fallback" do
    facts =
      collect("""
      defmodule WildcardFallback do
        def caller, do: consume(nil)
        def consume(%{next: next}), do: consume(next)
        def consume(_), do: :done
      end
      """)

    assert [%{uses: []}] = Enum.filter(facts, &(&1.function == :consume))
  end

  test "uses CFG dominance for positive and reversed nil guards" do
    facts =
      collect("""
      defmodule DominatedUse do
        def caller do
          guarded(nil, 429)
          reversed(nil)
        end

        def guarded(token, status) do
          if status == 429 and not is_nil(token), do: token.name
        end

        def reversed(token) do
          if is_nil(token), do: :missing, else: token.name
        end
      end
      """)

    for function <- [:guarded, :reversed] do
      fact = Enum.find(facts, &(&1.function == function))
      assert [%{safe?: true, dominating_guards: [_ | _]}] = fact.uses
    end
  end

  test "recognizes clause patterns and prior total nil clauses" do
    facts =
      collect("""
      defmodule ClauseGuards do
        def caller do
          explicit(nil)
          patterned(nil)
        end

        def explicit(nil), do: :missing
        def explicit(token), do: token.name

        def patterned(%{name: _} = token), do: token.name
      end
      """)

    explicit = Enum.find(facts, &(&1.function == :explicit))
    assert [%{safe?: true}] = explicit.uses

    patterned = Enum.find(facts, &(&1.function == :patterned))
    assert [%{safe?: true}] = patterned.uses
  end

  test "recognizes matching nil clauses, short-circuit guards, and shadowed callback parameters" do
    facts =
      collect("""
      defmodule ContextualGuards do
        def caller do
          sorted(nil, :path)
          short(nil)
          callback(nil)
        end

        def sorted(nil, :path), do: ""
        def sorted(nil, :line), do: 0
        def sorted(value, :path), do: Map.get(value, :path)
        def sorted(value, :line), do: Map.get(value, :line)

        def short(value), do: value && value.name

        def callback(value) do
          Enum.map([], fn value -> value.name end)
          value
        end
      end
      """)

    sorted = Enum.find(facts, &(&1.function == :sorted))
    short = Enum.find(facts, &(&1.function == :short))
    callback = Enum.find(facts, &(&1.function == :callback))

    assert sorted.uses != []
    assert Enum.all?(sorted.uses, & &1.safe?)
    assert [%{safe?: true}] = short.uses
    assert callback.uses == []
  end

  test "scopes literal nil calls to matching multi-parameter clauses" do
    facts =
      collect("""
      defmodule CallContext do
        def caller, do: route(:missing, nil)
        def route(:missing, nil), do: :missing
        def route(:loaded, value), do: value.name
      end
      """)

    fact = Enum.find(facts, &(&1.function == :route))
    assert fact.uses == []
  end

  test "keeps dynamic call arguments conservative across dispatch clauses" do
    facts =
      collect("""
      defmodule DynamicCallContext do
        def caller(kind), do: route(kind, nil)
        def route(:missing, nil), do: :missing
        def route(:loaded, value), do: value.name
      end
      """)

    fact = Enum.find(facts, &(&1.function == :route))
    assert [%{safe?: false, line: 4}] = fact.uses
  end

  test "filters nil sources that cannot reach a short-circuit use" do
    facts =
      collect("""
      defmodule SourceFeasibility do
        def safe_caller, do: safe(nil)
        def unsafe_caller, do: unsafe(nil, true)

        def safe(value, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def unsafe(value, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def default_safe(value \\\\ nil, check? \\\\ false) do
          check? && Map.get(value, :id)
        end

        def safe_branch_caller, do: safe_branch(nil, 200)
        def unsafe_branch_caller, do: unsafe_branch(nil, 429)

        def safe_branch(value, status) do
          if status == 429, do: Map.get(value, :id)
        end

        def unsafe_branch(value, status) do
          if status == 429, do: Map.get(value, :id)
        end
      end
      """)

    safe = Enum.find(facts, &(&1.function == :safe))
    unsafe = Enum.find(facts, &(&1.function == :unsafe))
    default_safe = Enum.find(facts, &(&1.function == :default_safe))
    safe_branch = Enum.find(facts, &(&1.function == :safe_branch))
    unsafe_branch = Enum.find(facts, &(&1.function == :unsafe_branch))

    assert default_safe.uses == []
    assert safe.uses == []
    assert safe_branch.uses == []
    assert [%{safe?: false}] = unsafe.uses
    assert [%{safe?: false}] = unsafe_branch.uses
  end

  test "keeps conditional compilation definitions isolated" do
    facts =
      collect("""
      defmodule IsolatedDefinitions do
        if System.get_env("FEATURE") do
          def enabled(nil), do: :missing
          def enabled(value), do: value.name
        else
          def enabled(_value), do: :disabled
        end
      end
      """)

    assert Enum.all?(facts, fn fact -> Enum.all?(fact.uses, & &1.safe?) end)
  end

  test "stops parameter provenance after rebinding while retaining uses in the right-hand side" do
    facts =
      collect("""
      defmodule ReboundParameter do
        def normalized(options \\\\ nil) do
          options = options || %{id: 1}
          options.id
        end

        def strict_rhs(options \\\\ nil) do
          options = Map.fetch!(options, :nested)
          options.id
        end
      end
      """)

    normalized = Enum.find(facts, &(&1.function == :normalized))
    strict_rhs = Enum.find(facts, &(&1.function == :strict_rhs))

    assert normalized.uses == []
    assert [%{safe?: false, target: {Map, :fetch!, 2}}] = strict_rhs.uses
  end

  test "recognizes cond guards, companion defaults, guarded nil clauses, and static modules" do
    facts =
      collect("""
      defmodule AdditionalNilGuards do
        def cond_guard(options \\\\ nil) do
          cond do
            is_map(options) -> options.id
            true -> nil
          end
        end

        def companion_default(metadata \\\\ nil, cursor \\\\ nil) do
          case cursor do
            :next -> metadata.id
            _other -> nil
          end
        end

        def guarded_caller, do: guarded_nil(nil)
        def guarded_nil(value) when is_nil(value), do: :missing
        def guarded_nil(value) when is_atom(value), do: value.render()

        def static_module(ets \\\\ nil), do: :ets.new(:nil_parameter_test, [])
      end
      """)

    for function <- [:cond_guard, :companion_default, :guarded_nil, :static_module] do
      fact = Enum.find(facts, &(&1.function == function))
      assert Enum.all?(fact.uses, & &1.safe?)
    end
  end

  test "tracks unless paths, with bindings, repeated dispatch, and default wrappers precisely" do
    facts =
      collect("""
      defmodule AdditionalNilFlow do
        def unless_guard(options \\\\ nil),
          do: unless(is_nil(options), do: Map.get(options, :id))

        def with_binding(options \\\\ nil) do
          with {:ok, options} <- normalize(options) do
            Map.get(options, :id)
          end
        end

        def normalize(options), do: {:ok, options || %{id: 1}}

        def transition(same, same), do: same
        def transition(nil, new), do: consume(new)
        def transition(_old, nil), do: nil
        def consume(%{id: id}), do: id

        def wrapper, do: request(:pool, [], Handler, nil)

        def request(pool, headers \\\\ [], body \\\\ "", module, init) do
          {pool, headers, body, module.handle(init)}
        end
      end
      """)

    for function <- [:unless_guard, :with_binding, :transition] do
      fact = Enum.find(facts, &(&1.function == function))
      assert is_nil(fact) or Enum.all?(fact.uses, & &1.safe?)
    end

    refute Enum.any?(facts, &(&1.function == :request and &1.parameter == :module))
  end

  test "treats calls into shape-restricted functions as strict uses" do
    facts =
      collect("""
      defmodule StrictCallee do
        def caller, do: forward(nil)
        def forward(token), do: consume(token)
        def consume(%{id: id}), do: id
      end
      """)

    fact = Enum.find(facts, &(&1.function == :forward))
    assert [%{safe?: false, target: {StrictCallee, :consume, 1}}] = fact.uses
  end

  test "propagates strict requirements through default-arity wrappers" do
    facts =
      collect("""
      defmodule DefaultArityCallee do
        def caller, do: forward(nil)
        def forward(token), do: consume(token)

        def consume(token, option \\\\ nil)
        def consume(%{id: id}, _option), do: id
      end
      """)

    fact = Enum.find(facts, &(&1.function == :forward))
    assert [%{safe?: false, target: {DefaultArityCallee, :consume, 2}}] = fact.uses
  end

  test "records nil defaults and strict Map uses" do
    facts =
      collect("""
      defmodule NilDefault do
        def read(options \\\\ nil), do: Map.get(options, :name)
      end
      """)

    fact = Enum.find(facts, &(&1.function == :read))
    assert [%{kind: :nil_default}] = fact.nil_sources
    assert [%{safe?: false, target: {Map, :get, 2}}] = fact.uses
  end

  test "supports functions without module metadata" do
    facts =
      collect(
        """
        defmodule ModulelessNilDefault do
          def read(options \\\\ nil), do: Map.get(options, :name)
        end
        """,
        without_module: :read
      )

    assert [%{module: nil, function: :read}] = facts
  end

  defp collect(source, opts \\ []) do
    source |> project(opts) |> NilParameter.collect_project()
  end

  defp project(source, opts) do
    path =
      Path.join(System.tmp_dir!(), "reach-nil-parameter-#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    project = Project.from_sources([path], Keyword.take(opts, [:plugins]))

    case opts[:without_module] do
      nil -> project
      name -> delete_function_module(project, name)
    end
  end

  defp delete_function_module(project, name) do
    {id, _function} =
      Enum.find(project.nodes, fn {_id, node} ->
        node.type == :function_def and node.meta[:name] == name
      end)

    nodes =
      Map.update!(project.nodes, id, fn function ->
        %{function | meta: Map.delete(function.meta, :module)}
      end)

    %{project | nodes: nodes}
  end
end
