defmodule Backplane.Memory.Operations.ProjectionRunner do
  @moduledoc """
  Bounded, resumable orchestration for canonical projection rebuilds.

  Each terminal subject outcome is stored as an audit checkpoint. Reusing a
  `run_id` resumes after those checkpoints without replaying completed work.
  """

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Projections.{Rebuild, Source, State}

  @checkpoint_operation "projection.rebuild.checkpoint"
  @report_operation "projection.rebuild.report"
  @default_page_size 100
  @max_page_size 500

  @type report :: %{
          run_id: String.t(),
          status: String.t(),
          scanned: non_neg_integer(),
          rebuilt: non_neg_integer(),
          planned: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          resumed: non_neg_integer(),
          limit_reached: boolean(),
          failures: [map()]
        }

  @spec run(keyword()) :: {:ok, report()} | {:error, report() | term()}
  def run(opts \\ [])

  def run(opts) when is_list(opts) do
    with {:ok, config} <- config(opts) do
      initial = %{
        run_id: config.run_id,
        status: "running",
        scanned: 0,
        rebuilt: 0,
        planned: 0,
        skipped: 0,
        failed: 0,
        resumed: 0,
        limit_reached: false,
        failures: []
      }

      result =
        Source.reduce_subjects(initial, &process_subject(&1, &2, config),
          page_size: config.page_size
        )

      finish(result, config)
    end
  end

  def run(_opts), do: {:error, :invalid_options}

  defp process_subject(subject, report, config) do
    if handled(report) >= config.max_subjects do
      {:halt, Map.put(report, :limit_reached, true)}
    else
      report = Map.update!(report, :scanned, &(&1 + 1))

      cond do
        checkpointed?(config, subject["subject_id"]) ->
          {:cont, Map.update!(report, :resumed, &(&1 + 1))}

        config.failed_only and not failed_subject?(subject["subject_id"]) ->
          checkpoint(subject, config, "skipped", nil)
          {:cont, Map.update!(report, :skipped, &(&1 + 1))}

        config.dry_run ->
          checkpoint(subject, config, "planned", nil)
          {:cont, Map.update!(report, :planned, &(&1 + 1))}

        true ->
          rebuild_subject(subject, report, config)
      end
    end
  end

  defp rebuild_subject(subject, report, config) do
    started_at = System.monotonic_time()

    result =
      Backplane.Memory.PipelineTelemetry.span("projection.rebuild", subject, fn ->
        safe_rebuild(config.rebuild, config.on_result, subject)
      end)

    case result do
      {:ok, _result} ->
        checkpoint(subject, config, "rebuilt", nil)
        emit(started_at, subject, "rebuilt", nil)
        {:cont, Map.update!(report, :rebuilt, &(&1 + 1))}

      {:error, reason} ->
        error_class = error_class(reason)
        checkpoint(subject, config, "failed", error_class)
        emit(started_at, subject, "failed", error_class)

        failure = %{
          host_id: subject["host_id"],
          session_id: subject["session_id"],
          error_class: error_class
        }

        failed =
          report
          |> Map.update!(:failed, &(&1 + 1))
          |> Map.update!(:failures, &[failure | &1])

        if config.continue_on_error,
          do: {:cont, failed},
          else: {:error, failed}
    end
  end

  defp finish({:ok, report}, config) do
    status = if report.failed == 0 and not report.limit_reached, do: "complete", else: "partial"
    report = report |> Map.put(:status, status) |> reverse_failures()
    audit_report(report, config)
    if report.failed == 0, do: {:ok, report}, else: {:error, report}
  end

  defp finish({:error, %{} = report}, config) do
    report = report |> Map.put(:status, "failed") |> reverse_failures()
    audit_report(report, config)
    {:error, report}
  end

  defp finish({:error, reason}, _config), do: {:error, reason}

  defp checkpoint(subject, config, status, error_class) do
    metadata = %{
      "run_id" => config.run_id,
      "host_id" => subject["host_id"],
      "session_id" => subject["session_id"],
      "subject_id" => subject["subject_id"],
      "status" => status,
      "error_class" => error_class,
      "dry_run" => config.dry_run,
      "failed_only" => config.failed_only
    }

    repo().transaction(fn ->
      Audit.log_once(
        @checkpoint_operation,
        config.actor,
        [subject["subject_id"]],
        checkpoint_key(config.run_id, subject["subject_id"], status),
        metadata
      )
    end)

    :ok
  end

  defp audit_report(report, config) do
    Audit.log(@report_operation, config.actor, [], %{
      "run_id" => report.run_id,
      "status" => report.status,
      "scanned" => report.scanned,
      "rebuilt" => report.rebuilt,
      "planned" => report.planned,
      "skipped" => report.skipped,
      "failed" => report.failed,
      "resumed" => report.resumed,
      "limit_reached" => report.limit_reached,
      "dry_run" => config.dry_run,
      "failed_only" => config.failed_only,
      "error_classes" => Enum.map(report.failures, & &1.error_class)
    })
  end

  defp checkpointed?(config, subject_id) do
    statuses =
      cond do
        config.dry_run -> ["planned"]
        config.failed_only -> ["rebuilt", "skipped"]
        true -> ["rebuilt"]
      end

    repo().exists?(
      from(r in "memory_audit_log",
        where: r.operation == ^@checkpoint_operation,
        where: fragment("?->>'run_id' = ?", r.metadata, ^config.run_id),
        where: fragment("?->>'subject_id' = ?", r.metadata, ^subject_id),
        where: fragment("?->>'status'", r.metadata) in ^statuses
      )
    )
  end

  defp failed_subject?(subject_id) do
    repo().exists?(
      from(s in State,
        where:
          s.subject_type == "captured_session" and s.subject_id == ^subject_id and
            s.status in ["failed", "dead_letter"]
      )
    )
  end

  defp safe_rebuild(rebuild, on_result, subject) do
    case rebuild.(subject["host_id"], subject["session_id"]) do
      {:ok, result} ->
        on_result.(result)
        {:ok, result}

      other ->
        other
    end
  rescue
    _exception -> {:error, :exception}
  catch
    _kind, _reason -> {:error, :exit}
  end

  defp config(opts) do
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    max_subjects = Keyword.get(opts, :max_subjects, @max_page_size)
    rebuild = Keyword.get(opts, :rebuild, &Rebuild.session/2)
    on_result = Keyword.get(opts, :on_result, fn _result -> :ok end)

    if nonempty?(run_id) and page_size in 1..@max_page_size and
         is_integer(max_subjects) and max_subjects in 1..10_000 and is_function(rebuild, 2) and
         is_function(on_result, 1) do
      {:ok,
       %{
         run_id: String.trim(run_id),
         page_size: page_size,
         max_subjects: max_subjects,
         rebuild: rebuild,
         on_result: on_result,
         actor: Keyword.get(opts, :actor, "system"),
         dry_run: Keyword.get(opts, :dry_run, false) == true,
         failed_only: Keyword.get(opts, :failed_only, false) == true,
         continue_on_error: Keyword.get(opts, :continue_on_error, false) == true
       }}
    else
      {:error, :invalid_options}
    end
  end

  defp emit(started_at, subject, status, error_class) do
    :telemetry.execute(
      [:backplane, :memory, :operation],
      %{count: 1, duration: System.monotonic_time() - started_at},
      %{
        operation: "projection.rebuild",
        status: status,
        error_class: error_class,
        host_id: subject["host_id"],
        scope: "captured_session"
      }
    )
  end

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_reason), do: "unknown"
  defp handled(report), do: report.rebuilt + report.planned + report.skipped + report.failed
  defp checkpoint_key(run_id, subject_id, status), do: "#{run_id}:#{subject_id}:#{status}"
  defp reverse_failures(report), do: Map.update!(report, :failures, &Enum.reverse/1)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
