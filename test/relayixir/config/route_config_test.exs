defmodule Relayixir.Config.RouteConfigTest do
  use ExUnit.Case, async: false

  alias Relayixir.Config.RouteConfig

  setup do
    # Reset routes before each test
    RouteConfig.put_routes([])
    :ok
  end

  describe "get_routes/0" do
    test "returns empty list when no routes configured" do
      assert RouteConfig.get_routes() == []
    end

    test "returns all configured routes" do
      routes = [
        %{host_match: "example.com", path_prefix: "/api", upstream_name: "api"},
        %{host_match: "*", path_prefix: "/", upstream_name: "default"}
      ]

      RouteConfig.put_routes(routes)
      assert RouteConfig.get_routes() == routes
    end
  end

  describe "put_routes/1" do
    test "replaces all routes" do
      RouteConfig.put_routes([%{host_match: "*", path_prefix: "/", upstream_name: "a"}])
      RouteConfig.put_routes([%{host_match: "*", path_prefix: "/new", upstream_name: "b"}])

      routes = RouteConfig.get_routes()
      assert length(routes) == 1
      assert hd(routes).upstream_name == "b"
    end

    test "can set routes to empty list" do
      RouteConfig.put_routes([%{host_match: "*", path_prefix: "/", upstream_name: "a"}])
      RouteConfig.put_routes([])
      assert RouteConfig.get_routes() == []
    end
  end

  describe "find_route/2" do
    test "returns nil when no routes configured" do
      assert RouteConfig.find_route("example.com", "/api") == nil
    end

    test "matches wildcard host" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/", upstream_name: "default"}
      ])

      assert %{upstream_name: "default"} = RouteConfig.find_route("anything.com", "/path")
    end

    test "matches exact host" do
      RouteConfig.put_routes([
        %{host_match: "example.com", path_prefix: "/", upstream_name: "example"}
      ])

      assert %{upstream_name: "example"} = RouteConfig.find_route("example.com", "/path")
      assert RouteConfig.find_route("other.com", "/path") == nil
    end

    test "matches path prefix" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/api", upstream_name: "api"},
        %{host_match: "*", path_prefix: "/", upstream_name: "default"}
      ])

      assert %{upstream_name: "api"} = RouteConfig.find_route("example.com", "/api/users")
      assert %{upstream_name: "api"} = RouteConfig.find_route("example.com", "/api")
      assert %{upstream_name: "default"} = RouteConfig.find_route("example.com", "/other")
    end

    test "returns first matching route when multiple match" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/api", upstream_name: "first"},
        %{host_match: "*", path_prefix: "/api", upstream_name: "second"}
      ])

      assert %{upstream_name: "first"} = RouteConfig.find_route("example.com", "/api/test")
    end

    test "matches route without host_match field (defaults to match-all)" do
      RouteConfig.put_routes([
        %{path_prefix: "/", upstream_name: "default"}
      ])

      assert %{upstream_name: "default"} = RouteConfig.find_route("anything.com", "/path")
    end

    test "matches route without path_prefix field (defaults to match-all)" do
      RouteConfig.put_routes([
        %{host_match: "*", upstream_name: "default"}
      ])

      assert %{upstream_name: "default"} = RouteConfig.find_route("example.com", "/any/path")
    end

    test "host matching is case-sensitive" do
      RouteConfig.put_routes([
        %{host_match: "Example.com", path_prefix: "/", upstream_name: "example"}
      ])

      assert RouteConfig.find_route("example.com", "/") == nil
      assert %{upstream_name: "example"} = RouteConfig.find_route("Example.com", "/")
    end

    test "path prefix matching requires exact prefix" do
      RouteConfig.put_routes([
        %{host_match: "*", path_prefix: "/api", upstream_name: "api"}
      ])

      # /api-v2 starts with /api, so it matches
      assert %{upstream_name: "api"} = RouteConfig.find_route("example.com", "/api-v2")
      # /ap does not start with /api
      assert RouteConfig.find_route("example.com", "/ap") == nil
    end
  end
end
