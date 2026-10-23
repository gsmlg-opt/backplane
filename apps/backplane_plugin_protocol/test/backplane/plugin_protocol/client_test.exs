defmodule Backplane.PluginProtocol.ClientTest do
  use ExUnit.Case, async: true
  alias Backplane.PluginProtocol.{Archive, Client}

  test "injected auth and transport expose catalog and exact release selection" do
    owner = self()

    client =
      Client.new(
        base_url: "https://bp.example/",
        auth: fn -> [{"authorization", "Bearer private"}] end,
        transport: fn request ->
          send(owner, request)
          {:ok, %{status: 200, body: "{\"data\":[]}"}}
        end
      )

    assert {:ok, %{"data" => []}} = Client.catalog(client)

    assert_received %{
      method: :get,
      url: "https://bp.example/plugin-protocol/v1/catalog",
      headers: [{"authorization", "Bearer private"}]
    }

    assert {:ok, _} =
             Client.resolve(client, plugin_id: "one/two", release_id: "fixed", channel: nil)

    assert_received %{url: url}

    assert URI.decode_query(URI.parse(url).query) == %{
             "plugin_id" => "one/two",
             "release_id" => "fixed"
           }
  end

  test "download verifies content identity before unpacking and loading" do
    files = %{
      "plugin.json" =>
        JSON.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example"
        }),
      "assets/file" => "full resource"
    }

    assert {:ok, archive} = Archive.pack(files)
    digest = Archive.digest(archive)
    owner = self()

    client =
      Client.new(
        base_url: "https://bp.example",
        auth: "token",
        transport: fn request ->
          send(owner, request)
          {:ok, %{status: 200, body: archive}}
        end
      )

    assert {:ok,
            %{
              files: ^files,
              artifact: ^archive,
              artifact_digest: ^digest,
              package: %{manifest: %{"name" => "example"}}
            }} = Client.download(client, digest)

    assert_received %{url: url}
    assert String.ends_with?(url, "/artifacts/" <> digest)
    assert {:error, :digest_mismatch} = Client.download(client, String.duplicate("0", 64))
    assert {:error, :invalid_artifact} = Client.download(client, "../escape")
  end

  test "transport, HTTP and malformed responses remain explicit errors" do
    for {response, expected} <- [
          {{:error, :timeout}, {:error, :timeout}},
          {{:ok, %{status: 403, body: "secret"}}, {:error, {:http_status, 403}}},
          {{:ok, %{status: 200, body: "not JSON"}}, {:error, :invalid_response}},
          {{:ok, %{status: 200, body: "[]"}}, {:error, :invalid_response}}
        ] do
      client = Client.new(base_url: "https://bp.example", transport: fn _ -> response end)
      assert Client.catalog(client) == expected
    end
  end

  test "installation report helper sends JSON through the same origin and refuses path escapes" do
    owner = self()

    client =
      Client.new(
        base_url: "https://bp.example",
        transport: fn request ->
          send(owner, request)
          {:ok, %{status: 200, body: %{"ok" => true}}}
        end
      )

    assert {:ok, %{"ok" => true}} =
             Client.request(client, :post, "/installations/id/report", %{status: "installed"})

    assert_received %{
      method: :post,
      url: "https://bp.example/plugin-protocol/v1/installations/id/report",
      body: body,
      headers: [{"content-type", "application/json"}]
    }

    assert JSON.decode!(body) == %{"status" => "installed"}

    for path <- [
          "https://evil.example",
          "//evil.example",
          "/../secrets",
          "/%2e%2e/secrets",
          "/installations?override=1"
        ] do
      assert {:error, :invalid_endpoint} = Client.request(client, :get, path)
    end
  end
end
