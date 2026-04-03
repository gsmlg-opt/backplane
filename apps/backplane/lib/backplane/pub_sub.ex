defmodule Backplane.PubSubBroadcaster do
  @moduledoc """
  Centralized PubSub topic definitions and broadcast helpers.

  Topics (per PRD Section 11.6):
  - `upstream:<prefix>` — upstream state changes
  - `skills:sync` — skill sync lifecycle
  - `docs:reindex` — documentation reindex lifecycle
  - `tools:call` — tool call events
  - `config:reloaded` — configuration reload events
  """

  @pubsub Backplane.PubSub

  # Topic builders

  def upstream_topic(prefix), do: "upstream:#{prefix}"
  def skills_sync_topic, do: "skills:sync"
  def docs_reindex_topic, do: "docs:reindex"
  def tools_call_topic, do: "tools:call"
  def config_reloaded_topic, do: "config:reloaded"

  # Subscriptions

  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  # Broadcasts

  def broadcast_upstream(prefix, event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      upstream_topic(prefix),
      {event, Map.put(payload, :prefix, prefix)}
    )
  end

  def broadcast_skills_sync(event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(@pubsub, skills_sync_topic(), {event, payload})
  end

  def broadcast_docs_reindex(event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(@pubsub, docs_reindex_topic(), {event, payload})
  end

  def broadcast_tools_call(event, payload \\ %{}) do
    Phoenix.PubSub.broadcast(@pubsub, tools_call_topic(), {event, payload})
  end

  def broadcast_config_reloaded(payload \\ %{}) do
    Phoenix.PubSub.broadcast(@pubsub, config_reloaded_topic(), {:reloaded, payload})
  end
end
