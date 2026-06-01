defmodule Backplane.Skills.AgentManage do
  @moduledoc """
  Runtime manager facade for durable host agents.

  Durable identity and token assignments stay in PostgreSQL. One manager
  process per durable host caches token hashes, owns the live connection state,
  and publishes runtime updates for the admin UI.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills, as: SkillsContext
  alias Backplane.Skills.{Host, HostAgentToken, HostAssignment, HostAuthToken, Skill}
  alias Backplane.Skills.AgentManage.Manager

  @registry Backplane.Skills.AgentManage.Registry
  @supervisor Backplane.Skills.AgentManage.DynamicSupervisor
  @topic "host_agents:agents"

  @doc "Subscribe to host-agent manager state changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)
  end

  @doc "Start managers for all durable host agents."
  @spec ensure_all_agents() :: :ok | {:error, term()}
  def ensure_all_agents do
    Host
    |> order_by(:name)
    |> Repo.all()
    |> Enum.each(&ensure_agent/1)

    :ok
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Ensure a manager exists for `host`."
  @spec ensure_agent(Host.t() | Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_agent(%Host{} = host) do
    tokens = tokens_for_host(host.id)
    ensure_agent(host, tokens)
  end

  def ensure_agent(host_id) when is_binary(host_id) do
    case Repo.get(Host, host_id) do
      nil -> {:error, :not_found}
      host -> ensure_agent(host)
    end
  end

  @doc "Stop a host manager if it is running."
  @spec stop_agent(Ecto.UUID.t()) :: :ok
  def stop_agent(host_id) do
    with {:ok, pid} <- lookup(host_id) do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    broadcast_changed()
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Refresh host metadata and token hashes from the database."
  @spec refresh_tokens(Host.t() | Ecto.UUID.t()) :: :ok | {:error, term()}
  def refresh_tokens(%Host{} = host), do: refresh_tokens(host.id)

  def refresh_tokens(host_id) when is_binary(host_id) do
    with %Host{} = host <- Repo.get(Host, host_id),
         tokens <- tokens_for_host(host_id),
         {:ok, pid} <- ensure_agent(host, tokens) do
      Manager.refresh(pid, host, tokens)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Authenticate a host token against that host manager's cached token hashes."
  @spec authenticate(Ecto.UUID.t(), term()) :: {:ok, Host.t(), map()} | :error
  def authenticate(host_id, token) when is_binary(host_id) and is_binary(token) do
    with {:ok, %{host: %Host{} = host, tokens: tokens}} <- auth_material(host_id),
         {:ok, token_entry} <- verify_token(tokens, token) do
      {:ok, host, token_entry}
    else
      _ -> :error
    end
  end

  def authenticate(_host_id, _token) do
    Bcrypt.no_user_verify()
    :error
  end

  @doc "Register a channel process as the current connection for a host."
  @spec register_connection(Host.t(), HostAuthToken.t() | map(), pid(), map()) ::
          :ok | {:error, term()}
  def register_connection(%Host{} = host, auth_token, pid, metadata \\ %{}) when is_pid(pid) do
    with {:ok, manager} <- running_agent(host) do
      Manager.register_connection(manager, auth_token, pid, metadata)
    end
  end

  @doc "Disconnect and forget a live host connection."
  @spec disconnect(Ecto.UUID.t()) :: :ok
  def disconnect(host_id) do
    with {:ok, pid} <- lookup(host_id) do
      Manager.disconnect(pid)
    end

    :ok
  end

  @doc "List all durable host agents with runtime manager state."
  @spec list_agents() :: [map()]
  def list_agents do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.map(&Manager.snapshot/1)
    |> Enum.sort_by(&String.downcase(&1.host.name || ""))
  catch
    :error, :badarg -> []
    :exit, _ -> []
  end

  @doc "List connected agents only."
  @spec list_connected() :: [map()]
  def list_connected do
    Enum.filter(list_agents(), &(&1.status == :online))
  end

  @doc "Fetch one manager entry by host ID."
  @spec get_agent(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_agent(host_id) do
    with {:ok, pid} <- lookup(host_id) do
      {:ok, Manager.snapshot(pid)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Update runtime state reported by heartbeat."
  @spec update_runtime(Ecto.UUID.t(), map()) :: :ok | {:error, :invalid_payload | :not_connected}
  def update_runtime(host_id, payload) when is_map(payload) do
    with {:ok, runtime} <- normalize_runtime(payload),
         {:ok, pid} <- lookup(host_id) do
      Manager.update_runtime(pid, runtime)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_connected}
    end
  end

  def update_runtime(_host_id, _payload), do: {:error, :invalid_payload}

  @doc "Store latest runtime config reported by a connected host agent."
  @spec report_config(Ecto.UUID.t(), map()) :: :ok | {:error, :invalid_payload | :not_connected}
  def report_config(host_id, config) when is_map(config) do
    with {:ok, pid} <- lookup(host_id) do
      Manager.report_config(pid, stringify_keys(config))
    else
      _ -> {:error, :not_connected}
    end
  end

  def report_config(_host_id, _config), do: {:error, :invalid_payload}

  @doc "Record volatile sync status on the manager."
  @spec record_sync(Ecto.UUID.t(), map()) :: :ok | {:error, :not_connected}
  def record_sync(host_id, payload) when is_map(payload) do
    with {:ok, pid} <- lookup(host_id) do
      Manager.record_sync(pid, payload)
    else
      _ -> {:error, :not_connected}
    end
  end

  def record_sync(_host_id, _payload), do: {:error, :not_connected}

  @doc "Return one base64 encoded skill archive chunk for an assigned skill."
  @spec skill_bundle_chunk(Ecto.UUID.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def skill_bundle_chunk(host_id, slug_or_id, chunk_index, chunk_size \\ 49_152)
      when is_binary(host_id) and is_binary(slug_or_id) and is_integer(chunk_index) and
             chunk_index >= 0 and is_integer(chunk_size) and chunk_size > 0 do
    with %Skill{} = skill <- assigned_archive_skill(host_id, slug_or_id),
         {:ok, stream} <- SkillsContext.archive_stream(skill) do
      archive = Enum.into(stream, <<>>)
      chunks = chunk_binary(archive, chunk_size)
      chunk_count = length(chunks)

      case Enum.at(chunks, chunk_index) do
        nil ->
          {:error, :chunk_not_found}

        chunk ->
          {:ok,
           %{
             "id" => skill.id,
             "slug" => skill.slug,
             "checksum" => skill.content_hash,
             "chunk_index" => chunk_index,
             "chunk_count" => chunk_count,
             "chunk_size" => chunk_size,
             "encoding" => "base64",
             "data" => Base.encode64(chunk)
           }}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop all managers. Intended for tests."
  @spec clear() :: :ok
  def clear do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.each(&DynamicSupervisor.terminate_child(@supervisor, &1))

    broadcast_changed()
    :ok
  catch
    :error, :badarg -> :ok
    :exit, _ -> :ok
  end

  defp ensure_agent(%Host{} = host, tokens) do
    case lookup(host.id) do
      {:ok, pid} ->
        Manager.refresh(pid, host, tokens)
        {:ok, pid}

      {:error, :not_found} ->
        start_child(host, tokens)
    end
  end

  defp start_child(host, tokens) do
    spec = {Manager, host: host, tokens: tokens}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp running_agent(%Host{} = host) do
    case lookup(host.id) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> ensure_agent(host)
    end
  end

  defp lookup(host_id) do
    case Registry.lookup(@registry, host_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  catch
    :error, :badarg -> {:error, :not_found}
  end

  defp auth_material(host_id) do
    case Registry.lookup(@registry, host_id) do
      [{_pid, %{host: %Host{}, tokens: tokens} = value}] when is_list(tokens) ->
        {:ok, value}

      _other ->
        {:error, :not_found}
    end
  catch
    :error, :badarg -> {:error, :not_found}
  end

  defp verify_token(tokens, token) do
    case Enum.find(tokens, &Bcrypt.verify_pass(token, &1.token_hash)) do
      nil ->
        Bcrypt.no_user_verify()
        :error

      token_entry ->
        {:ok, token_entry}
    end
  end

  defp tokens_for_host(host_id) do
    HostAuthToken
    |> join(:inner, [auth_token], agent_token in HostAgentToken,
      on: agent_token.auth_token_id == auth_token.id
    )
    |> where([_auth_token, agent_token], agent_token.host_id == ^host_id)
    |> order_by([auth_token, _agent_token], auth_token.name)
    |> Repo.all()
  end

  defp assigned_archive_skill(host_id, slug_or_id) do
    HostAssignment
    |> where([assignment], assignment.host_id == ^host_id and assignment.enabled == true)
    |> join(:inner, [assignment], skill in Skill, on: skill.id == assignment.skill_id)
    |> where(
      [_assignment, skill],
      skill.enabled == true and skill.source_kind == "archive" and not is_nil(skill.archive_ref) and
        (skill.slug == ^slug_or_id or skill.id == ^slug_or_id)
    )
    |> select([_assignment, skill], skill)
    |> Repo.one()
  end

  defp chunk_binary(binary, chunk_size), do: chunk_binary(binary, chunk_size, [])

  defp chunk_binary(<<>>, _chunk_size, []), do: [<<>>]
  defp chunk_binary(<<>>, _chunk_size, chunks), do: Enum.reverse(chunks)

  defp chunk_binary(binary, chunk_size, chunks) do
    size = min(byte_size(binary), chunk_size)
    <<chunk::binary-size(size), rest::binary>> = binary
    chunk_binary(rest, chunk_size, [chunk | chunks])
  end

  defp normalize_runtime(payload) do
    payload = stringify_keys(payload)

    with :ok <- validate_targets(payload),
         :ok <- validate_metadata(payload) do
      runtime =
        %{}
        |> maybe_put(:status, payload["status"] || "online")
        |> maybe_put(:agent_version, payload["agent_version"])
        |> maybe_put(:targets, payload["targets"])
        |> maybe_put(:metadata, payload["metadata"])

      {:ok, runtime}
    end
  end

  defp validate_targets(%{"targets" => targets}) when not is_list(targets) do
    {:error, :invalid_payload}
  end

  defp validate_targets(_payload), do: :ok

  defp validate_metadata(%{"metadata" => metadata}) when not is_map(metadata) do
    {:error, :invalid_payload}
  end

  defp validate_metadata(_payload), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp broadcast_changed do
    if Process.whereis(Backplane.PubSub) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :agents_changed)
    end
  end
end
