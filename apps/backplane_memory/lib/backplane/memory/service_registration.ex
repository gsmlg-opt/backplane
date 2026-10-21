defmodule Backplane.Memory.ServiceRegistration do
  @moduledoc false

  use GenServer

  alias Backplane.Memory.Service
  alias Backplane.Registry.{PromptRegistry, ToolRegistry}
  alias Backplane.Settings

  @settings ~w(services.memory.enabled memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    settings = Keyword.get(opts, :settings_module, Settings)
    :ok = settings.subscribe()
    deregister()
    send(self(), :reconcile)

    {:ok,
     %{
       settings: settings,
       retry_interval_ms: Keyword.get(opts, :retry_interval_ms, 1_000),
       retry: nil
     }}
  end

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, reconcile(cancel_retry(state))}

  def handle_info({:setting_changed, key, _value}, state) when key in @settings,
    do: {:noreply, reconcile(cancel_retry(state))}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_retry(state)
    deregister()
    :ok
  end

  defp reconcile(state) do
    result =
      safely(fn ->
        with {:ok, values} <- state.settings.fetch_many(@settings),
             :ok <- deregister() do
          if values["services.memory.enabled"] == true do
            with :ok <- ToolRegistry.register_managed(Service.prefix(), Service.tools()) do
              PromptRegistry.register_managed(Service.prefix(), Service.prompts(), Service)
            end
          else
            :ok
          end
        end
      end)

    if result == :ok do
      state
    else
      deregister()
      %{state | retry: Process.send_after(self(), :reconcile, state.retry_interval_ms)}
    end
  end

  defp deregister do
    tools = safely(fn -> ToolRegistry.deregister_managed(Service.prefix()) end)
    prompts = safely(fn -> PromptRegistry.deregister_managed(Service.prefix()) end)
    if tools == :ok and prompts == :ok, do: :ok, else: {:error, :registry_unavailable}
  end

  defp safely(function) do
    function.()
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp cancel_retry(%{retry: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry)
    %{state | retry: nil}
  end
end
