defmodule Backplane.Monitor.HttpProxy do
  @moduledoc "Builds `Backplane.HTTPClient` connect options from HTTP(S)_PROXY/ALL_PROXY/NO_PROXY environment variables."

  alias Backplane.HTTPClient.Proxy

  @doc "Returns `connect_options` for reaching `url`, or `[]` when no proxy applies."
  @spec connect_options(String.t()) :: keyword()
  def connect_options(url) do
    case Proxy.from_env(url) do
      nil ->
        []

      {scheme, host, port, opts} ->
        case Keyword.get(opts, :headers, []) do
          [] -> [proxy: {scheme, host, port, []}]
          headers -> [proxy: {scheme, host, port, []}, proxy_headers: headers]
        end
    end
  end
end
