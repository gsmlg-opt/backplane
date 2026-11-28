defmodule Backplane.DiagnosticsClient.Receipt do
  @moduledoc "Validates diagnostics batches and reconciles complete per-item replies."

  alias Backplane.DiagnosticsClient.{Canonical, Envelope}

  @max_items 100
  @max_bytes 512 * 1024
  @max_retry_after_ms 86_400_000
  @local "diagnostics.v1"
  @remote "host_diagnostics.v1"
  @local_level "local_durable"
  @remote_level "remote_durable"
  @statuses ~w(stored duplicate retryable_rejection permanent_rejection identity_conflict unsupported_schema)

  def limits,
    do: %{
      "max_items" => @max_items,
      "max_bytes" => @max_bytes,
      "max_event_bytes" => Canonical.max_bytes()
    }

  def protocol(:local), do: @local
  def protocol(:remote), do: @remote

  def batch(stage, batch_id, items),
    do: %{"protocol" => protocol(stage), "batch_id" => batch_id, "events" => items}

  def entry(event, digest), do: %{"event" => event, "digest" => digest}

  def response(stage, batch_id, receipts) do
    %{"batch_id" => batch_id, "level" => level(stage), "receipts" => receipts}
  end

  @doc "Validates batch framing, preserving malformed entries for individual rejection."
  def validate_batch(
        %{"protocol" => protocol, "batch_id" => batch_id, "events" => items} = batch,
        stage
      )
      when is_list(items) and map_size(batch) == 3 do
    cond do
      protocol != protocol(stage) -> {:error, :unsupported_schema}
      not Envelope.id?(batch_id) or items == [] -> {:error, :invalid_batch}
      length(Enum.take(items, @max_items + 1)) > @max_items -> {:error, :batch_too_large}
      true -> {:ok, batch_id, items}
    end
  end

  def validate_batch(_, _), do: {:error, :invalid_batch}

  def decode_batch(input, _stage) when is_binary(input) and byte_size(input) > @max_bytes,
    do: {:error, :batch_too_large}

  def decode_batch(input, stage) when is_binary(input) do
    case Formata.JSON.decode(input) do
      {:ok, batch} -> validate_batch(batch, stage)
      {:error, _} -> {:error, :invalid_batch}
    end
  end

  @doc "Encodes a batch for HTTP or measures its payload before Channel framing."
  def encode_batch(batch) do
    bytes = Formata.JSON.encode!(batch)
    if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: {:error, :batch_too_large}
  end

  @doc "Validates and verifies a claimed wire entry without redacting its immutable bytes."
  def validate_entry(%{"event" => event, "digest" => digest} = entry) when map_size(entry) == 2 do
    with {:ok, bytes, ^digest} <- Envelope.seal(event) do
      {:ok, event, bytes, digest}
    else
      {:ok, _, _} -> {:error, :digest_mismatch}
      {:error, _} = error -> error
    end
  end

  def validate_entry(_), do: {:error, :invalid_event}

  def result(entry, status, reason \\ nil) when status in @statuses do
    {id, digest} = claim(entry)
    receipt = %{"event_id" => id, "digest" => digest, "status" => status}
    if is_nil(reason), do: receipt, else: Map.put(receipt, "reason", Atom.to_string(reason))
  end

  @doc "Returns only unique, well-formed replies matching the sent IDs and digests. Missing keys are unknown."
  def reconcile(
        %{"batch_id" => batch_id, "level" => level, "receipts" => replies} = response,
        stage,
        batch_id,
        sent
      )
      when is_list(replies) and map_size(response) == 3 do
    if level == level(stage) and length(Enum.take(replies, @max_items + 1)) <= @max_items do
      sent_by_id = sent |> Enum.map(&claim/1) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      replies
      |> Enum.group_by(&reply_id/1)
      |> Enum.reduce(%{}, fn {id, matching}, valid ->
        case {Map.get(sent_by_id, id), matching} do
          {[digest], [%{"digest" => reply_digest} = reply]} when digest == reply_digest ->
            if valid_reply?(id, digest, reply), do: Map.put(valid, id, reply), else: valid

          _ ->
            valid
        end
      end)
    else
      %{}
    end
  end

  def reconcile(_, _, _, _), do: %{}

  defp claim(%{"event" => %{"event_id" => id}, "digest" => digest}) do
    {if(Envelope.id?(id), do: id), if(Canonical.digest?(digest), do: digest)}
  end

  defp claim(_), do: {nil, nil}

  defp reply_id(%{"event_id" => id}), do: id
  defp reply_id(_), do: nil

  defp valid_reply?(id, digest, %{"status" => status} = reply) when status in @statuses do
    Envelope.id?(id) and Canonical.digest?(digest) and
      Enum.all?(Map.keys(reply), &(&1 in ~w(event_id digest status reason retry_after_ms))) and
      valid_reason?(Map.get(reply, "reason")) and valid_delay?(Map.get(reply, "retry_after_ms"))
  end

  defp valid_reply?(_, _, _), do: false

  defp valid_reason?(nil), do: true

  defp valid_reason?(reason),
    do: is_binary(reason) and byte_size(reason) in 1..64 and reason =~ ~r/\A[a-z0-9_]+\z/

  defp valid_delay?(nil), do: true
  defp valid_delay?(delay), do: is_integer(delay) and delay in 0..@max_retry_after_ms

  defp level(:local), do: @local_level
  defp level(:remote), do: @remote_level
end
