defmodule Backplane.SecretHub.Sync do
  @moduledoc """
  Publishes API key credentials to SecretHub through the local SecretHub Agent.

  When `secrethub.sync.enabled` is on, every API key credential (kind any;
  metadata `auth_type` absent or `"api_key"`) is published at
  `backplane.<kind>.<name>` as `%{"api_key" => value}`. OAuth, device and
  imported CLI credentials are never published: they refresh automatically and
  are bound to their sessions.

  SecretHub is a downstream mirror. Local credential storage never depends on
  it: failures are logged (without values), recorded in
  `Backplane.SecretHub.Publication`, and repaired by `reconcile/0`, which runs
  periodically. Republishing an unchanged value is a no-op in SecretHub, so
  reconciliation is safe to repeat. Disabling sync stops publication; it does
  not remove what was already published.
  """

  import Ecto.Query
  require Logger

  alias Backplane.Repo
  alias Backplane.SecretHub.Publication
  alias Backplane.Settings
  alias Backplane.Settings.{Credential, Encryption}

  @enabled_key "secrethub.sync.enabled"
  @socket_key "secrethub.sync.socket_path"
  @prefix "backplane"

  # Conditions under which retrying soon can succeed without operator action.
  @transient ~w(agent_unavailable unconfirmed busy unavailable sealed audit_unavailable)a

  def enabled_key, do: @enabled_key
  def socket_key, do: @socket_key

  @doc "Whether publication is enabled."
  def enabled?, do: Settings.get(@enabled_key) == true

  @doc "Whether an error is expected to clear without operator action."
  def transient?(reason), do: reason in @transient

  @doc "The SecretHub path for a credential, or an error for an unusable name."
  @spec path_for(%Credential{}) :: {:ok, String.t()} | {:error, :invalid_name}
  def path_for(%Credential{kind: kind, name: name}) do
    {:ok, SecretHub.SDK.path([@prefix, kind, name])}
  rescue
    ArgumentError -> {:error, :invalid_name}
  end

  @doc "Whether a credential is a plain API key eligible for publication."
  def eligible?(%Credential{metadata: metadata}),
    do: Map.get(metadata || %{}, "auth_type") in [nil, "api_key"]

  @doc """
  Brings SecretHub in line with the credential `name`: publishes it if it is
  an eligible API key, otherwise removes anything previously published for it.
  """
  @spec sync_credential(String.t()) :: :ok | {:error, atom()}
  def sync_credential(name) when is_binary(name) do
    # Change-triggered jobs and reconciliation can sync the same credential at
    # once; a per-credential advisory lock makes them take turns. The outcome,
    # including recorded errors, is committed either way.
    Repo.transaction(
      fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key(name)])
        publication = Repo.get(Publication, name)

        case desired(name) do
          {:publish, path, value} -> publish(name, path, value, publication)
          :absent -> withdraw(publication)
          {:skip, reason} -> skip(name, reason, publication)
        end
      end,
      timeout: 120_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Syncs every credential and every recorded publication. Stops at the first
  `:agent_unavailable`, since nothing else can succeed until the Agent is back.
  """
  @spec reconcile() ::
          {:ok, %{synced: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, :agent_unavailable}
  def reconcile do
    names =
      Repo.all(from(c in Credential, select: c.name))
      |> Enum.concat(Repo.all(from(p in Publication, select: p.credential_name)))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce_while(names, {:ok, %{synced: 0, failed: 0}}, fn name, {:ok, acc} ->
      case sync_credential(name) do
        :ok -> {:cont, {:ok, %{acc | synced: acc.synced + 1}}}
        {:error, :agent_unavailable} -> {:halt, {:error, :agent_unavailable}}
        {:error, _} -> {:cont, {:ok, %{acc | failed: acc.failed + 1}}}
      end
    end)
  end

  @doc "Counts for the admin UI. Contains no values."
  def status do
    publications = Repo.all(Publication)

    %{
      published: Enum.count(publications, &(&1.version && is_nil(&1.last_error))),
      failing: Enum.count(publications, & &1.last_error),
      last_synced_at:
        publications |> Enum.map(& &1.synced_at) |> Enum.reject(&is_nil/1) |> max_time(),
      errors:
        publications
        |> Enum.filter(& &1.last_error)
        |> Enum.map(&%{credential_name: &1.credential_name, error: &1.last_error})
    }
  end

  ## Decisions

  defp desired(name) do
    with %Credential{} = credential <- Repo.get_by(Credential, name: name),
         true <- eligible?(credential),
         {:ok, path} <- path_for(credential),
         {:ok, value} <- decrypt(credential) do
      {:publish, path, value}
    else
      nil -> :absent
      false -> :absent
      {:error, reason} -> {:skip, reason}
    end
  end

  defp decrypt(%Credential{encrypted_value: encrypted}) do
    case Encryption.decrypt(encrypted) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :decryption_failed}
    end
  end

  ## Effects

  # A moved path (kind change) is withdrawn first so the old path never keeps
  # serving a value the credential no longer has there.
  defp publish(name, path, value, %Publication{path: old} = publication) when old != path do
    with :ok <- delete_remote(name, publication) do
      Repo.delete(publication)
      publish(name, path, value, nil)
    end
  end

  defp publish(name, path, value, publication) do
    # Never overwrite a path another credential already owns (names that
    # normalize to the same path). The unique index backs this up on record.
    if Repo.exists?(
         from(p in Publication, where: p.path == ^path and p.credential_name != ^name)
       ),
       do: collision(name, path),
       else: put(name, path, value, publication)
  end

  defp put(name, path, value, publication) do
    case SecretHub.SDK.put_secret(path, %{"api_key" => value}, sdk_opts()) do
      {:ok, %{version: version} = result} ->
        record(publication, %{
          credential_name: name,
          path: path,
          version: version,
          synced_at: now(),
          last_error: nil
        })
        |> case do
          {:ok, _} ->
            if result.status != :unchanged,
              do: Logger.info("SecretHub sync published #{name} at #{path} (v#{version})")

            :ok

          {:error, %Ecto.Changeset{}} ->
            collision(name, path)
        end

      {:error, %SecretHub.SDK.Error{code: code}} ->
        Logger.warning("SecretHub sync could not publish #{name} at #{path}: #{code}")
        record_error(publication, name, path, code)
    end
  end

  defp withdraw(nil), do: :ok

  defp withdraw(%Publication{credential_name: name} = publication) do
    with :ok <- delete_remote(name, publication) do
      Repo.delete(publication)
      Logger.info("SecretHub sync removed #{publication.path} for #{name}")
      :ok
    end
  end

  # Unusable names or undecryptable values are never published; anything
  # published earlier for the credential is withdrawn.
  defp skip(name, reason, publication) do
    Logger.warning("SecretHub sync skipped #{name}: #{reason}")

    case withdraw(publication) do
      :ok -> {:error, reason}
      error -> error
    end
  end

  defp delete_remote(name, %Publication{path: path} = publication) do
    case SecretHub.SDK.delete_secret(path, sdk_opts()) do
      {:ok, _} ->
        :ok

      {:error, %SecretHub.SDK.Error{code: code}} ->
        Logger.warning("SecretHub sync could not remove #{path} for #{name}: #{code}")
        record_error(publication, name, path, code)
    end
  end

  defp collision(name, path) do
    Logger.warning("SecretHub sync skipped #{name}: #{path} is published for another credential")
    {:error, :path_collision}
  end

  defp record_error(publication, name, path, code) do
    case record(publication, %{credential_name: name, path: path, last_error: to_string(code)}) do
      {:ok, _} -> {:error, code}
      {:error, %Ecto.Changeset{}} -> collision(name, path)
    end
  end

  defp record(nil, attrs), do: record(%Publication{}, attrs)

  defp record(%Publication{} = publication, attrs) do
    publication
    |> Publication.changeset(Map.put(attrs, :last_attempt_at, now()))
    |> Repo.insert_or_update()
  end

  defp sdk_opts do
    case Settings.get(@socket_key) do
      path when is_binary(path) and path != "" -> [socket_path: path]
      _ -> []
    end
  end

  defp lock_key(name), do: :erlang.phash2({__MODULE__, name})

  defp now, do: DateTime.utc_now()

  defp max_time([]), do: nil
  defp max_time(times), do: Enum.max(times, DateTime)
end
