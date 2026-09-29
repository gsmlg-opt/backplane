defmodule Backplane.AgentRuntime.Codex.Interactions do
  @moduledoc """
  Host-owned interaction ledger for Codex user input and messages.

  The model can create a request, but only a caller holding the original host
  token, run and incarnation can settle it.  A settlement is single-use.
  """

  alias Backplane.AgentRuntime.Error

  @type t :: %{next: pos_integer(), pending: map(), settled: map()}

  @spec new() :: t()
  def new, do: %{next: 1, pending: %{}, settled: %{}}

  @spec request(t(), atom(), term(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def request(state, kind, payload, auth)
      when is_map(state) and kind in [:request, :answer, :cancel] and is_map(auth) do
    with :ok <- valid_auth(auth),
         :ok <- valid_payload(payload) do
      id = Map.get(auth, :interaction_id) || "interaction_#{state.next}"

      if Map.has_key?(state.pending, id) or Map.has_key?(state.settled, id) do
        {:error, Error.new(:resource_conflict, "interaction id is already used")}
      else
        interaction = %{
          id: id,
          kind: kind,
          payload: payload,
          run_id: auth.run_id,
          token: auth.token,
          owner: auth.owner,
          incarnation: auth.incarnation,
          status: :pending
        }

        {:ok, %{state | next: state.next + 1, pending: Map.put(state.pending, id, interaction)},
         request_receipt(kind, id)}
      end
    end
  end

  @spec answer(t(), String.t(), term(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def answer(state, id, value, auth), do: settle(state, id, :answered, value, auth)

  @spec cancel(t(), String.t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def cancel(state, id, auth), do: settle(state, id, :cancelled, nil, auth)

  @spec settle(t(), String.t(), atom(), term(), map()) ::
          {:ok, t(), map()} | {:error, Error.t()}
  def settle(state, id, status, value, auth)
      when is_map(state) and is_binary(id) and status in [:answered, :cancelled] and is_map(auth) do
    with {:ok, interaction} <- fetch_pending(state, id),
         :ok <- authenticate(interaction, auth) do
      result = %{interaction_id: id, status: status, value: value, completion: :settled}

      updated = %{
        state
        | pending: Map.delete(state.pending, id),
          settled: Map.put(state.settled, id, result)
      }

      {:ok, updated, result}
    end
  end

  defp fetch_pending(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, interaction} ->
        {:ok, interaction}

      :error ->
        {:error,
         Error.new(:not_found, "interaction is not pending", details: %{interaction_id: id})}
    end
  end

  defp request_receipt(:request, id),
    do: %{
      interaction_id: id,
      kind: :request,
      status: :requested,
      acknowledgement: :accepted,
      completion: :pending
    }

  defp request_receipt(:answer, id),
    do: %{
      interaction_id: id,
      kind: :answer,
      status: :delivered,
      acknowledgement: :accepted,
      completion: :pending
    }

  defp request_receipt(:cancel, id),
    do: %{
      interaction_id: id,
      kind: :cancel,
      status: :cancel_requested,
      acknowledgement: :accepted,
      completion: :pending
    }

  defp authenticate(interaction, auth) do
    keys = [:run_id, :token, :owner, :incarnation]

    if Enum.all?(keys, &(Map.get(interaction, &1) == Map.get(auth, &1))) do
      :ok
    else
      {:error, Error.new(:forbidden, "interaction responder is not authorized")}
    end
  end

  defp valid_auth(auth) do
    if Enum.all?(
         [:run_id, :token, :owner],
         &(is_binary(Map.get(auth, &1)) and Map.get(auth, &1) != "")
       ) and
         is_integer(Map.get(auth, :incarnation)) and Map.get(auth, :incarnation) >= 0 do
      :ok
    else
      {:error, Error.new(:validation, "run, token, owner and incarnation are required")}
    end
  end

  defp valid_payload(payload) when is_binary(payload) or is_map(payload) or is_list(payload),
    do: :ok

  defp valid_payload(_), do: {:error, Error.new(:validation, "interaction payload is invalid")}
end
