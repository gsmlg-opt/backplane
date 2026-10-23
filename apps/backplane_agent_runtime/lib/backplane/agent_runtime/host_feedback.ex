defmodule Backplane.AgentRuntime.HostFeedback do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  @fields ~w(id text source stage)
  @identity ~w(
    run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id
    tool_name tool_revision catalog_revision enclosing_invocation_id
  )a

  def payload(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if key in @fields and not Map.has_key?(acc, key) and
           valid_text?(value, if(key == "text", do: 65_536, else: 256)) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:halt,
         invalid("feedback requires only nonempty UTF-8 id, text, source and stage strings")}
      end
    end)
    |> case do
      {:ok, normalized} when map_size(normalized) == 4 -> {:ok, normalized}
      _ -> invalid("feedback requires only nonempty UTF-8 id, text, source and stage strings")
    end
  end

  def payload(_), do: invalid("feedback must be a map")

  # Public interactions are transport values, not executable host terms. Bound
  # recursion and bytes before accepting them into canonical state or events.
  def public(value) do
    with {:ok, value} <- normalize(value, 0),
         {:ok, bytes} <- Jason.encode(value),
         true <- byte_size(bytes) <= 262_144 do
      {:ok, value}
    else
      _ -> invalid("interaction must be bounded JSON-safe data without ambiguous keys")
    end
  end

  defp normalize(_, depth) when depth > 32, do: :error

  defp normalize(value, _) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp normalize(value, _) when is_boolean(value) or is_nil(value) or is_number(value),
    do: {:ok, value}

  defp normalize(value, _) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize(value, depth) when is_list(value) do
    normalize_list(value, depth + 1, [])
  end

  defp normalize(value, depth) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      with true <- is_atom(key) or is_binary(key),
           key = if(is_atom(key), do: Atom.to_string(key), else: key),
           {:ok, key} <- normalize(key, depth + 1),
           true <- is_binary(key) and not Map.has_key?(acc, key),
           {:ok, item} <- normalize(item, depth + 1) do
        {:cont, {:ok, Map.put(acc, key, item)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize(_, _), do: :error

  defp normalize_list([], _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([item | rest], depth, acc) do
    case normalize(item, depth) do
      {:ok, item} -> normalize_list(rest, depth, [item | acc])
      _ -> :error
    end
  end

  defp normalize_list(_, _, _), do: :error

  def history(opts) do
    records = Keyword.get(opts, :host_feedback, [])
    messages = Keyword.get(opts, :messages, [])

    with true <- is_list(records) and is_list(messages),
         {:ok, records} <- validate_history(records),
         {:ok, records} <- history_messages(messages, records) do
      {:ok, records}
    else
      _ -> invalid("invalid host_feedback history seed")
    end
  end

  defp validate_history(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      with {:ok, record} <- history_record(record),
           false <- Enum.any?(acc, &(&1["id"] == record["id"])) do
        {:cont, {:ok, acc ++ [record]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp history_record(record) do
    with {:ok, record} <- normalize(record, 0),
         true <- is_map(record) and map_size(record) == 8,
         {:ok, _} <- payload(Map.take(record, @fields)),
         true <- is_map(record["correlation"]),
         true <-
           Enum.all?(
             @identity -- [:enclosing_invocation_id],
             &Map.has_key?(record["correlation"], Atom.to_string(&1))
           ),
         true <- is_integer(record["revision"]) and record["revision"] > 0,
         true <- record["store_mode"] in ["durable", "ephemeral"],
         true <- is_boolean(record["projected"]) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  defp history_messages(messages, records) do
    Enum.reduce_while(messages, {:ok, records}, fn message, {:ok, records} ->
      case message_record(message) do
        nil ->
          {:cont, {:ok, records}}

        {:ok, record} ->
          case Enum.find(records, &(&1["id"] == record["id"])) do
            nil ->
              {:cont, {:ok, records ++ [record]}}

            current ->
              if Map.drop(current, ["projected"]) == Map.drop(record, ["projected"]),
                do: {:cont, {:ok, merge(records, [record])}},
                else: {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp message_record(message) when is_map(message) do
    metadata = Map.get(message, :host_feedback, Map.get(message, "host_feedback"))

    if is_nil(metadata) do
      nil
    else
      with {:ok, metadata} <- normalize(metadata, 0),
           true <- is_map(metadata),
           content when is_binary(content) <-
             Map.get(message, :content, Map.get(message, "content")),
           role when role in [:user, "user"] <- Map.get(message, :role, Map.get(message, "role")),
           source when is_binary(source) <- metadata["source"],
           stage when is_binary(stage) <- metadata["stage"],
           prefix = "[Host feedback] #{source} / #{stage}\n",
           true <- String.starts_with?(content, prefix),
           text = binary_part(content, byte_size(prefix), byte_size(content) - byte_size(prefix)),
           true <- not Map.has_key?(metadata, "text") or metadata["text"] == text do
        metadata |> Map.put("text", text) |> Map.put("projected", true) |> history_record()
      else
        _ -> :error
      end
    end
  end

  defp message_record(_), do: nil

  def correlation(invocation, enclosing) do
    correlation = Map.take(invocation, @identity)

    if enclosing && enclosing.invocation_id != invocation.invocation_id,
      do: Map.put(correlation, :enclosing_invocation_id, enclosing.invocation_id),
      else: correlation
  end

  def record(payload, correlation, revision, mode) do
    Map.merge(payload, %{
      "correlation" => Map.new(correlation, fn {key, value} -> {Atom.to_string(key), value} end),
      "revision" => revision,
      "store_mode" => Atom.to_string(mode),
      "projected" => false
    })
  end

  def same?(record, payload, correlation) do
    Map.take(record, @fields) == payload and
      record["correlation"] ==
        Map.new(correlation, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  def receipt(record) do
    correlation =
      for key <- @identity,
          Map.has_key?(record["correlation"], Atom.to_string(key)),
          into: %{},
          do: {key, record["correlation"][Atom.to_string(key)]}

    %{
      id: record["id"],
      correlation: correlation,
      revision: record["revision"],
      store_mode: if(record["store_mode"] == "durable", do: :durable, else: :ephemeral)
    }
  end

  def merge(current, desired) do
    Enum.reduce(desired, current, fn record, acc ->
      case Enum.find_index(acc, &(&1["id"] == record["id"])) do
        nil ->
          acc ++ [record]

        index ->
          List.update_at(
            acc,
            index,
            &Map.put(&1, "projected", &1["projected"] or record["projected"])
          )
      end
    end)
  end

  def merge_messages(messages) do
    {messages, _seen} =
      Enum.reduce(messages, {[], MapSet.new()}, fn message, {acc, seen} ->
        metadata =
          if is_map(message),
            do: Map.get(message, :host_feedback, Map.get(message, "host_feedback"))

        id = if is_map(metadata), do: Map.get(metadata, "id", Map.get(metadata, :id))

        if is_binary(id) and MapSet.member?(seen, id) do
          {acc, seen}
        else
          {[message | acc], if(is_binary(id), do: MapSet.put(seen, id), else: seen)}
        end
      end)

    Enum.reverse(messages)
  end

  def project(conversation) do
    {records, messages} =
      Enum.map_reduce(Map.get(conversation, :host_feedback, []), [], fn record, messages ->
        if record["projected"] or
             Enum.any?(conversation.messages, &projected_message?(&1, record["id"])) do
          {Map.put(record, "projected", true), messages}
        else
          message = %{
            role: :user,
            content:
              "[Host feedback] #{record["source"]} / #{record["stage"]}\n#{record["text"]}",
            host_feedback: Map.drop(record, ["projected"])
          }

          {Map.put(record, "projected", true), messages ++ [message]}
        end
      end)

    conversation
    |> Map.put(:host_feedback, records)
    |> Map.put(:messages, conversation.messages ++ messages)
  end

  defp projected_message?(message, id) when is_map(message) do
    metadata = Map.get(message, :host_feedback, Map.get(message, "host_feedback"))
    is_map(metadata) and Map.get(metadata, "id", Map.get(metadata, :id)) == id
  end

  defp projected_message?(_, _), do: false

  defp valid_text?(value, max),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= max

  defp invalid(message), do: {:error, Error.new(:validation, message)}
end
