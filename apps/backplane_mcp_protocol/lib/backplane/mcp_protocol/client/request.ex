defmodule Backplane.McpProtocol.Client.Request do
  @moduledoc false

  alias Backplane.McpProtocol.Client.ToolCall

  @type t :: %__MODULE__{
          id: String.t(),
          logical_id: String.t(),
          method: String.t(),
          from: GenServer.from() | nil,
          timer_ref: reference(),
          start_time: integer(),
          params: map(),
          base_params: map(),
          extra_meta: map(),
          progress_opts: keyword() | nil,
          timeout: pos_integer() | nil,
          deadline: integer() | nil,
          continuation: term(),
          resolver_supervisor: pid() | nil,
          resolver_task: Task.t() | nil,
          tool_call: ToolCall.t() | nil,
          owner_monitor: reference() | nil,
          dispatch_task: Task.t() | nil,
          dispatch_status: :registered | :dispatching | :accepted | nil,
          progress_owner: term()
        }

  defstruct [
    :id,
    :logical_id,
    :method,
    :from,
    :timer_ref,
    :start_time,
    :params,
    :timeout,
    :deadline,
    :continuation,
    :resolver_supervisor,
    :resolver_task,
    :tool_call,
    :owner_monitor,
    :dispatch_task,
    :dispatch_status,
    :progress_owner,
    base_params: %{},
    extra_meta: %{},
    progress_opts: nil
  ]

  @doc """
  Creates a new request struct.

  ## Parameters

    * `attrs` - Map containing the request attributes
      * `:id` - The unique request ID
      * `:method` - The MCP method name
      * `:from` - The GenServer caller reference
      * `:timer_ref` - Reference to the request-specific timeout timer
  """
  @spec new(%{
          id: String.t(),
          method: String.t(),
          from: GenServer.from(),
          timer_ref: reference(),
          params: map()
        }) :: t()
  def new(attrs) do
    %__MODULE__{
      id: attrs.id,
      logical_id: attrs.id,
      method: attrs.method,
      from: Map.get(attrs, :from),
      timer_ref: attrs.timer_ref,
      params: attrs.params,
      base_params: attrs.params,
      start_time: System.monotonic_time(:millisecond)
    }
  end

  @doc false
  @spec async?(t()) :: boolean()
  def async?(%__MODULE__{tool_call: %ToolCall{}}), do: true
  def async?(%__MODULE__{}), do: false

  @doc false
  @spec reply(t(), term()) :: :ok
  def reply(%__MODULE__{tool_call: %ToolCall{} = handle}, result) do
    ToolCall.deliver(handle, result)
  end

  def reply(%__MODULE__{from: from}, result) do
    GenServer.reply(from, result)
  end

  @doc "Retains the immutable operation data and absolute deadline for retries."
  @spec retain_operation(t(), map()) :: t()
  def retain_operation(%__MODULE__{} = request, operation) when is_map(operation) do
    now = System.monotonic_time(:millisecond)
    remaining = Process.read_timer(request.timer_ref) || 0

    %{
      request
      | base_params: operation.params,
        params: operation.params,
        extra_meta: operation.extra_meta,
        progress_opts: operation.progress_opts,
        timeout: operation.timeout,
        deadline: now + remaining
    }
  end

  @doc "Returns the time remaining before the operation's original deadline."
  @spec remaining_time(t()) :: non_neg_integer() | nil
  def remaining_time(%__MODULE__{deadline: nil}), do: nil

  def remaining_time(%__MODULE__{deadline: deadline}) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  @doc """
  Calculates the elapsed time for a request in milliseconds.
  """
  @spec elapsed_time(t()) :: integer()
  def elapsed_time(%__MODULE__{start_time: start_time}) do
    System.monotonic_time(:millisecond) - start_time
  end
end

defimpl Inspect, for: Backplane.McpProtocol.Client.Request do
  def inspect(%{id: id, method: method, start_time: start_time}, _opts) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    "#MCP.Client.Request<#{id} #{method} (elapsed: #{elapsed}ms)>"
  end
end
