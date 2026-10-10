defmodule Relayixir.Proxy.ConnPool do
  @moduledoc """
  Maps upstream idle-pool policy to HTTP Fetch's HTTP/1 connection reuse.

  Fetch owns sockets, liveness checks, isolation and cancellation. Its idle pool
  retains at most sixteen sockets per route and 256 across all callers.
  """

  alias Relayixir.Proxy.Upstream

  @spec options(Upstream.t()) :: keyword()
  def options(%Upstream{pool_size: size}) when is_integer(size) and size > 0 do
    [http1_reuse: true, http1_scope: "relayixir", http1_pool_size: min(size, 16)]
  end

  def options(%Upstream{}), do: []
end
