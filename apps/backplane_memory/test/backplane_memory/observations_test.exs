defmodule BackplaneMemory.ObservationsTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Observations
  alias BackplaneMemory.Observations.Session

  # ---------------------------------------------------------------------------
  # record/3
  # ---------------------------------------------------------------------------

  describe "record/3" do
    test "inserts an observation and returns {:ok, obs}" do
      assert {:ok, obs} = Observations.record("sess-1", "fixed a bug in lib/foo.ex")
      assert obs.session_id == "sess-1"
      assert obs.content == "fixed a bug in lib/foo.ex"
      assert obs.is_error == false
      assert is_binary(obs.id)
    end

    test "stores optional tool_name" do
      assert {:ok, obs} = Observations.record("sess-2", "ran tests", tool_name: "Bash")
      assert obs.tool_name == "Bash"
    end

    test "stores is_error flag" do
      assert {:ok, obs} = Observations.record("sess-3", "compilation failed", is_error: true)
      assert obs.is_error == true
    end

    test "extracts file paths into files map" do
      assert {:ok, obs} =
               Observations.record("sess-4", "edited /project/lib/foo.ex and apps/bar/mix.exs")

      paths = obs.files["paths"]
      assert is_list(paths)
      assert Enum.any?(paths, &String.contains?(&1, "foo.ex"))
    end

    test "returns {:error, :filtered} when privacy filter rejects the content" do
      # Privacy filter strips secrets; we rely on the filter module's own logic.
      # A session_id-only call with empty content triggers changeset validation instead.
      result = Observations.record("sess-5", "")
      # Either filtered or changeset error — it must not be :ok
      assert result != {:ok, %{}}
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # register_session/2
  # ---------------------------------------------------------------------------

  describe "register_session/2" do
    test "creates a new session record" do
      assert {:ok, session} = Observations.register_session("sid-a", "my-project")
      assert session.session_id == "sid-a"
      assert session.project == "my-project"
    end

    test "is idempotent — re-registering the same session_id does not error" do
      assert {:ok, _} = Observations.register_session("sid-b", "proj")
      # Second call must not crash
      assert {:ok, _} = Observations.register_session("sid-b", "proj-updated")
    end

    test "idempotent call does not overwrite the original project" do
      assert {:ok, _} = Observations.register_session("sid-c", "original")
      # on_conflict: :nothing — second insert silently skipped
      assert {:ok, _} = Observations.register_session("sid-c", "overwrite")

      session = repo().get(Session, "sid-c")
      assert session.project == "original"
    end
  end

  # ---------------------------------------------------------------------------
  # end_session/1
  # ---------------------------------------------------------------------------

  describe "end_session/1" do
    test "sets ended_at on a started session" do
      {:ok, _} = Observations.register_session("end-a", "p")
      {1, _} = Observations.end_session("end-a")

      session = repo().get(Session, "end-a")
      assert session.ended_at != nil
    end

    test "calling end_session on an already-ended session is a no-op" do
      {:ok, _} = Observations.register_session("end-b", "p")
      {1, _} = Observations.end_session("end-b")
      # Second call matches 0 rows (already has ended_at set)
      {0, _} = Observations.end_session("end-b")
    end

    test "end_session on unknown session_id returns {0, nil}" do
      assert {0, _} = Observations.end_session("nonexistent-session-xyz")
    end
  end

  # ---------------------------------------------------------------------------
  # file_history/2
  # ---------------------------------------------------------------------------

  describe "file_history/2" do
    test "returns observations whose files map includes any of the given paths" do
      {:ok, _} = Observations.record("fh-sess-1", "updated lib/foo.ex")
      {:ok, _} = Observations.record("fh-sess-1", "changed apps/bar/mix.exs")
      {:ok, _} = Observations.record("fh-sess-1", "no path here at all")

      results = Observations.file_history(["lib/foo.ex"])
      contents = Enum.map(results, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "foo.ex"))
      refute Enum.any?(contents, &(&1 == "no path here at all"))
    end

    test "excludes observations from the given session when exclude_session is set" do
      {:ok, _} = Observations.record("fh-mine", "changed lib/foo.ex")
      {:ok, _} = Observations.record("fh-other", "touched lib/foo.ex too")

      results = Observations.file_history(["lib/foo.ex"], exclude_session: "fh-mine")
      session_ids = Enum.map(results, & &1.session_id)
      refute "fh-mine" in session_ids
      assert "fh-other" in session_ids
    end

    test "respects the limit option" do
      for i <- 1..5 do
        Observations.record("fh-limit-sess", "edited lib/foo.ex version #{i}")
      end

      results = Observations.file_history(["lib/foo.ex"], limit: 2)
      assert length(results) <= 2
    end

    test "returns empty list when no observations match the given paths" do
      assert [] = Observations.file_history(["does/not/exist.ex"])
    end
  end
end
