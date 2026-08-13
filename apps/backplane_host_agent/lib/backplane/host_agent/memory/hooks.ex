defmodule Backplane.HostAgent.Memory.Hooks do
  @moduledoc """
  Dispatches locally verified runtime hook contracts to capture normalizers.

  Claude Code and Codex are supported. OpenCode is deliberately unsupported:
  no OpenCode runtime or versioned hook contract is present in this repository,
  so accepting that integration would make an unverified compatibility claim.
  """

  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode
  alias Backplane.HostAgent.Memory.Hooks.Codex

  @adapters %{"claude_code" => ClaudeCode, "codex" => Codex}

  @doc "Normalizes a hook through a locally verified adapter."
  def normalize(integration, hook, source, runtime) do
    case Map.fetch(@adapters, integration) do
      {:ok, adapter} -> adapter.normalize(hook, source, runtime)
      :error -> {:error, :unsupported_integration}
    end
  end

  @doc "Returns the explicit availability disposition for a runtime."
  def availability(integration) when integration in ["claude_code", "codex"],
    do: {:supported, Map.fetch!(@adapters, integration)}

  def availability("opencode"), do: {:unsupported, :local_hook_contract_unavailable}
  def availability(_integration), do: {:unsupported, :unknown_integration}

  @doc "Returns a truthful runtime hook inventory when the adapter publishes one."
  def inventory(integration) do
    case availability(integration) do
      {:supported, adapter} ->
        hooks =
          if Code.ensure_loaded?(adapter) and function_exported?(adapter, :supported_hooks, 0),
            do: adapter.supported_hooks(),
            else: []

        %{status: :supported, adapter: adapter, hooks: hooks, hook_count: length(hooks)}

      {:unsupported, reason} ->
        %{status: :unsupported, reason: reason, hooks: [], hook_count: 0}
    end
  end
end
