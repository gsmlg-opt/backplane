defmodule Backplane.Skills.AgentManage.ChannelPush do
  @moduledoc false

  def push(channel_pid, event, payload) when is_pid(channel_pid) and is_binary(event) do
    send(channel_pid, {:agent_push, event, payload})
    :ok
  end
end
