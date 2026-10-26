Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ReconciliationOwnerTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Error,
    Codex.Reconciliation,
    Codex.ResourceRegistry,
    Codex.Session
  }

  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  test "a fenced Registry consumes exact observations without repeating cleanup" do
    host = Host.new()

    registry =
      start_supervised!(
        {ResourceRegistry, recovery: Host.config(host), recovery_scope_id: "scope"}
      )

    test = self()

    {:ok, handle} =
      ResourceRegistry.register(registry, "owner", :component, :opaque,
        cleanup: fn ->
          send(test, :cleaned)
          {:uncertain, :lost_ack}
        end
      )

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release(registry, handle, "owner")

    assert_receive :cleaned

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.recovery_manifest(registry, "owner")

    :ok = ResourceRegistry.fence_owner(registry, "owner")
    assert {:ok, manifest} = ResourceRegistry.recovery_manifest(registry, "owner")
    confirm(host, manifest, "registry")

    assert {:ok, acknowledgement} =
             ResourceRegistry.reconcile_owner(registry, "owner", "registry")

    assert {:ok, ^acknowledgement} =
             ResourceRegistry.reconcile_owner(registry, "owner", "registry")

    assert {:ok, []} = ResourceRegistry.owner_status(registry, "owner")

    assert {:ok, %{status: :confirmed, initial_reason: :lost_ack}} =
             ResourceRegistry.cleanup_status(registry, handle, "owner")

    refute_receive :cleaned

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.register(registry, "owner", :component, :new)
  end

  test "physical shutdown cannot erase a failed receipt acknowledgement" do
    host = Host.new()

    registry =
      start_supervised!(
        {ResourceRegistry, recovery: Host.config(host), recovery_scope_id: "scope"}
      )

    test = self()

    {:ok, id} =
      ResourceRegistry.register_session(registry, "owner", :opaque,
        cleanup: fn ->
          send(test, :physical_cleanup)
          :ok
        end,
        acknowledge: fn _ ->
          send(test, :acknowledged)
          {:error, Error.new(:execution_failure, "lost receipt")}
        end
      )

    assert {:ok, :ok} = ResourceRegistry.release_session(registry, id, "owner", 1)
    assert_receive :physical_cleanup
    assert_receive :acknowledged
    await_ack(registry, id)
    :ok = ResourceRegistry.fence_owner(registry, "owner")
    {:ok, manifest} = ResourceRegistry.recovery_manifest(registry, "owner")
    assert Enum.any?(manifest["obligations"], &(&1["kind"] == "acknowledgement"))

    observations =
      for o <- manifest["obligations"], o["kind"] != "acknowledgement", do: Host.observe(o)

    bundle = Host.bundle(manifest, observations)
    Host.put(host, {:evidence, "physical"}, bundle)

    assert {:error, %Error{class: :unknown_outcome}} =
             Reconciliation.reconcile(
               Host.config(host),
               Host.request(manifest, "physical", "physical")
             )

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.reconcile_owner(registry, "owner", "physical")

    confirm(host, manifest, "registry")
    assert {:ok, _} = ResourceRegistry.reconcile_owner(registry, "owner", "registry")

    assert {:ok, %{status: :confirmed, initial_acknowledgement: {:error, %Error{}}}} =
             ResourceRegistry.session_cleanup_status(registry, id, "owner", 1)

    refute_receive :physical_cleanup
    refute_receive :acknowledged
  end

  test "explicit Session reconciliation preserves initial failure and permanent closure" do
    host = Host.new()
    {:ok, _} = Host.seed_run(host, "session-run")

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "scope"}
      )

    {:ok, binding} = Session.bind(session, %{run_id: "session-run"})
    test = self()

    {:ok, _} =
      ResourceRegistry.register(binding.resource_registry, binding.owner_id, :component, :opaque,
        cleanup: fn ->
          send(test, :session_cleanup)
          {:uncertain, :lost_ack}
        end
      )

    assert {:error, %Error{class: :unknown_outcome}} = first = Session.close(session)
    assert_receive :session_cleanup
    assert {:ok, manifest} = Session.recovery_manifest(session)
    confirm(host, manifest, "session")
    assert {:error, %Error{class: :unknown_outcome}} = Session.reconcile_close(session, "session")

    {:ok, registry_manifest} =
      ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id)

    confirm(host, registry_manifest, "registry")

    assert {:ok, _} =
             ResourceRegistry.reconcile_owner(
               binding.resource_registry,
               binding.owner_id,
               "registry"
             )

    assert {:ok, %{status: :confirmed} = ack} = Session.reconcile_close(session, "session")

    assert Session.status(session) == %{
             owner_id: binding.owner_id,
             incarnation: binding.incarnation,
             phase: :closed,
             cleanup: {:ok, ack},
             initial_cleanup: first,
             cleanup_revision: 1,
             reconciliation: "session"
           }

    assert {:ok, ^ack} = Session.reconcile_close(session, "session")
    assert {:ok, ^ack} = Session.close(session)
    assert {:error, %Error{class: :resource_conflict}} = Session.bind(session, %{run_id: "fresh"})
    assert {:error, %Error{}} = Session.validate(binding, %{})
    refute_receive :session_cleanup
  end

  test "recovery operations are opt-in and exact owner subjects cannot cross" do
    registry = start_supervised!(ResourceRegistry)
    :ok = ResourceRegistry.fence_owner(registry, "owner")

    assert {:error, %Error{class: :unsupported_capability}} =
             ResourceRegistry.recovery_manifest(registry, "owner")

    host = Host.new()

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "scope"}
      )

    assert {:error, %Error{class: :resource_conflict}} = Session.recovery_manifest(session)
    {:ok, _} = Session.close(session)
    {:ok, manifest} = Session.recovery_manifest(session)

    other =
      put_in(manifest, ["subject", "owner_id"], "other")
      |> Backplane.AgentRuntime.Codex.Reconciliation.Evidence.seal("manifest_digest")

    confirm(host, other, "other")
    assert {:error, %Error{class: :resource_conflict}} = Session.reconcile_close(session, "other")
  end

  test "Session projects a newer confirmed receipt revision while exact retry is a no-op" do
    host = Host.new()

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "scope"}
      )

    assert {:ok, _} = Session.close(session)
    {:ok, manifest} = Session.recovery_manifest(session)
    assert {:ok, first} = confirm(host, manifest, "progress")
    assert {:ok, %{receipt_revision: 1}} = Session.reconcile_close(session, "progress")

    Host.put(
      host,
      {:evidence, "progress-v2"},
      Host.bundle(
        manifest,
        Enum.map(manifest["obligations"], &Host.observe/1)
      )
    )

    request =
      Host.request(manifest, "progress", "progress-v2")
      |> Map.put("expected_revision", first["revision"])

    assert {:ok, %{"revision" => 2}} = Reconciliation.reconcile(Host.config(host), request)
    assert {:ok, %{receipt_revision: 2} = latest} = Session.reconcile_close(session, "progress")
    assert Session.status(session).cleanup_revision == 2
    assert {:ok, ^latest} = Session.reconcile_close(session, "progress")
    assert Session.status(session).cleanup_revision == 2
  end

  defp confirm(host, manifest, reference) do
    Host.put(
      host,
      {:evidence, reference},
      Host.bundle(manifest, Enum.map(manifest["obligations"], &Host.observe/1))
    )

    assert {:ok, _} =
             Reconciliation.reconcile(
               Host.config(host),
               Host.request(manifest, reference, reference)
             )
  end

  defp await_ack(registry, id, remaining \\ 100) do
    case ResourceRegistry.session_cleanup_status(registry, id, "owner", 1) do
      {:ok, %{acknowledgement: {:error, _}}} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(1)
        await_ack(registry, id, remaining - 1)

      _ ->
        flunk("acknowledgement was not settled")
    end
  end
end
