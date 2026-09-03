defmodule Backplane.Observability.Flags do
  @moduledoc """
  Observability v2 feature flags.

  Application configuration remains available for tests and boot overrides.
  Operational policy is read from `Backplane.Observability.Settings` when app
  flags are not explicitly enabled.
  """

  @app :backplane_telemetry

  @flags [
    :observability_v2_enabled,
    :observability_v2_llm_write,
    :observability_v2_mcp_write,
    :observability_v2_runtime_sink,
    :use_legacy_telemetry_logger
  ]

  @doc "Returns true when the Observability v2 master switch is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    app_override?(:observability_v2_enabled) or domain_settings_enabled?()
  end

  @doc "Returns true when LLM v2 durable writers should persist records."
  @spec llm_write?() :: boolean()
  def llm_write? do
    app_override?(:observability_v2_llm_write) or llm_persist_from_settings?()
  end

  @doc "Returns true when MCP v2 durable writers should persist records."
  @spec mcp_write?() :: boolean()
  def mcp_write? do
    app_override?(:observability_v2_mcp_write) or mcp_persist_from_settings?()
  end

  @doc """
  Returns true when the v2 runtime sink should replace legacy logger routing.

  Defaults to the active Observability v2 policy from settings. Boot-time app env
  flags remain available for tests and explicit overrides.
  """
  @spec runtime_sink?() :: boolean()
  def runtime_sink? do
    cond do
      legacy_runtime_logger_forced?() -> false
      app_override?(:observability_v2_runtime_sink) -> true
      enabled?() -> true
      true -> false
    end
  end

  @doc "Returns a map of raw flag values (ignores master-switch gating)."
  @spec snapshot() :: %{atom() => boolean()}
  def snapshot do
    Map.new(@flags, fn flag -> {flag, get(flag)} end)
  end

  @doc false
  @spec get(atom()) :: boolean()
  def get(flag) when flag in @flags do
    Application.get_env(@app, flag, false) == true
  end

  defp app_override?(flag) do
    get(:observability_v2_enabled) and get(flag)
  end

  defp domain_settings_enabled? do
    settings_available?() and
      (Backplane.Observability.Settings.llm_proxy_enabled?() or
         Backplane.Observability.Settings.mcp_proxy_enabled?())
  end

  defp llm_persist_from_settings? do
    settings_available?() and
      Backplane.Observability.Settings.llm_proxy_enabled?() and
      Backplane.Observability.Settings.llm_proxy_persist?()
  end

  defp mcp_persist_from_settings? do
    settings_available?() and
      Backplane.Observability.Settings.mcp_proxy_enabled?() and
      Backplane.Observability.Settings.mcp_proxy_persist?()
  end

  defp settings_available? do
    Code.ensure_loaded?(Backplane.Observability.Settings) and
      Process.whereis(Backplane.Observability.Settings) != nil
  end

  defp legacy_runtime_logger_forced? do
    Application.get_env(@app, :use_legacy_telemetry_logger, false) == true
  end
end
