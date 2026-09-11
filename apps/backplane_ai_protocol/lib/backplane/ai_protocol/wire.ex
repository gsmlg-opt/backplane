defmodule Backplane.AiProtocol.Wire do
  @moduledoc """
  Concrete Backplane WebSocket wire contract for V1.

  The state type is a pure contract record. Runtime transports own sockets and process effects.
  """

  alias Backplane.AiProtocol.Error

  @supported_wire %{major: 1, minor: 0}
  @protocol "backplane.ai.v1"
  @initial_limits %{
    inbound_request_bytes: 8_388_608,
    data_event_bytes: 65_536,
    initial_request_credit_bytes: 262_144,
    pending_request_buffer_bytes: 524_288,
    pending_connection_buffer_bytes: 8_388_608,
    concurrent_requests: 8,
    control_reserve_bytes: 65_536
  }
  @max_seen_ids 32

  defstruct [:hello, :welcome, seen_ids: %{}, credits: %{}, retired: false]

  @type t :: %__MODULE__{
          hello: map() | nil,
          welcome: map() | nil,
          seen_ids: map(),
          credits: map(),
          retired: boolean()
        }

  @spec hello(map()) :: {:ok, map()} | {:error, Error.t()}
  def hello(attrs) when is_map(attrs) do
    with :ok <- validate_protocol(Map.get(attrs, :protocol)),
         {:ok, wire} <- validate_wire(Map.get(attrs, :wire)) do
      {:ok,
       %{
         type: "hello",
         protocol: @protocol,
         wire: wire
       }}
    end
  end

  def hello(_attrs), do: {:error, Error.invalid!("Wire hello requires a map")}

  @spec welcome(map()) :: {:ok, map()} | {:error, Error.t()}
  def welcome(attrs) when is_map(attrs) do
    with :ok <- validate_protocol(Map.get(attrs, :protocol)),
         {:ok, wire} <- validate_wire(Map.get(attrs, :wire)),
         :ok <- validate_limits(Map.get(attrs, :limits)),
         :ok <- validate_flow_control(Map.get(attrs, :flow_control)) do
      {:ok,
       %{
         type: "welcome",
         protocol: @protocol,
         wire: wire,
         limits: Map.get(attrs, :limits, %{}),
         extensions: Map.get(attrs, :extensions, []),
         flow_control: Map.get(attrs, :flow_control)
       }}
    end
  end

  def welcome(_attrs), do: {:error, Error.invalid!("Wire welcome requires a map")}

  @spec command_response(map()) :: map()
  def command_response(attrs) when is_map(attrs) do
    %{
      type: "command.response",
      accepted: Map.get(attrs, :accepted, false),
      request_id: Map.get(attrs, :request_id),
      terminal: false
    }
  end

  @spec terminal(map()) :: map()
  def terminal(attrs) when is_map(attrs) do
    %{
      type: "request.finished",
      status: Map.get(attrs, :status),
      upstream_outcome: Map.get(attrs, :upstream_outcome),
      output_completeness: Map.get(attrs, :output_completeness),
      terminal: true
    }
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec accept_request(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def accept_request(%__MODULE__{retired: true}, _request_id) do
    {:error, Error.wire!("Wire connection is retired")}
  end

  def accept_request(%__MODULE__{} = wire, request_id) when is_binary(request_id) do
    cond do
      Map.has_key?(wire.seen_ids, request_id) ->
        {:error, Error.wire!("Duplicate request ID")}

      map_size(wire.seen_ids) >= @max_seen_ids ->
        {:ok, %{wire | retired: true}}

      true ->
        {:ok, %{wire | seen_ids: Map.put(wire.seen_ids, request_id, true)}}
    end
  end

  @spec seen_ids(t()) :: [String.t()]
  def seen_ids(%__MODULE__{seen_ids: seen_ids}), do: Map.keys(seen_ids) |> Enum.sort()

  @spec retire?(t()) :: boolean()
  def retire?(%__MODULE__{retired: retired}), do: retired

  @spec grant_credit(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def grant_credit(%__MODULE__{} = wire, request_id, amount)
      when is_binary(request_id) and amount >= 0 do
    current = Map.get(wire.credits, request_id, 0)
    {:ok, %{wire | credits: Map.put(wire.credits, request_id, current + amount)}}
  end

  @spec consume_credit(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def consume_credit(%__MODULE__{} = wire, request_id, amount)
      when is_binary(request_id) and amount >= 0 do
    current = Map.get(wire.credits, request_id, 0)

    if current >= amount do
      {:ok, %{wire | credits: Map.put(wire.credits, request_id, current - amount)}}
    else
      {:error, Error.wire!("Insufficient credit")}
    end
  end

  @spec credit(t(), String.t()) :: non_neg_integer()
  def credit(%__MODULE__{} = wire, request_id), do: Map.get(wire.credits, request_id, 0)

  @spec send_data(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def send_data(%__MODULE__{} = wire, request_id, bytes)
      when is_binary(request_id) and bytes >= 0 do
    limit = @initial_limits.data_event_bytes

    cond do
      bytes > limit ->
        {:error, Error.wire!("Data event exceeds #{limit} bytes")}

      Map.get(wire.credits, request_id, 0) < bytes ->
        {:error, Error.wire!("Insufficient credit")}

      true ->
        {:ok,
         %{
           wire
           | credits:
               Map.put(wire.credits, request_id, Map.get(wire.credits, request_id, 0) - bytes)
         }}
    end
  end

  defp validate_protocol("backplane.ai.v1"), do: :ok

  defp validate_protocol(nil), do: {:error, Error.invalid!("Protocol is required")}

  defp validate_protocol(_protocol),
    do: {:error, Error.incompatible!("Unsupported protocol")}

  defp validate_limits(%{} = limits) when is_map(limits) do
    required_keys = [
      :inbound_request_bytes,
      :data_event_bytes,
      :initial_request_credit_bytes,
      :pending_request_buffer_bytes,
      :pending_connection_buffer_bytes,
      :concurrent_requests,
      :control_reserve_bytes
    ]

    if Enum.all?(required_keys, &Map.has_key?(limits, &1)) do
      :ok
    else
      {:error, Error.invalid!("Wire limits are incomplete")}
    end
  end

  defp validate_limits(_limits), do: {:error, Error.invalid!("Wire limits must be a map")}

  defp validate_flow_control(:per_request_credit), do: :ok

  defp validate_flow_control(_value),
    do: {:error, Error.invalid!("Unsupported flow control")}

  defp validate_wire(%{major: major, minor: minor} = wire)
       when major == @supported_wire.major and minor == @supported_wire.minor do
    {:ok, wire}
  end

  defp validate_wire(_wire) do
    {:error, Error.incompatible!("Unsupported wire version", nil, :wire)}
  end
end
