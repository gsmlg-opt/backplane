defmodule Backplane.Api.AudioVoicesEndpointTest do
  use Backplane.Api.DataCase, async: false
  import Plug.Conn

  alias Backplane.Audio.{Binding, Config}
  alias Backplane.Auth
  alias Backplane.LLM.{ModelAlias, Provider, ProviderModel}
  alias Backplane.Settings.Credentials

  setup do
    env = for key <- [:auth_token, :auth_tokens], do: {key, Application.get_env(:backplane, key)}
    Enum.each(env, fn {key, _} -> Application.delete_env(:backplane, key) end)
    :ok = Config.set_enabled(true)
    :ok = Config.set_voices(%{})
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok = Backplane.Settings.set(ModelAlias.provider_setting_key(), [])

    on_exit(fn ->
      Backplane.Clients.Activity.flush()

      Enum.each(env, fn
        {key, nil} -> Application.delete_env(:backplane, key)
        {key, value} -> Application.put_env(:backplane, key, value)
      end)
    end)

    %{token: client(["llm::models"])}
  end

  test "missing, invalid, and invoke-only client tokens cannot discover voices" do
    invoke = client(["llm::invoke"])

    for {token, status} <- [{nil, 401}, {"invalid", 401}, {invoke, 403}] do
      conn = request(token)
      assert conn.status == status
      refute conn.private[:audio_session]
    end
  end

  test "OAuth requires the v1 audience and discovery scope" do
    allowed = oauth_token(:v1, ["llm::models"])
    denied = oauth_token(:v1, ["llm::invoke"])
    wrong_audience = oauth_token(:mcp, ["llm::models"])
    assert request(allowed).status == 200
    assert request(denied).status == 403
    assert request(wrong_audience).status == 401
  end

  test "retired shared token is rejected alongside DB clients" do
    Application.put_env(:backplane, :auth_token, "voices-legacy")
    assert request("voices-legacy").status == 401
  end

  test "enabled audio without eligible speech providers returns an empty list", %{token: token} do
    assert body(request(token)) == %{"object" => "list", "data" => []}
    {provider, _, _} = route("transcription-only", :transcription)
    policy(provider, %{"allow_native" => true, "aliases" => %{}})
    assert body(request(token))["data"] == []
  end

  test "native catalog preserves metadata and merges aliases with public-id shadowing", %{
    token: token
  } do
    {provider, model, _} = route("native")
    {:ok, second} = ProviderModel.create(%{provider_id: provider.id, model: "second"})

    {:ok, _} =
      Binding.create(%{
        provider_id: provider.id,
        provider_model_id: second.id,
        operation: :speech,
        native_protocol: :minimax,
        api_origin: "https://audio.invalid",
        enabled: true
      })

    policy(provider, %{
      "allow_native" => true,
      "aliases" => %{
        "alloy" => "female-shaonv",
        "female-shaonv" => "custom-clone",
        "private" => "custom-clone"
      }
    })

    conn = request(token)
    assert conn.status == 200
    rows = body(conn)["data"]

    assert Enum.find(rows, &(&1["id"] == "alloy")) == %{
             "id" => "alloy",
             "object" => "audio.voice",
             "name" => "少女音色",
             "language" => "中文 (普通话)",
             "provider" => provider.name,
             "native_id" => "female-shaonv",
             "type" => "alias"
           }

    assert Enum.find(rows, &(&1["id"] == "female-shaonv"))["native_id"] == "custom-clone"
    assert Enum.find(rows, &(&1["id"] == "female-shaonv"))["type"] == "alias"
    assert Enum.find(rows, &(&1["id"] == "private"))["name"] == "private"
    assert Enum.find(rows, &(&1["id"] == "private"))["language"] == nil
    assert Enum.find(rows, &(&1["id"] == "Cantonese_ProfessionalHost（F)"))["type"] == "system"
    assert Enum.count(rows, &(&1["id"] == "female-shaonv")) == 1
    assert rows == Enum.sort_by(rows, &{&1["provider"], &1["id"]})

    assert body(
             request(token, "model=" <> URI.encode_www_form(provider.name <> "/" <> model.model))
           )["data"] == rows
  end

  test "policy limits native catalog and aliases, while providers distinguish duplicate voice ids",
       %{token: token} do
    {first, _, _} = route("first")
    {second, _, _} = route("second")
    {without_policy, _, _} = route("unconfigured")
    policy(first, %{"allow_native" => false, "aliases" => %{"alloy" => "female-shaonv"}})
    policy(second, %{"allow_native" => false, "aliases" => %{"alloy" => "custom"}})
    rows = body(request(token))["data"]

    assert Enum.map(rows, &{&1["provider"], &1["id"]}) == [
             {first.name, "alloy"},
             {second.name, "alloy"}
           ]

    refute Enum.any?(rows, &(&1["provider"] == without_policy.name))
  end

  test "model and alias filtering selects the speech provider", %{token: token} do
    {first, model, _} = route("filter-first")
    {second, _, _} = route("filter-second")
    policy(first, %{"allow_native" => false, "aliases" => %{"a" => "female-shaonv"}})
    policy(second, %{"allow_native" => false, "aliases" => %{"b" => "female-shaonv"}})
    {:ok, _} = ModelAlias.put("speech-public", model.id)
    {:ok, _} = ModelAlias.put("speech-chain", "speech-public")
    :ok = ModelAlias.add_provider(first.name)

    for name <- [first.name <> "/" <> model.model, "speech-public", "speech-chain", "speech"] do
      conn = request(token, "model=" <> URI.encode_www_form(name))
      assert conn.status == 200
      assert Enum.map(body(conn)["data"], & &1["provider"]) == [first.name]
    end
  end

  test "disabled and deleted route components are excluded", %{token: token} do
    {provider, model, binding} = route("excluded")
    policy(provider, %{"allow_native" => false, "aliases" => %{"a" => "female-shaonv"}})
    assert length(body(request(token))["data"]) == 1
    {:ok, binding} = Binding.update(binding, %{enabled: false})
    assert body(request(token))["data"] == []

    assert error(request(token, "model=" <> provider.name <> "/speech")) ==
             {404, "model_not_found", "model"}

    {:ok, _} = Binding.update(binding, %{enabled: true})
    {:ok, model} = ProviderModel.update(model, %{enabled: false})
    assert body(request(token))["data"] == []
    {:ok, _} = ProviderModel.update(model, %{enabled: true})
    {:ok, provider} = Provider.update(provider, %{enabled: false})
    assert body(request(token))["data"] == []
    {:ok, provider} = Provider.update(provider, %{enabled: true})
    {:ok, provider} = Provider.soft_delete(provider)
    Repo.update!(Ecto.Changeset.change(provider, enabled: true))
    assert body(request(token))["data"] == []
  end

  test "disabled feature fails consistently for filtered and unfiltered discovery", %{
    token: token
  } do
    :ok = Config.set_enabled(false)

    for query <- ["", "model=missing/speech"] do
      assert error(request(token, query)) == {503, "audio_disabled", "model"}
    end
  end

  test "unknown, unsupported, cyclic, and invalid model filters preserve errors", %{token: token} do
    {provider, _, _} = route("asr", :transcription)
    {:ok, _} = ModelAlias.put("loop-one", "loop-two")
    {:ok, _} = ModelAlias.put("loop-two", "loop-one")
    assert error(request(token, "model=missing/speech")) == {404, "model_not_found", "model"}

    assert error(request(token, "model=" <> provider.name <> "/asr")) ==
             {400, "operation_mismatch", "model"}

    assert error(request(token, "model=loop-one")) == {400, "alias_loop", "model"}

    for query <- ["model=", "model=%20%20", "model[]=speech", "model[name]=speech"] do
      assert error(request(token, query)) == {400, "invalid_parameter", "model"}
    end
  end

  test "discovery needs no provider credential or media admission", %{token: token} do
    {provider, _, _} = route("no-dispatch")
    policy(provider, %{"allow_native" => false, "aliases" => %{"alloy" => "female-shaonv"}})
    :ok = Credentials.delete(provider.credential)

    for query <- ["", "model=" <> provider.name <> "/speech"] do
      conn = request(token, query)
      assert conn.status == 200
      assert length(body(conn)["data"]) == 1
      refute conn.private[:audio_session]
      refute conn.private[:audio_observer]
      assert :ets.lookup(Plug.Upload.Path, self()) == []
      refute conn.resp_body =~ "offline-secret"
      refute conn.resp_body =~ provider.credential
    end
  end

  defp route(name, operation \\ :speech) do
    unique = System.unique_integer([:positive])
    credential = "voices-credential-#{unique}"
    {:ok, _} = Credentials.store(credential, "offline-secret", "llm")
    {:ok, provider} = Provider.create(%{name: name, credential: credential})
    model_name = if operation == :speech, do: "speech", else: "asr"
    {:ok, model} = ProviderModel.create(%{provider_id: provider.id, model: model_name})

    {:ok, binding} =
      Binding.create(%{
        provider_id: provider.id,
        provider_model_id: model.id,
        operation: operation,
        native_protocol: :minimax,
        api_origin: "https://audio.invalid",
        enabled: true
      })

    {provider, model, binding}
  end

  defp policy(provider, value),
    do: Config.set_voices(Map.put(Config.voices(), provider.name, value))

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp error(conn), do: {conn.status, body(conn)["error"]["code"], body(conn)["error"]["param"]}

  defp request(token, query \\ "") do
    path = "/v1/audio/voices" <> if(query == "", do: "", else: "?" <> query)
    conn = Plug.Test.conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
  end

  defp client(scopes) do
    {:ok, _client, token} =
      Backplane.Clients.issue_client(%{
        name: "endpoint-client-#{System.unique_integer([:positive])}",
        scopes: scopes,
        active: true
      })

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
