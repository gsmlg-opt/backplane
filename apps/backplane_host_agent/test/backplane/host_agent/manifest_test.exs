defmodule Backplane.HostAgent.ManifestTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Manifest

  @tag :tmp_dir
  test "missing manifest reads as empty manifest", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing/manifest.json")

    assert {:ok, %Manifest{schema_version: 1, machine_name: "t430", skills: []}} =
             Manifest.read(path, "t430")
  end

  @tag :tmp_dir
  test "writes and reads manifest skills", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "state/manifest.json")

    manifest = %Manifest{
      machine_name: "t430",
      updated_at: "2026-05-22T00:00:00Z",
      skills: [
        %{
          name: "Agent Tools",
          slug: "agent-tools",
          version: "1.0.0",
          checksum: "sha256:abc",
          targets: ["agents"],
          owned: true,
          installed_at: "2026-05-22T00:00:00Z"
        }
      ]
    }

    assert :ok = Manifest.write(path, manifest)

    assert {:ok,
            %Manifest{
              machine_name: "t430",
              updated_at: updated_at,
              skills: [
                %{
                  slug: "agent-tools",
                  owned: true
                }
              ]
            }} = Manifest.read(path, "t430")

    assert is_binary(updated_at)
  end

  @tag :tmp_dir
  test "rejects non-object manifest JSON", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "state/manifest.json")
    File.mkdir_p!(Path.dirname(path))

    for json <- ["[]", "null", "1", "\"value\"", "true"] do
      File.write!(path, json)

      assert {:error, {:manifest_read_error, message}} = Manifest.read(path, "t430")
      assert is_binary(message)
    end
  end

  test "public facade delegates to worker", _context do
    assert {:error, :not_configured} = Backplane.HostAgent.sync_now()

    assert %{
             last_sync: nil,
             last_error: :not_configured
           } = Backplane.HostAgent.status()
  end
end
