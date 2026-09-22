defmodule Backplane.Api.SkillProtocolRouterTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Clients
  alias Backplane.Skills

  @blob_setting "skills.blob.local_root"
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = :ets.lookup(:backplane_settings, @blob_setting)
    previous_enabled = Application.get_env(:backplane_skills, :skill_protocol_v1_enabled)
    :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})
    Application.put_env(:backplane_skills, :skill_protocol_v1_enabled, true)

    on_exit(fn ->
      :ets.delete(:backplane_settings, @blob_setting)
      if previous_blob_root != [], do: :ets.insert(:backplane_settings, previous_blob_root)
      restore_enabled(previous_enabled)
    end)

    %{blob_root: Path.join(tmp_dir, "blobs")}
  end

  test "catalog paginates and resolves opaque slash IDs without legacy route changes", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    first = ingest!(tmp_dir, "alpha", "Alpha")
    second = ingest!(tmp_dir, "beta", "Beta")

    page_one = conn |> get("/skill-protocol/v1/catalog?limit=1") |> json_response(200)

    assert %{"protocol_version" => "1", "data" => [descriptor], "next_cursor" => cursor} =
             page_one

    assert descriptor["skill_id"] == first.id
    assert is_binary(cursor)

    page_two =
      conn
      |> recycle()
      |> get("/skill-protocol/v1/catalog?limit=1&cursor=#{URI.encode_www_form(cursor)}")
      |> json_response(200)

    assert [%{"skill_id" => skill_id}] = page_two["data"]
    assert skill_id == second.id
    assert page_two["next_cursor"] == nil

    resolved =
      conn
      |> recycle()
      |> get("/skill-protocol/v1/resolve?skill_id=#{URI.encode_www_form(first.id)}")
      |> json_response(200)

    assert resolved["skill_id"] == "skill/alpha"
    assert resolved["revision"] == first.current_revision

    assert conn |> recycle() |> get("/skills/alpha") |> json_response(200)
    assert conn |> recycle() |> get("/skills/export") |> response(200)
  end

  test "catalog argument hint is opt-in and cursor-bound", %{conn: conn, tmp_dir: tmp_dir} do
    first = ingest!(tmp_dir, "hint-alpha", "Alpha", "PATH")
    _second = ingest!(tmp_dir, "hint-beta", "Beta", nil)

    legacy = conn |> get("/skill-protocol/v1/catalog?q=hint-alpha") |> json_response(200)
    assert [%{"skill_id" => skill_id} = descriptor] = legacy["data"]
    assert skill_id == first.id
    refute Map.has_key?(descriptor, "argument_hint")

    extended =
      conn
      |> recycle()
      |> get("/skill-protocol/v1/catalog?fields=argument_hint&limit=1")
      |> json_response(200)

    assert [%{"argument_hint" => "PATH"}] = extended["data"]
    assert is_binary(extended["next_cursor"])

    assert conn
           |> recycle()
           |> get(
             "/skill-protocol/v1/catalog?cursor=#{URI.encode_www_form(extended["next_cursor"])}"
           )
           |> json_response(400)
           |> get_in(["error", "code"]) == "invalid_request"

    for value <- ["unknown", "argument_hint,unknown"] do
      assert conn
             |> recycle()
             |> get("/skill-protocol/v1/catalog?fields=#{URI.encode_www_form(value)}")
             |> json_response(400)
             |> get_in(["error", "code"]) == "invalid_request"
    end
  end

  test "artifact is exact, conditional reads authorize, and missing revisions do not fall back",
       %{
         conn: conn,
         tmp_dir: tmp_dir
       } do
    skill = ingest!(tmp_dir, "exact", "Exact bytes")
    path = artifact_path(skill)

    artifact = get(conn, path)
    assert response(artifact, 200) == File.read!(archive_path(tmp_dir, "exact"))
    assert [etag] = get_resp_header(artifact, "etag")
    assert get_resp_header(artifact, "content-type") == ["application/x-tar+gzip"]

    unchanged = conn |> recycle() |> put_req_header("if-none-match", etag) |> get(path)
    assert response(unchanged, 304) == ""

    missing =
      conn
      |> recycle()
      |> get(
        "/skill-protocol/v1/resolve?skill_id=#{URI.encode_www_form(skill.id)}&revision=r-#{String.duplicate("0", 64)}"
      )
      |> json_response(410)

    assert missing["error"]["code"] == "revision_unavailable"
  end

  test "disabled and deleted skills deny exact artifact reads", %{conn: conn, tmp_dir: tmp_dir} do
    skill = ingest!(tmp_dir, "withdrawn", "Withdrawn")
    path = artifact_path(skill)

    assert {:ok, disabled} = Skills.update(skill, %{enabled: false})

    assert conn |> get(path) |> json_response(410) |> get_in(["error", "code"]) ==
             "revision_unavailable"

    assert {:ok, _deleted} = Skills.delete(disabled)

    assert conn |> recycle() |> get(path) |> json_response(410) |> get_in(["error", "code"]) ==
             "revision_unavailable"
  end

  test "client tokens require skill read scope before catalog disclosure", %{conn: conn} do
    denied_token = "denied-#{System.unique_integer([:positive])}"

    assert {:ok, _client} =
             Clients.create_client(%{
               name: denied_token,
               token: denied_token,
               scopes: ["llm::models"]
             })

    denied =
      conn
      |> put_req_header("authorization", "Bearer #{denied_token}")
      |> get("/skill-protocol/v1/catalog")

    assert denied |> json_response(403) |> get_in(["error", "code"]) == "forbidden"
  end

  test "invalid and context-mismatched cursors fail explicitly", %{conn: conn, tmp_dir: tmp_dir} do
    _skill = ingest!(tmp_dir, "cursor", "Cursor")
    page = conn |> get("/skill-protocol/v1/catalog?limit=1") |> json_response(200)

    assert conn
           |> recycle()
           |> get("/skill-protocol/v1/catalog?cursor=invalid")
           |> json_response(400)
           |> get_in(["error", "code"]) == "invalid_request"

    if cursor = page["next_cursor"] do
      assert conn
             |> recycle()
             |> get("/skill-protocol/v1/catalog?q=changed&cursor=#{URI.encode_www_form(cursor)}")
             |> json_response(400)
             |> get_in(["error", "code"]) == "invalid_request"
    end
  end

  test "array and empty query parameters return structured invalid requests", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    skill = ingest!(tmp_dir, "malformed-query", "Query")

    for query <- [
          "limit[]=1",
          "cursor[]=x",
          "q[]=x",
          "tag[]=x",
          "skill_id[]=#{skill.id}",
          "revision[]=old",
          "revision[key]=old",
          "revision="
        ] do
      path =
        if String.starts_with?(query, "skill_id") or String.starts_with?(query, "revision"),
          do: "/skill-protocol/v1/resolve?skill_id=#{URI.encode_www_form(skill.id)}&#{query}",
          else: "/skill-protocol/v1/catalog?#{query}"

      response = conn |> recycle() |> get(path) |> json_response(400)
      assert get_in(response, ["error", "code"]) == "invalid_request"
    end
  end

  test "catalog filters committed metadata by query and tag", %{conn: conn, tmp_dir: tmp_dir} do
    alpha = ingest!(tmp_dir, "alpha-filter", "Alpha")
    _beta = ingest!(tmp_dir, "beta-filter", "Beta")

    assert %{"data" => [%{"skill_id" => skill_id}]} =
             conn
             |> get("/skill-protocol/v1/catalog?q=ALPHA-FILTER")
             |> json_response(200)

    assert skill_id == alpha.id

    assert %{"data" => [%{"skill_id" => ^skill_id}]} =
             conn
             |> recycle()
             |> get("/skill-protocol/v1/catalog?tag=alpha-filter")
             |> json_response(200)

    assert %{"data" => []} =
             conn
             |> recycle()
             |> get("/skill-protocol/v1/catalog?tag=absent")
             |> json_response(200)
  end

  test "feature switch conceals the v1 surface", %{conn: conn} do
    Application.put_env(:backplane_skills, :skill_protocol_v1_enabled, false)

    assert response(get(conn, "/skill-protocol/v1/catalog"), 404) == "not found"
  end

  defp ingest!(tmp_dir, slug, resource, argument_hint \\ nil) do
    archive = archive_path(tmp_dir, slug)

    skill_document = """
    ---
    name: #{slug}
    description: #{slug} protocol fixture
    #{if argument_hint, do: "argument-hint: #{argument_hint}", else: ""}
    tags: [protocol, #{slug}]
    ---

    # #{slug}
    """

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [
          {String.to_charlist("#{slug}/SKILL.md"), skill_document},
          {String.to_charlist("#{slug}/resource.txt"), resource},
          {String.to_charlist("#{slug}/meta.json"), JSON.encode!(%{"slug" => slug})}
        ],
        [:compressed]
      )

    assert {:ok, skill} = Skills.ingest_archive(archive, [])
    skill
  end

  defp artifact_path(skill) do
    "/skill-protocol/v1/artifact?skill_id=#{URI.encode_www_form(skill.id)}&revision=#{URI.encode_www_form(skill.current_revision)}"
  end

  defp archive_path(tmp_dir, slug), do: Path.join(tmp_dir, "#{slug}.tar.gz")

  defp restore_enabled(nil),
    do: Application.delete_env(:backplane_skills, :skill_protocol_v1_enabled)

  defp restore_enabled(value),
    do: Application.put_env(:backplane_skills, :skill_protocol_v1_enabled, value)
end
