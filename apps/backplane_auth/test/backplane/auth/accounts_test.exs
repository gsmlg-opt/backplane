defmodule Backplane.Auth.AccountsTest do
  use Backplane.Auth.DataCase, async: false

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.{PasswordCredential, Session, User}

  describe "create_user/1" do
    test "creates a local user with normalized email" do
      assert {:ok, %User{} = user} =
               Auth.Accounts.create_user(%{
                 email: "  Alice@Example.COM ",
                 name: "Alice",
                 active: true
               })

      assert user.email == "alice@example.com"
      assert user.name == "Alice"
      assert user.active
    end

    test "enforces unique normalized email" do
      assert {:ok, _user} = Auth.Accounts.create_user(%{email: "alice@example.com"})

      assert {:error, changeset} =
               Auth.Accounts.create_user(%{email: " ALICE@example.com "})

      assert %{email: [_message]} = errors_on(changeset)
    end
  end

  describe "password credentials" do
    test "stores a password hash and never plaintext" do
      user = user!("alice@example.com")

      assert {:ok, %PasswordCredential{} = credential} =
               Auth.Accounts.set_password(user, "correct horse battery staple")

      refute credential.password_hash == "correct horse battery staple"
      assert Bcrypt.verify_pass("correct horse battery staple", credential.password_hash)
    end

    test "authenticates with the correct password and updates last login" do
      user = user!("alice@example.com")
      assert {:ok, _credential} = Auth.Accounts.set_password(user, "correct horse battery staple")

      assert {:ok, %User{} = authed} =
               Auth.Accounts.authenticate(" Alice@Example.COM ", "correct horse battery staple")

      assert authed.id == user.id
      assert %DateTime{} = authed.last_login_at
    end

    test "rejects a wrong password" do
      user = user!("alice@example.com")
      assert {:ok, _credential} = Auth.Accounts.set_password(user, "correct horse battery staple")

      assert {:error, :invalid_credentials} =
               Auth.Accounts.authenticate("alice@example.com", "wrong password")
    end

    test "rejects inactive users" do
      user = user!("alice@example.com")
      assert {:ok, _credential} = Auth.Accounts.set_password(user, "correct horse battery staple")
      assert {:ok, _user} = Auth.Accounts.disable_user(user)

      assert {:error, :inactive} =
               Auth.Accounts.authenticate("alice@example.com", "correct horse battery staple")
    end
  end

  describe "sessions" do
    test "creates, resolves, and revokes browser sessions without storing plaintext tokens" do
      user = user!("alice@example.com")

      assert {:ok, %{session: %Session{} = session, token: token}} =
               Auth.Accounts.create_session(user, %{
                 user_agent: "Mozilla/5.0",
                 ip: "203.0.113.9"
               })

      assert is_binary(token)
      refute session.token_hash == token
      assert session.user_id == user.id
      assert session.user_agent == "Mozilla/5.0"
      assert session.ip == "203.0.113.9"

      assert {:ok, %Session{id: session_id}} = Auth.Accounts.get_session_by_token(token)
      assert session_id == session.id

      assert {:ok, %Session{} = revoked} = Auth.Accounts.revoke_session(session)
      assert %DateTime{} = revoked.revoked_at

      assert {:error, :not_found} = Auth.Accounts.get_session_by_token(token)
    end

    test "lists sessions with users and revokes by id" do
      user = user!("alice@example.com")
      assert {:ok, %{session: session}} = Auth.Accounts.create_session(user)

      assert [%Session{id: session_id, user: %User{email: "alice@example.com"}}] =
               Auth.Accounts.list_sessions()

      assert session_id == session.id

      assert {:ok, %Session{revoked_at: %DateTime{}}} =
               Auth.Accounts.revoke_session_by_id(session.id)
    end

    test "disabling a user revokes active browser sessions" do
      user = user!("alice@example.com")
      assert {:ok, %{session: session, token: token}} = Auth.Accounts.create_session(user)

      assert {:ok, _resolved} = Auth.Accounts.get_session_by_token(token)
      assert {:ok, _disabled} = Auth.Accounts.disable_user(user)

      assert {:error, :not_found} = Auth.Accounts.get_session_by_token(token)
      assert %Session{revoked_at: %DateTime{}} = Backplane.Repo.get!(Session, session.id)
    end
  end

  describe "list_users/1" do
    test "returns users ordered by email" do
      charlie = user!("charlie@example.com")
      alice = user!("alice@example.com")
      bob = user!("bob@example.com")

      assert [^alice, ^bob, ^charlie] = Auth.Accounts.list_users()
    end
  end

  defp user!(email) do
    assert {:ok, user} = Auth.Accounts.create_user(%{email: email, name: email})
    user
  end
end
