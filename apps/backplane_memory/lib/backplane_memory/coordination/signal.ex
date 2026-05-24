defmodule BackplaneMemory.Coordination.Signal do
  @moduledoc "Point-to-point agent signals stored in memory_signals."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_signals" do
    field(:sender_agent_id, :string)
    field(:recipient_agent_id, :string)
    field(:topic, :string)
    field(:payload, :map, default: %{})
    field(:sent_at, :utc_datetime_usec)
    field(:read_at, :utc_datetime_usec)
  end

  def changeset(sig, attrs) do
    sig
    |> cast(attrs, [:sender_agent_id, :recipient_agent_id, :topic, :payload, :sent_at])
    |> validate_required([:sender_agent_id, :recipient_agent_id, :topic])
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Send a signal from sender to recipient."
  def send_signal(sender, recipient, topic, payload \\ %{}) do
    %__MODULE__{}
    |> changeset(%{
      sender_agent_id: sender,
      recipient_agent_id: recipient,
      topic: topic,
      payload: payload,
      sent_at: DateTime.utc_now()
    })
    |> repo().insert()
  end

  @doc "Read unread signals for agent (and optionally topic). Marks them read atomically."
  def read_signals(agent_id, topic \\ nil, limit \\ 20) do
    now = DateTime.utc_now()

    query =
      from(s in __MODULE__,
        where: s.recipient_agent_id == ^agent_id and is_nil(s.read_at),
        order_by: [asc: s.sent_at],
        limit: ^limit
      )

    query = if topic, do: where(query, [s], s.topic == ^topic), else: query

    repo().transaction(fn ->
      signals = repo().all(query)
      ids = Enum.map(signals, & &1.id)

      if ids != [] do
        repo().update_all(from(s in __MODULE__, where: s.id in ^ids), set: [read_at: now])
      end

      signals
    end)
  end
end
