defmodule Backplane.Observability.Context do
  @moduledoc false

  alias Backplane.Observability.Id

  @enforce_keys [:request_id, :trace_id, :span_id, :service]
  defstruct [
    :request_id,
    :trace_id,
    :span_id,
    :parent_span_id,
    :client_id,
    :project_id,
    :agent_id,
    :session_id,
    :run_id,
    :node,
    service: "backplane"
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          client_id: String.t() | nil,
          project_id: String.t() | nil,
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          node: String.t() | nil,
          service: String.t()
        }

  @conn_assign_key :observability_context

  @doc "Builds a root context for an HTTP request."
  @spec root(keyword()) :: t()
  def root(opts \\ []) do
    gen = Id.generator()

    %__MODULE__{
      request_id: Keyword.get(opts, :request_id, gen.request_id()),
      trace_id: Keyword.get(opts, :trace_id, gen.trace_id()),
      span_id: Keyword.get(opts, :span_id, gen.span_id()),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      client_id: Keyword.get(opts, :client_id),
      project_id: Keyword.get(opts, :project_id),
      agent_id: Keyword.get(opts, :agent_id),
      session_id: Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id),
      node: Keyword.get(opts, :node, Node.self() |> Atom.to_string()),
      service: Keyword.get(opts, :service, "backplane")
    }
  end

  @doc "Creates a child span context from a parent context."
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = parent, opts \\ []) do
    gen = Id.generator()

    %__MODULE__{
      request_id: parent.request_id,
      trace_id: parent.trace_id,
      span_id: Keyword.get(opts, :span_id, gen.span_id()),
      parent_span_id: parent.span_id,
      client_id: Keyword.get(opts, :client_id, parent.client_id),
      project_id: Keyword.get(opts, :project_id, parent.project_id),
      agent_id: Keyword.get(opts, :agent_id, parent.agent_id),
      session_id: Keyword.get(opts, :session_id, parent.session_id),
      run_id: Keyword.get(opts, :run_id, parent.run_id),
      node: parent.node,
      service: Keyword.get(opts, :service, parent.service)
    }
  end

  @doc "Stores context on a Plug connection."
  @spec put(Plug.Conn.t(), t()) :: Plug.Conn.t()
  def put(conn, %__MODULE__{} = context) do
    Plug.Conn.assign(conn, @conn_assign_key, context)
  end

  @doc "Reads context from a Plug connection."
  @spec get(Plug.Conn.t()) :: t() | nil
  def get(conn), do: Map.get(conn.assigns, @conn_assign_key)

  @doc "Serializes context to a plain map for event envelopes."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ctx) do
    ctx
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "Returns bounded scalar metadata suitable for Logger."
  @spec logger_metadata(t()) :: keyword()
  def logger_metadata(%__MODULE__{} = ctx) do
    [
      request_id: ctx.request_id,
      trace_id: ctx.trace_id,
      span_id: ctx.span_id,
      client_id: ctx.client_id,
      session_id: ctx.session_id
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Parses a W3C `traceparent` header value.

  Returns `{trace_id, parent_span_id}` when valid, otherwise `:invalid`.
  """
  @spec parse_traceparent(String.t()) :: {:ok, {String.t(), String.t()}} | :invalid
  def parse_traceparent(header) when is_binary(header) do
    case String.trim(header) |> String.split("-", parts: 4) do
      ["00", trace_id, parent_id, _flags]
      when byte_size(trace_id) == 32 and byte_size(parent_id) == 16 ->
        if hex32?(trace_id) and hex16?(parent_id) do
          {:ok, {String.downcase(trace_id), String.downcase(parent_id)}}
        else
          :invalid
        end

      _ ->
        :invalid
    end
  end

  def parse_traceparent(_), do: :invalid

  defp hex32?(value), do: String.match?(value, ~r/^[0-9a-fA-F]{32}$/)
  defp hex16?(value), do: String.match?(value, ~r/^[0-9a-fA-F]{16}$/)
end
