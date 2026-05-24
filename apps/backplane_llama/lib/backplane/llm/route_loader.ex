defmodule Backplane.LLM.RouteLoader do
  @moduledoc """
  GenServer that keeps Relayixir's UpstreamConfig in sync with active LLM providers.

  On init and on each `{:llm_providers_changed, _}` PubSub message, it reads all
  active providers, builds upstream config maps from their API URLs, and replaces
  the LLM-provider entries in UpstreamConfig while preserving any non-LLM upstreams.
  """

  use GenServer

  require Logger

  alias Backplane.LLM.ProviderApi
  alias Backplane.PubSubBroadcaster
  alias Relayixir.Config.UpstreamConfig

  @llm_prefix "llm_provider_"

  # ── Client API ───────────────────────────────────────────────────────────────

  @doc "Start the GenServer (registered under its module name)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the Relayixir upstream name for the given provider API id."
  @spec upstream_name(binary()) :: String.t()
  def upstream_name(provider_api_id) when is_binary(provider_api_id) do
    "#{@llm_prefix}#{provider_api_id}"
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    PubSubBroadcaster.subscribe(PubSubBroadcaster.llm_providers_topic())
    send(self(), :load_all_providers)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:load_all_providers, state) do
    load_all_providers()
    {:noreply, state}
  end

  def handle_info({:llm_providers_changed, _payload}, state) do
    load_all_providers()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal helpers ──────────────────────────────────────────────────────────

  defp load_all_providers do
    try do
      provider_apis = ProviderApi.list_enabled()

      new_llm_upstreams =
        Map.new(provider_apis, fn provider_api ->
          {upstream_name(provider_api.id), build_upstream_config(provider_api)}
        end)

      current = UpstreamConfig.list_upstreams()

      non_llm =
        current
        |> Enum.reject(fn {name, _} -> String.starts_with?(name, @llm_prefix) end)
        |> Map.new()

      merged = Map.merge(non_llm, new_llm_upstreams)

      UpstreamConfig.put_upstreams(merged)

      Logger.debug(
        "RouteLoader: loaded #{map_size(new_llm_upstreams)} LLM provider API upstream(s)"
      )
    rescue
      e ->
        Logger.warning("RouteLoader: failed to load providers: #{Exception.message(e)}")
        :ok
    catch
      :exit, reason ->
        Logger.warning("RouteLoader: upstream config not available: #{inspect(reason)}")
        :ok
    end
  end

  defp build_upstream_config(%ProviderApi{base_url: base_url}) do
    uri = URI.parse(base_url)

    %{
      scheme: String.to_atom(uri.scheme || "https"),
      host: uri.host,
      port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path_prefix_rewrite: uri.path || "",
      max_request_body_size: 50_000_000,
      max_response_body_size: 50_000_000,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      connect_timeout: 10_000
    }
  end
end
