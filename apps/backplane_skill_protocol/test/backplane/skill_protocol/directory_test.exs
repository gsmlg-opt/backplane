defmodule Backplane.SkillProtocol.DirectoryTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Client, Directory, Error, Parser, Resolver, SkillRef}
  alias Backplane.SkillProtocol.Source.{Backplane, Local}

  @moduletag :tmp_dir
  @digest "sha256:" <> String.duplicate("a", 64)
  @operation [:backplane, :skill_protocol, :operation]
  @native_linux_watch :os.type() == {:unix, :linux} and
                        not is_nil(System.find_executable("inotifywait"))

  test "the directory schedules no periodic local or remote work" do
    trace = :trace.session_create(:directory_timers, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)
    :trace.process(trace, :new, true, [:call])
    :trace.function(trace, {:erlang, :send_after, 3}, true, [:local])

    server = start_supervised!({Directory, []})

    # Synchronize trace delivery after the child's init has completed.
    delivery = :trace.delivered(trace, server)
    assert_receive {:trace_delivered, ^server, ^delivery}
    refute_received {:trace, ^server, :call, {:erlang, :send_after, [_, ^server, _]}}
  end

  test "two scopes share one warmup and all consumer reads are I/O free", %{tmp_dir: root} do
    write_skill(root, "alpha", "alpha")
    write_skill(root, "manual", "manual", "disable-model-invocation: true\n")
    write_skill(root, "model", "model", "user-invocable: false\n")
    remote = remote_source()

    server = start_directory()
    trace = trace_calls()
    sources = [{"global", {:local, root}}, {"cloud", remote}]
    assert :ok = Directory.register_scope(server, :one, sources: sources)
    assert :ok = Directory.register_scope(server, :two, sources: sources, disabled: ["alpha"])
    assert {:ok, %{status: :warming}} = Directory.subscribe(server, :one)
    assert {:ok, %{status: :warming}} = Directory.subscribe(server, :two)
    assert_receive {:request, transport, url}
    assert URI.decode_query(URI.parse(url).query)["view"] == "always"

    send(transport, response("always", []))
    one = await_snapshot(server, :one, &(&1.status == :ready))
    two = await_snapshot(server, :two, &(&1.status == :ready))
    assert names(one.automatic) == ["alpha", "model"]
    assert names(one.explicit) == ["alpha", "manual"]
    assert names(two.automatic) == ["model"]
    assert names(two.explicit) == ["manual"]
    assert one.sources["cloud"].status == :ready
    assert count(trace, {File, :ls, 1}) > 0
    assert count(trace, {File, :read, 1}) == 3
    assert count(trace, {Parser, :parse, 2}) == 3

    reset_counts(trace)

    1..24
    |> Task.async_stream(
      fn _ ->
        assert {:ok, ^one} = Directory.snapshot(server, :one)
        assert {:ok, ^one} = Directory.subscribe(server, :one)
        assert {:ok, ^two} = Directory.snapshot(server, :two)
      end,
      max_concurrency: 12
    )
    |> Enum.each(fn {:ok, _} -> :ok end)

    assert count(trace, {File, :ls, 1}) == 0
    assert count(trace, {File, :read, 1}) == 0
    assert count(trace, {Parser, :parse, 2}) == 0
    refute_received {:request, _, _}
  end

  test "repository precedence and effective policy update without rescanning shared sources", %{
    tmp_dir: tmp
  } do
    global = Path.join(tmp, "global")
    repository = Path.join(tmp, "repository")
    write_skill(global, "shared", "shared")
    write_skill(global, "global-only", "global-only")
    write_skill(repository, "shared", "shared")

    server = start_directory()
    shared = {"global", {:local, global}}
    override = {"repository", {:local, repository}, 0}
    assert :ok = Directory.register_scope(server, :one, sources: [shared, override])
    assert :ok = Directory.register_scope(server, :two, sources: [shared])
    assert {:ok, _} = Directory.subscribe(server, :one)
    assert {:ok, _} = Directory.subscribe(server, :two)
    one = await_snapshot(server, :one, &(&1.status == :ready))
    two = await_snapshot(server, :two, &(&1.status == :ready))

    assert {:ok, %{ref: %{source_id: "repository"}}} = Resolver.resolve(one.explicit, "shared")

    assert {:ok, %{ref: %{source_id: "global"}}} =
             Resolver.resolve(one.explicit, %SkillRef{source_id: "global", skill_id: "shared"})

    trace = trace_calls()

    assert :ok =
             Directory.register_scope(server, :one,
               sources: [shared],
               disabled: [{"global", "global-only"}],
               allow_explicit: false
             )

    assert {:ok, %{automatic: [%{name: "shared"}], explicit: [], sources: %{"global" => _}} = new} =
             Directory.snapshot(server, :one)

    assert new.revision > one.revision
    assert {:ok, ^two} = Directory.snapshot(server, :two)
    assert count(trace, {File, :ls, 1}) == 0
    assert count(trace, {Parser, :parse, 2}) == 0

    assert :ok = Directory.register_scope(server, :one, sources: [])

    assert {:ok, %{status: :ready, automatic: [], explicit: [], sources: %{}}} =
             Directory.snapshot(server, :one)

    assert :ok = Directory.unregister_scope(server, :one)
    assert {:error, :unknown_scope} = Directory.snapshot(server, :one)
    assert {:ok, ^two} = Directory.snapshot(server, :two)
  end

  @tag skip: !@native_linux_watch && "requires Linux inotifywait"
  test "an edit reads and parses only that file and lifecycle changes update both views", %{
    tmp_dir: root
  } do
    current = write_skill(root, "alpha", "alpha", "argument-hint: file\n")
    write_skill(root, "sibling", "sibling")
    server = start_directory(watch: true, debounce_ms: 100)
    assert :ok = Directory.register_scope(server, :repo, sources: [{"local", {:local, root}}])
    assert {:ok, _} = Directory.subscribe(server, :repo)
    initial = await_snapshot(server, :repo, &(&1.status == :ready))

    probe_watch(root, server, 10)
    File.rm_rf!(Path.join(root, "probe"))

    initial =
      await_snapshot(
        server,
        :repo,
        &(&1.revision > initial.revision and names(&1.explicit) == ["alpha", "sibling"])
      )

    trace = trace_calls()

    write_skill(
      root,
      "alpha",
      "alpha",
      "argument-hint: filepath\ndisable-model-invocation: true\n"
    )

    edited = await_snapshot(server, :repo, &(&1.revision > initial.revision))
    assert names(edited.automatic) == ["sibling"]
    assert [%{name: "alpha", argument_hint: "filepath"}, %{name: "sibling"}] = edited.explicit
    assert count(trace, {File, :read, 1}) == 1
    assert count(trace, {Parser, :parse, 2}) == 1

    write_skill(root, "new", "new")
    added = await_snapshot(server, :repo, &(&1.revision > edited.revision))
    assert names(added.explicit) == ["alpha", "new", "sibling"]

    File.rename!(Path.join(root, "new"), Path.join(root, "moved"))
    renamed = await_snapshot(server, :repo, &(&1.revision > added.revision))
    assert Enum.any?(renamed.explicit, &(&1.ref.skill_id == "moved"))
    refute Enum.any?(renamed.explicit, &(&1.ref.skill_id == "new"))

    File.rm!(Path.join([root, "moved", "SKILL.md"]))
    deleted = await_snapshot(server, :repo, &(&1.revision > renamed.revision))
    assert names(deleted.explicit) == ["alpha", "sibling"]

    # Atomic replacement at the existing SKILL.md path.
    temp = current <> ".tmp"
    File.write!(temp, "invalid document")
    File.rename!(temp, current)
    invalid = await_snapshot(server, :repo, &(&1.revision > deleted.revision))
    assert names(invalid.explicit) == ["sibling"]

    assert [%{code: :missing_frontmatter, context: %{path: "alpha/SKILL.md"}}] =
             invalid.sources["local"].diagnostics

    write_skill(root, "alpha", "alpha")
    fixed = await_snapshot(server, :repo, &(&1.revision > invalid.revision))
    assert names(fixed.automatic) == ["alpha", "sibling"]
    assert fixed.sources["local"].diagnostics == []
  end

  @tag skip: !@native_linux_watch && "requires Linux inotifywait"
  test "watch follows an optional root created later and reconnects when that root is replaced",
       %{
         tmp_dir: tmp
       } do
    root = Path.join([tmp, "optional", "skills"])
    replacement = Path.join(tmp, "replacement")
    write_skill(replacement, "new", "new")
    server = start_directory(watch: true, debounce_ms: 100)

    assert :ok =
             Directory.register_scope(server, :repo,
               sources: [{"local", {:local, root, missing: :empty}}]
             )

    assert {:ok, _} = Directory.subscribe(server, :repo)
    ready = await_snapshot(server, :repo, &(&1.status == :ready))
    assert ready.automatic == []

    # inotifywait starts asynchronously. A non-directory at the missing
    # boundary exercises that watch before creating the actual skill root.
    blocker = Path.dirname(root)
    probe_boundary(blocker, server, ready.revision, 10)
    assert {:ok, %{status: :degraded}} = Directory.snapshot(server, :repo)
    File.rm!(blocker)
    write_skill(root, "original", "original")
    active = await_snapshot(server, :repo, &(names(&1.automatic) == ["original"]))
    probe_watch(root, server, 10)
    File.rename!(root, Path.join(tmp, "former"))
    File.rename!(replacement, root)
    replaced = await_snapshot(server, :repo, &(names(&1.automatic) == ["new"]))
    assert replaced.revision > active.revision
    probe_watch(root, server, 10)
    write_skill(root, "added", "added")

    assert %{automatic: [%{name: "added"}, %{name: "new"}, %{name: "probe"}]} =
             await_snapshot(server, :repo, &(names(&1.automatic) == ["added", "new", "probe"]))
  end

  @tag skip: !@native_linux_watch && "requires Linux inotifywait"
  test "native watch detects a same-length edit without polling or auditing", %{tmp_dir: root} do
    watched = write_skill(root, "watched", "watched")
    write_skill(root, "sibling", "sibling")
    server = start_directory(watch: true, debounce_ms: 100)
    assert :ok = Directory.register_scope(server, :repo, sources: [{"native", {:local, root}}])
    assert {:ok, _} = Directory.subscribe(server, :repo)
    initial = await_snapshot(server, :repo, &(&1.status == :ready))

    # Native backends start asynchronously. Observe one update before measuring
    # a write, then leave the watcher as the only way to detect the next edit.
    probe_watch(root, server, 10)
    assert {:ok, ready} = Directory.snapshot(server, :repo)
    assert ready.revision > initial.revision
    bytes = File.read!(watched)
    trace = trace_calls()
    File.write!(watched, String.replace(bytes, "Body", "Edit"))
    new = await_snapshot(server, :repo, &(&1.revision > ready.revision))

    assert new.explicit != ready.explicit
    assert count(trace, {File, :read, 1}) == 1
    assert count(trace, {Parser, :parse, 2}) == 1
  end

  test "directories honor standard and legacy profiles and distinguish missing roots", %{
    tmp_dir: root
  } do
    path = write_skill(root, "legacy", "legacy")
    File.write!(path, "---\nname: Legacy Skill\n---\nContent")
    missing = Path.join(root, "not-created")

    server = start_directory()

    assert :ok =
             Directory.register_scope(server, :repo,
               sources: [
                 {"legacy", {:local, root, profile: :legacy}},
                 {"standard", {:local, root, profile: :standard}},
                 {"optional", {:local, missing, missing: :empty}},
                 {"required", {:local, missing}}
               ]
             )

    assert {:ok, _} = Directory.subscribe(server, :repo)
    snapshot = await_snapshot(server, :repo, &(&1.status == :degraded))
    assert [%{name: "Legacy Skill", description: nil}] = snapshot.automatic
    assert [%{name: "Legacy Skill", description: nil}] = snapshot.explicit

    assert %{status: :ready, diagnostics: [%{code: :missing_description}]} =
             snapshot.sources["legacy"]

    assert %{status: :ready, diagnostics: [%{code: :invalid_document}]} =
             snapshot.sources["standard"]

    assert %{status: :ready, diagnostics: [], error: nil} = snapshot.sources["optional"]
    assert %{status: :error, error: %Error{}} = snapshot.sources["required"]
  end

  test "initial scan reconciles changes observed after directory traversal", %{tmp_dir: root} do
    write_skill(root, "old", "old")
    server = start_directory()
    gate_first_scan("race")
    assert :ok = Directory.register_scope(server, :repo, sources: [{"race", {:local, root}}])
    assert_receive {:scanned, worker}, 3_000

    assert {:ok, %{status: :warming, automatic: [], explicit: []} = warming} =
             Directory.subscribe(server, :repo)

    File.rm_rf!(Path.join(root, "old"))
    write_skill(root, "new", "new")
    send(worker, :continue)

    assert_receive {:skill_directory_updated, ^server, :repo, revision}, 3_000

    assert {:ok, %{status: :ready, revision: ^revision, explicit: entries}} =
             Directory.snapshot(server, :repo)

    assert {:ok, ^entries} = Local.discover([%{source_id: "race", path: root}])
    assert [%{name: "new"}] = entries
    assert revision > warming.revision
    refute_received {:skill_directory_updated, ^server, :repo, _}
  end

  test "local changes during refresh preserve the former complete snapshot until reconciliation",
       %{
         tmp_dir: root
       } do
    path = write_skill(root, "one", "one")
    server = start_directory()
    assert :ok = Directory.register_scope(server, :repo, sources: [{"local", {:local, root}}])
    assert {:ok, _} = Directory.subscribe(server, :repo)
    initial = await_snapshot(server, :repo, &(&1.status == :ready))

    gate_first_scan("local")
    assert :ok = Directory.force_reload(server, :repo, "local")
    assert_receive {:scanned, worker}, 3_000
    File.rename!(path, path <> ".former")
    write_skill(root, "one", "replaced")
    write_skill(root, "two", "another")
    assert :ok = Directory.force_reload(server, :repo, "local")
    assert {:ok, ^initial} = Directory.snapshot(server, :repo)
    send(worker, :continue)

    assert_receive {:skill_directory_updated, ^server, :repo, revision}, 3_000

    assert {:ok, %{revision: ^revision, status: :ready, explicit: entries}} =
             Directory.snapshot(server, :repo)

    assert names(entries) == ["another", "replaced"]
    assert {:ok, ^entries} = Local.discover([%{source_id: "local", path: root}])
    refute_received {:skill_directory_updated, ^server, :repo, _}
  end

  test "force reload repairs an unreported write and transient root failure retains its last view",
       %{
         tmp_dir: tmp
       } do
    root = Path.join(tmp, "skills")
    away = Path.join(tmp, "away")
    current = write_skill(root, "alpha", "alpha")
    server = start_directory()
    assert :ok = Directory.register_scope(server, :repo, sources: [{"local", {:local, root}}])
    assert {:ok, _} = Directory.subscribe(server, :repo)
    initial = await_snapshot(server, :repo, &(&1.status == :ready))

    File.write!(current, String.replace(File.read!(current), "Body", "Edit"))
    assert {:ok, ^initial} = Directory.snapshot(server, :repo)
    assert :ok = Directory.force_reload(server, :repo)
    audited = await_snapshot(server, :repo, &(&1.revision > initial.revision))
    assert [%{document_digest: digest}] = audited.automatic
    refute initial.automatic == audited.automatic

    File.rename!(root, away)
    assert :ok = Directory.force_reload(server, :repo)
    failed = await_snapshot(server, :repo, &(&1.status == :degraded))
    assert [%{document_digest: ^digest}] = failed.automatic
    assert %{status: :stale, error: %Error{retryable: true}} = failed.sources["local"]

    File.rename!(away, root)
    assert :ok = Directory.force_reload(server, :repo)
    recovered = await_snapshot(server, :repo, &(&1.status == :ready))
    assert recovered.automatic == audited.automatic
    assert recovered.revision > failed.revision
  end

  test "refresh coalesces in-flight invalidations and concurrent subscribers miss no publication" do
    server = start_directory()
    remote = remote_source()
    assert :ok = Directory.register_scope(server, :repo, sources: [{"cloud", remote}])
    assert {:ok, _} = Directory.subscribe(server, :repo)
    reply_to_request(response("always", [remote_item("initial")]))
    initial = await_snapshot(server, :repo, &(&1.status == :ready))

    assert :ok = Directory.force_reload(server, :repo, "cloud")
    assert_receive {:request, old_request, _}, 3_000

    for _ <- 1..10 do
      assert :ok = Directory.force_reload(server, :repo, "cloud")
      assert {:ok, ^initial} = Directory.snapshot(server, :repo)
    end

    send(old_request, response("always", [remote_item("outdated")]))
    assert_receive {:request, new_request, _}, 3_000
    assert {:ok, ^initial} = Directory.snapshot(server, :repo)
    refute_received {:skill_directory_updated, ^server, :repo, _}

    subscribers =
      for _ <- 1..20 do
        Task.async(fn ->
          assert {:ok, snapshot} = Directory.subscribe(server, :repo)

          case snapshot.explicit do
            [%{name: "initial"}] ->
              assert_receive {:skill_directory_updated, ^server, :repo, revision}, 3_000
              assert revision > snapshot.revision

              assert {:ok, %{revision: ^revision, explicit: [%{name: "latest"}]}} =
                       Directory.snapshot(server, :repo)

            [%{name: "latest"}] ->
              assert snapshot.revision > initial.revision
          end
        end)
      end

    send(new_request, response("always", [remote_item("latest")]))
    refute_receive {:request, _, _}, 80
    Enum.each(subscribers, &Task.await/1)
    assert {:ok, %{explicit: [%{name: "latest"}]}} = Directory.snapshot(server, :repo)
  end

  test "remote paging, search, transient failure and denial remain distinct" do
    server = start_directory()
    remote = remote_source()
    assert :ok = Directory.register_scope(server, :repo, sources: [{"cloud", remote}])
    assert {:ok, %{status: :warming}} = Directory.subscribe(server, :repo)
    reply_to_request(response("always", [remote_item("normal")], "second"))
    assert_receive {:request, second, url}, 3_000
    assert URI.decode_query(URI.parse(url).query)["cursor"] == "second"
    assert {:ok, %{status: :warming, explicit: []}} = Directory.snapshot(server, :repo)
    send(second, response("always", [remote_item("manual", true)]))

    ready = await_snapshot(server, :repo, &(&1.status == :ready))
    assert names(ready.automatic) == ["normal"]

    assert [
             %{
               name: "manual",
               argument_hint: "path",
               ref: %{revision: "r-manual", artifact_digest: @digest}
             },
             %{name: "normal"}
           ] = ready.explicit

    [manual, _] = ready.explicit
    assert {:ok, ^manual} = Resolver.resolve(ready.explicit, manual.ref)
    wrong = %{manual.ref | artifact_digest: "sha256:" <> String.duplicate("b", 64)}
    assert {:error, %Error{code: :not_found}} = Resolver.resolve(ready.explicit, wrong)

    search = Task.async(fn -> Backplane.search(remote, q: "other") end)
    assert_receive {:request, on_demand, url}, 3_000
    assert URI.parse(url).path == "/skill-protocol/v1/search"
    send(on_demand, response("search", [remote_item("other")]))
    assert {:ok, %{data: [%{name: "other"}]}} = Task.await(search)
    assert {:ok, ^ready} = Directory.snapshot(server, :repo)

    assert :ok = Directory.force_reload(server, :repo)
    reply_to_request({:error, :closed})
    stale = await_snapshot(server, :repo, &(&1.status == :degraded))
    assert stale.explicit == ready.explicit

    assert %{status: :stale, error: %Error{code: :temporarily_unavailable}} =
             stale.sources["cloud"]

    assert :ok = Directory.force_reload(server, :repo)
    reply_to_request({:error, :timeout})
    timed_out = await_snapshot(server, :repo, &(&1.revision > stale.revision))
    assert timed_out.explicit == ready.explicit
    assert %{status: :stale, error: %Error{code: :timeout}} = timed_out.sources["cloud"]

    assert :ok = Directory.force_reload(server, :repo)
    reply_to_request({:ok, %{status: 403, body: ""}})
    denied = await_snapshot(server, :repo, &(&1.revision > timed_out.revision))
    assert denied.explicit == []
    assert %{status: :error, error: %Error{code: :forbidden}} = denied.sources["cloud"]

    assert :ok = Directory.force_reload(server, :repo)
    reply_to_request(response("always", []))
    empty = await_snapshot(server, :repo, &(&1.status == :ready))
    assert empty.automatic == []
    assert empty.explicit == []
    assert empty.sources["cloud"].status == :ready
  end

  test "source replacement discards in-flight results from the former client" do
    server = start_directory()

    assert :ok =
             Directory.register_scope(server, :repo, sources: [{"cloud", remote_source("old")}])

    assert_receive {:request, former_request, _}, 3_000
    assert {:ok, _} = Directory.subscribe(server, :repo)

    assert :ok =
             Directory.register_scope(server, :repo, sources: [{"cloud", remote_source("new")}])

    send(former_request, response("always", [remote_item("former")]))
    reply_to_request(response("always", [remote_item("current")]))
    snapshot = await_snapshot(server, :repo, &(&1.status == :ready))
    assert names(snapshot.explicit) == ["current"]
    assert :ok = Directory.register_scope(server, :repo, sources: [])
    assert {:ok, %{status: :ready, explicit: []}} = Directory.snapshot(server, :repo)
    assert {:error, :unknown_source} = Directory.force_reload(server, :repo, "cloud")
  end

  @tag capture_log: true
  test "supervisor restarts directory and the host re-registers and re-subscribes", %{
    tmp_dir: root
  } do
    name = __MODULE__.RestartDirectory
    former = start_directory(name: name)
    write_skill(root, "one", "one")
    sources = [{"local", {:local, root}}]
    assert :ok = Directory.register_scope(name, :repo, sources: sources)
    assert {:ok, _} = Directory.subscribe(name, :repo)
    initial = await_snapshot(former, :repo, &(&1.status == :ready))

    ref = Process.monitor(former)
    Process.exit(former, :kill)
    assert_receive {:DOWN, ^ref, :process, ^former, :killed}, 3_000
    write_skill(root, "two", "two")

    current = wait_for_restart(name, 100)
    assert current != former
    assert {:error, :unknown_scope} = Directory.snapshot(name, :repo)
    gate_first_scan("local")
    assert :ok = Directory.register_scope(name, :repo, sources: sources)
    assert_receive {:scanned, worker}, 3_000
    assert {:ok, %{status: :warming}} = Directory.subscribe(name, :repo)
    send(worker, :continue)
    recovered = await_snapshot(current, :repo, &(&1.status == :ready))
    assert names(recovered.explicit) == ["one", "two"]
    assert recovered.revision > initial.revision
  end

  defp remote_source(access \\ "tester") do
    parent = self()

    Client.new!(
      endpoint: "https://example.test",
      source_id: "cloud",
      access_context_id: access,
      max_attempts: 1,
      transport: fn request ->
        send(parent, {:request, self(), request.url})
        receive do: (reply -> reply)
      end
    )
    |> Backplane.new!()
  end

  defp reply_to_request(response) do
    assert_receive {:request, transport, _url}, 3_000
    send(transport, response)
  end

  defp remote_item(name, manual? \\ false) do
    %{
      "skill_id" => name,
      "name" => name,
      "description" => name,
      "argument_hint" => "path",
      "revision" => "r-" <> name,
      "artifact_digest" => @digest,
      "publication_status" => "ready",
      "disable_model_invocation" => manual?
    }
  end

  defp gate_first_scan(source_id) do
    parent = self()
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        @operation,
        &__MODULE__.gate_scan/4,
        {parent, source_id, handler_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def gate_scan(
        _event,
        _measurements,
        %{phase: :directory, operation: :scan, source_id: id},
        {parent, id, handler_id}
      ) do
    :ok = :telemetry.detach(handler_id)
    send(parent, {:scanned, self()})
    receive do: (:continue -> :ok)
  end

  def gate_scan(_event, _measurements, _metadata, _config), do: :ok

  defp wait_for_restart(name, attempts) when attempts > 0 do
    case Process.whereis(name) do
      nil ->
        Process.sleep(10)
        wait_for_restart(name, attempts - 1)

      pid ->
        pid
    end
  end

  defp wait_for_restart(_name, 0), do: flunk("directory failed to restart")

  defp probe_watch(root, server, attempts) when attempts > 0 do
    write_skill(root, "probe", "probe", "argument-hint: '#{attempts}'\n")

    receive do
      {:skill_directory_updated, ^server, :repo, _} -> :ok
    after
      350 -> probe_watch(root, server, attempts - 1)
    end
  end

  defp probe_watch(_root, _server, 0), do: flunk("native file watcher published no update")

  defp probe_boundary(path, server, revision, attempts) when attempts > 0 do
    File.write!(path, Integer.to_string(attempts))

    receive do
      {:skill_directory_updated, ^server, :repo, newer} when newer > revision -> :ok
    after
      350 -> probe_boundary(path, server, revision, attempts - 1)
    end
  end

  defp probe_boundary(_path, _server, _revision, 0), do: flunk("parent watch published no update")

  defp response(view, data, cursor \\ nil) do
    {:ok,
     %{
       status: 200,
       body:
         JSON.encode!(%{
           "protocol_version" => "1",
           "view" => view,
           "data" => data,
           "next_cursor" => cursor
         })
     }}
  end

  defp start_directory(opts \\ []) do
    start_supervised!(
      {Directory,
       Keyword.merge(
         [
           watch: false,
           remote_events: false,
           debounce_ms: 0
         ],
         opts
       )}
    )
  end

  defp await_snapshot(server, scope, condition) do
    assert {:ok, snapshot} = Directory.snapshot(server, scope)

    if condition.(snapshot) do
      snapshot
    else
      assert_receive {:skill_directory_updated, ^server, ^scope, _revision}, 3_000
      await_snapshot(server, scope, condition)
    end
  end

  defp write_skill(root, directory, name, extra \\ "") do
    path = Path.join([root, directory, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nname: #{name}\ndescription: #{name}\n#{extra}---\nBody")
    path
  end

  defp names(entries), do: Enum.map(entries, & &1.name)

  @calls [{File, :ls, 1}, {File, :read, 1}, {Parser, :parse, 2}]

  defp trace_calls do
    session = :trace.session_create(:directory_test, self(), [])
    reset_counts(session)
    on_exit(fn -> :trace.session_destroy(session) end)
    session
  end

  defp reset_counts(session) do
    for mfa <- @calls do
      :trace.function(session, mfa, false, [:call_count])
      :trace.function(session, mfa, true, [:call_count])
    end
  end

  defp count(session, mfa) do
    {:call_count, count} = :trace.info(session, mfa, :call_count)
    count
  end
end
