defmodule Relayixir.Proxy.Request do
  @moduledoc """
  Normalized struct representing an inbound proxy request.
  Populated before forwarding to upstream; available to dump hooks and telemetry handlers.
  """

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), String.t()}],
          remote_ip: :inet.ip_address() | nil,
          upstream_host: String.t()
        }

  defstruct [:method, :path, :query, :headers, :remote_ip, :upstream_host]

  @doc """
  Builds a `Request` from a `Plug.Conn` after upstream headers are prepared.
  `upstream_headers` is the header list that will be forwarded (already stripped).
  """
  @spec from_conn(Plug.Conn.t(), [{String.t(), String.t()}], String.t()) :: t()
  def from_conn(%Plug.Conn{} = conn, upstream_headers, upstream_host) do
    %__MODULE__{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: upstream_headers,
      remote_ip: conn.remote_ip,
      upstream_host: upstream_host
    }
  end
end
