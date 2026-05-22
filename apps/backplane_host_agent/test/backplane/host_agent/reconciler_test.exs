defmodule Backplane.HostAgent.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.{Manifest, Reconciler}

  test "missing desired skill installs" do
    manifest = %Manifest{skills: []}
    desired = [%{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents"]}]

    assert [%{action: :install, slug: "repo-review", skill: skill}] =
             Reconciler.plan(desired, manifest)

    assert skill == List.first(desired)
  end

  test "matching owned local skill noops" do
    manifest = %Manifest{
      skills: [%{slug: "repo-review", checksum: "sha256:a", targets: ["agents"], owned: true}]
    }

    desired = [%{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents"]}]

    assert [%{action: :noop, slug: "repo-review"}] = Reconciler.plan(desired, manifest)
  end

  test "checksum change updates" do
    manifest = %Manifest{
      skills: [%{slug: "repo-review", checksum: "sha256:a", targets: ["agents"], owned: true}]
    }

    desired = [%{"slug" => "repo-review", "checksum" => "sha256:b", "targets" => ["agents"]}]

    assert [%{action: :update, slug: "repo-review"}] = Reconciler.plan(desired, manifest)
  end

  test "target set change updates" do
    manifest = %Manifest{
      skills: [
        %{slug: "repo-review", checksum: "sha256:a", targets: ["agents", "codex"], owned: true}
      ]
    }

    desired = [%{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents"]}]

    assert [%{action: :update, slug: "repo-review"}] = Reconciler.plan(desired, manifest)
  end

  test "target order changes noop when sets match" do
    manifest = %Manifest{
      skills: [
        %{slug: "repo-review", checksum: "sha256:a", targets: ["codex", "agents"], owned: true}
      ]
    }

    desired = [
      %{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents", "codex"]}
    ]

    assert [%{action: :noop, slug: "repo-review"}] = Reconciler.plan(desired, manifest)
  end

  test "undesired manifest-owned skill removes" do
    manifest = %Manifest{
      skills: [%{slug: "repo-review", checksum: "sha256:a", targets: ["agents"], owned: true}]
    }

    assert [%{action: :remove, slug: "repo-review"}] = Reconciler.plan([], manifest)
  end

  test "undesired manifest skill defaults to owned and removes" do
    manifest = %Manifest{
      skills: [%{slug: "repo-review", checksum: "sha256:a", targets: ["agents"]}]
    }

    assert [%{action: :remove, slug: "repo-review"}] = Reconciler.plan([], manifest)
  end

  test "undesired manual skill noops" do
    manifest = %Manifest{
      skills: [%{slug: "manual", checksum: "sha256:m", targets: ["agents"], owned: false}]
    }

    assert [%{action: :noop, slug: "manual"}] = Reconciler.plan([], manifest)
  end
end
