defmodule Backplane.DiagnosticsClient.Integrations.Task do
  @moduledoc "Carries diagnostics context across Tasks and captures existing monitor notifications."

  alias Backplane.DiagnosticsClient.Context
  alias Backplane.DiagnosticsClient.Integrations.Capture

  def with_context(fun) when is_function(fun, 0) do
    context = Context.current()
    fn -> Context.with_context(context, fn -> run_task(fun) end) end
  end

  defp run_task(fun) do
    fun.()
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Capture.report("exception", kind, reason, stack)
      :erlang.raise(kind, reason, stack)
  end

  def failed(pid, {reason, frames}, opts) when is_pid(pid) and is_list(frames),
    do: Capture.report("worker_exit", :exit, reason, frames, Keyword.put(opts, :pid, pid))

  def failed(pid, reason, opts) when is_pid(pid),
    do: Capture.report("worker_exit", :exit, reason, [], Keyword.put(opts, :pid, pid))
end
