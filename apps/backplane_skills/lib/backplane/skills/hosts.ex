defmodule Backplane.Skills.Hosts do
  @moduledoc """
  Public context for durable host agents and their auth tokens.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostAgentToken, HostAuthToken, HostConnectionRegistry}

  @token_prefix "bha_"

  @doc "List host agents ordered by name."
  @spec list_hosts() :: [Host.t()]
  def list_hosts do
    Host |> order_by(:name) |> Repo.all()
  end

  @doc "List host agents with their assigned auth tokens ordered by name."
  @spec list_hosts_with_auth_tokens() :: [Host.t()]
  def list_hosts_with_auth_tokens do
    auth_token_query = from(token in HostAuthToken, order_by: token.name)

    Host
    |> order_by(:name)
    |> preload(auth_tokens: ^auth_token_query)
    |> Repo.all()
  end

  @doc "Fetch a host agent by ID."
  @spec get_host(Ecto.UUID.t()) :: Host.t() | nil
  def get_host(id), do: Repo.get(Host, id)

  @doc "List host agent auth tokens ordered by name."
  @spec list_auth_tokens() :: [HostAuthToken.t()]
  def list_auth_tokens do
    HostAuthToken |> order_by(:name) |> Repo.all()
  end

  @doc "List auth tokens with the host agent they are assigned to, when any."
  @spec list_auth_tokens_with_assignments() :: [
          %{token: HostAuthToken.t(), assigned_host: Host.t() | nil}
        ]
  def list_auth_tokens_with_assignments do
    HostAuthToken
    |> join(:left, [token], agent_token in HostAgentToken,
      on: agent_token.auth_token_id == token.id
    )
    |> join(:left, [_token, agent_token], host in Host, on: host.id == agent_token.host_id)
    |> order_by([token, _agent_token, _host], token.name)
    |> select([token, _agent_token, host], %{token: token, assigned_host: host})
    |> Repo.all()
  end

  @doc "Fetch a host agent auth token by ID."
  @spec get_auth_token(Ecto.UUID.t()) :: HostAuthToken.t() | nil
  def get_auth_token(id), do: Repo.get(HostAuthToken, id)

  @doc "Create a host agent auth token and return the plaintext token once."
  @spec create_auth_token(map()) ::
          {:ok, HostAuthToken.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_auth_token(attrs) when is_map(attrs) do
    token = generate_token()

    case insert_auth_token(attrs, Bcrypt.hash_pwd_salt(token)) do
      {:ok, auth_token} -> {:ok, auth_token, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Delete an unassigned host agent auth token."
  @spec delete_auth_token(HostAuthToken.t()) :: {:ok, HostAuthToken.t()} | {:error, :assigned}
  def delete_auth_token(%HostAuthToken{} = auth_token) do
    assigned? =
      HostAgentToken
      |> where([agent_token], agent_token.auth_token_id == ^auth_token.id)
      |> Repo.exists?()

    if assigned? do
      {:error, :assigned}
    else
      Repo.delete(auth_token)
    end
  end

  @doc "Create a durable host agent identity."
  @spec create_agent(map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def create_agent(attrs) when is_map(attrs) do
    attrs = normalize_agent_attrs(attrs)
    auth_token_ids = normalize_auth_token_ids(attrs["auth_token_ids"])
    host_attrs = Map.delete(attrs, "auth_token_ids")

    Repo.transaction(fn ->
      with {:ok, host} <- %Host{} |> Host.changeset(host_attrs) |> Repo.insert(),
           :ok <- sync_auth_tokens(host, auth_token_ids, host_attrs) do
        host
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Update a durable host agent identity and token assignments."
  @spec update_agent(Host.t(), map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def update_agent(%Host{} = host, attrs) when is_map(attrs) do
    attrs = normalize_agent_attrs(attrs)

    auth_token_ids =
      if Map.has_key?(attrs, "auth_token_ids") do
        normalize_auth_token_ids(attrs["auth_token_ids"])
      else
        auth_token_ids_for_host(host)
      end

    host_attrs = Map.delete(attrs, "auth_token_ids")

    Repo.transaction(fn ->
      with {:ok, updated_host} <- host |> Host.changeset(host_attrs) |> Repo.update(),
           :ok <- sync_auth_tokens(updated_host, auth_token_ids, host_attrs) do
        updated_host
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Delete a host agent and leave its auth tokens unassigned."
  @spec delete_agent(Host.t()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def delete_agent(%Host{} = host) do
    disconnect_if_running(host.id)
    Repo.delete(host)
  end

  @doc "List assigned auth token IDs for a host."
  @spec auth_token_ids_for_host(Host.t() | Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def auth_token_ids_for_host(%Host{id: host_id}), do: auth_token_ids_for_host(host_id)

  def auth_token_ids_for_host(host_id) do
    HostAgentToken
    |> join(:inner, [agent_token], token in HostAuthToken,
      on: token.id == agent_token.auth_token_id
    )
    |> where([agent_token, _token], agent_token.host_id == ^host_id)
    |> order_by([_agent_token, token], token.name)
    |> select([agent_token, _token], agent_token.auth_token_id)
    |> Repo.all()
  end

  @doc "Verify an assigned host token."
  @spec verify_token(term()) :: {:ok, Host.t(), HostAuthToken.t()} | :error
  def verify_token(token) when is_binary(token) do
    assigned_tokens =
      HostAuthToken
      |> join(:inner, [auth_token], agent_token in HostAgentToken,
        on: agent_token.auth_token_id == auth_token.id
      )
      |> join(:inner, [_auth_token, agent_token], host in Host,
        on: host.id == agent_token.host_id
      )
      |> select([auth_token, _agent_token, host], {auth_token, host})
      |> Repo.all()

    case Enum.find(assigned_tokens, fn {auth_token, _host} ->
           Bcrypt.verify_pass(token, auth_token.token_hash)
         end) do
      nil ->
        Bcrypt.no_user_verify()
        :error

      {auth_token, host} ->
        {:ok, host, auth_token}
    end
  end

  def verify_token(_), do: :error

  defp sync_auth_tokens(%Host{} = host, auth_token_ids, host_attrs) do
    with :ok <- validate_auth_tokens_exist(host, auth_token_ids, host_attrs),
         :ok <- validate_auth_tokens_available(host, auth_token_ids, host_attrs) do
      replace_auth_tokens(host, auth_token_ids)
    end
  end

  defp validate_auth_tokens_exist(_host, [], _host_attrs), do: :ok

  defp validate_auth_tokens_exist(host, auth_token_ids, host_attrs) do
    found_count =
      HostAuthToken
      |> where([auth_token], auth_token.id in ^auth_token_ids)
      |> select([auth_token], count(auth_token.id))
      |> Repo.one()

    if found_count == length(auth_token_ids) do
      :ok
    else
      {:error, assignment_changeset(host, host_attrs, "is invalid")}
    end
  end

  defp validate_auth_tokens_available(_host, [], _host_attrs), do: :ok

  defp validate_auth_tokens_available(host, auth_token_ids, host_attrs) do
    already_assigned? =
      HostAgentToken
      |> where(
        [agent_token],
        agent_token.auth_token_id in ^auth_token_ids and agent_token.host_id != ^host.id
      )
      |> Repo.exists?()

    if already_assigned? do
      {:error, assignment_changeset(host, host_attrs, "is already assigned")}
    else
      :ok
    end
  end

  defp replace_auth_tokens(%Host{} = host, auth_token_ids) do
    existing_ids = auth_token_ids_for_host(host)
    remove_ids = existing_ids -- auth_token_ids
    add_ids = auth_token_ids -- existing_ids

    if remove_ids != [] do
      HostAgentToken
      |> where(
        [agent_token],
        agent_token.host_id == ^host.id and agent_token.auth_token_id in ^remove_ids
      )
      |> Repo.delete_all()
    end

    Enum.reduce_while(add_ids, :ok, fn auth_token_id, :ok ->
      changeset =
        HostAgentToken.changeset(%HostAgentToken{}, %{
          "host_id" => host.id,
          "auth_token_id" => auth_token_id
        })

      case Repo.insert(changeset) do
        {:ok, _agent_token} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp assignment_changeset(host, attrs, message) do
    host
    |> Host.changeset(attrs)
    |> add_error(:auth_token_ids, message)
  end

  defp insert_auth_token(attrs, token_hash) do
    attrs =
      attrs
      |> stringify_keys()
      |> normalize_auth_token_params()
      |> Map.put("token_hash", token_hash)

    %HostAuthToken{}
    |> HostAuthToken.changeset(attrs)
    |> Repo.insert()
  end

  defp normalize_agent_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> Map.update("name", "", &String.trim/1)
  end

  defp normalize_auth_token_params(attrs) do
    Map.update(attrs, "name", "", &String.trim/1)
  end

  defp normalize_auth_token_ids(nil), do: []
  defp normalize_auth_token_ids(""), do: []

  defp normalize_auth_token_ids(auth_token_ids) when is_list(auth_token_ids) do
    auth_token_ids
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_auth_token_ids(auth_token_id), do: normalize_auth_token_ids([auth_token_id])

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp disconnect_if_running(host_id) do
    if Process.whereis(HostConnectionRegistry) do
      HostConnectionRegistry.disconnect(host_id)
    end
  end
end
