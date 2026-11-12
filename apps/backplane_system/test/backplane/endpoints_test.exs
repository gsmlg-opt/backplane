defmodule Backplane.EndpointsTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.{Clients, Endpoints}

  defp create!(attrs \\ %{}) do
    {:ok, e} =
      Endpoints.create(
        Map.merge(%{name: "chatgpt", mcp_enabled: true, mcp_prefixes: ["day", "web"]}, attrs)
      )

    e
  end

  test "create applies defaults" do
    e = create!()
    assert e.enabled == true
    assert e.restrict_clients == false
    assert e.llm_enabled == false
  end

  test "name validation" do
    for name <- ["Chat GPT", "-x", "a_b", String.duplicate("a", 64)] do
      assert {:error, cs} = Endpoints.create(%{name: name})
      assert errors_on(cs)[:name]
    end

    create!()
    assert {:error, cs} = Endpoints.create(%{name: "chatgpt"})
    assert errors_on(cs)[:name]
  end

  test "forbidden prefixes are rejected" do
    assert Endpoints.forbidden_prefixes() == ["admin", "hub", "skill", "system"]

    for p <- Endpoints.forbidden_prefixes() do
      assert {:error, cs} = Endpoints.create(%{name: "x", mcp_prefixes: [p]})
      assert errors_on(cs)[:mcp_prefixes]
    end
  end

  test "update ignores name and enabled" do
    e = create!()
    assert {:ok, u} = Endpoints.update(e, %{name: "other", enabled: false, models: ["openai/gpt-5"]})
    assert u.name == "chatgpt"
    assert u.enabled == true
    assert u.models == ["openai/gpt-5"]
  end

  test "active/2" do
    e = create!()
    assert {:ok, _} = Endpoints.active("chatgpt", :mcp)
    assert :error = Endpoints.active("chatgpt", :llm)
    assert {:ok, _} = Endpoints.set_enabled(e, false)
    assert :error = Endpoints.active("chatgpt", :mcp)
    assert :error = Endpoints.active("nope", :mcp)
  end

  test "cache coherence" do
    e = create!()
    assert Endpoints.get_by_name("chatgpt").id == e.id
    {:ok, _} = Endpoints.update(e, %{description: "new"})
    assert Endpoints.get_by_name("chatgpt").description == "new"
    assert Endpoints.get!(e.id).id == e.id
    {:ok, _} = Endpoints.delete(e)
    assert Endpoints.get_by_name("chatgpt") == nil
    assert Endpoints.list() == []
  end

  test "a load started before an invalidation cannot store a stale value" do
    e = create!()
    Backplane.Endpoints.Cache.clear()

    stale =
      Backplane.Endpoints.Cache.fetch("chatgpt", fn ->
        old = Repo.get_by(Backplane.Endpoints.Endpoint, name: "chatgpt")
        {:ok, _} = Endpoints.update(e, %{description: "fresh"})
        old
      end)

    assert stale.description == nil
    assert Endpoints.get_by_name("chatgpt").description == "fresh"
  end

  test "cache of a miss is cleared by create" do
    assert Endpoints.get_by_name("late") == nil
    create!(%{name: "late"})
    assert %{name: "late"} = Endpoints.get_by_name("late")
  end

  test "invalid names return nil/:error without touching the cache" do
    Backplane.Endpoints.Cache.clear()
    before = :ets.info(:backplane_endpoints, :size)

    for name <- ["Bad Name", "-x", "a_b", "chatgpt\n", String.duplicate("a", 64), ""] do
      assert Endpoints.get_by_name(name) == nil
      assert Endpoints.active(name, :mcp) == :error
    end

    assert :ets.info(:backplane_endpoints, :size) == before
  end

  test "misses are not cached" do
    Backplane.Endpoints.Cache.clear()

    for i <- 1..5, do: assert(Endpoints.get_by_name("unknown-#{i}") == nil)

    assert :ets.tab2list(:backplane_endpoints) == []
  end

  test "prefix validation rejects a trailing newline" do
    assert {:error, cs} = Endpoints.create(%{name: "nl", mcp_prefixes: ["day\n"]})
    assert errors_on(cs)[:mcp_prefixes]
  end

  test "client_allowed?/3" do
    id = Ecto.UUID.generate()
    assert Endpoints.client_allowed?(%{restrict_clients: false}, :oauth, "anything")

    e = %{restrict_clients: true, oauth_client_ids: ["c1"], client_ids: [id]}
    assert Endpoints.client_allowed?(e, :oauth, "c1")
    assert Endpoints.client_allowed?(e, :client_token, id)
    refute Endpoints.client_allowed?(e, :oauth, "c2")
    refute Endpoints.client_allowed?(e, :client_token, "c1")
    refute Endpoints.client_allowed?(e, :oauth, id)
  end

  test "restrict_tool_scopes/2" do
    e = %{mcp_prefixes: ["day", "web"]}
    assert Endpoints.restrict_tool_scopes(e, ["*"]) == ["day::*", "web::*"]
    assert Endpoints.restrict_tool_scopes(e, ["day::*", "fs::*"]) == ["day::*"]
    assert Endpoints.restrict_tool_scopes(e, ["day::now"]) == ["day::now"]
    assert Endpoints.restrict_tool_scopes(e, ["fs::read"]) == []
    assert Endpoints.restrict_tool_scopes(e, []) == []

    scopes = Endpoints.restrict_tool_scopes(e, ["web::*", "web::fetch"])
    tools = for n <- ["web::fetch", "web::search", "day::now", "fs::x"], do: %{name: n}
    assert Enum.map(Clients.filter_tools(tools, scopes), & &1.name) == ["web::fetch", "web::search"]
  end

  test "model_allowed?/2" do
    e = %{models: ["openai/gpt-5", "fast"]}
    assert Endpoints.model_allowed?(e, "fast")
    refute Endpoints.model_allowed?(e, "openai/gpt-5-mini")
  end
end
