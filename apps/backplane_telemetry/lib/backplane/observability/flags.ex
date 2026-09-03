defmodule Backplane.Observability.Flags do
  @moduledoc """
  Temporary Observability v2 feature flags.

  Flags live in application configuration under `:backplane_telemetry` with
  safe defaults (`false`) so PR-00 does not change production behavior.
  Operational dynamic settings arrive in a later PR.
  """

  @app :backplane_telemetry

  @flags [
    :observability_v2_enabled,
    :observability_v2_llm_write,
    :observability_v2_mcp_write,
    :observability_v2_runtime_sink
  ]

  @doc "Returns true when the Observability v2 master switch is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: get(:observability_v2_enabled)

  @doc "Returns true when LLM v2 durable writers should persist records."
  @spec llm_write?() :: boolean()
  def llm_write?, do: enabled?() and get(:observability_v2_llm_write)

  @doc "Returns true when MCP v2 durable writers should persist records."
  @spec mcp_write?() :: boolean()
  def mcp_write?, do: enabled?() and get(:observability_v2_mcp_write)

  @doc "Returns true when the v2 runtime sink should replace legacy logger routing."
  @spec runtime_sink?() :: boolean()
  def runtime_sink?, do: enabled?() and get(:observability_v2_runtime_sink)

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
end
