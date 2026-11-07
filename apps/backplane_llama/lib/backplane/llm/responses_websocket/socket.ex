defmodule Backplane.LLM.ResponsesWebSocket.Socket do
  @moduledoc """
  Native JSON text-message downstream for a caller-owned Responses session.

  Ping/pong are hop-local. No application interrupt or cancellation is inferred
  from a Close frame or downstream disconnect.
  """

  @behaviour WebSock
  alias Backplane.LLM.ResponsesWebSocket.Session

  @impl true
  def init(%{session: session} = state) do
    monitor = Process.monitor(session)

    case Session.attach(session, self()) do
      :ok -> {:ok, Map.put(state, :monitor, monitor)}
      _ -> {:stop, :normal, {1011, "Upstream unavailable"}, state}
    end
  end

  @impl true
  def handle_in({bytes, opcode: :text}, state) do
    case Session.send(state.session, bytes) do
      :ok ->
        {:ok, state}

      {:error, code}
      when code in [:submission_unknown, :session_unavailable, :policy_unavailable] ->
        {:stop, :normal, {1011, "Request outcome uncertain; do not replay"}, state}

      {:error, _} ->
        {:stop, :normal, {1008, "Responses request rejected"}, state}
    end
  end

  def handle_in(_message, state),
    do: {:stop, :normal, {1003, "JSON text messages required"}, state}

  @impl true
  def handle_info({:responses_event, session, bytes, ref}, %{session: session} = state) do
    # Gaoxy completes the synchronous push before dispatching this next message.
    # If its write fails, terminate closes the session without releasing credit.
    Kernel.send(self(), {:responses_ack, session, ref})
    {:push, {:text, bytes}, state}
  end

  def handle_info({:responses_ack, session, ref}, %{session: session} = state) do
    Session.ack(session, ref)
    {:ok, state}
  end

  def handle_info({:responses_closed, session, code}, %{session: session} = state),
    do: {:stop, :normal, {code, ""}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, {1011, "Upstream unavailable"}, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_control(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{session: session}) do
    Session.close(session)
    :ok
  end
end
