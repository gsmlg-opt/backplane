defmodule Backplane.Api.SkillProtocolEventsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.{Clients, Settings}
  alias Backplane.SkillProtocol.{Client, Directory}
  alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource
  alias Backplane.Skills
  alias Backplane.Skills.{ProtocolChanges, Revision, SearchCategories, Skill}
  alias HTTP.{ClientCompletion, WebSocket}
  alias HTTP.WebSocket.Event

  @digest "sha256:" <> String.duplicate("a", 64)

  setup tags do
    if tags[:committed] do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, sandbox: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    else
      BackplaneDataCase.setup_sandbox(Repo, tags)
    end

    Backplane.Endpoints.Cache.clear()
    :ok
  end

  @tag :tmp_dir
  @tag :committed
  test "the package directory warms over the real socket and reuses a prepared remote skill", %{
    tmp_dir: tmp_dir
  } do
    setting = "skills.blob.local_root"
    previous = :ets.lookup(:backplane_settings, setting)
    :ets.insert(:backplane_settings, {setting, Path.join(tmp_dir, "blobs")})

    on_exit(fn ->
      :ets.delete(:backplane_settings, setting)
      if previous != [], do: :ets.insert(:backplane_settings, previous)
    end)

    content = "---\nname: live-skill\ndescription: Live skill\n---\nBody"
    archive = Path.join(tmp_dir, "live.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(archive), [{~c"live-skill/SKILL.md", content}], [
        :compressed
      ])

    assert {:ok, skill} = Skills.ingest_archive(archive, [])
    assert {:ok, :saved} = Skills.set_always_return(%{skill.id => true})

    {:ok, client_record, token} =
      Clients.issue_client(%{name: "directory-reader", scopes: ["skill::read"]})

    on_exit(fn ->
      ids = [skill.id, "skill/live-second"]

      Repo.transaction(fn ->
        Repo.delete_all(from(s in Skill, where: s.id in ^ids))
      end)

      Clients.delete_client(client_record)
    end)

    endpoint =
      start_endpoint()
      |> URI.parse()
      |> then(&URI.to_string(%{&1 | scheme: "http", path: nil}))

    client =
      Client.new!(
        endpoint: endpoint,
        source_id: "live",
        access_context_id: "directory-reader",
        credential_supplier: fn -> token end
      )

    parent = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :skill_protocol, :operation],
        &__MODULE__.capture_request/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    directory = start_supervised!({Directory, []}, id: :live_directory)

    assert :ok =
             Directory.register_scope(directory, :repo,
               sources: [{"live", BackplaneSource.new!(client)}]
             )

    assert {:ok, _initial} = Directory.subscribe(directory, :repo)
    ready = await_directory(directory, &(&1.status == :ready))
    assert [%{name: "live-skill", ref: ref}] = ready.explicit
    assert ref.revision == skill.current_revision

    assert {:ok, %{content: ^content, manifest: manifest}} =
             Directory.read_remote(directory, :repo, ref)

    assert {:ok, %{content: ^content, manifest: ^manifest}} =
             Directory.read_remote(directory, :repo, ref)

    assert_received {:client_operation, :resolve}
    assert_received {:client_operation, :artifact}
    refute_received {:client_operation, :resolve}
    refute_received {:client_operation, :artifact}
    refute_received {:client_operation, :catalog}

    second_content = "---\nname: live-second\ndescription: Second skill\n---\nSecond body"
    second_archive = Path.join(tmp_dir, "second.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(second_archive),
        [{~c"live-second/SKILL.md", second_content}],
        [:compressed]
      )

    assert {:ok, second} =
             Repo.transaction(fn ->
               {:ok, second} = Skills.ingest_archive(second_archive, [])
               {:ok, :saved} = Skills.set_always_return(%{second.id => true})
               second
             end)

    changed = await_directory(directory, &(length(&1.explicit) == 2))
    second_ref = Enum.find(changed.explicit, &(&1.ref.skill_id == second.id)).ref

    assert {:ok, %{content: ^second_content}} =
             Directory.read_remote(directory, :repo, second_ref)

    assert_received {:client_operation, :catalog_entry}
    assert_received {:client_operation, :resolve}
    assert_received {:client_operation, :artifact}
    refute_received {:client_operation, :resolve}
    refute_received {:client_operation, :artifact}
    refute_received {:client_operation, :catalog}

    assert {:ok, %{content: ^content, manifest: ^manifest}} =
             Directory.read_remote(directory, :repo, ref)

    refute_received {:client_operation, :resolve}
    refute_received {:client_operation, :artifact}

    assert {:ok, _} = Clients.revoke_client_token(client_record)
    Phoenix.PubSub.broadcast(Backplane.PubSub, ProtocolChanges.topic(), :skill_protocol_changed)

    assert %{status: :degraded, explicit: []} =
             await_directory(directory, &(&1.status == :degraded and &1.explicit == []))

    assert {:error, _} = Directory.read_remote(directory, :repo, ref)
  end

  def capture_request(_event, _measurements, %{phase: :client, operation: operation}, parent),
    do: send(parent, {:client_operation, operation})

  def capture_request(_event, _measurements, _metadata, _parent), do: :ok

  defp await_directory(directory, condition) do
    assert {:ok, snapshot} = Directory.snapshot(directory, :repo)

    if condition.(snapshot) do
      snapshot
    else
      assert_receive {:skill_directory_updated, ^directory, :repo, _}, 5_000
      await_directory(directory, condition)
    end
  end

  test "one snapshot contains more than one HTTP page and reconnect sends unchanged" do
    {:ok, _client, token} = Clients.issue_client(%{name: "skill-events", scopes: ["skill::read"]})
    insert_skills(105)
    url = start_endpoint()
    socket = connect(url, token)
    on_exit(fn -> cleanup(socket) end)

    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 5_000

    assert %{
             "type" => "snapshot",
             "generation" => generation,
             "catalog" => %{
               "protocol_version" => "1",
               "view" => "always",
               "next_cursor" => nil,
               "data" => descriptors
             }
           } = JSON.decode!(bytes)

    assert length(descriptors) == 105
    assert Enum.all?(descriptors, &(&1["argument_hint"] == "PATH"))
    assert Enum.all?(descriptors, &(&1["artifact_digest"] == @digest))

    reconnect = connect(url <> "?generation=" <> URI.encode_www_form(generation), token)
    on_exit(fn -> cleanup(reconnect) end)
    assert_receive {WebSocket, ^reconnect, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^reconnect, %Event.Message{data: unchanged}}, 5_000

    assert JSON.decode!(unchanged) ==
             %{"type" => "unchanged", "generation" => generation, "search_categories" => []}

    assert_receive {WebSocket, ^socket, %Event.Message{data: heartbeat}}, 16_000
    assert JSON.decode!(heartbeat) == %{"type" => "heartbeat", "generation" => generation}
  end

  test "scope denial rejects upgrade and revocation closes an established connection" do
    {:ok, _client, wrong_token} =
      Clients.issue_client(%{name: "llm-only-events", scopes: ["llm::invoke"]})

    {:ok, client, token} = Clients.issue_client(%{name: "reader-events", scopes: ["skill::read"]})
    url = start_endpoint()
    denied = connect(url, wrong_token)
    on_exit(fn -> cleanup(denied) end)
    assert_receive {WebSocket, ^denied, %Event.Error{handshake: %{status: 403}}}, 5_000

    socket = connect(url, token)
    on_exit(fn -> cleanup(socket) end)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 5_000
    assert {:ok, _} = Clients.revoke_client_token(client)
    Phoenix.PubSub.broadcast(Backplane.PubSub, ProtocolChanges.topic(), :skill_protocol_changed)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
  end

  @tag :committed
  test "changing one skill sends only its ID and reconnect resumes that delta" do
    {:ok, client, token} =
      Clients.issue_client(%{name: "changes-reader", scopes: ["skill::read"]})

    on_exit(fn ->
      Repo.transaction(fn ->
        Repo.delete_all(from(s in Skill, where: s.id in ["events/skill-1", "events/skill-2"]))
      end)

      Clients.delete_client(client)
    end)

    assert {:ok, _} = Repo.transaction(fn -> insert_skills(2) end)
    url = start_endpoint()
    socket = connect(url, token)
    on_exit(fn -> cleanup(socket) end)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 5_000
    first = JSON.decode!(bytes)
    assert [one, _two] = first["catalog"]["data"]

    Repo.update_all(from(s in Skill, where: s.id == ^one["skill_id"]),
      set: [always_return: false]
    )

    Phoenix.PubSub.broadcast(Backplane.PubSub, ProtocolChanges.topic(), :skill_protocol_changed)
    assert_receive {WebSocket, ^socket, %Event.Message{data: updated}}, 5_000
    second = JSON.decode!(updated)
    assert second["type"] == "changed"
    assert second["previous_generation"] == first["generation"]
    assert second["generation"] != first["generation"]
    assert second["skill_ids"] == [one["skill_id"]]
    refute Map.has_key?(second, "catalog")

    reconnect = connect(url <> "?generation=" <> URI.encode_www_form(first["generation"]), token)
    on_exit(fn -> cleanup(reconnect) end)
    assert_receive {WebSocket, ^reconnect, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^reconnect, %Event.Message{data: replay}}, 5_000
    assert JSON.decode!(replay) == second
    assert_receive {WebSocket, ^reconnect, %Event.Message{data: metadata}}, 5_000

    assert JSON.decode!(metadata) ==
             %{
               "type" => "search_categories",
               "generation" => second["generation"],
               "search_categories" => []
             }
  end

  test "search category edits publish metadata and reconnect includes it without a skill change" do
    key = SearchCategories.key()
    previous = :ets.lookup(:backplane_settings, key)

    on_exit(fn ->
      :ets.delete(:backplane_settings, key)
      if previous != [], do: :ets.insert(:backplane_settings, previous)
    end)

    {:ok, _client, token} =
      Clients.issue_client(%{name: "category-reader", scopes: ["skill::read"]})

    assert :ok = Settings.set(key, ["Android debugging"])
    url = start_endpoint()
    socket = connect(url, token)
    on_exit(fn -> cleanup(socket) end)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 5_000

    assert %{
             "type" => "snapshot",
             "generation" => generation,
             "search_categories" => ["Android debugging"]
           } = JSON.decode!(bytes)

    assert :ok = Settings.set(key, ["Android debugging", "iOS debugging"])
    assert_receive {WebSocket, ^socket, %Event.Message{data: metadata}}, 5_000

    assert JSON.decode!(metadata) == %{
             "type" => "search_categories",
             "generation" => generation,
             "search_categories" => ["Android debugging", "iOS debugging"]
           }

    assert {:ok, ^generation} = ProtocolChanges.current()
    refute_receive {WebSocket, ^socket, %Event.Message{}}, 50

    reconnect = connect(url <> "?generation=" <> URI.encode_www_form(generation), token)
    on_exit(fn -> cleanup(reconnect) end)
    assert_receive {WebSocket, ^reconnect, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^reconnect, %Event.Message{data: unchanged}}, 5_000

    assert JSON.decode!(unchanged) == %{
             "type" => "unchanged",
             "generation" => generation,
             "search_categories" => ["Android debugging", "iOS debugging"]
           }
  end

  test "an authorization change resets the source snapshot for a permitted reader" do
    {:ok, client, token} = Clients.issue_client(%{name: "reset-reader", scopes: ["skill::read"]})
    insert_skills(1)
    url = start_endpoint()
    socket = connect(url, token)
    on_exit(fn -> cleanup(socket) end)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 5_000
    first = JSON.decode!(bytes)
    assert {:ok, _} = Clients.update_client(client, %{scopes: ["skill::*"]})
    Phoenix.PubSub.broadcast(Backplane.PubSub, ProtocolChanges.topic(), :skill_protocol_changed)
    assert_receive {WebSocket, ^socket, %Event.Message{data: updated}}, 5_000
    second = JSON.decode!(updated)
    assert second["type"] == "snapshot"
    assert second["generation"] != first["generation"]
    assert second["catalog"] == first["catalog"]
  end

  test "an open source closes when a new client protects anonymous reads" do
    url = start_endpoint()
    socket = WebSocket.new(url, [], http_version: :http1, mode: :browser)
    on_exit(fn -> cleanup(socket) end)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 5_000
    assert %{"type" => "snapshot", "catalog" => %{"data" => []}} = JSON.decode!(bytes)

    assert {:ok, _client} =
             Clients.create_client(%{name: "protect-skills", scopes: ["skill::read"]})

    Phoenix.PubSub.broadcast(Backplane.PubSub, ProtocolChanges.topic(), :skill_protocol_changed)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
  end

  defp insert_skills(count) do
    now = DateTime.utc_now()

    for number <- 1..count do
      id = "events/skill-#{number}"
      revision = "r-" <> String.duplicate("a", 64)

      Repo.insert_all(Skill, [
        %{
          id: id,
          slug: "event-skill-#{number}",
          name: "event-skill-#{number}",
          content: "Body",
          always_return: true,
          enabled: true,
          current_revision: revision,
          publication_status: "ready",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all(Revision, [
        %{
          skill_id: id,
          revision: revision,
          artifact_digest: @digest,
          manifest: %{
            "document_metadata" => %{
              "name" => "event-skill-#{number}",
              "description" => "Skill #{number}",
              "argument-hint" => "PATH"
            }
          },
          blob_ref: "sha256/" <> String.duplicate("a", 64) <> ".tar.gz",
          published_at: now,
          inserted_at: now
        }
      ])
    end
  end

  defp start_endpoint do
    endpoint =
      start_supervised!({Gaoxy.HTTP, plug: {Backplane.Api.Endpoint, []}, port: 0},
        id: :skill_events_endpoint
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(endpoint, :http)
    "ws://127.0.0.1:#{port}/skill-protocol/v1/events"
  end

  defp connect(url, token) do
    WebSocket.new(url, [],
      http_version: :http1,
      mode: :browser,
      headers: [{"authorization", "Bearer " <> token}]
    )
  end

  defp cleanup(socket) do
    WebSocket.close(socket)
    ClientCompletion.await(WebSocket.completion(socket), 1_000)
  end
end
