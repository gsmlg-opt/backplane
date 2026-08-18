defmodule Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeaders do
  @moduledoc false

  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers

  @type provider :: (-> {:ok, map()} | {:error, term()})

  @spec resolve(map(), provider() | nil) :: {:ok, map()} | {:error, term()}
  def resolve(static, nil) when is_map(static), do: Headers.configured(static)

  def resolve(static, provider) when is_map(static) and is_function(provider, 0) do
    with {:ok, static} <- Headers.configured(static) do
      case provider.() do
        {:ok, dynamic} when is_map(dynamic) ->
          with {:ok, dynamic} <- Headers.configured(dynamic) do
            {:ok, Map.merge(static, dynamic)}
          end

        {:ok, _invalid} ->
          {:error, :invalid_headers_provider_result}

        {:error, reason} ->
          {:error, reason}

        _invalid ->
          {:error, :invalid_headers_provider_result}
      end
    end
  rescue
    _exception -> {:error, :headers_provider_failed}
  catch
    _kind, _reason -> {:error, :headers_provider_failed}
  end

  def resolve(static, _provider) when is_map(static), do: {:error, :invalid_headers_provider_result}
end
