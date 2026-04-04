defmodule Relayixir.Proxy.Response do
  @moduledoc """
  Normalized struct representing an upstream proxy response.
  Populated after the upstream response headers are received; available to dump hooks.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          duration_ms: non_neg_integer()
        }

  defstruct [:status, :headers, :duration_ms]

  @doc """
  Builds a `Response` from the upstream response data.
  """
  @spec new(non_neg_integer(), [{String.t(), String.t()}], non_neg_integer()) :: t()
  def new(status, headers, duration_ms) do
    %__MODULE__{status: status, headers: headers, duration_ms: duration_ms}
  end
end
