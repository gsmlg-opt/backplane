defmodule Backplane.Transport.McpObservability do
  @moduledoc """
  Root MCP proxy access recorder.

  Starts observability before rate limiting, auth, parsing, and dispatch, then
  finalizes terminal outcomes with byte counts and bounded metadata only.
  """

  @behaviour Plug

  alias Backplane.MCP.AccessEvent

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    access = AccessEvent.start(conn)

    conn
    |> Plug.Conn.assign(:mcp_access_event, access)
    |> Plug.Conn.assign(:mcp_access_finalized, false)
    |> Plug.Conn.register_before_send(fn conn ->
      if conn.assigns[:mcp_access_finalized], do: conn, else: finalize(conn)
    end)
  end

  @doc "Finalizes observability for a connection response."
  @spec finalize(Plug.Conn.t()) :: Plug.Conn.t()
  def finalize(%Plug.Conn{assigns: %{mcp_access_event: access}} = conn) do
    outcome = outcome_for(conn)
    opts = finalize_opts(conn, outcome)

    :ok = AccessEvent.finalize(access, conn, outcome, opts)

    conn
    |> Plug.Conn.assign(:mcp_access_finalized, true)
    |> then(fn conn ->
      %{conn | assigns: Map.delete(conn.assigns, :mcp_access_event)}
    end)
  end

  def finalize(conn), do: conn

  @doc "Finalizes observability outside the normal plug pipeline (parser rescues)."
  @spec finalize_rescue(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def finalize_rescue(%Plug.Conn{} = conn, opts \\ []) do
    conn =
      if Map.has_key?(conn.assigns, :mcp_access_event) do
        conn
      else
        Plug.Conn.assign(conn, :mcp_access_event, AccessEvent.start(conn))
      end

    outcome = Keyword.get(opts, :outcome, :error)
    finalize_opts = Keyword.merge(finalize_opts(conn, outcome), opts)

    conn = Map.put(conn, :status, Keyword.get(finalize_opts, :status, conn.status))

    :ok = AccessEvent.finalize(conn.assigns.mcp_access_event, conn, outcome, finalize_opts)
    conn
  end

  defp outcome_for(conn) do
    cond do
      conn.state == :set_chunked or conn.state == :chunked ->
        :success

      is_integer(conn.status) and conn.status >= 500 ->
        :error

      is_integer(conn.status) and conn.status >= 400 ->
        :error

      jsonrpc_error?(conn) ->
        :error

      true ->
        :success
    end
  end

  defp jsonrpc_error?(conn) do
    with true <- is_binary(conn.resp_body),
         {:ok, decoded} <- Jason.decode(conn.resp_body),
         true <- jsonrpc_error_present?(decoded) do
      true
    else
      _ -> false
    end
  end

  defp jsonrpc_error_present?(%{"error" => _}), do: true

  defp jsonrpc_error_present?(list) when is_list(list) do
    Enum.any?(list, &jsonrpc_error_present?/1)
  end

  defp jsonrpc_error_present?(_), do: false

  defp finalize_opts(conn, outcome) do
    []
    |> maybe_put(:status, conn.status)
    |> maybe_put(:error_kind, error_kind_for(conn))
    |> maybe_put(:error_message, error_message_for(conn, outcome))
    |> maybe_put(:error_reason, error_message_for(conn, outcome))
  end

  defp error_kind_for(%Plug.Conn{status: 429}), do: "rate_limit"
  defp error_kind_for(%Plug.Conn{status: status}) when status in [401, 403], do: "auth"
  defp error_kind_for(%Plug.Conn{status: 413}), do: "validation"
  defp error_kind_for(%Plug.Conn{status: 400}), do: "validation"
  defp error_kind_for(_), do: "internal"

  defp error_message_for(%Plug.Conn{status: 429}, _), do: "Too many requests"
  defp error_message_for(%Plug.Conn{status: 401}, _), do: "Unauthorized"
  defp error_message_for(%Plug.Conn{status: 403}, _), do: "Forbidden"
  defp error_message_for(%Plug.Conn{status: 413}, _), do: "Request body too large"
  defp error_message_for(%Plug.Conn{status: 400}, _), do: "Malformed request body"

  defp error_message_for(conn, :error) do
    case jsonrpc_error_message(conn) do
      nil -> nil
      message -> message
    end
  end

  defp error_message_for(_conn, _), do: nil

  defp jsonrpc_error_message(conn) do
    with true <- is_binary(conn.resp_body),
         {:ok, decoded} <- Jason.decode(conn.resp_body),
         message when is_binary(message) <- jsonrpc_message_from(decoded) do
      message
    else
      _ -> nil
    end
  end

  defp jsonrpc_message_from(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp jsonrpc_message_from(list) when is_list(list) do
    Enum.find_value(list, &jsonrpc_message_from/1)
  end

  defp jsonrpc_message_from(_), do: nil

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
