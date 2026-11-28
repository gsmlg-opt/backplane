defmodule Backplane.Skills.ProtocolChangesTest do
  use BackplaneSkills.DataCase, async: false

  alias Backplane.Clients.Client
  alias Backplane.Skills.{ProtocolChanges, Revision, Skill}

  test "durable deltas coalesce skill and revision mutations in a transaction" do
    initial = current()
    first = insert_skill!("delta-first")
    second = insert_skill!("delta-second")
    after_insert = current()

    assert {:ok, %{generation: ^after_insert, skill_ids: ["delta-first", "delta-second"]}} =
             ProtocolChanges.since(initial)

    hash = String.duplicate("a", 64)

    published =
      Repo.insert!(%Revision{
        skill_id: first.id,
        revision: "r-" <> hash,
        artifact_digest: "sha256:" <> hash,
        manifest: %{},
        blob_ref: "sha256/" <> hash <> ".tar.gz",
        published_at: DateTime.utc_now()
      })

    Repo.delete!(published)
    second |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    Repo.delete!(second)
    latest = current()

    assert {:ok, %{generation: ^latest, skill_ids: ["delta-first", "delta-second"]}} =
             ProtocolChanges.since(initial)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM skill_protocol_changes WHERE previous_generation::text = $1",
               [initial]
             )

    assert %{rows: [[^latest, ["delta-first", "delta-second"], false]]} =
             Repo.query!(
               """
               SELECT generation::text, skill_ids, reset FROM skill_protocol_changes
               WHERE previous_generation::text = $1
               """,
               [initial]
             )
  end

  test "unchanged generations have no delta and unknown history requires reset" do
    initial = current()
    assert {:ok, %{generation: ^initial, skill_ids: []}} = ProtocolChanges.since(initial)
    assert {:reset, ^initial} = ProtocolChanges.since(Ecto.UUID.generate())
    assert {:reset, ^initial} = ProtocolChanges.since(nil)
  end

  test "authorization changes require reset even when the transaction also changes skills" do
    initial = current()
    insert_skill!("delta-auth")
    Repo.insert!(%Client{name: "delta-auth", scopes: ["skill::read"]})
    latest = current()
    assert {:reset, ^latest} = ProtocolChanges.since(initial)
  end

  test "large skill batches bound their retained IDs and require reset" do
    initial = current()
    now = DateTime.utc_now()

    rows =
      for number <- 1..513 do
        id = "delta-bound-#{number}"
        %{id: id, slug: id, name: id, content: "Body", inserted_at: now, updated_at: now}
      end

    assert {513, _} = Repo.insert_all(Skill, rows)
    latest = current()
    assert {:reset, ^latest} = ProtocolChanges.since(initial)

    assert %{rows: [[[], true]]} =
             Repo.query!(
               "SELECT skill_ids, reset FROM skill_protocol_changes WHERE generation::text = $1",
               [latest]
             )
  end

  test "generation changes for skill visibility and publication changes but remains stable for no-op writes" do
    before = current()

    skill =
      Repo.insert!(%Skill{
        id: "protocol-generation",
        slug: "protocol-generation",
        name: "generation",
        content: "Body"
      })

    inserted = current()
    assert inserted != before

    skill |> Ecto.Changeset.change(always_return: true) |> Repo.update!()
    selected = current()
    assert selected != inserted

    skill |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    disabled = current()
    assert disabled != selected

    skill |> Ecto.Changeset.change(publication_status: "withdrawn") |> Repo.update!()
    withdrawn = current()
    assert withdrawn != disabled

    Repo.query!("UPDATE skills SET enabled = enabled, updated_at = now() WHERE id = $1", [
      skill.id
    ])

    assert current() == withdrawn

    Repo.delete!(skill)
    assert current() != withdrawn
  end

  test "authorization mutations invalidate generations without changing them on request accounting" do
    before = current()
    client = Repo.insert!(%Client{name: "skill-protocol-client", scopes: ["skill::read"]})
    inserted = current()
    assert inserted != before

    client |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now()) |> Repo.update!()
    assert current() == inserted

    client |> Ecto.Changeset.change(scopes: ["day::*"]) |> Repo.update!()
    restricted = current()
    assert restricted != inserted

    client |> Ecto.Changeset.change(active: false) |> Repo.update!()
    assert current() != restricted
  end

  test "only the client bypass setting changes the authorization generation" do
    Repo.query!("DELETE FROM system_settings WHERE key = 'clients.auth_bypass.enabled'")
    initial = current()

    Repo.query!("INSERT INTO system_settings (key, value) VALUES ($1, $2::jsonb)", [
      "skill-protocol-unrelated-setting",
      "true"
    ])

    assert current() == initial

    Repo.query!(
      """
      INSERT INTO system_settings (key, value) VALUES ($1, $2::jsonb)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value
      """,
      ["clients.auth_bypass.enabled", "true"]
    )

    enabled = current()
    assert enabled != initial

    Repo.query!("UPDATE system_settings SET value = $2::jsonb WHERE key = $1", [
      "clients.auth_bypass.enabled",
      "false"
    ])

    assert current() != enabled
  end

  test "generation rolls back with an abandoned write" do
    initial = current()

    assert {:error, :abandoned} =
             Repo.transaction(fn ->
               Repo.insert!(%Skill{
                 id: "protocol-rollback",
                 slug: "protocol-rollback",
                 name: "rollback",
                 content: "Body"
               })

               assert current() != initial
               Repo.rollback(:abandoned)
             end)

    assert current() == initial
  end

  test "OAuth revocation, audience, client policy and user activation change the generation" do
    %{rows: [[user_id]]} =
      Repo.query!(
        "INSERT INTO users (email, inserted_at, updated_at) VALUES ($1, now(), now()) RETURNING id",
        [
          "skill-protocol-generation@example.invalid"
        ]
      )

    %{rows: [[client_id]]} =
      Repo.query!("""
      INSERT INTO oauth_clients (name, secret, private_key, inserted_at, updated_at)
      VALUES ('protocol-generation', 'test-secret', 'test-private-key', now(), now()) RETURNING id
      """)

    %{rows: [[token_id]]} =
      Repo.query!(
        """
        INSERT INTO oauth_tokens (type, value, scope, client_id, sub, expires_at, inserted_at, updated_at)
        VALUES ('access_token', 'test-access-value', 'skill::read', $1, $2, 2000000000, now(), now())
        RETURNING id
        """,
        [client_id, Ecto.UUID.load!(user_id)]
      )

    before = current()
    Repo.query!("UPDATE oauth_tokens SET revoked_at = now() WHERE id = $1", [token_id])
    revoked = current()
    assert revoked != before

    Repo.query!(
      """
      INSERT INTO oauth_token_resources (oauth_token_id, resource, inserted_at, updated_at)
      VALUES ($1, 'skill_protocol', now(), now())
      """,
      [token_id]
    )

    audience = current()
    assert audience != revoked

    Repo.query!(
      "UPDATE oauth_clients SET metadata = '{\"disabled\":true}'::jsonb WHERE id = $1",
      [client_id]
    )

    client_disabled = current()
    assert client_disabled != audience

    Repo.query!("UPDATE users SET active = false WHERE id = $1", [user_id])
    assert current() != client_disabled
  end

  test "subscription has a live, monitorable database listener" do
    assert :ok = ProtocolChanges.subscribe()
    assert is_pid(ProtocolChanges.listener())
    assert Process.alive?(ProtocolChanges.listener())
    assert {:ok, generation} = ProtocolChanges.current()
    assert {:ok, _uuid} = Ecto.UUID.cast(generation)
  end

  @tag capture_log: true
  test "database listener loss withdraws readiness and supervised restart announces reconciliation" do
    assert :ok = ProtocolChanges.subscribe()
    listener = ProtocolChanges.listener()
    monitor = Process.monitor(listener)
    %{connection: connection} = :sys.get_state(listener)
    generation = current()

    Process.exit(connection, :kill)

    assert_receive :skill_protocol_unavailable, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^listener, :database_listener_closed}, 1_000
    assert_receive :skill_protocol_changed, 1_000
    assert ProtocolChanges.listener() != listener
    assert current() == generation
  end

  defp current do
    assert {:ok, generation} = ProtocolChanges.current()
    generation
  end

  defp insert_skill!(id),
    do: Repo.insert!(%Skill{id: id, slug: id, name: id, content: "Body"})
