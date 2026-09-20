defmodule Backplane.HostAgent.Memory.Mirror do
  @moduledoc "Validated, protected entrypoint for the revisioned canonical edge mirror."
  alias Backplane.HostAgent.Memory.Edge.Protection
  alias Backplane.HostAgent.Memory.Mirror.Store

  @spec offer(keyword()) :: {:ok, map()} | {:error, term()}
  def offer(opts \\ []) do
    with :ok <- protection(opts), do: Store.offer(store(opts))
  end

  @spec apply_delivery(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_delivery(delivery, opts \\ []) do
    with :ok <- protection(opts),
         :ok <- validate(delivery, opts) do
      Store.apply_delivery(store(opts), delivery)
    end
  end

  @spec offline_read(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def offline_read(operation, args, opts \\ []) do
    with :ok <- protection(opts),
         true <- operation in ["recall", "list", "stats"] and is_map(args),
         true <- partition?(Map.take(args, ["memory_space_id", "scope", "namespace"])),
         true <- is_integer(Map.get(args, "limit", 20)) and Map.get(args, "limit", 20) > 0,
         true <-
           is_binary(Map.get(args, "query", "")) and byte_size(Map.get(args, "query", "")) <= 4096 do
      Store.read(
        store(opts),
        operation,
        Map.put(args, "limit", min(Map.get(args, "limit", 20), 100))
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp protection(opts) do
    case Protection.status(Keyword.get(opts, :config, %{})) do
      :plaintext_development -> :ok
      reason -> {:error, reason}
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, Backplane.HostAgent.Memory.Edge.Store)

  defp validate(d, opts) do
    config = Keyword.get(opts, :config, %{})
    max_bytes = min(Map.get(config, :max_frame_bytes, 524_288), 524_288)
    max_items = min(Map.get(config, :max_changes, 100), 100)

    cond do
      not is_map(d) ->
        {:error, :invalid_delivery}

      byte_size(Jason.encode!(d)) > max_bytes ->
        {:error, :payload_too_large}

      d["protocol"] != "host_memory.v2" or d["status"] != "batch" ->
        {:error, :invalid_delivery}

      not partition?(d["partition"]) or not text?(d["batch_id"]) ->
        {:error, :invalid_delivery}

      Keyword.has_key?(opts, :partition) and Keyword.fetch!(opts, :partition) != d["partition"] ->
        {:error, :partition_mismatch}

      not revision?(d["to_revision"]) ->
        {:error, :invalid_delivery}

      true ->
        validate_kind(d, max_items)
    end
  rescue
    _ in [Jason.EncodeError, Protocol.UndefinedError, ArgumentError] ->
      {:error, :invalid_delivery}
  end

  defp validate_kind(%{"kind" => "delta"} = d, max_items) do
    changes = d["changes"]

    if is_list(changes) and length(changes) in 1..max_items and
         revision?(d["from_revision"]) and d["from_revision"] > 0 and
         d["to_revision"] == d["from_revision"] + length(changes) - 1 and
         Enum.with_index(changes, d["from_revision"])
         |> Enum.all?(fn {change, revision} -> change?(change, revision) end) do
      :ok
    else
      {:error, :invalid_delivery}
    end
  end

  defp validate_kind(%{"kind" => "snapshot_chunk"} = d, max_items) do
    if text?(d["snapshot_id"]) and revision?(d["base_revision"]) and
         d["to_revision"] >= d["base_revision"] and revision?(d["chunk_index"]) and
         is_integer(d["chunk_count"]) and d["chunk_count"] > d["chunk_index"] and
         revision?(d["item_count"]) and is_list(d["items"]) and length(d["items"]) <= max_items and
         Enum.all?(d["items"], &item?/1) and
         length(Enum.uniq_by(d["items"], & &1["canonical_id"])) == length(d["items"]) and
         hash?(d["chunk_hash"]) and hash?(d["integrity_hash"]) do
      if Store.hash(%{"items" => d["items"]}) == d["chunk_hash"],
        do: :ok,
        else: {:error, :integrity_failure}
    else
      {:error, :invalid_delivery}
    end
  end

  defp validate_kind(_, _), do: {:error, :invalid_delivery}

  defp change?(%{"revision" => r, "op" => op, "memory_id" => id, "payload" => payload}, revision) do
    r === revision and text?(id) and is_map(payload) and payload["canonical_id"] == id and
      (op == "delete" or (op == "upsert" and item?(payload)))
  end

  defp change?(_, _), do: false

  defp item?(item) when is_map(item) do
    text?(item["canonical_id"]) and text?(item["memory_type"]) and is_binary(item["content"]) and
      text?(item["content_hash"]) and item["lifecycle_state"] in ["active", "disputed"] and
      is_number(item["confidence"]) and is_list(item["tags"]) and
      Enum.all?(item["tags"], &is_binary/1) and
      is_map(item["metadata"]) and (is_nil(item["expires_at"]) or is_binary(item["expires_at"]))
  end

  defp item?(_), do: false

  defp partition?(p) when is_map(p),
    do:
      Enum.sort(Map.keys(p)) == ["memory_space_id", "namespace", "scope"] and
        Enum.all?(Map.values(p), &text?/1)

  defp partition?(_), do: false
  defp text?(s), do: is_binary(s) and byte_size(s) in 1..1024
  defp revision?(n), do: is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807
  defp hash?(s), do: is_binary(s) and Regex.match?(~r/^sha256:[0-9a-f]{64}$/, s)
end
