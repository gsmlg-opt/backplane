defmodule Backplane.AgentRuntime.Goal.Host do
  @moduledoc """
  Host provenance and fast atomic admission through the existing thread/session owner.

  Callbacks must not synchronously reenter Goal or start hooks, Provider or tool
  effects. `start_turn_if_idle/3` receives the current `host_generation` and a
  Runtime-generated `reservation_token`. Atomically reserve both with the
  ordinary host admission, then return its run/incarnation/logical turn identity.
  Goal includes the token/generation in its successful `idle/2` admission. An
  adapter may echo these fields but must not change them.

  Release is a separate host-owned atomic decision after this callback returns.
  Before withdrawing, fence the exact token/generation against release. A
  successful `Goal.withdraw_admission/3` requires that no later execution can
  use that reservation. If release won, use ordinary Runtime cancellation even
  when the start receipt has not reached Goal, unless the exclusively owned
  executor definitively ended before Runtime admission. For that narrow case,
  atomically seal the exact token/generation against binding, admission and
  future dispatch, reconcile any uncertain startup/outbox writes, and attest
  actual executor termination and no dispatched effects through
  `Goal.settle_unstarted_admission/4`. An absent Runtime record alone is not
  proof. Keep the seal after storage errors; an unknown ACK is not settlement.
  A committed start for the same
  run/incarnation also refuses withdrawal; Runtime may mint a different turn ID
  from the host's logical reservation ID. Goal binds that first fresh start and
  only its fresh terminal receipt releases the reservation. Receipt replays do
  not release newer reservations, including when a host reuses run identities.

  Use `:superseded` for replacement user input/session operations, and
  `:cancelled` for explicit cancellation. Cancellation persists continuation
  deferral before acknowledgement while leaving Goal status and accounting
  intact. Restore is recovery, not a substitute for conditional withdrawal.

  No-start settlement also accepts `:preparation_failed`, which retires the
  reservation without fabricating a Runtime error or deferring continuation.
  A matching live binding or fresh Runtime evidence refuses settlement. Late
  binding/delegation for a pending/settled run identity is fenced; deliberate
  reuse requires explicitly passing the new complete `:admission` to binding.
  The host's external seal remains authoritative across Goal process restart.

  If a host hook already dispatched effects before Runtime admission, use the
  separate `Goal.settle_host_admission/4` with exact ordered effect results and
  terminal host result, confirmed executor DOWN and complete command/helper/pipe
  cleanup. Seal the token/generation at the same admission gate, including queued
  continuations and future starts. Cleanup does not undo visible effects.
  `:host_stopped` retires only the reservation and preserves continuation policy;
  ordinary hook vetoes must not use cancellation to force settlement. Settlement
  never schedules new work. A later real ordinary prompt may complete, then the
  host can make its normal idle decision for the same active Goal and a fresh
  token. Cold recovery must re-establish the host seal and reconcile uncertain
  Runtime/outbox activity; Goal persistence cannot recreate that external fence.
  """
  alias Backplane.AgentRuntime.Error
  @callback record_user_instruction(term(), binary(), map()) :: :ok | {:error, Error.t()}
  @callback start_turn_if_idle(term(), binary(), map()) ::
              {:ok, {:started, map()}} | {:ok, {:not_submitted, atom()}} | {:error, Error.t()}
end
