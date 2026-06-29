defmodule Backplane.Accounts do
  @moduledoc """
  Human identity and upstream auth-provider context for Backplane inbound OAuth.
  """

  import Ecto.Query

  alias Backplane.Accounts.{AuthProvider, User, UserIdentity}
  alias Backplane.Repo
  alias Backplane.Settings.Encryption
  alias Boruta.Oauth.ResourceOwner

  @type provision_result :: %{user: User.t(), identity: UserIdentity.t()}

  @spec list_auth_providers() :: [AuthProvider.t()]
  def list_auth_providers do
    AuthProvider
    |> order_by(:slug)
    |> Repo.all()
    |> Enum.map(&sanitize_provider/1)
  end

  @spec get_auth_provider_by_slug(String.t()) :: AuthProvider.t() | nil
  def get_auth_provider_by_slug(slug) when is_binary(slug) do
    AuthProvider
    |> Repo.get_by(slug: normalize_slug(slug))
    |> sanitize_provider()
  end

  @spec create_auth_provider(map()) :: {:ok, AuthProvider.t()} | {:error, Ecto.Changeset.t()}
  def create_auth_provider(attrs) when is_map(attrs) do
    result =
      %AuthProvider{}
      |> AuthProvider.changeset(attrs)
      |> Repo.insert()

    sanitize_result(result)
  end

  @spec update_auth_provider(AuthProvider.t(), map()) ::
          {:ok, AuthProvider.t()} | {:error, Ecto.Changeset.t()}
  def update_auth_provider(%AuthProvider{} = provider, attrs) when is_map(attrs) do
    result =
      provider
      |> AuthProvider.changeset(attrs)
      |> Repo.update()

    sanitize_result(result)
  end

  @spec rotate_auth_provider_secret(AuthProvider.t(), String.t()) ::
          {:ok, AuthProvider.t()} | {:error, Ecto.Changeset.t()}
  def rotate_auth_provider_secret(%AuthProvider{} = provider, secret) when is_binary(secret) do
    result =
      provider
      |> AuthProvider.secret_changeset(secret)
      |> Repo.update()

    sanitize_result(result)
  end

  @spec fetch_auth_provider_secret(AuthProvider.t() | String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :decryption_failed}
  def fetch_auth_provider_secret(%AuthProvider{encrypted_client_secret: encrypted}) do
    Encryption.decrypt(encrypted)
  end

  def fetch_auth_provider_secret(slug) when is_binary(slug) do
    case get_auth_provider_by_slug(slug) do
      nil -> {:error, :not_found}
      provider -> fetch_auth_provider_secret(provider)
    end
  end

  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  @spec list_users() :: [User.t()]
  def list_users do
    User |> order_by(:email) |> Repo.all()
  end

  @spec get_user_by_identity(String.t(), String.t()) :: User.t() | nil
  def get_user_by_identity(provider_id, subject)
      when is_binary(provider_id) and is_binary(subject) do
    UserIdentity
    |> where(provider_id: ^provider_id, subject: ^subject)
    |> preload(:user)
    |> Repo.one()
    |> case do
      %UserIdentity{user: user} -> user
      nil -> nil
    end
  end

  @spec provision_federated_user(AuthProvider.t(), map()) ::
          {:ok, provision_result()} | {:error, term()}
  def provision_federated_user(%AuthProvider{} = provider, claims) when is_map(claims) do
    with {:ok, subject} <- fetch_claim(claims, "sub") do
      now = DateTime.utc_now()
      email = claims_value(claims, "email")
      name = claims_value(claims, "name")
      raw_claims = stringify_keys(claims)

      provider
      |> provision_identity(subject, email, name, raw_claims, now)
      |> recover_identity_conflict(provider, subject, email, name, raw_claims, now)
    end
  end

  @spec to_resource_owner(User.t()) :: ResourceOwner.t()
  def to_resource_owner(%User{} = user) do
    %ResourceOwner{
      sub: user.id,
      username: user.email,
      last_login_at: user.last_login_at,
      extra_claims: %{
        "email" => user.email,
        "name" => user.name
      }
    }
  end

  @spec bootstrap_admin_emails() :: [String.t()]
  def bootstrap_admin_emails do
    :backplane
    |> Application.get_env(:bootstrap_admin_emails, [])
    |> normalize_email_list()
  end

  @spec bootstrap_admin?(User.t() | String.t() | nil) :: boolean()
  def bootstrap_admin?(%User{email: email}), do: bootstrap_admin?(email)

  def bootstrap_admin?(email) when is_binary(email) do
    normalized = normalize_optional_email(email)
    is_binary(normalized) and normalized in bootstrap_admin_emails()
  end

  def bootstrap_admin?(_email), do: false

  defp provision_identity(provider, subject, email, name, raw_claims, now) do
    Repo.transaction(fn ->
      case Repo.get_by(UserIdentity, provider_id: provider.id, subject: subject) do
        nil ->
          create_user_identity(provider, subject, email, name, raw_claims, now)

        %UserIdentity{} = identity ->
          update_user_identity(identity, email, name, raw_claims, now)
      end
    end)
  end

  defp recover_identity_conflict(
         {:error, %Ecto.Changeset{} = changeset},
         provider,
         subject,
         email,
         name,
         raw_claims,
         now
       ) do
    if identity_conflict?(changeset) do
      provision_identity(provider, subject, email, name, raw_claims, now)
    else
      {:error, changeset}
    end
  end

  defp recover_identity_conflict(result, _provider, _subject, _email, _name, _raw_claims, _now),
    do: result

  defp create_user_identity(provider, subject, email, name, raw_claims, now) do
    with {:ok, user} <-
           %User{}
           |> User.changeset(%{
             email: email,
             name: name,
             active: true,
             last_login_at: now
           })
           |> Repo.insert(),
         {:ok, identity} <-
           %UserIdentity{}
           |> UserIdentity.changeset(%{
             user_id: user.id,
             provider_id: provider.id,
             subject: subject,
             email: email,
             name: name,
             raw_claims: raw_claims,
             last_login_at: now
           })
           |> Repo.insert() do
      %{user: user, identity: identity}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_user_identity(%UserIdentity{} = identity, email, name, raw_claims, now) do
    with {:ok, identity} <-
           identity
           |> UserIdentity.claim_changeset(%{
             email: email,
             name: name,
             raw_claims: raw_claims,
             last_login_at: now
           })
           |> Repo.update(),
         user = Repo.get!(User, identity.user_id),
         {:ok, user} <-
           user
           |> User.changeset(%{
             email: email || user.email,
             name: name || user.name,
             last_login_at: now
           })
           |> Repo.update() do
      %{user: user, identity: identity}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp identity_conflict?(%Ecto.Changeset{data: %UserIdentity{}, errors: errors}) do
    Enum.any?(errors, fn
      {:provider_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp identity_conflict?(_changeset), do: false

  defp fetch_claim(claims, key) do
    case claims_value(claims, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_claim, key}}
    end
  end

  defp claims_value(claims, key) do
    Map.get(claims, key) || Map.get(claims, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(claims, key)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp sanitize_result({:ok, %AuthProvider{} = provider}), do: {:ok, sanitize_provider(provider)}
  defp sanitize_result(result), do: result

  defp sanitize_provider(nil), do: nil
  defp sanitize_provider(%AuthProvider{} = provider), do: %{provider | client_secret: nil}

  defp normalize_slug(slug), do: slug |> String.trim() |> String.downcase()

  defp normalize_email_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_email_list()
  end

  defp normalize_email_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_email/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_email_list(_value), do: []

  defp normalize_optional_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    if email == "", do: nil, else: email
  end

  defp normalize_optional_email(_email), do: nil
end
