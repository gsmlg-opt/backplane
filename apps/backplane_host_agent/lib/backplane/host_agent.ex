defmodule Backplane.HostAgent do
  @moduledoc """
  Public facade for host agent operations.
  """

  alias Backplane.HostAgent.Worker

  def sync_now do
    Worker.sync_now()
  end

  def status do
    Worker.status()
  end
end
