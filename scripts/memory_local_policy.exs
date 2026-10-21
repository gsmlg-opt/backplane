# Bounded L16 policy acceptance against an ALREADY RUNNING local gateway.
# Example (coordinator owns live execution and must keep other writers quiet):
# devenv shell -- env MIX_ENV=dev mix run --no-start --no-compile \
#   scripts/memory_local_policy.exs --fixture PATH/fixture.json --run RUN \
#   --marker l16-UNIQUE --gateway-state PATH/state.json --database backplane_dev \
#   --output PATH/l16-UNIQUE.json [--preflight-only] \
#   [--protect-fixture-lesson UUID ...]
# To continue a stopped cron_timer_timeout before any jobs were inserted, keep the
# original marker/controls, use --resume-from FAILED.json and a NEW output path.
# Resume validates unchanged evidence and skips all API writes and fixture setup.
# The script never starts gateway queues, changes Settings, or calls Worker.perform.
# Synthetic eligibility clocks and activity INPUT rows are explicitly fixture setup.
defmodule MemoryLocalPolicy do
  defmodule Failure do
    defexception [:message]
  end

  @fields ~w(memory_space_id host_id client_id scope namespace)
  @sweep "Backplane.Memory.Workers.LessonDecaySweepWorker"
  @decay "Backplane.Memory.Workers.LessonDecayWorker"
  @retention "Backplane.Memory.Workers.ActivityRetentionWorker"
  @tables ~w(bpm_memories memory_lessons memory_activity_daily memory_activity_subject_contributions system_settings)
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  def check!(true, _code), do: :ok
  def check!(_, code), do: raise(Failure, message: code)

  def utc_add(datetime, seconds),
    do: DateTime.add(datetime, seconds, :second, Calendar.UTCOnlyTimeZoneDatabase)

  def initialize_clock! do
    # mix run --no-start loads the configured Tzdata database without its ETS
    # owner. Styx peer election and Cron use that database, not utc_add/2.
    check!(Application.get_env(:tzdata, :autoupdate) == :disabled, "timezone_autoupdate_enabled")
    {:ok, _} = Application.ensure_all_started(:tzdata)
    now = DateTime.utc_now()

    check!(
      DateTime.diff(DateTime.add(now, 30_000, :millisecond), now) == 30,
      "timezone_not_ready"
    )

    :ok
  end

  def resume!(prior, opts, partition, current) do
    check!(
      prior["scenario"] == "L16" and prior["status"] == "incomplete" and
        prior["failure"] == "cron_timer_timeout" and prior["stage"] == "real_cron_timer" and
        prior["scheduler_stopped"] == true and prior["last_jobs"] == [] and
        Map.get(prior, "cron_roots", []) == [] and Map.get(prior, "jobs", []) == [],
      "resume_not_stopped_before_jobs"
    )

    check!(
      prior["marker"] == opts[:marker] and prior["run_id"] == opts[:run] and
        prior["partition"] == partition,
      "resume_identity_mismatch"
    )

    ids = prior["target_ids"]

    check!(
      is_list(ids) and length(ids) == 2 and length(Enum.uniq(ids)) == 2 and
        Enum.all?(ids, &(is_binary(&1) and Regex.match?(@uuid, &1))),
      "resume_invalid_targets"
    )

    receipts =
      Enum.zip_with(ids, ["recent", "archive"], fn id, kind ->
        %{"method" => "lesson_save", "status" => 200, "memory_id" => id, "kind" => kind}
      end)

    check!(prior["api_receipts"] == receipts, "resume_missing_source_receipts")
    {:ok, now, 0} = DateTime.from_iso8601(prior["clocks"]["now"])
    {:ok, cutoff} = Date.from_iso8601(prior["clocks"]["cutoff"])
    {:ok, today} = Date.from_iso8601(prior["clocks"]["retention_today"])
    days = prior["policy"]["retention_days"]

    check!(
      DateTime.to_date(now) == DateTime.to_date(current) and
        DateTime.compare(now, current) != :gt,
      "resume_policy_day_changed"
    )

    check!(
      is_integer(days) and days in 1..3660 and Date.diff(today, cutoff) == days and
        Date.compare(today, DateTime.to_date(current)) != :gt,
      "resume_invalid_retention_clock"
    )

    %{prior: prior, ids: ids, now: now, cutoff: cutoff, today: today}
  end

  def resume_unchanged!(prior, snapshot) do
    for key <-
          ~w(services_before database policy targets_before protected_controls_setup activity_setup nonfixture_before) do
      check!(
        Map.has_key?(prior, key) and Map.has_key?(snapshot, key) and
          json_term(prior[key]) == json_term(snapshot[key]),
        "resume_changed_#{key}"
      )
    end

    :ok
  end

  defp json_term(value), do: value |> Jason.encode!() |> Jason.decode!()

  def retention_clock!(actual, days, earliest) do
    check!(is_integer(days) and days in 1..3660, "invalid_retention_days")
    natural = Date.add(actual, -days)

    cutoff =
      if earliest && Date.compare(earliest, natural) != :gt,
        do: Date.add(earliest, -1),
        else: natural

    today = Date.add(cutoff, days)
    check!(Date.compare(cutoff, ~D[0001-01-02]) != :lt, "unsafe_historical_cutoff")
    check!(Date.compare(today, actual) != :gt, "future_retention_clock")
    {cutoff, today}
  end

  def eligible!(actual, allowed) do
    check!(MapSet.subset?(MapSet.new(actual), MapSet.new(allowed)), "nonfixture_eligible_lesson")
  end

  def fixture!(fixture, run) do
    check!(is_binary(run) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,49}$/, run), "invalid_run")
    check!(fixture["run_id"] == run, "fixture_run_mismatch")
    host = List.first(fixture["hosts"] || []) || %{}
    p = Map.take(host["partition"] || %{}, @fields)

    check!(
      Enum.all?(@fields, &(is_binary(p[&1]) and String.trim(p[&1]) != "")),
      "incomplete_partition"
    )

    check!(
      Regex.match?(@uuid, p["memory_space_id"]) and Regex.match?(@uuid, p["host_id"]),
      "invalid_partition_uuid"
    )

    check!(host["name"] == "memory-local-#{run}-primary", "nonsynthetic_host")

    check!(
      host["host_id"] == p["host_id"] and p["client_id"] == "host:" <> p["host_id"],
      "host_identity_mismatch"
    )

    check!(
      p["scope"] == "memory_local_#{run}_primary" and p["namespace"] == "private",
      "nonsynthetic_partition"
    )

    p
  end

  def roots!(roots, run, workers) do
    check!(Enum.sort(Enum.map(roots, & &1["worker"])) == Enum.sort(workers), "missing_cron_roots")

    check!(
      Enum.all?(roots, fn row ->
        meta = row["meta"] || %{}

        meta["cron"] == true and meta["cron_expr"] == "@reboot" and meta["l16_run"] == run and
          meta["cron_tz"] == "Etc/UTC" and is_binary(meta["cron_name"]) and
          meta["cron_name"] != ""
      end),
      "invalid_cron_metadata"
    )

    roots
  end

  def control!(row, p, run) do
    check!(
      Map.take(row, @fields) == p and row["status"] in ~w(candidate active disputed) and
        row["lifecycle_state"] in ~w(candidate active disputed),
      "control_partition_or_status"
    )

    check!(
      row["project"] == "/synthetic/backplane-memory/#{run}" or
        String.starts_with?(row["session_id"] || "", "memory-local-#{run}-"),
      "nonsynthetic_control"
    )
  end

  def stack_locations(stacktrace) do
    stacktrace
    |> Enum.take(12)
    |> Enum.map(fn {module, function, arity_or_args, location} ->
      %{
        module: Atom.to_string(module),
        function: Atom.to_string(function),
        arity: if(is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args),
        file: location |> Keyword.get(:file, "unknown") |> to_string() |> Path.basename(),
        line: Keyword.get(location, :line)
      }
    end)
  end

  def scheduler_opts(marker, now, today) do
    [
      name: {:l16_scheduler, marker},
      node: "l16-controller-#{System.pid()}",
      repo: Backplane.Repo,
      prefix: "public",
      engine: Styx.Engines.Basic,
      notifier: {Styx.Notifiers.Postgres, []},
      peer: {Styx.Peers.Database, []},
      queues: [],
      stager: false,
      testing: :disabled,
      plugins: [
        {Styx.Cron,
         timezone: "Etc/UTC",
         crontab: [
           {"@reboot", Backplane.Memory.Workers.LessonDecaySweepWorker,
            args: %{"now" => DateTime.to_iso8601(now)}, meta: %{l16_run: marker}},
           {"@reboot", Backplane.Memory.Workers.ActivityRetentionWorker,
            args: %{"today" => Date.to_iso8601(today), "batch_size" => 1},
            meta: %{l16_run: marker}}
         ]}
      ]
    ]
  end

  def main(args) do
    Process.flag(:trap_exit, true)

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          fixture: :string,
          run: :string,
          marker: :string,
          gateway_state: :string,
          database: :string,
          output: :string,
          host_url: :string,
          preflight_only: :boolean,
          resume_from: :string,
          protect_fixture_lesson: :keep
        ]
      )

    check!(rest == [] and invalid == [], "invalid_cli")

    for key <- ~w(fixture run marker gateway_state database output)a,
        do: check!(is_binary(opts[key]) and opts[key] != "", "missing_#{key}")

    check!(Regex.match?(~r/^l16-[a-z0-9][a-z0-9-]{0,49}$/, opts[:marker]), "invalid_marker")
    check!(Mix.env() == :dev, "requires_dev_environment")
    Logger.configure(level: :error)
    fixture = read_json!(opts[:fixture])
    p = fixture!(fixture, opts[:run])
    url = opts[:host_url] || "http://127.0.0.1:4222"
    uri = URI.parse(url)

    check!(
      uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
        uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
        uri.path in [nil, "", "/"],
      "requires_local_http"
    )

    controls = Keyword.get_values(opts, :protect_fixture_lesson)

    check!(
      length(controls) <= 100 and Enum.all?(controls, &Regex.match?(@uuid, &1)),
      "invalid_control_ids"
    )

    check!(length(Enum.uniq(controls)) == length(controls), "duplicate_control_ids")

    File.mkdir_p!(Path.dirname(opts[:output]))
    {:ok, io} = File.open(opts[:output], [:write, :exclusive, :binary])
    File.chmod!(opts[:output], 0o600)
    Process.put(:policy_io, io)

    Process.put(:policy_report, %{
      scenario: "L16",
      run_id: opts[:run],
      marker: opts[:marker],
      status: "incomplete",
      controller_os_pid: System.pid(),
      partition: p,
      evidence_level: "scheduled-live-workers",
      fixture_setup: "eligibility clocks and activity inputs only"
    })

    try do
      initialize_clock!()
      record(:timezone_ready, true)

      for app <- [:ecto_sql, :postgrex, :styx, :inets],
          do: {:ok, _} = Application.ensure_all_started(app)

      check!(
        Process.whereis(BackplaneSystem.Supervisor) == nil and
          Process.whereis(Backplane.Supervisor) == nil,
        "controller_started_gateway_applications"
      )

      {:ok, repo} =
        Backplane.Repo.start_link(log: false, show_sensitive_data_on_connection_error: false)

      Process.put(:policy_repo, repo)
      :backplane_settings = :ets.new(:backplane_settings, [:named_table, :public, :set])
      :ok = Backplane.Settings.load_all()
      execute(opts, p, String.trim_trailing(url, "/"), controls)
    rescue
      error in Failure ->
        record(:last_jobs, Process.get(:policy_last_jobs, []))
        record(:failure, error.message)

      error ->
        record(:last_jobs, Process.get(:policy_last_jobs, []))
        record(:failure_type, inspect(error.__struct__))
        record(:failure_locations, stack_locations(__STACKTRACE__))
        record(:failure, "unexpected_controller_error")
    after
      scheduler = Process.get(:policy_scheduler)

      if is_pid(scheduler) and Process.alive?(scheduler),
        do: Supervisor.stop(scheduler, :normal, 10_000)

      record(:scheduler_stopped, not (is_pid(scheduler) and Process.alive?(scheduler)))
      repo = Process.get(:policy_repo)
      if is_pid(repo) and Process.alive?(repo), do: Supervisor.stop(repo, :normal, 10_000)
      File.close(io)
    end

    report = Process.get(:policy_report)

    IO.puts(
      Jason.encode!(%{
        status: report[:status],
        evidence: opts[:output],
        failure: report[:failure]
      })
    )

    if report[:status] not in ["passed", "preflight_passed"], do: System.halt(1)
  end

  defp execute(opts, p, url, controls) do
    now = DateTime.utc_now()

    resume =
      if opts[:resume_from] do
        prior = read_json!(opts[:resume_from])
        record(:resume_from, Path.expand(opts[:resume_from]))

        record(
          :resume_source_sha256,
          :crypto.hash(:sha256, File.read!(opts[:resume_from])) |> Base.encode16(case: :lower)
        )

        resume!(prior, opts, p, now)
      end

    day_start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00])
    check!(DateTime.diff(utc_add(day_start, 86_400), now) > 240, "near_utc_midnight")
    # Leave a generous exclusion window around ALL existing global nightly policies.
    quiet_clock!(now)
    identities = identities!(opts[:gateway_state])
    record(:services_before, identities)
    record(:revision, System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim())

    [db] =
      query(
        "SELECT current_database() AS database, current_schema() AS schema, inet_server_addr()::text AS address, inet_server_port() AS port"
      )

    check!(
      db["database"] == opts[:database] and db["schema"] == "public",
      "database_identity_mismatch"
    )

    record(:database, db)

    owners =
      query(
        "SELECT h.id::text FROM skill_hosts h JOIN bpm_memory_space_entitlements e ON e.host_id = h.id JOIN bpm_memory_spaces s ON s.id = e.memory_space_id WHERE h.id::text = $1 AND h.name = $2 AND h.memory_scope = $3 AND e.memory_space_id::text = $4 AND e.scope = $3 AND e.namespace = $5 AND e.status = 'active' AND s.status = 'active' AND e.default_capture = true",
        [
          p["host_id"],
          "memory-local-#{opts[:run]}-primary",
          p["scope"],
          p["memory_space_id"],
          p["namespace"]
        ]
      )

    check!(length(owners) == 1, "fixture_database_owner_mismatch")
    record(:fixture_database_owner_verified, true)

    [gateway_peer] =
      query("SELECT node FROM styx_peers WHERE name = 'Styx' AND expires_at > now()")

    record(:gateway_styx_peer, gateway_peer)
    check!(Backplane.Memory.Config.lesson_decay_enabled?(), "lesson_decay_disabled")
    check!(Backplane.Settings.get("memory.pipeline.enabled") == false, "pipeline_must_be_quiet")

    settings = %{
      retention_days: Backplane.Memory.Config.activity_retention_days(),
      archive_days: Backplane.Memory.Config.lesson_decay_archive_days(),
      lesson_decay_enabled: true,
      pipeline_enabled: false
    }

    record(:policy, settings)

    for table <- @tables do
      [[count]] = raw("SELECT count(*) FROM #{table}").rows
      check!(count <= 20_000, "snapshot_row_bound")
    end

    active =
      query(
        "SELECT id FROM styx_jobs WHERE state IN ('available','scheduled','executing','retryable') AND (worker = ANY($1::text[]) OR queue IN ('embeddings','llm','memory','memory_lessons','memory_crystals')) LIMIT 1",
        [[@sweep, @decay, @retention, "Backplane.Memory.Workers.EvictionWorker"]]
      )

    record(:pending_memory_job_ids, Enum.map(active, & &1["id"]))
    check!(active == [], "pending_memory_work")

    partitions =
      query(
        "SELECT DISTINCT m.memory_space_id, m.host_id, m.client_id, m.scope, m.namespace FROM memory_lessons l JOIN bpm_memories m ON m.id = l.memory_id WHERE l.status IN ('active','candidate','disputed') LIMIT 101"
      )

    check!(length(partitions) <= 100, "sweep_partition_bound")
    project = "/synthetic/backplane-memory/#{opts[:run]}"
    control_before = lesson_rows(controls)
    check!(length(control_before) == length(controls), "control_not_found")

    for row <- control_before, do: control!(row, p, opts[:run])

    eligible = eligible_ids(day_start)
    record(:eligible_lesson_ids, eligible)
    eligible!(eligible, controls ++ if(resume, do: resume.ids, else: []))
    record(:protected_controls_before, control_before)

    [[earliest]] =
      raw(
        "SELECT min(date) FROM (SELECT min(date) AS date FROM memory_activity_daily UNION ALL SELECT min(date) AS date FROM memory_activity_subject_contributions) dates"
      ).rows

    {cutoff, today} =
      if resume,
        do: {resume.cutoff, resume.today},
        else: retention_clock!(Date.utc_today(), settings.retention_days, earliest)

    now = if resume, do: resume.now, else: now
    record(:clocks, %{now: now, cutoff: cutoff, retention_today: today})
    activity_project = project <> "/" <> opts[:marker]

    for table <- ~w(memory_activity_daily memory_activity_subject_contributions) do
      [[count]] =
        raw(
          "SELECT count(*) FROM #{table} WHERE #{if resume, do: "project IS DISTINCT FROM $1 AND date < $2", else: "project = $1 OR date < $2"}",
          [
            activity_project,
            cutoff
          ]
        ).rows

      check!(count == 0, "existing_activity_fixture_or_expired_data")
    end

    if resume do
      setup = lesson_rows(resume.ids)
      check!(length(setup) == 2, "resume_target_not_found")
      for row <- setup, do: control!(row, p, opts[:run])
      check!(Enum.sort(eligible) == Enum.sort(resume.ids), "resume_eligibility_changed")

      check!(
        Enum.sort(Enum.map(resume.prior["protected_controls_setup"], & &1["memory_id"])) ==
          Enum.sort(controls),
        "resume_controls_changed"
      )

      resume_unchanged!(resume.prior, %{
        "services_before" => identities,
        "database" => db,
        "policy" => settings,
        "targets_before" => setup,
        "protected_controls_setup" => control_before,
        "activity_setup" => activity_rows(activity_project),
        "nonfixture_before" => fingerprints(resume.ids, controls, activity_project)
      })

      check!(
        query("SELECT name FROM styx_peers WHERE name = $1", [
          inspect({:l16_scheduler, opts[:marker]})
        ]) == [],
        "resume_scheduler_peer_present"
      )

      record(:resume_validated, true)
    end

    check!(
      policy_jobs(opts[:marker], DateTime.to_iso8601(now), today) == [],
      "existing_policy_run"
    )

    record(:preflight, %{
      eligible_control_ids: controls,
      nonfixture_eligible_lessons: 0,
      nonfixture_expired_activity: 0,
      bounded_rows: true
    })

    if opts[:preflight_only] do
      record(:status, "preflight_passed")
    else
      {ids, now, setup, fingerprint} =
        if resume do
          record(:target_ids, resume.ids)
          record(:targets_source, resume.prior["targets_source"])
          record(:api_receipts, resume.prior["api_receipts"])
          record(:nonfixture_before, resume.prior["nonfixture_before"])
          record(:targets_before, lesson_rows(resume.ids))
          record(:protected_controls_setup, control_before)
          record(:activity_setup, activity_rows(activity_project))
          record(:fixture_setup, "resumed unchanged prior inputs; no API or fixture writes")
          {resume.ids, resume.now, lesson_rows(resume.ids), resume.prior["nonfixture_before"]}
        else
          record(:stage, "create_source_lessons_through_host_http")
          ids = for kind <- ["recent", "archive"], do: save_lesson!(url, opts, project, kind)
          record(:target_ids, ids)
          before = lesson_rows(ids)
          check!(length(before) == 2, "targets_not_canonical")
          record(:targets_source, before)

          # Select the real policy clock AFTER the API created its source lessons.
          now = DateTime.utc_now()
          check!(DateTime.to_date(now) == DateTime.to_date(day_start), "utc_day_changed")
          record(:clocks, %{now: now, cutoff: cutoff, retention_today: today})

          for row <- before do
            check!(
              Map.take(row, @fields) == p and row["status"] == "active" and
                row["lifecycle_state"] == "active" and row["project"] == project and
                row["last_decayed_at"] == nil and row["decay_rate"] == 0.0,
              "invalid_target_source"
            )
          end

          eligible!(eligible_ids(day_start), ids ++ controls)
          fingerprint = fingerprints(ids, controls, activity_project)
          record(:nonfixture_before, fingerprint)
          record(:stage, "synthetic_eligibility_and_activity_input_setup")

          {:ok, :ok} =
            Backplane.Repo.transaction(fn ->
              setup_clocks!(ids, controls, p, now, settings.archive_days)
              insert_activity!(p, activity_project, opts[:marker], cutoff, now)
            end)

          setup = lesson_rows(ids)
          record(:targets_before, setup)
          record(:protected_controls_setup, lesson_rows(controls))
          record(:activity_setup, activity_rows(activity_project))

          check!(
            Enum.sort(eligible_ids(day_start)) == Enum.sort(ids),
            "unexpected_eligible_after_setup"
          )

          check!(
            fingerprint == fingerprints(ids, controls, activity_project),
            "nonfixture_changed_during_setup"
          )

          {ids, now, setup, fingerprint}
        end

      record(:stage, "real_cron_timer")
      quiet_clock!(DateTime.utc_now())
      run_cron!(opts[:marker], now, today)
      record(:stage, "existing_gateway_worker_execution")

      jobs =
        wait!(
          fn ->
            jobs = policy_jobs(opts[:marker], DateTime.to_iso8601(now), today)

            check!(
              not Enum.any?(jobs, &(&1["state"] in ["discarded", "cancelled", "retryable"])),
              "policy_job_failed"
            )

            children = Enum.filter(jobs, &(&1["worker"] == @decay))
            if children != [] and Enum.all?(jobs, &(&1["state"] == "completed")), do: jobs
          end,
          90_000,
          "policy_jobs_timeout"
        )

      record(:jobs, jobs)

      check!(
        Enum.all?(jobs, &(List.first(&1["attempted_by"] || []) == gateway_peer["node"])),
        "job_not_executed_by_gateway_node"
      )

      roots!(Enum.filter(jobs, &(&1["meta"]["l16_run"] == opts[:marker])), opts[:marker], [
        @sweep,
        @retention
      ])

      children = Enum.filter(jobs, &(&1["worker"] == @decay))

      check!(
        Enum.any?(children, &(Map.take(&1["args"], @fields) == p)),
        "missing_exact_partition_child"
      )

      for job <- Enum.filter(jobs, &(&1["worker"] in [@sweep, @decay])) do
        check!(job["args"]["now"] == DateTime.to_iso8601(now), "changed_decay_clock")

        if job["worker"] == @decay,
          do:
            check!(
              Enum.all?(@fields, &(is_binary(job["args"][&1]) and job["args"][&1] != "")),
              "incomplete_child_partition"
            )

        if job["args"]["cursor"],
          do: check!(length(job["args"]["cursor"]) == 5, "incomplete_sweep_cursor")
      end

      after_rows = lesson_rows(ids)
      verify_targets!(setup, after_rows, ids, now)
      control_after = lesson_rows(controls)

      check!(
        Enum.map(control_before, &Map.drop(&1, ["last_decayed_at"])) ==
          Enum.map(control_after, &Map.drop(&1, ["last_decayed_at"])),
        "protected_control_changed"
      )

      check!(
        Enum.all?(control_after, &(&1["last_decayed_at"] == DateTime.to_naive(now))),
        "protected_control_clock_changed"
      )

      record(:targets_after, after_rows)
      record(:protected_controls_after, control_after)
      record(:activity_after, verify_activity!(activity_project, cutoff))

      audits =
        query(
          "SELECT metadata->>'cutoff' AS cutoff, (metadata->>'contributions_deleted')::int AS contributions_deleted, (metadata->>'daily_deleted')::int AS daily_deleted FROM memory_audit_log WHERE operation = 'memory.activity.purge' AND metadata->>'cutoff' = $1 AND created_at >= $2 ORDER BY created_at LIMIT 100",
          [Date.to_iso8601(cutoff), DateTime.to_naive(now)]
        )

      check!(
        Enum.sum(Enum.map(audits, & &1["contributions_deleted"])) == 1 and
          Enum.sum(Enum.map(audits, & &1["daily_deleted"])) == 1,
        "retention_audit_counts"
      )

      check!(
        Enum.count(jobs, &(&1["worker"] == @retention)) >= 2,
        "missing_retention_continuation"
      )

      record(:retention_audits, audits)
      after_fingerprint = fingerprints(ids, controls, activity_project)
      record(:nonfixture_after, after_fingerprint)
      check!(fingerprint == after_fingerprint, "nonfixture_changed")
      after_identities = identities!(opts[:gateway_state])
      record(:services_after, after_identities)
      check!(identities == after_identities, "service_identity_changed")

      record(:checks, %{
        real_cron_roots: true,
        real_gateway_workers: true,
        exact_partition: true,
        archived_only_target: true,
        daily_decay_once: true,
        confidence_unchanged: true,
        strict_retention_boundary: true,
        retention_continuation: true,
        nonfixture_hashes_unchanged: true
      })

      record(:status, "passed")
    end
  end

  defp save_lesson!(url, opts, project, kind) do
    args = %{
      rule:
        "MEMORY-LOCAL-#{opts[:run]} #{opts[:marker]} #{kind}: verify bounded policy processing",
      context: "synthetic L16 #{opts[:marker]}",
      project: project,
      idempotency_key: "#{opts[:marker]}:#{kind}",
      request_id: "#{opts[:marker]}:#{kind}",
      correlation_id: opts[:marker]
    }

    path = "/memory/memory-local-#{opts[:run]}/call/lesson_save"

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> path), [], ~c"application/json", Jason.encode!(args)},
        [timeout: 15_000, connect_timeout: 3_000],
        body_format: :binary
      )

    check!(byte_size(body) <= 1_000_000 and status == 200, "lesson_save_http_failed")
    reply = Jason.decode!(body)
    id = get_in(reply, ["result", "memory_id"])

    check!(
      reply["ok"] == true and is_binary(id) and Regex.match?(@uuid, id),
      "lesson_save_failed"
    )

    record(
      :api_receipts,
      (Process.get(:policy_report)[:api_receipts] || []) ++
        [%{method: "lesson_save", status: status, memory_id: id, kind: kind}]
    )

    id
  end

  defp setup_clocks!(ids, controls, p, now, days) do
    params = [controls] ++ Enum.map(@fields, &p[&1]) ++ [DateTime.to_naive(now)]

    where =
      "m.id = l.memory_id AND l.memory_id::text = ANY($1::text[]) AND m.memory_space_id::text = $2 AND m.host_id = $3 AND m.client_id = $4 AND m.scope = $5 AND m.namespace = $6"

    count =
      raw(
        "UPDATE memory_lessons l SET last_decayed_at = $7 FROM bpm_memories m WHERE #{where}",
        params
      ).num_rows

    check!(count == length(controls), "control_clock_update_count")
    old = utc_add(now, -(days + 1) * 86_400) |> DateTime.to_naive()
    params = [[List.last(ids)]] ++ Enum.map(@fields, &p[&1]) ++ [old]

    count =
      raw(
        "UPDATE memory_lessons l SET promoted_at = $7, last_reinforced_at = NULL, last_applied_at = NULL, last_decayed_at = NULL FROM bpm_memories m WHERE #{where}",
        params
      ).num_rows

    check!(count == 1, "archive_clock_update_count")
    :ok
  end

  defp insert_activity!(p, project, marker, cutoff, now) do
    for {kind, date} <- [
          {"expired", Date.add(cutoff, -1)},
          {"boundary", cutoff},
          {"retained", Date.add(cutoff, 1)}
        ],
        table <- ~w(memory_activity_daily memory_activity_subject_contributions) do
      contribution? = table == "memory_activity_subject_contributions"

      extra_columns =
        if contribution?, do: ", subject_id, processing_version, input_revision", else: ""

      extra_values = if contribution?, do: ", $11, 'activity-v1', 'l16-fixture-input'", else: ""

      params =
        Enum.map(@fields, &p[&1]) ++
          [project, marker, date, DateTime.to_naive(now), "agent.prompt.submitted"]

      params = if contribution?, do: params ++ [marker <> "-" <> kind], else: params

      raw(
        "INSERT INTO #{table} (memory_space_id, host_id, client_id, scope, namespace, source_client_id, project, agent_id, date, inserted_at, updated_at, event_type, event_count, session_count, memory_count, lesson_count, crystal_count, recall_count, action_count, error_count#{extra_columns}) VALUES ($1::text::uuid, $2, $3, $4, $5, $3, $6, $7, $8, $9, $9, $10, 1, 1, 0, 0, 0, 0, 0, 0#{extra_values})",
        params
      )
    end

    :ok
  end

  defp run_cron!(marker, now, today) do
    name = {:l16_scheduler, marker}
    opts = scheduler_opts(marker, now, today)

    :ok = Styx.Config.validate(opts)
    {:ok, pid} = Styx.start_link(opts)
    Process.put(:policy_scheduler, pid)
    check!(Styx.check_all_queues(name) == [], "controller_has_queues")

    roots =
      wait!(
        fn ->
          rows =
            Enum.filter(
              policy_jobs(marker, DateTime.to_iso8601(now), today),
              &(&1["meta"]["l16_run"] == marker)
            )

          if length(rows) == 2, do: rows
        end,
        90_000,
        "cron_timer_timeout"
      )

    record(:cron_roots, roots!(roots, marker, [@sweep, @retention]))
    Supervisor.stop(pid, :normal, 10_000)
    record(:scheduler_stopped_after_insert, not Process.alive?(pid))

    check!(
      query("SELECT name FROM styx_peers WHERE name = $1", [inspect(name)]) == [],
      "controller_peer_not_removed"
    )

    record(:controller_peer_removed, true)
    record(:controller_queue_count, 0)
  end

  defp verify_targets!(before, after_rows, ids, now) do
    check!(length(after_rows) == 2, "target_disappeared")

    for row <- after_rows do
      old = Enum.find(before, &(&1["memory_id"] == row["memory_id"]))
      target = if row["memory_id"] == List.last(ids), do: "archived", else: "active"

      check!(
        row["status"] == target and row["lifecycle_state"] == target,
        "incorrect_policy_lifecycle"
      )

      check!(
        abs(row["decay_rate"] - old["decay_rate"] - 0.05) < 0.000001,
        "incorrect_daily_decay"
      )

      check!(row["confidence"] == old["confidence"], "confidence_changed")
      check!(row["last_decayed_at"] == DateTime.to_naive(now), "incorrect_decay_timestamp")
    end
  end

  defp verify_activity!(project, cutoff) do
    rows = activity_rows(project)
    before = Process.get(:policy_report)[:activity_setup]

    for {table, entries} <- rows do
      expected = Enum.filter(before[table], &(Date.compare(&1["date"], cutoff) != :lt))

      check!(
        Enum.map(entries, & &1["date"]) == [cutoff, Date.add(cutoff, 1)] and entries == expected,
        "incorrect_retention_boundary"
      )
    end

    rows
  end

  defp activity_rows(project) do
    Map.new(~w(memory_activity_daily memory_activity_subject_contributions), fn table ->
      rows =
        query(
          "SELECT date, count(*) AS count, md5(string_agg(md5(row_to_json(t)::text), '' ORDER BY md5(row_to_json(t)::text))) AS digest FROM #{table} t WHERE project = $1 GROUP BY date ORDER BY date",
          [project]
        )

      {table, rows}
    end)
  end

  defp lesson_rows(ids) do
    query(
      "SELECT l.memory_id::text, m.memory_space_id::text, m.host_id, m.client_id, m.scope, m.namespace, m.metadata->>'project' AS project, m.session_id, l.status, l.decay_rate, l.last_decayed_at, l.promoted_at, l.last_reinforced_at, l.last_applied_at, m.confidence, m.lifecycle_state FROM memory_lessons l JOIN bpm_memories m ON m.id = l.memory_id WHERE l.memory_id::text = ANY($1::text[]) ORDER BY l.memory_id",
      [ids]
    )
  end

  defp eligible_ids(start) do
    query(
      "SELECT l.memory_id::text FROM memory_lessons l JOIN bpm_memories m ON m.id = l.memory_id WHERE l.status IN ('active','candidate','disputed') AND (l.last_decayed_at IS NULL OR l.last_decayed_at < $1) ORDER BY l.memory_id LIMIT 1001",
      [DateTime.to_naive(start)]
    )
    |> Enum.map(& &1["memory_id"])
  end

  defp fingerprints(ids, controls, project) do
    Map.new(@tables, fn table ->
      {where, params} =
        case table do
          "bpm_memories" -> {"id::text <> ALL($1::text[])", [ids]}
          "memory_lessons" -> {"memory_id::text <> ALL($1::text[])", [ids ++ controls]}
          "system_settings" -> {"true", []}
          _ -> {"project IS DISTINCT FROM $1", [project]}
        end

      [row] =
        query(
          "SELECT count(*) AS count, md5(COALESCE(string_agg(digest, '' ORDER BY digest), '')) AS digest FROM (SELECT md5(row_to_json(t)::text) AS digest FROM #{table} t WHERE #{where}) hashes",
          params
        )

      {table, row}
    end)
  end

  defp policy_jobs(marker, clock, today) do
    rows =
      query(
        "SELECT id, worker, queue, state, args, jsonb_build_object('cron',meta->'cron','cron_expr',meta->'cron_expr','cron_name',meta->'cron_name','cron_tz',meta->'cron_tz','l16_run',meta->'l16_run') AS meta, attempt, attempted_by, attempted_at, completed_at, cardinality(errors) AS error_count FROM styx_jobs WHERE meta->>'l16_run' = $1 OR (worker = ANY($2::text[]) AND args->>'now' = $3) OR (worker = $4 AND args->>'today' = $5 AND args->>'batch_size' = '1') ORDER BY id LIMIT 1001",
        [marker, [@sweep, @decay], clock, @retention, Date.to_iso8601(today)]
      )

    Process.put(:policy_last_jobs, rows)
    check!(length(rows) <= 1000, "policy_job_bound")
    rows
  end

  defp identities!(path) do
    state = read_json!(path)
    records = Enum.filter(state["processes"] || [], &(&1["name"] in ["gateway", "host"]))

    check!(
      Enum.sort(Enum.map(records, & &1["name"])) == ["gateway", "host"],
      "missing_service_identities"
    )

    scripts = Path.expand(__DIR__)

    code =
      "import json,sys;sys.path.insert(0,sys.argv[1]);import memory_local_dev;print(json.dumps(memory_local_dev.process_identity(int(sys.argv[2]))))"

    for record <- records do
      {json, 0} =
        System.cmd("python3", ["-c", code, scripts, to_string(record["pid"])],
          stderr_to_stdout: true
        )

      identity = Jason.decode!(json)

      check!(
        is_map(identity) and
          Enum.all?(~w(started_at birth pgid uid), &(identity[&1] == record[&1])),
        "service_identity_mismatch"
      )

      Map.merge(Map.take(record, ~w(name pid)), Map.take(identity, ~w(started_at birth pgid uid)))
    end
  end

  defp wait!(fun, timeout, code) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll = fn poll ->
      result = fun.()

      if result do
        result
      else
        check!(System.monotonic_time(:millisecond) < deadline, code)
        Process.sleep(250)
        poll.(poll)
      end
    end

    poll.(poll)
  end

  defp read_json!(path) do
    check!(File.stat!(path).size <= 1_000_000, "input_size_bound")
    File.read!(path) |> Jason.decode!()
  end

  defp quiet_clock!(now) do
    check!(
      Enum.all?([now, utc_add(now, 240)], &(&1.hour not in [2, 3, 4, 5])),
      "nightly_policy_window"
    )
  end

  defp raw(sql, params \\ []), do: Backplane.Repo.query!(sql, params, log: false, timeout: 10_000)

  defp query(sql, params \\ []) do
    result = raw(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp record(key, value) do
    report = Map.put(Process.get(:policy_report), key, value)
    Process.put(:policy_report, report)
    io = Process.get(:policy_io)
    :file.position(io, 0)
    IO.binwrite(io, Jason.encode!(report, pretty: true) <> "\n")
    :file.truncate(io)
    :ok = :file.sync(io)
  end
end

unless System.get_env("MEMORY_LOCAL_POLICY_LIBRARY") == "1" do
  MemoryLocalPolicy.main(System.argv())
end
