defmodule BackplaneWeb.E2E.SkillsHubTest do
  use Backplane.LiveCase

  alias Backplane.Settings
  alias Backplane.SkillArchiveCase
  alias Backplane.Skills.Registry
  alias BackplaneWeb.Router

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = Settings.set("skills.blob.local_root", tmp_dir)

    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    on_exit(fn ->
      if Process.whereis(Settings), do: Settings.set("skills.blob.local_root", nil)
    end)

    :ok
  end

  test "publishes, lists, searches, and pulls a skill archive through public surfaces" do
    archive = archive("e2e-publish", "E2E Publish", ["e2e", "publish"])
    archive_hash = hash(archive)

    publish =
      call_mcp_tool("skill::publish", %{
        "archive_base64" => Base.encode64(archive),
        "filename" => "e2e-publish.tar.gz"
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

    assert pull["url"] == "/api/skills/e2e-publish/archive"
    assert pull["hash"] == archive_hash

    conn = router_conn(:get, pull["url"])

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
    assert conn.resp_body == archive
    assert {:ok, cached} = Registry.fetch("e2e-publish")
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

  defp archive(slug, name, tags) do
    skill_md = """
    ---
    name: #{name}
    description: #{name} description
    tags: #{inspect(tags)}
    ---

    # #{name}
    """

    SkillArchiveCase.tar_gz([
      {"#{slug}/SKILL.md", skill_md},
      {"#{slug}/meta.json", SkillArchiveCase.meta_json(%{"slug" => slug})},
      {"#{slug}/scripts/publish.sh", "echo published\n"}
    ])
  end

  defp hash(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
end
