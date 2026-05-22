defmodule BackplaneWeb.E2E.SkillsHubTest do
  use Backplane.LiveCase

  import Backplane.SkillArchiveCase

  alias Backplane.Skills
  alias BackplaneWeb.Router

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    :ok
  end

  test "publishes, lists, searches, and pulls a skill archive through public surfaces", %{
    tmp_dir: tmp_dir
  } do
    archive = archive!(tmp_dir, "e2e-publish", name: "E2E Publish", tags: ["e2e", "publish"])
    archive_hash = sha256_file(archive)

    publish =
      call_mcp_tool("skill::publish", %{
        "archive_base64" => Base.encode64(File.read!(archive))
      })

    assert publish["slug"] == "e2e-publish"
    assert publish["content_hash"] == archive_hash

    list = call_mcp_tool("skill::list", %{})
    listed = Enum.find(list, &(&1["slug"] == "e2e-publish"))

    assert listed["name"] == "E2E Publish"
    refute Map.has_key?(listed, "content")

    search =
      call_mcp_tool("skill::search", %{
        "query" => "Publish",
        "tags" => ["e2e"],
        "limit" => 5
      })

    assert [%{"slug" => "e2e-publish"}] = search

    pull = call_mcp_tool("skill::download", %{"slug" => "e2e-publish"})

    assert pull["archive_url"] == "/api/skills/e2e-publish/archive"
    assert pull["content_hash"] == archive_hash

    conn = router_conn(:get, pull["archive_url"])

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
    assert conn.resp_body == File.read!(archive)
    assert {:ok, cached} = Skills.get_by_slug("e2e-publish")
    assert cached.content_hash == archive_hash
  end

  defp call_mcp_tool(name, arguments) do
    response =
      router_conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => arguments}
        }),
        [{"content-type", "application/json"}]
      )

    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    refute body["error"]
    refute body["result"]["isError"]

    body
    |> get_in(["result", "content"])
    |> hd()
    |> Map.fetch!("text")
    |> Jason.decode!()
  end

  defp router_conn(method, path, body \\ "", headers \\ []) do
    method
    |> Phoenix.ConnTest.build_conn(path, body)
    |> put_req_headers(headers)
    |> Router.call(Router.init([]))
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  defp archive!(tmp_dir, slug, attrs) do
    name = Keyword.fetch!(attrs, :name)
    tags = Keyword.fetch!(attrs, :tags)

    skill_md = """
    ---
    name: #{name}
    description: #{name} description
    tags: [#{Enum.join(tags, ", ")}]
    ---

    # #{name}
    """

    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_md},
        {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})},
        {"#{slug}/scripts/publish.sh", "echo published\n"}
      ],
      name: "#{slug}.tar.gz"
    )
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
