defmodule Backplane.Clients do
  @moduledoc """
  Context module for managing MCP client identities and scoped tool access.

  Token verification caches active clients in ETS to avoid per-request DB
  round-trips. The `any_clients?` check uses `persistent_term` for O(1) reads.
  Both are refreshed on any mutation.
  """

  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.Repo

  @cache_table :backplane_clients_cache

  # --- ETS Cache ---

  @doc "Initialize the clients ETS cache. Called during application startup."
  def init_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [
          :named_table,
          :set,
          :public,
          read_concurrency: true
        ])

      _ref ->
        :ok
    end

    refresh_cache()
  end

  @doc "Refresh the ETS cache from the database."
  def refresh_cache do
    clients =
      try do
        Client |> where(active: true) |> Repo.all()
      rescue
        _ -> []
      end

    rows = Enum.map(clients, fn c -> {c.id, c} end)

    new_ids = MapSet.new(rows, fn {id, _} -> id end)
    :ets.insert(@cache_table, rows)

    @cache_table
    |> :ets.tab2list()
    |> Enum.each(fn {id, _} ->
      unless MapSet.member?(new_ids, id), do: :ets.delete(@cache_table, id)
    end)

    # Update the persistent_term flag
    :persistent_term.put(:backplane_clients_exist, length(clients) > 0)

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cached_active_clients do
    @cache_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, client} -> client end)
  rescue
    ArgumentError -> []
  end

  # --- Token Verification ---

  @doc """
  Verify a bearer token against all active clients.
  Uses ETS-cached client list to avoid DB round-trip.
  """
  @spec verify_token(String.t()) :: {:ok, Client.t()} | :error
  def verify_token(token) when is_binary(token) do
    clients =
      if Application.get_env(:backplane, :env) == :test do
        # In test, read from DB sandbox for isolation
        Client |> where(active: true) |> Repo.all()
      else
        cached_active_clients()
      end

    case Enum.find(clients, fn client -> Bcrypt.verify_pass(token, client.token_hash) end) do
      nil ->
        Bcrypt.no_user_verify()
        :error

      client ->
        touch_last_seen(client)
        {:ok, client}
    end
  end

  def verify_token(_), do: :error

  defp touch_last_seen(%Client{id: id}) do
    Task.start(fn ->
      Client
      |> where(id: ^id)
      |> Repo.update_all(set: [last_seen_at: DateTime.utc_now()])
    end)
  end

  # --- Scope Matching ---

  @spec scope_matches?([String.t()], String.t()) :: boolean()
  def scope_matches?(scopes, tool_name) when is_list(scopes) and is_binary(tool_name) do
    Enum.any?(scopes, fn scope -> scope_match?(scope, tool_name) end)
  end

  defp scope_match?("*", _tool_name), do: true

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

    result =
      %Client{}
      |> Client.changeset(attrs)
      |> Repo.insert()

    if match?({:ok, _}, result), do: refresh_cache()
    result
  end

  @spec update_client(Client.t(), map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs) do
    attrs = hash_token_in_attrs(attrs)

    result =
      client
      |> Client.changeset(attrs)
      |> Repo.update()

    if match?({:ok, _}, result), do: refresh_cache()
    result
  end

  @spec delete_client(Client.t()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client) do
    result = Repo.delete(client)
    if match?({:ok, _}, result), do: refresh_cache()
    result
  end

  @doc """
  Check if any clients exist.

  In test environment, queries the DB directly (sandbox-isolated).
  In production, reads from persistent_term (O(1), no DB hit).
  """
  @spec any_clients?() :: boolean()
  def any_clients? do
    if Application.get_env(:backplane, :env) == :test do
      Repo.exists?(Client)
    else
      :persistent_term.get(:backplane_clients_exist, false)
    end
  rescue
    _ -> false
  end

  # --- Config Upsert ---

  @spec upsert_from_config(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def upsert_from_config(%{name: name, token: token, scopes: scopes}) do
    token_hash = Bcrypt.hash_pwd_salt(token)

    result =
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

    if match?({:ok, _}, result), do: refresh_cache()
    result
  end

  # --- Helpers ---

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
