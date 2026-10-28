defmodule Backplane.AgentRuntime.Goal.Settlement do
  @moduledoc false
  alias Backplane.AgentRuntime.Error

  @identity ~w(run_id turn_id incarnation host_generation reservation_token)a
  @attestation ~w(admission executor runtime_admission future_start effects)a
  @receipt ~w(thread_id expected_goal_id admission reason attestation response)a
  @payload ~w(admission reason attestation response)a
  @reasons [:preparation_failed, :cancelled, :superseded]
  @host_reasons [:host_stopped, :cancelled, :superseded]
  @effects ~w(kind records result cleanup)a
  @effect_record ~w(effect_id kind result)a
  @max_effect_bytes 1_048_576

  def identity(admission) when is_map(admission) do
    if Enum.all?(@identity, &Map.has_key?(admission, &1)) and
         Enum.all?([:run_id, :turn_id, :reservation_token], &nonempty?(admission[&1])) and
         is_integer(admission[:incarnation]) and admission.incarnation > 0 and
         serializable?(Map.take(admission, @identity)),
       do: {:ok, Map.take(admission, @identity)},
       else: invalid()
  end

  def identity(_), do: invalid()

  def normalize(admission, reason, attestation) do
    normalize(admission, reason, attestation, @reasons, &(&1 == :none_dispatched))
  end

  def normalize_host(admission, reason, attestation) do
    normalize(admission, reason, attestation, @host_reasons, &host_effects?/1)
  end

  defp normalize(admission, reason, attestation, reasons, effects?) do
    with {:ok, identity} <- identity(admission),
         true <- reason in reasons,
         true <- closed?(attestation, @attestation),
         true <- closed?(attestation.admission, @identity),
         true <- attestation.admission === identity,
         true <- attestation.executor == :confirmed_down,
         true <- attestation.runtime_admission == :never_started,
         true <- attestation.future_start == :fenced,
         true <- effects?.(attestation.effects) do
      {:ok,
       %{
         admission: identity,
         reason: reason,
         attestation: attestation,
         response: {:settled, reason}
       }}
    else
      _ -> invalid()
    end
  end

  defp host_effects?(effects) do
    with true <- closed?(effects, @effects),
         true <- effects.kind == :host_pre_runtime and effects.cleanup == :confirmed,
         true <- is_list(effects.records),
         true <- length(effects.records) in 1..128,
         true <- Enum.all?(effects.records, &effect_record?/1),
         ids = Enum.map(effects.records, & &1.effect_id),
         true <- length(Enum.uniq(ids)) == length(ids),
         true <- json_value?(effects.result) do
      # Encode the fixed schema tags as strings; retain the original attestation
      # unchanged in the ledger, including ordered records and numeric types.
      encoded = JSON.encode!(%{effects | kind: "host_pre_runtime", cleanup: "confirmed"})
      byte_size(encoded) <= @max_effect_bytes
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp effect_record?(record) do
    closed?(record, @effect_record) and text?(record.effect_id) and text?(record.kind) and
      json_value?(record.result)
  end

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_value?(item)
      end)

  defp json_value?(value) when is_list(value), do: json_list?(value)
  defp json_value?(_), do: false
  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json_value?(head) and json_list?(tail)
  defp json_list?(_), do: false
  defp text?(value), do: nonempty?(value) and String.valid?(value)

  def same_payload?(saved, payload), do: Map.take(saved, @payload) === payload

  def validate_extensions(record) do
    if valid_counts?(Map.get(record, :runtime_receipt_counts, %{})) and
         valid_receipts?(Map.get(record, :admission_settlements, %{}), record[:thread_id]),
       do: :ok,
       else: {:error, Error.new(:malformed_result, "invalid goal admission settlement state")}
  end

  def serializable?(value)
      when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
      do: false

  def serializable?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> serializable?(key) and serializable?(item) end)

  def serializable?(value) when is_list(value), do: serializable_list?(value)

  def serializable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  def serializable?(_), do: true

  defp serializable_list?([]), do: true
  defp serializable_list?([head | tail]), do: serializable?(head) and serializable_list?(tail)
  defp serializable_list?(_), do: false

  defp valid_counts?(counts) when is_map(counts) do
    Enum.all?(counts, fn
      {{run, incarnation}, count} ->
        is_binary(run) and is_integer(incarnation) and incarnation >= 0 and
          is_integer(count) and count >= 0

      _ ->
        false
    end)
  end

  defp valid_counts?(_), do: false

  defp valid_receipts?(receipts, thread) when is_map(receipts) do
    Enum.all?(receipts, fn {token, receipt} -> valid_receipt?(token, receipt, thread) end)
  end

  defp valid_receipts?(_, _), do: false

  defp valid_receipt?(token, receipt, thread) do
    with true <- closed?(receipt, @receipt),
         true <- nonempty?(receipt.thread_id) and receipt.thread_id == thread,
         true <- nonempty?(receipt.expected_goal_id),
         {:ok, normalized} <- normalize_receipt(receipt) do
      receipt.admission.reservation_token == token and same_payload?(receipt, normalized)
    else
      _ -> false
    end
  end

  defp normalize_receipt(%{attestation: %{effects: :none_dispatched}} = receipt),
    do: normalize(receipt.admission, receipt.reason, receipt.attestation)

  defp normalize_receipt(receipt),
    do: normalize_host(receipt.admission, receipt.reason, receipt.attestation)

  defp closed?(value, keys),
    do:
      is_map(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp invalid, do: {:error, Error.new(:validation, "invalid unstarted admission settlement")}
end
