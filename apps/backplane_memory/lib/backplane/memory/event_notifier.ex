defmodule Backplane.Memory.EventNotifier do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Backplane.Memory.Events.Event

  @database_channel "backplane_memory_v2_events"
  @topic "memory:v2:events"
  @notification_server Backplane.Memory.EventNotifications
  @summary_fields [
    :id,
    :stream_id,
    :event_type,
    :project,
    :agent_id,
    :session_id,
    :run_id,
    :tool_name,
    :status,
    :occurred_at
  ]
  @connection_keys [
    :url,
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :socket_dir,
    :ssl,
    :ssl_opts,
    :parameters,
    :connect_timeout,
    :socket_options,
    :types
  ]

  def database_channel, do: @database_channel
  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)
  end

  def enqueue(repo, event_id) do
    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT pg_notify($1, $2)",
           [@database_channel, event_id]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_many(_repo, []), do: :ok

  def enqueue_many(repo, event_ids) when is_list(event_ids) do
    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT pg_notify($1, event_id) FROM unnest($2::text[]) AS event_id",
           [@database_channel, event_ids]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def connection_options do
    repo().config()
    |> Keyword.take(@connection_keys)
    |> Keyword.merge(
      name: @notification_server,
      sync_connect: true,
      auto_reconnect: false
    )
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, ref} = Postgrex.Notifications.listen(@notification_server, @database_channel)
    {:ok, %{listen_ref: ref}}
  end

  @impl true
  def handle_info(
        {:notification, _pid, ref, @database_channel, event_id},
        %{listen_ref: ref} = state
      ) do
    event = load_summary(event_id)

    if event do
      Phoenix.PubSub.broadcast(
        Backplane.PubSub,
        @topic,
        {:memory_event_inserted, event}
      )
    end

    {:noreply, state}
  end

  defp load_summary(event_id) do
    Event
    |> where([event], event.id == ^event_id)
    |> select([event], map(event, ^@summary_fields))
    |> repo().one()
  rescue
    DBConnection.OwnershipError ->
      nil
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
