defmodule Backplane.Api.SkillProtocolHttpIntegrationTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Clients
  alias Backplane.SkillProtocol.{Cache, Client, Error, Resource}
  alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource
  alias Backplane.Skills

  @blob_setting "skills.blob.local_root"
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = :ets.lookup(:backplane_settings, @blob_setting)
    previous_enabled = Application.get_env(:backplane_skills, :skill_protocol_v1_enabled)
    blob_root = Path.join(tmp_dir, "blobs")
    :ets.insert(:backplane_settings, {@blob_setting, blob_root})
    Application.put_env(:backplane_skills, :skill_protocol_v1_enabled, true)

    {:ok, server} =
      Bandit.start_link(
        plug: Backplane.Api.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0
      )

    Process.unlink(server)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      monitor = Process.monitor(server)
      ThousandIsland.stop(server)
      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 1_000
      refute Process.alive?(server)
      :ets.delete(:backplane_settings, @blob_setting)
      if previous_blob_root != [], do: :ets.insert(:backplane_settings, previous_blob_root)
      restore_enabled(previous_enabled)
    end)

    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  test "real client retains and prepares exact revisions and persists denial offline", %{
    endpoint: endpoint,
    tmp_dir: tmp_dir
  } do
    token = "skill-protocol-http-#{System.unique_integer([:positive])}"

    assert {:ok, _client_record} =
             Clients.create_client(%{
               name: token,
               token: token,
               scopes: ["skill::read"]
             })

    _catalog_peer =
      ingest!(tmp_dir, "aaa-catalog-peer", %{
        "SKILL.md" => skill_document("aaa-catalog-peer", "peer"),
        "references/guide.md" => "peer reference"
      })

    archive_a =
      archive!(tmp_dir, "opaque-http-skill-a", %{
        "SKILL.md" => skill_document("opaque-http-skill", "revision A"),
        "references/guide.md" => "reference A",
        "assets/pixel.bin" => <<0, 1, 2, 255>>,
        "scripts/run.sh" => "#!/bin/sh\nprintf 'A script source\\n'\n"
      })

    assert {:ok, skill_a} = Skills.ingest_archive(archive_a, [])

    client = client(endpoint, token)
    cache = Cache.new!(Path.join(tmp_dir, "cache"), owner: "http-integration-consumer")
    source = BackplaneSource.new!(client, cache, offline_policy: {:age_bounded, 60_000})

    assert {:ok, %{data: [page_one], next_cursor: cursor}} = Client.catalog(client, limit: 1)
    assert is_binary(cursor)

    assert {:ok, %{data: [page_two], next_cursor: nil}} =
             Client.catalog(client, limit: 1, cursor: cursor)

    assert Enum.sort([page_one.ref.skill_id, page_two.ref.skill_id]) ==
             Enum.sort(["skill/aaa-catalog-peer", skill_a.id])

    assert {:ok, manifest_a} = Client.resolve(client, skill_a.id)
    assert manifest_a.ref.skill_id == "skill/opaque-http-skill"
    assert manifest_a.ref.revision == skill_a.current_revision
    assert manifest_a.artifact_digest == manifest_a.ref.artifact_digest

    archive_b =
      archive!(tmp_dir, "opaque-http-skill-b", %{
        "SKILL.md" => skill_document("opaque-http-skill", "revision B"),
        "references/guide.md" => "reference B",
        "assets/pixel.bin" => <<9, 8, 7, 0>>,
        "scripts/run.sh" => "#!/bin/sh\nprintf 'B script source\\n'\n"
      })

    assert {:ok, skill_b} = Skills.ingest_archive(archive_b, [])
    refute skill_b.current_revision == manifest_a.ref.revision

    assert {:ok, exact_a_bytes} = Client.artifact(client, manifest_a.ref)
    assert exact_a_bytes == File.read!(archive_a)

    assert {:ok, prepared_a} =
             BackplaneSource.prepare(source, skill_a.id, manifest_a.ref.revision)

    assert prepared_a.manifest.ref == manifest_a.ref
    assert prepared_a.manifest.document_metadata["description"] == "revision A"
    assert {:ok, "reference A"} = Resource.read(prepared_a, "references/guide.md")
    assert {:ok, <<0, 1, 2, 255>>} = Resource.read(prepared_a, "assets/pixel.bin")

    assert {:ok, "#!/bin/sh\nprintf 'A script source\\n'\n"} =
             Resource.read(prepared_a, "scripts/run.sh")

    assert {:ok, manifest_b} = Client.resolve(client, skill_b.id)
    assert manifest_b.ref.revision == skill_b.current_revision
    refute manifest_b.ref.revision == manifest_a.ref.revision
    refute manifest_b.artifact_digest == manifest_a.artifact_digest

    assert {:ok, prepared_b} =
             BackplaneSource.prepare(source, skill_b.id, manifest_b.ref.revision)

    refute prepared_b.root == prepared_a.root
    assert prepared_b.manifest.document_metadata["description"] == "revision B"
    assert {:ok, "reference B"} = Resource.read(prepared_b, "references/guide.md")
    assert {:ok, <<9, 8, 7, 0>>} = Resource.read(prepared_b, "assets/pixel.bin")

    assert {:ok, disabled} = Skills.update(skill_b, %{enabled: false})

    assert {:error, %Error{code: :revision_unavailable, retryable: false}} =
             BackplaneSource.prepare(source, disabled.id, manifest_a.ref.revision)

    offline_client = client("http://127.0.0.1:1", token)

    offline_source =
      BackplaneSource.new!(offline_client, cache, offline_policy: {:age_bounded, 60_000})

    assert {:error, %Error{code: :revision_unavailable, retryable: false}} =
             BackplaneSource.prepare(offline_source, disabled.id, manifest_a.ref.revision)
  end

  defp client(endpoint, token) do
    Client.new!(
      endpoint: endpoint,
      source_id: "backplane-http-integration",
      access_context_id: "client:skill-protocol-http-integration",
      credential_supplier: fn -> token end,
      max_attempts: 1
    )
  end

  defp ingest!(tmp_dir, fixture, files) do
    path = archive!(tmp_dir, fixture, files)
    assert {:ok, skill} = Skills.ingest_archive(path, [])
    skill
  end

  defp archive!(tmp_dir, fixture, files) do
    root = files |> Map.fetch!("SKILL.md") |> document_name()
    path = Path.join(tmp_dir, "#{fixture}.tar.gz")

    entries =
      Enum.map(files, fn {relative, bytes} ->
        {String.to_charlist(Path.join(root, relative)), bytes}
      end)

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end

  defp skill_document(name, description) do
    """
    ---
    name: #{name}
    description: #{description}
    tags: [protocol, integration]
    ---

    # #{name}
    """
  end

  defp document_name(document) do
    [_, name] = Regex.run(~r/^name: ([^\n]+)$/m, document)
    name
  end

  defp restore_enabled(nil),
    do: Application.delete_env(:backplane_skills, :skill_protocol_v1_enabled)

  defp restore_enabled(value),
    do: Application.put_env(:backplane_skills, :skill_protocol_v1_enabled, value)
end
