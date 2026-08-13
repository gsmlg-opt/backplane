defmodule Backplane.Memory.Workers.SummaryWorker do
  @moduledoc "Builds deterministic, revisioned summaries from canonical projections."

  use Oban.Worker,
    queue: :memory,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:host_id, :session_id, :input_revision]
    ]

  import Ecto.Query

  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.{ReadModels, Revision, Source, State}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{CrystalWorker, EpisodicWorker}

  @processing_version "summary-v1"
  @subject_type "captured_session"

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "host_id" => host_id,
            "session_id" => session_id,
            "processing_version" => @processing_version,
            "input_revision" => expected_revision
          } = args
      }) do
    Backplane.Memory.PipelineTelemetry.span("summary", args, fn ->
      if valid_identifier?(host_id) and valid_identifier?(session_id) and
           valid_identifier?(expected_revision) do
        perform_canonical(host_id, session_id, expected_revision)
      else
        {:cancel, :invalid_arguments}
      end
    end)
  end

  # Explicitly isolated compatibility for legacy jobs and callers. Canonical jobs
  # above never enter this branch and therefore never read legacy tables.
  def perform(%Oban.Job{args: %{"session_id" => session_id} = args})
      when is_binary(session_id) and map_size(args) == 1 do
    Backplane.Memory.PipelineTelemetry.span("summary.legacy", args, fn ->
      perform_legacy(session_id)
    end)
  end

  def perform(%Oban.Job{args: args}) do
    Backplane.Memory.PipelineTelemetry.span("summary", args, fn ->
      {:cancel, :invalid_arguments}
    end)
  end

  @doc "Enqueues the legacy session-only compatibility job."
  def enqueue(session_id) when is_binary(session_id) do
    %{session_id: session_id}
    |> new(unique: [period: :infinity, states: :all, keys: [:session_id]])
    |> Oban.insert()
  end

  @doc "Enqueues a canonical summary revision."
  def enqueue(host_id, session_id, input_revision)
      when is_binary(host_id) and is_binary(session_id) and is_binary(input_revision) do
    subject_id = Source.subject_id!(host_id, session_id)

    case repo().transaction(fn ->
           Source.lock_streams(host_id, session_id)
           lock_subject(subject_id)
           mark_pending(subject_id, input_revision)

           %{
             host_id: host_id,
             session_id: session_id,
             processing_version: @processing_version,
             input_revision: input_revision
           }
           |> new()
           |> Oban.insert()
           |> case do
             {:ok, job} -> job
             {:error, reason} -> repo().rollback(reason)
           end
         end) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_canonical(host_id, session_id, expected_revision) do
    case ReadModels.summary_input(host_id, session_id, limit: 100, allow_incomplete: true) do
      {:ok, %{input_revision: ^expected_revision} = input} ->
        if summary_ready?(input) do
          persist_canonical(host_id, session_id, expected_revision)
        else
          :ok
        end

      {:ok, _newer_input} ->
        :ok

      {:error, reason}
      when reason in [:not_found, :session_not_closed, :projection_incomplete] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_canonical(host_id, session_id, expected_revision) do
    subject_id = Source.subject_id!(host_id, session_id)

    result =
      repo().transaction(fn ->
        Source.lock_streams(host_id, session_id)
        lock_subject(subject_id)

        with {:ok, %{input_revision: ^expected_revision}} <-
               Source.input_revision(host_id, session_id),
             {:ok, %{input_revision: ^expected_revision} = input} <-
               ReadModels.summary_input(host_id, session_id,
                 limit: 100,
                 allow_incomplete: true
               ),
             true <- summary_ready?(input) do
          state = mark_running(subject_id, expected_revision)
          attrs = summary_attrs(input)
          summary = store_summary(subject_id, attrs)
          store_summary_sources(summary, input)
          complete_state(state, expected_revision, attrs.output_revision)
          summary
        else
          {:ok, _newer_input} -> repo().rollback(:stale_input_revision)
          false -> repo().rollback(:gap_grace_pending)
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, %Summary{} = summary} ->
        with {:ok, _episodic_job} <- EpisodicWorker.enqueue_summary(summary.id),
             {:ok, _crystal_job} <-
               CrystalWorker.enqueue(host_id, session_id, expected_revision) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason}
      when reason in [
             :stale_input_revision,
             :gap_grace_pending,
             :not_found,
             :session_not_closed,
             :projection_incomplete
           ] ->
        :ok

      {:error, reason} ->
        record_failed(host_id, session_id, subject_id, expected_revision, reason)
        {:error, reason}
    end
  rescue
    exception ->
      subject_id = Source.subject_id!(host_id, session_id)
      record_failed(host_id, session_id, subject_id, expected_revision, exception)
      reraise exception, __STACKTRACE__
  end

  defp summary_attrs(input) do
    counts = input.counts
    observations = input.observations
    errors = input.errors

    header =
      [
        "Session #{input.session_id}",
        "host=#{input.host_id}",
        "project=#{if input.project == "", do: "unknown", else: input.project}",
        "status=#{input.status}",
        "started_at=#{format_time(input.started_at)}",
        "ended_at=#{format_time(input.ended_at)}",
        "source_complete=#{input.source_complete}",
        "source_gap_count=#{length(input.source_gaps)}",
        "source_gaps=#{format_gaps(input.source_gaps)}",
        "events=#{counts["events"] || 0}",
        "tools=#{counts["tools"] || 0}",
        "errors=#{counts["errors"] || 0}",
        "tool_counts=#{format_counts(counts["by_tool"] || %{})}",
        "file_counts=#{file_counts(observations ++ errors)}",
        "commits=#{commits(observations ++ errors)}"
      ]
      |> Enum.join(" | ")

    lines =
      Enum.map(observations, fn observation ->
        metadata =
          [
            observation.event_type,
            observation.tool_name,
            Enum.join(observation.file_paths || [], ","),
            observation.commit_hash
          ]
          |> Enum.filter(&valid_identifier?/1)
          |> Enum.join(" | ")

        "[observation importance=#{observation.importance || 0} | #{metadata}] #{String.slice(observation.content, 0, 500)}"
      end)

    error_lines =
      Enum.map(errors, fn error ->
        detail = error.message || error.content

        "[error importance=#{error.importance || 0} | #{error.event_type}] #{String.slice(detail, 0, 500)}"
      end)

    content = Enum.join([header | lines ++ error_lines], "\n---\n")

    output = %{
      "content" => content,
      "input_revision" => input.input_revision,
      "processing_version" => @processing_version,
      "source_event_count" => counts["events"] || 0,
      "source_complete" => input.source_complete,
      "source_gaps" => input.source_gaps
    }

    {:ok, output_revision} = Revision.output_revision(output)

    %{
      session_id: input.session_id,
      project: input.project,
      content: content,
      observation_count: length(observations),
      subject_id: input.subject_id,
      host_id: input.host_id,
      agent_id: input.agent_id,
      processing_version: @processing_version,
      input_revision: input.input_revision,
      output_revision: output_revision,
      source_complete: input.source_complete,
      source_gap_count: length(input.source_gaps),
      source_gaps: %{"ranges" => input.source_gaps}
    }
  end

  defp store_summary_sources(summary, input) do
    repo().query!(
      """
      INSERT INTO memory_summary_source_events
        (summary_id, event_id, host_id, session_id, inserted_at)
      SELECT $1::uuid, event.id, $2, $3, now()
      FROM bpm_events AS event
      WHERE event.schema_version IS NOT NULL
        AND event.host_id = $2
        AND event.session_id = $3
      ORDER BY event.source_sequence, event.event_type, event.id
      ON CONFLICT (summary_id, event_id) DO NOTHING
      """,
      [Ecto.UUID.dump!(summary.id), input.host_id, input.session_id]
    )

    expected_count = input.counts["events"] || 0

    actual_count =
      repo().aggregate(from(link in SourceEvent, where: link.summary_id == ^summary.id), :count)

    if actual_count != expected_count, do: repo().rollback(:source_provenance_mismatch)
  end

  defp store_summary(subject_id, attrs) do
    case current_summary(subject_id) do
      nil ->
        %Summary{} |> Summary.changeset(attrs) |> repo().insert!()

      %Summary{input_revision: input_revision, output_revision: output_revision} = summary
      when input_revision == attrs.input_revision and output_revision == attrs.output_revision ->
        summary

      %Summary{input_revision: input_revision} when input_revision == attrs.input_revision ->
        repo().rollback(:nondeterministic_summary_output)

      %Summary{} = previous ->
        supersede(previous, attrs.input_revision)
        %Summary{} |> Summary.changeset(attrs) |> repo().insert!()
    end
  end

  defp current_summary(subject_id) do
    repo().one(
      from(s in Summary,
        where: s.subject_id == ^subject_id and s.processing_version == @processing_version,
        lock: "FOR UPDATE"
      )
    )
  end

  defp supersede(summary, successor_revision) do
    summary
    |> Summary.changeset(%{
      processing_version: "#{@processing_version}@#{summary.input_revision}",
      superseded_at: now(),
      superseded_by_input_revision: successor_revision
    })
    |> repo().update!()
  end

  defp mark_running(subject_id, input_revision) do
    attrs = %{
      projector: "summary",
      subject_type: @subject_type,
      subject_id: subject_id,
      processing_version: @processing_version,
      input_revision: input_revision,
      output_revision: nil,
      status: "running",
      last_error: nil,
      started_at: now(),
      completed_at: nil
    }

    case locked_state(subject_id) do
      nil ->
        %State{}
        |> State.changeset(Map.put(attrs, :attempt_count, 1))
        |> repo().insert!()

      state ->
        state
        |> State.changeset(Map.put(attrs, :attempt_count, state.attempt_count + 1))
        |> repo().update!()
    end
  end

  defp mark_pending(subject_id, input_revision) do
    attrs = %{
      projector: "summary",
      subject_type: @subject_type,
      subject_id: subject_id,
      processing_version: @processing_version,
      input_revision: input_revision,
      output_revision: nil,
      status: "pending",
      attempt_count: 0,
      last_error: nil,
      started_at: nil,
      completed_at: nil
    }

    case locked_state(subject_id) do
      nil ->
        %State{} |> State.changeset(attrs) |> repo().insert!()

      %State{status: status, input_revision: ^input_revision}
      when status in ["pending", "running", "complete"] ->
        :ok

      state ->
        state
        |> State.changeset(Map.put(attrs, :attempt_count, state.attempt_count))
        |> repo().update!()
    end
  end

  defp complete_state(state, input_revision, output_revision) do
    state
    |> State.changeset(%{
      status: "complete",
      input_revision: input_revision,
      output_revision: output_revision,
      last_error: nil,
      completed_at: now()
    })
    |> repo().update!()
  end

  @doc false
  def record_failed(host_id, session_id, subject_id, input_revision, reason) do
    error = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)

    try do
      repo().transaction(fn ->
        Source.lock_streams(host_id, session_id)
        lock_subject(subject_id)

        case Source.input_revision(host_id, session_id) do
          {:ok, %{input_revision: ^input_revision}} ->
            write_failed_state(subject_id, input_revision, error)

          _stale_or_unavailable ->
            :ok
        end
      end)
    rescue
      _exception -> :ok
    end

    :ok
  end

  defp write_failed_state(subject_id, input_revision, error) do
    attrs = %{
      projector: "summary",
      subject_type: @subject_type,
      subject_id: subject_id,
      processing_version: @processing_version,
      input_revision: input_revision,
      output_revision: nil,
      status: "failed",
      last_error: error,
      started_at: now(),
      completed_at: now()
    }

    case locked_state(subject_id) do
      %State{status: "complete", input_revision: ^input_revision} ->
        :ok

      nil ->
        %State{}
        |> State.changeset(Map.put(attrs, :attempt_count, 1))
        |> repo().insert!()

      %State{input_revision: ^input_revision} = state ->
        state
        |> State.changeset(Map.put(attrs, :attempt_count, state.attempt_count + 1))
        |> repo().update!()

      _newer_state ->
        :ok
    end
  end

  defp locked_state(subject_id) do
    repo().one(
      from(s in State,
        where:
          s.projector == "summary" and s.subject_type == @subject_type and
            s.subject_id == ^subject_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_subject(subject_id) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [subject_id])
  end

  defp perform_legacy(session_id) do
    case repo().one(from(s in Session, where: s.session_id == ^session_id)) do
      nil ->
        :ok

      %Session{} = session ->
        observations =
          repo().all(
            from(o in Observation,
              where: o.session_id == ^session_id and not o.is_error,
              order_by: [desc: fragment("length(?)", o.content), asc: o.id],
              limit: 20
            )
          )

        if observations == [] do
          mark_legacy_consolidated(session_id)
          :ok
        else
          attrs = %{
            session_id: session_id,
            project: session.project || "",
            content: build_legacy_summary(session, observations),
            observation_count: length(observations)
          }

          changeset = Summary.changeset(%Summary{}, attrs)

          case repo().insert(changeset,
                 on_conflict: :nothing,
                 conflict_target: [:subject_id, :processing_version]
               ) do
            {:ok, _} ->
              mark_legacy_consolidated(session_id)
              EpisodicWorker.enqueue(session_id)
              :ok

            {:error, changeset} ->
              {:error, changeset}
          end
        end
    end
  end

  defp build_legacy_summary(session, observations) do
    header =
      "Session #{session.session_id} (project: #{session.project || "unknown"}) — #{length(observations)} observations"

    lines = Enum.map(observations, &String.slice(&1.content, 0, 500))
    Enum.join([header | lines], "\n---\n")
  end

  defp mark_legacy_consolidated(session_id) do
    repo().update_all(
      from(s in Session, where: s.session_id == ^session_id),
      set: [consolidated_at: now()]
    )
  end

  defp valid_identifier?(value), do: is_binary(value) and String.trim(value) != ""
  defp format_counts(counts), do: format_frequency_pairs(counts)

  defp file_counts(observations) do
    observations
    |> Enum.flat_map(&(&1.file_paths || []))
    |> Enum.frequencies()
    |> format_frequency_pairs()
  end

  defp format_frequency_pairs(counts) do
    counts
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Enum.map_join(",", fn {key, count} -> "#{key}=#{count}" end)
    |> empty_as("none")
  end

  defp commits(observations) do
    observations
    |> Enum.map(& &1.commit_hash)
    |> Enum.filter(&valid_identifier?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
    |> empty_as("none")
  end

  defp empty_as("", fallback), do: fallback
  defp empty_as(value, _fallback), do: value
  defp format_time(nil), do: "unknown"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value), do: to_string(value)
  defp format_gaps([]), do: "none"

  defp format_gaps(gaps) do
    Enum.map_join(gaps, ",", fn %{"from" => first, "to" => last} ->
      "#{first}-#{last}"
    end)
  end

  defp summary_ready?(%{source_complete: true}), do: true

  defp summary_ready?(%{last_event_at: %DateTime{} = last_event_at}) do
    DateTime.diff(now(), last_event_at, :second) >= Config.event_gap_grace_seconds()
  end

  defp summary_ready?(_input), do: false
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
