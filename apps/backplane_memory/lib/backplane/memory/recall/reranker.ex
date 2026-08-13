defmodule Backplane.Memory.Recall.Reranker do
  @moduledoc "Optional bounded, failure-isolated recall reranking with exact fallback."

  alias Backplane.Memory.Config
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Recall.Candidate

  @default_timeout 1_000
  @options [:enabled, :top_k, :timeout_ms, :provider, :model, :task_supervisor]
  @max_timeout 60_000
  @max_query_chars 2_000
  @max_content_chars 2_000
  @max_payload_chars 32_000
  @rejection_reasons ~w(diversity token_budget lifecycle duplicate below_threshold superseded disputed archived channel_error review)

  def apply(traces, query, opts \\ [])

  def apply(traces, query, opts)
      when is_list(traces) and is_binary(query) do
    with :ok <- validate_traces(traces),
         {:ok, config} <- options(opts) do
      run(traces, query, config)
    end
  end

  def apply(_traces, _query, _opts), do: {:error, :invalid_rerank_input}

  defp run(traces, _query, %{enabled: false}),
    do: {:ok, traces, %{status: :disabled, model: nil}}

  defp run(traces, _query, %{model: nil}),
    do: {:ok, traces, %{status: :unavailable, model: nil}}

  defp run(traces, query, config) do
    input = traces |> Enum.filter(& &1.selected) |> Enum.take(config.top_k)

    if input == [] do
      {:ok, traces, %{status: :empty, model: config.model}}
    else
      dispatch(traces, query, input, config)
    end
  end

  defp dispatch(traces, query, input, config) do
    with {:ok, payload} <- descriptors(query, input),
         {:ok, task} <-
           start_task(config.task_supervisor, fn ->
             safe_provider(config.provider, payload.query, payload.items)
           end) do
      await(task, traces, input, config)
    else
      :error -> fallback(traces, :unavailable, config.model)
    end
  end

  defp await(task, traces, input, config) do
    case Task.yield(task, config.timeout) do
      {:ok, {:provider_result, {:ok, rows}}} ->
        success(traces, input, rows, config.model)

      {:ok, {:provider_result, {:error, _private_reason}}} ->
        fallback(traces, :provider_error, config.model)

      {:ok, {:provider_failure, status}} ->
        fallback(traces, status, config.model)

      {:ok, _malformed} ->
        fallback(traces, :malformed, config.model)

      {:exit, _private_reason} ->
        fallback(traces, :exit, config.model)

      nil ->
        Task.shutdown(task, :brutal_kill)
        fallback(traces, :timeout, config.model)
    end
  end

  defp success(traces, input, rows, model) when is_list(rows) do
    expected_tokens =
      input |> Enum.with_index() |> Map.new(fn {_trace, index} -> {index, true} end)

    parsed =
      Enum.reduce_while(rows, {:ok, []}, fn
        %{token: token, score: score} = row, {:ok, acc}
        when map_size(row) == 2 and is_integer(token) and is_number(score) ->
          if Map.has_key?(expected_tokens, token) and unit_score?(score) do
            {:cont, {:ok, [{token, score / 1} | acc]}}
          else
            {:halt, :error}
          end

        _, _ ->
          {:halt, :error}
      end)

    case parsed do
      {:ok, reversed} ->
        ranked = reversed |> Enum.reverse()
        tokens = Enum.map(ranked, &elem(&1, 0))

        if length(tokens) == map_size(expected_tokens) and tokens == Enum.uniq(tokens) do
          by_token =
            input |> Enum.with_index() |> Map.new(fn {trace, index} -> {index, trace} end)

          ranked = Enum.sort_by(ranked, fn {token, score} -> {-score, token} end)
          final_slots = input |> Enum.map(& &1.scores.final) |> Enum.sort(:desc)

          reordered =
            ranked
            |> Enum.zip(final_slots)
            |> Enum.map(fn {{token, score}, final_score} ->
              trace = by_token[token]

              %{
                trace
                | scores:
                    trace.scores
                    |> Map.put(:reranker, score)
                    |> Map.put(:final, final_score)
              }
            end)

          input_keys = MapSet.new(input, &identity/1)
          tail = Enum.reject(traces, &MapSet.member?(input_keys, identity(&1)))
          {:ok, reordered ++ tail, %{status: :ok, model: model}}
        else
          fallback(traces, :malformed, model)
        end

      :error ->
        fallback(traces, :malformed, model)
    end
  end

  defp success(traces, _input, _rows, model), do: fallback(traces, :malformed, model)

  defp descriptors(query, traces) do
    {:ok, safe_query} = Filter.apply_bounded(query, @max_query_chars)

    items =
      traces
      |> Enum.with_index()
      |> Enum.map(fn {trace, token} ->
        {:ok, content} = Filter.apply_bounded(trace.candidate.content, @max_content_chars)

        %{
          token: token,
          kind: Atom.to_string(trace.candidate.kind),
          memory_type: Atom.to_string(trace.candidate.memory_type),
          content: content
        }
      end)

    payload = fit_payload(%{query: safe_query, items: items})
    if byte_size(Jason.encode!(payload)) <= @max_payload_chars, do: {:ok, payload}, else: :error
  end

  defp options(opts) do
    with :ok <- validate_option_keys(opts) do
      config = %{
        enabled: Keyword.get(opts, :enabled, Config.recall_reranker_enabled?()),
        top_k: Keyword.get(opts, :top_k, Config.recall_reranker_top_k()),
        timeout: Keyword.get(opts, :timeout_ms, @default_timeout),
        provider: Keyword.get(opts, :provider, &llm_provider/2),
        model: Keyword.get(opts, :model, configured_model()),
        task_supervisor: Keyword.get(opts, :task_supervisor, configured_task_supervisor())
      }

      basic_valid =
        is_boolean(config.enabled) and is_integer(config.top_k) and config.top_k in 1..500 and
          is_integer(config.timeout) and config.timeout in 1..@max_timeout and
          valid_model?(config.model)

      execution_valid =
        not config.enabled or is_nil(config.model) or
          is_function(config.provider, 2)

      if basic_valid and execution_valid do
        {:ok, config}
      else
        {:error, :invalid_options}
      end
    end
  end

  def validate_options(opts) do
    case options(opts) do
      {:ok, _config} -> :ok
      {:error, :invalid_options} = error -> error
    end
  end

  defp validate_option_keys(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys == Enum.uniq(keys) and keys -- @options == [],
        do: :ok,
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp validate_traces(traces) do
    valid = Enum.all?(traces, &valid_trace?/1)
    identities = Enum.map(traces, &identity/1)
    if valid and identities == Enum.uniq(identities), do: :ok, else: {:error, :invalid_traces}
  end

  defp valid_trace?(%{
         candidate: %Candidate{} = candidate,
         selected: selected,
         rejection_reason: reason,
         scores: %{final: score},
         token_estimate: tokens
       }) do
    valid_selection?(selected, reason) and nonnegative_finite?(score) and
      is_integer(tokens) and tokens >= 0 and tokens == candidate.token_estimate
  end

  defp valid_trace?(_trace), do: false
  defp identity(%{candidate: candidate}), do: {candidate.kind, candidate.id}

  defp valid_selection?(true, nil), do: true
  defp valid_selection?(false, reason), do: reason in @rejection_reasons
  defp valid_selection?(_selected, _reason), do: false

  defp start_task(supervisor, fun) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fun)}
  catch
    :exit, _reason -> :error
  end

  defp safe_provider(provider, query, items) do
    {:provider_result, provider.(query, items)}
  rescue
    _private_error -> {:provider_failure, :exit}
  catch
    :exit, _private_reason -> {:provider_failure, :exit}
    :throw, _private_reason -> {:provider_failure, :exit}
  end

  defp valid_model?(nil), do: true
  defp valid_model?(model), do: is_binary(model) and byte_size(model) in 1..512

  defp configured_model do
    case Backplane.Settings.get("memory.llm_model") do
      model when is_binary(model) -> if(String.trim(model) == "", do: nil, else: model)
      _other -> nil
    end
  end

  defp configured_task_supervisor do
    Application.get_env(
      :backplane_memory,
      :recall_task_supervisor,
      Backplane.Memory.Recall.TaskSupervisor
    )
  end

  defp llm_provider(query, items) do
    case Backplane.Memory.LLM.rerank(query, items) do
      {:ok, reranked} when is_list(reranked) ->
        {:ok, reranked}

      {:skip, reason} ->
        {:error, reason}

      other ->
        other
    end
  end

  defp fit_payload(payload) do
    if byte_size(Jason.encode!(payload)) <= @max_payload_chars do
      payload
    else
      update_in(payload.items, fn items ->
        Enum.map(items, fn item -> %{item | content: trim_half(item.content)} end)
      end)
      |> fit_payload_or_stop(payload)
    end
  end

  defp fit_payload_or_stop(smaller, previous) do
    cond do
      byte_size(Jason.encode!(smaller)) <= @max_payload_chars -> smaller
      smaller == previous -> smaller
      true -> fit_payload(smaller)
    end
  end

  defp trim_half(""), do: ""
  defp trim_half(content), do: String.slice(content, 0, div(String.length(content), 2))

  defp unit_score?(score), do: score >= 0 and score <= 1 and finite?(score)
  defp nonnegative_finite?(score), do: is_number(score) and score >= 0 and finite?(score)
  defp finite?(score) when is_integer(score), do: true
  defp finite?(score) when is_float(score), do: score == score and score <= 1.0e308

  defp fallback(traces, status, model), do: {:ok, traces, %{status: status, model: model}}
end
