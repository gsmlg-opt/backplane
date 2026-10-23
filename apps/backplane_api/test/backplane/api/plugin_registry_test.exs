defmodule Backplane.Api.PluginRegistryTest do
  use Backplane.Api.ConnCase, async: false
  alias Backplane.{Clients, Plugins}
  alias Backplane.HostAgent.AgentPlugins
  alias Backplane.PluginProtocol.{Archive, Client}
  @moduletag :tmp_dir

  defp files do
    {:ok, files} =
      Archive.read_directory(
        Path.expand("../../../../backplane_agent_runtime/examples/plugin", __DIR__)
      )

    files
  end

  test "publish, shared client download, installation and old release resolution", %{
    conn: conn,
    tmp_dir: dir
  } do
    {:ok, bytes} = Archive.pack(files())

    candidate =
      conn
      |> post("/plugin-protocol/v1/releases", %{archive_base64: Base.encode64(bytes)})
      |> json_response(201)

    assert candidate["manifest"]["name"] == "backplane-example"

    assert conn
           |> recycle()
           |> get("/plugin-protocol/v1/artifacts/" <> candidate["artifact_digest"])
           |> response(404)

    published =
      conn
      |> recycle()
      |> post("/plugin-protocol/v1/releases/" <> candidate["id"] <> "/publish", %{})
      |> json_response(200)

    assert published["published_at"]
    client = client()
    {:ok, %{"data" => [descriptor]}} = Client.catalog(client)
    assert descriptor["release_id"] == candidate["id"]
    {:ok, download} = Client.download(client, descriptor["artifact_digest"])
    assert download.files == files()
    {:ok, installed} = AgentPlugins.install(client, descriptor["plugin_id"], root: dir)
    assert installed.release_id == candidate["id"]

    assert File.read!(Path.join(installed.root, "skills/plugin-hello/references/marker.txt")) ==
             "BACKPLANE_PLUGIN_V1\n"

    etag = ~s("#{candidate["artifact_digest"]}")

    assert conn
           |> recycle()
           |> put_req_header("if-none-match", etag)
           |> get("/plugin-protocol/v1/artifacts/" <> candidate["artifact_digest"])
           |> response(304)

    next_files =
      Map.put(files(), "skills/plugin-hello/references/marker.txt", "BACKPLANE_PLUGIN_V2\n")

    {:ok, next} = Plugins.import_files(next_files)
    {:ok, _} = Plugins.publish_release(next.id)
    {:ok, latest} = Client.resolve(client, plugin_id: next.plugin_id)
    assert latest["release_id"] == next.id
    {:ok, old} = Client.resolve(client, plugin_id: next.plugin_id, release_id: candidate["id"])
    assert old["artifact_digest"] == candidate["artifact_digest"]
    assert AgentPlugins.status(next.plugin_id, root: dir) == {:ok, installed}
    {:ok, desired} = Plugins.set_desired("local:test", next.plugin_id, next.id, %{enabled: true})
    assert {:ok, [{id, {:ok, report}}]} = AgentPlugins.reconcile(client, root: dir)
    assert id == desired.id
    assert report["actual_release_id"] == next.id
    assert report["actual_enabled"]
    assert report["components"] == %{}
  end

  test "scope enforcement protects management, artifacts and per-client reports", %{conn: conn} do
    {:ok, release} = Plugins.import_files(files())
    {:ok, _} = Plugins.publish_release(release.id)

    {:ok, reader, token} =
      Clients.issue_client(%{name: "plugin-reader", scopes: ["plugin::read"]})

    {:ok, _other_client, other} = Clients.issue_client(%{name: "other", scopes: ["skill::read"]})

    {:ok, installer, install_token} =
      Clients.issue_client(%{name: "installer", scopes: ["plugin::read", "plugin::install"]})

    assert conn |> get("/plugin-protocol/v1/catalog") |> response(401)
    assert auth(conn, token) |> get("/plugin-protocol/v1/catalog") |> response(200)

    assert auth(conn, token)
           |> post("/plugin-protocol/v1/releases/" <> release.id <> "/publish", %{})
           |> response(403)

    assert auth(conn, other)
           |> get("/plugin-protocol/v1/artifacts/" <> release.artifact_digest)
           |> response(403)

    assert auth(conn, token) |> get("/plugin-protocol/v1/sources") |> response(403)

    assert auth(conn, install_token)
           |> post("/plugin-protocol/v1/sources/report/sync", %{})
           |> response(403)

    {:ok, owned} = Plugins.set_desired("client:" <> installer.id, release.plugin_id, release.id)
    {:ok, foreign} = Plugins.set_desired("client:" <> reader.id, release.plugin_id, release.id)

    assert auth(conn, install_token)
           |> get("/plugin-protocol/v1/installations")
           |> json_response(200)
           |> Map.get("data")
           |> Enum.map(& &1["id"]) == [owned.id]

    assert auth(conn, install_token)
           |> post("/plugin-protocol/v1/installations/" <> foreign.id <> "/report", %{
             actual_release_id: release.id,
             status: "installed"
           })
           |> response(403)

    reported =
      auth(conn, install_token)
      |> post(
        "/plugin-protocol/v1/installations/" <> owned.id <> "/report",
        %{actual_release_id: release.id, actual_enabled: true, status: "installed"}
      )
      |> json_response(200)

    assert reported["actual_release_id"] == release.id
    assert reported["actual_enabled"]
  end

  test "malformed requests and modified client downloads fail without publishing", %{conn: conn} do
    assert conn |> get("/plugin-protocol/v1/resolve?plugin_id[]=bad") |> response(400)

    assert conn
           |> recycle()
           |> get("/plugin-protocol/v1/catalog?channel[]=stable")
           |> response(400)

    assert conn
           |> recycle()
           |> post("/plugin-protocol/v1/releases", %{archive_base64: "invalid"})
           |> response(422)

    {:ok, bytes} = Archive.pack(files())

    assert conn
           |> recycle()
           |> post("/plugin-protocol/v1/releases", %{
             archive_base64: Base.encode64(bytes),
             publisher: %{bad: true}
           })
           |> response(422)

    assert conn
           |> recycle()
           |> post("/plugin-protocol/v1/compose", %{manifest: %{}, skills: ["invalid"]})
           |> response(422)

    bad =
      Client.new(
        base_url: "http://registry.test",
        transport: fn _ -> {:ok, %{status: 200, body: "tampered"}} end
      )

    assert {:error, :digest_mismatch} = Client.download(bad, String.duplicate("a", 64))
    assert Plugins.list_plugins() == []
  end

  test "composition API snapshots MCP and resources and exposes candidate history", %{conn: conn} do
    source_files = files()
    manifest = Jason.decode!(source_files["plugin.json"])

    files =
      source_files
      |> Map.delete("plugin.json")
      |> Map.new(fn {path, bytes} -> {path, Base.encode64(bytes)} end)

    release =
      conn
      |> post("/plugin-protocol/v1/compose", %{
        manifest: manifest,
        skills: [],
        files_base64: files
      })
      |> json_response(201)

    history =
      conn
      |> recycle()
      |> get("/plugin-protocol/v1/plugins/" <> release["plugin_id"] <> "/releases")
      |> json_response(200)

    assert [%{"id" => id}] = history["data"]
    assert id == release["id"]

    assert [%{"name" => "backplane-example"}] =
             conn
             |> recycle()
             |> get("/plugin-protocol/v1/plugins")
             |> json_response(200)
             |> Map.get("data")

    assert {:ok, _} = Plugins.publish_release(id)
    {:ok, download} = Client.download(client(), release["artifact_digest"])
    assert download.package.mcp_servers["echo"]
    assert download.files["scripts/server.py"] == source_files["scripts/server.py"]
  end

  defp client do
    Client.new(
      base_url: "http://registry.test",
      transport: fn request ->
        uri = URI.parse(request.url)
        path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
        conn = Plug.Test.conn(request.method, path, request.body || "")

        conn =
          Enum.reduce(request.headers, conn, fn {key, value}, acc ->
            Plug.Conn.put_req_header(acc, key, value)
          end)

        conn = Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
        {:ok, %{status: conn.status, body: conn.resp_body}}
      end
    )
  end

  defp auth(conn, token),
    do: conn |> recycle() |> put_req_header("authorization", "Bearer " <> token)
end
