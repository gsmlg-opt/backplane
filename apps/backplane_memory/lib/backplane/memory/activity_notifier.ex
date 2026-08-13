defmodule Backplane.Memory.ActivityNotifier do
  @moduledoc "Commit-ordered, content-free activity projection invalidations."

  use GenServer

  @database_channel "backplane_memory_activity"
  @topic "memory:v2:activity"
  @notification_server Backplane.Memory.EventNotifications

  def subscribe, do: Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)

  def enqueue(repo, keys) when is_list(keys) do
    keys
    |> summaries()
    |> Enum.each(fn summary ->
      repo.query!("SELECT pg_notify($1, $2)", [@database_channel, Jason.encode!(summary)])
    end)

    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, ref} = Postgrex.Notifications.listen(@notification_server, @database_channel)
    {:ok, %{listen_ref: ref}}
  end

  @impl true
  def handle_info(
        {:notification, _pid, ref, @database_channel, payload},
        %{listen_ref: ref} = state
      ) do
    with {:ok, summary} <- Jason.decode(payload),
         {:ok, parsed} <- parse_summary(summary) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, {:memory_activity_updated, parsed})
    end

    {:noreply, state}
  end

  defp summaries(keys) do
    keys
    |> Enum.group_by(fn {_date, _project, _agent, host, client, scope, namespace, _type} ->
      {host, client, scope, namespace}
    end)
    |> Enum.map(fn {{host, client, scope, namespace}, partition_keys} ->
      dates = Enum.map(partition_keys, &elem(&1, 0))

      %{
        host_id: host,
        client_id: client,
        scope: scope,
        namespace: namespace,
        date_from: dates |> Enum.min() |> Date.to_iso8601(),
        date_to: dates |> Enum.max() |> Date.to_iso8601()
      }
    end)
  end

  defp parse_summary(%{
         "host_id" => host,
         "client_id" => client,
         "scope" => scope,
         "namespace" => namespace,
         "date_from" => from,
         "date_to" => to
       }) do
    with {:ok, date_from} <- Date.from_iso8601(from),
         {:ok, date_to} <- Date.from_iso8601(to) do
      {:ok,
       %{
         host_id: host,
         client_id: client,
         scope: scope,
         namespace: namespace,
         date_from: date_from,
         date_to: date_to
       }}
    end
  end

  defp parse_summary(_summary), do: {:error, :invalid_notification}
end
