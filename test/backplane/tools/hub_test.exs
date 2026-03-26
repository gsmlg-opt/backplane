defmodule Backplane.Tools.HubTest do
  use Backplane.DataCase, async: false

  alias Backplane.Skills.{Registry, Skill}
  alias Backplane.Tools.Hub

  setup do
    content = "# Test skill content"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: "hub/s1",
      name: "Hub Test Skill",
      description: "A skill for hub testing",
      tags: ["test"],
      content: content,
      content_hash: hash,
      source: "db",
      enabled: true
    })
    |> Repo.insert!()

    if :ets.whereis(:backplane_skills) != :undefined do
      Registry.refresh()
    end

    # Ensure native tools are registered in the tool registry
    if :ets.whereis(:backplane_tools) != :undefined do
      alias Backplane.Registry.{Tool, ToolRegistry}

      for module <- [
            Backplane.Tools.Skill,
            Backplane.Tools.Docs,
            Backplane.Tools.Git,
            Backplane.Tools.Hub
          ],
          tool_def <- module.tools() do
        tool = %Tool{
          name: tool_def.name,
          description: tool_def.description,
          input_schema: tool_def.input_schema,
          origin: :native,
          module: tool_def.module,
          handler: tool_def.handler
        }

        ToolRegistry.register_native(tool)
      end
    end

    :ok
  end

  describe "hub::discover" do
    test "returns grouped results matching query" do
      {:ok, results} = Hub.call(%{"_handler" => "discover", "query" => "skill"})
      assert is_map(results)
      assert Map.has_key?(results, :tools)
      assert Map.has_key?(results, :skills)
    end

    test "respects scope filter" do
      {:ok, results} =
        Hub.call(%{"_handler" => "discover", "query" => "skill", "scope" => ["tools"]})

      assert results.skills == []
    end

    test "respects limit" do
      {:ok, results} = Hub.call(%{"_handler" => "discover", "query" => "skill", "limit" => 1})
      assert length(results.tools) <= 1
    end
  end

  describe "hub::inspect" do
    test "returns full schema for native tool" do
      {:ok, result} = Hub.call(%{"_handler" => "inspect", "tool_name" => "skill::search"})
      assert result.name == "skill::search"
      assert is_map(result.input_schema)
      assert result.origin == "native"
    end

    test "returns error for unknown tool" do
      {:error, msg} = Hub.call(%{"_handler" => "inspect", "tool_name" => "nonexistent::tool"})
      assert String.contains?(msg, "Unknown tool")
    end
  end

  describe "hub::status" do
    test "returns upstream connection statuses" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.upstreams)
    end

    test "returns skill source summaries" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.skill_sources)
    end

    test "returns doc project summaries" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.doc_projects)
    end

    test "returns total tool count" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_integer(result.total_tools)
      assert result.total_tools > 0
    end

    test "returns total skill count" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_integer(result.total_skills)
    end

    test "doc_projects includes chunk counts" do
      Repo.insert!(
        %Backplane.Docs.Project{
          id: "hub-status-proj",
          repo: "https://github.com/t/r.git",
          ref: "main"
        },
        on_conflict: :nothing
      )

      Repo.insert!(%Backplane.Docs.DocChunk{
        project_id: "hub-status-proj",
        source_path: "lib/mod.ex",
        content: "content",
        chunk_type: "module_doc",
        content_hash: "hubstatus1"
      })

      {:ok, result} = Hub.call(%{"_handler" => "status"})
      proj = Enum.find(result.doc_projects, &(&1.id == "hub-status-proj"))
      assert proj
      assert proj.chunk_count >= 1
    end

    test "skill_sources groups by source" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert Enum.any?(result.skill_sources, fn s -> s.name == "db" end)
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler" do
      {:error, msg} = Hub.call(%{"_handler" => "unknown"})
      assert msg =~ "Unknown hub tool handler"
    end

    test "returns error for missing handler" do
      {:error, msg} = Hub.call(%{})
      assert msg =~ "Unknown hub tool handler"
    end
  end

  # ---------------------------------------------------------------------------
  # Rescue branch: get_upstream_status
  #
  # Inject a fake upstream child under Pool that returns a map missing the
  # expected :name/:status/:tool_count keys. The Enum.map in
  # get_upstream_status raises a KeyError which is caught by its rescue block.
  # DB operations are still healthy so the rest of hub::status succeeds.
  # ---------------------------------------------------------------------------

  describe "hub::status get_upstream_status rescue branch" do
    defmodule BadUpstream do
      @moduledoc false
      use GenServer
      def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
      def init(_), do: {:ok, []}
      def handle_call(:status, _from, state), do: {:reply, %{unexpected: "bad_shape"}, state}
    end

    test "get_upstream_status returns [] and logs warning when upstream status is malformed" do
      import ExUnit.CaptureLog

      {:ok, bad_pid} = DynamicSupervisor.start_child(Backplane.Proxy.Pool, {BadUpstream, []})

      on_exit(fn ->
        if Process.alive?(bad_pid),
          do: DynamicSupervisor.terminate_child(Backplane.Proxy.Pool, bad_pid)
      end)

      log =
        capture_log(fn ->
          {:ok, result} = Hub.call(%{"_handler" => "status"})
          assert result.upstreams == []
        end)

      assert log =~ "Failed to get upstream status"
    end
  end
end

# ---------------------------------------------------------------------------
# Separate module for DB rescue branches.
#
# These tests kill the DBConnection pool which makes the Ecto sandbox
# unusable afterwards (the sandbox registry points to the old pool PID).
# By using a plain ExUnit.Case (no DataCase sandbox) the other hub tests
# are not affected.
# ---------------------------------------------------------------------------
defmodule Backplane.Tools.HubDbRescueTest do
  use Backplane.DataCase, async: false

  alias Backplane.Tools.Hub

  # Switch the sandbox to :manual mode so that Hub.call, when run in a
  # spawned Task, cannot obtain a DB connection. Repo.all() then raises
  # DBConnection.OwnershipError — an Elixir exception caught by the rescue
  # blocks in get_skill_sources and get_doc_projects. After the test we
  # restore {:shared, self()} so other tests are unaffected.
  defp with_db_unavailable(fun) do
    Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)

    try do
      fun.()
    after
      Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, {:shared, self()})
    end
  end

  test "get_skill_sources rescue returns [] and logs warning when DB is unavailable" do
    with_db_unavailable(fn ->
      {{:ok, result}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Task.async(fn -> Hub.call(%{"_handler" => "status"}) end)
          |> Task.await(5000)
        end)

      assert result.skill_sources == []
      assert log =~ "Failed to get skill sources"
    end)
  end

  test "get_doc_projects rescue returns [] and logs warning when DB is unavailable" do
    with_db_unavailable(fn ->
      {{:ok, result}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Task.async(fn -> Hub.call(%{"_handler" => "status"}) end)
          |> Task.await(5000)
        end)

      assert result.doc_projects == []
      assert log =~ "Failed to get doc projects"
    end)
  end
end