end

defmodule Backplane.Skills.ProtocolChangesCommitTest do
  use ExUnit.Case, async: false

  alias Backplane.Repo
  alias Backplane.Skills.ProtocolChanges

  test "committed changes notify subscribers and rolled-back changes do not" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert :ok = ProtocolChanges.subscribe()
      id = "protocol-notify-#{System.unique_integer([:positive])}"

      try do
        assert {:ok, :saved} =
                 Repo.transaction(fn ->
                   insert_skill(id)
                   refute_receive :skill_protocol_changed, 50
                   :saved
                 end)

        assert_receive :skill_protocol_changed, 1_000

        assert {:error, :abandoned} =
                 Repo.transaction(fn ->
                   Repo.query!("UPDATE skills SET enabled = false WHERE id = $1", [id])
                   Repo.rollback(:abandoned)
                 end)

        refute_receive :skill_protocol_changed, 100
      after
        Repo.query!("DELETE FROM skills WHERE id = $1", [id])
      end
    end)
  end

  test "delta history survives separate commits and resets after retention removes its anchor" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      id = "protocol-retention-#{System.unique_integer([:positive])}"

      try do
        insert_skill(id)
        assert {:ok, initial} = ProtocolChanges.current()

        previous =
          Enum.reduce(1..257, initial, fn number, _previous ->
            assert {:ok, before} = ProtocolChanges.current()

            Repo.query!("UPDATE skills SET description = $2 WHERE id = $1", [
              id,
              Integer.to_string(number)
            ])

            assert {:ok, latest} = ProtocolChanges.current()
            assert {:ok, %{generation: ^latest, skill_ids: [^id]}} = ProtocolChanges.since(before)
            before
          end)

        assert {:ok, latest} = ProtocolChanges.current()
        assert {:ok, %{generation: ^latest, skill_ids: [^id]}} = ProtocolChanges.since(previous)
        assert {:reset, ^latest} = ProtocolChanges.since(initial)
        assert %{rows: [[256]]} = Repo.query!("SELECT count(*) FROM skill_protocol_changes")
      after
        Repo.query!("DELETE FROM skills WHERE id = $1", [id])
      end
    end)
  end

  defp insert_skill(id) do
    Repo.query!(
      """
      INSERT INTO skills (id, slug, name, content, inserted_at, updated_at)
      VALUES ($1, $1, $1, 'Body', now(), now())
      """,
      [id]
    )
  end
end
