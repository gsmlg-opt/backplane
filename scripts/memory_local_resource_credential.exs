defmodule Backplane.Scripts.MemoryLocalResourceCredential do
  @moduledoc """
  Fixture-only resource credential reconciliation. Database issuance and encrypted
  storage share a transaction. File publication follows commit: if it fails, the
  vault retains the issued token and a repeat invocation repairs the file.
  """

  import Ecto.Query
  import Bitwise, only: [band: 2]

  alias Backplane.{Clients, Repo}
  alias Backplane.Clients.{AuthCache, Client}
  alias Backplane.Settings.{Credential, Credentials, Encryption}
  alias Backplane.Settings.Credentials.Vault

  @project_root Path.expand("..", __DIR__)
  @private_query [log: false, telemetry_event: nil]

  defmodule Error do
    defexception [:reason, message: "fixture resource credential operation refused"]
  end

  def prepare(run_id, project_root \\ @project_root), do: reconcile(run_id, project_root, false)
  def cutover(run_id, project_root \\ @project_root), do: reconcile(run_id, project_root, true)

  defp reconcile(run_id, project_root, require_fixture?) do
    unless is_binary(run_id) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,49}\z/, run_id),
      do: refuse(:invalid_run_id)

    project_root = Path.expand(project_root)
    root = Path.join([project_root, ".devenv", "memory-local-fixtures", run_id])
    owner = File.lstat!(project_root).uid

    context = %{
      root: root,
      project: project_root,
      owner: owner,
      run_id: run_id,
      allow_issue: not require_fixture?,
      name: "memory-local-#{run_id}-processor",
      credential: "memory-local-#{run_id}-resource",
      token_file: Path.join(root, "resource-token")
    }

    validate_directories(context)
    validate_fixture(context, require_fixture?)
    file_token = read_private(context.token_file, owner, 256) |> trim_token()
    lock = Path.join(root, ".resource-credential.lock")
    unless File.mkdir(lock) == :ok, do: refuse(:fixture_locked)

    try do
      File.chmod!(lock, 0o700)
      reconcile_locked(context, file_token)
    after
      File.rmdir(lock)
    end
  rescue
    error in Error -> {:error, error.reason}
    _error -> {:error, :credential_operation_failed}
  end

  defp reconcile_locked(context, file_token) do
    result =
      Repo.transaction(
        fn ->
          client =
            Repo.one(
              from(c in Client, where: c.name == ^context.name, lock: "FOR UPDATE"),
              @private_query
            )

          credential =
            Repo.one(
              from(c in Credential, where: c.name == ^context.credential, lock: "FOR UPDATE"),
              @private_query
            )

          validate_client(client)
          vault_token = decrypt_credential(credential)
          tokens = Enum.reject([vault_token, file_token], &is_nil/1) |> Enum.uniq()
          validate_tokens(tokens, client)
          {client, token, action} = resolve_token(client, tokens, context)

          if token != vault_token do
            try do
              metadata = if credential, do: credential.metadata, else: %{}

              case Credentials.store(context.credential, token, "service", metadata) do
                {:ok, _} -> :ok
                _ -> Repo.rollback(:credential_store_failed)
              end
            rescue
              _ -> Repo.rollback(:credential_store_failed)
            end
          else
            Vault.put(credential)
          end

          %{client_id: client.id, token: token, action: action}
        end,
        @private_query
      )

    case result do
      {:ok, result} ->
        case publish_token(context, result.token) do
          :ok -> {:ok, Map.delete(result, :token) |> Map.put(:token_file, context.token_file)}
          :error -> {:error, :token_file_write_failed}
        end

      {:error, reason} ->
        restore_caches(context.credential)
        {:error, reason}
    end
  rescue
    error in Error ->
      restore_caches(context.credential)
      {:error, error.reason}

    _ ->
      restore_caches(context.credential)
      {:error, :credential_operation_failed}
  end

  defp restore_caches(name) do
    case Repo.get_by(Credential, [name: name], @private_query) do
      nil -> Vault.remove(name)
      credential -> Vault.put(credential)
    end

    Clients.refresh_cache()
  end

  defp validate_client(nil), do: :ok

  defp validate_client(client) do
    unless client.active == true, do: refuse(:inactive_fixture_client)
    attrs = Map.take(client, [:name, :scopes, :active, :metadata])

    unless Client.changeset(%Client{}, attrs).valid? and
             (is_nil(client.token_digest) or
                (is_binary(client.token_digest) and byte_size(client.token_digest) == 32)),
           do: refuse(:malformed_fixture_client)
  end

  defp decrypt_credential(nil), do: nil

  defp decrypt_credential(credential) do
    unless credential.kind == "service" and is_map(credential.metadata) and
             credential.metadata["auth_type"] in [nil, "api_key"],
           do: refuse(:malformed_fixture_credential)

    case Encryption.decrypt(credential.encrypted_value) do
      {:ok, token} -> token
      _ -> refuse(:malformed_fixture_credential)
    end
  end

  defp validate_tokens(tokens, client) do
    for token <- tokens do
      unless AuthCache.token_format_valid?(token) or legacy_token?(token),
        do: refuse(:malformed_fixture_token)

      if AuthCache.token_format_valid?(token) do
        owner = Repo.get_by(Client, [token_digest: :crypto.hash(:sha256, token)], @private_query)
        if owner && (is_nil(client) or owner.id != client.id), do: refuse(:fixture_token_mismatch)
      end
    end
  end

  defp legacy_token?(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == token

      _ ->
        false
    end
  end

  defp legacy_token?(_), do: false

  defp resolve_token(client, tokens, context) do
    matching =
      Enum.find(tokens, fn token ->
        client && AuthCache.token_format_valid?(token) &&
          client.token_digest == :crypto.hash(:sha256, token)
      end)

    cond do
      matching ->
        {client, matching, :unchanged}

      is_nil(client) and context.allow_issue ->
        issued_result(Clients.issue_client(%{name: context.name, scopes: ["*"]}), :issued)

      is_nil(client) ->
        refuse(:fixture_client_missing)

      is_nil(client.token_digest) ->
        issued_result(Clients.rotate_client_token(client), :rotated)

      true ->
        refuse(:issued_fixture_token_unavailable)
    end
  end

  defp issued_result({:ok, client, token}, action), do: {client, token, action}
  defp issued_result(_, _), do: refuse(:client_issuance_failed)

  defp validate_directories(context) do
    paths = [
      context.project,
      Path.join(context.project, ".devenv"),
      Path.dirname(context.root),
      context.root
    ]

    for path <- paths do
      case File.lstat(path) do
        {:ok, %{type: :directory, uid: owner} = stat} when owner == context.owner ->
          if path == context.root and band(stat.mode, 0o777) != 0o700,
            do: refuse(:unsafe_fixture_path)

        _ ->
          refuse(:unsafe_fixture_path)
      end
    end
  end

  defp validate_fixture(context, required?) do
    case read_private(Path.join(context.root, "fixture.json"), context.owner, 1_048_576) do
      nil when not required? ->
        :ok

      nil ->
        refuse(:fixture_missing)

      content ->
        case Jason.decode(content) do
          {:ok, %{"run_id" => run_id, "settings" => %{"memory.proxy_credential" => credential}}}
          when run_id == context.run_id and credential == context.credential ->
            :ok

          _ ->
            refuse(:fixture_mismatch)
        end
    end
  end

  defp read_private(path, owner, max_bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        nil

      {:ok, %{type: :regular, uid: ^owner, links: 1, size: size, mode: mode}}
      when size <= max_bytes and band(mode, 0o077) == 0 ->
        File.read!(path)

      _ ->
        refuse(:unsafe_fixture_path)
    end
  end

  defp trim_token(nil), do: nil
  defp trim_token(content), do: String.trim(content)

  defp publish_token(context, token) do
    validate_directories(context)
    existing = read_private(context.token_file, context.owner, 256)

    if existing == token <> "\n" and band(File.stat!(context.token_file).mode, 0o777) == 0o600 do
      :ok
    else
      temporary =
        context.token_file <>
          ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      try do
        {:ok, :ok} =
          File.open(temporary, [:write, :exclusive, :binary], fn io ->
            File.chmod!(temporary, 0o600)
            :ok = IO.binwrite(io, token <> "\n")
            :file.sync(io)
          end)

        File.rename!(temporary, context.token_file)
        :ok
      after
        File.rm(temporary)
      end
    end
  rescue
    _ -> :error
  end

  defp refuse(reason), do: raise(Error, reason: reason)
end
