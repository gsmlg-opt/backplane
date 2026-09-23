defmodule Backplane.LLM.Antigravity.RequestTarget do
  @moduledoc false

  alias Backplane.AiProtocol.Antigravity

  defstruct [:provider_name, :operation]

  def parse("POST", "/antigravity/providers/" <> rest, query) do
    case String.split(rest, "/", parts: 2) do
      [provider_name, "v1internal:" <> rpc] ->
        with :ok <- validate_provider_name(provider_name),
             {:ok, operation} <- Antigravity.operation(rpc),
             :ok <- validate_query(operation, query) do
          {:ok, %__MODULE__{provider_name: provider_name, operation: operation}}
        end

      _ ->
        {:error, :unsupported_route}
    end
  end

  def parse(_method, _path, _query), do: {:error, :unsupported_route}

  defp validate_provider_name(provider_name) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, provider_name),
      do: :ok,
      else: {:error, :invalid_provider}
  end

  defp validate_query(_operation, ""), do: :ok

  defp validate_query(:stream_generate_content, query) do
    if Enum.to_list(URI.query_decoder(query)) == [{"alt", "sse"}],
      do: :ok,
      else: {:error, :query_not_allowed}
  rescue
    ArgumentError -> {:error, :query_not_allowed}
  end

  defp validate_query(_operation, _query), do: {:error, :query_not_allowed}
end
