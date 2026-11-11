defmodule Backplane.SecretHub.SyncWorker do
  @moduledoc """
  Styx worker for SecretHub publication.

  A job with `credential_name` syncs one credential; transient failures (Agent
  or SecretHub unavailable) are retried by Styx, other failures are recorded
  and left to the next reconciliation. A job without args (the periodic cron
  run) reconciles everything. Both are no-ops while sync is disabled.
  """

  use Styx.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [period: 30, keys: [:credential_name]]

  require Logger

  alias Backplane.SecretHub.Sync

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"credential_name" => name}}) when is_binary(name) do
    if Sync.enabled?() do
      case Sync.sync_credential(name) do
        :ok ->
          :ok

        {:error, reason} ->
          if Sync.transient?(reason), do: {:error, reason}, else: {:cancel, reason}
      end
    else
      :ok
    end
  end

  def perform(%Styx.Job{}) do
    if Sync.enabled?() do
      case Sync.reconcile() do
        {:ok, %{failed: 0}} ->
          :ok

        {:ok, %{failed: failed}} ->
          Logger.warning("SecretHub reconciliation left #{failed} credential(s) unsynced")
          :ok

        {:error, :agent_unavailable} ->
          Logger.warning("SecretHub reconciliation deferred: Agent unavailable")
          :ok
      end
    else
      :ok
    end
  end

  @doc "Enqueues a sync for one credential, or a full reconciliation."
  def enqueue(args \\ %{}) do
    args |> new() |> Styx.insert()
  end
end
