defmodule Relayixir.Config.UpstreamConfigTest do
  use ExUnit.Case, async: false

  alias Relayixir.Config.UpstreamConfig

  setup do
    UpstreamConfig.put_upstreams(%{})
    :ok
  end

  describe "get_upstream/1" do
    test "returns nil for non-existent upstream" do
      assert UpstreamConfig.get_upstream("nonexistent") == nil
    end

    test "returns upstream config by name" do
      UpstreamConfig.put_upstreams(%{
        "backend" => %{scheme: :http, host: "localhost", port: 8080}
      })

      assert %{scheme: :http, host: "localhost", port: 8080} =
               UpstreamConfig.get_upstream("backend")
    end
  end

  describe "put_upstreams/1" do
    test "replaces all upstreams" do
      UpstreamConfig.put_upstreams(%{"a" => %{host: "a.com"}})
      UpstreamConfig.put_upstreams(%{"b" => %{host: "b.com"}})

      assert UpstreamConfig.get_upstream("a") == nil
      assert %{host: "b.com"} = UpstreamConfig.get_upstream("b")
    end

    test "can set to empty map" do
      UpstreamConfig.put_upstreams(%{"a" => %{host: "a.com"}})
      UpstreamConfig.put_upstreams(%{})
      assert UpstreamConfig.list_upstreams() == %{}
    end
  end

  describe "list_upstreams/0" do
    test "returns empty map when no upstreams configured" do
      assert UpstreamConfig.list_upstreams() == %{}
    end

    test "returns all configured upstreams" do
      upstreams = %{
        "api" => %{scheme: :http, host: "api.local", port: 3000},
        "web" => %{scheme: :https, host: "web.local", port: 443}
      }

      UpstreamConfig.put_upstreams(upstreams)
      assert UpstreamConfig.list_upstreams() == upstreams
    end
  end
end
