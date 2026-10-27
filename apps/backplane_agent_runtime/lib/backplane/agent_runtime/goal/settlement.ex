defmodule Backplane.AgentRuntime.Goal.Settlement do
  @moduledoc false
  alias Backplane.AgentRuntime.Error

  @identity ~w(run_id turn_id incarnation host_generation reservation_token)a
  @attestation ~w(admission executor runtime_admission future_start effects)a
  @receipt ~w(thread_id expected_goal_id admission reason attestation response)a
  @payload ~w(admission reason attestation response)a
  @reasons [:preparation_failed, :cancelled, :superseded]

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
    with {:ok, identity} <- identity(admission),
         true <- reason in @reasons,
         true <- closed?(attestation, @attestation),
         true <- closed?(attestation.admission, @identity),
         true <- attestation.admission === identity,
         true <- attestation.executor == :confirmed_down,
         true <- attestation.runtime_admission == :never_started,
         true <- attestation.future_start == :fenced,
         true <- attestation.effects == :none_dispatched do
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
         {:ok, normalized} <- normalize(receipt.admission, receipt.reason, receipt.attestation) do
      receipt.admission.reservation_token == token and same_payload?(receipt, normalized)
    else
      _ -> false
    end
  end

  defp closed?(value, keys),
    do:
      is_map(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp invalid, do: {:error, Error.new(:validation, "invalid unstarted admission settlement")}
end
