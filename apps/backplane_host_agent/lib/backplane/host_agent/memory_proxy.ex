defmodule Backplane.HostAgent.MemoryProxy do
  @moduledoc """
  Forwards memory requests from the local HTTP API to the Backplane hub
  through the established host-agent WebSocket channel.

  The channel pid + host_id are stashed by `Mix.Tasks.Agent.Run` after the
  channel is joined; the router reads them at request time.
  """

  alias Backplane.HostAgent.Channel

  @methods ~w(remember recall list forget stats)
  @method_set MapSet.new(@methods)

  @doc "List of memory methods exposed by the HTTP API."
  def methods, do: @methods

  @doc "True if `method` is one of the supported memory methods."
  def valid_method?(method) when is_binary(method), do: MapSet.member?(@method_set, method)
  def valid_method?(_), do: false

  @doc """
  Set the live channel pid that proxy requests should be pushed through.
  """
  @spec set_channel(pid() | nil) :: :ok
  def set_channel(nil) do
    _ = :persistent_term.erase(__MODULE__)
    :ok
  end

  def set_channel(pid) when is_pid(pid) do
    :persistent_term.put(__MODULE__, pid)
    :ok
  end

  @doc "Get the current channel pid, or nil."
  @spec channel() :: pid() | nil
  def channel do
    :persistent_term.get(__MODULE__, nil)
  end

  @doc """
  Invoke a memory method with `args`. `agent_id` is required and is injected
  into the arguments before being forwarded to the hub.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(method, args, opts \\ []) when is_binary(method) and is_map(args) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    cond do
      not valid_method?(method) ->
        {:error, {:unknown_method, method}}

      is_nil(channel()) ->
        {:error, :not_connected}

      true ->
        payload = %{
          "method" => method,
          "arguments" => Map.put(args, "agent_id", agent_id)
        }

        push_module =
          Keyword.get(opts, :channel_module) ||
            Application.get_env(:backplane_host_agent, :channel_module, Channel)

        case push_module.push(channel(), "memory_call", payload) do
          {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
          {:ok, %{"error" => error}} -> {:error, error}
          {:ok, reply} -> {:ok, reply}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_reply, other}}
        end
    end
  end
end
