defmodule Backplane.Memory.Workers.WindowSummaryWorker do
  @moduledoc "Deterministic evidence windows over at most 100 durable events in one stream."

  use Styx.Worker, queue: :memory, max_attempts: 3
  import Ecto.Query

  alias Backplane.Memory.{Config, PartitionIdentity}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProcessingState, ProjectedSession, Revision, Source, State}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.StageResumeWorker

  @version "window-summary-v1"
  @page_size 100

  def enqueue(host_id, session_id, revision, partition, opts \\ []) do
    with {:ok, partition} <- PartitionIdentity.validate_generator(partition),
         %ProjectedSession{input_revision: ^revision} = session <-
           repo().get(ProjectedSession, Source.subject_id!(host_id, session_id)),
         {:ok, _} <- PartitionIdentity.validate_generator(partition, Map.from_struct(session)) do
      insert(
        Map.merge(partition, %{
          mode: "enumerate",
          session_id: session_id,
          input_revision: revision,
          retry_failed: opts[:retry_failed] == true,
          resume_enumeration: resumable_windows?(session, opts)
        })
      )
    else
      nil -> {:error, :not_found}
      %ProjectedSession{} -> {:error, :stale_input_revision}
      {:error, _} = error -> error
    end
  end

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"mode" => "enumerate", "session_id" => session} = args})
      when is_binary(session) and session != "" do
    with {:ok, partition} <- PartitionIdentity.validate_generator(args),
         {:ok, cursor} <- cursor(args["cursor"]) do
      enumerate(args, partition, cursor)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(
        %Styx.Job{
          args:
            %{
              "mode" => "window",
              "session_id" => session,
              "stream_id" => stream,
              "bucket" => bucket,
              "input_revision" => revision
            } = args
        } = job
      )
      when is_binary(session) and session != "" and is_binary(stream) and stream != "" and
             is_integer(bucket) and bucket >= 0 and is_binary(revision) do
    with {:ok, partition} <- PartitionIdentity.validate_generator(args) do
      perform_window(job, args, partition)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  defp perform_window(job, args, partition) do
    case repo().transaction(fn -> persist_window(args, partition) end) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        record_failure(job, args, partition)
        {:error, reason}
    end
  rescue
    exception ->
      record_failure(job, args, partition)
      reraise exception, __STACKTRACE__
  end

  defp record_failure(job, args, partition) do
    # A failed output transaction also rolls back its running transition. Record
    # that attempt separately, under the same source fence, without hiding errors.
    repo().transaction(fn ->
      Source.lock_streams(partition.host_id, args["session_id"])
      events = events(partition, args["session_id"], args["stream_id"], args["bucket"])
      attrs = processing_attrs(args, partition, Revision.input_revision(events))

      if events != [] and attrs.input_revision == args["input_revision"] and
           not StageResumeWorker.complete?(attrs) do
        transition(attrs, "running")
        transition(attrs, ProcessingState.failure_status(job), reason: :window_persistence_failed)
      end
    end)
  rescue
    _exception -> :ok
  end

  defp enumerate(args, partition, cursor) do
    query =
      from(e in Event,
        where: not is_nil(e.schema_version),
        where:
          e.memory_space_id == ^partition.memory_space_id and e.host_id == ^partition.host_id and
            e.client_id == ^partition.client_id and e.scope == ^partition.scope and
            e.namespace == ^partition.namespace and e.session_id == ^args["session_id"],
        group_by: [e.stream_id, fragment("(? - 1) / 100", e.sequence)],
        order_by: [asc: e.stream_id, asc: fragment("(? - 1) / 100", e.sequence)],
        limit: ^@page_size,
        select: {e.stream_id, fragment("(? - 1) / 100", e.sequence)}
      )

    query =
      case cursor do
        nil ->
          query

        [stream, bucket] ->
          where(
            query,
            [e],
            fragment(
              "ROW(?, (? - 1) / 100) > ROW(?, ?)",
              e.stream_id,
              e.sequence,
              ^stream,
              type(^bucket, :integer)
            )
          )
      end

    windows = repo().all(query)

    Enum.reduce_while(windows, :ok, fn {stream, bucket}, :ok ->
      events = events(partition, args["session_id"], stream, bucket)

      next =
        args
        |> Map.drop(["cursor"])
        |> Map.merge(%{
          "mode" => "window",
          "stream_id" => stream,
          "bucket" => bucket,
          "input_revision" => Revision.input_revision(events)
        })

      attrs = processing_attrs(next, partition, next["input_revision"])

      result =
        if StageResumeWorker.eligible?(attrs, retry_failed: args["retry_failed"] == true),
          do: insert(next),
          else: {:ok, :ineligible}

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok when length(windows) == @page_size ->
        {stream, bucket} = List.last(windows)

        case insert(Map.put(args, "cursor", [stream, bucket])) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      result ->
        result
    end
  end

  defp persist_window(args, partition) do
    Source.lock_streams(partition.host_id, args["session_id"])
    events = events(partition, args["session_id"], args["stream_id"], args["bucket"])
    revision = Revision.input_revision(events)

    attrs = processing_attrs(args, partition, revision)

    cond do
      events == [] or revision != args["input_revision"] ->
        :stale

      StageResumeWorker.complete?(attrs) ->
        :complete

      not Config.window_summaries_enabled?() ->
        transition(attrs, "skipped_disabled", reason: :disabled)

      true ->
        transition(attrs, "running")
        summary = store_summary(attrs, events, args)

        links =
          Enum.map(
            events,
            &%{
              summary_id: summary.id,
              event_id: &1.id,
              host_id: partition.host_id,
              session_id: args["session_id"],
              inserted_at: now()
            }
          )

        repo().insert_all(SourceEvent, links, on_conflict: :nothing)
        transition(Map.put(attrs, :output_revision, summary.output_revision), "complete")
        summary
    end
  end

  defp processing_attrs(args, partition, revision) do
    subject =
      window_subject(partition.host_id, args["session_id"], args["stream_id"], args["bucket"])

    Map.merge(
      Map.take(partition, [:memory_space_id, :host_id, :source_client_id, :scope, :namespace]),
      %{
        projector: "window_summary",
        subject_type: "captured_session_window",
        subject_id: subject,
        processing_version: @version,
        input_revision: revision,
        output_revision: nil
      }
    )
  end

  defp store_summary(attrs, events, args) do
    # Durable stream sequence is unique. Captured source_sequence may repeat across event types.
    # Fixed stream intervals therefore retain a hard 100-event bound even for late capture.
    first = args["bucket"] * 100 + 1

    header =
      "generation_mode=deterministic | generation_reason=evidence_window | " <>
        "stream=#{args["stream_id"]} | stream_sequence=#{first}-#{first + 99}"

    content =
      Enum.map_join(events, "\n", fn event ->
        text = event.content || event.payload["message"] || Jason.encode!(event.payload)
        text = if is_binary(text), do: text, else: Jason.encode!(text)

        "[#{event.event_type} source_sequence=#{event.source_sequence}] #{String.slice(text, 0, 500)}"
      end)

    content = header <> "\n" <> content

    {:ok, output_revision} =
      Revision.output_revision(%{"content" => content, "input_revision" => attrs.input_revision})

    current =
      repo().one(
        from(s in Summary,
          where:
            s.subject_id == ^attrs.subject_id and
              s.processing_version == ^@version,
          lock: "FOR UPDATE"
        )
      )

    if current do
      current
      |> Summary.changeset(%{
        processing_version: @version <> "@" <> current.input_revision,
        superseded_at: now(),
        superseded_by_input_revision: attrs.input_revision
      })
      |> repo().update!()
    end

    %Summary{}
    |> Summary.changeset(
      Map.merge(attrs, %{
        session_id: args["session_id"],
        project: hd(events).project || "",
        agent_id: hd(events).agent_id,
        content: content,
        observation_count: length(events),
        output_revision: output_revision,
        source_complete: true,
        source_gap_count: 0,
        source_gaps: %{"ranges" => []}
      })
    )
    |> repo().insert!()
  end

  defp events(partition, session, stream, bucket) do
    first = bucket * 100 + 1

    repo().all(
      from(e in Event,
        where:
          not is_nil(e.schema_version) and e.memory_space_id == ^partition.memory_space_id and
            e.host_id == ^partition.host_id and e.client_id == ^partition.client_id and
            e.scope == ^partition.scope and e.namespace == ^partition.namespace and
            e.session_id == ^session and e.stream_id == ^stream and
            e.sequence >= ^first and e.sequence < ^(first + 100),
        order_by: [asc: e.source_sequence, asc: e.event_type, asc: e.id],
        limit: 100
      )
    )
  end

  defp transition(attrs, status, opts \\ []) do
    case ProcessingState.transition(
           repo(),
           attrs,
           status,
           Keyword.put(opts, :authoritative_revision, true)
         ) do
      {:ok, state} -> state
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp window_subject(host, session, stream, bucket),
    do:
      Source.subject_id!(host, session) <>
        ":window:" <> Base.url_encode64(stream, padding: false) <> ":#{bucket}"

  defp cursor(nil), do: {:ok, nil}

  defp cursor([stream, bucket] = cursor)
       when is_binary(stream) and stream != "" and is_integer(bucket) and bucket >= 0,
       do: {:ok, cursor}

  defp cursor(_), do: {:error, :invalid_arguments}

  defp resumable_windows?(session, opts) do
    statuses =
      if opts[:retry_failed],
        do: ~w(skipped_disabled failed dead_letter),
        else: ["skipped_disabled"]

    prefix = session.subject_id <> ":window:"

    repo().exists?(
      from(s in State,
        where:
          s.projector == "window_summary" and s.subject_type == "captured_session_window" and
            s.memory_space_id == ^session.memory_space_id and s.host_id == ^session.host_id and
            s.scope == ^session.scope and s.namespace == ^session.namespace and
            fragment("starts_with(?, ?)", s.subject_id, ^prefix) and s.status in ^statuses
      )
    )
  end

  defp insert(args) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)

    # An unchanged enumeration is durable even after its job completes. Only
    # skipped work or an explicit failed-stage retry opens another enumeration.
    states =
      if args["mode"] == "enumerate" and args["resume_enumeration"] != true,
        do: :all,
        else: :incomplete

    args
    |> new(
      unique: [
        period: :infinity,
        states: states,
        keys: [
          :memory_space_id,
          :host_id,
          :session_id,
          :mode,
          :stream_id,
          :bucket,
          :input_revision,
          :cursor
        ]
      ]
    )
    |> Styx.insert()
    |> case do
      {:ok, %Styx.Job{conflict?: true, state: state}}
      when state in ["completed", "discarded", "cancelled"] ->
        {:ok, :already_enumerated}

      result ->
        result
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
