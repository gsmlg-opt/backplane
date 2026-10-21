defmodule Backplane.Clients do
  @moduledoc """
  Context module for managing MCP client identities and scoped tool access.

  Server-issued credentials are resolved by a digest index in supervised ETS.
  Mutations invalidate authority before writing; leased authorization snapshots
  bound cross-node freshness without request SQL or client enumeration.
  """

  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.Clients.{Activity, AuthCache}
  alias Backplane.Repo

  # Ecto SQL telemetry includes raw params and result rows; schema Inspect
  # redaction does not protect credentials there. Keep this policy query-local.
  @credential_query_opts [log: false, telemetry_event: nil]

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

  @doc "Verify a server-issued credential using its indexed digest."
  @spec verify_token(String.t()) :: {:ok, Client.t()} | :error | {:error, :unavailable}
  def verify_token(token) do
    cond do
      not AuthCache.token_format_valid?(token) -> :error
      Application.get_env(:backplane, :env) == :test -> sandbox_verify_token(token)
      true -> AuthCache.verify(token)
    end
  end

  # Request header parsing also serves OAuth, whose format is independent.
  def token_size_valid?(token), do: AuthCache.token_size_valid?(token)

  defp sandbox_verify_token(token) do
    digest = :crypto.hash(:sha256, token)

    case Repo.get_by(Client, [token_digest: digest, active: true], @credential_query_opts) do
      nil ->
        :error

      client ->
        Activity.record(client.id)
        {:ok, client}
    end
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
    Client |> order_by(:name) |> Repo.all(@credential_query_opts)
  end

  @spec get_client(String.t()) :: Client.t() | nil
  def get_client(id), do: Repo.get(Client, id, @credential_query_opts)

  @spec get_client_by_name(String.t()) :: Client.t() | nil
  def get_client_by_name(name), do: Repo.get_by(Client, [name: name], @credential_query_opts)

  @spec create_client(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(attrs) when is_map(attrs) do
    mutate_client(%Client{}, :put, fn ->
      %Client{}
      |> Client.changeset(attrs)
      |> Repo.insert(@credential_query_opts)
    end)
  end

  @doc "Create a client and return its server-generated credential once."
  def issue_client(attrs) when is_map(attrs) do
    token = generate_token()

    result =
      mutate_client(%Client{}, :put, fn ->
        %Client{}
        |> Client.changeset(attrs)
        |> Ecto.Changeset.put_change(:token_digest, :crypto.hash(:sha256, token))
        |> Repo.insert(@credential_query_opts)
      end)

    issued_result(result, token)
  end

  @doc "Replace a client's sole credential and return the new token once."
  def rotate_client_token(%Client{} = client, attrs \\ %{}) do
    token = generate_token()

    result =
      mutate_client(client, :put, fn ->
        Repo.get!(Client, client.id, @credential_query_opts)
        |> Client.changeset(attrs)
        |> Ecto.Changeset.put_change(:token_digest, :crypto.hash(:sha256, token))
        |> Repo.update(@credential_query_opts)
      end)

    issued_result(result, token)
  end

  @doc "Revoke the client's credential without removing its identity or scopes."
  def revoke_client_token(%Client{} = client) do
    mutate_client(client, :put, fn ->
      Repo.get!(Client, client.id, @credential_query_opts)
      |> Client.changeset(%{})
      |> Ecto.Changeset.put_change(:token_digest, nil)
      |> Repo.update(@credential_query_opts)
    end)
  end

  defp generate_token,
    do: "bp2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp issued_result({:ok, client}, token), do: {:ok, client, token}

  defp issued_result({:error, %Ecto.Changeset{} = changeset}, _token),
    do: {:error, Ecto.Changeset.delete_change(changeset, :token_digest)}

  defp issued_result(error, _token), do: error

  @spec update_client(Client.t(), map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs) do
    mutate_client(client, :put, fn ->
      Repo.get!(Client, client.id, @credential_query_opts)
      |> Client.changeset(attrs)
      |> Repo.update(@credential_query_opts)
    end)
  end

  @spec delete_client(Client.t()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client) do
    mutate_client(client, :delete, fn -> Repo.delete(client, @credential_query_opts) end)
  end

  @doc """
  Check if any clients exist, treating unavailable state as protected.
  """
  @spec any_clients?() :: boolean()
  def any_clients? do
    case fetch_any_clients() do
      {:ok, any?} -> any?
      {:error, :unavailable} -> true
    end
  end

  @doc """
  Check if any clients exist without conflating unavailable state with client presence.

  In test environment, queries the DB directly (sandbox-isolated).
  In production, reads the fresh authorization lease (O(1), no DB hit).
  """
  @spec fetch_any_clients() :: {:ok, boolean()} | {:error, :unavailable}
  def fetch_any_clients do
    if Application.get_env(:backplane, :env) == :test do
      {:ok, Repo.exists?(Client, @credential_query_opts)}
    else
      AuthCache.fetch_any_clients()
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # --- Config Upsert ---

  @spec upsert_from_config(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def upsert_from_config(attrs) when is_map(attrs) do
    name = attrs[:name] || attrs["name"]

    # The ordinary changeset rejects all credential attrs, including config imports.
    case get_client_by_name(name) do
      nil -> create_client(attrs)
      existing -> update_client(existing, attrs)
    end
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
end
