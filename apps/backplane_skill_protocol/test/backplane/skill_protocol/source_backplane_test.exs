defmodule Backplane.SkillProtocol.Source.BackplaneTest do
  use ExUnit.Case, async: true

  import Backplane.SkillProtocol.ArchiveHelpers

  alias Backplane.SkillProtocol.{Bundle, Client, Error, Resource, SkillRef, Wire}
  alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource

  @moduletag :tmp_dir

  test "catalog forwards search and paging without downloading a bundle" do
    parent = self()

    transport = fn request ->
      send(parent, {:request, request.url})

      {:ok,
       %{
         status: 200,
         headers: %{},
         body: JSON.encode!(%{"protocol_version" => "1", "data" => [], "next_cursor" => "next"})
       }}
    end

    source = BackplaneSource.new!(client(transport))

    assert {:ok, %{data: [], next_cursor: "next"}} =
             BackplaneSource.catalog(source, q: "deploy", limit: 10, cursor: "page-1")

    assert_receive {:request, url}
    assert URI.parse(url).path == "/skill-protocol/v1/catalog"

    assert URI.decode_query(URI.parse(url).query) == %{
             "cursor" => "page-1",
             "limit" => "10",
             "q" => "deploy"
           }

    refute_receive {:request, _url}
  end

  test "one-shot prepare returns the complete bundle without executing scripts", %{
    tmp_dir: tmp_dir
  } do
    {manifest, bytes} = bundle_fixture(tmp_dir)

    source =
      BackplaneSource.new!(
        client(sequence([manifest_response(manifest), artifact_response(bytes)]))
      )

    destination = Path.join(tmp_dir, "prepared")

    assert {:ok, prepared} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: destination)

    assert prepared.root == Path.expand(destination)
    assert prepared.manifest == manifest
    assert {:ok, skill_md()} == Resource.read(prepared, "SKILL.md")
    assert {:ok, "guide"} == Resource.read(prepared, "references/guide.md")
    assert {:ok, <<0, 1, 2, 255>>} == Resource.read(prepared, "assets/pixel.bin")
    assert {:ok, "#!/bin/sh\necho must-not-run\n"} == Resource.read(prepared, "scripts/run.sh")
    refute File.exists?(Path.join(tmp_dir, "must-not-run"))
  end

  test "each use downloads again and a later remote error does not reuse earlier content", %{
    tmp_dir: tmp_dir
  } do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    responses = [
      manifest_response(manifest),
      artifact_response(bytes),
      manifest_response(manifest),
      artifact_response(bytes),
      {:ok, %{status: 503, headers: %{}, body: error_json("temporarily_unavailable", true)}}
    ]

    source =
      BackplaneSource.new!(client(sequence(responses, calls), max_attempts: 1))

    first = Path.join(tmp_dir, "first")
    second = Path.join(tmp_dir, "second")
    third = Path.join(tmp_dir, "third")

    assert {:ok, prepared_first} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: first)

    assert {:ok, _prepared_second} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: second)

    assert {:error, %Error{code: :temporarily_unavailable}} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: third)

    assert {:ok, "guide"} == Resource.read(prepared_first, "references/guide.md")
    refute File.exists?(third)

    paths = Agent.get(calls, &Enum.reverse/1)
    assert Enum.count(paths, &(&1 == "/skill-protocol/v1/resolve")) == 3
    assert Enum.count(paths, &(&1 == "/skill-protocol/v1/artifact")) == 2
  end

  test "manifest disagreement and cancellation expose no prepared destination", %{
    tmp_dir: tmp_dir
  } do
    {manifest, bytes} = bundle_fixture(tmp_dir)

    mismatched = %{
      manifest
      | document_metadata: Map.put(manifest.document_metadata, "description", "changed")
    }

    mismatch_destination = Path.join(tmp_dir, "mismatch")

    mismatch_source =
      BackplaneSource.new!(
        client(sequence([manifest_response(mismatched), artifact_response(bytes)]))
      )

    assert {:error, %Error{code: :integrity_mismatch}} =
             BackplaneSource.prepare(mismatch_source, "opaque/id", "r1",
               destination: mismatch_destination
             )

    refute File.exists?(mismatch_destination)

    cancelled_destination = Path.join(tmp_dir, "cancelled")

    cancelled_source =
      BackplaneSource.new!(
        client(sequence([manifest_response(manifest), artifact_response(bytes)]))
      )

    assert {:error, %Error{code: :cancelled}} =
             BackplaneSource.prepare(cancelled_source, "opaque/id", "r1",
               destination: cancelled_destination,
               cancelled?: fn -> true end
             )

    refute File.exists?(cancelled_destination)
  end

  test "destination is required, must be fresh, and leaves existing files untouched", %{
    tmp_dir: tmp_dir
  } do
    untouched = Path.join(tmp_dir, "existing")
    File.mkdir!(untouched)
    marker = Path.join(untouched, "marker")
    File.write!(marker, "untouched")
    dangling = Path.join(tmp_dir, "dangling")
    File.ln_s!(Path.join(tmp_dir, "missing-target"), dangling)
    source = BackplaneSource.new!(client(fn _request -> flunk("network must not run") end))

    assert {:error, %Error{code: :invalid_request}} =
             BackplaneSource.prepare(source, "opaque/id", "r1")

    assert {:error, %Error{code: :invalid_request}} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: untouched)

    assert {:error, %Error{code: :invalid_request}} =
             BackplaneSource.prepare(source, "opaque/id", "r1", destination: dangling)

    assert {:error, %Error{code: :invalid_request}} =
             BackplaneSource.prepare(source, "opaque/id", "r1",
               destination: Path.join([tmp_dir, "missing-parent", "prepared"])
             )

    assert File.read!(marker) == "untouched"
  end

  defp bundle_fixture(tmp_dir) do
    archive =
      archive!(
        tmp_dir,
        [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/references/guide.md", "guide"},
          {"example-skill/assets/pixel.bin", <<0, 1, 2, 255>>},
          {"example-skill/scripts/run.sh", "#!/bin/sh\necho must-not-run\n"}
        ],
        "remote.tar.gz"
      )

    bytes = File.read!(archive)
    ref = %SkillRef{source_id: "source-a", skill_id: "opaque/id", revision: "r1"}
    assert {:ok, bundle} = Bundle.inspect(archive, ref: ref)
    {bundle.manifest, bytes}
  end

  defp client(transport, opts \\ []) do
    Client.new!(
      Keyword.merge(
        [
          endpoint: "https://backplane.example",
          source_id: "source-a",
          access_context_id: "tenant-a",
          credential_supplier: fn -> nil end,
          retry_delays_ms: [0, 0],
          transport: transport
        ],
        opts
      )
    )
  end

  defp manifest_response(manifest),
    do: {:ok, %{status: 200, headers: %{}, body: JSON.encode!(Wire.manifest_map(manifest))}}

  defp artifact_response(bytes), do: {:ok, %{status: 200, headers: %{}, body: bytes}}

  defp error_json(code, retryable) do
    JSON.encode!(%{
      "protocol_version" => "1",
      "error" => %{
        "code" => code,
        "message" => code,
        "retryable" => retryable,
        "context" => %{}
      }
    })
  end

  defp sequence(responses, calls \\ nil) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    fn request ->
      if calls, do: Agent.update(calls, &[URI.parse(request.url).path | &1])
      Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
    end
  end
end
