Code.require_file("../../../fixtures/staged_export_file_host.exs", __DIR__)
Code.require_file("../../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.Codex.ArchiveOutcomeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, StagedExportFileHostFixture}
  alias Backplane.AgentRuntime.Codex.MultiAgent.{Archive, StagedExport}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Shapes
  alias StagedExportFileHostFixture, as: Store

  @moduletag :tmp_dir

  defmodule ProviderFailureError do
    defexception [:kind, :message]
  end

  defmodule Host do
    defdelegate mode(), to: Store
    defdelegate load_evidence(context, ref), to: Store
    defdelegate runtime_store(context, ref), to: Store
    defdelegate load_receipt(context, ref), to: Store
    defdelegate compare_and_swap_receipt(context, id, revision, next), to: Store

    def load_recovery_journal(context, ref) do
      {:ok, record} = Store.load(context, ref["run_id"])

      {:ok,
       Enum.map(record.journal, fn entry ->
         [kind, _at, input] = Tuple.to_list(entry.command)
         {:ok, input} = Evidence.public(host_values(input))

         %{
           "revision" => entry.revision,
           "prior_revision" => entry.revision - 1,
           "prior_incarnation" => entry.incarnation,
           "incarnation" => entry.incarnation,
           "kind" => to_string(kind),
           "input" => input
         }
       end)}
    end

    defp host_values(%ProviderFailureError{} = error), do: host_values(Map.from_struct(error))

    defp host_values(value) when is_map(value) and not is_struct(value),
      do: Map.new(value, fn {key, item} -> {key, host_values(item)} end)

    defp host_values(value) when is_list(value), do: Enum.map(value, &host_values/1)
    defp host_values(value), do: value
  end

  test "foreign failed outcomes export and restore without changing authoritative records",
       context do
    {store, pin, original} = source(context.tmp_dir, failure())
    receipt = retire(store, pin)
    before = File.read!(Path.join(context.tmp_dir, "host.term"))

    assert {:ok, archive} = Archive.export({Host, store}, pin, receipt)
    assert archive["terminal_record"]["outcome_encoding"] == "term-v1"
    assert archive["terminal_record"]["outcome"] == elem(Evidence.typed_projection(failure()), 1)
    archive = archive |> JSON.encode!() |> JSON.decode!()

    assert {:ok, %{snapshot: %{run: run}}} = Archive.restore({Host, store}, archive)
    assert run == original.run
    assert {:ok, ^original} = Store.load(store, original.run.run_id)
    assert File.read!(Path.join(context.tmp_dir, "host.term")) == before

    unmarked =
      archive
      |> update_in(["terminal_record"], &Map.delete(&1, "outcome_encoding"))
      |> seal_archive()

    assert {:error, %Error{class: :validation}} = Archive.restore({Host, store}, unmarked)
  end

  test "public outcome archives retain their legacy terminal record", context do
    outcome = %{error: %{kind: :server_error, message: "overloaded"}}
    {store, pin, original} = source(context.tmp_dir, outcome)
    receipt = retire(store, pin)
    assert {:ok, archive} = Archive.export({Host, store}, pin, receipt)
    {:ok, public} = Evidence.public(outcome)

    assert archive["terminal_record"] ==
             Map.merge(hd(pin.manifest["run_refs"]), %{
               "current_incarnation" => 1,
               "revision" => original.revision,
               "historical_outcome" => "failed",
               "outcome" => public
             })

    assert {:ok, %{snapshot: %{run: run}}} = Archive.restore({Host, store}, archive)
    assert run == original.run
  end

  test "stored typed markers select their encoding and changed payloads remain incompatible",
       context do
    outcome = %{error: %{kind: :server_error, message: "overloaded"}}
    {store, pin, original} = source(context.tmp_dir, outcome)
    receipt = retire(store, pin)
    assert {:ok, archive} = Archive.export({Host, store}, pin, receipt)
    {:ok, typed} = Evidence.typed_projection(outcome)

    encoded =
      archive
      |> update_in(["terminal_record"], fn terminal ->
        terminal |> Map.put("outcome_encoding", "term-v1") |> Map.put("outcome", typed)
      end)
      |> seal_archive()

    assert {:ok, %{snapshot: %{run: run}}} = Archive.restore({Host, store}, encoded)
    assert run == original.run

    changed = encoded |> put_in(["terminal_record", "outcome"], ["changed"]) |> seal_archive()
    assert {:error, %Error{class: :resource_conflict}} = Archive.restore({Host, store}, changed)

    unknown =
      encoded |> put_in(["terminal_record", "outcome_encoding"], "term-v2") |> seal_archive()

    assert {:error, %Error{class: :validation}} = Archive.restore({Host, store}, unknown)
  end

  test "typed staged checkpoints complete after Store reopen without rewriting history",
       context do
    {store, pin, original} = source(context.tmp_dir, failure())
    assert {:ok, stage} = StagedExport.stage({Host, store}, pin, [])
    assert "term-v1:" <> _ = stage["source_checkpoint"]["outcome_digest"]
    assert "term-v1:" <> _ = stage["source_checkpoint"]["run_digest"]
    :ok = Store.put(store, {:evidence, "stage"}, stage)
    receipt = retire(store, pin)
    before = File.read!(Path.join(context.tmp_dir, "host.term"))
    :ok = Store.cleanup(store)
    {:ok, reopened} = Store.open(context.tmp_dir)
    on_exit(fn -> Store.cleanup(reopened) end)

    assert {:ok, archive} = StagedExport.complete({Host, reopened}, "stage", receipt)
    assert {:ok, ^archive} = StagedExport.complete({Host, reopened}, "stage", receipt)
    assert {:ok, %{snapshot: %{run: run}}} = Archive.restore({Host, reopened}, archive)
    assert run == original.run
    assert {:ok, ^original} = Store.load(reopened, original.run.run_id)
    assert File.read!(Path.join(context.tmp_dir, "host.term")) == before
  end

  test "staged completion selects saved fingerprint prefixes for now-public outcomes", context do
    outcome = %{error: %{kind: :server_error, message: "overloaded"}}
    {store, pin, original} = source(context.tmp_dir, outcome)
    assert {:ok, stage} = StagedExport.stage({Host, store}, pin, [])
    settled = put_in(original.run, [:context, :conversation, :goal_outbox], [])
    immutable = Map.drop(settled, [:incarnation, :expected_revision])
    assert stage["source_checkpoint"]["outcome_digest"] == Evidence.digest(outcome)
    assert stage["source_checkpoint"]["run_digest"] == Evidence.digest(immutable)

    versioned =
      stage
      |> put_in(
        ["source_checkpoint", "outcome_digest"],
        Evidence.outcome_digest(outcome, "term-v1:saved")
      )
      |> put_in(
        ["source_checkpoint", "run_digest"],
        Evidence.outcome_digest(immutable, "term-v1:saved")
      )
      |> seal_stage()

    :ok = Store.put(store, {:evidence, "versioned-stage"}, versioned)
    receipt = retire(store, pin)
    assert {:ok, _} = StagedExport.complete({Host, store}, "versioned-stage", receipt)
    assert {:ok, ^original} = Store.load(store, original.run.run_id)
  end

  test "a fresh BEAM restores typed history without loading the host exception module", context do
    {store, pin, _original} = source(context.tmp_dir, failure())
    receipt = retire(store, pin)
    assert {:ok, archive} = Archive.export({Host, store}, pin, receipt)
    :ok = Store.put(store, {:evidence, "cold-archive"}, archive)
    before = File.read!(Path.join(context.tmp_dir, "host.term"))
    :ok = Store.cleanup(store)
    result_path = Path.join(context.tmp_dir, "cold-result")
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    script = Path.expand("../../../fixtures/archive_outcome_cold.exs", __DIR__)

    assert {output, 0} =
             System.cmd(
               System.find_executable("elixir"),
               ["--erl", "+S 2:2"] ++ paths ++ [script, context.tmp_dir, result_path],
               stderr_to_stdout: true
             )

    assert output == ""
    assert File.read!(result_path) == "restored without host module\n"
    assert File.read!(Path.join(context.tmp_dir, "host.term")) == before
  end

  defp failure,
    do: %{error: %ProviderFailureError{kind: :server_error, message: "overloaded"}, outcome: :failed}

  defp source(dir, outcome) do
    {:ok, store} = Store.open(dir)
    on_exit(fn -> Store.cleanup(store) end)
    identity = Shapes.subject()["identity"]

    run = %{
      run_id: identity["run_id"],
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: :infinity,
      outcome: nil,
      children: [],
      execution_budget: %{quota: 10, used: 1},
      context: %{
        conversation: %{
          messages: [%{role: :assistant, content: "retained answer"}],
          host_feedback: [],
          goal_outbox: []
        }
      }
    }

    {:ok, _} =
      Store.store(store, run, %{command: {:admit, 1, %{state: :running, deadline: :infinity}}})

    {:ok, %{run: running}} = Store.load(store, run.run_id)

    {:ok, _} =
      Store.store(store, running, %{
        command:
          {:finish, 2, %{run_id: run.run_id, incarnation: 1, status: :failed, outcome: outcome}}
      })

    configuration = %{"provider" => "fixture"}
    ceiling = %{"grants" => []}

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => identity,
      "store_ref" => "source-store",
      "config_ref" => "config",
      "authority_ceiling_ref" => "ceiling",
      "tool_profile" => "v2",
      "admission_receipt_ref" => "admitted",
      "child_request" => %{
        "profile" => "v2",
        "message" => "work",
        "task_name" => "child",
        "options" => %{}
      },
      "configuration" => configuration,
      "authority_ceiling" => ceiling,
      "artifact_refs" => [],
      "inventory_ref" => "inventory"
    }

    obligation =
      Evidence.obligation("executor", %{"run_id" => run.run_id, "incarnation" => 1}, "admitted")

    inventory = %{
      "schema_version" => 1,
      "record_type" => "child_inventory",
      "child_identity" => identity,
      "complete" => true,
      "producer_ref" => "fixture-command-ledger",
      "obligations" => [obligation]
    }

    for {ref, value} <- [
          {"admitted", admission},
          {"config", configuration},
          {"ceiling", ceiling},
          {"inventory", inventory}
        ],
        do: :ok = Store.put(store, {:evidence, ref}, value)

    run_ref = %{
      "store_ref" => "source-store",
      "run_id" => run.run_id,
      "original_incarnation" => 1
    }

    manifest = Shapes.manifest(Shapes.subject(), [run_ref], [obligation])
    {:ok, original} = Store.load(store, run.run_id)

    pin = %{
      identity: identity,
      admission_ref: "admitted",
      manifest: manifest,
      host_metadata: %{},
      fence_ref: manifest["admission_fence_ref"]
    }

    {store, pin, original}
  end

  defp retire(store, pin) do
    bundle = Shapes.bundle(pin.manifest, Enum.map(pin.manifest["obligations"], &Shapes.observe/1))
    :ok = Store.put(store, {:evidence, "retired-evidence"}, bundle)

    assert {:ok, _} =
             Reconciliation.reconcile(
               {Host, store},
               Shapes.request(pin.manifest, "retirement", "retired-evidence")
             )

    "retirement"
  end

  defp seal_archive(archive) do
    archive
    |> Map.put(
      "archive_id",
      "archive_" <> Evidence.digest(Map.drop(archive, ~w(archive_id archive_digest)))
    )
    |> Evidence.seal("archive_digest")
  end

  defp seal_stage(stage) do
    stage
    |> Map.put(
      "stage_id",
      "stage_" <> Evidence.digest(Map.drop(stage, ~w(stage_id stage_digest)))
    )
    |> Evidence.seal("stage_digest")
  end
end
