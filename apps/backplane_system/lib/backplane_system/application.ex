defmodule BackplaneSystem.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Repo,
      {Phoenix.PubSub, name: Backplane.PubSub},
      Backplane.Settings.TokenCache,
      Backplane.Settings.Credentials.Vault,
      Backplane.Settings.OAuthStateStore,
      Backplane.Settings,
      Backplane.Registry.ToolRegistry,
      Backplane.Registry.PromptCatalog,
      Backplane.Registry.PromptRegistry,
      Backplane.Metrics
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneSystem.Supervisor)
  end

  @impl true
  def stop(_state) do
    Backplane.Registry.PromptCatalog.cleanup()
    :ok
  end
end
