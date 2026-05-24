defmodule BackplaneMemory.ContextTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Context

  @settings_table :backplane_settings
  @key "memory.inject_context"

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
      result = Context.build("unknown-project-#{:rand.uniform(99_999)}", "sess-none")
      assert result == nil
    end

    test "returns a non-empty string when inject_context is 'true' and a profile exists" do
      stub_setting("true")

      project = "ctx-proj-#{:rand.uniform(99_999)}"

      repo().insert!(%BackplaneMemory.Memories.Profile{
        project: project,
        top_concepts: %{"elixir" => 3},
        top_files: %{"lib/foo.ex" => 2},
        patterns: %{},
        session_count: 1,
        total_observations: 5
      })

      result = Context.build(project, "some-session")
      assert is_binary(result)
      assert String.length(result) > 0
      assert String.contains?(result, project)
    end
  end

  defp stub_setting(value) do
    :ets.insert(@settings_table, {@key, value})
  end
end
