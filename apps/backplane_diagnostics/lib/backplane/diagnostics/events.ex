defmodule Backplane.Diagnostics.Events do
  @moduledoc "Authenticates, stores, and acknowledges immutable host diagnostics events."

  import Ecto.Query

  alias Backplane.Diagnostics.{Outbox, Resolutions, Sources}
  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Redaction}
  alias Backplane.Repo

  defmodule Event do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_events" do
      field :source_id, :string
      field :event_id, :string
      field :producer_epoch, :string
      field :event_type, :string
      field :occurred_at, :utc_datetime_usec
      field :received_at, :utc_datetime_usec
      field :run_id, :string
      field :attempt_id, :string
      field :trace_id, :string
      field :git_sha, :string
      field :release, :string
      field :error_class, :string
      field :historical, :boolean, default: false
      field :body, :map
    end
  end

  defmodule Received do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_event_receipts" do
      field :source_id, :string, primary_key: true
      field :event_id, :string, primary_key: true
      field :producer_epoch, :string
      field :source_sequence, :integer
      field :forward_digest, :string
      field :received_at, :utc_datetime_usec
    end
  end

  defmodule Epoch do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_epochs" do
      field :source_id, :string, primary_key: true
      field :producer_epoch, :string, primary_key: true
      field :sealed_at, :utc_datetime_usec
    end
  end

  @doc "Independently commits each valid event and its projection work before returning its receipt."
  def ingest(host_id, batch_id, items) do
    Receipt.response(:remote, batch_id, Enum.map(items, &ingest_entry(host_id, &1)))
  end

  @doc "Imports one observation from a sealed epoch through the trusted operator boundary."
  def import_history(host_id, entry, actor)
      when is_binary(host_id) and is_binary(actor) and byte_size(actor) in 1..128 do
    with {:ok, event, _bytes, digest} <- Receipt.validate_entry(entry) do
      persist(host_id, event, digest, actor)
    end
  end

  @doc "Seals an epoch once the host has finished its delivery window and the projection queue is clear."
  def seal_epoch(host_id, source_id, epoch) when is_binary(host_id) do
    if Envelope.id?(source_id) and Envelope.id?(epoch) do
      Repo.transact(fn ->
        case Sources.lock_for_host(host_id, source_id) do
          %Sources.Source{} -> seal_locked_epoch(source_id, epoch)
          nil -> {:error, :unauthorized_source}
        end
      end)
    else
      {:error, :invalid_epoch}
    end
  end

  defp ingest_entry(host_id, entry) do
    with {:ok, event, _bytes, digest} <- Receipt.validate_entry(entry),
         {:ok, status} <- persist(host_id, event, digest) do
      Receipt.result(entry, status)
    else
      {:error, :unsupported_schema} ->
        Receipt.result(entry, "unsupported_schema")

      {:error, :persistence_unavailable} ->
        Receipt.result(entry, "retryable_rejection", :persistence_unavailable)

      {:error, reason} when reason in [:identity_conflict, :source_sequence_conflict] ->
        Receipt.result(entry, "identity_conflict", reason)

      {:error, reason} ->
        Receipt.result(entry, "permanent_rejection", reason)
    end
  end

  defp persist(host_id, event, digest, historical_actor \\ nil) do
    Repo.transact(
      fn ->
        host_id
        |> Sources.lock_for_host(event["source_id"])
        |> duplicate_or_store(event, digest, historical_actor)
      end,
      log: false
    )
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, Ecto.ConstraintError] ->
      {:error, :persistence_unavailable}
  end

  defp duplicate_or_store(source, event, digest, historical_actor) do
    if Sources.permits_event?(source, event) do
      case Repo.get_by(Received, source_id: source.id, event_id: event["event_id"]) do
        %Received{forward_digest: ^digest} -> {:ok, "duplicate"}
        %Received{} -> {:error, :identity_conflict}
        nil -> check_epoch_and_store(event, digest, historical_actor)
      end
    else
      {:error, :unauthorized_source}
    end
  end

  defp check_epoch_and_store(event, digest, historical_actor) do
    source_id = event["source_id"]
    epoch = event["producer_epoch"]
    sequence = event["source_sequence"]
    sealed? = Repo.get_by(Epoch, source_id: source_id, producer_epoch: epoch) != nil

    cond do
      sealed? and is_nil(historical_actor) ->
        {:error, :epoch_sealed}

      not sealed? and is_binary(historical_actor) ->
        {:error, :epoch_not_sealed}

      Repo.get_by(Received,
        source_id: source_id,
        producer_epoch: epoch,
        source_sequence: sequence
      ) ->
        {:error, :source_sequence_conflict}

      true ->
        store(event, digest, historical_actor)
    end
  end

  defp store(event, digest, historical_actor) do
    sanitized = Redaction.project(event)

    with :ok <- Envelope.validate(sanitized),
         {:ok, occurred_at, _offset} <- DateTime.from_iso8601(event["occurred_at"]) do
      received_at = DateTime.utc_now()

      Repo.insert!(
        %Received{
          source_id: event["source_id"],
          event_id: event["event_id"],
          producer_epoch: event["producer_epoch"],
          source_sequence: event["source_sequence"],
          forward_digest: digest,
          received_at: received_at
        },
        log: false
      )

      {microsecond, _precision} = occurred_at.microsecond

      record =
        Repo.insert!(
          %Event{
            source_id: sanitized["source_id"],
            event_id: sanitized["event_id"],
            producer_epoch: sanitized["producer_epoch"],
            event_type: sanitized["event_type"],
            occurred_at: %{occurred_at | microsecond: {microsecond, 6}},
            received_at: received_at,
            run_id: get_in(sanitized, ["subject", "run_id"]),
            attempt_id: get_in(sanitized, ["subject", "attempt_id"]),
            trace_id: get_in(sanitized, ["correlation", "trace_id"]),
            git_sha: get_in(sanitized, ["version", "git_sha"]),
            release: get_in(sanitized, ["version", "release"]),
            error_class: get_in(sanitized, ["result", "error_class"]),
            historical: is_binary(historical_actor),
            body: sanitized
          },
          log: false
        )

      if historical_actor do
        Resolutions.audit!(nil, "history_imported", historical_actor, record.id)
      else
        Outbox.insert!(record.id, received_at)
      end

      {:ok, "stored"}
    end
  end

  defp seal_locked_epoch(source_id, epoch) do
    pending =
      from event in Event,
        join: entry in Outbox.Entry,
        on: entry.event_key == event.id,
        where: event.source_id == ^source_id and event.producer_epoch == ^epoch

    if Repo.exists?(pending) do
      {:error, :projection_pending}
    else
      Repo.insert(
        %Epoch{source_id: source_id, producer_epoch: epoch, sealed_at: DateTime.utc_now()},
        on_conflict: :nothing,
        conflict_target: [:source_id, :producer_epoch]
      )
    end
  end
end
