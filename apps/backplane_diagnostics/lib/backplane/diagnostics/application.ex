defmodule Backplane.Diagnostics.Application do
  @moduledoc false

  use Application

  alias Backplane.Diagnostics.{Analyses, Projector, ReportScheduler, Retention}

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:backplane_diagnostics, :workers_enabled, true) do
        [{Projector, name: Projector}, ReportScheduler, Retention.Worker, Analyses.Supervisor]
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Backplane.Diagnostics.Supervisor
    )
  end
end
