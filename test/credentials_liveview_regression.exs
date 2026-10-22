# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
if Mix.env() != :dev, do: raise("run with MIX_ENV=dev mix run --no-start")

ExUnit.start(autorun: false)
Logger.configure(level: :warning)

for application <- [:gaoxy_http, :phoenix, :phoenix_live_view, :phoenix_live_reload, :req] do
  {:ok, _} = Application.ensure_all_started(application)
end

defmodule Backplane.CredentialsLiveViewRegression do
  use ExUnit.Case, async: false

  alias Backplane.Settings.{Credential, Credentials, Encryption}

  defmodule FixtureVault do
    use GenServer

    def start_link(credentials),
      do: GenServer.start_link(__MODULE__, credentials, name: Credentials.Vault)

    def init(credentials) do
      :ets.new(:credentials_vault, [:named_table, :public, :set])
      :ets.new(:credential_token_cache, [:named_table, :public, :set])

      for {name, auth_type, plaintext} <- credentials do
        credential = %Credential{
          id: Ecto.UUID.generate(),
          name: name,
          kind: "llm",
          encrypted_value: Encryption.encrypt(plaintext),
          metadata: %{"auth_type" => auth_type},
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        :ets.insert(:credentials_vault, {name, credential})
      end

      {:ok, nil}
    end

    def handle_call(:reload_all, _from, state), do: {:reply, :ok, state}
  end

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Backplane.PubSub})
    start_supervised!({Phoenix.SessionProcess, []})

    credentials = [
      {"api-key", "api_key", "synthetic-key-1234"},
      {"google-expired", "google_oauth",
       Jason.encode!(%{"access_token" => "stored-google-2345", "expires_at" => 0})},
      {"claude-expired", "anthropic_oauth",
       Jason.encode!(%{
         "claudeAiOauth" => %{"accessToken" => "stored-claude-3456", "expiresAt" => 0}
       })},
      {"codex-expired", "openai_oauth",
       Jason.encode!(%{"tokens" => %{"access_token" => "stored-codex-4567"}})},
      {"client-credentials", "oauth2_client_credentials", "synthetic-client-secret"},
      {"malformed-oauth", "figma_oauth", "invalid-json-secret"},
      {"missing-token", "xai_oauth", Jason.encode!(%{"refresh_token" => "must-not-render"})},
      {"short-key", "api_key", "abc"},
      {"unicode-key", "api_key", "synthetic-密钥测试"}
    ]

    start_supervised!({FixtureVault, credentials})
    endpoint = Backplane.Admin.Endpoint
    config = Application.fetch_env!(:backplane_admin, endpoint)

    Application.put_env(
      :backplane_admin,
      endpoint,
      Keyword.merge(config,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: 0],
        code_reloader: false,
        debug_errors: false,
        watchers: []
      )
    )

    start_supervised!(endpoint)
    {:ok, {_, port}} = Gaoxy.PhoenixAdapter.server_info(endpoint, :http)
    %{port: port}
  end

  test "hints read stored values without a Repo, token exchange, refresh or cache writes" do
    for {name, expected} <- [
          {"api-key", "...1234"},
          {"google-expired", "...2345"},
          {"claude-expired", "...3456"},
          {"codex-expired", "...4567"},
          {"client-credentials", "..."},
          {"malformed-oauth", "..."},
          {"missing-token", "..."},
          {"short-key", "..."},
          {"unicode-key", "...密钥测试"},
          {"absent", "..."}
        ] do
      assert Credentials.fetch_hint(name) == expected
    end

    assert :ets.tab2list(:credential_token_cache) == []
    refute Process.whereis(Backplane.Repo)
  end

  test "populated credentials join and Add Credential patch work over Gaoxy", %{port: port} do
    stored_credentials = :ets.tab2list(:credentials_vault)
    url = "http://localhost:#{port}/system/credentials"
    response = Req.get!(url, retry: false, receive_timeout: 2_000)
    assert response.status == 200
    document = Floki.parse_document!(response.body)
    [root] = Floki.find(document, "[data-phx-main]")
    [root_id] = Floki.attribute(root, "id")
    [session] = Floki.attribute(root, "data-phx-session")
    [static] = Floki.attribute(root, "data-phx-static")
    [csrf] = document |> Floki.find("meta[name=csrf-token]") |> Floki.attribute("content")

    cookie =
      response.headers["set-cookie"] |> Enum.map(&hd(String.split(&1, ";"))) |> Enum.join("; ")

    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(socket, [
        "GET /live/websocket?vsn=2.0.0&_csrf_token=#{URI.encode_www_form(csrf)} HTTP/1.1\r\n",
        "Host: localhost:#{port}\r\nCookie: #{cookie}\r\n",
        "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      ])

    assert read_headers(socket) =~ "HTTP/1.1 101"
    topic = "lv:#{root_id}"

    send_message(socket, [
      "1",
      "1",
      topic,
      "phx_join",
      %{
        "url" => url,
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0},
        "session" => session,
        "static" => static
      }
    ])

    assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok", "response" => joined}] =
             read_message(socket)

    assert Jason.encode!(joined) =~ "credentials-table"

    send_message(socket, ["1", "2", topic, "live_patch", %{"url" => url <> "/new"}])

    assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok", "response" => patched}] =
             read_message(socket)

    form_diff = Jason.encode!(patched)
    assert String.contains?(form_diff, "cred-name")
    assert String.contains?(form_diff, "cred-secret")
    assert String.contains?(form_diff, "save_credential")
    send_message(socket, [nil, "3", "phoenix", "heartbeat", %{}])
    assert [nil, "3", "phoenix", "phx_reply", %{"status" => "ok"}] = read_message(socket)
    assert :ets.tab2list(:credentials_vault) == stored_credentials
    assert :ets.tab2list(:credential_token_cache) == []
  end

  defp read_headers(socket, bytes \\ "") do
    if String.ends_with?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, next} = :gen_tcp.recv(socket, 1, 2_000)
      read_headers(socket, bytes <> next)
    end
  end

  defp send_message(socket, message) do
    bytes = Jason.encode!(message)
    size = byte_size(bytes)
    length = if size < 126, do: <<1::1, size::7>>, else: <<1::1, 126::7, size::16>>
    :ok = :gen_tcp.send(socket, [<<0x81>>, length, <<0::32>>, bytes])
  end

  defp read_message(socket) do
    assert {:ok, <<0x81, 0::1, length::7>>} = :gen_tcp.recv(socket, 2, 2_000)

    size =
      case length do
        126 ->
          {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 2_000)
          size

        127 ->
          {:ok, <<size::64>>} = :gen_tcp.recv(socket, 8, 2_000)
          size

        size ->
          size
      end

    {:ok, payload} = :gen_tcp.recv(socket, size, 2_000)
    Jason.decode!(payload)
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 2)
