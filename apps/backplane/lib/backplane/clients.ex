defmodule Backplane.Clients do
  @moduledoc """
  Context module for managing MCP client identities and scoped tool access.
  """

  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.Repo

  # --- Token Verification ---

  @doc """
  Verify a bearer token against all active clients.
  Returns `{:ok, client}` on match, `:error` on failure.
  Updates `last_seen_at` asynchronously on success.
  """
  @spec verify_token(String.t()) :: {:ok, Client.t()} | :error
  def verify_token(token) when is_binary(token) do
    clients = Client |> where(active: true) |> Repo.all()

    case Enum.find(clients, fn client -> Bcrypt.verify_pass(token, client.token_hash) end) do
      nil ->
        # Run dummy check to prevent timing attacks
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

  @doc """
  Check if a tool name is allowed by a list of scopes.

  Scope matching rules:
  - `"*"` matches all tools
  - `"prefix::*"` matches all tools starting with `"prefix::"`
  - `"prefix::tool_name"` matches the exact tool name
  """
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

  @doc "Filter a list of tools by scopes."
  @spec filter_tools([map()], [String.t()]) :: [map()]
  def filter_tools(tools, ["*"]), do: tools

  def filter_tools(tools, scopes) when is_list(scopes) do
    Enum.filter(tools, fn tool ->
      name = if is_struct(tool), do: tool.name, else: tool[:name] || tool["name"]
      scope_matches?(scopes, name)
    end)
  end

  # --- CRUD ---

  @doc "List all clients (ordered by name)."
  @spec list_clients() :: [Client.t()]
  def list_clients do
    Client |> order_by(:name) |> Repo.all()
  end

  @doc "Get a client by ID."
  @spec get_client(String.t()) :: Client.t() | nil
  def get_client(id), do: Repo.get(Client, id)

  @doc "Get a client by name."
  @spec get_client_by_name(String.t()) :: Client.t() | nil
  def get_client_by_name(name), do: Repo.get_by(Client, name: name)

  @doc "Create a new client. Expects `token` (plaintext) in attrs — it will be hashed."
  @spec create_client(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(attrs) when is_map(attrs) do
    attrs = hash_token_in_attrs(attrs)

    %Client{}
    |> Client.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing client. If `token` is provided, it will be re-hashed."
  @spec update_client(Client.t(), map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs) do
    attrs = hash_token_in_attrs(attrs)

    client
    |> Client.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a client."
  @spec delete_client(Client.t()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client) do
    Repo.delete(client)
  end

  @doc "Check if any clients exist in the database."
  @spec any_clients?() :: boolean()
  def any_clients? do
    Repo.exists?(Client)
  end

  # --- Config Upsert ---

  @doc """
  Upsert a client from TOML config.
  Creates if not exists, updates scopes/token if changed.
  """
  @spec upsert_from_config(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def upsert_from_config(%{name: name, token: token, scopes: scopes}) do
    token_hash = Bcrypt.hash_pwd_salt(token)

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

  defp has_atom_keys?(map) do
    map |> Map.keys() |> List.first() |> is_atom()
  end
end
