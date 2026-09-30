defmodule Backplane.Clients do
  @moduledoc """
  Context module for managing MCP client identities and scoped tool access.

  Verification evidence and current authorization snapshots live in supervised
  ETS tables. Warm checks avoid database queries and client enumeration;
  mutations invalidate authority before writing and periodic refresh bounds
  cross-node freshness independently of reusable verification evidence.
  """

  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.Clients.{Activity, AuthCache}
  alias Backplane.Repo

  @verification_table :backplane_client_token_verifications
  @verification_slots 1_024
  @verification_ttl_ms 60_000

  # --- ETS Cache ---

  @doc "Initialize the clients ETS cache. Called during application startup."
  def init_cache do
    refresh_cache()
  end

  @doc "Refresh the ETS cache from the database."
  def refresh_cache do
    case :global.trans({{__MODULE__, :refresh, node()}, self()}, &do_refresh_cache/0, [node()]) do
      :aborted -> fail_closed()
      result -> result
    end
  end

  defp do_refresh_cache do
    case AuthCache.refresh() do
      :ok ->
        :persistent_term.put(:backplane_clients_exist, AuthCache.any_clients?())
        :ok

      _unavailable ->
        fail_closed()
    end
  end

  defp fail_closed do
    :persistent_term.put(:backplane_clients_exist, true)
    :ok
  end

  # --- Token Verification ---

  @doc """
  Verify a bounded bearer credential. Warm evidence is checked against current
  authorization; cold legacy bcrypt scans are bounded and coalesced per node.
  """
  @spec verify_token(String.t()) ::
          {:ok, Client.t()} | :error | {:error, :unavailable | :overloaded}
  def verify_token(token) when is_binary(token) do
    cond do
      not token_size_valid?(token) -> :error
      Application.get_env(:backplane, :env) == :test -> sandbox_verify_token(token)
      true -> AuthCache.verify(token)
    end
  end

  def verify_token(_), do: :error

  def token_size_valid?(token), do: AuthCache.token_size_valid?(token)

  defp sandbox_verify_token(token) do
    generation = verification_generation()
    clients = active_clients_for_verification()
    digest = :crypto.hash(:sha256, token)
    key = verification_key(digest, clients)

    case cached_verification(key, generation, clients) do
      {:ok, client} ->
        touch_last_seen(client)
        {:ok, client}

      :miss ->
        :error

      :uncached ->
        verify_and_cache(token, key, generation, clients)
    end
  end

  defp active_clients_for_verification do
    Client |> where(active: true) |> Repo.all()
  end

  defp verification_key(digest, clients) do
    if Application.get_env(:backplane, :env) == :test do
      # Tests can mutate sandbox rows directly. The fingerprint invalidates a
      # miss after such a mutation; self() isolates parallel sandbox owners.
      fingerprint =
        clients
        |> Enum.map(&{&1.id, &1.token_hash})
        |> Enum.sort()
        |> :erlang.phash2()

      {self(), digest, fingerprint}
    else
      digest
    end
  end

  defp verify_and_cache(token, key, generation, clients) do
    case Enum.find(clients, fn client -> Bcrypt.verify_pass(token, client.token_hash) end) do
      nil ->
        cache_verification(key, generation, :miss)
        :error

      client ->
        cache_verification(key, generation, {:client, client.id, client.token_hash})
        touch_last_seen(client)
        {:ok, client}
    end
  end

  defp cached_verification(_key, generation, _clients)
       when not is_integer(generation) or rem(generation, 2) != 0,
       do: :uncached

  defp cached_verification(key, generation, clients) do
    slot = :erlang.phash2(key, @verification_slots)

    case :ets.lookup(@verification_table, slot) do
      [{^slot, ^key, ^generation, expires_at, result}] ->
        if expires_at > System.monotonic_time(:millisecond) and
             verification_generation() == generation do
          resolve_cached_verification(result, clients)
        else
          :uncached
        end

      _other ->
        :uncached
    end
  rescue
    ArgumentError -> :uncached
  end

  defp resolve_cached_verification(:miss, _clients), do: :miss

  defp resolve_cached_verification({:client, id, token_hash}, clients) do
    case Enum.find(clients, &(&1.id == id and &1.token_hash == token_hash)) do
      nil -> :uncached
      client -> {:ok, client}
    end
  end

  defp cache_verification(_key, generation, _result)
       when not is_integer(generation) or rem(generation, 2) != 0,
       do: :ok

  defp cache_verification(key, generation, result) do
    if verification_generation() == generation do
      slot = :erlang.phash2(key, @verification_slots)
      expires_at = System.monotonic_time(:millisecond) + @verification_ttl_ms
      :ets.insert(@verification_table, {slot, key, generation, expires_at, result})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp verification_generation do
    case :ets.lookup(@verification_table, :generation) do
      [{:generation, generation}] -> generation
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp touch_last_seen(%Client{id: id}) do
    Activity.record(id)
  end

  # --- Scope Matching ---

  @spec scope_matches?([String.t()], String.t()) :: boolean()
  def scope_matches?(scopes, tool_name) when is_list(scopes) and is_binary(tool_name) do
    Enum.any?(scopes, fn scope -> scope_match?(scope, tool_name) end)
  end

  defp scope_match?("*", _tool_name), do: true

  defp scope_match?("memory." <> _permission = scope, "memory::" <> _ = tool_name) do
    case Backplane.MemoryPermissions.for_tool(tool_name) do
      {:ok, ^scope} -> true
      _other -> false
    end
  end

  defp scope_match?(scope, target) when scope == target, do: true

  defp scope_match?(scope, tool_name) do
    case String.split(scope, "::", parts: 2) do
      [prefix, "*"] -> String.starts_with?(tool_name, prefix <> "::")
      [_prefix, _name] -> scope == tool_name
      _ -> false
    end
  end

  @spec filter_tools([map()], [String.t()]) :: [map()]
  def filter_tools(tools, ["*"]), do: tools

  def filter_tools(tools, scopes) when is_list(scopes) do
    Enum.filter(tools, fn tool ->
      name = if is_struct(tool), do: tool.name, else: tool[:name] || tool["name"]
      scope_matches?(scopes, name)
    end)
  end

  # --- CRUD ---

  @spec list_clients() :: [Client.t()]
  def list_clients do
    Client |> order_by(:name) |> Repo.all()
  end

  @spec get_client(String.t()) :: Client.t() | nil
  def get_client(id), do: Repo.get(Client, id)

  @spec get_client_by_name(String.t()) :: Client.t() | nil
  def get_client_by_name(name), do: Repo.get_by(Client, name: name)

  @spec create_client(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(attrs) when is_map(attrs) do
    attrs = hash_token_in_attrs(attrs)

    mutate_client(%Client{}, :put, fn ->
      %Client{}
      |> Client.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @spec update_client(Client.t(), map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs) do
    attrs = hash_token_in_attrs(attrs)

    mutate_client(client, :put, fn ->
      Repo.get!(Client, client.id)
      |> Client.changeset(attrs)
      |> Repo.update()
    end)
  end

  @spec delete_client(Client.t()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client) do
    mutate_client(client, :delete, fn -> Repo.delete(client) end)
  end

  @doc """
  Check if any clients exist.

  In test environment, queries the DB directly (sandbox-isolated).
  In production, reads the fresh authorization lease (O(1), no DB hit).
  """
  @spec any_clients?() :: boolean()
  def any_clients? do
    if Application.get_env(:backplane, :env) == :test do
      Repo.exists?(Client)
    else
      AuthCache.any_clients?()
    end
  rescue
    _ -> true
  end

  # --- Config Upsert ---

  @spec upsert_from_config(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def upsert_from_config(%{name: name, token: token, scopes: scopes}) do
    token_hash = Bcrypt.hash_pwd_salt(token)

    mutate_client(%Client{}, :put, fn ->
      case get_client_by_name(name) do
        nil ->
          %Client{}
          |> Client.changeset(%{name: name, token_hash: token_hash, scopes: scopes})
          |> Repo.insert()

        existing ->
          existing
          |> Client.changeset(%{token_hash: token_hash, scopes: scopes})
          |> Repo.update()
      end
    end)
  end

  # --- Helpers ---

  defp mutate_client(client, operation, write) do
    :global.trans(
      {{__MODULE__, :mutation, node()}, self()},
      fn ->
        :ok = AuthCache.begin_mutation()

        try do
          result = write.()

          case result do
            {:ok, _client} ->
              propagate_mutation(result, operation)

            _failure ->
              AuthCache.abort_mutation()
              refresh_cache()
          end

          result
        rescue
          exception ->
            AuthCache.abort_mutation()
            refresh_cache()
            reraise exception, __STACKTRACE__
        end
      end,
      [node()]
    )
  catch
    :exit, _reason ->
      {:error,
       client
       |> Ecto.Changeset.change()
       |> Ecto.Changeset.add_error(:base, "authentication cache unavailable")}
  end

  defp propagate_mutation({:ok, client}, operation) do
    change = if operation == :put, do: {:put, client}, else: {:delete, client.id}
    AuthCache.mutate(change)

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      "client_auth:invalidations",
      {:client_auth_invalidated, node(), client.id}
    )

    if Application.get_env(:backplane, :env) == :test, do: refresh_cache()
    :ok
  end

  defp propagate_mutation(_result, _operation), do: :ok

  defp hash_token_in_attrs(attrs) do
    token = attrs[:token] || attrs["token"]

    if token do
      hash = Bcrypt.hash_pwd_salt(token)

      attrs
      |> Map.drop([:token, "token"])
      |> then(fn a ->
        if has_atom_keys?(a),
          do: Map.put(a, :token_hash, hash),
          else: Map.put(a, "token_hash", hash)
      end)
    else
      attrs
    end
  end

  defp has_atom_keys?(map) when map_size(map) == 0, do: true

  defp has_atom_keys?(map) do
    map |> Map.keys() |> hd() |> is_atom()
  end
end
