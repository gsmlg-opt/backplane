defmodule Backplane.Skills.AgentMcpServers do
  @moduledoc """
  Context for managing MCP server configurations that run on host agents.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.AgentMcpServer

  @topic "agent_mcp_servers"

  @doc "Subscribe to agent MCP server config changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)
  end

  @doc "List all agent MCP server configs ordered by name."
  @spec list() :: [AgentMcpServer.t()]
  def list do
    AgentMcpServer |> order_by(:name) |> Repo.all()
  end

  @doc "List agent MCP server configs for a specific host (including global ones)."
  @spec list_for_host(Ecto.UUID.t()) :: [AgentMcpServer.t()]
  def list_for_host(host_id) do
    AgentMcpServer
    |> where([s], is_nil(s.host_id) or s.host_id == ^host_id)
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "List enabled agent MCP server configs for a specific host (including global ones)."
  @spec list_enabled_for_host(Ecto.UUID.t()) :: [AgentMcpServer.t()]
  def list_enabled_for_host(host_id) do
    AgentMcpServer
    |> where([s], s.enabled == true and (is_nil(s.host_id) or s.host_id == ^host_id))
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "Get an agent MCP server config by ID."
  @spec get!(Ecto.UUID.t()) :: AgentMcpServer.t()
  def get!(id), do: Repo.get!(AgentMcpServer, id)

  @doc "Create a new agent MCP server config."
  @spec create(map()) :: {:ok, AgentMcpServer.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %AgentMcpServer{}
      |> AgentMcpServer.changeset(attrs)
      |> Repo.insert()

    broadcast_changed(result)
    result
  end

  @doc "Update an agent MCP server config."
  @spec update(AgentMcpServer.t(), map()) ::
          {:ok, AgentMcpServer.t()} | {:error, Ecto.Changeset.t()}
  def update(%AgentMcpServer{} = server, attrs) do
    result =
      server
      |> AgentMcpServer.changeset(attrs)
      |> Repo.update()

    broadcast_changed(result)
    result
  end

  @doc "Delete an agent MCP server config."
  @spec delete(AgentMcpServer.t()) :: {:ok, AgentMcpServer.t()} | {:error, Ecto.Changeset.t()}
  def delete(%AgentMcpServer{} = server) do
    result = Repo.delete(server)
    broadcast_changed(result)
    result
  end

  @doc "Build a changeset for an agent MCP server."
  @spec change(AgentMcpServer.t(), map()) :: Ecto.Changeset.t()
  def change(%AgentMcpServer{} = server, attrs \\ %{}) do
    AgentMcpServer.changeset(server, attrs)
  end

  defp broadcast_changed({:ok, _server}) do
    if Process.whereis(Backplane.PubSub) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :agent_mcp_servers_changed)
    end
  end

  defp broadcast_changed(_), do: :ok
end
