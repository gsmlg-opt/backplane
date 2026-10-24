defmodule Backplane.Scripts.DevenvHostAgent do
  @moduledoc """
  Provisions the project-local development host agent through existing contexts.
  """

  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Skills.{AgentManage, Host, Hosts}

  def prepare(config_path) do
    config_path = Path.expand(config_path)

    suffix =
      :crypto.hash(:sha256, config_path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    name = "backplane-devenv-#{suffix}"

    with {:ok, host, token} <- ensure_host(name, "devenv_#{suffix}"),
         :ok <- validate_host(host, token),
         :ok <- publish_config(config_path, config_yaml(host, token, config_path)) do
      {:ok,
       %{
         host_id: host.id,
         name: host.name,
         memory_scope: host.memory_scope,
         config_path: config_path
       }}
    end
  end

  defp ensure_host(name, scope) do
    case Repo.get_by(Host, name: name) do
      nil ->
        case Hosts.create_agent_with_token(%{name: name, memory_scope: scope}) do
          {:ok, host, _auth_token, token} -> {:ok, host, token}
          {:error, _changeset} -> {:error, :host_registration_failed}
        end

      host ->
        reuse_token(host)
    end
  end

  defp reuse_token(host) do
    case Hosts.auth_token_ids_for_host(host) do
      [] ->
        case Hosts.create_auth_token_for_agent(host, %{name: "#{host.name} token"}) do
          {:ok, _auth_token, token} -> {:ok, host, token}
          {:error, _changeset} -> {:error, :token_creation_failed}
        end

      [auth_token_id | _] ->
        case Hosts.reveal_auth_token(auth_token_id) do
          {:ok, token} -> {:ok, host, token}
          {:error, _reason} -> {:error, :token_unavailable}
        end
    end
  end

  defp validate_host(%Host{id: host_id, memory_scope: scope} = host, token) do
    with {:ok, %Host{id: ^host_id}, auth_token} <- Hosts.verify_token(token),
         {:ok, _manager} <- AgentManage.ensure_agent(host),
         {:ok, %Host{id: ^host_id}, %{id: token_id}} <- AgentManage.authenticate(host_id, token),
         true <- token_id == auth_token.id,
         {:ok, %{scope: ^scope, namespace: "private"}} <-
           MemorySpaces.resolve_host_partition(host_id, scope, "private") do
      :ok
    else
      _ -> {:error, :host_validation_failed}
    end
  end

  defp config_yaml(host, token, config_path) do
    directory = Path.dirname(config_path)

    """
    agent:
      host_id: #{Jason.encode!(host.id)}
      machine_name: #{Jason.encode!(host.name)}
      hub_url: "http://127.0.0.1:4220"
      token: #{Jason.encode!(token)}
      work_dir: #{Jason.encode!(directory)}
      manifest_path: #{Jason.encode!(Path.join(directory, "manifest.json"))}
      http_bind: "127.0.0.1"
      http_port: 4222
    memory:
      enabled: true
      bound_scope: #{Jason.encode!(host.memory_scope)}
      db_path: #{Jason.encode!(Path.join(directory, "memory.db"))}
    targets: []
    """
  end

  defp publish_config(path, content) do
    directory = Path.dirname(path)
    File.mkdir_p!(directory)

    case File.lstat!(directory) do
      %{type: :directory} ->
        File.chmod!(directory, 0o700)
        write_config(path, content)

      _ ->
        {:error, :unsafe_config_directory}
    end
  rescue
    _error in File.Error -> {:error, :config_write_failed}
  end

  defp write_config(path, content) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      {:ok, :ok} =
        File.open(temporary, [:write, :exclusive, :binary], fn io ->
          File.chmod!(temporary, 0o600)
          :ok = IO.binwrite(io, content)
          :file.sync(io)
        end)

      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end
end
