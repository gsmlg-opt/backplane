defmodule Backplane.Diagnostics.Issues do
  @moduledoc "Issue grouping, aggregate counts, and durable issue change notifications."

  import Ecto.Query

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Occurrences.{Evidence, Occurrence}
  alias Backplane.Diagnostics.Resolutions
  alias Backplane.Diagnostics.Resolutions.{ManagementAction, Resolution}
  alias Backplane.Diagnostics.Runs.Observation
  alias Backplane.DiagnosticsClient.Canonical
  alias Backplane.Repo

  @fingerprint_version 1
  @change_kinds ~w(opened repeat severity_increased evidence_added reopened verification_changed manual)
  @merge_action "issue_merged_into"
  @max_id 9_223_372_036_854_775_807

  defmodule Issue do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_issues" do
      field :fingerprint, :string
      field :fingerprint_version, :integer
      field :category, :string
      field :severity, :string
      field :status, :string, default: "open"
      field :occurrence_count, :integer, default: 0
      field :first_seen_at, :utc_datetime_usec
      field :last_seen_at, :utc_datetime_usec
    end
  end

  defmodule Membership do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_issue_occurrences" do
      field :issue_id, :id, primary_key: true
      field :occurrence_id, :id, primary_key: true
    end
  end

  defmodule Change do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:issue_id, :id, autogenerate: false}
    schema "diagnostics_issue_changes" do
      field :event_key, :id
      field :kind, :string
      field :revision, :integer
      field :available_at, :utc_datetime_usec
    end
  end

  def get(id) when is_integer(id), do: Repo.get(Issue, id)

  defmodule GroupingAction do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_issue_grouping_actions" do
      field :from_issue_id, :id
      field :to_issue_id, :id
      field :occurrence_id, :id
      field :actor, :string
      field :inserted_at, :utc_datetime_usec
    end
  end

  @doc "Returns a bounded page ordered by most recently observed issue."
  def list(opts \\ []) do
    Issue
    |> filter(:status, Keyword.get(opts, :status))
    |> filter(:category, Keyword.get(opts, :category))
    |> filter(:severity, Keyword.get(opts, :severity))
    |> before(Keyword.get(opts, :before))
    |> order_by([row], desc: row.last_seen_at, desc: row.id)
    |> limit(^bounded_limit(opts))
    |> Repo.all()
  end

  def counts(issue_id) when is_integer(issue_id) do
    Membership
    |> where([membership], membership.issue_id == ^issue_id)
    |> join(:inner, [membership], occurrence in Occurrence,
      on: occurrence.id == membership.occurrence_id
    )
    |> join(:left, [_, occurrence], evidence in Evidence,
      on: evidence.occurrence_id == occurrence.id
    )
    |> join(:left, [_, _, evidence], run_event in Observation,
      on: run_event.event_key == evidence.event_key
    )
    |> select([_, occurrence, evidence, run_event], %{
      events: count(evidence.event_key, :distinct),
      occurrences: count(occurrence.id, :distinct),
      runs: count(run_event.run_key, :distinct)
    })
    |> Repo.one!()
  end

  def occurrences(issue_id, opts \\ []) do
    Occurrence
    |> join(:inner, [occurrence], membership in Membership,
      on: membership.occurrence_id == occurrence.id
    )
    |> where([_, membership], membership.issue_id == ^issue_id)
    |> order_by([occurrence], desc: occurrence.last_seen_at, desc: occurrence.id)
    |> limit(^bounded_limit(opts))
    |> Repo.all()
  end

  def events(issue_id, opts \\ []) do
    Event
    |> join(:inner, [event], evidence in Evidence, on: evidence.event_key == event.id)
    |> join(:inner, [_, evidence], membership in Membership,
      on: membership.occurrence_id == evidence.occurrence_id
    )
    |> where([_, _, membership], membership.issue_id == ^issue_id)
    |> distinct(true)
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^bounded_limit(opts))
    |> Repo.all()
  end

  @doc "Moves existing occurrences between issue groups under an explicit, audited operator action."
  def reassign(from_id, to_id, occurrence_ids, actor)
      when from_id in 1..@max_id and to_id in 1..@max_id and from_id != to_id and
             is_list(occurrence_ids) and
             is_binary(actor) and byte_size(actor) in 1..128 do
    with {:ok, ids} <- grouping_ids(occurrence_ids) do
      Repo.transact(fn -> reassign_locked(from_id, to_id, ids, actor) end)
    end
  end

  def reassign(_, _, _, _), do: {:error, :invalid_grouping_action}

  @doc "Creates a separate issue from selected occurrences and records their original membership."
  def split(issue_id, occurrence_ids, actor)
      when issue_id in 1..@max_id and is_list(occurrence_ids) and is_binary(actor) and
             byte_size(actor) in 1..128 do
    with {:ok, ids} <- grouping_ids(occurrence_ids) do
      Repo.transact(fn -> split_locked(issue_id, ids, actor) end)
    end
  end

  def split(_, _, _), do: {:error, :invalid_grouping_action}

  @doc "Merges an issue into a destination while retaining the old issue and its fingerprint as provenance."
  def merge(from_id, to_id, actor)
      when from_id in 1..@max_id and to_id in 1..@max_id and from_id != to_id and
             is_binary(actor) and byte_size(actor) in 1..128 do
    Repo.transact(fn -> merge_locked(from_id, to_id, actor) end, log: false)
  end

  def merge(_, _, _), do: {:error, :invalid_grouping_action}

  @doc "Returns the canonical destination of a merged issue."
  def merged_into(issue_id) when issue_id in 1..@max_id do
    case canonical_id(issue_id) do
      ^issue_id -> nil
      target -> target
    end
  end

  def merged_into(_), do: nil

  defp grouping_ids(input) do
    ids = Enum.take(input, 101)

    if ids != [] and length(ids) <= 100 and Enum.all?(ids, &(is_integer(&1) and &1 in 1..@max_id)) do
      {:ok, Enum.uniq(ids)}
    else
      {:error, :invalid_occurrences}
    end
  end

  @doc false
  def observe(%Event{} = event, %Occurrence{} = occurrence, finding) do
    case Repo.get_by(Membership, occurrence_id: occurrence.id) do
      %Membership{issue_id: issue_id} ->
        previous = lock_issue(issue_id)
        touch(issue_id, occurrence, 0, finding.severity)
        new_evidence? = remember_evidence(issue_id, event)

        cond do
          escalated?(previous.severity, finding.severity) ->
            enqueue_change(issue_id, event.id, "severity_increased", event.received_at)

          new_evidence? ->
            enqueue_change(issue_id, event.id, "evidence_added", event.received_at)

          true ->
            :ok
        end

        issue_id

      nil ->
        create_or_attach(event, occurrence, finding)
    end
  end

  @doc false
  def issue_for_occurrence(occurrence_id) do
    case Repo.get_by(Membership, occurrence_id: occurrence_id) do
      %Membership{issue_id: id} -> id
      nil -> nil
    end
  end

  @doc false
  def corroborate(%Event{} = event, %Occurrence{id: occurrence_id}) do
    if issue_id = issue_for_occurrence(occurrence_id) do
      lock_issue(issue_id)

      if remember_evidence(issue_id, event) do
        enqueue_change(issue_id, event.id, "evidence_added", event.received_at)
      end
    end
  end

  @doc "Lists claimable issue refreshes. A newer revision supersedes an earlier snapshot."
  def changes(limit \\ 10) when limit in 1..100 do
    now = DateTime.utc_now()

    Change
    |> where([row], row.available_at <= ^now)
    |> order_by([row], asc: row.available_at, asc: row.issue_id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Acknowledges only the exact version read by the consumer."
  def acknowledge_change(%Change{issue_id: id, revision: revision}) do
    {count, _} =
      Repo.delete_all(
        from(row in Change, where: row.issue_id == ^id and row.revision == ^revision)
      )

    count == 1
  end

  defp create_or_attach(event, occurrence, finding) do
    fingerprint = fingerprint(event, finding)

    attrs = %{
      fingerprint: fingerprint,
      fingerprint_version: @fingerprint_version,
      category: finding.category,
      severity: finding.severity,
      status: "open",
      occurrence_count: 0,
      first_seen_at: occurrence.first_seen_at,
      last_seen_at: occurrence.last_seen_at
    }

    {opened, _} =
      Repo.insert_all(Issue, [attrs],
        on_conflict: :nothing,
        conflict_target: [:fingerprint_version, :fingerprint],
        log: false
      )

    issue_id =
      Issue
      |> where(
        [row],
        row.fingerprint_version == @fingerprint_version and row.fingerprint == ^fingerprint
      )
      |> select([row], row.id)
      |> Repo.one!()

    issue = lock_destination(issue_id, opened == 1)

    {attached, _} =
      Repo.insert_all(Membership, [%{issue_id: issue.id, occurrence_id: occurrence.id}],
        on_conflict: :nothing,
        conflict_target: [:occurrence_id],
        log: false
      )

    touch(issue.id, occurrence, attached, finding.severity)
    new_evidence? = remember_evidence(issue.id, event)

    if attached == 1 do
      kind =
        cond do
          opened == 1 -> "opened"
          escalated?(issue.severity, finding.severity) -> "severity_increased"
          new_evidence? -> "evidence_added"
          true -> "repeat"
        end

      enqueue_change(issue.id, event.id, kind, event.received_at)
    end

    issue.id
  end

  defp touch(id, occurrence, increment, severity) do
    Repo.update_all(
      from(row in Issue,
        where: row.id == ^id,
        update: [
          inc: [occurrence_count: ^increment],
          set: [
            first_seen_at:
              fragment(
                "LEAST(?, ?)",
                row.first_seen_at,
                type(^occurrence.first_seen_at, :utc_datetime_usec)
              ),
            last_seen_at:
              fragment(
                "GREATEST(?, ?)",
                row.last_seen_at,
                type(^occurrence.last_seen_at, :utc_datetime_usec)
              ),
            severity:
              fragment(
                "CASE WHEN ? = 'high' OR ? = 'high' THEN 'high' WHEN ? = 'medium' OR ? = 'medium' THEN 'medium' ELSE 'low' END",
                row.severity,
                type(^severity, :string),
                row.severity,
                type(^severity, :string)
              )
          ]
        ]
      ),
      [],
      log: false
    )
  end

  @doc "Schedules or coalesces a report refresh with a persistent version."
  def enqueue_change(issue_id, event_key, kind, available_at) when kind in @change_kinds do
    bump =
      from(change in Change,
        update: [
          set: [
            revision: fragment("EXCLUDED.revision"),
            event_key:
              fragment(
                "CASE WHEN EXCLUDED.kind = 'repeat' THEN ? ELSE EXCLUDED.event_key END",
                change.event_key
              ),
            kind:
              fragment(
                "CASE WHEN EXCLUDED.kind = 'repeat' OR (? = 'opened' AND EXCLUDED.kind = 'evidence_added') THEN ? ELSE EXCLUDED.kind END",
                change.kind,
                change.kind
              ),
            available_at: fragment("LEAST(?, EXCLUDED.available_at)", change.available_at)
          ]
        ]
      )

    Repo.insert_all(
      Change,
      [%{issue_id: issue_id, event_key: event_key, kind: kind, available_at: available_at}],
      on_conflict: bump,
      conflict_target: [:issue_id],
      log: false
    )
  end

  defp lock_issue(issue_id) do
    Repo.one!(from row in Issue, where: row.id == ^issue_id, lock: "FOR UPDATE")
  end

  defp lock_destination(issue_id, true), do: lock_issue(issue_id)

  defp lock_destination(issue_id, false) do
    case canonical_id(issue_id) do
      nil ->
        Repo.rollback(:invalid_grouping)

      target ->
        issue = lock_issue(target)

        # Release the locks and let the projector re-claim the event if a merge
        # completed after we resolved the target.
        if outgoing_merge?(target), do: Repo.rollback(:grouping_changed), else: issue
    end
  end

  defp canonical_id(issue_id) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE destination(id) AS (
          SELECT $1::bigint
          UNION
          SELECT action.entity_id
          FROM diagnostics_management_actions AS action
          JOIN destination ON action.issue_id = destination.id
          WHERE action.action = $2 AND action.entity_id IS NOT NULL
        )
        SELECT destination.id FROM destination
        WHERE NOT EXISTS (
          SELECT 1 FROM diagnostics_management_actions AS action
          WHERE action.issue_id = destination.id AND action.action = $2
        )
        """,
        [issue_id, @merge_action],
        log: false
      )

    case result.rows do
      [[target]] -> target
      _ -> nil
    end
  end

  defp outgoing_merge?(issue_id) do
    Repo.exists?(
      from action in ManagementAction,
        where: action.issue_id == ^issue_id and action.action == @merge_action
    )
  end

  defp escalated?("low", severity) when severity in ["medium", "high"], do: true
  defp escalated?("medium", "high"), do: true
  defp escalated?(_, _), do: false

  defp remember_evidence(issue_id, event) do
    exception = get_in(event.body, ["evidence", "exception"]) || %{}
    frames = stack_frames(exception)
    origin = get_in(event.body, ["quality", "origin"])

    parts = [event.git_sha, event.release, exception["type"], frames, origin]
    {:ok, bytes} = Canonical.encode(parts)
    digest = Canonical.digest(bytes)

    {added, _} =
      Repo.insert_all("diagnostics_issue_evidence_kinds", [%{issue_id: issue_id, digest: digest}],
        on_conflict: :nothing,
        conflict_target: [:issue_id, :digest],
        log: false
      )

    added == 1
  end

  defp fingerprint(event, finding) do
    exception = get_in(event.body, ["evidence", "exception"]) || %{}
    result = event.body["result"] || %{}
    frames = stack_frames(exception)

    # Operation phase refines failures lacking stack information. For a real
    # stack, its origin frame is more stable across observation adapters.
    boundary = if frames == [], do: result["phase"] || event.event_type, else: List.first(frames)

    signature = [
      event.body["application"],
      finding.category,
      finding.rule,
      boundary,
      exception["type"] || result["reason_code"] || exception["code"],
      frames,
      finding.details["rule"]
    ]

    {:ok, bytes} = Canonical.encode(signature)
    Canonical.digest(bytes)
  end

  defp stack_frames(exception) do
    (exception["stack"] || [])
    |> Enum.filter(&(is_binary(&1["module"]) and is_binary(&1["function"])))
    |> Enum.take(3)
    |> Enum.map(&Map.take(&1, ["module", "function", "arity"]))
  end

  defp reassign_locked(from_id, to_id, ids, actor) do
    with :ok <- lock_occurrences(from_id, ids),
         [_, _] <- lock_groups([from_id, to_id]),
         :ok <- regroupable([from_id, to_id]) do
      do_reassign(from_id, to_id, ids, actor)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_membership}
    end
  end

  defp split_locked(from_id, ids, actor) do
    with :ok <- lock_occurrences(from_id, ids),
         [%Issue{occurrence_count: count} = original] when count > length(ids) <-
           lock_groups([from_id]),
         :ok <- regroupable([from_id]) do
      {:ok, bytes} = Canonical.encode(["manual_split", original.fingerprint, Enum.sort(ids)])

      attrs = %{
        fingerprint_version: original.fingerprint_version,
        fingerprint: Canonical.digest(bytes),
        category: original.category,
        severity: original.severity,
        status: "open",
        first_seen_at: original.first_seen_at,
        last_seen_at: original.last_seen_at
      }

      Repo.insert_all(Issue, [attrs],
        on_conflict: :nothing,
        conflict_target: [:fingerprint_version, :fingerprint],
        log: false
      )

      target =
        Repo.one!(
          from issue in Issue,
            where:
              issue.fingerprint == ^attrs.fingerprint and
                issue.fingerprint_version == ^attrs.fingerprint_version,
            lock: "FOR UPDATE"
        )

      with :ok <- regroupable([target.id]),
           {:ok, _count} <- do_reassign(from_id, target.id, ids, actor) do
        {:ok, get(target.id)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_split}
    end
  end

  defp merge_locked(from_id, to_id, actor) do
    %{rows: [[locked_count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM (
          SELECT occurrence.id FROM diagnostics_occurrences AS occurrence
          JOIN diagnostics_issue_occurrences AS membership ON membership.occurrence_id = occurrence.id
          WHERE membership.issue_id = $1
          ORDER BY occurrence.id
          FOR UPDATE OF occurrence, membership
        ) AS locked_occurrences
        """,
        [from_id],
        log: false
      )

    with [_, _] = groups <- lock_groups([from_id, to_id]),
         :ok <- regroupable([from_id, to_id]),
         :ok <- unchanged_memberships(from_id, locked_count) do
      from = Enum.find(groups, &(&1.id == from_id))
      to = Enum.find(groups, &(&1.id == to_id))
      merge_memberships(from, to, actor)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp regroupable(ids) do
    cond do
      Repo.exists?(
        from action in ManagementAction,
          where: action.issue_id in ^ids and action.action == @merge_action
      ) ->
        {:error, :already_merged}

      Repo.exists?(from resolution in Resolution, where: resolution.issue_id in ^ids) ->
        {:error, :resolution_history}

      true ->
        :ok
    end
  end

  defp unchanged_memberships(issue_id, locked_count) do
    current = Repo.aggregate(from(row in Membership, where: row.issue_id == ^issue_id), :count)
    if current == locked_count, do: :ok, else: {:error, :grouping_changed}
  end

  defp merge_memberships(from, to, actor) do
    memberships = from membership in Membership, where: membership.issue_id == ^from.id
    stamp = DateTime.utc_now()

    event_key =
      memberships
      |> join(:inner, [membership], evidence in Evidence,
        on: evidence.occurrence_id == membership.occurrence_id
      )
      |> select([_, evidence], max(evidence.event_key))
      |> Repo.one!()

    audit =
      from membership in memberships,
        select: %{
          from_issue_id: membership.issue_id,
          to_issue_id: type(^to.id, :id),
          occurrence_id: membership.occurrence_id,
          actor: type(^actor, :string),
          inserted_at: type(^stamp, :utc_datetime_usec)
        }

    Repo.insert_all(GroupingAction, audit, log: false)
    Repo.update_all(memberships, [set: [issue_id: to.id]], log: false)

    from
    |> Ecto.Changeset.change(status: "duplicate", occurrence_count: 0)
    |> Repo.update!(log: false)

    if escalated?(to.severity, from.severity),
      do: to |> Ecto.Changeset.change(severity: from.severity) |> Repo.update!(log: false)

    refresh_group_bounds(to.id)
    Resolutions.audit!(from.id, @merge_action, actor, to.id)
    Repo.delete_all(from(change in Change, where: change.issue_id == ^from.id), log: false)
    if event_key, do: enqueue_change(to.id, event_key, "manual", stamp)
    {:ok, get(to.id)}
  end

  defp lock_occurrences(from_id, ids) do
    locked =
      Repo.all(
        from row in Occurrence,
          where: row.id in ^ids,
          order_by: row.id,
          lock: "FOR UPDATE",
          select: row.id
      )

    matching =
      Repo.all(
        from row in Membership,
          where: row.issue_id == ^from_id and row.occurrence_id in ^ids,
          select: row.occurrence_id
      )

    if length(locked) == length(ids) and length(matching) == length(ids) do
      :ok
    else
      {:error, :invalid_membership}
    end
  end

  defp lock_groups(ids) do
    Repo.all(from issue in Issue, where: issue.id in ^ids, order_by: issue.id, lock: "FOR UPDATE")
  end

  defp do_reassign(from_id, to_id, ids, actor) do
    Repo.update_all(
      from(row in Membership, where: row.issue_id == ^from_id and row.occurrence_id in ^ids),
      set: [issue_id: to_id]
    )

    stamp = DateTime.utc_now()

    audit =
      Enum.map(
        ids,
        &%{
          from_issue_id: from_id,
          to_issue_id: to_id,
          occurrence_id: &1,
          actor: actor,
          inserted_at: stamp
        }
      )

    Repo.insert_all(GroupingAction, audit, log: false)

    event_key =
      Repo.aggregate(from(row in Evidence, where: row.occurrence_id in ^ids), :max, :event_key)

    for id <- [from_id, to_id] do
      refresh_group_bounds(id)
      if event_key, do: enqueue_change(id, event_key, "manual", stamp)
    end

    {:ok, length(ids)}
  end

  defp refresh_group_bounds(issue_id) do
    summary =
      Repo.one!(
        from occurrence in Occurrence,
          join: membership in Membership,
          on: membership.occurrence_id == occurrence.id,
          where: membership.issue_id == ^issue_id,
          select: %{
            occurrence_count: count(occurrence.id),
            first_seen_at: min(occurrence.first_seen_at),
            last_seen_at: max(occurrence.last_seen_at)
          }
      )

    changes = summary |> Map.reject(fn {_, value} -> is_nil(value) end) |> Map.to_list()
    Repo.update_all(from(issue in Issue, where: issue.id == ^issue_id), set: changes)
  end

  defp filter(query, _key, nil), do: query
  defp filter(query, key, value), do: where(query, [row], field(row, ^key) == ^value)

  defp before(query, {datetime, id}),
    do:
      where(
        query,
        [row],
        row.last_seen_at < ^datetime or (row.last_seen_at == ^datetime and row.id < ^id)
      )

  defp before(query, _), do: query
  defp bounded_limit(opts), do: Keyword.get(opts, :limit, 30) |> max(1) |> min(100)
end
