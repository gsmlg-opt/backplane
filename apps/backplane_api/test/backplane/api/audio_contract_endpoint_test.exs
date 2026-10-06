defmodule Backplane.Api.AudioContractEndpointTest do
  use Backplane.Api.DataCase, async: false
  import Plug.Conn

  alias Backplane.Audio.Config
  alias Backplane.Auth

  defmodule UnreadableBody do
    def read_req_body(_, _), do: raise("unauthorized upload body was read")
    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
  end

  setup do
    observer_owner = self()
    telemetry_id = "observed_audio-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:backplane, :llm_proxy, :request, :stop],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.attributes["operation"] || "", "audio."),
            do: send(observer_owner, {:observed_audio, metadata.attributes})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    env = for key <- [:auth_token, :auth_tokens], do: {key, Application.get_env(:backplane, key)}
    Enum.each(env, fn {key, _} -> Application.delete_env(:backplane, key) end)
    :ok = Config.set_enabled(false)
    :ok = Config.set_policy(%{})

    on_exit(fn ->
      Enum.each(env, fn
        {key, nil} -> Application.delete_env(:backplane, key)
        {key, value} -> Application.put_env(:backplane, key, value)
      end)
    end)

    :ok
  end

  test "missing, invalid and insufficient DB client authorization cannot read or spool uploads" do
    token = client(["llm::models"])

    for {bearer, status} <- [{nil, 401}, {"wrong", 401}, {token, 403}] do
      assert_unread(bearer, status)
    end

    assert :ok = Backplane.Clients.Activity.flush()
  end

  test "OAuth requires the v1 audience and llm::invoke before reading any body" do
    allowed = oauth_token(:v1, ["llm::invoke"])
    denied = oauth_token(:v1, ["llm::models"])
    wrong_audience = oauth_token(:mcp, ["llm::invoke"])
    assert_unread(nil, 401)
    assert_unread(denied, 403)
    assert_unread(wrong_audience, 401)
    conn = upload(allowed)
    assert conn.status == 503
    assert conn.assigns.resource_auth.kind == :oauth
    assert_cleaned(conn)
  end

  test "legacy token retains access alongside DB clients and authorized client uploads clean up" do
    token = client(["llm::invoke"])
    Application.put_env(:backplane, :auth_token, "audio-legacy")

    for bearer <- [token, "audio-legacy"] do
      conn = upload(bearer)
      assert conn.status == 503
      assert get_resp_header(conn, "x-request-id") != []
      assert_cleaned(conn)
    end

    assert :ok = Backplane.Clients.Activity.flush()
  end

  test "authorized multipart duplicates, truncation and storage errors clean up immediately" do
    Application.put_env(:backplane, :auth_token, "audio-legacy")
    parts = [{"file", "clip.wav", "bytes"}, {"model", nil, "asr"}]

    for body <- [
          multipart(parts ++ [{"file", "other.wav", "bytes"}]),
          multipart(parts ++ [{"model", nil, "duplicate"}]),
          String.replace_suffix(multipart(parts), "--boundary--\r\n", "")
        ] do
      conn =
        request(
          "/v1/audio/transcriptions",
          "audio-legacy",
          body,
          "multipart/form-data; boundary=boundary"
        )

      assert conn.status == 400
      assert_receive {:observed_audio, attrs}
      assert attrs["outcome"] == "error"
      assert attrs["metadata"]["audio"]["provider_dispatched"] == "false"
      assert attrs["request_bytes"] == 5
      refute_receive {:observed_audio, _}, 20
      assert :ets.lookup(Plug.Upload.Path, self()) == []
    end

    # Override only this request owner's Plug directory to exercise allocation
    # failure without altering system permissions or another request's files.
    old_dir = :ets.lookup(Plug.Upload.Dir, self())
    :ets.insert(Plug.Upload.Dir, {self(), "/dev/null"})

    try do
      conn = upload("audio-legacy")
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "upload_unavailable"
      assert :ets.lookup(Plug.Upload.Path, self()) == []
    after
      :ets.delete(Plug.Upload.Dir, self())
      :ets.insert(Plug.Upload.Dir, old_dir)
    end
  end

  test "file bytes and speech JSON bytes are bounded independently of content length" do
    Application.put_env(:backplane, :auth_token, "audio-legacy")
    :ok = Config.set_policy(%{"upload_bytes" => 4, "speech_json_bytes" => 8})
    assert upload("audio-legacy").status == 413
    assert :ets.lookup(Plug.Upload.Path, self()) == []
    conn = request("/v1/audio/speech", "audio-legacy", ~s({"input":"hello"}), "application/json")
    assert conn.status == 413
  end

  test "conversation JSON retains exact raw bytes through the public endpoint" do
    Application.put_env(:backplane, :auth_token, "audio-legacy")
    body = ~s({ "model" : "missing/model", "messages": [], "extra": "keep" })
    conn = request("/v1/chat/completions", "audio-legacy", body, "application/json")
    assert conn.status == 404
    assert conn.assigns.raw_body == body
    assert conn.body_params["extra"] == "keep"
  end

  test "admitted malformed JSON and unresolved requests finalize exactly once" do
    Application.put_env(:backplane, :auth_token, "audio-legacy")

    for body <- ["{", ~s({"model":"missing/speech","input":"Private input","voice":"v"})] do
      conn = request("/v1/audio/speech", "audio-legacy", body, "application/json")
      assert conn.status in [400, 503]
      assert_receive {:observed_audio, attrs}
      assert attrs["outcome"] == "error"
      assert attrs["request_bytes"] == byte_size(body)
      assert attrs["metadata"]["audio"]["provider_dispatched"] == "false"
      refute inspect(attrs) =~ "Private input"
      refute_receive {:observed_audio, _}, 20
    end
  end

  defp assert_unread(token, status) do
    for path <- ["/v1/audio/transcriptions", "/v1/audio/speech"] do
      conn =
        Plug.Test.conn(:post, path, "malformed body")
        |> put_req_header("content-type", "multipart/form-data; boundary=boundary")
        |> bearer(token)

      {_, state} = conn.adapter

      conn =
        %{conn | adapter: {UnreadableBody, state}}
        |> Backplane.Api.Endpoint.call(Backplane.Api.Endpoint.init([]))

      assert conn.status == status
      assert %Plug.Conn.Unfetched{} = conn.body_params
      refute conn.private[:audio_observer]
      refute_receive {:observed_audio, _}, 20
      assert :ets.lookup(Plug.Upload.Path, self()) == []
    end
  end

  defp assert_cleaned(conn) do
    assert %Plug.Upload{path: path} = conn.body_params["file"]
    refute File.exists?(path)
    assert :ets.lookup(Plug.Upload.Path, self()) == []
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  defp upload(token) do
    request(
      "/v1/audio/transcriptions",
      token,
      multipart([{"file", "clip.wav", "audio bytes"}, {"model", nil, "asr"}]),
      "multipart/form-data; boundary=boundary"
    )
  end

  defp request(path, token, body, type) do
    Plug.Test.conn(:post, path, body)
    |> put_req_header("content-type", type)
    |> bearer(token)
    |> Backplane.Api.Endpoint.call(Backplane.Api.Endpoint.init([]))
  end

  defp bearer(conn, nil), do: conn
  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp multipart(parts) do
    Enum.map_join(parts, "", fn {name, filename, value} ->
      file = if filename, do: ~s(; filename="#{filename}"), else: ""
      ~s(--boundary\r\ncontent-disposition: form-data; name="#{name}"#{file}\r\n\r\n#{value}\r\n)
    end) <> "--boundary--\r\n"
  end

  defp client(scopes) do
    token = "audio-client-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Backplane.Clients.create_client(%{name: token, token: token, scopes: scopes, active: true})

    token
  end

  defp oauth_token(resource, scopes) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Auth.Accounts.create_user(%{email: "audio-#{unique}@example.test", name: "Audio"})

    {:ok, %{client: client}} =
      Auth.OAuth.create_client(%{
        name: "Audio #{unique}",
        redirect_uris: ["https://client.example.test/callback"],
        scopes: scopes,
        resources: [resource],
        confidential: true,
        pkce: true
      })

    code =
      Repo.insert!(%Boruta.Ecto.Token{
        type: "code",
        value: "audio-code-#{unique}",
        client_id: client.id,
        sub: user.id,
        scope: Enum.join(scopes, " "),
        expires_at: System.system_time(:second) + 60
      })

    {:ok, _} = Auth.TokenResources.bind_issued("code", client.id, code.value, resource)

    oauth_client =
      client.id |> Auth.OAuth.get_client() |> Boruta.Ecto.OauthMapper.to_oauth_schema()

    {:ok, token} =
      Boruta.Ecto.AccessTokens.create(
        %{
          client: oauth_client,
          sub: user.id,
          scope: Enum.join(scopes, " "),
          previous_code: code.value
        },
        refresh_token: true
      )

    {:ok, _} = Auth.TokenResources.bind_issued("access_token", client.id, token.value, resource)
    token.value
  end
end
