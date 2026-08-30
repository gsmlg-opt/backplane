defmodule Backplane.Proxy.McpUpstreamTest do
  use ExUnit.Case, async: true

  alias Backplane.Proxy.{McpUpstream, Upstreams}

  defp changeset(attrs) do
    McpUpstream.changeset(%McpUpstream{}, attrs)
  end

  defp valid_http_attrs do
    %{name: "test-http", prefix: "http", transport: "http", url: "http://localhost:8080/mcp"}
  end

  describe "prefix validation" do
    test "normalizes leading and trailing path separators" do
      cs = changeset(%{valid_http_attrs() | prefix: " /github/ "})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :prefix) == "github"
    end

    test "rejects the reserved skill prefix" do
      for prefix <- ["skill", " /skill/ "] do
        cs = changeset(%{valid_http_attrs() | prefix: prefix})

        refute cs.valid?
        assert {message, _opts} = cs.errors[:prefix]
        assert message =~ "reserved"
      end
    end

    test "accepts a non-reserved prefix" do
      cs = changeset(%{valid_http_attrs() | prefix: "github"})

      assert cs.valid?
    end
  end

  describe "transport validation" do
    test "accepts valid http config with url" do
      cs = changeset(valid_http_attrs())
      assert cs.valid?
    end

    test "rejects http config without url" do
      cs = changeset(%{valid_http_attrs() | url: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:url]
    end

    test "rejects sse transport" do
      cs = changeset(%{valid_http_attrs() | transport: "sse", url: "http://localhost:8080/sse"})
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:transport]
    end

    test "defaults headers to empty map" do
      cs = changeset(valid_http_attrs())
      assert Ecto.Changeset.get_field(cs, :headers) == %{}
    end

    test "defaults auth_scheme to none" do
      cs = changeset(valid_http_attrs())
      assert Ecto.Changeset.get_field(cs, :auth_scheme) == "none"
    end
  end

  describe "protocol preference" do
    test "defaults to the legacy protocol version" do
      assert Map.has_key?(%McpUpstream{}, :protocol_version)

      assert Ecto.Changeset.get_field(changeset(valid_http_attrs()), :protocol_version) ==
               "2025-11-25"
    end

    test "accepts only supported protocol preferences" do
      assert Map.has_key?(%McpUpstream{}, :protocol_version)

      for preference <- ["2025-11-25", "2026-07-28", "auto"] do
        assert changeset(Map.put(valid_http_attrs(), :protocol_version, preference)).valid?
      end

      for preference <- [nil, "", "latest"] do
        refute changeset(Map.put(valid_http_attrs(), :protocol_version, preference)).valid?
      end
    end

    test "runtime config preserves all runtime fields and the selected preference" do
      assert Code.ensure_loaded?(Upstreams)

      upstream =
        struct!(McpUpstream,
          name: "runtime-http",
          prefix: "runtime",
          transport: "http",
          protocol_version: "2026-07-28",
          url: "https://example.test/mcp",
          command: nil,
          args: ["--flag"],
          timeout_ms: 12_345,
          refresh_interval_ms: 67_890,
          headers: %{"X-Trace" => "enabled"},
          credential: "runtime-credential",
          auth_scheme: "custom_header",
          auth_header_name: "X-Service-Key"
        )

      assert Upstreams.runtime_config(upstream) == %{
               name: "runtime-http",
               prefix: "runtime",
               transport: "http",
               protocol_version: "2026-07-28",
               url: "https://example.test/mcp",
               command: nil,
               args: ["--flag"],
               timeout: 12_345,
               refresh_interval: 67_890,
               headers: %{"X-Trace" => "enabled"},
               credential: "runtime-credential",
               auth_scheme: "custom_header",
               auth_header_name: "X-Service-Key"
             }
    end

    test "runtime config falls back to legacy defaults for nullable historical values" do
      assert Code.ensure_loaded?(Upstreams)

      upstream =
        struct!(McpUpstream,
          name: "historical-http",
          prefix: "historical",
          transport: "http",
          protocol_version: nil,
          url: "https://example.test/mcp",
          args: nil,
          headers: nil,
          auth_scheme: nil
        )

      assert %{
               protocol_version: "2025-11-25",
               args: [],
               headers: %{},
               auth_scheme: "none"
             } = Upstreams.runtime_config(upstream)
    end
  end

  describe "headers deny-list" do
    for header <- [
          "Authorization",
          "Proxy-Authorization",
          "Cookie",
          "X-API-Key",
          "X-Auth-Token",
          "Api-Key"
        ] do
      test "rejects #{header} in headers (case-insensitive)" do
        cs = changeset(Map.put(valid_http_attrs(), :headers, %{unquote(header) => "val"}))
        refute cs.valid?
        assert {"contains prohibited auth header: " <> _, _} = cs.errors[:headers]
      end
    end

    test "rejects lowercase variant of denied header" do
      cs = changeset(Map.put(valid_http_attrs(), :headers, %{"authorization" => "Bearer x"}))
      refute cs.valid?
    end

    test "accepts non-auth headers" do
      cs =
        changeset(
          Map.put(valid_http_attrs(), :headers, %{"User-Agent" => "backplane", "X-Custom" => "v"})
        )

      assert cs.valid?
    end
  end

  describe "URL userinfo rejection" do
    test "rejects url with userinfo" do
      cs = changeset(%{valid_http_attrs() | url: "https://user:pass@host.com/mcp"})
      refute cs.valid?
      assert {"must not contain embedded credentials", _} = cs.errors[:url]
    end

    test "accepts url without userinfo" do
      cs = changeset(%{valid_http_attrs() | url: "https://host.com/mcp"})
      assert cs.valid?
    end
  end

  describe "auth_scheme and credential coupling" do
    test "requires credential when auth_scheme != none" do
      cs = changeset(Map.merge(valid_http_attrs(), %{auth_scheme: "bearer"}))
      refute cs.valid?
      assert {"is required when auth_scheme is set", _} = cs.errors[:credential]
    end

    test "accepts auth_scheme=none without credential" do
      cs = changeset(Map.merge(valid_http_attrs(), %{auth_scheme: "none"}))
      assert cs.valid?
    end

    test "accepts auth_scheme=bearer with credential" do
      cs =
        changeset(Map.merge(valid_http_attrs(), %{auth_scheme: "bearer", credential: "my-cred"}))

      assert cs.valid?
    end

    test "requires auth_header_name when auth_scheme=custom_header" do
      cs =
        changeset(Map.merge(valid_http_attrs(), %{auth_scheme: "custom_header", credential: "c"}))

      refute cs.valid?
      assert {"is required when auth_scheme is custom_header", _} = cs.errors[:auth_header_name]
    end

    test "rejects deny-listed auth_header_name" do
      cs =
        changeset(
          Map.merge(valid_http_attrs(), %{
            auth_scheme: "custom_header",
            credential: "c",
            auth_header_name: "Authorization"
          })
        )

      refute cs.valid?
    end

    test "accepts valid custom auth_header_name" do
      cs =
        changeset(
          Map.merge(valid_http_attrs(), %{
            auth_scheme: "custom_header",
            credential: "c",
            auth_header_name: "X-Service-Key"
          })
        )

      assert cs.valid?
    end
  end
end
