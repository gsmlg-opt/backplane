defmodule Backplane.LLM.HealthChecker do
  @moduledoc """
  GenServer that periodically probes enabled LLM provider API surfaces.

  Health state is stored in ETS as `{provider_api_id, boolean}`.
  """

  use GenServer

  require Logger

  alias Backplane.LLM.{CredentialPlug, ProviderApi}

  @table :llm_health_state

  @doc "Returns true if the provider API is known healthy, false otherwise."
  @spec healthy?(binary()) :: boolean()
  def healthy?(provider_api_id) do
    case :ets.lookup(@table, provider_api_id) do
      [{^provider_api_id, status}] -> status
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Mark a provider API as healthy."
  @spec mark_healthy(binary()) :: :ok
  def mark_healthy(provider_api_id) do
    :ets.insert(@table, {provider_api_id, true})
    :ok
  end

  @doc "Mark a provider API as unhealthy."
  @spec mark_unhealthy(binary()) :: :ok
  def mark_unhealthy(provider_api_id) do
    :ets.insert(@table, {provider_api_id, false})
    :ok
  end

  @doc "Start the HealthChecker GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @impl GenServer
  def init(opts) do
    ensure_table()

    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:backplane, :llm_health_check_interval, 60) * 1_000
      end)

    Process.send_after(self(), :probe, interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:probe, state) do
    probe_all_provider_apis()
    Process.send_after(self(), :probe, state.interval)
    {:noreply, state}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  rescue
    ArgumentError -> :ok
  end

  defp probe_all_provider_apis do
    for provider_api <- ProviderApi.list_enabled() do
      Task.start(fn -> probe_provider_api(provider_api) end)
    end
  end

  defp probe_provider_api(%ProviderApi{} = provider_api) do
    {url, headers} = probe_params(provider_api)

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200}} ->
        mark_healthy(provider_api.id)

      {:ok, %{status: status}} ->
        Logger.debug(
          "LLM health check failed for #{provider_label(provider_api)}: HTTP #{status}"
        )

        mark_unhealthy(provider_api.id)

      {:error, reason} ->
        Logger.debug(
          "LLM health check error for #{provider_label(provider_api)}: #{inspect(reason)}"
        )

        mark_unhealthy(provider_api.id)
    end
  end

  defp probe_params(%ProviderApi{} = provider_api) do
    path = provider_api.model_discovery_path || default_discovery_path(provider_api.api_surface)
    url = provider_api.base_url <> path

    headers =
      case CredentialPlug.build_auth_headers(provider_api.provider, provider_api.api_surface) do
        {:ok, hdrs} -> hdrs
        {:error, _} -> []
      end

    {url, headers}
  end

  defp default_discovery_path(:openai), do: "/models"
  defp default_discovery_path(:anthropic), do: "/v1/models"

  defp provider_label(%ProviderApi{provider: %{name: name}, api_surface: surface}) do
    "#{name}/#{surface}"
  end
end
