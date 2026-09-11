defmodule Backplane.SkillProtocol.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Backplane.SkillProtocol.Cache.Ownership, []}],
      strategy: :one_for_one,
      name: Backplane.SkillProtocol.Supervisor
    )
  end
end
