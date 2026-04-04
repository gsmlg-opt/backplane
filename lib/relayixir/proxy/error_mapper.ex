defmodule Relayixir.Proxy.ErrorMapper do
  @moduledoc """
  Maps internal error atoms to HTTP status codes and response bodies.
  """

  @doc """
  Returns `{status_code, body}` for the given error atom.
  """
  @spec to_response(atom()) :: {non_neg_integer(), String.t()}
  def to_response(:route_not_found), do: {404, "Not Found"}
  def to_response(:method_not_allowed), do: {405, "Method Not Allowed"}
  def to_response(:upstream_connect_failed), do: {502, "Bad Gateway"}
  def to_response(:upstream_timeout), do: {504, "Gateway Timeout"}
  def to_response(:upstream_invalid_response), do: {502, "Bad Gateway"}
  def to_response(:response_too_large), do: {502, "Bad Gateway"}
  def to_response(:request_too_large), do: {413, "Payload Too Large"}
  def to_response(:internal_error), do: {500, "Internal Server Error"}
  def to_response(_), do: {500, "Internal Server Error"}

  @doc """
  Sends an error response on the given `Plug.Conn`.
  """
  @spec send_error(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def send_error(%Plug.Conn{} = conn, error) do
    {status, body} = to_response(error)

    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end
end
