defmodule BackplaneSystem.Application do
  @moduledoc false

  use Application

  alias Backplane.Audit.{Buffer, Writer}

  @impl true
  def start(_type, _args) do
    children =
      [
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
      |> maybe_audit_writer()

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneSystem.Supervisor)
  end

  @impl true
  def stop(_state) do
    Backplane.Registry.PromptCatalog.cleanup()
    Writer.drain()
    :ok
  end

  defp maybe_audit_writer(children) do
    if audit_writer_enabled?() do
      children ++
        [
          {Buffer, [name: :audit, capacity: audit_queue_capacity()]},
          {Writer, audit_writer_opts()}
        ]
    else
      children
    end
  end

  defp audit_writer_enabled? do
    Application.get_env(:backplane_system, :start_audit_writer, true) and audit_enabled?()
  end

  defp audit_enabled? do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :audit_enabled?, [])
    else
      Application.get_env(:backplane, :audit_enabled, true)
    end
  end

  defp audit_queue_capacity do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :queue_capacity, [:audit])
    else
      Buffer.default_capacity()
    end
  end

  defp audit_writer_opts do
    Application.get_env(:backplane_system, :audit_writer, [])
  end

  defp settings_available? do
    Code.ensure_loaded?(Backplane.Observability.Settings) and
      Process.whereis(Backplane.Observability.Settings) != nil
  end
end
