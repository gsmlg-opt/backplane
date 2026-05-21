defmodule Backplane.Skills.ApiRouterTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase
  import Plug.Conn
  import Plug.Test

  alias Backplane.Skills
  alias Backplane.Skills.ApiRouter

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    {:ok, blob_root: blob_root}
  end

  describe "GET /api/skills" do
    test "lists matching skills by query, tags, and limit", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "alpha-skill", name: "Alpha Skill", tags: ["archive", "alpha"])
      ingest_archive!(tmp_dir, "beta-skill", name: "Beta Skill", tags: ["archive", "beta"])

      conn = api_request(:get, "/?q=skill&tags=archive,alpha&limit=1")

      assert conn.status == 200
      assert %{"data" => [%{"slug" => "alpha-skill"}]} = json_body(conn)
    end
  end

  describe "GET /api/skills/:slug" do
    test "returns skill metadata without full content and includes archive files", %{
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "detail-skill", name: "Detail Skill")

      conn = api_request(:get, "/detail-skill")

      assert conn.status == 200

      assert %{
               "slug" => "detail-skill",
               "name" => "Detail Skill",
               "files" => ["SKILL.md", "meta.json"]
             } = json_body(conn)

      refute Map.has_key?(json_body(conn), "content")
    end

    test "returns 404 for a missing skill" do
      conn = api_request(:get, "/missing")

      assert conn.status == 404
      assert %{"error" => "not found"} = json_body(conn)
    end
  end

  describe "GET /api/skills/:slug/archive" do
    test "streams the stored archive", %{tmp_dir: tmp_dir} do
      archive = ingest_archive!(tmp_dir, "download-skill", name: "Download Skill")

      conn = api_request(:get, "/download-skill/archive")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
      assert conn.resp_body == File.read!(archive)
    end
  end

  describe "POST /api/skills" do
    test "ingests a raw application/x-tar+gzip body", %{tmp_dir: tmp_dir} do
      archive = create_skill_archive!(tmp_dir, "raw-upload", name: "Raw Upload")

      conn =
        api_request(:post, "/", File.read!(archive), [
          {"content-type", "application/x-tar+gzip"}
        ])

      assert conn.status == 201
      assert %{"slug" => "raw-upload", "name" => "Raw Upload"} = json_body(conn)
      assert {:ok, _skill} = Skills.get_by_slug("raw-upload")
    end

    test "ingests a multipart archive upload", %{tmp_dir: tmp_dir} do
      archive = create_skill_archive!(tmp_dir, "multipart-upload", name: "Multipart Upload")

      conn =
        :post
        |> conn("/", "")
        |> put_req_header("content-type", "multipart/form-data")
        |> Map.put(:body_params, %{
          "archive" => %Plug.Upload{
            path: archive,
            filename: "multipart-upload.tar.gz",
            content_type: "application/x-tar+gzip"
          }
        })
        |> ApiRouter.call(ApiRouter.init([]))

      assert conn.status == 201
      assert %{"slug" => "multipart-upload", "name" => "Multipart Upload"} = json_body(conn)
    end

    test "returns 422 for invalid upload without committing a blob", %{blob_root: blob_root} do
      conn =
        api_request(:post, "/", "not a tarball", [
          {"content-type", "application/x-tar+gzip"}
        ])

      assert conn.status == 422
      assert %{"error" => _reason} = json_body(conn)
      refute File.exists?(Path.join(blob_root, "sha256"))
    end
  end

  describe "DELETE /api/skills/:slug" do
    test "deletes the skill", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "delete-skill", name: "Delete Skill")

      conn = api_request(:delete, "/delete-skill")

      assert conn.status == 200
      assert %{"ok" => true} = json_body(conn)
      assert {:error, :not_found} = Skills.get_by_slug("delete-skill")
    end
  end

  defp api_request(method, path, body \\ "", headers \\ []) do
    method
    |> conn(path, body)
    |> put_headers(headers)
    |> ApiRouter.call(ApiRouter.init([]))
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp ingest_archive!(tmp_dir, slug, attrs) do
    archive = create_skill_archive!(tmp_dir, slug, attrs)
    assert {:ok, _skill} = Skills.ingest_archive(archive, [])
    archive
  end

  defp create_skill_archive!(tmp_dir, slug, attrs) do
    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_content(attrs)},
        {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})}
      ],
      name: "#{slug}.tar.gz"
    )
  end

  defp skill_content(attrs) do
    name = Keyword.get(attrs, :name, "example-skill")
    description = Keyword.get(attrs, :description, "Example skill")
    version = Keyword.get(attrs, :version, "1.2.3")
    tags = attrs |> Keyword.get(:tags, ["archive", "test"]) |> Enum.join(", ")

    """
    ---
    name: #{name}
    description: #{description}
    tags: [#{tags}]
    version: "#{version}"
    ---

    # #{name}

    Use this skill in API tests.
    """
  end
end
