defmodule Backplane.LLM.StreamMapperChain do
  @moduledoc """
  Composes multiple Relayixir `:response_stream_mapper` modules in sequence.

  Chunks flow through each stage in order; `finish/2` flushes each stage and
  feeds its emitted tail into all downstream stages before finishing them.
  """

  @spec init(integer(), [{String.t(), String.t()}], [{module(), term()}]) ::
          {:ok, [map()]} | {:error, term()}
  def init(status, headers, specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, []}, fn {module, arg}, {:ok, acc} ->
      case module.init(status, headers, arg) do
        {:ok, state} -> {:cont, {:ok, [%{module: module, state: state} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, stages} -> {:ok, Enum.reverse(stages)}
      error -> error
    end
  end

  @spec feed([map()], binary()) ::
          {:ok, [map()], [binary()]} | {:error, term(), [map()], [binary()]}
  def feed(stages, chunk) when is_list(stages) and is_binary(chunk) do
    feed_stages(stages, [chunk], [])
  end

  @spec finish([map()], term()) ::
          {:ok, [map()], [binary()]} | {:error, term(), [map()], [binary()]}
  def finish(stages, reason) when is_list(stages) do
    finish_stages(stages, reason, [], [])
  end

  defp feed_stages([], chunks, done), do: {:ok, Enum.reverse(done), chunks}

  defp feed_stages([%{module: module, state: state} = stage | rest], chunks, done) do
    case run_stage_chunks(module, state, chunks, []) do
      {:ok, next_state, next_chunks} ->
        feed_stages(rest, next_chunks, [%{stage | state: next_state} | done])

      {:error, reason, next_state, next_chunks} ->
        case feed_stages(rest, next_chunks, [%{stage | state: next_state} | done]) do
          {:ok, final_stages, final_chunks} -> {:error, reason, final_stages, final_chunks}
          {:error, _later, final_stages, final_chunks} -> {:error, reason, final_stages, final_chunks}
        end
    end
  end

  defp run_stage_chunks(_module, state, [], acc), do: {:ok, state, Enum.reverse(acc)}

  defp run_stage_chunks(module, state, [chunk | rest], acc) do
    case module.feed(state, chunk) do
      {:ok, next_state, emitted} ->
        run_stage_chunks(module, next_state, rest, prepend_chunks(emitted, acc))

      {:error, reason, next_state, emitted} ->
        {:error, reason, next_state, Enum.reverse(prepend_chunks(emitted, acc))}
    end
  end

  defp finish_stages([], _reason, chunks, done), do: {:ok, Enum.reverse(done), chunks}

  defp finish_stages([%{module: module, state: state} = stage | rest], reason, incoming, done) do
    case run_stage_chunks(module, state, incoming, []) do
      {:ok, mid_state, mid_chunks} ->
        case module.finish(mid_state, reason) do
          {:ok, final_state, tail_chunks} ->
            all = mid_chunks ++ normalize_chunks(tail_chunks)
            finish_stages(rest, reason, all, [%{stage | state: final_state} | done])

          {:error, err, final_state, tail_chunks} ->
            all = mid_chunks ++ normalize_chunks(tail_chunks)
            finish_rest_with_error(rest, reason, all, [%{stage | state: final_state} | done], err)
        end

      {:error, err, mid_state, mid_chunks} ->
        finish_rest_with_error(rest, reason, mid_chunks, [%{stage | state: mid_state} | done], err)
    end
  end

  defp finish_rest_with_error(rest, reason, chunks, done, err) do
    case finish_stages(rest, reason, chunks, done) do
      {:ok, final_stages, final_chunks} -> {:error, err, final_stages, final_chunks}
      {:error, _later, final_stages, final_chunks} -> {:error, err, final_stages, final_chunks}
    end
  end

  defp prepend_chunks(chunks, acc) do
    chunks
    |> normalize_chunks()
    |> Enum.reduce(acc, fn chunk, list -> [chunk | list] end)
  end

  defp normalize_chunks(nil), do: []
  defp normalize_chunks(chunk) when is_binary(chunk), do: [chunk]
  defp normalize_chunks(chunks) when is_list(chunks), do: chunks
  defp normalize_chunks(_), do: []
end
