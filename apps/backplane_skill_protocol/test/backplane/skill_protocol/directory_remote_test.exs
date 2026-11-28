defmodule Backplane.SkillProtocol.DirectoryRemoteTest do
  use ExUnit.Case, async: false

  import Backplane.SkillProtocol.ArchiveHelpers

  alias Backplane.SkillProtocol.{Bundle, Client, Directory, SkillRef, Wire}
  alias Backplane.SkillProtocol.Source.Backplane
  alias HTTP.WebSocket.Event

  defmodule TestWebSocket do
    def new(url, [], opts) do
      socket = %HTTP.WebSocket{pid: self(), ref: make_ref(), url: url}
      send(__MODULE__.Receiver, {:socket, socket, opts[:headers]})
      socket
    end

    def close(_socket), do: :ok
  end

  @tag :tmp_dir
  test "prefetches only Always return and retains verified resources offline", %{tmp_dir: root} do
    fixtures =
      [alpha, beta, search_only] =
      Enum.map(["alpha", "beta", "search-only"], &fixture(root, &1, "r1"))

    alpha_content = alpha.content
    outside_content = search_only.content

    {directory, socket, options} = initialize(fixtures)
    publish(socket, Map.put(snapshot("g1", [alpha, beta]), "search_categories", ["Android 调试"]))
    ready = await(directory, :one, &(&1.status == :ready))
    assert Enum.map(ready.automatic, & &1.name) == ["alpha", "beta"]
    assert ready.sources["cloud"].search_categories == ["Android 调试"]

    # No read has been requested. Registration initiates both complete bundle downloads.
    assert_loaded(alpha.ref)
    assert_loaded(beta.ref)

    assert {:ok, %{content: ^alpha_content, availability: :online}} =
             Directory.read_remote(directory, :one, alpha.ref)

    assert {:ok, %{content: "guide"}} =
             Directory.read_remote(directory, :two, beta.ref, "references/guide.md")

    refute_received {:http, _, _, _}

    publish(socket, %{
      "type" => "search_categories",
      "generation" => "g1",
      "search_categories" => ["Android 调试", "iOS 调试"]
    })

    guidance = await(directory, :one, &(&1.revision > ready.revision))
    assert guidance.sources["cloud"].search_categories == ["Android 调试", "iOS 调试"]
    assert guidance.sources["cloud"].generation == "g1"
    assert {:ok, %{content: ^alpha_content}} = Directory.read_remote(directory, :one, alpha.ref)
    refute_received {:http, _, _, _}

    send(socket.pid, {HTTP.WebSocket, socket, %Event.Close{code: 1006}})
    offline = await(directory, :one, &(&1.status == :degraded))
    assert %{status: :stale, notifications: :offline, generation: "g1"} = offline.sources["cloud"]
    assert Enum.map(offline.explicit, & &1.name) == ["alpha", "beta"]

    assert {:ok, %{content: ^alpha_content, availability: :offline}} =
             Directory.read_remote(directory, :one, alpha.ref)

    assert {:ok, %{content: "guide", availability: :offline}} =
             Directory.read_remote(directory, :two, beta.ref, "references/guide.md")

    assert {:error, %{code: :temporarily_unavailable}} =
             Directory.read_remote(directory, :one, search_only.ref)

    refute_received {:http, _, _, _}

    assert_receive {:socket, connected, _}, 2_000
    assert URI.decode_query(URI.parse(connected.url).query) == %{"generation" => "g1"}
    publish(connected, %{"type" => "unchanged", "generation" => "g1"})
    restored = await(directory, :one, &(&1.status == :ready))
    assert %{status: :ready, notifications: :online} = restored.sources["cloud"]

    assert {:ok, %{content: ^alpha_content, availability: :online}} =
             Directory.read_remote(directory, :one, alpha.ref)

    refute_received {:http, _, _, _}

    assert {:ok, %{content: ^outside_content}} =
             Directory.read_remote(directory, :one, search_only.ref)

    assert_loaded(search_only.ref)
    refute_received {:http, _, _, _}

    # A confirmed denial revokes offline access as well.
    send(connected.pid, {HTTP.WebSocket, connected, %Event.Close{code: 1008}})
    denied = await(directory, :one, &(&1.sources["cloud"].notifications == :denied))
    assert denied.explicit == []
    assert {:error, _} = Directory.read_remote(directory, :one, alpha.ref)
    assert Agent.get(options, & &1.catalog) == %{}
  end

  @tag :tmp_dir
  test "one notification reloads one descriptor and leaves other cached skills intact", %{
    tmp_dir: root
  } do
    alpha = fixture(root, "alpha", "r1")
    newer = fixture(root, "alpha", "r2")
    beta = fixture(root, "beta", "r1")
    outside = fixture(root, "outside", "r1")
    {directory, socket, options} = initialize([alpha, newer, beta, outside])
    newer_content = newer.content
    beta_content = beta.content
    publish(socket, snapshot("g1", [alpha, beta]))
    await(directory, :one, &(&1.status == :ready))
    assert_loaded(alpha.ref)
    assert_loaded(beta.ref)
    assert {:ok, _} = Directory.read_remote(directory, :one, beta.ref)

    set_catalog(options, [newer])
    publish(socket, changed("g1", "g2", ["alpha"]))
    assert_receive {:http, "catalog/entry", "alpha", nil}

    updated =
      await(directory, :one, &Enum.any?(&1.automatic, fn entry -> entry.ref == newer.ref end))

    assert Enum.map(updated.automatic, & &1.ref) == [newer.ref, beta.ref]
    assert_loaded(newer.ref)
    assert {:ok, %{content: ^newer_content}} = Directory.read_remote(directory, :one, newer.ref)
    assert {:ok, %{content: ^beta_content}} = Directory.read_remote(directory, :one, beta.ref)
    refute_received {:http, _, _, _}

    publish(socket, changed("g2", "g3", ["outside"]))
    assert_receive {:http, "catalog/entry", "outside", nil}
    latest = await(directory, :one, &(&1.sources["cloud"].generation == "g3"))
    assert Enum.map(latest.automatic, & &1.ref) == [newer.ref, beta.ref]
    refute_received {:http, _, _, _}

    publish(socket, changed("g3", "g4", ["beta"]))
    assert_receive {:http, "catalog/entry", "beta", nil}
    removed = await(directory, :one, &(&1.sources["cloud"].generation == "g4"))
    assert [%{ref: ref}] = removed.automatic
    assert ref == newer.ref
    refute_received {:http, _, _, _}
  end

  defp fixture(root, name, revision) do
    content = skill_md(name) <> "\n" <> revision

    archive =
      archive!(
        root,
        [{name <> "/SKILL.md", content}, {name <> "/references/guide.md", "guide"}],
        "#{name}-#{revision}.tar.gz"
      )

    {:ok, bundle} =
      Bundle.inspect(archive,
        ref: %SkillRef{source_id: "cloud", skill_id: name, revision: revision}
      )

    %{
      ref: bundle.manifest.ref,
      content: content,
      manifest: JSON.encode!(Wire.manifest_map(bundle.manifest)),
      artifact: File.read!(archive)
    }
  end

  defp initialize(fixtures) do
    Process.register(self(), TestWebSocket.Receiver)
    parent = self()
    options = start_supervised!({Agent, fn -> %{catalog: %{}} end})
    bundles = Map.new(fixtures, &{{&1.ref.skill_id, &1.ref.revision}, &1})

    source =
      Backplane.new!(
        Client.new!(
          endpoint: "https://example.test",
          source_id: "cloud",
          access_context_id: "agent",
          credential_supplier: fn -> "fixture-token" end,
          transport: fn request ->
            assert request.headers["authorization"] == "Bearer fixture-token"
            uri = URI.parse(request.url)
            operation = String.replace_prefix(uri.path, "/skill-protocol/v1/", "")
            %{"skill_id" => id} = params = URI.decode_query(uri.query || "")
            revision = params["revision"]
            send(parent, {:http, operation, id, revision})

            case operation do
              "resolve" ->
                ok(bundles[{id, revision}].manifest)

              "artifact" ->
                ok(bundles[{id, revision}].artifact)

              "catalog/entry" ->
                entries = Agent.get(options, &Map.get(&1.catalog, id, []))
                ok(JSON.encode!(catalog(entries)))
            end
          end
        )
      )

    directory = start_supervised!({Directory, websocket: TestWebSocket})
    sources = [{"cloud", source}]
    assert :ok = Directory.register_scope(directory, :one, sources: sources)
    assert :ok = Directory.register_scope(directory, :two, sources: sources)
    assert {:ok, %{status: :warming}} = Directory.subscribe(directory, :one)
    assert {:ok, %{status: :warming}} = Directory.subscribe(directory, :two)
    assert_receive {:socket, socket, [{"authorization", "Bearer fixture-token"}]}
    assert socket.url == "wss://example.test/skill-protocol/v1/events"
    refute_received {:socket, _, _}
    {directory, socket, options}
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}

  defp set_catalog(options, entries) do
    Agent.update(options, fn state ->
      %{state | catalog: Map.new(entries, &{&1.ref.skill_id, [&1]})}
    end)
  end

  defp assert_loaded(%SkillRef{skill_id: id, revision: revision}) do
    assert_receive {:http, "resolve", ^id, ^revision}
    assert_receive {:http, "artifact", ^id, ^revision}
  end

  defp publish(socket, value),
    do: send(socket.pid, {HTTP.WebSocket, socket, %Event.Message{data: JSON.encode!(value)}})

  defp changed(previous, generation, ids),
    do: %{
      "type" => "changed",
      "previous_generation" => previous,
      "generation" => generation,
      "skill_ids" => ids
    }

  defp snapshot(generation, entries),
    do: %{"type" => "snapshot", "generation" => generation, "catalog" => catalog(entries)}

  defp catalog(entries) do
    %{
      "protocol_version" => "1",
      "view" => "always",
      "next_cursor" => nil,
      "data" =>
        Enum.map(entries, fn %{ref: ref} ->
          %{
            "skill_id" => ref.skill_id,
            "name" => ref.skill_id,
            "description" => "A fixture",
            "revision" => ref.revision,
            "artifact_digest" => ref.artifact_digest,
            "publication_status" => "ready",
            "disable_model_invocation" => false
          }
        end)
    }
  end

  defp await(directory, scope, matches?) do
    assert {:ok, snapshot} = Directory.snapshot(directory, scope)

    if matches?.(snapshot) do
      snapshot
    else
      assert_receive {:skill_directory_updated, ^directory, ^scope, _}, 3_000
      await(directory, scope, matches?)
    end
  end
end
