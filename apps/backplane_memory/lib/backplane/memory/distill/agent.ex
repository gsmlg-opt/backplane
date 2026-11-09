defmodule Backplane.Memory.Distill.Agent do
  @moduledoc """
  Runs the memory agent over one session chunk.

  Each run is a bounded `Backplane.AgentRuntime.Conversation` (ephemeral store,
  five memory tools, `work: 40`, `run_timeout: 240_000`) owned by a task under
  `Backplane.Memory.Distill.TaskSupervisor`. The result counts records newly
  inserted by `write_memory` / `replace_memory`; idempotent request_key hits are
  not counted. A run that completes without ever calling `read_chunk` means the
  model ignored the tools, so it is an error naming the model rather than a
  silent zero-record success.

  Options: `:provider` (default `:distill_provider` app env, else
  `Backplane.Memory.Distill.Provider`), `:provider_context` (merged into the
  provider context), `:chunk_index` (default 0), `:model` (name used in errors;
  default `memory.llm_model`).
  """

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}
  alias Backplane.Memory.Config
  alias Backplane.Memory.Distill.{Prompts, ToolBackend}

  @work 40
  @run_timeout 240_000
  @receive_timeout 250_000
  @prompt "Process this session chunk."

  @spec run_chunk(map(), [map()], String.t(), keyword()) ::
          {:ok, %{records_written: non_neg_integer()}} | {:error, String.t()}
  def run_chunk(session, chunk, mode, opts \\ []) when mode in ["distill", "review"] do
    task =
      Task.Supervisor.async_nolink(Backplane.Memory.Distill.TaskSupervisor, fn ->
        run(session, chunk, mode, opts)
      end)

    case Task.yield(task, @receive_timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "memory agent crashed: " <> Exception.format_exit(reason)}
      nil -> {:error, "memory agent timed out"}
    end
  end

  defp run(session, chunk, mode, opts) do
    context = ToolBackend.context(session, chunk, mode)
    run_id = run_id(context.subject_id, Keyword.get(opts, :chunk_index, 0))

    with {:ok, registry} <- registry(context),
         {:ok, store} <- EphemeralStore.new(1),
         {:ok, pid} <- start_conversation(run_id, store, registry, mode, opts) do
      try do
        await(pid, run_id, context, opts)
      after
        stop(pid)
      end
    else
      {:error, error} -> {:error, "memory agent could not start: " <> reason(error)}
    end
  end

  defp start_conversation(run_id, store, registry, mode, opts) do
    provider =
      opts[:provider] ||
        Application.get_env(
          :backplane_memory,
          :distill_provider,
          Backplane.Memory.Distill.Provider
        )

    Conversation.start_link(
      run_id: run_id,
      store: EphemeralStore,
      context: store,
      provider: provider,
      provider_context: Keyword.get(opts, :provider_context, %{}),
      registry: registry,
      subscriber: self(),
      authority: %{
        caller: "backplane_memory",
        run_id: run_id,
        grants: ToolBackend.tool_names(),
        tool_revision: 1
      },
      messages: [%{role: :system, content: Prompts.system(mode)}],
      work: @work,
      run_timeout: @run_timeout
    )
  end

  defp await(pid, run_id, context, opts) do
    with {:ok, _} <- Conversation.prompt(pid, @prompt) do
      receive do
        {:agent_runtime, ^run_id, %{type: :run_completed}} ->
          completed(context, opts)

        {:agent_runtime, ^run_id, %{type: type} = event}
        when type in [:run_failed, :run_cancelled] ->
          {:error, failure(event)}
      after
        @receive_timeout -> {:error, "memory agent run timed out"}
      end
    else
      {:error, error} -> {:error, "memory agent prompt rejected: " <> reason(error)}
    end
  end

  defp completed(context, opts) do
    if :counters.get(context.reads, 1) == 0 do
      model = Keyword.get(opts, :model) || Config.llm_model() || "(unset)"
      {:error, "model #{model} made no tool calls; memory.llm_model must support tool calling"}
    else
      {:ok, %{records_written: :counters.get(context.written, 1)}}
    end
  end

  defp registry(context) do
    context
    |> ToolBackend.descriptors()
    |> Enum.reduce_while({:ok, %ToolRegistry{}}, fn descriptor, {:ok, registry} ->
      case ToolRegistry.register(registry, descriptor) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        error -> {:halt, error}
      end
    end)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp run_id(subject_id, chunk_index) do
    "distill-#{subject_id}-#{chunk_index}-#{System.unique_integer([:positive])}"
  end

  defp failure(%{type: type, outcome: %{error: error}}) when not is_nil(error),
    do: reason(error) |> prefixed(type)

  defp failure(%{type: type}), do: prefixed("no error reported", type)

  defp prefixed(text, :run_cancelled), do: "memory agent run cancelled: " <> text
  defp prefixed(text, _), do: text

  defp reason(%Error{message: message}) when is_binary(message), do: message
  defp reason(text) when is_binary(text), do: text
  defp reason(%{message: message}) when is_binary(message), do: message
  defp reason(other), do: inspect(other)
end
