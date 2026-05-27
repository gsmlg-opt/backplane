defmodule Backplane.Settings.Credentials.Vault do
  @moduledoc """
  In-memory credential cache backed by ETS.

  On startup, loads all `Credential` records from the database into an ETS
  table keyed by credential name.  Subscribes to `"credentials:changed"` PubSub
  topic so any mutation performed by `Backplane.Settings.Credentials` is
  immediately reflected in the cache.

  ## Reading credentials

  Other modules should call the public API on this module (`get/1`, `list/0`,
  `exists?/1`) instead of querying the database directly.  These functions read
  from ETS and do not serialise through the GenServer mailbox, so they are safe
  to call from any process with no bottleneck.

  ## Reload triggers

  - `{:credential_changed, name}` — reload a single credential from DB
  - `:credentials_reloaded` — full reload of all credentials
  """

  use GenServer

  require Logger

  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @table :credentials_vault
  @pubsub_topic "credentials:changed"

  # ── Client API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a credential struct by name. Returns `%Credential{}` or `nil`."
  @spec get(String.t()) :: Credential.t() | nil
  def get(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, cred}] -> cred
      [] -> nil
    end
  catch
    :error, :badarg -> nil
  end

  @doc """
  List all cached credentials.

  Returns a list of maps with selected fields (id, name, kind, metadata,
  inserted_at, updated_at). Encrypted values are never exposed.
  """
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, cred} ->
      %{
        id: cred.id,
        name: cred.name,
        kind: cred.kind,
        metadata: cred.metadata,
        inserted_at: cred.inserted_at,
        updated_at: cred.updated_at
      }
    end)
    |> Enum.sort_by(& &1.name)
  catch
    :error, :badarg -> []
  end

  @doc "Check whether a credential exists in the cache."
  @spec exists?(String.t()) :: boolean()
  def exists?(name) when is_binary(name) do
    :ets.member(@table, name)
  catch
    :error, :badarg -> false
  end

  @doc "Force a synchronous full reload of all credentials from the database."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload_all)
  catch
    :exit, _ -> :ok
  end

  @doc "Force reload a single credential from the database."
  @spec reload(String.t()) :: :ok
  def reload(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:reload_one, name})
  end

  @doc """
  Directly insert or update a credential in the ETS cache.

  Called synchronously by `Credentials` after a successful DB write so the
  cache is immediately consistent without waiting for a PubSub round-trip.
  """
  @spec put(Credential.t()) :: :ok
  def put(%Credential{} = cred) do
    :ets.insert(@table, {cred.name, cred})
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Directly remove a credential from the ETS cache by name.

  Called synchronously by `Credentials` after a successful DB delete.
  """
  @spec remove(String.t()) :: :ok
  def remove(name) when is_binary(name) do
    :ets.delete(@table, name)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc "The PubSub topic for credential change notifications."
  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  # ── Server callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(Backplane.PubSub, @pubsub_topic)
    load_all()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:load_all, state) do
    load_all()
    {:noreply, state}
  end

  def handle_info({:credential_changed, name}, state) when is_binary(name) do
    reload_one(name)
    {:noreply, state}
  end

  def handle_info(:credentials_reloaded, state) do
    load_all()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:reload_all, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:reload_all, state) do
    load_all()
    {:noreply, state}
  end

  def handle_cast({:reload_one, name}, state) do
    reload_one(name)
    {:noreply, state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp load_all do
    credentials = Repo.all(Credential)

    # Clear and repopulate
    :ets.delete_all_objects(@table)

    for cred <- credentials do
      :ets.insert(@table, {cred.name, cred})
    end

    Logger.debug("Credentials.Vault: loaded #{length(credentials)} credentials into ETS")
  catch
    kind, reason ->
      Logger.warning("Credentials.Vault: load_all failed: #{inspect(kind)} #{inspect(reason)}")
  end

  defp reload_one(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        :ets.delete(@table, name)
        Logger.debug("Credentials.Vault: removed credential '#{name}' from cache")

      cred ->
        :ets.insert(@table, {cred.name, cred})
        Logger.debug("Credentials.Vault: reloaded credential '#{name}' into cache")
    end
  catch
    kind, reason ->
      Logger.warning(
        "Credentials.Vault: reload_one(#{name}) failed: #{inspect(kind)} #{inspect(reason)}"
      )
  end
end
