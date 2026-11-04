defmodule Backplane.LLM.ResponseRouteTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi, ResponseRoute}
  alias Backplane.Settings.Credentials

  setup do
    suffix = System.unique_integer([:positive])
    name = "responses-routes-#{suffix}"
    {:ok, credential} = Credentials.store(name, "test-key", "llm")
    {:ok, provider} = Provider.create(%{name: name, credential: name})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://mock.example/v1",
        native_protocols: [:openai_responses],
        responses_lifecycle: true
      })

    :sys.get_state(Credentials.Vault)
    on_exit(fn -> :sys.get_state(Credentials.Vault) end)

    %{provider: provider, api: api, credential: credential, conn: owner_conn("owner-1")}
  end

  test "admission is durable before the ID and lookup reads only the durable index", ctx do
    assert {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    persisted = Repo.get!(ResponseRoute, route.id)
    assert persisted.status == "submitting"
    assert is_nil(persisted.response_id)
    assert persisted.credential_id == ctx.credential.id
    assert persisted.api_target == "https://mock.example/v1"
    refute inspect(persisted) =~ "test-key"
    assert DateTime.diff(persisted.expires_at, persisted.inserted_at) in 86_399..86_400

    assert :ok = ResponseRoute.bind(route, "resp_1", "queued")
    # Discard the admitted struct; a fresh lookup needs no process-owned state.
    assert {:ok, loaded, provider, api} = ResponseRoute.lookup(ctx.conn, "resp_1")
    assert loaded.id == route.id
    assert loaded.status == "queued"
    assert provider.id == ctx.provider.id
    assert api.id == ctx.api.id
  end

  test "open access is not a durable owner", ctx do
    conn = Plug.Test.conn(:post, "/v1/responses")

    assert {:error, :responses_identity_required} =
             ResponseRoute.admit(conn, ctx.provider, ctx.api)

    assert Repo.aggregate(ResponseRoute, :count) == 0
  end

  test "original API target is retained without URL credentials or query secrets", ctx do
    {:ok, api} =
      ProviderApi.update(ctx.api, %{
        base_url:
          "https://user:private-password@mock.example/v1?api_key=private-query#private-fragment"
      })

    assert {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, api)
    assert route.api_target == "https://mock.example/v1"
    refute inspect(route) =~ "private-"
  end

  test "wrong client, OAuth subject and tenant cannot access a response", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    :ok = ResponseRoute.bind(route, "resp_private", "in_progress")

    assert {:error, :response_not_found} =
             ResponseRoute.lookup(owner_conn("owner-2"), "resp_private")

    oauth = fn subject, tenant ->
      Plug.Test.conn(:get, "/v1/responses/resp_oauth")
      |> Plug.Conn.assign(:resource_auth, %{
        kind: :oauth,
        client_id: "oauth-client",
        subject: subject,
        principal_metadata: %{"memory_partition_id" => tenant}
      })
    end

    {:ok, oauth_route} = ResponseRoute.admit(oauth.("user-1", "tenant-1"), ctx.provider, ctx.api)
    :ok = ResponseRoute.bind(oauth_route, "resp_oauth", "queued")

    for conn <- [oauth.("user-2", "tenant-1"), oauth.("user-1", "tenant-2")] do
      assert {:error, :response_not_found} = ResponseRoute.lookup(conn, "resp_oauth")
    end
  end

  test "same owner and ID cannot be rebound to a different admission", ctx do
    {:ok, first} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    {:ok, second} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    assert :ok = ResponseRoute.bind(first, "resp_collision", "queued")

    assert {:error, :response_id_conflict} =
             ResponseRoute.bind(second, "resp_collision", "queued")

    assert {:ok, loaded, _, _} = ResponseRoute.lookup(ctx.conn, "resp_collision")
    assert loaded.id == first.id
    assert :ok = ResponseRoute.bind(first, "resp_collision", "in_progress")
    assert {:error, :response_id_conflict} = ResponseRoute.bind(first, "resp_different", "queued")
  end

  test "same upstream ID cannot be granted to two owners", ctx do
    {:ok, first} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    {:ok, second} = ResponseRoute.admit(owner_conn("owner-2"), ctx.provider, ctx.api)
    assert :ok = ResponseRoute.bind(first, "resp_same", "queued")
    assert {:error, :response_id_conflict} = ResponseRoute.bind(second, "resp_same", "queued")

    assert {:error, :response_not_found} =
             ResponseRoute.lookup(owner_conn("owner-2"), "resp_same")
  end

  test "a different provider cannot capture an owner's existing response ID", ctx do
    {:ok, first} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    assert :ok = ResponseRoute.bind(first, "resp_cross_provider", "queued")

    {:ok, provider} =
      Provider.create(%{
        name: "another-responses-provider-#{System.unique_integer([:positive])}",
        credential: ctx.provider.credential
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://another-mock.example/v1",
        native_protocols: [:openai_responses],
        responses_lifecycle: true
      })

    {:ok, second} = ResponseRoute.admit(ctx.conn, provider, api)

    assert {:error, :response_id_conflict} =
             ResponseRoute.bind(second, "resp_cross_provider", "queued")

    assert {:ok, route, original_provider, _api} =
             ResponseRoute.lookup(ctx.conn, "resp_cross_provider")

    assert route.id == first.id
    assert original_provider.id == ctx.provider.id
  end

  test "expired routes fail closed and their IDs are not silently recycled", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    :ok = ResponseRoute.bind(route, "resp_expired", "completed")
    Repo.update!(Ecto.Changeset.change(route, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    assert {:error, :response_expired} = ResponseRoute.lookup(ctx.conn, "resp_expired")
    {:ok, replacement} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)

    assert {:error, :response_id_conflict} =
             ResponseRoute.bind(replacement, "resp_expired", "queued")
  end

  test "provider target, headers and credential changes invalidate a route", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    :ok = ResponseRoute.bind(route, "resp_pinned", "queued")

    {:ok, changed_api} = ProviderApi.update(ctx.api, %{base_url: "https://changed.example/v1"})
    assert {:error, :response_route_changed} = ResponseRoute.lookup(ctx.conn, "resp_pinned")
    {:ok, _api} = ProviderApi.update(changed_api, %{base_url: ctx.api.base_url})
    assert {:ok, _, _, _} = ResponseRoute.lookup(ctx.conn, "resp_pinned")

    {:ok, changed_provider} =
      Provider.update(ctx.provider, %{default_headers: %{"openai-project" => "new"}})

    assert {:error, :response_route_changed} = ResponseRoute.lookup(ctx.conn, "resp_pinned")
    {:ok, _provider} = Provider.update(changed_provider, %{default_headers: %{}})

    {:ok, _credential} = Credentials.store(ctx.provider.credential, "rotated-key", "llm")
    assert {:error, :response_route_changed} = ResponseRoute.lookup(ctx.conn, "resp_pinned")
  end

  test "dispatch revalidation detects credential or routing changes before an ID exists", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    assert :ok = ResponseRoute.verify(route)
    assert {:ok, snapshot} = ResponseRoute.credential_snapshot(route)
    assert snapshot.id == ctx.credential.id
    assert snapshot.encrypted_value == ctx.credential.encrypted_value

    {:ok, _credential} =
      Credentials.store(ctx.provider.credential, "rotated-before-dispatch", "llm")

    assert {:error, :response_route_changed} = ResponseRoute.verify(route)
    assert {:error, :response_route_changed} = ResponseRoute.credential_snapshot(route)
    assert is_nil(Repo.get!(ResponseRoute, route.id).response_id)
  end

  test "credential snapshot uses the pinned database version even if the Vault cache is stale",
       ctx do
    {:ok, current} = Credentials.store(ctx.provider.credential, "current-db-key", "llm")
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    :ok = Credentials.Vault.put(ctx.credential)
    on_exit(fn -> Credentials.Vault.put(current) end)

    assert {:ok, snapshot} = ResponseRoute.credential_snapshot(route)
    assert snapshot.encrypted_value == current.encrypted_value
    refute snapshot.encrypted_value == ctx.credential.encrypted_value
  end

  test "removed or disabled providers and capability switches fail closed", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    :ok = ResponseRoute.bind(route, "resp_disabled", "queued")
    {:ok, disabled_api} = ProviderApi.update(ctx.api, %{responses_lifecycle: false})
    assert {:error, :response_route_changed} = ResponseRoute.lookup(ctx.conn, "resp_disabled")
    {:ok, _api} = ProviderApi.update(disabled_api, %{responses_lifecycle: true})
    assert {:ok, _, _, _} = ResponseRoute.lookup(ctx.conn, "resp_disabled")
    {:ok, _provider} = Provider.soft_delete(ctx.provider)
    assert {:error, :response_route_changed} = ResponseRoute.lookup(ctx.conn, "resp_disabled")
  end

  test "status persists uncertainty and terminal states do not regress", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    assert :ok = ResponseRoute.uncertain(route)
    assert Repo.get!(ResponseRoute, route.id).status == "uncertain"
    assert :ok = ResponseRoute.bind(route, "resp_status", "queued")
    assert :ok = ResponseRoute.mark(route, "in_progress")
    assert :ok = ResponseRoute.mark(route, "completed")
    assert :ok = ResponseRoute.mark(route, "in_progress")
    assert :ok = ResponseRoute.uncertain(route)
    assert Repo.get!(ResponseRoute, route.id).status == "completed"
    assert :ok = ResponseRoute.mark(route, "deleted")
    assert {:error, :response_not_found} = ResponseRoute.lookup(ctx.conn, "resp_status")
  end

  test "unsafe response IDs are never indexed", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)

    for id <- ["../secret", "resp/other", "resp?query", "", nil] do
      assert {:error, :invalid_response_id} = ResponseRoute.bind(route, id, "queued")
    end
  end

  test "database admission failure is explicit", ctx do
    Repo.query!(
      "ALTER TABLE llm_response_routes ADD CONSTRAINT response_test_admission_failure CHECK (false) NOT VALID"
    )

    assert {:error, :responses_index_unavailable} =
             ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
  end

  test "database bind failure never acknowledges an ID", ctx do
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)

    Repo.query!(
      "ALTER TABLE llm_response_routes ADD CONSTRAINT response_test_bind_failure CHECK (response_id IS NULL) NOT VALID"
    )

    assert {:error, :responses_index_unavailable} =
             ResponseRoute.bind(route, "resp_failed", "queued")

    assert is_nil(Repo.get!(ResponseRoute, route.id).response_id)
  end

  defp owner_conn(id) do
    Plug.Test.conn(:post, "/v1/responses")
    |> Plug.Conn.assign(:resource_auth, %{
      kind: :client_token,
      client_id: id,
      principal_metadata: %{}
    })
  end
end
