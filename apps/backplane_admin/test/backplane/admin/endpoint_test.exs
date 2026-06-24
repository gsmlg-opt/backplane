defmodule Backplane.Admin.EndpointTest do
  use ExUnit.Case, async: true

  test "disables origin checks" do
    endpoint_config = Application.fetch_env!(:backplane_admin, Backplane.Admin.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == false
  end

  test "live socket only enables the websocket transport" do
    assert {"/live", Phoenix.LiveView.Socket, opts} =
             Enum.find(Backplane.Admin.Endpoint.__sockets__(), fn {path, _socket, _opts} ->
               path == "/live"
             end)

    assert Keyword.has_key?(opts, :websocket)
    assert Keyword.fetch!(opts, :longpoll) == false
  end
end
