defmodule Backplane.LLM.HealthChecker do
  @moduledoc """
  GenServer that periodically probes all enabled LLM providers for health.

  Stores health state in ETS table `:llm_health_state` as `{provider_id, boolean}`.

  ## API

  - `healthy?(provider_id)` — returns true/false (false for unknown providers)
  - `mark_healthy(provider_id)` — records provider as healthy
  - `mark_unhealthy(provider_id)` — records provider as unhealthy

  ## Health probe

  For each enabled, non-deleted provider:
  - `:anthropic` → GET `{api_url}/v1/models` with `x-api-key` header
  - `:openai` → GET `{api_url}/v1/models` with `Authorization: Bearer` header

  A 200 response means healthy; anything else means unhealthy.

  ## Options

  - `interval:` — probe interval in milliseconds. Defaults to
    `Application.get_env(:backplane, :llm_health_check_interval, 60) * 1000`.
  """

  use GenServer

  require Logger

  alias Backplane.LLM.Provider

  @table :llm_health_state

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Returns true if the provider is known-healthy, false otherwise."
  @spec healthy?(binary()) :: boolean()
  def healthy?(provider_id) do
    case :ets.lookup(@table, provider_id) do
      [{^provider_id, status}] -> status
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Mark a provider as healthy."
  @spec mark_healthy(binary()) :: :ok
  def mark_healthy(provider_id) do
    :ets.insert(@table, {provider_id, true})
    :ok
  end

  @doc "Mark a provider as unhealthy."
  @spec mark_unhealthy(provider_id :: binary()) :: :ok
  def mark_unhealthy(provider_id) do
    :ets.insert(@table, {provider_id, false})
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

  # ── GenServer callbacks ───────────────────────────────────────────────────────

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
    probe_all_providers()
    Process.send_after(self(), :probe, state.interval)
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

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

  defp probe_all_providers do
    providers =
      Provider.list()
      |> Enum.filter(& &1.enabled)

    for provider <- providers do
      Task.start(fn -> probe_provider(provider) end)
    end
  end

  defp probe_provider(provider) do
    {url, headers} = probe_params(provider)

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200}} ->
        mark_healthy(provider.id)

      {:ok, %{status: status}} ->
        Logger.debug("LLM health check failed for #{provider.name}: HTTP #{status}")
        mark_unhealthy(provider.id)

      {:error, reason} ->
        Logger.debug("LLM health check error for #{provider.name}: #{inspect(reason)}")
        mark_unhealthy(provider.id)
    end
  end

  defp probe_params(%{api_url: api_url} = provider) do
    alias Backplane.LLM.CredentialPlug

    url = "#{api_url}/v1/models"

    headers =
      case CredentialPlug.build_auth_headers(provider) do
        {:ok, hdrs} -> hdrs
        {:error, _} -> []
      end

    {url, headers}
  end
end
