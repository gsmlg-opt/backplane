defmodule Backplane.AgentRuntime.Codex.Image do
  @moduledoc """
  Host-configured image-generation adapter; no local fake executor.
  """
  alias Backplane.AgentRuntime.Error

  @default_timeout 30_000
  @default_max_bytes 10 * 1024 * 1024

  @callback generate(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @spec generate(module() | nil, map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def generate(nil, _request, _opts),
    do: {:error, Error.new(:unsupported_capability, "image generation service is unavailable")}

  def generate(adapter, request, opts)
      when is_atom(adapter) and is_map(request) and is_list(opts) do
    with :ok <- validate_request(request),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes, @default_max_bytes),
         true <-
           function_exported?(adapter, :generate, 2) or
             {:error,
              Error.new(:unsupported_capability, "image generation adapter is unavailable")},
         result <- run(adapter, request, opts, timeout),
         {:ok, result} <- normalize_result(result, max_bytes) do
      {:ok, result}
    end
  end

  def generate(_, _, _),
    do: {:error, Error.new(:validation, "image request and adapter are invalid")}

  defp validate_request(request) do
    prompt = Map.get(request, :prompt, Map.get(request, "prompt"))

    if is_binary(prompt) and String.trim(prompt) != "",
      do: :ok,
      else: {:error, Error.new(:validation, "image prompt is required")}
  end

  defp positive_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, Error.new(:validation, "#{key} must be positive")}
  end

  defp run(adapter, request, opts, timeout) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    task = Task.Supervisor.async_nolink(supervisor, fn -> adapter.generate(request, opts) end)

    result =
      case Task.yield(task, timeout) do
        {:ok, value} ->
          value

        {:exit, reason} ->
          {:error, Error.new(:execution_failure, "image adapter crashed", cause: reason)}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, Error.new(:timeout, "image generation timed out")}
      end

    Process.unlink(supervisor)
    Supervisor.stop(supervisor, :shutdown)
    result
  end

  defp normalize_result({:ok, result}, max_bytes) when is_map(result) do
    data = Map.get(result, :data, Map.get(result, "data"))
    artifact = Map.get(result, :artifact, Map.get(result, "artifact"))

    cond do
      is_binary(data) and byte_size(data) > max_bytes ->
        {:error, Error.new(:budget_exceeded, "generated image exceeds the configured bound")}

      is_binary(data) or is_map(artifact) ->
        {:ok, result}

      true ->
        {:error,
         Error.new(:malformed_result, "image result requires data or an artifact reference")}
    end
  end

  defp normalize_result({:error, %Error{} = error}, _max_bytes), do: {:error, error}

  defp normalize_result(other, _max_bytes),
    do:
      {:error,
       Error.new(:malformed_result, "image adapter returned an invalid result",
         details: %{received: other}
       )}
end
