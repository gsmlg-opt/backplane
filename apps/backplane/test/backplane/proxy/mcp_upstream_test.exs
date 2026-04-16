defmodule Backplane.Proxy.McpUpstreamTest do
  use ExUnit.Case, async: true

  alias Backplane.Proxy.McpUpstream

  defp changeset(attrs) do
    McpUpstream.changeset(%McpUpstream{}, attrs)
  end

  defp valid_sse_attrs do
    %{name: "test-sse", prefix: "sse", transport: "sse", url: "http://localhost:8080/sse"}
  end

  describe "transport=sse" do
    test "accepts valid sse config with url" do
      cs = changeset(valid_sse_attrs())
      assert cs.valid?
    end

    test "rejects sse config without url" do
      cs = changeset(%{valid_sse_attrs() | url: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:url]
    end

    test "defaults headers to empty map" do
      cs = changeset(valid_sse_attrs())
      assert Ecto.Changeset.get_field(cs, :headers) == %{}
    end

    test "defaults auth_scheme to none" do
      cs = changeset(valid_sse_attrs())
      assert Ecto.Changeset.get_field(cs, :auth_scheme) == "none"
    end
  end

  describe "headers deny-list" do
    for header <- ["Authorization", "Proxy-Authorization", "Cookie", "X-API-Key", "X-Auth-Token", "Api-Key"] do
      test "rejects #{header} in headers (case-insensitive)" do
        cs = changeset(Map.put(valid_sse_attrs(), :headers, %{unquote(header) => "val"}))
        refute cs.valid?
        assert {"contains prohibited auth header: " <> _, _} = cs.errors[:headers]
      end
    end

    test "rejects lowercase variant of denied header" do
      cs = changeset(Map.put(valid_sse_attrs(), :headers, %{"authorization" => "Bearer x"}))
      refute cs.valid?
    end

    test "accepts non-auth headers" do
      cs = changeset(Map.put(valid_sse_attrs(), :headers, %{"User-Agent" => "backplane", "X-Custom" => "v"}))
      assert cs.valid?
    end
  end

  describe "URL userinfo rejection" do
    test "rejects url with userinfo" do
      cs = changeset(%{valid_sse_attrs() | url: "https://user:pass@host.com/mcp"})
      refute cs.valid?
      assert {"must not contain embedded credentials", _} = cs.errors[:url]
    end

    test "accepts url without userinfo" do
      cs = changeset(%{valid_sse_attrs() | url: "https://host.com/mcp"})
      assert cs.valid?
    end
  end

  describe "auth_scheme and credential coupling" do
    test "requires credential when auth_scheme != none" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{auth_scheme: "bearer"}))
      refute cs.valid?
      assert {"is required when auth_scheme is set", _} = cs.errors[:credential]
    end

    test "accepts auth_scheme=none without credential" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{auth_scheme: "none"}))
      assert cs.valid?
    end

    test "accepts auth_scheme=bearer with credential" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{auth_scheme: "bearer", credential: "my-cred"}))
      assert cs.valid?
    end

    test "requires auth_header_name when auth_scheme=custom_header" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{auth_scheme: "custom_header", credential: "c"}))
      refute cs.valid?
      assert {"is required when auth_scheme is custom_header", _} = cs.errors[:auth_header_name]
    end

    test "rejects deny-listed auth_header_name" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{
        auth_scheme: "custom_header", credential: "c", auth_header_name: "Authorization"
      }))
      refute cs.valid?
    end

    test "accepts valid custom auth_header_name" do
      cs = changeset(Map.merge(valid_sse_attrs(), %{
        auth_scheme: "custom_header", credential: "c", auth_header_name: "X-Service-Key"
      }))
      assert cs.valid?
    end
  end
end
