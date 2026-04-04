defmodule Relayixir.Config.HookConfig do
  @moduledoc """
  Agent storing opt-in dump/inspection hook functions.

  Hooks are called after each proxied request with normalized request/response structs,
  and optionally on each WebSocket frame.

  Register hooks via `Relayixir.load/1` with the `:hooks` key:

      Relayixir.load(
        hooks: [
          on_request_complete: fn req, resp -> IO.inspect({req, resp}) end,
          on_ws_frame: fn session_id, direction, frame -> IO.inspect(frame) end
        ]
      )
  """

  use Agent

  @type hook_fn :: (Relayixir.Proxy.Request.t(), Relayixir.Proxy.Response.t() | nil -> any())
  @type ws_hook_fn ::
          (String.t(), :inbound | :outbound, Relayixir.Proxy.WebSocket.Frame.t() -> any())

  def start_link(_opts) do
    Agent.start_link(fn -> %{on_request_complete: nil, on_ws_frame: nil} end, name: __MODULE__)
  end

  @doc "Returns the on_request_complete hook function, or nil if not set."
  @spec get_on_request_complete() :: hook_fn() | nil
  def get_on_request_complete do
    Agent.get(__MODULE__, & &1.on_request_complete)
  end

  @doc "Sets the on_request_complete hook function."
  @spec put_on_request_complete(hook_fn() | nil) :: :ok
  def put_on_request_complete(fun) when is_function(fun, 2) or is_nil(fun) do
    Agent.update(__MODULE__, &Map.put(&1, :on_request_complete, fun))
  end

  @doc "Returns the on_ws_frame hook function, or nil if not set."
  @spec get_on_ws_frame() :: ws_hook_fn() | nil
  def get_on_ws_frame do
    Agent.get(__MODULE__, & &1.on_ws_frame)
  end

  @doc "Sets the on_ws_frame hook function."
  @spec put_on_ws_frame(ws_hook_fn() | nil) :: :ok
  def put_on_ws_frame(fun) when is_function(fun, 3) or is_nil(fun) do
    Agent.update(__MODULE__, &Map.put(&1, :on_ws_frame, fun))
  end
end
