defmodule Backplane.HostAgent do
  @moduledoc """
  Public facade for host agent operations.
  """

  alias Backplane.HostAgent.Worker

  @version_suffix if Mix.env() == :dev, do: "-dev", else: ""

  @doc "Returns the host-agent version with a development suffix for development builds."
  @spec version() :: String.t()
  def version do
    to_string(Application.spec(:backplane_host_agent, :vsn)) <> @version_suffix
  end

  def sync_now do
    if Process.whereis(Worker) do
      Worker.sync_now()
    else
      {:error, :not_configured}
    end
  end

  def status do
    if Process.whereis(Worker) do
      Worker.status()
    else
      %{last_sync: nil, last_error: :not_configured}
    end
  end
end
