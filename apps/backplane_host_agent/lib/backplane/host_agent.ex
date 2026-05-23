defmodule Backplane.HostAgent do
  @moduledoc """
  Public facade for host agent operations.
  """

  alias Backplane.HostAgent.Worker

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
