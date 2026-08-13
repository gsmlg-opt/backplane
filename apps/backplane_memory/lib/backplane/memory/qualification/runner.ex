defmodule Backplane.Memory.Qualification.Runner do
  @moduledoc "Reproducible, bounded workloads for Memory V2 M18 qualification."

  import Ecto.Query

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Ingest.EventValidator
  alias Backplane.Memory.Projections.{Rebuild, Source, State}
  alias Backplane.Memory.Qualification
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{ProjectionRepairWorker, SummaryWorker}

  @max_batch_size 100

  def run(opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "m18-#{System.unique_integer([:positive])}")

    with {:ok, ingest} <-
           measure_ingest(
             run_id: "#{run_id}-ingest",
             event_count: 1_000,
             batch_size: 50,
             warmup_event_count: 500
           ),
         {:ok, projection} <-
           measure_projection(run_id: "#{run_id}-projection", sample_count: 100),
         {:ok, consolidation} <-
           measure_consolidation(run_id: "#{run_id}-consolidation", session_count: 20),
         {:ok, outage} <- measure_outage(run_id: "#{run_id}-outage", event_count: 100),
         {:ok, resilience} <-
           measure_resilience(
             run_id: "#{run_id}-resilience",
             event_count: 100,
             contention_workers: 4
           ) do
      measurements = %{
        ingest: ingest,
        projection: projection,
        consolidation: consolidation,
        outage: outage,
        resilience: resilience
      }

      {:ok,
       Qualification.evaluate(measurements,
         configuration: %{
           command: "MIX_ENV=test mix memory.qualify --report <path>",
           runtime: %{
             elixir: System.version(),
             otp: List.to_string(:erlang.system_info(:otp_release)),
             schedulers_online: System.schedulers_online()
           },
           workload: %{
             ingest_events: 1_000,
             ingest_warmup_events: 500,
             ingest_batch_size: 50,
             projection_samples: 100,
             eligible_sessions: 20,
             outage_events: 100,
             outage_simulated_hours: 24,
             resilience_events: 100,
             contention_workers: 4
           },
           cross_release_outage_test:
             "apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs"
         }
       )}
    end
  end

  def sandboxed_run(opts \\ []) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
    Ecto.Adapters.SQL.Sandbox.mode(repo(), {:shared, self()})

    try do
      run(opts)
    after
      Ecto.Adapters.SQL.Sandbox.checkin(repo())
    end
  end

  def measure_ingest(opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    event_count = Keyword.get(opts, :event_count, 500)
    batch_size = Keyword.get(opts, :batch_size, @max_batch_size)

    with :ok <- validate_count(event_count),
         :ok <- validate_batch_size(batch_size),
         :ok <- maybe_warm_ingest(run_id, event_count, batch_size, opts) do
      host_id = "m18-ingest-#{run_id}"
      auth = auth_context(host_id)

      events =
        Enum.map(1..event_count, fn index ->
          batch_number = div(index - 1, batch_size) + 1
          source_sequence = rem(index - 1, batch_size) + 1

          event(host_id, run_id, index,
            session_id: "#{run_id}-batch-#{batch_number}",
            source_sequence: source_sequence
          )
        end)

      started_at = System.monotonic_time()

      batches = Enum.chunk_every(events, batch_size)
      concurrency = length(batches)

      results =
        with_projection_repair(fn ->
          Oban.Testing.with_testing_mode(:manual, fn ->
            batches
            |> Task.async_stream(
              fn batch ->
                Oban.Testing.with_testing_mode(:manual, fn ->
                  Ingest.ingest_batch(auth, %{
                    "batch_id" => Ecto.UUID.generate(),
                    "host_id" => host_id,
                    "events" => batch
                  })
                end)
              end,
              max_concurrency: concurrency,
              ordered: true,
              timeout: 60_000
            )
            |> Enum.flat_map(fn {:ok, {:ok, %{"results" => batch_results}}} -> batch_results end)
          end)
        end)

      elapsed_native = max(System.monotonic_time() - started_at, 1)

      elapsed_seconds =
        System.convert_time_unit(elapsed_native, :native, :microsecond) / 1_000_000

      accepted = Enum.count(results, &(&1["status"] == "accepted"))

      persisted =
        repo().aggregate(from(event in Event, where: event.correlation_id == ^run_id), :count)

      distinct_effects =
        repo().one(
          from(event in Event,
            where: event.correlation_id == ^run_id,
            select: count(fragment("DISTINCT ?", event.id))
          )
        )

      event_ids = Enum.map(events, & &1["event_id"])
      projection_jobs = projection_jobs(event_ids)
      projection_job_event_ids = Enum.map(projection_jobs, & &1.args["event_id"])

      # Qualification runs inside a rollback sandbox. Remove only this workload's queued jobs
      # after proving that production ingestion committed them, so later workload measurements
      # can control exactly which jobs they execute.
      cleanup_projection_jobs(projection_jobs)

      {:ok,
       %{
         accepted: accepted,
         persisted: persisted,
         duplicate_effects: persisted - distinct_effects,
         events_per_second: accepted / elapsed_seconds,
         elapsed_ms: elapsed_seconds * 1_000,
         batch_size: batch_size,
         batch_count: length(batches),
         concurrency: concurrency,
         projection_jobs_durable: length(projection_jobs),
         projection_job_event_ids_unique:
           projection_job_event_ids |> MapSet.new() |> MapSet.size(),
         measured_path:
           "Ingest.ingest_batch -> Events.Store.append_batch_tagged -> Oban projection job commit"
       }}
    end
  end

  defp maybe_warm_ingest(run_id, event_count, batch_size, opts) do
    if Keyword.get(opts, :warmup, true) do
      warmup_event_count = Keyword.get(opts, :warmup_event_count, event_count)

      case measure_ingest(
             run_id: "#{run_id}-warmup",
             event_count: warmup_event_count,
             batch_size: batch_size,
             warmup: false
           ) do
        {:ok, _measurement} -> :ok
        {:error, reason} -> {:error, {:ingest_warmup_failed, reason}}
      end
    else
      :ok
    end
  end

  def measure_projection(opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    sample_count = Keyword.get(opts, :sample_count, 100)

    with :ok <- validate_count(sample_count) do
      host_id = "m18-projection-#{run_id}"
      auth = auth_context(host_id)
      events = Enum.map(1..sample_count, &event(host_id, run_id, &1))

      {ingest_result, acknowledged_at} =
        with_projection_repair(fn ->
          result =
            Oban.Testing.with_testing_mode(:manual, fn ->
              Ingest.ingest_batch(auth, %{
                "batch_id" => Ecto.UUID.generate(),
                "host_id" => host_id,
                "events" => events
              })
            end)

          {result, System.monotonic_time()}
        end)

      {:ok, %{"results" => results}} = ingest_result

      if Enum.all?(results, &(&1["status"] == "accepted")) do
        event_by_id = Map.new(events, &{&1["event_id"], &1})
        jobs = projection_jobs(Map.keys(event_by_id))

        with true <- length(jobs) == sample_count,
             {:ok, lags, complete_subjects, projectors, jobs_completed} <-
               Oban.Testing.with_testing_mode(:manual, fn ->
                 execute_projection_jobs(jobs, event_by_id, acknowledged_at)
               end) do
          lag_values = Enum.map(lags, & &1.lag_ms)

          {:ok,
           %{
             samples: length(lag_values),
             jobs_durable: length(jobs),
             jobs_completed: jobs_completed,
             complete_subjects: complete_subjects,
             projectors: projectors |> MapSet.to_list() |> Enum.sort(),
             p95_lag_ms: percentile(lag_values, 95),
             max_lag_ms: Enum.max(lag_values),
             worker: inspect(ProjectionRepairWorker),
             queue_execution: "Oban manual drain through production worker",
             measurement:
               "ingest acknowledgement to ProjectionRepairWorker job and projection-state completion"
           }}
        else
          false -> {:error, :projection_jobs_not_durable}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :projection_fixture_ingest_failed}
      end
    end
  end

  def measure_consolidation(opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_count = Keyword.get(opts, :session_count, 20)

    with :ok <- validate_count(session_count) do
      host_id = "m18-consolidation-#{run_id}"
      auth = auth_context(host_id)
      base_time = DateTime.add(DateTime.utc_now(), -300, :second)

      events =
        1..session_count
        |> Enum.flat_map(fn session_number ->
          session_id = "#{run_id}-closed-#{session_number}"

          Enum.map(
            [
              {1, "agent.session.started"},
              {2, "agent.prompt.submitted"},
              {3, "agent.session.ended"}
            ],
            fn {sequence, event_type} ->
              event(host_id, run_id, session_number * 10 + sequence,
                session_id: session_id,
                source_sequence: sequence,
                event_type: event_type,
                occurred_at: DateTime.add(base_time, sequence, :second)
              )
            end
          )
        end)

      {:ok, %{"results" => results}} =
        Ingest.ingest_batch(auth, %{
          "batch_id" => Ecto.UUID.generate(),
          "host_id" => host_id,
          "events" => events
        })

      if Enum.all?(results, &(&1["status"] == "accepted")) do
        Enum.each(1..session_count, fn session_number ->
          session_id = "#{run_id}-closed-#{session_number}"
          {:ok, projection} = Rebuild.session(host_id, session_id)

          :ok =
            SummaryWorker.perform(%Oban.Job{
              args: %{
                "host_id" => host_id,
                "session_id" => session_id,
                "processing_version" => "summary-v1",
                "input_revision" => projection.input_revision
              }
            })
        end)

        summaries = repo().all(from(summary in Summary, where: summary.host_id == ^host_id))

        summarized_within_four_hours =
          Enum.count(summaries, fn summary ->
            DateTime.diff(summary.created_at, base_time, :second) <= 4 * 60 * 60
          end)

        without_provenance =
          Enum.count(summaries, fn summary ->
            repo().aggregate(
              from(source in SourceEvent, where: source.summary_id == ^summary.id),
              :count
            ) == 0
          end)

        {:ok,
         %{
           eligible: session_count,
           summarized_within_four_hours: summarized_within_four_hours,
           coverage: summarized_within_four_hours / session_count,
           without_provenance: without_provenance,
           window_seconds: 4 * 60 * 60
         }}
      else
        {:error, :consolidation_fixture_ingest_failed}
      end
    end
  end

  def measure_resilience(opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    event_count = Keyword.get(opts, :event_count, 100)
    contention_workers = Keyword.get(opts, :contention_workers, 4)

    with :ok <- validate_count(event_count),
         :ok <- validate_contention_workers(contention_workers),
         true <- event_count <= @max_batch_size do
      host_id = "m18-resilience-#{run_id}"
      auth = auth_context(host_id)
      events = Enum.map(1..event_count, &event(host_id, run_id, &1))
      batch = %{"batch_id" => run_id, "host_id" => host_id, "events" => events}

      {:ok, %{"results" => failed_results}} =
        Ingest.ingest_batch(auth, batch,
          store: Backplane.Memory.Qualification.TransientBatchStore
        )

      retryable_failures_observed =
        Enum.count(failed_results, fn result ->
          result["status"] == "failed" and result["retryable"] == true
        end)

      delivery_results =
        1..contention_workers
        |> Task.async_stream(
          fn _worker -> Ingest.ingest_batch(auth, batch) end,
          max_concurrency: contention_workers,
          ordered: false,
          timeout: 60_000
        )
        |> Enum.flat_map(fn {:ok, {:ok, %{"results" => results}}} -> results end)

      persisted =
        repo().aggregate(from(event in Event, where: event.correlation_id == ^run_id), :count)

      distinct_effects =
        repo().one(
          from(event in Event,
            where: event.correlation_id == ^run_id,
            select: count(fragment("DISTINCT ?", event.id))
          )
        )

      {:ok,
       %{
         accepted: Enum.count(delivery_results, &(&1["status"] == "accepted")),
         persisted: persisted,
         duplicate_deliveries: Enum.count(delivery_results, &(&1["status"] == "duplicate")),
         duplicate_effects: persisted - distinct_effects,
         retryable_failures_observed: retryable_failures_observed,
         permanent_failures:
           Enum.count(delivery_results, &(&1["status"] in ["failed", "rejected"])),
         contention_workers: contention_workers
       }}
    else
      false -> {:error, :event_count_exceeds_wire_batch_limit}
      {:error, reason} -> {:error, reason}
    end
  end

  def measure_outage(opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    event_count = Keyword.get(opts, :event_count, 100)

    with :ok <- validate_count(event_count),
         true <- event_count <= @max_batch_size do
      host_id = "m18-outage-#{run_id}"
      auth = auth_context(host_id)
      occurred_at = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

      events =
        Enum.map(1..event_count, fn index ->
          event(host_id, run_id, index, occurred_at: DateTime.add(occurred_at, index, :second))
        end)

      batch = %{"batch_id" => run_id, "host_id" => host_id, "events" => events}
      {:ok, %{"results" => first_delivery}} = Ingest.ingest_batch(auth, batch)
      {:ok, %{"results" => retry_delivery}} = Ingest.ingest_batch(auth, batch)

      persisted =
        repo().aggregate(from(event in Event, where: event.correlation_id == ^run_id), :count)

      {:ok,
       %{
         locally_accepted: event_count,
         delivered: Enum.count(first_delivery, &(&1["status"] == "accepted")),
         persisted: persisted,
         duplicate_deliveries: Enum.count(retry_delivery, &(&1["status"] == "duplicate")),
         duplicate_effects: max(persisted - event_count, 0),
         simulated_hours: 24,
         server_boundary: "Backplane.Memory.Ingest.ingest_batch/3"
       }}
    else
      false -> {:error, :event_count_exceeds_wire_batch_limit}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event(host_id, run_id, index, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "#{run_id}-#{index}")
    source_sequence = Keyword.get(opts, :source_sequence, 1)
    event_type = Keyword.get(opts, :event_type, "agent.prompt.submitted")
    payload = %{"message" => "M18 qualification event #{index}"}
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())
    now = occurred_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "event_id" => Ecto.UUID.generate(),
      "schema_version" => 1,
      "host_id" => host_id,
      "agent_id" => "m18-qualification",
      "client_id" => "qualification-runner",
      "integration" => "codex",
      "project" => "/qualification/memory-v2",
      "scope" => "project:memory-v2-qualification",
      "session_id" => session_id,
      "run_id" => run_id,
      "sequence" => source_sequence,
      "event_type" => event_type,
      "occurred_at" => now,
      "captured_at" => now,
      "idempotency_key" => "#{run_id}:#{session_id}:#{source_sequence}:#{event_type}:#{index}",
      "payload_hash" => EventValidator.payload_hash(payload),
      "privacy" => %{"filtered" => true, "filter_version" => "1"},
      "trace" => %{"correlation_id" => run_id},
      "payload" => payload
    }
  end

  defp auth_context(host_id) do
    %{host_id: host_id, auth_token_id: "qualification-token", scopes: ["host_agent.capture"]}
  end

  defp validate_count(value) when is_integer(value) and value > 0, do: :ok
  defp validate_count(_value), do: {:error, :invalid_event_count}

  defp validate_batch_size(value) when is_integer(value) and value in 1..@max_batch_size, do: :ok
  defp validate_batch_size(_value), do: {:error, :invalid_batch_size}

  defp validate_contention_workers(value) when is_integer(value) and value in 2..16, do: :ok
  defp validate_contention_workers(_value), do: {:error, :invalid_contention_workers}

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(ceil(percentile / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
  end

  defp execute_projection_jobs(jobs, event_by_id, acknowledged_at) do
    Enum.reduce_while(jobs, {:ok, [], 0, MapSet.new(), 0}, fn job,
                                                                     {:ok, lags, complete,
                                                                      projectors, completed} ->
      event = Map.fetch!(event_by_id, job.args["event_id"])
      drain = Oban.drain_queue(queue: :memory, with_limit: 1)
      stored_job = repo().get!(Oban.Job, job.id)
      states = projection_states(event["host_id"], event["session_id"])

      if drain.success == 1 and drain.failure == 0 and stored_job.state == "completed" and
           map_size(states) == 4 and Enum.all?(states, fn {_name, state} -> state == "complete" end) do
        lag = %{lag_ms: elapsed_ms(acknowledged_at), session_id: event["session_id"]}

        {:cont,
         {:ok, [lag | lags], complete + 1,
          MapSet.union(projectors, MapSet.new(Map.keys(states))), completed + 1}}
      else
        {:halt,
         {:error,
          {:projection_job_incomplete,
           %{job_id: job.id, drain: drain, job_state: stored_job.state, states: states}}}}
      end
    end)
  end

  defp projection_states(host_id, session_id) do
    subject_id = Source.subject_id!(host_id, session_id)

    repo().all(
      from(state in State,
        where:
          state.subject_id == ^subject_id and state.subject_type == "captured_session" and
            state.projector in ["observations", "session", "activity", "replay"],
        select: {state.projector, state.status}
      )
    )
    |> Map.new()
  end

  defp projection_jobs(event_ids) do
    event_ids = MapSet.new(event_ids)

    repo()
    |> Oban.Testing.all_enqueued(worker: ProjectionRepairWorker)
    |> Enum.filter(&MapSet.member?(event_ids, &1.args["event_id"]))
    |> Enum.sort_by(& &1.id)
  end

  defp cleanup_projection_jobs([]), do: :ok

  defp cleanup_projection_jobs(jobs) do
    job_ids = Enum.map(jobs, & &1.id)
    repo().delete_all(from(job in Oban.Job, where: job.id in ^job_ids))
    :ok
  end

  defp with_projection_repair(fun) do
    previous_enabled = Application.get_env(:backplane_memory, :projection_repair_enabled)
    previous_enqueue = Application.get_env(:backplane_memory, :projection_repair_enqueue)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)
    Application.delete_env(:backplane_memory, :projection_repair_enqueue)

    try do
      fun.()
    after
      restore_env(:projection_repair_enabled, previous_enabled)
      restore_env(:projection_repair_enqueue, previous_enqueue)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

defmodule Backplane.Memory.Qualification.TransientBatchStore do
  @moduledoc false

  def append_batch_tagged(_attrs, _opts), do: {:error, :timeout}
  def append_tagged(_attrs, _opts), do: {:error, :timeout}
end
