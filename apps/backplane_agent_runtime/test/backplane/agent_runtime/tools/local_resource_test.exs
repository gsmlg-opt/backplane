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
end
