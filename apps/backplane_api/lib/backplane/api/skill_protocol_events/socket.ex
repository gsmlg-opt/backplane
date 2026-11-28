defmodule Backplane.Api.SkillProtocolEvents.Socket do
  @moduledoc false
  @behaviour WebSock

  alias Backplane.Api.SkillProtocolEvents
  alias Backplane.Settings
  alias Backplane.Skills.{ProtocolChanges, Publication, SearchCategories}

  @heartbeat_ms 15_000
  @max_snapshot_bytes 4 * 1024 * 1024

  @impl true
  def init(state) do
    with true <- SkillProtocolEvents.authorized?(state.auth_conn),
         :ok <- Settings.subscribe(),
         :ok <- ProtocolChanges.subscribe(),
         listener when is_pid(listener) <- ProtocolChanges.listener() do
      state = Map.put(state, :listener_ref, Process.monitor(listener))
      Process.send_after(self(), :heartbeat, @heartbeat_ms)
      publish(state, 3, true)
    else
      false -> close(state, 1008, "skill read access denied")
      _ -> close(state, 1013, "skill notifications unavailable")
    end
  end

  @impl true
  def handle_in(_frame, state), do: close(state, 1008, "notification connection is read only")

  @impl true
  def handle_info(:skill_protocol_changed, state), do: publish(state, 3)

  def handle_info(:skill_protocol_unavailable, state),
    do: close(state, 1013, "skill notifications unavailable")

  def handle_info({:setting_changed, "skills.search_categories", _value}, state) do
    if SkillProtocolEvents.authorized?(state.auth_conn) do
      push(categories(state.generation), state)
    else
      close(state, 1008, "skill read access denied")
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{listener_ref: ref} = state),
    do: close(state, 1013, "skill notifications unavailable")

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    with true <- SkillProtocolEvents.authorized?(state.auth_conn),
         {:ok, generation} <- ProtocolChanges.current() do
      if generation == state.generation do
        push(%{type: "heartbeat", generation: generation}, state, [{:ping, "skills"}])
      else
        publish(state, 3)
      end
    else
      false -> close(state, 1008, "skill read access denied")
      _ -> close(state, 1013, "skill notifications unavailable")
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp publish(state, attempts, send_categories? \\ false)

  defp publish(state, 0, _send_categories?), do: close(state, 1013, "skill directory is changing")

  defp publish(state, attempts, send_categories?) do
    with true <- SkillProtocolEvents.authorized?(state.auth_conn),
         {:ok, %{generation: generation} = payload} <- payload(state.generation),
         {:ok, current} <- ProtocolChanges.current(),
         true <- SkillProtocolEvents.authorized?(state.auth_conn) do
      if generation == current do
        metadata =
          if send_categories? and payload.type == "changed",
            do: [{:text, JSON.encode!(categories(generation))}],
            else: []

        push(payload, %{state | generation: generation}, metadata)
      else
        publish(state, attempts - 1, send_categories?)
      end
    else
      false -> close(state, 1008, "skill read access denied")
      {:error, :limit_exceeded} -> close(state, 1009, "skill snapshot exceeds limit")
      _ -> close(state, 1013, "skill directory unavailable")
    end
  end

  defp payload(nil) do
    with {:ok, generation} <- ProtocolChanges.current(), do: snapshot(generation)
  end

  defp payload(previous) do
    case ProtocolChanges.since(previous) do
      {:ok, %{generation: ^previous, skill_ids: []}} ->
        {:ok,
         %{type: "unchanged", generation: previous, search_categories: SearchCategories.list()}}

      {:ok, %{generation: generation, skill_ids: ids}} ->
        {:ok,
         %{
           type: "changed",
           previous_generation: previous,
           generation: generation,
           skill_ids: ids
         }}

      {:reset, generation} ->
        snapshot(generation)

      {:error, _} = error ->
        error
    end
  end

  defp snapshot(generation) do
    with {:ok, catalog} <- Publication.always_snapshot(),
         do:
           {:ok,
            %{
              type: "snapshot",
              generation: generation,
              catalog: catalog,
              search_categories: SearchCategories.list()
            }}
  end

  defp categories(generation),
    do: %{
      type: "search_categories",
      generation: generation,
      search_categories: SearchCategories.list()
    }

  defp push(payload, state, control \\ []) do
    bytes = JSON.encode!(payload)

    if byte_size(bytes) <= @max_snapshot_bytes do
      {:push, [{:text, bytes} | control], state}
    else
      close(state, 1009, "skill snapshot exceeds limit")
    end
  end

  defp close(state, code, message), do: {:stop, :normal, {code, message}, state}
end
