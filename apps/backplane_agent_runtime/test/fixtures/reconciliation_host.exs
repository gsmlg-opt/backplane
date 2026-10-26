defmodule Backplane.AgentRuntime.ReconciliationHostFixture do
  @moduledoc false
  alias Backplane.AgentRuntime.{EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  def mode, do: :ephemeral

  def new do
    table = :ets.new(__MODULE__, [:set, :public])
    {:ok, store} = EphemeralStore.new(1)
    %{table: table, store: store}
  end

  def config(context), do: {__MODULE__, context}

  def put(context, key, value) do
    :ets.insert(context.table, {key, value})
    :ok
  end

  def get(context, key) do
    case :ets.lookup(context.table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, Error.new(:not_found, "fixture record is absent")}
    end
  end

  def load_evidence(context, ref), do: get(context, {:evidence, ref})
  def load_receipt(context, id), do: get(context, {:receipt, id})

  def runtime_store(context, ref) do
    case get(context, {:store, ref}) do
      {:ok, value} -> {:ok, value}
      {:error, %Error{class: :not_found}} -> {:ok, {EphemeralStore, context.store}}
    end
  end

  def compare_and_swap_receipt(context, id, expected, next) do
    result =
      case load_receipt(context, id) do
        {:error, %Error{class: :not_found}} when expected == 0 ->
          if :ets.insert_new(context.table, {{:receipt, id}, next}),
            do: {:ok, next},
            else: conflict()

        {:ok, %{"revision" => ^expected} = old} ->
          spec = [
            {{{:receipt, id}, :"$1"}, [{:==, :"$1", {:const, old}}],
             [{:const, {{:receipt, id}, next}}]}
          ]

          if :ets.select_replace(context.table, spec) == 1,
            do: {:ok, next},
            else: conflict()

        _ ->
          conflict()
      end

    case :ets.take(context.table, :lose_next_receipt_ack) do
      [_] -> {:error, Error.new(:unknown_outcome, "fixture lost receipt acknowledgement")}
      [] -> result
    end
  end

  def seed_run(context, id, opts \\ []) do
    incarnation = Keyword.get(opts, :incarnation, 1)

    run = %{
      run_id: id,
      incarnation: incarnation,
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
          mailbox: [],
          follow_up: [],
          steering: []
        }
      }
    }

    {:ok, _} =
      EphemeralStore.store(context.store, run, %{command: {:admit, 1, %{state: :running}}})

    {:ok, %{run: run}} = EphemeralStore.load(context.store, id)

    command =
      case Keyword.get(opts, :state, :completed) do
        :completed ->
          {:finish, 2,
           %{
             run_id: id,
             incarnation: incarnation,
             status: :completed,
             outcome: %{"text" => "done"}
           }}

        :unknown_outcome ->
          {:cancel, 2}
      end

    {:ok, _} = EphemeralStore.store(context.store, run, %{command: command})
    {:ok, %{run: run}} = EphemeralStore.load(context.store, id)

    if Keyword.get(opts, :state) == :unknown_outcome do
      {:ok, _} =
        EphemeralStore.store(context.store, run, %{
          command:
            {:cleanup_settled, 3, %{certainty: :uncertain, evidence: %{reason: "lost closure"}}}
        })
    end

    EphemeralStore.load(context.store, id)
  end

  def subject(run_id \\ "child-run") do
    %{
      "kind" => "child",
      "identity" => %{
        "scope_id" => "scope",
        "root_agent_id" => "root-agent",
        "source_manager_id" => "old-manager",
        "agent_id" => "logical-child",
        "name" => "/root/child",
        "parent_id" => "root-agent",
        "parent_name" => "/root",
        "attempt_id" => "old-manager:1",
        "run_id" => run_id,
        "run_incarnation" => 1
      }
    }
  end

  def bundle(manifest, observations \\ []) do
    %{
      "schema_version" => 1,
      "manifest" => manifest,
      "admission_fence" => %{
        "reference" => manifest["admission_fence_ref"],
        "subject" => manifest["subject"],
        "manifest_digest" => manifest["manifest_digest"],
        "revision" => 1,
        "exclusive" => true,
        "producer_ref" => "fixture-owned-admission-ledger"
      },
      "inventory" => %{
        "manifest_digest" => manifest["manifest_digest"],
        "revision" => 1,
        "producer_ref" => "fixture-owned-effect-ledger",
        "complete" => true,
        "obligations" => manifest["obligations"]
      },
      "observations" => observations,
      "run_fences" => [],
      "policy_records" => %{},
      "archives" => %{},
      "artifacts" => %{}
    }
  end

  def observe(obligation, result \\ "stopped") do
    %{
      "observation_id" => "observed:" <> obligation["obligation_id"],
      "observation_revision" => 1,
      "obligation_id" => obligation["obligation_id"],
      "identity" => obligation["identity"],
      "result" => result,
      "source_ref" => "fixture-actual-component-exit",
      "observed_at_unix_ms" => 10
    }
  end

  def manifest(subject, refs \\ [], obligations \\ []) do
    Evidence.manifest(subject, refs, obligations, "fixture-admission-fence")
  end

  def request(manifest, id \\ "retirement", ref \\ "evidence") do
    %{
      "schema_version" => 1,
      "receipt_id" => id,
      "expected_revision" => 0,
      "subject" => manifest["subject"],
      "evidence_ref" => ref
    }
  end

  defp conflict, do: {:error, Error.new(:resource_conflict, "fixture receipt CAS conflict")}
end
