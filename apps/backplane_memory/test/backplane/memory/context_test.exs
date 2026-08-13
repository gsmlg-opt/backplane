defmodule Backplane.Memory.ContextTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Context, Lessons}

  @settings_table :backplane_settings
  @key "memory.inject_context"
  @partition [
    host_id: "context-host",
    client_id: "context-client",
    scope: "context-project",
    namespace: "private"
  ]

  setup do
    original =
      case :ets.lookup(@settings_table, @key) do
        [{_, v}] -> v
        [] -> :missing
      end

    on_exit(fn ->
      case original do
        :missing -> :ets.delete(@settings_table, @key)
        v -> :ets.insert(@settings_table, {@key, v})
      end
    end)

    :ok
  end

  describe "build/2" do
    test "returns nil when inject_context setting is not 'true'" do
      stub_setting("false")
      assert Context.build("my-project") == nil
    end

    test "returns nil when inject_context setting is nil" do
      stub_setting(nil)
      assert Context.build("my-project") == nil
    end

    test "returns nil when inject_context is 'true' but there is no profile or memories" do
      stub_setting("true")
      # No profile, no memories for this project → all parts empty → nil
      result =
        Context.build("unknown-project-#{:rand.uniform(99_999)}", "sess-none", @partition)

      assert result == nil
    end

    test "fails closed when inject_context is enabled without a trusted partition" do
      stub_setting("true")
      assert Context.build("my-project", "session") == nil
    end

    test "returns a non-empty string when inject_context is 'true' and a profile exists" do
      stub_setting("true")

      project = "ctx-proj-#{:rand.uniform(99_999)}"

      repo().insert!(%Backplane.Memory.Profiles.Profile{
        project: project,
        host_id: @partition[:host_id],
        client_id: @partition[:client_id],
        scope: @partition[:scope],
        namespace: @partition[:namespace],
        top_concepts: %{"elixir" => 3},
        top_files: %{"lib/foo.ex" => 2},
        patterns: %{},
        session_count: 1,
        total_observations: 5
      })

      result = Context.build(project, "some-session", @partition)
      assert is_binary(result)
      assert String.length(result) > 0
      assert String.contains?(result, project)
    end

    test "labels injected profiles with revision time and stale state" do
      stub_setting("true")
      project = "ctx-stale-#{System.unique_integer([:positive])}"

      repo().insert!(%Backplane.Memory.Profiles.Profile{
        project: project,
        host_id: @partition[:host_id],
        client_id: @partition[:client_id],
        scope: @partition[:scope],
        namespace: @partition[:namespace],
        updated_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      })

      result = Context.build(project, "some-session", @partition)
      assert result =~ "Profile revision:"
      assert result =~ "Profile state: stale"
    end

    test "session start injects typed exact-partition lessons with compact provenance" do
      stub_setting("true")
      project = "ctx-lessons-#{System.unique_integer([:positive])}"

      {:ok, lesson} =
        Lessons.save(
          %{
            rule: "Verify the manifest-selected asset",
            context: "browser release checks",
            project: project,
            session_id: "source-session",
            idempotency_key: "ctx-own"
          },
          Map.new(@partition),
          %{actor: "context-agent", request_id: "ctx-request", correlation_id: "ctx-correlation"}
        )

      {:ok, _foreign} =
        Lessons.save(
          %{
            rule: "Foreign partition secret lesson",
            context: "must not leak",
            project: project,
            session_id: "foreign-session",
            idempotency_key: "ctx-foreign"
          },
          @partition |> Map.new() |> Map.put(:client_id, "foreign-client"),
          %{
            actor: "foreign",
            request_id: "foreign-request",
            correlation_id: "foreign-correlation"
          }
        )

      context =
        Context.build(project, "current-session", Keyword.put(@partition, :kind, :session_start))

      assert context =~ "## Active Lessons"
      assert context =~ "Verify the manifest-selected asset"
      assert context =~ "[lesson:#{String.slice(lesson.memory_id, 0, 8)}"
      refute context =~ "Foreign partition secret lesson"
      assert byte_size(context) <= 8_000
    end

    test "pre-compact uses a distinct current-session emphasis" do
      stub_setting("true")
      project = "ctx-precompact-#{System.unique_integer([:positive])}"

      {:ok, _lesson} =
        Lessons.save(
          %{
            rule: "Preserve the current repair decision",
            context: "compaction",
            project: project,
            session_id: "current-session",
            idempotency_key: "ctx-precompact"
          },
          Map.new(@partition),
          %{
            actor: "context-agent",
            request_id: "compact-request",
            correlation_id: "compact-correlation"
          }
        )

      start = Context.build(project, "current-session", @partition ++ [kind: :session_start])
      compact = Context.build(project, "current-session", @partition ++ [kind: :pre_compact])

      assert start =~ "## Active Lessons"
      assert compact =~ "## Pre-Compact Continuity"
      assert compact =~ "current-session"
      assert compact =~ "## Relevant Lessons"
      refute compact == start
    end
  end

  defp stub_setting(value) do
    :ets.insert(@settings_table, {@key, value})
  end
end
