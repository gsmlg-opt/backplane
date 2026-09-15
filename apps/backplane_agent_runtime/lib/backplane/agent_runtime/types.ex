defmodule Backplane.AgentRuntime.Types do
  @type kind :: :hosted | :owner_bound
  @type id :: Backplane.AgentRuntime.ID.t()

  @type agent_definition :: %{
          definition_id: id(),
          revision: non_neg_integer(),
          name: String.t(),
          profile: String.t(),
          model: map(),
          tool_profile: [String.t()],
          context_strategy: map()
        }

  @type agent_instance :: %{
          agent_id: id(),
          definition_id: id(),
          definition_revision: non_neg_integer(),
          lifecycle: kind(),
          owner: id() | nil,
          incarnation: non_neg_integer(),
          status: :active | :stopped
        }

  @type context :: %{
          context_id: id(),
          agent_id: id(),
          revision: non_neg_integer(),
          instructions: list(),
          messages: list(),
          summaries: list(),
          resources: list()
        }

  @type run_state ::
          :queued
          | :running
          | :waiting_approval
          | :waiting_result
          | :cancelling
          | :completed
          | :failed
          | :cancelled
          | :timed_out
          | :unknown_outcome

  @type run :: %{
          run_id: id(),
          task_id: id(),
          agent_id: id(),
          context_id: id(),
          root_run_id: id(),
          budget_account_id: id(),
          parent_run_id: id() | nil,
          state: run_state(),
          deadline: integer() | nil,
          outcome: map() | nil,
          children: [id()]
        }

  @type task :: %{
          task_id: id(),
          target_agent_id: id(),
          requester_agent_id: id() | nil,
          input: map(),
          idempotency_key: String.t() | nil,
          state: :submitted | :accepted | :rejected | :completed,
          run_id: id() | nil
        }

  @type tool_invocation :: %{
          invocation_id: id(),
          run_id: id(),
          tool_name: String.t(),
          tool_revision: non_neg_integer(),
          arguments: map(),
          state:
            :admitted
            | :running
            | :completed
            | :failed
            | :cancelled
            | :timed_out
            | :unknown_outcome,
          result: map() | nil
        }

  @type approval :: %{
          approval_id: id(),
          run_id: id(),
          tool_name: String.t(),
          tool_revision: non_neg_integer(),
          arguments_digest: String.t(),
          expires_at: integer(),
          decision: :pending | :approved | :denied,
          resolver_id: String.t() | nil
        }

  @type event :: %{
          event_id: id(),
          aggregate_id: String.t(),
          sequence: non_neg_integer(),
          schema_version: pos_integer(),
          type: String.t(),
          occurred_at: integer(),
          causation_id: id() | nil,
          payload: map()
        }
end
