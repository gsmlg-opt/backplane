defmodule Mix.Tasks.Memory.Projections.Rebuild do
  @shortdoc "Rebuild captured-session production read models"

  @moduledoc """
  Rebuilds canonical production projection snapshots and states from captured events.

  ## Usage

      mix memory.projections.rebuild
      mix memory.projections.rebuild --host HOST_ID --session SESSION_ID
      mix memory.projections.rebuild --dry-run --run-id RUN_ID
      mix memory.projections.rebuild --failed-only --continue-on-error --page-size 100 --max-subjects 500

  """

  use Mix.Task

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Operations.ProjectionRunner

  @usage "Usage: mix memory.projections.rebuild [--host HOST_ID --session SESSION_ID] [--dry-run --failed-only --continue-on-error --page-size N --max-subjects N --run-id RUN_ID]"
  @projectors ~w(activity observations replay session)

  @impl Mix.Task
  def run(args) do
    action = parse_args(args)
    Mix.Task.run("app.start")
    Mix.shell().info("memory projections rebuild (production read models)")
    request_id = Ecto.UUID.generate()

    case action do
      {:all, runner_opts} ->
        runner_opts =
          runner_opts
          |> Keyword.put(:actor, "mix:memory.projections.rebuild")
          |> Keyword.put(:on_result, &report_result(&1, request_id))

        case ProjectionRunner.run(runner_opts) do
          {status, report} when status in [:ok, :error] ->
            print_report(report)

            if status == :error and not Keyword.get(runner_opts, :continue_on_error, false) do
              Mix.raise("projection rebuild failed: #{inspect(report)}")
            end
        end

      {:session, host_id, session_id} ->
        case Rebuild.session(host_id, session_id) do
          {:ok, result} ->
            report_result(result, request_id)
            Mix.shell().info("rebuilt=1")

          {:error, reason} ->
            Mix.raise("projection rebuild failed: #{inspect(reason)}")
        end
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          session: :string,
          dry_run: :boolean,
          failed_only: :boolean,
          continue_on_error: :boolean,
          page_size: :integer,
          max_subjects: :integer,
          run_id: :string
        ]
      )

    keys = Keyword.keys(opts)
    duplicate_switch? = switch_count(args, "--host") > 1 or switch_count(args, "--session") > 1

    cond do
      positional != [] or invalid != [] or duplicate_switch? ->
        usage_error()

      Enum.all?(
        keys,
        &(&1 in [:dry_run, :failed_only, :continue_on_error, :page_size, :max_subjects, :run_id])
      ) and
          valid_runner_opts?(opts) ->
        {:all,
         opts
         |> Keyword.take([
           :dry_run,
           :failed_only,
           :continue_on_error,
           :page_size,
           :max_subjects,
           :run_id
         ])}

      Enum.sort(keys) == [:host, :session] ->
        {:session, Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :session)}

      true ->
        usage_error()
    end
  end

  defp valid_runner_opts?(opts) do
    page_size = Keyword.get(opts, :page_size, 100)
    max_subjects = Keyword.get(opts, :max_subjects, 500)
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())

    page_size in 1..500 and max_subjects in 1..10_000 and is_binary(run_id) and
      String.trim(run_id) != ""
  end

  defp print_report(report) do
    Mix.shell().info("run_id=#{report.run_id} status=#{report.status}")

    Mix.shell().info(
      "scanned=#{report.scanned} rebuilt=#{report.rebuilt} planned=#{report.planned} skipped=#{report.skipped} resumed=#{report.resumed} failed=#{report.failed} limit_reached=#{report.limit_reached}"
    )
  end

  defp switch_count(args, switch) do
    Enum.count(args, &(&1 == switch or String.starts_with?(&1, switch <> "=")))
  end

  defp print_result(result) do
    Mix.shell().info(
      "subject=#{result.subject_id} host=#{result.host_id} session=#{result.session_id}"
    )

    revisions =
      Enum.map_join(@projectors, ",", fn projector ->
        "#{projector}:#{Map.fetch!(result.output_revisions, projector)}"
      end)

    states =
      Enum.map_join(@projectors, ",", fn projector ->
        "#{projector}:#{result.states[projector].status}"
      end)

    Mix.shell().info("input_revision=#{result.input_revision}")
    Mix.shell().info("output_revisions=#{revisions}")
    Mix.shell().info("gaps=#{format_gaps(result.gaps)}")
    Mix.shell().info("states=#{states}")
  end

  defp report_result(result, request_id) do
    print_result(result)
    audit_result(result, request_id)
  end

  defp audit_result(result, request_id) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    session = repo.get!(ProjectedSession, result.subject_id)

    correlation_ids =
      repo.all(
        from(e in Event,
          where: e.host_id == ^result.host_id and e.session_id == ^result.session_id,
          where: not is_nil(e.correlation_id),
          select: e.correlation_id,
          distinct: true,
          order_by: e.correlation_id
        )
      )

    metadata = %{
      "host_id" => session.host_id,
      "client_id" => session.client_id,
      "scope" => session.scope,
      "namespace" => session.namespace,
      "request_id" => request_id,
      "correlation_id" => List.first(correlation_ids),
      "correlation_ids" => correlation_ids,
      "result" => "rebuilt",
      "input_revision" => result.input_revision,
      "idempotency_key" => "#{result.subject_id}:#{result.input_revision}"
    }

    {:ok, :ok} =
      repo.transaction(fn ->
        Audit.log_once(
          "projection.rebuild",
          "mix:memory.projections.rebuild",
          [result.subject_id],
          metadata["idempotency_key"],
          metadata
        )
      end)

    :ok
  end

  defp format_gaps([]), do: "none"

  defp format_gaps(gaps) do
    Enum.map_join(gaps, ",", &"#{&1["from"]}-#{&1["to"]}")
  end

  defp usage_error, do: Mix.raise(@usage)
end
