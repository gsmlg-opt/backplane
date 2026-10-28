defmodule Backplane.AgentRuntime.Codex.MultiAgent.StagedExport do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.MultiAgent.Archive
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @fields ~w(schema_version record_type stage_id stage_digest child_identity admission_ref admission_digest inventory_digest manifest admission_fence_ref host_metadata source_checkpoint source_journal source_journal_digest)
  @checkpoint_fields ~w(run_ref revision incarnation state outcome_digest messages_digest host_feedback_digest remaining_work deadline goal_outbox run_digest)
  @entry_fields ~w(revision prior_revision prior_incarnation incarnation kind input)

  def stage(config, pin, opts) do
    with :ok <- options(opts),
         {:ok, material, checkpoint} <- Archive.staging_material(config, pin),
         {:ok, manifest} <- Evidence.validate_manifest(pin.manifest),
         :ok <- manifest_matches(manifest, pin.identity, material.run_ref, pin.fence_ref),
         :ok <- outbox(checkpoint["goal_outbox"]),
         {:ok, journal} <- Reconciliation.load_recovery_journal(config, material.run_ref),
         :ok <- journal(journal, checkpoint),
         {:ok, record} <- Reconciliation.load_record(config, material.run_ref),
         :ok <- same(record, material.record, "source Store changed while staging export"),
         {:ok, metadata} <- Evidence.public(Keyword.get(opts, :host_metadata, pin.host_metadata)),
         {:ok, fields} <-
           Evidence.public(%{
             "schema_version" => 1,
             "record_type" => "child_export_stage",
             "child_identity" => pin.identity,
             "admission_ref" => pin.admission_ref,
             "admission_digest" => Evidence.digest(material.admission),
             "inventory_digest" => Evidence.digest(material.inventory),
             "manifest" => manifest,
             "admission_fence_ref" => pin.fence_ref,
             "host_metadata" => metadata,
             "source_checkpoint" => checkpoint,
             "source_journal" => journal,
             "source_journal_digest" => Evidence.digest(journal)
           }) do
      fields = Map.put(fields, "stage_id", "stage_" <> Evidence.digest(fields))
      Evidence.public(Evidence.seal(fields, "stage_digest"))
    end
  end

  def complete(config, stage_ref, receipt_ref) do
    with {:ok, raw} <- Reconciliation.load_evidence(config, stage_ref),
         {:ok, stage} <- validate(raw),
         pin = %{
           identity: stage["child_identity"],
           admission_ref: stage["admission_ref"],
           manifest: stage["manifest"],
           host_metadata: stage["host_metadata"]
         },
         {:ok, material, current} <- Archive.staging_material(config, pin),
         :ok <-
           same(
             Evidence.digest(material.admission),
             stage["admission_digest"],
             "staged admission changed"
           ),
         :ok <-
           same(
             Evidence.digest(material.inventory),
             stage["inventory_digest"],
             "staged inventory changed"
           ),
         :ok <-
           manifest_matches(
             pin.manifest,
             pin.identity,
             material.run_ref,
             stage["admission_fence_ref"]
           ),
         {:ok, journal} <- Reconciliation.load_recovery_journal(config, material.run_ref),
         :ok <- journal(journal, current),
         :ok <- progress(stage, current, journal),
         {:ok, archive} <- Archive.export(config, pin, receipt_ref),
         {:ok, record} <- Reconciliation.load_record(config, material.run_ref),
         :ok <- same(record, material.record, "source Store changed while completing export") do
      {:ok, archive}
    end
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:host_metadata] == [],
      do: :ok,
      else: Evidence.invalid("invalid staged export options")
  end

  defp validate(value) do
    with {:ok, value} <- Evidence.public(value),
         :ok <- Evidence.fields(value, @fields, @fields),
         :ok <- Evidence.version(value),
         :ok <- same(value["record_type"], "child_export_stage", "staged export kind differs"),
         :ok <- Evidence.subject(Archive.subject(value["child_identity"])),
         :ok <- Evidence.identifier(value["admission_ref"]),
         :ok <- Evidence.sealed(value, "stage_digest"),
         :ok <-
           same(
             value["stage_id"],
             "stage_" <> Evidence.digest(Map.drop(value, ~w(stage_id stage_digest))),
             "staged export identity differs"
           ),
         {:ok, _} <- Evidence.validate_manifest(value["manifest"]),
         :ok <- checkpoint(value["source_checkpoint"]),
         :ok <- journal(value["source_journal"], value["source_checkpoint"]),
         :ok <-
           same(
             value["source_journal_digest"],
             Evidence.digest(value["source_journal"]),
             "staged journal digest differs"
           ) do
      {:ok, value}
    end
  end

  defp checkpoint(value) do
    with :ok <- Evidence.fields(value, @checkpoint_fields, @checkpoint_fields),
         :ok <- Evidence.run_ref(value["run_ref"]),
         :ok <- Evidence.positive(value["revision"]),
         :ok <- Evidence.positive(value["incarnation"]),
         :ok <- outbox(value["goal_outbox"]) do
      :ok
    end
  end

  defp manifest_matches(manifest, identity, run_ref, fence_ref) do
    with :ok <-
           same(manifest["subject"], Archive.subject(identity), "staged manifest child differs"),
         :ok <- same(manifest["run_refs"], [run_ref], "staged manifest source differs"),
         do: same(manifest["admission_fence_ref"], fence_ref, "staged admission fence differs")
  end

  defp journal([first | _] = entries, checkpoint) do
    initial = checkpoint["run_ref"]["original_incarnation"]

    with :ok <- Evidence.fields(first, @entry_fields, @entry_fields),
         :ok <- same(first["kind"], "admit", "recovery journal must start at admission"),
         {:ok, revision, incarnation} <- Enum.reduce_while(entries, {:ok, 0, initial}, &entry/2),
         :ok <- same(revision, checkpoint["revision"], "recovery journal Store revision differs"),
         do:
           same(
             incarnation,
             checkpoint["incarnation"],
             "recovery journal Store incarnation differs"
           )
  end

  defp journal(_, _), do: Evidence.invalid("recovery journal must be a complete nonempty chain")

  defp entry(value, {:ok, prior_revision, prior_incarnation}) do
    with :ok <- Evidence.fields(value, @entry_fields, @entry_fields),
         :ok <-
           same(
             value["prior_revision"],
             prior_revision,
             "recovery journal prior revision differs"
           ),
         :ok <- same(value["revision"], prior_revision + 1, "recovery journal is not contiguous"),
         :ok <-
           same(
             value["prior_incarnation"],
             prior_incarnation,
             "recovery journal prior incarnation differs"
           ),
         :ok <- Evidence.identifier(value["kind"]),
         true <- is_map(value["input"]),
         true <- valid_incarnation?(value, prior_incarnation) do
      {:cont, {:ok, value["revision"], value["incarnation"]}}
    else
      false -> {:halt, Evidence.invalid("invalid recovery journal transition")}
      error -> {:halt, error}
    end
  end

  defp valid_incarnation?(%{"kind" => "fence", "incarnation" => next, "input" => input}, prior),
    do: is_integer(next) and next > prior and input == %{}

  defp valid_incarnation?(%{"incarnation" => next}, prior), do: next == prior

  defp progress(stage, current, journal) do
    source = stage["source_checkpoint"]
    prefix = stage["source_journal"]
    immutable_fields = @checkpoint_fields -- ~w(revision incarnation goal_outbox)

    with :ok <-
           same(
             Enum.take(journal, length(prefix)),
             prefix,
             "staged source journal prefix changed"
           ),
         :ok <-
           same(
             Map.take(current, immutable_fields),
             Map.take(source, immutable_fields),
             "staged source checkpoint changed"
           ),
         {:ok, remaining} <-
           suffix(Enum.drop(journal, length(prefix)), source["goal_outbox"], current["run_ref"]),
         do:
           same(
             current["goal_outbox"],
             remaining,
             "Goal outbox changed without exact journal acknowledgement"
           )
  end

  defp suffix(entries, pending, run_ref) do
    Enum.reduce_while(entries, {:ok, pending}, fn
      %{"kind" => "fence"}, acc ->
        {:cont, acc}

      %{"kind" => "goal_outbox_acknowledged", "input" => input} = entry, {:ok, pending} ->
        case acknowledge(input, entry, pending, run_ref) do
          {:ok, remaining} -> {:cont, {:ok, remaining}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, conflict("staged export permits only exact Goal ACK and recovery fencing")}
    end)
  end

  defp acknowledge(input, entry, pending, run_ref) do
    receipts = input["receipts"]

    with :ok <-
           Evidence.fields(
             input,
             ~w(run_id incarnation receipts),
             ~w(run_id incarnation receipts)
           ),
         :ok <- same(input["run_id"], run_ref["run_id"], "Goal ACK run differs"),
         :ok <- same(input["incarnation"], entry["incarnation"], "Goal ACK incarnation differs"),
         :ok <- outbox(receipts),
         true <- receipts != [] and Enum.all?(receipts, &(&1 in pending)) do
      {:ok, Enum.reject(pending, &(&1 in receipts))}
    else
      false -> conflict("Goal ACK does not match staged receipt identities")
      error -> error
    end
  end

  defp outbox(value) when is_list(value) do
    ids = Enum.map(value, fn entry -> if is_map(entry), do: entry["receipt_id"] end)

    with :ok <- Evidence.each(ids, &Evidence.identifier/1),
         true <- length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      false -> Evidence.invalid("Goal outbox receipt identities must be unique")
      error -> error
    end
  end

  defp outbox(_), do: Evidence.invalid("Goal outbox must be a bounded receipt list")
  defp same(value, value, _), do: :ok
  defp same(_, _, message), do: conflict(message)
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
end
