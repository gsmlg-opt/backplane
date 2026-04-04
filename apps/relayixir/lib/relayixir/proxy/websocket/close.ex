defmodule Relayixir.Proxy.WebSocket.Close do
  @moduledoc """
  Close code/reason mapping and shutdown behavior for WebSocket proxy sessions.
  """

  @normal_codes [1000, 1001]
  @default_close_timeout 5_000

  alias Relayixir.Proxy.WebSocket.Frame

  @spec normal_close_code?(non_neg_integer()) :: boolean()
  def normal_close_code?(code) when code in @normal_codes, do: true
  def normal_close_code?(_), do: false

  @spec close_timeout() :: non_neg_integer()
  def close_timeout, do: @default_close_timeout

  @doc """
  Returns the appropriate close code for upstream connection failure after HTTP 101.
  """
  @spec upstream_failure_code() :: non_neg_integer()
  def upstream_failure_code, do: 1014

  @doc """
  Returns the appropriate close code for an internal proxy error.
  """
  @spec internal_error_code() :: non_neg_integer()
  def internal_error_code, do: 1011

  @doc """
  Returns a close frame for upstream connect failure (post-upgrade).
  """
  @spec upstream_connect_failed_frame() :: Frame.t()
  def upstream_connect_failed_frame do
    Frame.close(1014, "Bad Gateway")
  end

  @doc """
  Returns a close frame for internal error.
  """
  @spec internal_error_frame() :: Frame.t()
  def internal_error_frame do
    Frame.close(1011, "Internal Error")
  end

  @doc """
  Returns a normal close frame.
  """
  @spec normal_close_frame() :: Frame.t()
  def normal_close_frame do
    Frame.close(1000, "")
  end

  @doc """
  Determines shutdown behavior based on close initiator and state.
  Returns {:propagate, frame} to forward close to the other side,
  or :terminate to end immediately.
  """
  @spec shutdown_action(atom(), non_neg_integer() | nil, String.t() | nil) ::
          {:propagate_to_upstream, Frame.t()} | {:propagate_to_downstream, Frame.t()} | :terminate
  def shutdown_action(:downstream_close, code, reason) do
    {:propagate_to_upstream, Frame.close(code, reason)}
  end

  def shutdown_action(:upstream_close, code, reason) do
    {:propagate_to_downstream, Frame.close(code, reason)}
  end

  def shutdown_action(:upstream_failure, _code, _reason) do
    {:propagate_to_downstream, upstream_connect_failed_frame()}
  end

  def shutdown_action(:handler_death, _code, _reason) do
    :terminate
  end
end
