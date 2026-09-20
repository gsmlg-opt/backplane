defmodule Backplane.AgentRuntime.RecoveryHarness do
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Recovery
  alias Backplane.AgentRuntime.Store

  @moduledoc """
  Generic durable recovery and storage conformance harness.

  The harness does not assume any specific durable backend. It runs staged
  commits, failed/stalled acknowledgements, and conservative recovery
  classification through the host-provided `StorePort`.
  """

  @type t :: map()

  @crash_windows [:before_dispatch, :after_mutation, :before_result, :after_terminal]

  @spec run(module(), term(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(impl, context, record, meta)
      when is_atom(impl) and is_map(record) and is_map(meta) do
    with {:ok, staged} <- Store.stage(impl, context, record, meta),
         {:ok, committed} <- Store.acknowledge_commit(impl, context, staged.stage, meta),
         recovery_record <-
           staged.stage.run
           |> Map.put(:effects, staged.stage.effects)
           |> Map.put(:outbox, staged.stage.outbox),
         next_incarnation <- Map.get(recovery_record, :incarnation, 0) + 1,
         {:ok, fence} <-
           Store.fence(
             impl,
             context,
             recovery_record.run_id,
             committed.revision,
             Map.get(recovery_record, :incarnation, 0),
             next_incarnation
           ),
         {:ok, recovery} <-
           Recovery.recover(recovery_record, %{incarnation: next_incarnation}) do
      {:ok,
       %{
         committed: committed,
         fence: fence,
         recovery: recovery,
         mode: staged.mode,
         stage: staged.stage
       }}
    end
  end

  @spec run_failed(module(), term(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_failed(impl, context, record, meta)
      when is_atom(impl) and is_map(record) and is_map(meta) do
    with {:ok, staged} <- Store.stage(impl, context, record, meta) do
      case Store.acknowledge_commit(impl, context, staged.stage, meta) do
        {:error, error} ->
          {:ok, %{accepted?: false, error: error, stage: staged.stage}}

        {:ok, _committed} ->
          {:error, Error.new(:unknown_outcome, "failed commit was falsely acknowledged")}
      end
    end
  end

  @spec crash_window(atom()) ::
          :before_dispatch | :after_mutation | :before_result | :after_terminal
  def crash_window(window) when window in @crash_windows, do: window

  def crash_window(_window) do
    {:error, Error.new(:validation, "invalid crash window")}
  end

  @spec crash(module(), term(), map(), map(), atom()) ::
          {:ok, map()} | {:error, Error.t()}
  def crash(impl, context, record, meta, window) do
    with {:ok, staged} <- Store.stage(impl, context, record, meta) do
      case window do
        :before_dispatch ->
          {:ok, %{accepted?: false, window: window, stage: staged.stage, safe_to_resume?: true}}

        :after_mutation ->
          {:ok, %{accepted?: false, window: window, stage: staged.stage, safe_to_resume?: false}}

        :before_result ->
          {:ok, %{accepted?: false, window: window, stage: staged.stage, safe_to_resume?: false}}

        :after_terminal ->
          {:ok, %{accepted?: true, window: window, stage: staged.stage, safe_to_resume?: false}}
      end
    end
  end
end
