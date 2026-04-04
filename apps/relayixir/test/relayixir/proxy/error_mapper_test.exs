defmodule Relayixir.Proxy.ErrorMapperTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.ErrorMapper

  describe "to_response/1" do
    test "route_not_found returns 404" do
      assert ErrorMapper.to_response(:route_not_found) == {404, "Not Found"}
    end

    test "upstream_connect_failed returns 502" do
      assert ErrorMapper.to_response(:upstream_connect_failed) == {502, "Bad Gateway"}
    end

    test "upstream_timeout returns 504" do
      assert ErrorMapper.to_response(:upstream_timeout) == {504, "Gateway Timeout"}
    end

    test "upstream_invalid_response returns 502" do
      assert ErrorMapper.to_response(:upstream_invalid_response) == {502, "Bad Gateway"}
    end

    test "response_too_large returns 502" do
      assert ErrorMapper.to_response(:response_too_large) == {502, "Bad Gateway"}
    end

    test "request_too_large returns 413" do
      assert ErrorMapper.to_response(:request_too_large) == {413, "Payload Too Large"}
    end

    test "method_not_allowed returns 405" do
      assert ErrorMapper.to_response(:method_not_allowed) == {405, "Method Not Allowed"}
    end

    test "internal_error returns 500" do
      assert ErrorMapper.to_response(:internal_error) == {500, "Internal Server Error"}
    end

    test "unknown error returns 500" do
      assert ErrorMapper.to_response(:some_random_error) == {500, "Internal Server Error"}
    end
  end

  describe "send_error/2" do
    test "sends proper 404 response" do
      conn = Plug.Test.conn(:get, "/missing")
      result = ErrorMapper.send_error(conn, :route_not_found)

      assert result.status == 404
      assert result.resp_body == "Not Found"
      assert result.state == :sent

      content_type =
        Enum.find_value(result.resp_headers, fn
          {"content-type", v} -> v
          _ -> nil
        end)

      assert content_type =~ "text/plain"
    end

    test "sends proper 502 response" do
      conn = Plug.Test.conn(:get, "/test")
      result = ErrorMapper.send_error(conn, :upstream_connect_failed)

      assert result.status == 502
      assert result.resp_body == "Bad Gateway"
    end

    test "sends proper 504 response" do
      conn = Plug.Test.conn(:get, "/test")
      result = ErrorMapper.send_error(conn, :upstream_timeout)

      assert result.status == 504
      assert result.resp_body == "Gateway Timeout"
    end

    test "sends proper 500 response for unknown error" do
      conn = Plug.Test.conn(:get, "/test")
      result = ErrorMapper.send_error(conn, :something_else)

      assert result.status == 500
      assert result.resp_body == "Internal Server Error"
    end
  end
end
