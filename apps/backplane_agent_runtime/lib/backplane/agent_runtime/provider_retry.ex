defmodule Backplane.AgentRuntime.ProviderRetry do
  @moduledoc false
  alias Backplane.AgentRuntime.Error

  def validate_options(opts) do
    case Keyword.get(opts, :provider_retry) do
      value when value in [nil, false] ->
        :ok

      value when is_map(value) ->
        if is_integer(Map.get(value, :stream_max_retries, 5)) and
             Map.get(value, :stream_max_retries, 5) >= 0 and
             is_boolean(Map.get(value, :unbounded_connection_retries, false)),
           do: :ok,
           else: invalid()

      _ ->
        invalid()
    end
  end

  def valid_failure?(event) do
    valid_retry?(event[:retry]) and valid_message?(event[:message]) and
      (is_nil(event[:response_id]) or is_binary(event[:response_id]))
  end

  def decision(opts, counts, %{class: class} = retry) do
    policy = Keyword.get(opts, :provider_retry)
    count = counts[class] + 1

    cond do
      not is_map(policy) ->
        :stop

      class == :connection and Map.get(policy, :unbounded_connection_retries, false) ->
        {:retry, count, delay(class, count, retry[:retry_after_ms])}

      bounded_count(policy, counts, class) < Map.get(policy, :stream_max_retries, 5) ->
        {:retry, count, delay(class, count, retry[:retry_after_ms])}

      true ->
        :stop
    end
  end

  def decision(_, _, _), do: :stop

  defp bounded_count(%{unbounded_connection_retries: true}, counts, :stream), do: counts.stream
  defp bounded_count(_, counts, _), do: counts.stream + counts.connection

  # Keep the original attempted message in the failure ledger. Only complete
  # textual blocks are eligible for a replacement request; failed tool calls
  # have no acknowledged results and must never enter a new tool batch.
  def input_message(%{role: :assistant, content: text} = message) when is_binary(text) do
    if text == "", do: nil, else: Map.take(message, [:id, :role, :content])
  end

  def input_message(%{role: :assistant, content: blocks} = message) when is_list(blocks) do
    blocks =
      Enum.filter(blocks, fn
        %{type: :text, text: text} when is_binary(text) -> String.valid?(text)
        %{type: :thinking, thinking: text} when is_binary(text) -> String.valid?(text)
        _ -> false
      end)

    if blocks == [],
      do: nil,
      else: message |> Map.take([:id, :role]) |> Map.put(:content, blocks)
  end

  def input_message(_), do: nil

  defp delay(class, count, advice) do
    base = if class == :connection, do: 5_000, else: 200
    delay = min(base * Integer.pow(2, min(count - 1, 9)), 60_000)
    if is_integer(advice), do: max(delay, advice), else: delay
  end

  defp valid_retry?(nil), do: true

  defp valid_retry?(%{class: class} = retry) when class in [:stream, :connection],
    do:
      is_nil(retry[:retry_after_ms]) or
        (is_integer(retry[:retry_after_ms]) and retry[:retry_after_ms] >= 0 and
           retry[:retry_after_ms] <= 86_400_000)

  defp valid_retry?(_), do: false

  defp valid_message?(nil), do: true

  defp valid_message?(%{role: :assistant, content: text}) when is_binary(text),
    do: String.valid?(text)

  defp valid_message?(%{role: :assistant, content: blocks}) when is_list(blocks), do: true
  defp valid_message?(_), do: false

  defp invalid,
    do:
      {:error,
       Error.new(:validation, "provider_retry requires a retry count and connection policy")}
end
