defmodule Backplane.McpProtocol.ToolCallTransport do
  @moduledoc false

  @behaviour Backplane.McpProtocol.Transport.Behaviour

  @impl true
  def start_link(_opts), do: {:ok, self()}

  @impl true
  def send_message(agent, encoded, opts) do
    {test_pid, action} =
      Agent.get_and_update(agent, fn state ->
        {action, actions} = pop_action(state.actions)
        {{state.test_pid, action}, %{state | actions: actions}}
      end)

    message = JSON.decode!(encoded)
    send(test_pid, {:tool_call_send, self(), message, opts})
    execute(action)
  end

  @impl true
  def shutdown(_agent), do: :ok

  @impl true
  def supported_protocol_versions, do: :all

  defp pop_action([action | actions]), do: {action, actions}
  defp pop_action([]), do: {:ok, []}

  defp execute(:ok), do: :ok
  defp execute({:error, reason}), do: {:error, reason}

  defp execute({:block, gate}) do
    receive do
      {^gate, result} -> result
    end
  end

  defp execute({:trap_block, gate}) do
    Process.flag(:trap_exit, true)

    receive do
      {^gate, result} -> result
    end
  end
end
