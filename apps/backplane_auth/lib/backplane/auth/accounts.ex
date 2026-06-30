defmodule Backplane.Auth.Accounts do
  @moduledoc "Local users, password credentials, and browser sessions for Backplane Auth."

  import Ecto.Query

  alias Backplane.Auth.Audit
  alias Backplane.Auth.Schemas.{PasswordCredential, Session, User}
  alias Backplane.Repo

  @default_session_ttl_seconds 86_400

  def create_user(attrs) when is_map(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def list_users do
    User
    |> order_by(:email)
    |> Repo.all()
  end

  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  def set_password(%User{id: user_id}, password) when is_binary(password) do
    attrs = %{
      user_id: user_id,
      password_hash: Bcrypt.hash_pwd_salt(password),
      password_changed_at: now()
    }

    case Repo.get_by(PasswordCredential, user_id: user_id) do
      nil ->
        %PasswordCredential{}
        |> PasswordCredential.changeset(attrs)
        |> Repo.insert()

      %PasswordCredential{} = credential ->
        credential
        |> PasswordCredential.changeset(attrs)
        |> Repo.update()
    end
  end

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    email = normalize_email(email)

    case get_user_by_email(email) do
      nil ->
        Bcrypt.no_user_verify()
        record_login_failure(nil, email, "invalid_credentials")
        {:error, :invalid_credentials}

      %User{active: false} = user ->
        record_login_failure(user, email, "inactive")
        {:error, :inactive}

      %User{password_credential: nil} = user ->
        Bcrypt.no_user_verify()
        record_login_failure(user, email, "invalid_credentials")
        {:error, :invalid_credentials}

      %User{password_credential: credential} = user ->
        if Bcrypt.verify_pass(password, credential.password_hash) do
          {:ok, user} = mark_login(user)
          Audit.record("login.success", user, target_attrs(user))
          {:ok, user}
        else
          record_login_failure(user, email, "invalid_credentials")
          {:error, :invalid_credentials}
        end
    end
  end

  def disable_user(%User{} = user) do
    result =
      user
      |> User.changeset(%{active: false})
      |> Repo.update()

    with {:ok, disabled} <- result do
      Audit.record("user.disabled", disabled, target_attrs(disabled))
      {:ok, disabled}
    end
  end

  def create_session(%User{id: user_id} = user, attrs \\ %{}) when is_map(attrs) do
    token = random_token()

    attrs = %{
      user_id: user_id,
      token_hash: token_hash(token),
      user_agent: attr(attrs, :user_agent),
      ip: attr(attrs, :ip),
      expires_at:
        attr(attrs, :expires_at, DateTime.add(now(), @default_session_ttl_seconds, :second)),
      metadata: attr(attrs, :metadata, %{})
    }

    case %Session{} |> Session.changeset(attrs) |> Repo.insert() do
      {:ok, session} ->
        Audit.record(
          "session.created",
          user,
          Map.merge(target_attrs(user), %{metadata: %{"session_id" => session.id}})
        )

        {:ok, %{session: session, token: token}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_session_by_token(token) when is_binary(token) do
    hashed = token_hash(token)
    now = now()

    Session
    |> where([session], session.token_hash == ^hashed)
    |> where([session], is_nil(session.revoked_at))
    |> where([session], session.expires_at > ^now)
    |> Repo.one()
    |> case do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  def revoke_session(%Session{} = session) do
    result =
      session
      |> Session.changeset(%{revoked_at: now()})
      |> Repo.update()

    with {:ok, revoked} <- result do
      Audit.record(
        "session.revoked",
        %{actor_type: "auth_session", actor_id: revoked.id},
        %{target_type: "auth_session", target_id: revoked.id}
      )

      {:ok, revoked}
    end
  end

  defp get_user_by_email(email) do
    User
    |> where(email: ^normalize_email(email))
    |> preload(:password_credential)
    |> Repo.one()
  end

  defp mark_login(%User{} = user) do
    user
    |> User.changeset(%{last_login_at: now()})
    |> Repo.update()
  end

  defp record_login_failure(user, email, reason) do
    Audit.record("login.failure", user, %{
      target_type: if(user, do: "auth_user", else: nil),
      target_id: user && user.id,
      severity: "warning",
      metadata: %{"email" => email, "reason" => reason}
    })
  end

  defp target_attrs(%User{id: id}) do
    %{target_type: "auth_user", target_id: id}
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, to_string(key), default))
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp now, do: DateTime.utc_now()

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp token_hash(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end
end
