Code.require_file("reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.MultiAgentRecoveryHostFixture do
  @moduledoc false
  alias Backplane.AgentRuntime.{EphemeralStore, ReconciliationHostFixture, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  defdelegate mode(), to: ReconciliationHostFixture
  defdelegate load_receipt(context, id), to: ReconciliationHostFixture
  defdelegate runtime_store(context, ref), to: ReconciliationHostFixture
  defdelegate compare_and_swap_receipt(context, id, revision, next), to: ReconciliationHostFixture
  defdelegate put(context, key, value), to: ReconciliationHostFixture
  defdelegate get(context, key), to: ReconciliationHostFixture

  def new(test, options \\ []) do
    {:ok, sessions} = DynamicSupervisor.start_link(strategy: :one_for_one)

    ReconciliationHostFixture.new()
    |> Map.merge(%{
      test: test,
      sessions: sessions,
      managed: Keyword.get(options, :managed, false)
    })
  end

  def config(context), do: {__MODULE__, context}

  def load_evidence(context, ref) do
    send(context.test, {:recovery_read, ref, self()})

    case get(context, :read_barrier) do
      {:ok, {^ref, destination}} ->
        send(destination, {:recovery_barrier, self()})

        receive do
          :continue -> :ok
        end

      _ ->
        :ok
    end

    get(context, {:evidence, ref})
  end

  def child_options(context, label, request, run_id, parent) do
    send(context.test, {:prepared, label, request, run_id, parent})
    identity = parent.child.recovery_identity
    ref = "admission:" <> parent.child.attempt_id
    config_ref = "config:" <> parent.child.attempt_id
    ceiling_ref = "ceiling:" <> parent.child.attempt_id
    inventory_ref = "inventory:" <> parent.child.attempt_id
    configuration = %{"provider_ref" => "fixture-provider", "profile" => "fixture"}
    ceiling = %{"grants" => [], "tool_revisions" => %{}, "tool_bindings" => %{}}

    artifact_refs =
      case get(context, :artifact_refs) do
        {:ok, refs} -> refs
        _ -> []
      end

    {:ok, child_request} = Evidence.public(request)

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => identity,
      "store_ref" => "source-store",
      "config_ref" => config_ref,
      "authority_ceiling_ref" => ceiling_ref,
      "tool_profile" => Atom.to_string(request.profile),
      "admission_receipt_ref" => ref,
      "child_request" => child_request,
      "configuration" => configuration,
      "authority_ceiling" => ceiling,
      "artifact_refs" => artifact_refs,
      "inventory_ref" => inventory_ref
    }

    put(context, {:evidence, ref}, admission)
    put(context, {:evidence, config_ref}, configuration)
    put(context, {:evidence, ceiling_ref}, ceiling)

    options = [
      run_id: run_id,
      store: EphemeralStore,
      context: context.store,
      provider: __MODULE__.Provider,
      provider_context: %{test: context.test, label: label},
      registry: %ToolRegistry{},
      tools: [],
      authority: %{caller: "host", run_id: run_id, grants: []},
      schema_admission: :strict,
      work: 10,
      run_timeout: :infinity,
      recovery_admission_ref: ref,
      recovery_store_ref: "source-store",
      recovery_config_ref: config_ref,
      recovery_authority_ref: ceiling_ref,
      recovery_tool_profile: request.profile
    ]

    {:ok, managed_options(context, label, parent, options)}
  end

  defp managed_options(%{managed: false}, _label, _parent, options), do: options

  defp managed_options(context, label, parent, options) do
    key = {:session, label, parent.child.name}

    session =
      case get(context, key) do
        {:ok, previous} ->
          if Session.status(previous).phase == :closed, do: new_session(context), else: previous

        _ ->
          new_session(context)
      end

    put(context, key, session)

    {:ok, binding} =
      Session.bind(session, options[:authority], incarnation: parent.child.incarnation)

    {:ok, _} =
      ResourceRegistry.register(binding.resource_registry, binding.owner_id, :component, :fixture,
        cleanup: fn ->
          send(context.test, {:cleaned, label, parent.child.attempt_id})

          case get(context, :cleanup_result) do
            {:ok, result} -> result
            _ -> :ok
          end
        end
      )

    send(context.test, {:bound, label, binding})
    Keyword.put(options, :session_binding, binding)
  end

  defp new_session(context) do
    {:ok, session} =
      DynamicSupervisor.start_child(
        context.sessions,
        {Session,
         owner_pid: context.test,
         cleanup_timeout: 1_000,
         recovery: config(context),
         recovery_scope_id: "scope"}
      )

    session
  end

  def seal_inventory(context, agent) do
    ref = "admission:" <> agent.attempt_id
    {:ok, admission} = get(context, {:evidence, ref})
    identity = admission["child_identity"]

    executor =
      Evidence.obligation(
        "executor",
        %{"run_id" => identity["run_id"], "incarnation" => identity["run_incarnation"]},
        "fixture-executor-ledger"
      )

    inventory = %{
      "schema_version" => 1,
      "record_type" => "child_inventory",
      "child_identity" => identity,
      "complete" => true,
      "producer_ref" => "fixture-authoritative-owner-ledger",
      "obligations" => [executor]
    }

    put(context, {:evidence, admission["inventory_ref"]}, inventory)
  end

  def bundle(manifest, observations \\ nil) do
    observations =
      observations || Enum.map(manifest["obligations"], &ReconciliationHostFixture.observe/1)

    ReconciliationHostFixture.bundle(manifest, observations)
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, context.label, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end
end
