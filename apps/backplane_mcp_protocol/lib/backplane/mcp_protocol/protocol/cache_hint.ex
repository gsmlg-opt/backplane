defmodule Backplane.McpProtocol.Protocol.CacheHint do
  @moduledoc """
  Cache metadata carried by cacheable MCP `2026-07-28` results.

  Cache hints stay in their wire spelling when added to protocol result maps.
  """

  @cacheable_methods ~w(
                       server/discover
                       tools/list
                       prompts/list
                       resources/list
                       resources/templates/list
                       resources/read
                     )

  @enforce_keys []
  defstruct ttl_ms: 0, scope: :private

  @type scope :: :public | :private
  @type t :: %__MODULE__{ttl_ms: non_neg_integer(), scope: scope()}

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_ttl_ms | :invalid_cache_scope, term()}}
  def new(attrs) when is_map(attrs) do
    ttl_ms = Map.get(attrs, "ttlMs", Map.get(attrs, :ttl_ms, 0))
    scope = Map.get(attrs, "cacheScope", Map.get(attrs, :scope, :private))

    with :ok <- validate_ttl_ms(ttl_ms),
         {:ok, scope} <- normalize_scope(scope) do
      {:ok, %__MODULE__{ttl_ms: ttl_ms, scope: scope}}
    end
  end

  @spec put(map(), t()) :: map()
  def put(result, %__MODULE__{ttl_ms: ttl_ms, scope: scope})
      when is_map(result) and is_integer(ttl_ms) and ttl_ms >= 0 and scope in [:public, :private] do
    result
    |> Map.put("ttlMs", ttl_ms)
    |> Map.put("cacheScope", Atom.to_string(scope))
  end

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_ttl_ms | :invalid_cache_scope, term()}}
  def parse(result) when is_map(result), do: new(result)

  @spec cacheable_method?(term()) :: boolean()
  def cacheable_method?(method) when is_binary(method), do: method in @cacheable_methods
  def cacheable_method?(_method), do: false

  defp validate_ttl_ms(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_ttl_ms(value), do: {:error, {:invalid_ttl_ms, value}}

  defp normalize_scope(scope) when scope in [:public, :private], do: {:ok, scope}
  defp normalize_scope("public"), do: {:ok, :public}
  defp normalize_scope("private"), do: {:ok, :private}
  defp normalize_scope(scope), do: {:error, {:invalid_cache_scope, scope}}
end
