defmodule Backplane.Skills.ApiRouterTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase
  import Plug.Conn
  import Plug.Test

  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.Blob
  alias Backplane.Skills.Skill
  alias Backplane.Api.Endpoint

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

  describe "GET /skills" do
    test "lists matching skills by query, tags, and limit", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "alpha-skill", name: "Alpha Skill", tags: ["archive", "alpha"])
      ingest_archive!(tmp_dir, "beta-skill", name: "Beta Skill", tags: ["archive", "beta"])

      conn = api_request(:get, "/skills?q=skill&tags=archive,alpha&limit=1")

      assert conn.status == 200
      assert %{"data" => [%{"slug" => "alpha-skill"}]} = json_body(conn)
    end
  end

  describe "GET /skills/:slug" do
    test "returns skill metadata without full content and includes archive files", %{
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "detail-skill", name: "Detail Skill")

      conn = api_request(:get, "/skills/detail-skill")

      assert conn.status == 200

      assert %{
               "slug" => "detail-skill",
               "name" => "Detail Skill",
               "files" => ["SKILL.md", "meta.json"]
             } = json_body(conn)

      refute Map.has_key?(json_body(conn), "content")
    end

    test "returns 404 for a missing skill" do
      conn = api_request(:get, "/skills/missing")

      assert conn.status == 404
      assert %{"error" => "not found"} = json_body(conn)
    end

    test "returns an error when archive-backed file listing cannot read the blob", %{
      blob_root: blob_root,
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "missing-blob-detail", name: "Missing Blob Detail")
      assert {:ok, skill} = Skills.get_by_slug("missing-blob-detail")
      assert :ok = Blob.delete(skill.archive_ref, root: blob_root)

      conn = api_request(:get, "/skills/missing-blob-detail")

      assert conn.status == 500
      assert %{"error" => _reason} = json_body(conn)
    end
  end

  describe "GET /skills/:slug/archive" do
    test "streams the stored archive", %{tmp_dir: tmp_dir} do
      archive = ingest_archive!(tmp_dir, "download-skill", name: "Download Skill")

      conn = api_request(:get, "/skills/download-skill/archive")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
      assert conn.resp_body == File.read!(archive)
    end

    test "accepts archive media type negotiation", %{tmp_dir: tmp_dir} do
      archive = ingest_archive!(tmp_dir, "accept-archive-skill", name: "Accept Archive Skill")

      conn =
        api_request(:get, "/skills/accept-archive-skill/archive", "", [
          {"accept", "application/x-tar+gzip"}
        ])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
      assert conn.resp_body == File.read!(archive)
    end
  end

  describe "GET /skills/export" do
    test "streams a collection archive before treating export as a slug", %{tmp_dir: tmp_dir} do
      archive = ingest_archive!(tmp_dir, "export", name: "Export Skill")

      conn = api_request(:get, "/skills/export")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]

      assert {:ok, entries} = extract_collection(conn.resp_body)

      assert %{
               "manifest.json" => manifest_json,
               "archives/export.tar.gz" => archive_bytes
             } = entries

      assert %{"count" => 1} = Jason.decode!(manifest_json)
      assert archive_bytes == File.read!(archive)
    end
  end

  describe "POST /skills" do
    test "ingests a raw application/x-tar+gzip body with casing and parameters", %{
      tmp_dir: tmp_dir
    } do
      archive =
        create_skill_archive!(tmp_dir, "raw-upload",
          name: "Raw Upload",
          entries: [{"raw-upload/payload.bin", :crypto.strong_rand_bytes(130_000)}]
        )

      assert File.stat!(archive).size > 64_000

      conn =
        api_request(:post, "/skills", File.read!(archive), [
          {"content-type", "APPLICATION/X-TAR+GZIP; charset=binary"}
        ])

      assert conn.status == 201
      assert %{"slug" => "raw-upload", "name" => "Raw Upload"} = json_body(conn)
      assert {:ok, _skill} = Skills.get_by_slug("raw-upload")
    end

    test "ingests a multipart archive upload", %{tmp_dir: tmp_dir} do
      archive = create_skill_archive!(tmp_dir, "multipart-upload", name: "Multipart Upload")
      original_archive_path = archive
      {body, boundary} = multipart_archive_body(archive, "multipart-upload.tar.gz")

      conn =
        api_request(:post, "/skills", body, [
          {"content-type", "multipart/form-data; boundary=#{boundary}"}
        ])

      assert conn.status == 201

      assert %Plug.Upload{
               filename: "multipart-upload.tar.gz",
               path: parsed_upload_path
             } = conn.body_params["archive"]

      refute parsed_upload_path == original_archive_path
      assert File.exists?(parsed_upload_path)

      assert %{"slug" => "multipart-upload", "name" => "Multipart Upload"} = json_body(conn)
    end

    test "returns 422 for invalid upload without committing a blob", %{blob_root: blob_root} do
      conn =
        api_request(:post, "/skills", "not a tarball", [
          {"content-type", "application/x-tar+gzip"}
        ])

      assert conn.status == 422
      assert %{"error" => _reason} = json_body(conn)
      refute File.exists?(Path.join(blob_root, "sha256"))
    end
  end

  describe "POST /skills/import" do
    test "ingests a raw collection archive before the generic upload route", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "import-a", name: "Import A")
      ingest_archive!(tmp_dir, "import-b", name: "Import B")
      collection = Path.join(tmp_dir, "collection.tar.gz")

      assert {:ok, %{count: 2}} = Skills.export(path: collection)

      assert {:ok, skill} = Skills.get_by_slug("import-a")
      assert {:ok, _deleted} = Skills.delete(skill)
      assert {:ok, skill} = Skills.get_by_slug("import-b")
      assert {:ok, _deleted} = Skills.delete(skill)

      conn =
        api_request(:post, "/skills/import", File.read!(collection), [
          {"content-type", "APPLICATION/X-TAR+GZIP; charset=binary"}
        ])

      assert conn.status == 201

      assert %{"count" => 2, "data" => [%{"slug" => "import-a"}, %{"slug" => "import-b"}]} =
               json_body(conn)

      assert {:ok, _skill} = Skills.get_by_slug("import-a")
      assert {:ok, _skill} = Skills.get_by_slug("import-b")
    end

    test "returns 422 for unsafe collection entries", %{tmp_dir: tmp_dir} do
      collection =
        create_archive!(
          tmp_dir,
          [
            {"manifest.json", Jason.encode!(%{"count" => 0, "skills" => []})},
            {"archives/%2e%2e.tar.gz", "unsafe"}
          ],
          name: "unsafe-collection.tar.gz"
        )

      conn =
        api_request(:post, "/skills/import", File.read!(collection), [
          {"content-type", "application/x-tar+gzip"}
        ])

      assert conn.status == 422
      assert %{"error" => _reason} = json_body(conn)
    end
  end

  describe "PUT /skills/:slug" do
    test "updates existing skill attributes and refreshes registry", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "put-skill", name: "Put Skill", description: "Original description", tags: ["original"])

      conn =
        api_request(
          :put,
          "/skills/put-skill",
          Jason.encode!(%{
            "description" => "Updated description",
            "tags" => ["updated", "new"],
            "category" => "testing",
            "enabled" => false
          }),
          [{"content-type", "application/json"}]
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["slug"] == "put-skill"
      assert body["description"] == "Updated description"
      assert body["tags"] == ["updated", "new"]
      assert body["category"] == "testing"

      # Verify database and registry cache are updated
      assert {:ok, skill} = Skills.get_by_slug("put-skill")
      assert skill.description == "Updated description"
      assert skill.tags == ["updated", "new"]
      assert skill.category == "testing"
      assert skill.enabled == false

      # Verify it's no longer listed in active registry list due to enabled == false
      refute Enum.any?(Skills.Registry.list(), &(&1.slug == "put-skill"))
    end

    test "returns 404 when updating non-existent skill" do
      conn =
        api_request(
          :put,
          "/skills/missing-put",
          Jason.encode!(%{"description" => "Updated description"}),
          [{"content-type", "application/json"}]
        )

      assert conn.status == 404
      assert %{"error" => "not found"} = json_body(conn)
    end

    test "returns 422 for invalid parameter types", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "invalid-put-skill", name: "Invalid Put Skill")

      conn =
        api_request(
          :put,
          "/skills/invalid-put-skill",
          Jason.encode!(%{
            "enabled" => "not-a-boolean"
          }),
          [{"content-type", "application/json"}]
        )

      assert conn.status == 422
      assert %{"errors" => %{"enabled" => ["is invalid"]}} = json_body(conn)
    end
  end

  describe "DELETE /skills/:slug" do
    test "deletes the skill and unreferenced archive blob", %{
      blob_root: blob_root,
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "delete-skill", name: "Delete Skill")
      assert {:ok, skill} = Skills.get_by_slug("delete-skill")
      assert Blob.exists?(skill.archive_ref, root: blob_root)

      conn = api_request(:delete, "/skills/delete-skill")

      assert conn.status == 200
      assert %{"ok" => true} = json_body(conn)
      assert {:error, :not_found} = Skills.get_by_slug("delete-skill")
      refute Blob.exists?(skill.archive_ref, root: blob_root)
    end

    test "keeps a shared archive blob when another committed skill references it", %{
      blob_root: blob_root,
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "shared-delete-a", name: "Shared Delete A")
      assert {:ok, original} = Skills.get_by_slug("shared-delete-a")

      %Skill{}
      |> Skill.changeset(%{
        id: "skill/shared-delete-b",
        slug: "shared-delete-b",
        name: "Shared Delete B",
        content: "# Shared Delete B",
        content_hash: original.content_hash,
        archive_ref: original.archive_ref,
        source_kind: "archive"
      })
      |> Repo.insert!()

      conn = api_request(:delete, "/skills/shared-delete-a")

      assert conn.status == 200
      assert %{"ok" => true} = json_body(conn)
      assert {:error, :not_found} = Skills.get_by_slug("shared-delete-a")
      assert {:ok, _remaining} = Skills.get_by_slug("shared-delete-b")
      assert Blob.exists?(original.archive_ref, root: blob_root)
    end
  end

  defp api_request(method, path, body \\ "", headers \\ []) do
    method
    |> conn(path, body)
    |> put_headers(headers)
    |> Endpoint.call([])
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
      ] ++ Keyword.get(attrs, :entries, []),
      name: "#{slug}.tar.gz"
    )
  end

  defp multipart_archive_body(archive_path, filename) do
    boundary = "backplane-test-#{System.unique_integer([:positive])}"

    body =
      IO.iodata_to_binary([
        "--",
        boundary,
        "\r\n",
        "Content-Disposition: form-data; name=\"archive\"; filename=\"",
        filename,
        "\"\r\n",
        "Content-Type: application/x-tar+gzip\r\n\r\n",
        File.read!(archive_path),
        "\r\n--",
        boundary,
        "--\r\n"
      ])

    {body, boundary}
  end

  defp extract_collection(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "backplane-api-collection-#{System.unique_integer([:positive])}.tar.gz"
      )

    File.write!(path, bytes)

    try do
      case :erl_tar.extract(String.to_charlist(path), [:compressed, :memory]) do
        {:ok, entries} ->
          entries =
            Map.new(entries, fn {name, content} ->
              {IO.chardata_to_string(name), IO.iodata_to_binary(content)}
            end)

          {:ok, entries}

        {:error, _} = error ->
          error
      end
    after
      File.rm(path)
    end
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
