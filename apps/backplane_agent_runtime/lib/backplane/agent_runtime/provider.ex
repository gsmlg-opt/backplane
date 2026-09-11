defmodule Backplane.AgentRuntime.Provider do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  ProviderPort boundary for Backplane agent runtime.
  """

  @type adapter :: module()

  @callback start(map()) :: {:ok, map()} | {:error, Error.t()}

  @callback chunks([map()]) :: {:ok, map()} | {:error, Error.t()}

  @spec start(adapter(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def start(adapter, request, context)
      when is_atom(adapter) and is_map(request) and is_map(context) do
    with {:ok, _} <- validate_request(request),
         {:ok, response} <- adapter.start(request) do
      {:ok, Map.put(request, :response, response)}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_request(request) do
    if Map.has_key?(request, :step_id) and Map.has_key?(request, :attempt_id) do
      {:ok, request}
    else
      {:error, Error.new(:validation, "provider request requires step_id and attempt_id")}
    end
  end

  @spec complete_stream(adapter(), [map()]) :: {:ok, map()} | {:error, Error.t()}
  def complete_stream(adapter, chunks) when is_atom(adapter) and is_list(chunks) do
    case adapter.chunks(chunks) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(:malformed_result, "provider stream returned an invalid acknowledgement",
           details: %{received: other}
         )}
    end
  end
end
