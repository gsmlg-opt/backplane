defmodule Backplane.Proxy.Upstreams do
  @moduledoc "Context for managing MCP upstream server definitions."

  alias Backplane.Repo
  alias Backplane.Proxy.McpUpstream

  import Ecto.Query

  @pubsub Backplane.PubSub
  @topic "upstreams:changed"

  def list do
    McpUpstream
    |> order_by(:name)
    |> Repo.all()
  end

  def list_enabled do
    McpUpstream
    |> where([u], u.enabled == true)
    |> order_by(:name)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(McpUpstream, id)

  def get_by_name(name), do: Repo.get_by(McpUpstream, name: name)

  def create(attrs) do
    result =
      %McpUpstream{}
      |> McpUpstream.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, upstream} ->
        broadcast(:created, upstream)
        {:ok, upstream}

      error ->
        error
    end
  end

  def update(%McpUpstream{} = upstream, attrs) do
    result =
      upstream
      |> McpUpstream.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, upstream} ->
        broadcast(:updated, upstream)
        {:ok, upstream}

      error ->
        error
    end
  end

  def delete(%McpUpstream{} = upstream) do
    case Repo.delete(upstream) do
      {:ok, upstream} ->
        broadcast(:deleted, upstream)
        {:ok, upstream}

      error ->
        error
    end
  end

  def change(%McpUpstream{} = upstream, attrs \\ %{}) do
    McpUpstream.changeset(upstream, attrs)
  end

  def topic, do: @topic

  defp broadcast(event, upstream) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:upstream_config, event, upstream})
  end
end
