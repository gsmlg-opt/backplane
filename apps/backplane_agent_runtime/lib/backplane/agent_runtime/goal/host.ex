defmodule Backplane.AgentRuntime.Goal.Host do
  @moduledoc "Host provenance and fast atomic admission through the existing thread/session owner. Callbacks must not synchronously reenter Goal."
  alias Backplane.AgentRuntime.Error
  @callback record_user_instruction(term(), binary(), map()) :: :ok | {:error, Error.t()}
  @callback start_turn_if_idle(term(), binary(), map()) ::
              {:ok, {:started, map()}} | {:ok, {:not_submitted, atom()}} | {:error, Error.t()}
end
