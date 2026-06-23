defmodule Backplane.Skills.HostAgentApiRouterTest do
  use BackplaneSkills.DataCase, async: false

  import Plug.Test

  alias Backplane.Skills.HostAgentApiRouter
  alias Backplane.Api.Endpoint

  test "retired whoami route returns not found" do
    conn = conn(:get, "/whoami")
    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "retired HTTP skill download route returns not found without auth" do
    conn = conn(:get, "/skills/repo-review/download")
    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "mounted retired host-agent API route returns not found" do
    conn =
      :get
      |> conn("/api/host-agent/skills/repo-review/download")
      |> Endpoint.call([])

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end
end
