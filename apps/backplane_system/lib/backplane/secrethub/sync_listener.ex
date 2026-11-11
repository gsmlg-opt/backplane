defmodule Backplane.SecretHub.SyncListener do
  @moduledoc """
  Turns credential and setting changes into SecretHub sync jobs.

  Only enqueues work: it never calls SecretHub itself, so credential storage
  and the processes broadcasting changes are unaffected by SecretHub. A failed
  enqueue is logged; the periodic reconciliation repairs anything missed.
  """

  use GenServer
  require Logger

  alias Backplane.PubSubBroadcaster
  alias Backplane.SecretHub.{Sync, SyncWorker}
  alias Backplane.Settings

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    PubSubBroadcaster.subscribe(PubSubBroadcaster.credentials_topic())
    Settings.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:credential_changed, name}, state) when is_binary(name) do
    if Sync.enabled?(), do: enqueue(%{credential_name: name})
    {:noreply, state}
  end

  def handle_info(:credentials_reloaded, state) do
    if Sync.enabled?(), do: enqueue(%{})
    {:noreply, state}
  end

  # Enabling sync or changing the socket starts a full reconciliation.
  def handle_info({:setting_changed, key, _value}, state) do
    if key in [Sync.enabled_key(), Sync.socket_key()] and Sync.enabled?(), do: enqueue(%{})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(args) do
    case SyncWorker.enqueue(args) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("SecretHub sync job not enqueued: #{inspect(error_reason(reason))}")
    end
  rescue
    error -> Logger.warning("SecretHub sync job not enqueued: #{inspect(error.__struct__)}")
  end

  # Changesets can carry job args; log only that the job was invalid.
  defp error_reason(%Ecto.Changeset{}), do: :invalid_job
  defp error_reason(reason), do: reason
end
