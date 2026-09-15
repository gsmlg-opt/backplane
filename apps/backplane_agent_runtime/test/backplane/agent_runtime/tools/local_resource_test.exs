defmodule Backplane.AgentRuntime.Tools.LocalResourceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools.LocalResource

  setup %{tmp_dir: scope} do
    {:ok, _} = LocalResource.start_link()

    {:ok, resource} =
      Backplane.AgentRuntime.Resource.new(%{scope: scope, adapter: LocalResource})

    %{resource: resource, scope: scope}
  end

  @tag :tmp_dir
  test "lists, globs, greps, and edits coordinated files", %{resource: resource, scope: scope} do
    File.write!(Path.join(scope, "alpha.txt"), "alpha one\nalpha two")

    File.write!(Path.join(scope, "safe.txt"), "hello world")

    assert {:ok, %{entries: [%{path: "alpha.txt"}, %{path: "safe.txt"}]}} =
             Backplane.AgentRuntime.Resource.list_dir(resource, %{path: scope}, [])

    assert {:ok, %{matches: [%{path: "alpha.txt"}, %{path: "safe.txt"}]}} =
             Backplane.AgentRuntime.Resource.glob(resource, %{path: scope}, "*.txt", [])

    assert {:ok, %{matches: [%{path: "alpha.txt", line: 1}]}} =
             Backplane.AgentRuntime.Resource.grep(resource, %{path: scope}, query: "alpha one")

    assert {:ok, %{written: true, revision: 1}} =
             Backplane.AgentRuntime.Resource.write(
               resource,
               %{path: Path.join(scope, "alpha.txt"), expected_revision: 0},
               %{payload: "alpha one"}
             )

    assert {:ok, %{revision: 2}} =
             Backplane.AgentRuntime.Resource.file_edit(
               resource,
               %{path: Path.join(scope, "alpha.txt"), expected_revision: 1},
               %{find: "one", replace: "two"}
             )

    assert File.read!(Path.join(scope, "alpha.txt")) == "alpha two"
  end

  @tag :tmp_dir
  test "rejects traversal and symlink replacement attacks", %{resource: resource, scope: scope} do
    File.mkdir_p!(Path.join(scope, "outside"))
    File.write!(Path.join([scope, "outside", "secret"]), "secret")
    target = Path.join(scope, "link.txt")
    File.ln_s!(Path.join([scope, "outside", "secret"]), target)

    assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
             Backplane.AgentRuntime.Resource.read(resource, %{path: Path.join(scope, "../secret")})

    assert {:error, %Backplane.AgentRuntime.Error{class: :unsupported_capability}} =
             Backplane.AgentRuntime.Resource.read(resource, %{path: target})
  end

  @tag :tmp_dir
  test "rejects oversized unpartial output", %{resource: resource, scope: scope} do
    path = Path.join(scope, "large.txt")
    File.write!(path, String.duplicate("x", 20))

    assert {:error, %Backplane.AgentRuntime.Error{}} =
             Backplane.AgentRuntime.Resource.read(resource, %{path: path}, output_limit: 10)
  end

  @tag :tmp_dir
  test "reads files within scope and reports bounded partial content", %{resource: resource} do
    path = Path.join(resource.scope, "safe.txt")
    File.write!(path, "hello world")

    assert {:ok, %{content: "hello", partial?: true}} =
             Backplane.AgentRuntime.Resource.read(
               resource,
               %{path: path},
               output_limit: 5,
               partial_output?: true
             )
  end

  @tag :tmp_dir
  test "rejects traversal outside declared scope", %{resource: resource} do
    assert {:error, %Error{class: :forbidden}} =
             Backplane.AgentRuntime.Resource.read(resource, %{path: "/outside/file"})
  end

  @tag :tmp_dir
  test "rejects stale writes without silent overwrite", %{resource: resource} do
    path = Path.join(resource.scope, "safe.txt")
    File.write!(path, "initial")

    reference = %{path: path, expected_revision: 0}

    assert {:ok, %{written: true, revision: 1}} =
             Backplane.AgentRuntime.Resource.write(resource, reference, %{payload: "next"})

    assert {:error, %Error{class: :resource_conflict}} =
             Backplane.AgentRuntime.Resource.write(resource, reference, %{payload: "stale"})
  end

  @tag :tmp_dir
  test "rejects grep patterns that escape the declared scope", %{scope: fixture_root} do
    scope = Path.join(fixture_root, "workspace")
    private = Path.join(fixture_root, "private")
    File.mkdir_p!(scope)
    File.mkdir_p!(private)
    File.write!(Path.join(private, "secret.txt"), "do not read")

    {:ok, resource} =
      Backplane.AgentRuntime.Resource.new(%{scope: scope, adapter: LocalResource})

    assert {:error, %Error{class: :forbidden}} =
             Backplane.AgentRuntime.Resource.grep(
               resource,
               %{path: scope},
               query: "do not read",
               pattern: "../private/*.txt"
             )
  end

  @tag :tmp_dir
  test "only one competing write at the same revision commits", %{resource: resource} do
    path = Path.join(resource.scope, "race.txt")

    results =
      compete(fn payload ->
        Backplane.AgentRuntime.Resource.write(
          resource,
          %{path: path, expected_revision: 0},
          %{payload: payload}
        )
      end)

    assert_single_committed_content(results, path)
  end

  @tag :tmp_dir
  test "only one competing edit at the same revision commits", %{resource: resource} do
    path = Path.join(resource.scope, "edit-race.txt")
    File.write!(path, "base")

    results =
      compete(fn replacement ->
        Backplane.AgentRuntime.Resource.file_edit(
          resource,
          %{path: path, expected_revision: 0},
          %{find: "base", replace: replacement}
        )
      end)

    assert_single_committed_content(results, path)
  end

  @tag :tmp_dir
  test "create-only contention creates the file once", %{resource: resource} do
    path = Path.join(resource.scope, "create-race.txt")

    results =
      compete(fn payload ->
        Backplane.AgentRuntime.Resource.write(
          resource,
          %{path: path, expected_revision: 0, create_only?: true},
          %{payload: payload}
        )
      end)

    assert_single_committed_content(results, path)
  end

  @tag :tmp_dir
  test "create-only writes do not require an expected revision", %{resource: resource} do
    path = Path.join(resource.scope, "create-only.txt")
    reference = %{path: path, create_only?: true}

    assert {:ok, %{revision: 1, written: true}} =
             Backplane.AgentRuntime.Resource.write(resource, reference, %{payload: "created"})

    assert {:error, %Error{class: :resource_conflict}} =
             Backplane.AgentRuntime.Resource.write(resource, reference, %{payload: "duplicate"})

    assert File.read!(path) == "created"
  end

  @tag :tmp_dir
  test "independently named coordinators do not collide or share revisions", %{
    scope: fixture_root
  } do
    {:ok, first_server} = LocalResource.start_link(%{name: nil})
    {:ok, second_server} = LocalResource.start_link(%{name: nil})

    first_scope = Path.join(fixture_root, "first")
    second_scope = Path.join(fixture_root, "second")
    File.mkdir_p!(first_scope)
    File.mkdir_p!(second_scope)

    {:ok, first} =
      Backplane.AgentRuntime.Resource.new(%{
        scope: first_scope,
        adapter: LocalResource,
        server: first_server
      })

    {:ok, second} =
      Backplane.AgentRuntime.Resource.new(%{
        scope: second_scope,
        adapter: LocalResource,
        server: second_server
      })

    assert {:ok, %{revision: 1}} =
             Backplane.AgentRuntime.Resource.write(
               first,
               %{path: Path.join(first_scope, "value.txt"), expected_revision: 0},
               %{payload: "first"}
             )

    assert {:ok, %{revision: 1}} =
             Backplane.AgentRuntime.Resource.write(
               second,
               %{path: Path.join(second_scope, "value.txt"), expected_revision: 0},
               %{payload: "second"}
             )

    GenServer.stop(first_server)

    assert {:ok, %{revision: 2}} =
             Backplane.AgentRuntime.Resource.write(
               second,
               %{path: Path.join(second_scope, "value.txt"), expected_revision: 1},
               %{payload: "still running"}
             )
  end

  defp compete(operation) do
    parent = self()

    tasks =
      for payload <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          result =
            receive do
              :go -> operation.(payload)
            end

          {payload, result}
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 1_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await/1)
  end

  defp assert_single_committed_content(results, path) do
    assert [{winner, {:ok, %{revision: 1, written: true}}}] =
             Enum.filter(results, &match?({_payload, {:ok, _result}}, &1))

    assert [{_loser, {:error, %Error{class: :resource_conflict}}}] =
             Enum.filter(results, &match?({_payload, {:error, _error}}, &1))

    assert File.read!(path) == winner
  end
end
