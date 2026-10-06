defmodule Backplane.Audio.Error do
  @moduledoc false

  defexception [:message, :type, :param, :code, :status]

  def new(status, message, param, code, type \\ "invalid_request_error") do
    %__MODULE__{status: status, message: message, type: type, param: param, code: code}
  end

  def send(conn, %__MODULE__{} = error) do
    body = %{
      error: %{
        message: error.message,
        type: error.type,
        param: error.param,
        code: error.code
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(error.status, Jason.encode!(body))
  end
end
