defmodule Backplane.Auth.AuditTest do
  use Backplane.Auth.DataCase, async: false

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.AuditEvent

  describe "record/3" do
    test "writes append-only audit events" do
      assert {:ok, %AuditEvent{} = event} =
               Auth.Audit.record("login.success", nil, %{
                 target_type: "auth_user",
                 target_id: "user-1",
                 severity: "info",
                 metadata: %{"email" => "alice@example.com"}
               })

      assert event.event_type == "login.success"
      assert event.target_type == "auth_user"
      assert event.target_id == "user-1"
      assert event.severity == "info"
      assert event.metadata["email"] == "alice@example.com"
    end

    test "redacts secrets from metadata" do
      assert {:ok, event} =
               Auth.Audit.record("login.failure", nil, %{
                 metadata: %{
                   "password" => "secret",
                   "refresh_token" => "refresh",
                   "client_secret" => "client-secret",
                   "authorization_code" => "code",
                   "session_token" => "session",
                   "safe" => "value"
                 }
               })

      refute Map.has_key?(event.metadata, "password")
      refute Map.has_key?(event.metadata, "refresh_token")
      refute Map.has_key?(event.metadata, "client_secret")
      refute Map.has_key?(event.metadata, "authorization_code")
      refute Map.has_key?(event.metadata, "session_token")
      assert event.metadata["safe"] == "value"
    end

    test "filters audit events by event type, severity, and target type" do
      assert {:ok, _event} =
               Auth.Audit.record("login.success", nil, %{
                 target_type: "auth_user",
                 target_id: "user-1",
                 severity: "info"
               })

      assert {:ok, refresh_reuse} =
               Auth.Audit.record("token.refresh_reuse_detected", nil, %{
                 target_type: "oauth_token",
                 target_id: "token-1",
                 severity: "error"
               })

      assert [^refresh_reuse] =
               Auth.Audit.list_events(
                 event_type: "token.refresh_reuse_detected",
                 severity: "error",
                 target_type: "oauth_token"
               )
    end
  end

  describe "login events" do
    test "successful and failed authentication attempts are audited" do
      assert {:ok, user} = Auth.Accounts.create_user(%{email: "alice@example.com"})
      assert {:ok, _credential} = Auth.Accounts.set_password(user, "correct horse battery staple")

      assert {:ok, _user} =
               Auth.Accounts.authenticate("alice@example.com", "correct horse battery staple")

      assert {:error, :invalid_credentials} =
               Auth.Accounts.authenticate("alice@example.com", "wrong")

      events = Auth.Audit.list_events()
      assert Enum.any?(events, &(&1.event_type == "login.success"))
      assert Enum.any?(events, &(&1.event_type == "login.failure"))
    end
  end
end
