defmodule Backplane.Skills.HostAgentApiRouterTest do
  use Backplane.DataCase, async: false

  import Backplane.SkillArchiveCase
  import Plug.Conn
  import Plug.Test

  alias Backplane.Skills
  alias Backplane.Skills.Assignments
  alias Backplane.Skills.HostAgentApiRouter
  alias Backplane.Skills.Hosts
  alias BackplaneWeb.Endpoint

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    :ok
  end

  test "rejects missing host token" do
    conn = conn(:get, "/skills/repo-review/download")
    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 401
    assert conn.resp_body == "unauthorized"
  end

  test "rejects invalid host token" do
    conn =
      :get
      |> conn("/skills/repo-review/download")
      |> put_req_header("x-backplane-host-token", "missing-token")

    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 401
    assert conn.resp_body == "unauthorized"
  end

  test "streams an archive for a valid host token through the mounted route", %{tmp_dir: tmp_dir} do
    archive_path = ingest_archive!(tmp_dir, "repo-review", name: "Repo Review")
    assert {:ok, skill} = Skills.get_by_slug("repo-review")
    {:ok, host, token} = Hosts.create_host(%{"name" => "t430"})
    {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})

    conn =
      :get
      |> conn("/api/host-agent/skills/repo-review/download")
      |> put_req_header("accept", "application/x-tar+gzip")
      |> put_req_header("x-backplane-host-token", token)
      |> Endpoint.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/x-tar+gzip"]
    assert conn.resp_body == File.read!(archive_path)
  end

  test "returns 404 when a valid host token is not assigned the requested archive", %{
    tmp_dir: tmp_dir
  } do
    ingest_archive!(tmp_dir, "repo-review", name: "Repo Review")
    assert {:ok, skill} = Skills.get_by_slug("repo-review")
    {:ok, host_a, _token_a} = Hosts.create_host(%{"name" => "t430"})
    {:ok, _host_b, token_b} = Hosts.create_host(%{"name" => "x1"})
    {:ok, _assignment} = Assignments.assign_skill(host_a, skill, %{"targets" => ["agents"]})

    conn =
      :get
      |> conn("/skills/repo-review/download")
      |> put_req_header("x-backplane-host-token", token_b)

    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "returns 404 for a missing skill with a valid host token" do
    {:ok, _host, token} = Hosts.create_host(%{"name" => "t430"})

    conn =
      :get
      |> conn("/skills/missing-skill/download")
      |> put_req_header("x-backplane-host-token", token)

    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  defp ingest_archive!(tmp_dir, slug, attrs) do
    archive_path =
      create_archive!(
        tmp_dir,
        [
          {"#{slug}/SKILL.md", skill_md(attrs)},
          {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})}
        ],
        name: "#{slug}.tar.gz"
      )

    upload = %Plug.Upload{path: archive_path, filename: "#{slug}.tar.gz"}
    assert {:ok, _skill} = Skills.ingest_archive(upload, %{})

    archive_path
  end
end
