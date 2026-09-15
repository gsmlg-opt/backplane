defmodule Backplane.AiProtocol.Wire do
  @moduledoc """
  Pure Backplane WebSocket V1 admission, correlation, sequencing, and credit contract.

  Unknown or terminal request IDs are rejected without allocating state. At the lifetime ID
  limit the connection enters draining state: active requests may terminate, but no new request
  is admitted.
  """

  alias Backplane.AiProtocol.{Error, Serialization}

  @protocol "backplane.ai.v1"
  @wire %{major: 1, minor: 0}
  @required_limits ~w(inbound_request_bytes data_event_bytes initial_request_credit_bytes pending_request_buffer_bytes pending_connection_buffer_bytes concurrent_requests control_reserve_bytes)a
  @default_max_seen_ids 32
  @max_request_id_bytes 128

  defstruct handshake?: false,
            limits: nil,
            max_seen_ids: @default_max_seen_ids,
            active: %{},
            seen_ids: MapSet.new(),
            credits: %{},
            draining?: false

  @type t :: %__MODULE__{}

  @spec hello(map()) :: {:ok, map()} | {:error, Error.t()}
  def hello(attrs) when is_map(attrs) do
    with :ok <- validate_message_id(value(attrs, :message_id)),
         :ok <- validate_protocol(value(attrs, :protocol)),
         :ok <- validate_wire(value(attrs, :wire)) do
      {:ok,
       envelope("hello", value(attrs, :message_id), nil, nil, "control", %{
         "protocol" => @protocol,
         "wire" => @wire
       })}
    end
  end

  def hello(_), do: {:error, Error.invalid!("Wire hello requires a map")}

  @spec welcome(map()) :: {:ok, map()} | {:error, Error.t()}
  def welcome(attrs) when is_map(attrs) do
    limits = value(attrs, :limits)

    with :ok <- validate_message_id(value(attrs, :message_id)),
         :ok <- validate_protocol(value(attrs, :protocol)),
         :ok <- validate_wire(value(attrs, :wire)),
         :ok <- validate_limits(limits),
         :ok <- validate_flow_control(value(attrs, :flow_control)) do
      {:ok,
       envelope("welcome", value(attrs, :message_id), nil, nil, "control", %{
         "protocol" => @protocol,
         "wire" => @wire,
         "limits" => stringify_keys(limits),
         "flow_control" => "per_request_credit",
         "extensions" => value(attrs, :extensions) || []
       })}
    end
  end

  def welcome(_), do: {:error, Error.invalid!("Wire welcome requires a map")}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec handshake(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def handshake(%__MODULE__{handshake?: false} = state, welcome_attrs) do
    with {:ok, _welcome} <- welcome(welcome_attrs),
         :ok <- validate_max_seen_ids(value(welcome_attrs, :max_seen_ids)) do
      {:ok,
       %{
         state
         | handshake?: true,
           limits: atom_limits(value(welcome_attrs, :limits)),
           max_seen_ids: value(welcome_attrs, :max_seen_ids) || @default_max_seen_ids
       }}
    end
  end

  def handshake(%__MODULE__{}, _), do: {:error, Error.wire!("Wire handshake already complete")}

  @spec accept_request(t(), String.t()) ::
          {:ok, t()} | {:error, Error.t()} | {:error, Error.t(), t()}
  def accept_request(%__MODULE__{handshake?: false}, _),
    do: {:error, Error.wire!("Wire handshake is required")}

  def accept_request(%__MODULE__{draining?: true}, _),
    do: {:error, Error.wire!("Wire connection is draining")}

  def accept_request(%__MODULE__{} = state, request_id) do
    with :ok <- validate_request_id(request_id) do
      cond do
        MapSet.member?(state.seen_ids, request_id) ->
          {:error, Error.wire!("Duplicate request ID")}

        map_size(state.active) >= state.limits.concurrent_requests ->
          {:error, Error.wire!("Concurrent request limit reached")}

        MapSet.size(state.seen_ids) >= state.max_seen_ids ->
          draining = %{state | draining?: true}

          {:error, Error.wire!("Lifetime request ID limit reached; connection is draining"),
           draining}

        true ->
          active = Map.put(state.active, request_id, %{next_sequence: 0})
          credits = Map.put(state.credits, request_id, state.limits.initial_request_credit_bytes)

          {:ok,
           %{
             state
             | active: active,
               seen_ids: MapSet.put(state.seen_ids, request_id),
               credits: credits
           }}
      end
    end
  end

  @spec grant_credit(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def grant_credit(%__MODULE__{} = state, request_id, amount)
      when is_integer(amount) and amount >= 0 do
    if Map.has_key?(state.active, request_id) do
      {:ok, %{state | credits: Map.update!(state.credits, request_id, &(&1 + amount))}}
    else
      {:error, Error.wire!("Credit target is unknown or terminal")}
    end
  end

  def grant_credit(%__MODULE__{}, _, _),
    do: {:error, Error.wire!("Credit must be a non-negative integer")}

  @spec send_data(t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def send_data(%__MODULE__{} = state, attrs) when is_map(attrs) do
    request_id = value(attrs, :request_id)
    sequence = value(attrs, :sequence)
    message_id = value(attrs, :message_id)
    payload = value(attrs, :payload)

    with :ok <- validate_message_id(message_id),
         {:ok, request} <- fetch_active(state, request_id),
         :ok <- validate_sequence(sequence, request.next_sequence),
         envelope <-
           envelope("response.event", message_id, request_id, sequence, "data", payload),
         {:ok, encoded} <- Serialization.to_json(envelope),
         :ok <- within_bytes(encoded, state.limits.data_event_bytes),
         :ok <- has_credit(state, request_id, byte_size(encoded)) do
      next_active = put_in(state.active[request_id].next_sequence, sequence + 1)
      next_credits = Map.update!(state.credits, request_id, &(&1 - byte_size(encoded)))
      {:ok, %{state | active: next_active, credits: next_credits}, envelope}
    end
  end

  def send_data(%__MODULE__{}, _), do: {:error, Error.wire!("Data envelope requires a map")}

  @spec terminal(t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def terminal(%__MODULE__{} = state, attrs) when is_map(attrs) do
    request_id = value(attrs, :request_id)
    message_id = value(attrs, :message_id)

    with :ok <- validate_message_id(message_id),
         {:ok, request} <- fetch_active(state, request_id) do
      terminal =
        envelope("request.finished", message_id, request_id, request.next_sequence, "terminal", %{
          "status" => value(attrs, :status),
          "upstream_outcome" => value(attrs, :upstream_outcome),
          "output_completeness" => value(attrs, :output_completeness)
        })

      {:ok,
       %{
         state
         | active: Map.delete(state.active, request_id),
           credits: Map.delete(state.credits, request_id)
       }, terminal}
    end
  end

  def terminal(%__MODULE__{}, _), do: {:error, Error.wire!("Terminal envelope requires a map")}

  @spec command_response(map()) :: map()
  def command_response(attrs) when is_map(attrs) do
    envelope(
      "command.response",
      value(attrs, :message_id),
      value(attrs, :request_id),
      value(attrs, :sequence),
      "control",
      %{"accepted" => value(attrs, :accepted) || false}
    )
  end

  def seen_ids(%__MODULE__{seen_ids: ids}), do: ids |> MapSet.to_list() |> Enum.sort()
  def active_ids(%__MODULE__{active: active}), do: active |> Map.keys() |> Enum.sort()
  def credit(%__MODULE__{} = state, request_id), do: Map.get(state.credits, request_id, 0)
  def retire?(%__MODULE__{draining?: draining?}), do: draining?

  defp envelope(type, message_id, request_id, sequence, classification, payload) do
    %{
      "wire" => %{"major" => 1, "minor" => 0},
      "type" => type,
      "message_id" => message_id,
      "request_id" => request_id,
      "sequence" => sequence,
      "classification" => classification,
      "payload" => stringify_keys(payload)
    }
  end

  defp fetch_active(state, request_id) do
    case Map.fetch(state.active, request_id) do
      {:ok, request} -> {:ok, request}
      :error -> {:error, Error.wire!("Request is unknown or terminal")}
    end
  end

  defp validate_protocol(@protocol), do: :ok
  defp validate_protocol(nil), do: {:error, Error.invalid!("Protocol is required")}
  defp validate_protocol(_), do: {:error, Error.incompatible!("Unsupported protocol", nil, :wire)}

  defp validate_wire(wire) do
    if atom_limits(wire) == @wire,
      do: :ok,
      else: {:error, Error.incompatible!("Unsupported wire version", nil, :wire)}
  end

  defp validate_limits(limits) when is_map(limits) do
    normalized = atom_limits(limits)

    if Enum.all?(@required_limits, &(is_integer(normalized[&1]) and normalized[&1] > 0)),
      do: :ok,
      else: {:error, Error.invalid!("Wire limits must contain positive integers")}
  end

  defp validate_limits(_), do: {:error, Error.invalid!("Wire limits must be a map")}

  defp validate_flow_control(value) when value in [:per_request_credit, "per_request_credit"],
    do: :ok

  defp validate_flow_control(_), do: {:error, Error.invalid!("Unsupported flow control")}

  defp validate_max_seen_ids(nil), do: :ok
  defp validate_max_seen_ids(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_seen_ids(_),
    do: {:error, Error.invalid!("Wire max_seen_ids must be a positive integer")}

  defp validate_request_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_request_id_bytes do
    if String.valid?(id),
      do: :ok,
      else: {:error, Error.wire!("Request ID must be non-empty bounded UTF-8")}
  end

  defp validate_request_id(_),
    do: {:error, Error.wire!("Request ID must be non-empty bounded UTF-8")}

  defp validate_message_id(id), do: validate_request_id(id)

  defp validate_sequence(sequence, expected)
       when is_integer(sequence) and sequence >= 0 and sequence == expected,
       do: :ok

  defp validate_sequence(_, _), do: {:error, Error.wire!("Invalid or duplicate request sequence")}
  defp within_bytes(encoded, max) when byte_size(encoded) <= max, do: :ok

  defp within_bytes(_, max),
    do: {:error, Error.wire!("Encoded data envelope exceeds #{max} bytes")}

  defp has_credit(state, id, bytes) do
    if credit(state, id) >= bytes, do: :ok, else: {:error, Error.wire!("Insufficient credit")}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp atom_limits(map) when is_map(map) do
    Enum.reduce(@required_limits ++ [:major, :minor], %{}, fn key, acc ->
      case value(map, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp atom_limits(_), do: %{}

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when value in [nil, true, false], do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value
end
