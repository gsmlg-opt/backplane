defmodule Backplane.Scripts.MemoryLocalResourceCredentialTest do
  use BackplaneSystem.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Backplane.Clients
  alias Backplane.Settings.{Credential, Credentials}
  alias Backplane.Settings.Credentials.Vault

  @helper Backplane.Scripts.MemoryLocalResourceCredential

  setup_all do
    path = Path.expand("../../../../../scripts/memory_local_resource_credential.exs", __DIR__)
    if File.regular?(path), do: Code.require_file(path)
    :ok
  end

  setup do
    project =
      Path.join(System.tmp_dir!(), "memory-fixture-auth-#{System.unique_integer([:positive])}")

    run_id = "auth-#{System.unique_integer([:positive])}"
    root = Path.join([project, ".devenv", "memory-local-fixtures", run_id])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    credential = "memory-local-#{run_id}-resource"
    client_name = "memory-local-#{run_id}-processor"
    fixture = %{"run_id" => run_id, "settings" => %{"memory.proxy_credential" => credential}}
    private_write(Path.join(root, "fixture.json"), Jason.encode!(fixture))
    on_exit(fn -> File.rm_rf!(project) end)

    %{
      project: project,
      run_id: run_id,
      root: root,
      credential: credential,
      client_name: client_name,
      fixture: fixture
    }
  end

  test "legacy fixture cutover issues a usable token while preserving identity and scopes", c do
    {:ok, client} =
      Clients.create_client(%{
        name: c.client_name,
        scopes: ["memory.read", "docs::*"],
        metadata: %{"fixture" => true}
      })

    legacy = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, _} = Credentials.store(c.credential, legacy, "service", %{"purpose" => "local"})
    private_write(Path.join(c.root, "resource-token"), legacy <> "\n")

    assert {:ok, %{action: :rotated, client_id: id}} = cutover(c)
    assert id == client.id
    current = Clients.get_client(id)
    assert current.scopes == client.scopes
    assert current.active == client.active
    assert current.metadata == client.metadata
    assert {:ok, token} = Credentials.fetch(c.credential)
    assert {:ok, %{id: ^id}} = Clients.verify_token(token)
    assert token != legacy
    assert File.read!(Path.join(c.root, "resource-token")) == token <> "\n"
    assert Bitwise.band(File.stat!(Path.join(c.root, "resource-token")).mode, 0o777) == 0o600
    assert Vault.get(c.credential).metadata == %{"purpose" => "local"}
    before = client_snapshot(id)
    assert {:ok, %{action: :unchanged}} = cutover(c)
    assert client_snapshot(id) == before
    assert Credentials.fetch(c.credential) == {:ok, token}
  end

  test "new fixture client uses server issuance", c do
    assert function_exported?(@helper, :prepare, 2)

    assert {:ok, %{action: :issued, client_id: id}} =
             apply(@helper, :prepare, [c.run_id, c.project])

    assert Clients.get_client(id).name == c.client_name
    assert Clients.get_client(id).scopes == ["*"]
    assert {:ok, token} = Credentials.fetch(c.credential)
    assert {:ok, %{id: ^id}} = Clients.verify_token(token)
    assert File.read!(Path.join(c.root, "resource-token")) == token <> "\n"
    assert {:ok, %{action: :unchanged, client_id: ^id}} = cutover(c)
  end

  test "valid issued vault token is retained and a missing file is repaired", c do
    {client, token} = issued_fixture(c)
    before = client_snapshot(client.id)
    stored = Repo.get_by!(Credential, name: c.credential)
    assert {:ok, %{action: :unchanged}} = cutover(c)
    assert client_snapshot(client.id) == before
    assert Repo.get_by!(Credential, name: c.credential) == stored
    assert File.read!(Path.join(c.root, "resource-token")) == token <> "\n"
  end

  test "a valid private file recovers the vault without rotating an issued credential", c do
    {client, token} = issued_fixture(c)
    private_write(Path.join(c.root, "resource-token"), token <> "\n")

    {:ok, _} =
      Credentials.store(
        c.credential,
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        "service"
      )

    before = client_snapshot(client.id)
    assert {:ok, %{action: :unchanged}} = cutover(c)
    assert client_snapshot(client.id) == before
    assert {:ok, ^token} = Credentials.fetch(c.credential)
  end

  test "inactive fixture clients are refused without changing files or credentials", c do
    {:ok, client} = Clients.create_client(%{name: c.client_name, scopes: ["*"], active: false})
    before = fixture_snapshot(c)
    assert {:error, :inactive_fixture_client} = cutover(c)
    assert fixture_snapshot(c) == before
    assert Clients.get_client(client.id).token_digest == nil
  end

  test "issued digest without its matching token is refused instead of rotated", c do
    {client, _token} = issued_fixture(c)

    {:ok, _} =
      Credentials.store(
        c.credential,
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        "service"
      )

    before = fixture_snapshot(c)
    assert {:error, :issued_fixture_token_unavailable} = cutover(c)
    assert fixture_snapshot(c) == before
    assert Clients.get_client(client.id).token_digest == client.token_digest
  end

  test "another client's issued token cannot authorize fixture adoption", c do
    {:ok, other, token} =
      Clients.issue_client(%{name: "unrelated-#{c.run_id}", scopes: ["docs::*"]})

    {:ok, _} = Credentials.store(c.credential, token, "service")
    before = fixture_snapshot(c)
    assert {:error, :fixture_token_mismatch} = cutover(c)
    assert fixture_snapshot(c) == before
    assert Clients.get_client_by_name(c.client_name) == nil
    assert {:ok, %{id: id}} = Clients.verify_token(token)
    assert id == other.id
  end

  test "unrelated clients, credentials, settings and fixture files are unchanged", c do
    {:ok, _fixture_client} =
      Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})

    {:ok, other, _token} =
      Clients.issue_client(%{name: "other-#{c.run_id}", scopes: ["memory.read"]})

    {:ok, credential} =
      Credentials.store("other-#{c.run_id}", "unrelated-private-value", "custom")

    files =
      for filename <- ["primary/host.yaml", "isolated/host.yaml", "notes"] do
        path = Path.join(c.root, filename)
        File.mkdir_p!(Path.dirname(path))
        private_write(path, "preserve-" <> filename)
        {path, File.read!(path)}
      end

    other_before = client_snapshot(other.id)
    settings_before = Repo.query!("SELECT * FROM system_settings ORDER BY key").rows
    assert {:ok, _} = cutover(c)
    assert client_snapshot(other.id) == other_before
    assert Repo.get!(Credential, credential.id) == credential
    assert Repo.query!("SELECT * FROM system_settings ORDER BY key").rows == settings_before
    for {path, content} <- files, do: assert(File.read!(path) == content)
  end

  test "fresh setup supports a directory before its final manifest exists", c do
    File.rm!(Path.join(c.root, "fixture.json"))
    assert function_exported?(@helper, :prepare, 2)
    assert {:ok, %{action: :issued}} = apply(@helper, :prepare, [c.run_id, c.project])
    refute File.exists?(Path.join(c.root, "fixture.json"))
  end

  test "cutover requires an existing matching manifest", c do
    File.rm!(Path.join(c.root, "fixture.json"))
    assert {:error, :fixture_missing} = cutover(c)
    assert Clients.get_client_by_name(c.client_name) == nil

    private_write(
      Path.join(c.root, "fixture.json"),
      Jason.encode!(
        put_in(c.fixture, ["settings", "memory.proxy_credential"], "another-resource")
      )
    )

    assert {:error, :fixture_mismatch} = cutover(c)
    assert Clients.get_client_by_name(c.client_name) == nil
  end

  test "cutover never creates new authority from a manifest alone", c do
    before = fixture_snapshot(c)
    assert {:error, :fixture_client_missing} = cutover(c)
    assert fixture_snapshot(c) == before
  end

  test "malformed existing client scopes are refused without broadening", c do
    {:ok, client} = Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})

    Repo.update_all(from(row in Backplane.Clients.Client, where: row.id == ^client.id),
      set: [scopes: []]
    )

    before = fixture_snapshot(c)
    assert {:error, :malformed_fixture_client} = cutover(c)
    assert fixture_snapshot(c) == before
  end

  test "unexpected credential kind or token is refused", c do
    {:ok, _client} = Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})
    {:ok, _} = Credentials.store(c.credential, "not-a-fixture-token", "llm")
    before = fixture_snapshot(c)
    assert {:error, :malformed_fixture_credential} = cutover(c)
    assert fixture_snapshot(c) == before
    {:ok, _} = Credentials.store(c.credential, "not-a-fixture-token", "service")
    before = fixture_snapshot(c)
    assert {:error, :malformed_fixture_token} = cutover(c)
    assert fixture_snapshot(c) == before
  end

  for change <- [
        :symlink_file,
        :symlink_root,
        :symlink_parent,
        :hardlink_file,
        :directory_file,
        :public_file,
        :public_root
      ] do
    @change change
    test "refuses unsafe fixture path #{@change} before issuing a client", c do
      external = Path.join(c.project, "external")
      private_write(external, "unchanged")
      token_file = Path.join(c.root, "resource-token")

      case @change do
        :symlink_file ->
          File.ln_s!(external, token_file)

        :symlink_root ->
          File.rename!(c.root, c.root <> "-real")
          File.ln_s!(c.root <> "-real", c.root)

        :symlink_parent ->
          parent = Path.dirname(c.root)
          File.rename!(parent, parent <> "-real")
          File.ln_s!(parent <> "-real", parent)

        :hardlink_file ->
          File.ln!(external, token_file)

        :directory_file ->
          File.mkdir!(token_file)

        :public_file ->
          File.write!(token_file, "unchanged")
          File.chmod!(token_file, 0o644)

        :public_root ->
          File.chmod!(c.root, 0o755)
      end

      assert {:error, :unsafe_fixture_path} = cutover(c)
      assert Clients.get_client_by_name(c.client_name) == nil
      assert File.read!(external) == "unchanged"
    end
  end

  test "invalid run identifiers are refused", c do
    assert function_exported?(@helper, :cutover, 2)

    for run <- ["../escape", "A", "", "a\n", "with/slash", String.duplicate("a", 51)] do
      assert {:error, :invalid_run_id} = apply(@helper, :cutover, [run, c.project])
    end

    assert Clients.get_client_by_name(c.client_name) == nil
  end

  test "vault storage failure rolls back credential rotation and restores its cache", c do
    {:ok, client} = Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})
    legacy = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, _} = Credentials.store(c.credential, legacy, "service")
    private_write(Path.join(c.root, "resource-token"), legacy <> "\n")

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_fixture_credential() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture store refused'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_fixture_credential BEFORE INSERT OR UPDATE ON credentials FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_fixture_credential()"
    )

    before = fixture_snapshot(c)
    assert {:error, :credential_store_failed} = cutover(c)
    assert fixture_snapshot(c) == before
    assert Clients.get_client(client.id).token_digest == nil
    assert Credentials.fetch(c.credential) == {:ok, legacy}
  end

  test "postcommit file failure is recoverable from vault without a second rotation", c do
    {:ok, _client} = Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})
    handler = "fixture-file-failure-#{c.run_id}"
    token_file = Path.join(c.root, "resource-token")

    :telemetry.attach(
      handler,
      [:backplane, :repo, :query],
      fn _, _, metadata, _ ->
        if metadata[:source] == "credentials" and String.starts_with?(metadata.query, "INSERT") and
             c.credential in metadata.params do
          File.mkdir!(token_file)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:error, :token_file_write_failed} = cutover(c)
    :telemetry.detach(handler)
    {:ok, token} = Credentials.fetch(c.credential)
    {:ok, client} = Clients.verify_token(token)
    before = client_snapshot(client.id)
    File.rmdir!(token_file)
    assert {:ok, %{action: :unchanged, client_id: id}} = cutover(c)
    assert id == client.id
    assert client_snapshot(client.id) == before
    assert File.read!(token_file) == token <> "\n"
  end

  test "results, stdout and logs contain neither issued secrets nor raw client queries", c do
    {:ok, _client} = Clients.create_client(%{name: c.client_name, scopes: ["memory.read"]})
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    output =
      capture_io(fn ->
        logs =
          capture_log([level: :debug], fn ->
            assert {:ok, result} = cutover(c)
            send(self(), {:result, result})
          end)

        send(self(), {:logs, logs})
      end)

    assert_receive {:result, result}
    assert_receive {:logs, logs}
    assert {:ok, token} = Credentials.fetch(c.credential)
    refute inspect(result) =~ token
    refute output =~ token
    refute logs =~ token
    refute logs =~ ~r/(SELECT|INSERT|UPDATE).*"clients"/
    refute inspect(result) =~ "token_digest"
  end

  defp cutover(c) do
    assert function_exported?(@helper, :cutover, 2),
           "fixture cutover helper must use indexed issuance"

    apply(@helper, :cutover, [c.run_id, c.project])
  end

  defp issued_fixture(c) do
    {:ok, client, token} = Clients.issue_client(%{name: c.client_name, scopes: ["memory.read"]})
    {:ok, _} = Credentials.store(c.credential, token, "service")
    {client, token}
  end

  defp private_write(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o600)
  end

  defp client_snapshot(id),
    do: Clients.get_client(id) |> Map.from_struct() |> Map.drop([:__meta__])

  defp fixture_snapshot(c) do
    {Clients.get_client_by_name(c.client_name), Repo.get_by(Credential, name: c.credential),
     File.read(Path.join(c.root, "resource-token")), File.read(Path.join(c.root, "fixture.json"))}
  end
end
