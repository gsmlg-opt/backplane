defmodule Backplane.HostAgent.Collectors.Collector do
  @moduledoc "Behaviour for host snapshot collectors run by `Collectors.Scheduler`."

  @type runner :: (String.t(), [String.t()], keyword() ->
                     {:ok, String.t()} | {:error, :not_found | {:exit, integer()} | :timeout})
  @type env :: %{
          required(:runner) => runner(),
          required(:os) => :linux | :darwin | :other,
          required(:home) => String.t(),
          optional(:hostname) => {:ok, charlist()},
          optional(:ifaddrs) => {:ok, [{charlist(), keyword()}]}
        }
  @type snapshot :: %{
          collector: String.t(),
          unit: String.t(),
          complete: boolean(),
          items: [map()]
        }

  @doc "Config section (under `capture.collectors`) that configures this collector."
  @callback config_key() :: :git | :docker | :services | :host

  @doc "Collects snapshots; returns `[]` when unavailable on this host."
  @callback collect(config :: map(), env :: env()) :: [snapshot()]
end
