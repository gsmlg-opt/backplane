defmodule Backplane.Memory.Coordination.Signal do
  @moduledoc "Point-to-point agent signals stored in memory_signals."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.PartitionIdentity

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_signals" do
    field(:memory_space_id, :binary_id)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:source_client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:sender_agent_id, :string)
    field(:recipient_agent_id, :string)
    field(:topic, :string)
    field(:payload, :map, default: %{})
    field(:sent_at, :utc_datetime_usec)
    field(:read_at, :utc_datetime_usec)
  end

  def changeset(sig, attrs) do
    sig
    |> cast(attrs, [
      :host_id,
      :memory_space_id,
      :client_id,
      :source_client_id,
      :scope,
      :namespace,
      :sender_agent_id,
      :recipient_agent_id,
      :topic,
      :payload,
      :sent_at
    ])
    |> validate_required([
      :memory_space_id,
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :sender_agent_id,
      :recipient_agent_id,
      :topic
    ])
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Send a signal from sender to recipient."
  def send_signal(_sender, _recipient, _topic, _payload \\ %{}),
    do: {:error, :partition_required}

  def send_signal(sender, recipient, topic, payload, partition) do
    with {:ok, partition} <- canonical_partition(partition) do
      do_send_signal(sender, recipient, topic, payload, partition)
    end
  end

  defp do_send_signal(sender, recipient, topic, payload, partition) do
    repo().transaction(fn ->
      case %__MODULE__{}
           |> changeset(
             %{
               sender_agent_id: sender,
               recipient_agent_id: recipient,
               topic: topic,
               payload: payload,
               sent_at: DateTime.utc_now()
             }
             |> Map.merge(partition_attrs(partition))
           )
           |> repo().insert() do
        {:ok, signal} ->
          Audit.log("coordination.signal.send", sender, [signal.id], %{
            recipient_agent_id: recipient,
            topic: topic,
            memory_space_id: signal.memory_space_id,
            host_id: signal.host_id,
            client_id: signal.client_id,
            source_client_id: signal.source_client_id,
            scope: signal.scope,
            namespace: signal.namespace,
            result: "sent"
          })

          signal

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
    |> case do
      {:ok, signal} -> {:ok, signal}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc "Read unread signals for agent (and optionally topic). Marks them read atomically."
  def read_signals(_agent_id, _topic \\ nil, _limit \\ 20),
    do: {:error, :partition_required}

  def read_signals(agent_id, topic, limit, partition) do
    with {:ok, partition} <- canonical_partition(partition) do
      do_read_signals(agent_id, topic, limit, partition)
    end
  end

  defp do_read_signals(agent_id, topic, limit, partition) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(s in __MODULE__,
        where: s.recipient_agent_id == ^agent_id and is_nil(s.read_at),
        where: ^partition_dynamic(partition),
        order_by: [asc: s.sent_at],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    query = if topic, do: where(query, [s], s.topic == ^topic), else: query

    repo().transaction(fn ->
      signals = repo().all(query)
      ids = Enum.map(signals, & &1.id)

      if ids != [] do
        {updated, _} =
          repo().update_all(
            from(s in __MODULE__, where: s.id in ^ids and is_nil(s.read_at)),
            set: [read_at: now]
          )

        if updated != length(ids), do: repo().rollback(:signal_consumption_conflict)

        Audit.log("coordination.signal.read", agent_id, ids, %{
          topic: topic,
          memory_space_id: partition.memory_space_id,
          host_id: partition.host_id,
          client_id: partition.client_id,
          source_client_id: partition[:source_client_id],
          scope: partition.scope,
          namespace: partition.namespace,
          result: "read"
        })
      end

      signals
    end)
  end

  defp partition_dynamic(partition) when is_map(partition),
    do:
      dynamic(
        [row],
        row.memory_space_id == ^Map.fetch!(partition, :memory_space_id) and
          row.scope == ^Map.fetch!(partition, :scope) and
          row.namespace == ^Map.fetch!(partition, :namespace)
      )

  defp partition_attrs(partition) when is_map(partition),
    do:
      Map.take(partition, [
        :memory_space_id,
        :host_id,
        :client_id,
        :source_client_id,
        :scope,
        :namespace
      ])

  defp canonical_partition(partition) do
    with {:ok, partition} <- PartitionIdentity.validate(partition),
         host_id when is_binary(host_id) and host_id != "" <- partition[:host_id],
         client_id when is_binary(client_id) and client_id != "" <- partition[:client_id] do
      {:ok, partition}
    else
      _invalid -> {:error, :partition_required}
    end
  end
end
