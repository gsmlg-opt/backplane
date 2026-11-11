defmodule Backplane.HostAgent.Collectors.Collector do
  @moduledoc "Behaviour for host snapshot collectors run by `Collectors.Scheduler`."

  @type runner :: (String.t(), [String.t()], keyword() ->
                     {:ok, String.t()}
                     | {:error,
                        :not_found
                        | {:exit, integer()}
                        | {:exit, integer(), String.t()}
                        | :timeout})
  @type env :: %{
          required(:runner) => runner(),
          required(:os) => :linux | :darwin | :other,
          required(:home) => String.t(),
          optional(:hostname) => {:ok, charlist()},
          optional(:ifaddrs) => {:ok, [{charlist(), keyword()}]}
        }
  @type snapshot :: %{
          required(:collector) => String.t(),
          required(:unit) => String.t(),
          required(:complete) => boolean(),
          required(:items) => [map()],
          optional(:unscanned) => [String.t()]
        }

  @doc "Config section (under `capture.collectors`) that configures this collector."
  @callback config_key() :: :git | :docker | :services | :host

  @doc "Collects snapshots; returns `[]` when unavailable on this host."
  @callback collect(config :: map(), env :: env()) :: [snapshot()]

  @doc """
  Returns `value` as valid UTF-8, replacing invalid bytes with U+FFFD.

  Command output and file names are raw bytes; snapshots must JSON-encode.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(value) when is_binary(value), do: String.replace_invalid(value)
end
