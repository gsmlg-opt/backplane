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
  when the start receipt has not reached Goal. A committed start for the same
  run/incarnation also refuses withdrawal; Runtime may mint a different turn ID
  from the host's logical reservation ID. Goal binds that first fresh start and
  only its fresh terminal receipt releases the reservation. Receipt replays do
  not release newer reservations, including when a host reuses run identities.

  Use `:superseded` for replacement user input/session operations, and
  `:cancelled` for explicit cancellation. Cancellation persists continuation
  deferral before acknowledgement while leaving Goal status and accounting
  intact. Restore is recovery, not a substitute for conditional withdrawal.
  """
  alias Backplane.AgentRuntime.Error
  @callback record_user_instruction(term(), binary(), map()) :: :ok | {:error, Error.t()}
  @callback start_turn_if_idle(term(), binary(), map()) ::
              {:ok, {:started, map()}} | {:ok, {:not_submitted, atom()}} | {:error, Error.t()}
end
