defmodule Backplane.AgentRuntime.Collaboration do
  alias Backplane.AgentRuntime.{AgentHost, Error, Inbox, Outbox, RunTree}

  @moduledoc "Host-controlled, opt-in collaboration operations."

  @v1 [:spawn_agent, :send_input, :resume_agent, :wait_agent, :close_agent]
  @v2 [:spawn_agent, :send_message, :followup_task, :interrupt_agent, :list_agents, :wait_agent]
  @known [
           :agent_discover,
           :agent_spawn,
           :agent_delegate,
           :agent_send,
           :run_status,
           :run_wait,
           :run_cancel,
           :ask_user
         ] ++ @v1 ++ @v2

  def register_tools(host, opts \\ []) when is_map(host) and is_list(opts) do
    selected = Keyword.get(opts, :tools, [])
    profile = Keyword.get(opts, :profile)

    cond do
      not is_list(selected) ->
        {:error, Error.new(:validation, "collaboration tools must be a list")}

      Enum.any?(selected, &(&1 not in @known)) ->
        {:error, Error.new(:validation, "invalid collaboration tool name")}

      is_nil(profile) and Enum.any?(selected, &(&1 not in [:agent_discover, :run_status])) ->
        unavailable(:collaboration_profile)

      profile not in [nil, :v1, :v2] ->
        {:error, Error.new(:validation, "invalid collaboration profile")}

      profile && Enum.any?(selected, &(&1 not in profile_tools(profile))) ->
        {:error,
         Error.new(
           :unsupported_capability,
           "tool is not available in selected collaboration profile"
         )}

      true ->
        {:ok, Map.put(host, :collaboration_profile, profile), selected}
    end
  end

  def profile_tools(:v1), do: @v1
  def profile_tools(:v2), do: @v2
  def profile_tools(_), do: []

  def discover(host, viewer, prefix) when is_map(host) and is_binary(prefix) do
    cond do
      not (prefix != "" and String.ends_with?(prefix, ":")) ->
        {:error, Error.new(:validation, "invalid agent namespace prefix")}

      not (is_binary(viewer) and viewer_namespace(viewer) == prefix) ->
        {:ok, []}

      true ->
        {:ok,
         host.agents |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()}
    end
  end

  def spawn(host, request), do: spawn_agent(host, request)

  def spawn_agent(host, request) when is_map(host) and is_map(request) do
    with :ok <- enabled(host, :spawn_agent),
         {:ok, parent} <- caller_run(host, request),
         {:ok, child_id} <- required(request, :agent_id),
         {:ok, run_id} <- optional_id(request, :run_id, "#{child_id}:run"),
         {:ok, host, _} <-
           AgentHost.register(host, %{
             agent_id: child_id,
             lifecycle: :owner_bound,
             owner: parent.run_id
           }),
         {:ok, host, receipt} <- AgentHost.submit(host, child_id, %{run_id: run_id}),
         {:ok, tree} <- tree_for(host, parent.run_id),
         {:ok, tree, _} <- RunTree.add_child(tree, parent.run_id, %{run_id: run_id, owner: :run}) do
      run =
        Map.merge(Map.fetch!(host.runs, run_id), %{
          parent_run_id: parent.run_id,
          owner: :run,
          context_id: Map.get(request, :context_id),
          state: :running
        })

      host =
        host
        |> put_in([:runs, run_id], run)
        |> Map.update(:run_tree, %{parent.run_id => tree}, &Map.put(&1, parent.run_id, tree))

      {:ok, host,
       %{agent_id: child_id, run_id: run_id, parent_run_id: parent.run_id, status: receipt.status}}
    end
  end

  def delegate(host, request) when is_map(host) and is_map(request) do
    with :ok <- enabled(host, :agent_delegate),
         {:ok, parent} <- caller_run(host, request),
         {:ok, target} <- required(request, :target_agent_id),
         {:ok, key} <- required(request, :idempotency_key),
         :ok <- target_exists(host, target),
         {:ok, outbox} <- outbox_for(host, parent.run_id),
         {:ok, outbox, receipt} <-
           Outbox.submit(outbox, key, Map.take(request, [:target_agent_id, :input, :task_class])) do
      {:ok,
       Map.update(
         host,
         :outboxes,
         %{parent.run_id => outbox},
         &Map.put(&1, parent.run_id, outbox)
       ), Map.merge(receipt, %{state: :submitted, target_agent_id: target})}
    end
  end

  def send(host, input), do: send_message(host, input)

  def send_input(host, input) when is_map(host) and is_map(input) do
    with :ok <- enabled(host, :send_input), do: deliver_message(host, input)
  end

  def send_message(host, input) when is_map(host) and is_map(input) do
    with :ok <- enabled(host, :send_message), do: deliver_message(host, input)
  end

  defp deliver_message(host, input) do
    with {:ok, sender} <- caller_run(host, input),
         {:ok, input} <- canonical_message(input, sender),
         {:ok, recipient} <- required(input, :recipient),
         :ok <- target_exists(host, recipient),
         {:ok, inbox} <- inbox_for(host, recipient),
         {:ok, inbox, receipt} <- Inbox.deliver(inbox, input) do
      {:ok, Map.update(host, :inboxes, %{recipient => inbox}, &Map.put(&1, recipient, inbox)),
       receipt}
    end
  end

  def followup_task(host, input) do
    with :ok <- enabled(host, :followup_task),
         do: deliver_message(host, Map.put(input, :kind, :task_request))
  end

  def resume_agent(host, input) do
    with :ok <- enabled(host, :resume_agent),
         do: deliver_message(host, Map.put(input, :kind, :task_result))
  end

  def status(host, run_id) when is_map(host) and is_binary(run_id) do
    case Map.get(host.runs, run_id) do
      nil -> {:error, Error.new(:not_found, "run not found", details: %{run_id: run_id})}
      run -> {:ok, run}
    end
  end

  def wait(host, run_id), do: wait_agent(host, %{run_id: run_id})

  def wait_agent(host, %{run_id: run_id} = request) when is_map(host) and is_binary(run_id) do
    with :ok <- enabled(host, :wait_agent),
         {:ok, run} <- status(host, run_id),
         :ok <- authorized_wait(request, run) do
      if run.status in [:completed, :failed, :cancelled, :timed_out, :unknown_outcome],
        do: {:ok, %{status: :completed, run: run}},
        else: {:ok, %{status: :waiting, run_id: run_id, continuation: "wait:#{run_id}"}}
    end
  end

  def cancel(host, run_id), do: interrupt_agent(host, %{run_id: run_id})

  def interrupt_agent(host, request) when is_map(host) and is_map(request) do
    with :ok <- enabled(host, :interrupt_agent),
         {:ok, run} <- status(host, Map.get(request, :run_id)),
         :ok <- authorized_wait(request, run),
         {:ok, tree} <- tree_for(host, run.run_id),
         {:ok, tree, _} <- RunTree.cancel(tree, run.run_id) do
      host =
        host
        |> put_in([:run_tree, run.run_id], tree)
        |> put_in([:runs, run.run_id, :status], :cancelled)

      {:ok, host, %{run_id: run.run_id, status: :cancelled}}
    end
  end

  def close_agent(host, request) when is_map(host) and is_map(request) do
    with :ok <- enabled(host, :close_agent),
         {:ok, run} <- status(host, Map.get(request, :run_id)),
         :ok <- authorized_wait(request, run),
         {:ok, tree} <- tree_for(host, run.parent_run_id || run.run_id),
         {:ok, tree, %{cancelled: cancelled}} <- RunTree.cancel(tree, run.run_id),
         {:ok, host} <- AgentHost.stop(host, run.agent_id) do
      root = run.parent_run_id || run.run_id
      host = Map.update(host, :run_tree, %{root => tree}, &Map.put(&1, root, tree))

      host =
        Enum.reduce(cancelled, host, fn cancelled_run, acc ->
          put_in(acc, [:runs, cancelled_run, :status], :cancelled)
        end)

      {:ok, host,
       %{agent_id: run.agent_id, run_id: run.run_id, status: :closed, cancelled: cancelled}}
    end
  end

  def list_agents(host, request \\ %{}) when is_map(host) do
    with :ok <- enabled(host, :list_agents),
         {:ok, caller} <- caller_run(host, request),
         do:
           {:ok,
            host.agents
            |> Enum.filter(fn {_id, a} -> a.owner == caller.run_id or a.lifecycle == :hosted end)
            |> Enum.map(&elem(&1, 1))}
  end

  def ask_user(_input, _resolver), do: unavailable(:ask_user)

  defp enabled(host, tool),
    do:
      if(tool in profile_tools(Map.get(host, :collaboration_profile)),
        do: :ok,
        else: unavailable(tool)
      )

  defp unavailable(operation),
    do:
      {:error,
       Error.new(:unsupported_capability, "collaboration operation is not available",
         details: %{operation: operation}
       )}

  defp required(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} is required")}
    end
  end

  defp optional_id(map, key, fallback) do
    case Map.get(map, key) do
      nil -> {:ok, fallback}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} must be a non-empty string")}
    end
  end

  defp caller_run(host, request) do
    with {:ok, run_id} <- required(request, :parent_run_id), {:ok, run} <- status(host, run_id) do
      if Map.get(request, :caller_run_id, run_id) == run_id,
        do: {:ok, run},
        else: {:error, Error.new(:forbidden, "caller is not the parent run")}
    end
  end

  defp canonical_message(input, sender_run) do
    canonical = sender_run.agent_id

    case Map.get(input, :sender) do
      nil -> {:ok, Map.put(input, :sender, canonical)}
      ^canonical -> {:ok, Map.put(input, :sender, canonical)}
      _ -> {:error, Error.new(:forbidden, "message sender does not match authenticated run")}
    end
  end

  defp authorized_wait(request, run),
    do:
      if(
        Map.get(request, :parent_run_id, run.run_id) in [run.run_id, Map.get(run, :parent_run_id)],
        do: :ok,
        else: {:error, Error.new(:forbidden, "run is outside caller scope")}
      )

  defp target_exists(host, target),
    do:
      if(Map.has_key?(host.agents, target),
        do: :ok,
        else: {:error, Error.new(:not_found, "target agent not found")}
      )

  defp tree_for(host, root),
    do:
      {:ok,
       Map.get(host, :run_tree, %{}) |> Map.get(root, elem(RunTree.new(root, %{max_depth: 8}), 1))}

  defp inbox_for(host, recipient),
    do: {:ok, Map.get(host, :inboxes, %{}) |> Map.get(recipient, elem(Inbox.new(100), 1))}

  defp outbox_for(host, owner),
    do: {:ok, Map.get(host, :outboxes, %{}) |> Map.get(owner, elem(Outbox.new(100), 1))}

  defp viewer_namespace(viewer) do
    case String.split(viewer, ":", parts: 2) do
      [namespace, _] when namespace != "" -> namespace <> ":"
      _ -> nil
    end
  end
end
