defmodule Backplane.McpProtocol.Server.Modern.Subscriptions do
  @moduledoc """
  Monitored, in-process subscription hub for modern MCP notification streams.

  The hub serializes subscription establishment and publication so its ACK is
  always queued before any event published after subscribe returns.
  """

  use GenServer

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Modern.Subscription

  defmodule State do
    @moduledoc false
    defstruct subscriptions: %{}, subscribers: %{}, monitor_refs: %{}
  end

  @type option :: {:name, GenServer.name()} | GenServer.option()

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @spec subscribe(GenServer.server(), pid(), map()) :: {:ok, reference()} | {:error, Error.t()}
  def subscribe(hub, subscriber, request_context) do
    GenServer.call(hub, {:subscribe, subscriber, request_context})
  end

  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(hub, subscription_ref) do
    GenServer.call(hub, {:unsubscribe, subscription_ref})
  end

  @spec publish(GenServer.server(), map()) :: :ok
  def publish(hub, notification) do
    GenServer.call(hub, {:publish, notification})
  end

  @doc "Gracefully completes every current subscription without stopping the hub."
  @spec close(GenServer.server()) :: :ok
  def close(hub) do
    GenServer.call(hub, :close)
  end

  @impl GenServer
  def init(:ok), do: {:ok, %State{}}

  @impl GenServer
  def handle_call({:subscribe, subscriber, request_context}, _from, state) do
    case Subscription.new(subscriber, request_context) do
      {:ok, %Subscription{} = subscription} ->
        state = add_subscription(state, subscription)
        send(subscriber, {:mcp_subscription, subscription.ref, Subscription.acknowledged(subscription)})
        {:reply, {:ok, subscription.ref}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_ref}, _from, state) do
    {:reply, :ok, remove_subscription(state, subscription_ref)}
  end

  def handle_call({:publish, notification}, _from, state) do
    Enum.each(state.subscriptions, fn {ref, subscription} ->
      case Subscription.deliver(subscription, notification) do
        {:ok, stamped} -> send(subscription.subscriber, {:mcp_subscription, ref, stamped})
        :ignore -> :ok
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    Enum.each(state.subscriptions, fn {ref, subscription} ->
      send(subscription.subscriber, {:mcp_subscription, ref, Subscription.complete(subscription)})
    end)

    {:reply, :ok, clear_subscriptions(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, subscriber, _reason}, state) do
    case Map.pop(state.monitor_refs, monitor_ref) do
      {^subscriber, monitor_refs} ->
        %{refs: refs} = Map.fetch!(state.subscribers, subscriber)
        subscriptions = Map.drop(state.subscriptions, MapSet.to_list(refs))

        {:noreply,
         %{
           state
           | subscriptions: subscriptions,
             subscribers: Map.delete(state.subscribers, subscriber),
             monitor_refs: monitor_refs
         }}

      {_unknown, _monitor_refs} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp add_subscription(state, subscription) do
    {subscriber_entry, state} = ensure_subscriber(state, subscription.subscriber)
    subscriber_entry = %{subscriber_entry | refs: MapSet.put(subscriber_entry.refs, subscription.ref)}

    %{
      state
      | subscriptions: Map.put(state.subscriptions, subscription.ref, subscription),
        subscribers: Map.put(state.subscribers, subscription.subscriber, subscriber_entry)
    }
  end

  defp ensure_subscriber(state, subscriber) do
    case Map.fetch(state.subscribers, subscriber) do
      {:ok, entry} ->
        {entry, state}

      :error ->
        monitor_ref = Process.monitor(subscriber)
        entry = %{monitor_ref: monitor_ref, refs: MapSet.new()}
        state = %{state | monitor_refs: Map.put(state.monitor_refs, monitor_ref, subscriber)}
        {entry, state}
    end
  end

  defp remove_subscription(state, subscription_ref) do
    case Map.pop(state.subscriptions, subscription_ref) do
      {nil, _subscriptions} ->
        state

      {%Subscription{subscriber: subscriber}, subscriptions} ->
        entry = Map.fetch!(state.subscribers, subscriber)
        refs = MapSet.delete(entry.refs, subscription_ref)

        if MapSet.size(refs) == 0 do
          Process.demonitor(entry.monitor_ref, [:flush])

          %{
            state
            | subscriptions: subscriptions,
              subscribers: Map.delete(state.subscribers, subscriber),
              monitor_refs: Map.delete(state.monitor_refs, entry.monitor_ref)
          }
        else
          %{
            state
            | subscriptions: subscriptions,
              subscribers: Map.put(state.subscribers, subscriber, %{entry | refs: refs})
          }
        end
    end
  end

  defp clear_subscriptions(state) do
    Enum.each(state.subscribers, fn {_subscriber, entry} ->
      Process.demonitor(entry.monitor_ref, [:flush])
    end)

    %State{}
  end
end
