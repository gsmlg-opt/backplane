defmodule Backplane.Proxy.ProtocolClientTest do
  use Backplane.DataCase, async: false

  alias Backplane.MCP.Info
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeaders
  alias Backplane.Proxy.ProtocolClient
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  describe "registry names" do
    test "uses local tuple keys without dynamic atoms" do
      assert {:via, Registry, {Backplane.Proxy.ProcessRegistry, {"github", :client}}} =
               ProtocolClient.client_name("github")

      assert {:via, Registry, {Backplane.Proxy.ProcessRegistry, {"github", :transport}}} =
               ProtocolClient.transport_name("github")
    end
  end

  describe "protocol_preference/1" do
    test "maps the two explicit versions and auto exactly" do
      assert ProtocolClient.protocol_preference(%{protocol_version: "2025-11-25"}) ==
               "2025-11-25"

      assert ProtocolClient.protocol_preference(%{protocol_version: "2026-07-28"}) ==
               "2026-07-28"

      assert ProtocolClient.protocol_preference(%{protocol_version: "auto"}) == :auto
    end

    test "defaults missing and malformed values to the legacy version without raising" do
      for config <- [
            %{},
            %{protocol_version: nil},
            %{protocol_version: ""},
            %{protocol_version: "2024-11-05"},
            %{protocol_version: 20_251_125},
            nil,
            :invalid
          ] do
        assert ProtocolClient.protocol_preference(config) == "2025-11-25"
      end
    end
  end

  describe "client_options/1" do
    test "builds the exact package contract for an HTTP client" do
      config = http_config(timeout: 12_345, headers: %{"X-Static" => "configured"})

      options = ProtocolClient.client_options(config)

      assert options[:name] == ProtocolClient.client_name("github")
      assert options[:transport_name] == ProtocolClient.transport_name("github")
      assert options[:protocol_version] == "2026-07-28"
      assert options[:client_info] == %{"name" => "backplane", "version" => Info.version()}
      assert options[:capabilities] == %{}
      assert options[:timeout] == 12_345

      assert {:streamable_http, transport_options} = options[:transport]
      assert transport_options[:url] == "https://mcp.example.test/custom/endpoint"
      assert transport_options[:headers] == %{"X-Static" => "configured"}
      assert is_function(transport_options[:headers_provider], 0)
    end

    test "uses a safe thirty-second timeout for missing, nil, and invalid values" do
      assert ProtocolClient.client_options(http_config())[:timeout] == 30_000

      for invalid <- [nil, 0, -1, "30000", :infinity] do
        assert ProtocolClient.client_options(http_config(timeout: invalid))[:timeout] == 30_000
      end
    end

    test "normalizes stdio command, args, and env to the package shape" do
      config = %{
        prefix: "filesystem",
        transport: "stdio",
        protocol_version: "auto",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem"],
        env: %{"HOME" => "/srv/backplane"}
      }

      assert {:stdio, stdio_options} = ProtocolClient.client_options(config)[:transport]

      assert stdio_options == [
               command: "npx",
               args: ["-y", "@modelcontextprotocol/server-filesystem"],
               env: %{"HOME" => "/srv/backplane"}
             ]

      assert {:stdio, defaults} =
               config
               |> Map.merge(%{args: nil, env: nil})
               |> ProtocolClient.client_options()
               |> Keyword.fetch!(:transport)

      assert defaults == [command: "npx", args: [], env: %{}]
    end
  end

  describe "HTTP headers provider" do
    test "resolves rotated bearer credentials on every invocation" do
      credential = unique_name("rotating-bearer")
      assert {:ok, _stored} = Credentials.store(credential, "first-secret", "upstream")
      sync_vault()

      provider =
        http_config(
          credential: credential,
          auth_scheme: "bearer",
          headers: %{"Authorization" => "static-value"}
        )
        |> ProtocolClient.client_options()
        |> headers_provider()

      assert {:ok, %{"authorization" => "Bearer first-secret"}} =
               RequestHeaders.resolve(%{"Authorization" => "static-value"}, provider)

      assert {:ok, _rotated} = Credentials.rotate(credential, "second-secret")
      sync_vault()

      assert {:ok, %{"authorization" => "Bearer second-secret"}} =
               RequestHeaders.resolve(%{"Authorization" => "static-value"}, provider)
    end

    test "canonicalizes dynamic auth keys and lets them override static headers" do
      credential = unique_name("custom-header")
      assert {:ok, _stored} = Credentials.store(credential, "dynamic-secret", "upstream")
      sync_vault()

      provider =
        http_config(
          credential: credential,
          auth_scheme: "custom_header",
          auth_header_name: "X-Service-Key"
        )
        |> ProtocolClient.client_options()
        |> headers_provider()

      assert {:ok, headers} =
               RequestHeaders.resolve(
                 %{"X-Service-Key" => "static-secret", "X-Static" => "kept"},
                 provider
               )

      assert headers == %{
               "x-service-key" => "dynamic-secret",
               "x-static" => "kept"
             }
    end

    test "preserves the x-api-key auth scheme" do
      credential = unique_name("x-api-key")
      assert {:ok, _stored} = Credentials.store(credential, "api-secret", "upstream")
      sync_vault()

      provider =
        http_config(credential: credential, auth_scheme: "x_api_key")
        |> ProtocolClient.client_options()
        |> headers_provider()

      assert provider.() == {:ok, %{"x-api-key" => "api-secret"}}
    end

    test "does not capture or emit construction and invocation request metadata" do
      provider =
        Task.async(fn ->
          Logger.metadata(request_id: "construction-process-id")
          http_config() |> ProtocolClient.client_options() |> headers_provider()
        end)
        |> Task.await()

      assert Task.async(fn ->
               without_invocation_metadata = provider.()

               Logger.metadata(request_id: "provider-invocation-id")
               with_invocation_metadata = provider.()

               Logger.metadata(request_id: nil)
               after_metadata_clear = provider.()

               {
                 without_invocation_metadata,
                 with_invocation_metadata,
                 after_metadata_clear
               }
             end)
             |> Task.await() ==
               {
                 {:ok, %{}},
                 {:ok, %{}},
                 {:ok, %{}}
               }
    end

    test "returns a sanitized provider error when a credential is unavailable" do
      provider =
        http_config(credential: unique_name("missing"), auth_scheme: "bearer")
        |> ProtocolClient.client_options()
        |> headers_provider()

      assert provider.() == {:error, :credential_unavailable}
    end
  end

  describe "error_message/1" do
    test "exposes only an MCP reason atom" do
      assert ProtocolClient.error_message(%Error{reason: :unsupported_protocol_version}) ==
               "unsupported_protocol_version"
    end

    test "never inspects protocol or connection error payloads" do
      secret = "credential-must-not-leak"

      protocol_message =
        ProtocolClient.error_message(%Error{
          reason: secret,
          message: secret,
          data: %{"credential" => secret}
        })

      connection_message = ProtocolClient.error_message({:connection_failed, secret})

      assert protocol_message == "upstream protocol error"
      assert connection_message == "upstream connection error"
      refute protocol_message =~ secret
      refute connection_message =~ secret
    end
  end

  defp http_config(overrides \\ []) do
    Map.merge(
      %{
        prefix: "github",
        transport: "http",
        protocol_version: "2026-07-28",
        url: "https://mcp.example.test/custom/endpoint",
        headers: %{},
        auth_scheme: "none",
        auth_header_name: nil,
        credential: nil
      },
      Map.new(overrides)
    )
  end

  defp headers_provider(options) do
    {:streamable_http, transport_options} = Keyword.fetch!(options, :transport)
    Keyword.fetch!(transport_options, :headers_provider)
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sync_vault do
    :sys.get_state(Vault)
    :ok
  end
end
