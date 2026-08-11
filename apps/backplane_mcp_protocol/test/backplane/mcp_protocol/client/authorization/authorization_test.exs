defmodule Backplane.McpProtocol.Client.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Client.Authorization
  alias Backplane.McpProtocol.Client.Authorization.CredentialStore

  defmodule SecureAdapter do
    @moduledoc false
    @behaviour CredentialStore

    @impl true
    def fetch(key, opts) do
      send(Keyword.fetch!(opts, :owner), {:credential_fetch, key})

      case key do
        {"https://auth.example.com", "client-a"} ->
          {:ok, %{"client_id" => "client-a", "client_secret" => "secret-a"}}

        _other ->
          {:error, :not_found}
      end
    end

    @impl true
    def put(key, credentials, opts) do
      send(Keyword.fetch!(opts, :owner), {:credential_put, key, credentials})
      :ok
    end
  end

  defmodule MisconfiguredAdapter do
    @moduledoc false
  end

  describe "validate_issuer/2 and validate_issuer/3" do
    test "accepts a byte-for-byte issuer match" do
      assert :ok =
               Authorization.validate_issuer(
                 "https://auth.example.com/tenant",
                 "https://auth.example.com/tenant"
               )
    end

    test "rejects case and URI-normalization differences" do
      expected = "https://auth.example.com/tenant/%7Euser"

      assert {:error, :issuer_mismatch} =
               Authorization.validate_issuer(expected, "https://AUTH.example.com/tenant/%7Euser")

      assert {:error, :issuer_mismatch} =
               Authorization.validate_issuer(expected, "https://auth.example.com/tenant/~user")

      assert {:error, :issuer_mismatch} =
               Authorization.validate_issuer(expected, expected <> "/")
    end

    test "always rejects a present mismatched issuer even when support is not advertised" do
      metadata = %{"authorization_response_iss_parameter_supported" => false}

      assert {:error, :issuer_mismatch} =
               Authorization.validate_issuer(
                 "https://auth.example.com",
                 "https://other.example.com",
                 metadata
               )
    end

    test "requires a missing issuer only when metadata advertises it" do
      advertised = %{"authorization_response_iss_parameter_supported" => true}
      not_advertised = %{"authorization_response_iss_parameter_supported" => false}

      assert {:error, :missing_issuer} =
               Authorization.validate_issuer("https://auth.example.com", nil, advertised)

      assert :ok =
               Authorization.validate_issuer("https://auth.example.com", nil, not_advertised)

      assert :ok = Authorization.validate_issuer("https://auth.example.com", nil, %{})
    end

    test "requires the metadata-aware API when a two-argument response omits iss" do
      assert {:error, :issuer_metadata_required} =
               Authorization.validate_issuer("https://auth.example.com", nil)
    end
  end

  describe "select_registration/2" do
    test "prefers pre-registration over CIMD and deprecated DCR" do
      metadata = %{
        "client_id_metadata_document_supported" => true,
        "registration_endpoint" => "https://auth.example.com/register"
      }

      registered = %{client_id: "registered-client"}

      assert {:ok, {:pre_registered, ^registered}} =
               Authorization.select_registration(metadata,
                 pre_registered: registered,
                 client_id_metadata_document: "https://client.example.com/oauth.json",
                 dynamic_client_registration: true
               )
    end

    test "prefers CIMD over deprecated DCR when advertised" do
      metadata = %{
        "client_id_metadata_document_supported" => true,
        "registration_endpoint" => "https://auth.example.com/register"
      }

      client_id = "https://client.example.com/oauth.json"

      assert {:ok, {:client_id_metadata_document, ^client_id}} =
               Authorization.select_registration(metadata,
                 client_id_metadata_document: client_id,
                 dynamic_client_registration: true
               )
    end

    test "uses deprecated DCR only when an endpoint is advertised and support is enabled" do
      endpoint = "https://auth.example.com/register"

      assert {:ok, {:dynamic_client_registration, ^endpoint}} =
               Authorization.select_registration(
                 %{"registration_endpoint" => endpoint},
                 dynamic_client_registration: true
               )

      assert {:error, :registration_unavailable} =
               Authorization.select_registration(%{}, dynamic_client_registration: true)
    end

    test "does not select CIMD unless authorization-server metadata advertises support" do
      assert {:error, :registration_unavailable} =
               Authorization.select_registration(%{},
                 client_id_metadata_document: "https://client.example.com/oauth.json"
               )
    end
  end

  describe "registration_metadata/2" do
    test "adds the required native application type without replacing other fields" do
      metadata = %{"client_name" => "Example", "redirect_uris" => ["http://127.0.0.1/callback"]}

      assert %{
               "application_type" => "native",
               "client_name" => "Example",
               "redirect_uris" => ["http://127.0.0.1/callback"]
             } = Authorization.registration_metadata(metadata, :native)
    end

    test "adds the required web application type and replaces atom or string forms" do
      assert %{"application_type" => "web"} =
               Authorization.registration_metadata(
                 %{"application_type" => "native", application_type: "native"},
                 :web
               )
    end
  end

  describe "CredentialStore" do
    test "delegates exact issuer and client ID keys without normalization" do
      store = [adapter: SecureAdapter, owner: self()]

      assert {:ok, %{"client_secret" => "secret-a"}} =
               CredentialStore.fetch("https://auth.example.com", "client-a", store: store)

      assert_receive {:credential_fetch, {"https://auth.example.com", "client-a"}}

      assert {:error, :not_found} =
               CredentialStore.fetch("https://AUTH.example.com", "client-a", store: store)

      assert_receive {:credential_fetch, {"https://AUTH.example.com", "client-a"}}

      assert {:error, :not_found} =
               CredentialStore.fetch("https://auth.example.com/", "client-a", store: store)

      assert_receive {:credential_fetch, {"https://auth.example.com/", "client-a"}}
    end

    test "delegates writes to the secure adapter under the exact key" do
      credentials = %{"client_id" => "client-b", "client_secret" => "secret-b"}
      store = [adapter: SecureAdapter, owner: self()]

      assert :ok =
               CredentialStore.put(
                 "https://auth.example.com/tenant",
                 "client-b",
                 credentials,
                 store: store
               )

      assert_receive {:credential_put, {"https://auth.example.com/tenant", "client-b"}, ^credentials}
    end

    test "returns an explicit error when no secure adapter is configured" do
      assert {:error, :credential_store_not_configured} =
               CredentialStore.fetch("https://auth.example.com", "client-a", store: nil)
    end

    test "returns an explicit error when the adapter does not implement the contract" do
      assert {:error, :credential_store_unavailable} =
               CredentialStore.fetch(
                 "https://auth.example.com",
                 "client-a",
                 store: [adapter: MisconfiguredAdapter]
               )
    end

    test "rejects invalid keys before invoking the adapter" do
      store = [adapter: SecureAdapter, owner: self()]

      assert {:error, :invalid_credential_key} = CredentialStore.fetch("", "client-a", store: store)
      assert {:error, :invalid_credential_key} = CredentialStore.fetch("https://auth.example.com", "", store: store)
      refute_received {:credential_fetch, _key}
    end
  end
end
