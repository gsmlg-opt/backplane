defmodule Backplane.AgentRuntime.Codex.Web.ReadableFetch do
  @moduledoc """
  Explicit revision-2 native readable-fetch adapter boundary.

  Hosts implement `fetch/2`, owning acquisition, per-hop redirect authorization,
  transfer decoding, extraction and caching. Options include `:allowed_hosts`,
  `:timeout`, `:result_limit` and, for native calls, reserved `:runtime_context`
  containing exact invocation identity and the live `:effect_deadline` accessor.
  Hosts must retain the deadline across their work and clean up owned resources.

  Results are unchanged plain JSON maps with UTF-8 string keys. Required fields
  are `url` (exact input), `final_url`, `text` and `content_type`. Additional
  portable metadata is retained. Both URLs must be authorized absolute HTTP(S)
  URLs; hosts also authorize every intermediate redirect. Complete result size is
  bounded by `:erlang.external_size/1`. Standalone calls invent no runtime identity.
  """

  alias Backplane.AgentRuntime.{Error, InputSchema}

  @callback fetch(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["url"],
      "properties" => %{
        "url" => %{"type" => "string", "format" => "uri"},
        "instructions" => %{"type" => "string"},
        "extract_mode" => %{"type" => "string", "enum" => ["markdown", "text"]},
        "max_chars" => %{"type" => "integer", "minimum" => 1}
      }
    }
  end

  @spec fetch(module(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(adapter, arguments, opts)
      when is_atom(adapter) and is_map(arguments) and is_list(opts) do
    with {:ok, ^arguments} <- InputSchema.validate(schema(), arguments),
         :ok <- authorize_url(arguments["url"], opts),
         {:ok, configured} <- positive_option(opts, :timeout, 5_000),
         {:ok, limit} <- positive_option(opts, :result_limit, 1_048_576),
         true <-
           (Code.ensure_loaded?(adapter) and function_exported?(adapter, :fetch, 2)) or
             {:error, Error.new(:unsupported_capability, "readable fetch adapter is unavailable")},
         {:ok, timeout} <- runtime_timeout(opts, configured),
         result <- run(adapter, arguments, Keyword.put(opts, :timeout, timeout), timeout) do
      validate_result(result, arguments["url"], opts, limit)
    end
  end

  def fetch(_, _, _),
    do:
      {:error,
       Error.new(:validation, "readable fetch adapter, arguments and options are required")}

  defp authorize_url(url, opts) when is_binary(url) do
    uri = URI.parse(url)
    hosts = Keyword.get(opts, :allowed_hosts, [])

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and
         (hosts == :all or (is_list(hosts) and uri.host in hosts)) do
      :ok
    else
      {:error, Error.new(:forbidden, "readable fetch URL is not authorized")}
    end
  end

  defp authorize_url(_, _),
    do: {:error, Error.new(:validation, "readable fetch URL is required")}

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} must be positive")}
    end
  end

  defp runtime_timeout(opts, configured) do
    case Keyword.get(opts, :runtime_context) do
      %{effect_deadline: accessor} when is_function(accessor, 0) ->
        case accessor.() do
          {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining > 0 ->
            {:ok, min(configured, remaining)}

          {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining <= 0 ->
            {:error, Error.new(:timeout, "readable fetch runtime deadline is exhausted")}

          {:error, %Error{} = error} ->
            {:error, error}

          _ ->
            {:error, Error.new(:malformed_result, "readable fetch runtime deadline is invalid")}
        end

      _ ->
        {:ok, configured}
    end
  end

  defp run(adapter, arguments, opts, timeout) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    task = Task.Supervisor.async_nolink(supervisor, fn -> adapter.fetch(arguments, opts) end)

    result =
      case Task.yield(task, timeout) do
        {:ok, value} ->
          value

        {:exit, reason} ->
          {:error, Error.new(:execution_failure, "readable fetch adapter crashed", cause: reason)}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, Error.new(:timeout, "readable fetch timed out")}
      end

    Process.unlink(supervisor)
    Supervisor.stop(supervisor, :shutdown)
    result
  end

  defp validate_result({:ok, result}, url, opts, limit)
       when is_map(result) and not is_struct(result) do
    cond do
      :erlang.external_size(result) > limit ->
        {:error,
         Error.new(:budget_exceeded, "readable fetch result exceeds the configured bound")}

      not portable?(result, 0) or result["url"] != url or not text?(result["text"]) or
        not text?(result["content_type"]) or result["content_type"] == "" ->
        {:error, Error.new(:malformed_result, "readable fetch returned an invalid document")}

      true ->
        with :ok <- authorize_url(result["final_url"], opts), do: {:ok, result}
    end
  end

  defp validate_result({:error, %Error{} = error}, _, _, _), do: {:error, error}

  defp validate_result(_, _, _, _),
    do:
      {:error, Error.new(:malformed_result, "readable fetch adapter returned an invalid result")}

  defp portable?(_, depth) when depth > 128, do: false
  defp portable?(value, _) when is_binary(value), do: String.valid?(value)
  defp portable?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp portable?(value, depth) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, child} -> text?(key) and portable?(child, depth + 1) end)

  defp portable?(value, depth) when is_list(value), do: portable_list?(value, depth)
  defp portable?(_, _), do: false
  defp portable_list?([], _), do: true

  defp portable_list?([head | tail], depth),
    do: portable?(head, depth + 1) and portable_list?(tail, depth)

  defp portable_list?(_, _), do: false
  defp text?(value), do: is_binary(value) and String.valid?(value)
end
