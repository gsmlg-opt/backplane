defmodule Backplane.Skills.ApiRouterTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Settings
  alias Backplane.SkillArchiveCase
  alias Backplane.Skills.ApiRouter
  alias Backplane.Skills.Blob.LocalFS

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

  test "GET / lists and searches skills with query, tags, and limit" do
    ingest_archive("elixir-skill", "Elixir Skill", ["elixir", "otp"])
    ingest_archive("react-skill", "React Skill", ["react"])

    conn = call(:get, "/?q=elixir&tags=otp&limit=1")

    assert conn.status == 200
    body = json(conn)
    assert [%{"slug" => "elixir-skill"}] = body["data"]
    refute Map.has_key?(hd(body["data"]), "content")
  end

  test "GET /:slug returns metadata and file list" do
    archive = ingest_archive("api-skill", "API Skill", ["api"])

    conn = call(:get, "/api-skill")

    assert conn.status == 200
    body = json(conn)
    assert body["data"]["slug"] == "api-skill"
    assert body["data"]["files"] == ["SKILL.md", "meta.json", "scripts/run.sh"]
    assert body["data"]["size_bytes"] == byte_size(archive)
  end

  test "GET /:slug/archive returns stored archive unchanged" do
    archive = ingest_archive("download-skill", "Download Skill", ["api"])

    conn = call(:get, "/download-skill/archive")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
    assert conn.resp_body == archive
  end

  test "POST / accepts raw application/x-tar+gzip uploads" do
    archive = archive("raw-skill", "Raw Skill", ["upload"])

    conn =
      conn(:post, "/", archive)
      |> put_req_header("content-type", "application/x-tar+gzip")
      |> call()

    assert conn.status == 201
    assert json(conn)["data"]["slug"] == "raw-skill"
    assert LocalFS.exists?(hash(archive))
  end

  test "POST / accepts multipart archive uploads", %{tmp_dir: tmp_dir} do
    archive = archive("multipart-skill", "Multipart Skill", ["upload"])
    path = Path.join(tmp_dir, "multipart-skill.tar.gz")
    File.write!(path, archive)

    upload = %Plug.Upload{
      path: path,
      filename: "multipart-skill.tar.gz",
      content_type: "application/x-tar+gzip"
    }

    conn = call(conn(:post, "/", %{"archive" => upload}))

    assert conn.status == 201
    assert json(conn)["data"]["slug"] == "multipart-skill"
  end

  test "DELETE /:slug removes a skill and its current archive" do
    archive = ingest_archive("delete-skill", "Delete Skill", ["api"])

    conn = call(:delete, "/delete-skill")

    assert conn.status == 204
    refute LocalFS.exists?(hash(archive))
    assert call(:get, "/delete-skill").status == 404
  end

  test "GET /missing returns 404" do
    assert call(:get, "/missing").status == 404
  end

  test "invalid upload returns 422 and does not commit a blob" do
    body = "not a skill archive"

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/x-tar+gzip")
      |> call()

    assert conn.status == 422
    refute LocalFS.exists?(hash(body))
  end

  defp ingest_archive(slug, name, tags) do
    archive = archive(slug, name, tags)
    {:ok, _skill} = Backplane.Skills.ingest_archive(archive, filename: "#{slug}.tar.gz")
    archive
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
      {"#{slug}/scripts/run.sh", "echo ok\n"}
    ])
  end

  defp call(method, path), do: method |> conn(path) |> call()
  defp call(conn), do: ApiRouter.call(conn, ApiRouter.init([]))
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp hash(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
end
