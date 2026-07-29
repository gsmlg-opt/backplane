# ChatGPT-Compatible Resource OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/mcp` and `/v1` separate RFC 8707/RFC 9728 protected resources that ChatGPT and API clients can discover and authorize against, while preserving PAT, legacy-token, open-mode, and identity-only OAuth behavior.

**Architecture:** Add a resource registry and one-to-one Boruta token-resource mapping in `backplane_auth`; make authorization and token issuance bind exactly one resource; validate resource JWTs through a shared Plug; then integrate that Plug with the existing MCP and LLM routers. Keep protocol framing and provider routing in their current apps, and expose discovery plus human setup guides from `backplane_api`.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix/Plug, Ecto/PostgreSQL, Boruta 2.3, JOSE/Joken, ExUnit, Phoenix LiveView, DuskMoon UI.

---

## Implementation map and invariants

| Concern | Primary files |
|---|---|
| Resource identifiers and scope vocabulary | `apps/backplane_auth/lib/backplane/auth/resources.ex` |
| OAuth client resource allowlist | `apps/backplane_auth/lib/backplane/auth/oauth.ex` |
| Token-resource persistence | `apps/backplane_system/priv/repo/migrations/20260722000001_create_oauth_token_resources.exs`, `apps/backplane_auth/lib/backplane/auth/schemas/oauth_token_resource.ex`, `apps/backplane_auth/lib/backplane/auth/token_resources.ex` |
| JWT issuance and validation | `apps/backplane_auth/lib/backplane/auth/access_token_generator.ex`, `apps/backplane_auth/lib/backplane/auth/tokens.ex` |
| Discovery metadata | `apps/backplane_auth/lib/backplane/auth/metadata.ex`, `apps/backplane_api/lib/backplane/api/controllers/auth/discovery_controller.ex` |
| Authorization and token grants | `apps/backplane_api/lib/backplane/api/auth/authorization_request.ex`, `apps/backplane_api/lib/backplane/api/controllers/auth/authorize_controller.ex`, `apps/backplane_api/lib/backplane/api/controllers/auth/token_controller.ex` |
| Raw duplicate parameters | `apps/backplane_api/lib/backplane/api/auth/raw_body_reader.ex`, `apps/backplane_api/lib/backplane/api/auth/resource_params.ex`, `apps/backplane_api/lib/backplane/api/endpoint.ex` |
| Shared resource authentication | `apps/backplane_auth/lib/backplane/auth/bearer_challenge.ex`, `apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex` |
| MCP enforcement | `apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex`, `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex` |
| LLM enforcement | `apps/backplane_llama/lib/backplane/llm/resource_authorization.ex`, `apps/backplane_llama/lib/backplane/llm/router.ex` |
| Admin setup | `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex` |
| Public setup guides | `apps/backplane_api/lib/backplane/api/controllers/page_controller.ex`, `apps/backplane_api/lib/backplane/api/controllers/page_html/docs.html.heex` |

Keep these invariants throughout implementation:

- Internal resource keys are atoms `:mcp | :v1`; persisted client metadata and token mappings use strings `"mcp" | "v1"`.
- Canonical URIs always come from `Backplane.WebOrigins`; request headers never choose issuer, audience, or metadata URLs.
- A valid Backplane signature classifies a bearer exclusively as OAuth. Semantic OAuth failures never fall through to PAT, legacy, or open mode.
- A missing resource mapping is valid only for a genuinely non-resource flow; any resource flow must fail before its code or token is disclosed.
- Boruta callbacks locate rows by the unique tuple `(type, client_id, value)` because callback responses do not carry Ecto IDs.
- `Boruta.Ecto.Admin.update_client/2` must always receive the existing `authorized_scopes` IDs when changing metadata. Omitting them clears the client's scopes.
- Resource-token fixtures must bind a code before access-token generation. Binding an already-signed access token would leave `aud` equal to the client ID.
- No `/.well-known/mcp` route is added.

Before editing a named production symbol, run the repository-required upstream GitNexus impact analysis and report any HIGH or CRITICAL result. Before every commit, run GitNexus change detection and confirm only the expected symbols and flows changed.

## Task 1: Add the resource registry, scope rules, and local-HTTP gate

**Files:**

- Create: `apps/backplane_auth/lib/backplane/auth/resources.ex`
- Create: `apps/backplane_auth/test/backplane/auth/resources_test.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/prod.exs`

- [ ] **Step 1: Write failing resource-registry tests**

Cover exact URI construction, URI-to-key lookup, metadata and documentation URLs, normalized/deduplicated keys, invalid keys, MCP and LLM scope classification, `system::...` rejection, omitted-scope intersection, empty-intersection failure, and HTTPS enforcement.

```elixir
defmodule Backplane.Auth.ResourcesTest do
  use ExUnit.Case, async: false

  alias Backplane.Auth.Resources

  setup do
    old_url = Application.get_env(:backplane, :api_url)
    old_override = Application.get_env(:backplane_auth, :allow_insecure_resource_origins)
    Application.put_env(:backplane, :api_url, "https://backplane.example.test")

    on_exit(fn ->
      restore(:backplane, :api_url, old_url)
      restore(:backplane_auth, :allow_insecure_resource_origins, old_override)
    end)
  end

  test "builds the two canonical resource surfaces" do
    assert Resources.uri(:mcp) == "https://backplane.example.test/mcp"
    assert Resources.uri(:v1) == "https://backplane.example.test/v1"
    assert Resources.metadata_uri(:mcp) ==
             "https://backplane.example.test/.well-known/oauth-protected-resource/mcp"
    assert Resources.documentation_uri(:v1) == "https://backplane.example.test/docs/llm"
    assert Resources.from_uri(Resources.uri(:mcp)) == {:ok, :mcp}
    assert Resources.from_uri("https://backplane.example.test/v1/") == :error
  end

  test "keeps scope meaning resource-relative" do
    assert Resources.valid_scope?(:mcp, "llm::models")
    assert Resources.valid_scope?(:v1, "llm::models")
    refute Resources.valid_scope?(:v1, "github::search")
    refute Resources.valid_scope?(:mcp, "system::*")
    refute Resources.valid_scope?(:v1, "system::admin")
  end

  test "defaults to the resource-operation intersection only" do
    client = ["openid", "github::*", "llm::invoke", "system::*"]
    user = ["openid", "github::*", "llm::invoke", "system::*"]

    assert Resources.default_scopes(:mcp, client, user) == {:ok, ["github::*", "llm::invoke"]}
    assert Resources.default_scopes(:v1, client, user) == {:ok, ["llm::invoke"]}
    assert Resources.default_scopes(:v1, ["openid"], ["openid"]) == {:error, :invalid_scope}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
```

- [ ] **Step 2: Run the test and confirm it fails because the module is absent**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/resources_test.exs`

Expected: compilation fails with `Backplane.Auth.Resources` undefined.

- [ ] **Step 3: Implement the registry and scope policy**

Use this public API and keep URI/path data centralized:

```elixir
defmodule Backplane.Auth.Resources do
  alias Backplane.WebOrigins

  @type key :: :mcp | :v1
  @keys [:mcp, :v1]
  @identity_scopes MapSet.new(["openid", "profile", "email"])
  @v1_scopes MapSet.new(["llm::models", "llm::invoke", "llm::*", "*"])

  def keys, do: @keys
  def path(:mcp), do: "/mcp"
  def path(:v1), do: "/v1"
  def uri(key), do: WebOrigins.api_url(path(key))
  def metadata_uri(key),
    do: WebOrigins.api_url("/.well-known/oauth-protected-resource/#{key}")
  def documentation_uri(:mcp), do: WebOrigins.api_url("/docs/mcp")
  def documentation_uri(:v1), do: WebOrigins.api_url("/docs/llm")

  def from_uri(value) when is_binary(value) do
    Enum.find_value(@keys, :error, fn key -> if value == uri(key), do: {:ok, key} end)
  end

  def normalize_keys(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_key(value) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        :error -> {:halt, {:error, :invalid_resource}}
      end
    end)
    |> then(fn
      {:ok, keys} -> {:ok, keys |> Enum.uniq() |> Enum.sort()}
      error -> error
    end)
  end

  def validate_origin([]), do: :ok
  def validate_origin(resources) when is_list(resources) do
    uri = URI.parse(WebOrigins.api_base_url())

    if uri.scheme == "https" or insecure_local_origin_allowed?() do
      :ok
    else
      {:error, :https_required}
    end
  end

  def valid_scope?(_key, "system::" <> _rest), do: false
  def valid_scope?(_key, scope) when scope in ["openid", "profile", "email"], do: true
  def valid_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def valid_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)

  def operation_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def operation_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)
  def protected_operation_scope?("*"), do: true
  def protected_operation_scope?("system::" <> _rest), do: false
  def protected_operation_scope?(scope), do: Regex.match?(~r/^[^:]+::(?:\*|[^:]+)$/, scope)

  def default_scopes(key, client_scopes, user_scopes) do
    user_set = MapSet.new(user_scopes)

    scopes =
      client_scopes
      |> Enum.filter(&MapSet.member?(user_set, &1))
      |> Enum.filter(&operation_scope?(key, &1))
      |> Enum.reject(&MapSet.member?(@identity_scopes, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if scopes == [], do: {:error, :invalid_scope}, else: {:ok, scopes}
  end

  defp mcp_operation_scope?("*"), do: true
  defp mcp_operation_scope?("system::" <> _rest), do: false
  defp mcp_operation_scope?(scope), do: Regex.match?(~r/^[^:]+::(?:\*|[^:]+)$/, scope)
  defp normalize_key(key) when key in @keys, do: {:ok, key}
  defp normalize_key("mcp"), do: {:ok, :mcp}
  defp normalize_key("v1"), do: {:ok, :v1}
  defp normalize_key(_value), do: :error

  defp insecure_local_origin_allowed? do
    Application.get_env(:backplane_auth, :allow_insecure_resource_origins, false) and
      Application.get_env(:backplane, :env) in [:dev, :test]
  end
end
```

Set `config :backplane, env: :dev` plus `config :backplane_auth, allow_insecure_resource_origins: true` in `config/dev.exs`; set the corresponding `:test` values in `config/test.exs`; set `config :backplane, env: :prod` and the override to `false` in `config/prod.exs`. The runtime check must still require the environment to be `:dev` or `:test`, so setting the override alone cannot enable HTTP in production.

- [ ] **Step 4: Run the focused tests**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/resources_test.exs`

Expected: all resource tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_auth/lib/backplane/auth/resources.ex \
  apps/backplane_auth/test/backplane/auth/resources_test.exs \
  config/dev.exs config/test.exs config/prod.exs
git commit -m "feat(auth): define protected OAuth resources"
```

## Task 2: Add OAuth client resource assignments without losing metadata or scopes

**Files:**

- Modify: `apps/backplane_auth/lib/backplane/auth/oauth.ex`
- Modify: `apps/backplane_auth/test/backplane/auth/oauth_test.exs`

- [ ] **Step 1: Add failing client-assignment tests**

Add tests proving create normalization, enabled-client activation, preservation of `disabled` and unknown metadata, preservation of authorized scopes, Boruta cache invalidation, HTTPS rejection without mutation, and empty-assignment rollback.

```elixir
test "updates resources while preserving metadata, scopes, and Boruta cache coherence" do
  created = oauth_client_fixture!(scopes: ["openid", "github::*"], resources: ["mcp"])
  client = Backplane.Auth.OAuth.get_client(created.id)
  client = %{client | metadata: Map.put(client.metadata, "tenant", "alpha")}
  {:ok, client} = Backplane.Auth.OAuth.update_client_resources(client, [:mcp, :v1])

  assert Backplane.Auth.OAuth.client_resources(client) == [:mcp, :v1]
  assert client.metadata["tenant"] == "alpha"
  assert Enum.map(client.authorized_scopes, & &1.name) |> Enum.sort() == ["github::*", "openid"]

  cached = Boruta.Ecto.Clients.get_client(client.id)
  assert cached.metadata["backplane_resources"] == ["mcp", "v1"]
end
```

- [ ] **Step 2: Confirm the new tests fail**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/oauth_test.exs`

Expected: failures report missing resource functions and ignored `resources` input.

- [ ] **Step 3: Implement the allowlist API and cache-safe metadata updates**

Add these public functions and route `disable_client/1` through the same metadata-update helper:

```elixir
alias Backplane.Auth.Resources

def client_resources(%Client{metadata: metadata}) do
  values =
    case metadata || %{} do
      %{"backplane_resources" => values} when is_list(values) -> values
      %{backplane_resources: values} when is_list(values) -> values
      _metadata -> []
    end

  case Resources.normalize_keys(values) do
    {:ok, resources} -> resources
    {:error, :invalid_resource} -> []
  end
end

def client_allows_resource?(%Client{} = client, resource),
  do: resource in client_resources(client)

def enabled_client_for_resource?(resource) do
  Enum.any?(list_clients(), fn client ->
    client_enabled?(client) and client_allows_resource?(client, resource)
  end)
end

def update_client_resources(%Client{} = client, values) do
  client = Repo.preload(client, :authorized_scopes)

  with {:ok, resources} <- Resources.normalize_keys(values),
       :ok <- Resources.validate_origin(resources) do
    metadata = Map.put(client.metadata || %{}, "backplane_resources", Enum.map(resources, &to_string/1))
    update_client_metadata(client, metadata)
  end
end

defp update_client_metadata(%Client{} = client, metadata) do
  Admin.update_client(client, %{
    metadata: metadata,
    authorized_scopes: Enum.map(client.authorized_scopes, &%{id: &1.id})
  })
end
```

Extend `normalize_client_attrs/1` with `resources`, validate and normalize it before `Admin.create_client/1`, and merge only `"backplane_resources"` into the supplied metadata. Store sorted strings. Change `disable_client/1` to call `update_client_metadata/2`; direct `Repo.update/1` leaves Boruta's client cache stale.

- [ ] **Step 4: Run the domain tests**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/resources_test.exs apps/backplane_auth/test/backplane/auth/oauth_test.exs`

Expected: both files pass; no existing identity-only client test changes behavior.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_auth/lib/backplane/auth/oauth.ex \
  apps/backplane_auth/test/backplane/auth/oauth_test.exs
git commit -m "feat(auth): assign OAuth clients to resources"
```

## Task 3: Persist resource bindings for Boruta codes and access tokens

**Files:**

- Create: `apps/backplane_system/priv/repo/migrations/20260722000001_create_oauth_token_resources.exs`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/oauth_token_resource.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/token_resources.ex`
- Create: `apps/backplane_auth/test/backplane/auth/token_resources_test.exs`
- Modify: `apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs`

- [ ] **Step 1: Write failing migration and lifecycle tests**

The tests must cover one mapping per token, cascade deletion, lookup by code/access/refresh value, lineage lookup from `previous_code` and `previous_token`, and compensating revocation/cache invalidation when binding fails.

```elixir
test "resolves one resource through code and refresh lineage" do
  code = insert_token!(type: "code", value: "code-1", client_id: client.id)
  assert {:ok, _binding} = TokenResources.bind_issued("code", client.id, code.value, :mcp)

  access =
    insert_token!(
      type: "access_token",
      value: "access-1",
      refresh_token: "refresh-1",
      previous_code: code.value,
      client_id: client.id
    )

  assert TokenResources.resource_for_lineage(access) == {:ok, :mcp}
  assert {:ok, _binding} =
           TokenResources.bind_issued("access_token", client.id, access.value, :mcp)
  assert {:ok, refresh_row, :mcp} = TokenResources.lookup_refresh(client.id, "refresh-1")
  assert refresh_row.id == access.id
end
```

- [ ] **Step 2: Confirm the tests fail before the migration and schema exist**

Run: `devenv shell -- mix test apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs apps/backplane_auth/test/backplane/auth/token_resources_test.exs`

Expected: missing table/module failures.

- [ ] **Step 3: Add the additive migration**

```elixir
defmodule Backplane.Repo.Migrations.CreateOauthTokenResources do
  use Ecto.Migration

  def change do
    create table(:oauth_token_resources, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :oauth_token_id,
          references(:oauth_tokens, type: :uuid, on_delete: :delete_all),
          null: false
      add :resource, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_token_resources, [:oauth_token_id])
    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check: "resource IN ('mcp', 'v1')")
  end
end
```

- [ ] **Step 4: Add the schema and context**

The schema changeset must require the FK/resource and apply the inclusion and unique constraints. Use this exact result algebra so callers distinguish an unknown credential from a known identity-only token:

```elixir
@type resource :: :mcp | :v1
@type lookup_result :: :not_found | {:ok, Boruta.Ecto.Token.t(), nil | resource()}
@type binding_result :: :unbound | {:ok, resource()}

@spec bind_issued("code" | "access_token", String.t(), String.t(), resource()) ::
        {:ok, %OAuthTokenResource{}} | {:error, :not_found | :binding_failed}
@spec lookup_code(String.t(), String.t()) :: lookup_result()
@spec lookup_refresh(String.t(), String.t()) :: lookup_result()
@spec lookup_access_token(String.t(), String.t()) :: lookup_result()
@spec resource_for_token(Boruta.Ecto.Token.t()) :: binding_result()
@spec resource_for_lineage(Boruta.Ecto.Token.t()) ::
        binding_result() | {:error, :lineage_not_found}
```

`bind_issued/4` must query `Boruta.Ecto.Token` by `%{type: type, client_id: client_id, value: value}`, insert the mapping, and return the row plus binding. If the mapping insert fails after the token row exists, call `Backplane.Auth.Tokens.revoke_token_by_id/1` before returning `{:error, :binding_failed}`. That existing revocation path converts the row to Boruta's token shape and invalidates `Boruta.Ecto.TokenStore`.

Each lookup returns `:not_found` for an unknown value, `{:ok, token, nil}` for a known identity-only row, or `{:ok, token, resource}` for a mapped row. `resource_for_token/1` converts `nil` to `:unbound`. `resource_for_lineage/1` returns `{:error, :lineage_not_found}` when `previous_code`/`previous_token` names no row. Define nested exception `Backplane.Auth.TokenResources.LineageError` with a non-sensitive fixed message; the signer raises it so the token controller can render a fail-closed OAuth error without logging predecessor values.

- [ ] **Step 5: Migrate and run the focused tests**

Run: `devenv shell -- mix ecto.migrate`

Run: `devenv shell -- mix test apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs apps/backplane_auth/test/backplane/auth/token_resources_test.exs`

Expected: the migration is applied and all persistence/lifecycle tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_system/priv/repo/migrations/20260722000001_create_oauth_token_resources.exs \
  apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs \
  apps/backplane_auth/lib/backplane/auth/schemas/oauth_token_resource.ex \
  apps/backplane_auth/lib/backplane/auth/token_resources.ex \
  apps/backplane_auth/test/backplane/auth/token_resources_test.exs
git commit -m "feat(auth): persist OAuth token resources"
```

## Task 4: Sign resource audiences and validate resource access tokens

**Files:**

- Modify: `apps/backplane_auth/lib/backplane/auth/access_token_generator.ex`
- Modify: `apps/backplane_auth/lib/backplane/auth/tokens.ex`
- Modify: `apps/backplane_auth/test/support/fixtures.ex`
- Modify: `apps/backplane_auth/test/backplane/auth/tokens_test.exs`

- [ ] **Step 1: Write failing JWT and fixture tests**

Cover MCP and `/v1` audiences, separate `client_id`, identity-token client-ID audience, issuer, expiry, future `nbf`, persisted-row revocation, missing/wrong mapping, wrong audience, mismatched `client_id`, disabled/unassigned client, disabled/missing user, persisted/claim scope mismatch, and signature classification.

```elixir
test "resource fixture signs the canonical audience through code lineage" do
  user = auth_user_fixture!()
  client = oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])
  token = resource_access_token_fixture!(user, client, ["github::*"], :mcp)

  assert {:ok, auth} = Tokens.verify_resource_access_token(token.value, :mcp)
  assert auth.claims["aud"] == Resources.uri(:mcp)
  assert auth.claims["client_id"] == client.id
  assert auth.scopes == ["github::*"]
  assert {:error, :invalid_token} = Tokens.verify_resource_access_token(token.value, :v1)
end

test "a non-Backplane signature is the only not-oauth result" do
  assert :not_oauth = Tokens.verify_resource_access_token("opaque-pat", :mcp)

  token = resource_access_token_fixture!(user, client, ["github::*"], :mcp)
  Backplane.Repo.delete_all(Backplane.Auth.Schemas.OAuthTokenResource)
  assert {:error, :invalid_token} = Tokens.verify_resource_access_token(token.value, :mcp)
end
```

- [ ] **Step 2: Run the token tests and observe audience/validation failures**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/tokens_test.exs`

Expected: resource fixture/functions are missing and current `aud` is the OAuth client ID.

- [ ] **Step 3: Resolve audience from Boruta lineage during generation**

Change the signer to use the mapping on `previous_code` or `previous_token`:

```elixir
def sign_access_token!(%Token{client_id: client_id, sub: sub, scope: scope} = token) do
  {:ok, key} = ensure_active_signing_key()
  now = System.system_time(:second)
  ttl = token.access_token_ttl || @access_token_ttl

  audience =
    case TokenResources.resource_for_lineage(token) do
      {:ok, resource} -> Resources.uri(resource)
      :unbound -> client_id
      {:error, :lineage_not_found} -> raise TokenResources.LineageError
    end

  sign_jwt!(key, %{
    "iss" => Boruta.Config.issuer(),
    "sub" => sub,
    "aud" => audience,
    "client_id" => client_id,
    "scope" => scope || "",
    "iat" => now,
    "exp" => now + ttl,
    "jti" => Ecto.UUID.generate()
  })
end
```

`AccessTokenGenerator.generate/2` remains the single JWT entry point. Let lookup failures raise the dedicated lineage exception before Boruta can return a token; do not rescue and silently choose the client ID. Only the explicit `:unbound` result selects the identity behavior.

- [ ] **Step 4: Add strict resource-token verification**

Keep `verify_access_token/1` for existing identity/userinfo callers. Add this separate contract:

```elixir
@spec verify_resource_access_token(String.t(), Resources.key()) ::
        {:ok, map()} | {:error, :invalid_token} | :not_oauth
def verify_resource_access_token(encoded, resource) do
  case verify_jwt(encoded) do
    {:ok, claims} ->
      with :ok <- validate_issuer(claims),
           :ok <- validate_expiration(claims),
           :ok <- validate_not_before(claims),
           {:ok, token} <- active_access_token(encoded),
           {:ok, ^resource} <- TokenResources.resource_for_token(token),
           true <- claims["aud"] == Resources.uri(resource),
           true <- claims["client_id"] == token.client_id,
           true <- claims["sub"] == token.sub,
           true <- claims["scope"] == token.scope,
           %User{active: true} = user <- Accounts.get_user(token.sub),
           %Client{} = client <- OAuth.get_client(token.client_id),
           true <- OAuth.client_enabled?(client),
           true <- OAuth.client_allows_resource?(client, resource) do
        {:ok,
         %{
           claims: claims,
           token: token,
           user: user,
           client: client,
           scopes: String.split(claims["scope"], " ", trim: true)
         }}
      else
        _failure -> {:error, :invalid_token}
      end

    {:error, :invalid_token} ->
      :not_oauth
  end
end

defp validate_issuer(%{"iss" => issuer}) do
  if issuer == Boruta.Config.issuer(), do: :ok, else: {:error, :invalid_token}
end
defp validate_issuer(_claims), do: {:error, :invalid_token}
defp validate_not_before(%{"nbf" => nbf}) when is_integer(nbf),
  do: if(nbf <= System.system_time(:second), do: :ok, else: {:error, :invalid_token})
defp validate_not_before(%{"nbf" => _invalid}), do: {:error, :invalid_token}
defp validate_not_before(_claims), do: :ok
```

The `:not_oauth` branch means only that none of Backplane's active or retained keys validates the signature. Every failure after a valid signature returns `{:error, :invalid_token}`.

Tighten `active_access_token/1` to query `type: "access_token", value: encoded`; a code row can never satisfy resource-server validation.

- [ ] **Step 5: Add a lineage-correct resource fixture**

`resource_access_token_fixture!/4` must insert or create a Boruta code row, bind that code, issue through `Boruta.Ecto.AccessTokens.create/2` with `previous_code`, then bind the resulting access-token row. It must not call `access_token_fixture!/3` and attach a mapping afterward.

```elixir
def resource_access_token_fixture!(user, client, scopes, resource) do
  code_value = "fixture-code-#{System.unique_integer([:positive])}"

  code =
    Backplane.Repo.insert!(%Boruta.Ecto.Token{
      type: "code",
      value: code_value,
      client_id: client.id,
      sub: user.id,
      scope: Enum.join(scopes, " "),
      expires_at: System.system_time(:second) + 60
    })

  {:ok, _binding} =
    Auth.TokenResources.bind_issued("code", client.id, code.value, resource)

  oauth_client =
    client.id
    |> Auth.OAuth.get_client()
    |> Boruta.Ecto.OauthMapper.to_oauth_schema()

  {:ok, oauth_token} =
    Boruta.Ecto.AccessTokens.create(
      %{
        client: oauth_client,
        sub: user.id,
        scope: Enum.join(scopes, " "),
        previous_code: code.value
      },
      refresh_token: true
    )

  {:ok, _binding} =
    Auth.TokenResources.bind_issued("access_token", client.id, oauth_token.value, resource)

  Backplane.Repo.get_by!(Boruta.Ecto.Token, value: oauth_token.value)
end
```

- [ ] **Step 6: Run focused token tests**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/token_resources_test.exs apps/backplane_auth/test/backplane/auth/tokens_test.exs`

Expected: all JWT, revocation, principal, mapping, and identity regression tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane_auth/lib/backplane/auth/access_token_generator.ex \
  apps/backplane_auth/lib/backplane/auth/tokens.ex \
  apps/backplane_auth/test/support/fixtures.ex \
  apps/backplane_auth/test/backplane/auth/tokens_test.exs
git commit -m "feat(auth): issue resource-bound access tokens"
```

## Task 5: Publish RFC 8414, OIDC, and RFC 9728 metadata

**Files:**

- Create: `apps/backplane_auth/lib/backplane/auth/metadata.ex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/discovery_controller.ex`
- Modify: `apps/backplane_api/lib/backplane/api/router.ex`
- Modify: `apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs`

- [ ] **Step 1: Expand discovery tests first**

Assert all four public metadata routes, exact canonical resources, matching AS/OIDC endpoint values, both `protected_resources`, S256 only, no `scopes_supported` in either AS document, no DCR/CIMD fields, MCP PRM without scopes, and `/v1` PRM with only the two least-privilege scopes.

```elixir
test "publishes path-aware protected-resource metadata", %{conn: conn} do
  mcp = get(conn, "/.well-known/oauth-protected-resource/mcp") |> json_response(200)
  v1 = get(recycle(conn), "/.well-known/oauth-protected-resource/v1") |> json_response(200)

  assert mcp["resource"] == Backplane.Auth.Resources.uri(:mcp)
  assert mcp["authorization_servers"] == [Backplane.WebOrigins.api_base_url()]
  refute Map.has_key?(mcp, "scopes_supported")

  assert v1["resource"] == Backplane.Auth.Resources.uri(:v1)
  assert v1["scopes_supported"] == ["llm::models", "llm::invoke"]
  assert v1["resource_documentation"] == Backplane.WebOrigins.api_url("/docs/llm")
end
```

- [ ] **Step 2: Run and observe route failures**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs`

Expected: the three new routes return 404 and OIDC lacks `protected_resources`.

- [ ] **Step 3: Implement one metadata builder**

```elixir
defmodule Backplane.Auth.Metadata do
  alias Backplane.Auth.Resources
  alias Backplane.WebOrigins

  def authorization_server do
    %{
      issuer: WebOrigins.api_base_url(),
      authorization_endpoint: WebOrigins.api_url("/oauth/authorize"),
      token_endpoint: WebOrigins.api_url("/oauth/token"),
      jwks_uri: WebOrigins.api_url("/oauth/jwks"),
      introspection_endpoint: WebOrigins.api_url("/oauth/introspect"),
      revocation_endpoint: WebOrigins.api_url("/oauth/revoke"),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post", "none"],
      protected_resources: Enum.map(Resources.keys(), &Resources.uri/1)
    }
  end

  def openid_configuration do
    Map.merge(authorization_server(), %{
      userinfo_endpoint: WebOrigins.api_url("/oauth/userinfo"),
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"]
    })
  end

  def protected_resource(:mcp) do
    protected_resource_base(:mcp, "Backplane MCP Hub")
  end

  def protected_resource(:v1) do
    protected_resource_base(:v1, "Backplane LLM API")
    |> Map.put(:scopes_supported, ["llm::models", "llm::invoke"])
  end

  defp protected_resource_base(resource, name) do
    %{
      resource: Resources.uri(resource),
      authorization_servers: [WebOrigins.api_base_url()],
      bearer_methods_supported: ["header"],
      resource_name: name,
      resource_documentation: Resources.documentation_uri(resource)
    }
  end
end
```

- [ ] **Step 4: Route the public discovery actions**

Add controller actions `openid_configuration/2`, `authorization_server/2`, and `protected_resource/2`, then route:

```elixir
get("/.well-known/openid-configuration", Auth.DiscoveryController, :openid_configuration)
get("/.well-known/oauth-authorization-server", Auth.DiscoveryController, :authorization_server)
get("/.well-known/oauth-protected-resource/:resource", Auth.DiscoveryController, :protected_resource)
```

Return 404 for any protected-resource path other than `mcp` and `v1`. Do not add a root PRM and do not add `/.well-known/mcp`.

- [ ] **Step 5: Run discovery tests**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs apps/backplane_api/test/backplane/api/route_boundary_test.exs`

Expected: discovery tests pass and unrelated route boundaries remain unchanged.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_auth/lib/backplane/auth/metadata.ex \
  apps/backplane_api/lib/backplane/api/controllers/auth/discovery_controller.ex \
  apps/backplane_api/lib/backplane/api/router.ex \
  apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs
git commit -m "feat(auth): publish OAuth resource metadata"
```

## Task 6: Preserve duplicate resource parameters and validate authorization requests

**Files:**

- Create: `apps/backplane_api/lib/backplane/api/auth/raw_body_reader.ex`
- Create: `apps/backplane_api/lib/backplane/api/auth/resource_params.ex`
- Create: `apps/backplane_api/lib/backplane/api/auth/authorization_request.ex`
- Modify: `apps/backplane_api/lib/backplane/api/endpoint.ex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/authorize_controller.ex`
- Modify: `apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

- [ ] **Step 1: Add failing raw-query and authorization-policy tests**

Test repeated identical and different query values, unsupported/disallowed/missing resources, pre-trust direct errors, post-trust redirect errors, resource-operation scope without resource, explicit strict scopes, `system::...` rejection, resource-relative `llm::...`, omitted-scope intersection, empty defaults, and empty-allowlist identity compatibility.

```elixir
test "rejects duplicate resource query pairs before map collapse", %{conn: conn} do
  query = URI.encode_query(base_authorize_params())
  resource = URI.encode_www_form(Resources.uri(:mcp))
  conn = get(conn, "/oauth/authorize?#{query}&resource=#{resource}&resource=#{resource}")

  assert response(conn, 400) =~ "invalid_target"
end


test "defaults resource scopes to the client and user RBAC intersection", %{conn: conn} do
  user = logged_in_user(conn, scopes: ["github::*", "docs::read"])
  client = oauth_client(resources: [:mcp], scopes: ["github::*", "skill::*"])

  conn = get(user.conn, "/oauth/authorize", authorize_params(client, resource: Resources.uri(:mcp)))
  code = authorization_code_from_redirect(conn)
  assert Backplane.Repo.get_by!(Boruta.Ecto.Token, value: code).scope == "github::*"
end

test "keeps system scopes on the existing no-resource path", %{conn: conn} do
  user = logged_in_user(conn, scopes: ["system::admin"])
  client = oauth_client(resources: [:mcp], scopes: ["system::admin"])

  conn =
    get(user.conn, "/oauth/authorize", authorize_params(client, scope: "system::admin"))

  assert authorization_code_from_redirect(conn)
end
```

- [ ] **Step 2: Confirm the focused tests fail**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

Expected: duplicate query values collapse, missing resource rules are not enforced, and omitted resource scopes stay blank.

- [ ] **Step 3: Add a duplicate-preserving form body reader**

```elixir
defmodule Backplane.Api.Auth.RawBodyReader do
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw = (conn.private[:oauth_raw_form_body] || "") <> body
        {:ok, body, maybe_store_pairs(conn, raw)}

      {:more, body, conn} ->
        raw = (conn.private[:oauth_raw_form_body] || "") <> body
        {:more, body, Plug.Conn.put_private(conn, :oauth_raw_form_body, raw)}

      other -> other
    end
  end

  defp maybe_store_pairs(%Plug.Conn{request_path: "/oauth/token"} = conn, body) do
    if form_urlencoded?(conn) do
      Plug.Conn.put_private(conn, :oauth_form_pairs, Enum.to_list(URI.query_decoder(body)))
    else
      conn
    end
  rescue
    ArgumentError -> Plug.Conn.put_private(conn, :oauth_form_pairs, :malformed)
  end

  defp maybe_store_pairs(conn, _body), do: conn

  defp form_urlencoded?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "application/x-www-form-urlencoded"))
  end
end
```

Configure `Plug.Parsers` in `Backplane.Api.Endpoint` with:

```elixir
plug(Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library(),
  body_reader: {Backplane.Api.Auth.RawBodyReader, :read_body, []}
)
```

Do not log or persist the raw body; it may contain codes, refresh tokens, and client secrets.

Add one parser used by both controllers so duplicate and canonical-URI behavior cannot drift:

```elixir
defmodule Backplane.Api.Auth.ResourceParams do
  alias Backplane.Auth.Resources

  @spec query(Plug.Conn.t(), map()) :: {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def query(conn, params) do
    values =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.filter(fn {key, _value} -> key == "resource" end)
      |> Enum.map(&elem(&1, 1))

    normalize(values, params["resource"])
  rescue
    ArgumentError -> {:error, :invalid_target}
  end

  @spec form(Plug.Conn.t(), map()) :: {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def form(%Plug.Conn{private: %{oauth_form_pairs: :malformed}}, _params),
    do: {:error, :invalid_target}

  def form(conn, params) do
    values =
      conn.private
      |> Map.get(:oauth_form_pairs, [])
      |> Enum.filter(fn {key, _value} -> key == "resource" end)
      |> Enum.map(&elem(&1, 1))

    normalize(values, params["resource"])
  end

  defp normalize([], nil), do: {:ok, nil}
  defp normalize([], parsed), do: normalize([parsed], nil)
  defp normalize([value], _parsed), do: Resources.from_uri(value) |> normalize_uri()
  defp normalize(_repeated, _parsed), do: {:error, :invalid_target}

  defp normalize_uri({:ok, resource}), do: {:ok, resource}
  defp normalize_uri(:error), do: {:error, :invalid_target}
end
```

Add direct tests through the authorize and token endpoints for zero, one, repeated-identical, repeated-different, malformed, unsupported, and exact canonical values.

Put client/user/scope policy in a pure helper with this complete contract:

```elixir
defmodule Backplane.Api.Auth.AuthorizationRequest do
  alias Backplane.Auth.{OAuth, RBAC, Resources}
  alias Backplane.Auth.Schemas.User
  alias Boruta.Ecto.Client

  @spec preflight(Client.t(), map(), nil | Resources.key()) ::
          {:ok, map()} | {:error, atom()}
  def preflight(client, params, resource) do
    requested = scopes(params)
    client_scopes = Enum.map(client.authorized_scopes, & &1.name)

    with :ok <- validate_response_type(params),
         :ok <- validate_pkce(params),
         :ok <- validate_resource_assignment(client, resource),
         :ok <- validate_client_scopes(requested, client_scopes),
         :ok <- validate_resource_vocabulary(requested, resource),
         :ok <- require_resource_for_operations(client, requested, resource) do
      {:ok, params}
    end
  end

  @spec for_user(Client.t(), User.t(), map(), nil | Resources.key()) ::
          {:ok, map()} | {:error, :invalid_scope}
  def for_user(client, user, params, resource) do
    requested = scopes(params)
    client_scopes = Enum.map(client.authorized_scopes, & &1.name)
    user_scopes = RBAC.effective_scope_names(user)

    effective =
      cond do
        resource && requested == [] -> Resources.default_scopes(resource, client_scopes, user_scopes)
        Enum.all?(requested, &(&1 in user_scopes)) -> {:ok, requested}
        true -> {:error, :invalid_scope}
      end

    case effective do
      {:ok, scopes} -> {:ok, Map.put(params, "scope", Enum.join(scopes, " "))}
      {:error, :invalid_scope} -> {:error, :invalid_scope}
    end
  end

  defp scopes(params), do: String.split(params["scope"] || "", " ", trim: true)
  defp validate_response_type(%{"response_type" => "code"}), do: :ok
  defp validate_response_type(_params), do: {:error, :unsupported_response_type}
  defp validate_pkce(%{"code_challenge" => value, "code_challenge_method" => "S256"})
       when is_binary(value) and value != "", do: :ok
  defp validate_pkce(%{"code_challenge_method" => "plain"}),
    do: {:error, :unsupported_code_challenge_method}
  defp validate_pkce(_params), do: {:error, :invalid_request}

  defp validate_resource_assignment(_client, nil), do: :ok
  defp validate_resource_assignment(client, resource) do
    if OAuth.client_allows_resource?(client, resource), do: :ok, else: {:error, :invalid_target}
  end

  defp validate_client_scopes(requested, allowed) do
    if Enum.all?(requested, &(&1 in allowed)), do: :ok, else: {:error, :invalid_scope}
  end

  defp validate_resource_vocabulary(_requested, nil), do: :ok
  defp validate_resource_vocabulary(requested, resource) do
    if Enum.all?(requested, &Resources.valid_scope?(resource, &1)),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp require_resource_for_operations(client, requested, nil) do
    if OAuth.client_resources(client) != [] and
         Enum.any?(requested, &Resources.protected_operation_scope?/1),
      do: {:error, :invalid_target},
      else: :ok
  end
  defp require_resource_for_operations(_client, _requested, _resource), do: :ok
end
```

This pure helper is unit-testable through `authorize_controller_test.exs`; it deliberately permits no-resource `system::...` and other existing custom scopes, while selected resources apply the strict vocabulary.

- [ ] **Step 4: Refactor authorization into trusted and resource-aware stages**

Use this control flow:

```elixir
def authorize(conn, params) do
  with {:ok, client} <- enabled_client(params),
       :ok <- Auth.OAuth.validate_redirect_uri(client, params["redirect_uri"]) do
    case prepare_before_login(conn, client, params) do
      {:ok, normalized_params} -> continue_authorize(conn, client, normalized_params)
      {:error, error} -> redirect_authorize_error(conn, params, error)
    end
  else
    _untrusted -> send_resp(conn, 400, "invalid_request")
  end
end

def authorize_for_user(conn, params, %User{} = user, %Client{} = client) do
  with {:ok, resource} <- Backplane.Api.Auth.ResourceParams.query(conn, params),
       {:ok, params} <-
         Backplane.Api.Auth.AuthorizationRequest.preflight(client, params, resource),
       {:ok, normalized_params} <-
         Backplane.Api.Auth.AuthorizationRequest.for_user(client, user, params, resource) do
    conn
    |> put_private(:backplane_oauth_resource, resource)
    |> put_private(:backplane_oauth_client_id, client.id)
    |> Map.put(:query_params, normalized_params)
    |> Boruta.Oauth.authorize(Auth.ResourceOwners.from_user(user), __MODULE__)
  else
    {:error, error} -> redirect_authorize_error(conn, params, error)
  end
end

defp prepare_before_login(conn, client, params) do
  with {:ok, resource} <- Backplane.Api.Auth.ResourceParams.query(conn, params),
       {:ok, normalized_params} <-
         Backplane.Api.Auth.AuthorizationRequest.preflight(client, params, resource) do
    {:ok, normalized_params}
  end
end
```

`prepare_before_login/3` receives the `nil | :mcp | :v1` result from `ResourceParams.query/2` and delegates to `AuthorizationRequest.preflight/3`. Preserve the normalized params in the existing login session. A no-resource `system::...` scope retains existing non-resource behavior; it is rejected only when a protected resource is selected.

`normalize_scopes_for_user/3` delegates to `AuthorizationRequest.for_user/4`, which must:

- keep a supplied scope set exact and require every scope from both client and current user RBAC grants;
- when resource is present and scope is blank, call `Resources.default_scopes/3` and write the sorted result back as a space-separated string;
- reject any selected-resource scope beginning `system::`;
- allow identity-only no-resource flows and existing empty-resource clients unchanged.

Only client and exact redirect validation establish a trusted redirect. Errors before that point are direct 400 responses; later errors append `error` and the original `state` to the registered redirect URI without including a code.

Implement the trusted redirect helper without copying any untrusted error description:

```elixir
defp redirect_authorize_error(conn, params, error) do
  uri = URI.parse(params["redirect_uri"])
  query = URI.decode_query(uri.query || "")
  query = query |> Map.put("error", to_string(error)) |> maybe_put_state(params["state"])
  redirect(conn, external: URI.to_string(%{uri | query: URI.encode_query(query)}))
end

defp maybe_put_state(query, nil), do: query
defp maybe_put_state(query, state), do: Map.put(query, "state", state)
```

- [ ] **Step 5: Bind the code before redirecting it**

```elixir
def authorize_success(conn, %AuthorizeResponse{} = response) do
  case conn.private[:backplane_oauth_resource] do
    nil ->
      redirect(conn, external: AuthorizeResponse.redirect_to_url(response))

    resource ->
      client_id = conn.private[:backplane_oauth_client_id]

      case Auth.TokenResources.bind_issued("code", client_id, response.code, resource) do
        {:ok, _binding} ->
          redirect(conn, external: AuthorizeResponse.redirect_to_url(response))

        {:error, _reason} ->
          redirect_response_error(conn, response, "server_error")
      end
  end
end
```

The failure path must contain no code and relies on `bind_issued/4` to revoke and invalidate the undisclosed row.

- [ ] **Step 6: Run authorization tests**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs apps/backplane_api/test/backplane/api/auth/login_controller_test.exs apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

Expected: resource and identity authorization cases pass, including login resume and raw duplicate rejection.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane_api/lib/backplane/api/auth/raw_body_reader.ex \
  apps/backplane_api/lib/backplane/api/auth/resource_params.ex \
  apps/backplane_api/lib/backplane/api/auth/authorization_request.ex \
  apps/backplane_api/lib/backplane/api/endpoint.ex \
  apps/backplane_api/lib/backplane/api/controllers/auth/authorize_controller.ex \
  apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs
git commit -m "feat(auth): validate OAuth resource requests"
```

## Task 7: Enforce code/refresh resource continuity and expose mapped audiences

**Files:**

- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/token_controller.ex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/introspect_controller.ex`
- Modify: `apps/backplane_api/test/backplane/api/auth/token_controller_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

- [ ] **Step 1: Add failing token lifecycle tests**

Cover one exact resource on code exchange, duplicate form pairs, code mismatch, refresh omission inheritance, same-resource refresh, cross-resource refresh, unknown code/refresh remaining `invalid_grant`, mapping failure cleanup, resource JWT response, mapped introspection `aud`, and unmapped introspection without `aud`.

```elixir
test "refresh inherits its original resource when omitted", %{conn: conn} do
  original = complete_resource_code_flow(conn, :mcp, ["github::*"])

  refreshed =
    post_form(conn, "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => original["refresh_token"],
      "client_id" => client.id,
      "client_secret" => client.plaintext_secret
    })
    |> json_response(200)

  assert {:ok, claims} = decode_verified_jwt(refreshed["access_token"])
  assert claims["aud"] == Resources.uri(:mcp)
end

test "rejects repeated resource form pairs before parser collapse", %{conn: conn} do
  body =
    URI.encode_query(base_token_params()) <>
      "&resource=#{URI.encode_www_form(Resources.uri(:mcp))}" <>
      "&resource=#{URI.encode_www_form(Resources.uri(:mcp))}"

  conn = post_raw_form(conn, "/oauth/token", body)
  assert json_response(conn, 400)["error"] == "invalid_target"
end
```

- [ ] **Step 2: Confirm continuity tests fail**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/token_controller_test.exs apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

Expected: resource mismatches are ignored and newly issued access rows are not mapped.

- [ ] **Step 3: Preflight authorization-code and refresh grants**

Before calling Boruta, count `resource` in `conn.private[:oauth_form_pairs]` and apply:

```elixir
defp resolve_grant_resource(conn, %{"grant_type" => "authorization_code"} = params, client_id) do
  with {:ok, supplied} <- Backplane.Api.Auth.ResourceParams.form(conn, params),
       {:ok, _token, bound} <- Auth.TokenResources.lookup_code(client_id, params["code"]) do
    case {bound, supplied} do
      {nil, nil} -> {:ok, conn, nil}
      {bound, supplied} when bound in [:mcp, :v1] and bound == supplied ->
        {:ok, put_resource_private(conn, client_id, bound), bound}

      _mismatch -> {:error, :invalid_target}
    end
  else
    :not_found -> {:ok, conn, nil}
    error -> error
  end
end

defp resolve_grant_resource(conn, %{"grant_type" => "refresh_token"} = params, client_id) do
  with {:ok, supplied} <- Backplane.Api.Auth.ResourceParams.form(conn, params),
       {:ok, _token, bound} <- Auth.TokenResources.lookup_refresh(client_id, params["refresh_token"]) do
    case {bound, supplied} do
      {nil, nil} -> {:ok, conn, nil}
      {nil, _supplied} -> {:error, :invalid_target}
      {resource, nil} -> {:ok, put_resource_private(conn, client_id, resource), resource}
      {bound, supplied} when bound in [:mcp, :v1] and bound == supplied ->
        {:ok, put_resource_private(conn, client_id, bound), bound}

      {_bound, _supplied} -> {:error, :invalid_target}
    end
  else
    :not_found -> {:ok, conn, nil}
    error -> error
  end
end

defp put_resource_private(conn, client_id, resource) do
  conn
  |> Plug.Conn.put_private(:backplane_oauth_client_id, client_id)
  |> Plug.Conn.put_private(:backplane_oauth_resource, resource)
end
```

For a known mapped code, require exactly one matching canonical URI after `ResourceParams.form/2` returns. For a known unmapped identity code, a supplied resource is `invalid_target`; omission is valid. For mapped refresh, omission inherits and one supplied value must match. More than one pair always fails even when values are identical. Unknown credentials must still be passed to Boruta so the client receives `invalid_grant`, not a false identity classification.

Wrap only the Boruta issuance call so the generator's dedicated lineage failure cannot become an HTML/uncaught 500:

```elixir
defp issue_token(conn) do
  try do
    Boruta.Oauth.token(conn, __MODULE__)
  rescue
    _error in Backplane.Auth.TokenResources.LineageError ->
      Helpers.json_error(conn, 400, "server_error")
  end
end
```

Call `issue_token/1` after client/resource preflight. The exception occurs before Boruta inserts a new access row; callback-time binding failures use the compensating revocation path in Step 4. Add a unit test that unknown predecessor lineage raises `LineageError` without embedding code/refresh values in the message, and a controller regression that the narrow boundary returns JSON `400 server_error` when the configured test token generator raises that exception.

- [ ] **Step 4: Bind the access row before returning token JSON**

```elixir
def token_success(conn, %TokenResponse{} = response) do
  case conn.private[:backplane_oauth_resource] do
    nil -> send_token_response(conn, response)
    resource ->
      client_id = conn.private[:backplane_oauth_client_id]

      case Auth.TokenResources.bind_issued(
             "access_token",
             client_id,
             response.access_token,
             resource
           ) do
        {:ok, _binding} -> send_token_response(conn, response)
        {:error, _reason} -> Helpers.json_error(conn, 400, "server_error")
      end
  end
end
```

Before sending success, verify the JWT `aud` equals `Resources.uri(resource)`. If it does not, revoke/invalidate the row and return `server_error`; this closes a race where a predecessor mapping disappears between preflight and generation.

- [ ] **Step 5: Add conditional introspection audience**

Build the current active response, then call the helper with `response.client_id` and `conn.params["token"]`:

```elixir
defp maybe_put_resource_audience(body, client_id, token) do
  case Backplane.Auth.TokenResources.lookup_access_token(client_id, token) do
    {:ok, _token, resource} when resource in [:mcp, :v1] ->
      Map.put(body, :aud, Backplane.Auth.Resources.uri(resource))

    _unmapped -> body
  end
end
```

Do not add `aud` to inactive or identity-only responses.

- [ ] **Step 6: Run token and identity regressions**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/auth/token_controller_test.exs apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`

Expected: code/refresh continuity and introspection tests pass; existing authorize, userinfo, revoke, and refresh-reuse tests remain green.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane_api/lib/backplane/api/controllers/auth/token_controller.ex \
  apps/backplane_api/lib/backplane/api/controllers/auth/introspect_controller.ex \
  apps/backplane_api/test/backplane/api/auth/token_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs
git commit -m "feat(auth): preserve OAuth resources across grants"
```

## Task 8: Add the shared resource authentication layer and correct PAT activation

**Files:**

- Modify: `apps/backplane_auth/mix.exs`
- Modify: `apps/backplane_mcp/mix.exs`
- Modify: `apps/backplane_llama/mix.exs`
- Create: `apps/backplane_auth/lib/backplane/auth/bearer_challenge.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex`
- Create: `apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs`
- Modify: `apps/backplane_system/lib/backplane/clients.ex`
- Modify: `apps/backplane_system/test/backplane/clients_test.exs`

- [ ] **Step 1: Wire the dependency direction**

Add `{:plug, "~> 1.16"}` directly to `backplane_auth`. Add `{:backplane_auth, in_umbrella: true}` to `backplane_mcp` and `backplane_llama`. Do not add any dependency from `backplane_system` back to auth.

- [ ] **Step 2: Write failing authentication matrix tests**

Cover OAuth, PAT, legacy, and open assignments; valid-signature exclusivity; invalid opaque credential behavior; missing credential activation; inactive-only PAT activation; exact versus query-bearing canonical challenges; PAT-only responses without OAuth metadata; and token-list precedence over the single legacy token.

```elixir
test "does not fall through after a Backplane-signed wrong-audience token" do
  token = resource_access_token_fixture!(user, client, ["github::*"], :v1)

  conn =
    conn(:post, "/mcp")
    |> put_req_header("authorization", "Bearer #{token.value}")
    |> ResourceAuthPlug.call(ResourceAuthPlug.init(resource: :mcp))

  assert conn.status == 401
  assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
  assert get_resp_header(conn, "www-authenticate") |> hd() =~ ~s(error="invalid_token")
end

test "rejects a supplied invalid bearer even when the resource is otherwise open" do
  conn =
    conn(:get, "/v1")
    |> put_req_header("authorization", "Bearer unknown")
    |> ResourceAuthPlug.call(ResourceAuthPlug.init(resource: :v1))

  assert conn.status == 401
  refute conn.assigns[:resource_auth]
end
```

- [ ] **Step 3: Confirm the tests fail and capture the PAT flag regression**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs apps/backplane_system/test/backplane/clients_test.exs`

Expected: the Plug is absent; an inactive-only PAT row does not protect the surface outside test-mode DB checks.

- [ ] **Step 4: Make PAT activation count all rows while verification remains active-only**

In `Backplane.Clients.refresh_cache/0`, keep the ETS rows filtered to `active: true`, but compute the persistent activation flag separately:

```elixir
active_clients = Client |> where(active: true) |> Repo.all()
any_client_rows? = Repo.exists?(Client)

# Populate ETS from active_clients as today.
:persistent_term.put(:backplane_clients_exist, any_client_rows?)
```

An inactive PAT must still make missing/invalid credentials reject, while `verify_token/1` must never authenticate it.

- [ ] **Step 5: Implement one challenge serializer**

`Backplane.Auth.BearerChallenge.put/3` owns header formatting for both surfaces:

```elixir
def put(conn, resource, opts \\ []) do
  params =
    []
    |> maybe_add("error", opts[:error])
    |> maybe_add("scope", opts[:scope])
    |> maybe_add_resource_metadata(conn, resource)

  value =
    case params do
      [] -> "Bearer"
      values -> "Bearer " <> Enum.map_join(values, ", ", fn {key, value} ->
        ~s(#{key}="#{escape(value)}")
      end)
    end

  Plug.Conn.put_resp_header(conn, "www-authenticate", value)
end

defp maybe_add(params, _key, nil), do: params
defp maybe_add(params, key, value), do: params ++ [{key, value}]

defp maybe_add_resource_metadata(params, conn, resource) do
  if Backplane.Auth.OAuth.enabled_client_for_resource?(resource) and
       conn.request_path == Backplane.Auth.Resources.path(resource) and
       conn.query_string == "" do
    params ++ [{"resource_metadata", Backplane.Auth.Resources.metadata_uri(resource)}]
  else
    params
  end
end

defp escape(value) do
  value
  |> String.replace("\\", "\\\\")
  |> String.replace("\"", "\\\"")
end
```

Escape `"` and `\\` in values even though current values are server-controlled. The canonical check must use `request_path` plus an empty `query_string`; never reconstruct the URL from Host or forwarded headers.

- [ ] **Step 6: Implement `ResourceAuthPlug` resolution order**

Expose normalized success under `conn.assigns[:resource_auth]`:

```elixir
@type resource_auth :: %{
  kind: :oauth | :client_token | :legacy | :open,
  subject: String.t() | nil,
  client_id: String.t() | nil,
  resource: :mcp | :v1,
  scopes: [String.t()]
}
```

The central branch must follow this order:

```elixir
defp authenticate(conn, resource, token) do
  case Backplane.Auth.Tokens.verify_resource_access_token(token, resource) do
    {:ok, oauth} -> oauth_success(conn, resource, oauth)
    {:error, :invalid_token} -> oauth_reject(conn, resource, "invalid_token")
    :not_oauth -> authenticate_opaque(conn, resource, token)
  end
end

defp authenticate_opaque(conn, resource, token) do
  case Backplane.Clients.verify_token(token) do
    {:ok, client} -> client_token_success(conn, resource, client)
    :error ->
      if valid_legacy_token?(token) do
        legacy_success(conn, resource)
      else
        opaque_reject(conn, resource)
      end
  end
end
```

Treat an absent Authorization header as open only when all three are false: `Clients.any_clients?/0`, a configured legacy token, and `OAuth.enabled_client_for_resource?/1`. A malformed/non-Bearer header is a supplied invalid credential, not missing.

Normalize init options once and evaluate the optional scope callback without a compile-time dependency on the LLM app:

```elixir
def init(opts) do
  resource = Keyword.fetch!(opts, :resource)
  true = resource in [:mcp, :v1]
  %{resource: resource, required_scope: Keyword.get(opts, :required_scope)}
end

defp required_scope(conn, %{required_scope: {module, function, args}}),
  do: apply(module, function, [conn | args])
defp required_scope(_conn, _opts), do: nil
```

For MCP, set `tool_scopes` from OAuth/PAT scopes or `["*"]` for legacy/open. Preserve `conn.assigns[:client]` only for PAT clients; MCP audit code expects that assign to be a `Backplane.Clients.Client`, not an OAuth client. When OAuth is enabled, missing/invalid OAuth responses use JSON OAuth error names and `BearerChallenge`; when only PAT/legacy protects the surface, preserve the existing `{"error":"Unauthorized"}` body and omit `resource_metadata`.

Allow an optional `required_scope: {module, function, args}` init option. It is used only to add the least operation scope to a missing/invalid nested `/v1` challenge; it does not authorize the operation.

- [ ] **Step 7: Run the shared authentication tests**

Run: `devenv shell -- mix test apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs apps/backplane_system/test/backplane/clients_test.exs`

Expected: the full credential matrix and inactive-PAT activation tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/backplane_auth/mix.exs apps/backplane_mcp/mix.exs apps/backplane_llama/mix.exs \
  apps/backplane_auth/lib/backplane/auth/bearer_challenge.ex \
  apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex \
  apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs \
  apps/backplane_system/lib/backplane/clients.ex \
  apps/backplane_system/test/backplane/clients_test.exs
git commit -m "feat(auth): authenticate protected resources"
```

## Task 9: Integrate resource OAuth with MCP filtering and denial semantics

**Files:**

- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex`
- Modify: `apps/backplane_mcp/test/backplane/transport/router_test.exs`
- Modify: `apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs`

- [ ] **Step 1: Add failing MCP transport tests**

Use lineage-correct resource fixtures. Cover OAuth activation/challenge, PAT-only challenge compatibility, canonical and query-bearing `/mcp`, valid MCP audience, `/v1` audience rejection, exact and wildcard list filtering, OAuth single-call 403, PAT single-call 200, and batch HTTP 200 without a batch-wide challenge.

```elixir
test "single OAuth tool denial keeps JSON-RPC body and adds a 403 challenge" do
  token = resource_access_token_fixture!(user, client, ["github::read"], :mcp)

  conn = mcp_conn("tools/call", %{"name" => "github::write", "arguments" => %{}})
  conn = put_req_header(conn, "authorization", "Bearer #{token.value}")
  conn = Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))

  assert conn.status == 403
  assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_001
  [challenge] = get_resp_header(conn, "www-authenticate")
  assert challenge =~ ~s(error="insufficient_scope")
  assert challenge =~ ~s(scope="github::write")
  assert challenge =~ Backplane.Auth.Resources.metadata_uri(:mcp)
end
```

- [ ] **Step 2: Confirm current MCP behavior fails the OAuth assertions**

Run: `devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/router_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs`

Expected: OAuth tokens are not accepted and single denials remain HTTP 200 without a bearer challenge.

- [ ] **Step 3: Replace only the authentication plug**

Keep existing pre-auth ordering for version headers, CORS, HEAD, compression, logging, and rate limiting. Replace:

```elixir
plug Backplane.Transport.AuthPlug
```

with:

```elixir
plug Backplane.Auth.ResourceAuthPlug, resource: :mcp
```

This preserves unauthenticated MCP `HEAD` and CORS `OPTIONS` short circuits.

- [ ] **Step 4: Give single OAuth denials an explicit transport status**

Keep `tools/list`, `Clients.filter_tools/2`, `handle_batch/2`, and `dispatch_single/5` unchanged. Replace only the single-request denial branch with `out_of_scope_tool(conn, id, name)` and add:

```elixir
defp out_of_scope_tool(conn, id, name) do
  conn =
    case conn.assigns[:resource_auth] do
      %{kind: :oauth} ->
        Backplane.Auth.BearerChallenge.put(conn, :mcp,
          error: "insufficient_scope",
          scope: name
        )

      _other ->
        conn
    end

  status = if get_in(conn.assigns, [:resource_auth, :kind]) == :oauth, do: 403, else: 200
  json_rpc_error(conn, id, -32_001, "Tool '#{name}' is not in scope for this client", status)
end
```

Change the helper signature to `json_rpc_error(conn, id, code, message, status \\ 200)`. Do not set a batch-wide header or status because each item can have a different required scope.

- [ ] **Step 5: Run MCP tests**

Run: `devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/router_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs`

Expected: OAuth MCP tests pass; existing PAT filtering, notifications, ETag, SSE, and batch tests stay green.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex \
  apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex \
  apps/backplane_mcp/test/backplane/transport/router_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
git commit -m "feat(mcp): enforce resource OAuth scopes"
```

## Task 10: Add the canonical `/v1` descriptor and OAuth operation scopes

**Files:**

- Create: `apps/backplane_llama/lib/backplane/llm/resource_authorization.ex`
- Create: `apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs`
- Modify: `apps/backplane_llama/lib/backplane/llm/proxy_plug.ex`
- Modify: `apps/backplane_llama/lib/backplane/llm/router.ex`
- Modify: `apps/backplane_llama/test/backplane/llm/router_test.exs`
- Modify: `apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs`
- Delete: `apps/backplane_system/lib/backplane/transport/auth_plug.ex`
- Delete: `apps/backplane_system/test/backplane/transport/auth_plug_test.exs`

- [ ] **Step 1: Write failing `/v1` policy and descriptor tests**

Cover open/authenticated descriptor success, canonical protected challenge, query-bearing descriptor without metadata, nested missing/invalid challenges without metadata, model/invoke separation, both wildcard grants, PAT/legacy/open full access, and MCP-audience rejection.

```elixir
test "maps routes to their least operation scope" do
  assert ResourceAuthorization.required_scope(conn(:get, "/v1")) == nil
  assert ResourceAuthorization.required_scope(conn(:get, "/v1/models")) == "llm::models"
  assert ResourceAuthorization.required_scope(conn(:post, "/v1/responses")) == "llm::invoke"
  assert ResourceAuthorization.required_scope(conn(:post, "/v1/messages")) == "llm::invoke"
end

test "canonical descriptor reports the resource and documentation" do
  body = public_llm_request(:get, "/v1") |> json_body()
  assert body["resource"] == Backplane.Auth.Resources.uri(:v1)
  assert body["resource_documentation"] == Backplane.Auth.Resources.documentation_uri(:v1)
end
```

- [ ] **Step 2: Confirm the route and policy tests fail**

Run: `devenv shell -- mix test apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs apps/backplane_llama/test/backplane/llm/router_test.exs apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs`

Expected: `GET /v1` is 404 and there is no OAuth operation-scope enforcement.

- [ ] **Step 3: Implement route-to-scope authorization**

```elixir
defmodule Backplane.LLM.ResourceAuthorization do
  @behaviour Plug
  import Plug.Conn

  alias Backplane.Auth.BearerChallenge
  alias Backplane.Clients

  def init(opts), do: opts

  def required_scope(%Plug.Conn{method: "GET", request_path: "/v1"}), do: nil
  def required_scope(%Plug.Conn{method: "GET", request_path: "/v1/models"}),
    do: "llm::models"
  def required_scope(%Plug.Conn{method: "POST", path_info: ["v1" | _rest]}),
    do: "llm::invoke"
  def required_scope(_conn), do: nil

  def call(%Plug.Conn{assigns: %{resource_auth: %{kind: :oauth, scopes: scopes}}} = conn, _opts) do
    case required_scope(conn) do
      nil -> conn
      scope ->
        if Clients.scope_matches?(scopes, scope) do
          conn
        else
          conn
          |> BearerChallenge.put(:v1, error: "insufficient_scope", scope: scope)
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{error: "insufficient_scope"}))
          |> halt()
        end
    end
  end

  def call(conn, _opts), do: conn
end
```

Use `Clients.scope_matches?/2` so exact scope, `llm::*`, and global `*` retain one tested matcher. PAT, legacy, and open assignments bypass this Plug.

- [ ] **Step 4: Install the two Plugs in the correct router order**

```elixir
plug(:match)
plug(Backplane.Auth.ResourceAuthPlug,
  resource: :v1,
  required_scope: {Backplane.LLM.ResourceAuthorization, :required_scope, []}
)
plug(Backplane.LLM.ResourceAuthorization)
```

The authentication Plug needs the callback only to add `scope` to a 401; `ResourceAuthorization` owns 403 decisions.

- [ ] **Step 5: Add `GET /v1` before `/v1/models`**

```elixir
get "/v1" do
  send_json(conn, 200, %{
    "resource" => Backplane.Auth.Resources.uri(:v1),
    "resource_documentation" => Backplane.Auth.Resources.documentation_uri(:v1)
  })
end
```

Do not add this route to `Backplane.Api.Router`. `Backplane.LLM.ProxyPlug` intercepts every `['v1' | rest]` request before endpoint parsers, including bare `/v1`.

- [ ] **Step 6: Remove the superseded system auth Plug**

After both MCP and LLM routers use `ResourceAuthPlug`, delete `Backplane.Transport.AuthPlug` and its direct test file. All legacy/PAT/open assertions now live in the shared resource Plug tests plus transport compatibility tests.

- [ ] **Step 7: Run the focused LLM and dependency tests**

Run: `devenv shell -- mix test apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs apps/backplane_llama/test/backplane/llm/router_test.exs apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs`

Expected: descriptor/scope tests pass and no code references `Backplane.Transport.AuthPlug`.

- [ ] **Step 8: Commit**

```bash
git add apps/backplane_llama/lib/backplane/llm/resource_authorization.ex \
  apps/backplane_llama/lib/backplane/llm/proxy_plug.ex \
  apps/backplane_llama/lib/backplane/llm/router.ex \
  apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs \
  apps/backplane_llama/test/backplane/llm/router_test.exs \
  apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs \
  apps/backplane_system/lib/backplane/transport/auth_plug.ex \
  apps/backplane_system/test/backplane/transport/auth_plug_test.exs
git commit -m "feat(llm): authorize the v1 OAuth resource"
```

## Task 11: Add resource create/edit controls to the OAuth admin UI

**Files:**

- Modify: `apps/backplane_admin/assets/js/app.js`
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex`
- Modify: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Write failing LiveView tests**

Cover resource checkboxes during create, resource badges in the table, an edit route, reducing assignments while preserving unrelated metadata/disabled state/scopes, immediate cache-visible activation, invalid ID handling, and a visible HTTPS-required error without mutation.

```elixir
test "creates and edits a client's protected resources", %{conn: conn} do
  scope!("github::*")
  {:ok, view, _html} = live(conn, "/auth/oauth/clients")

  view
  |> form("#oauth-client-form", %{
    "client" => %{
      "name" => "ChatGPT Connector",
      "redirect_uris" => "https://chatgpt.com/connector/callback",
      "scopes" => "github::*",
      "confidential" => "true",
      "resources" => %{"mcp" => "true", "v1" => "true"}
    }
  })
  |> render_submit()

  client = Enum.find(Auth.OAuth.list_clients(), &(&1.name == "ChatGPT Connector"))
  assert Auth.OAuth.client_resources(client) == [:mcp, :v1]

  {:ok, edit, html} = live(conn, "/auth/oauth/clients/#{client.id}/edit")
  assert html =~ "MCP (/mcp)"
  assert html =~ "LLM API (/v1)"

  edit
  |> form("#oauth-client-resource-form", %{
    "client" => %{"resources" => %{"mcp" => "true", "v1" => "false"}}
  })
  |> render_submit()

  assert Auth.OAuth.get_client(client.id) |> Auth.OAuth.client_resources() == [:mcp]
end
```

- [ ] **Step 2: Confirm the admin tests fail**

Run: `devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

Expected: there are no resource controls or client-edit route.

- [ ] **Step 3: Add the edit route and load the selected client**

Add:

```elixir
live("/auth/oauth/clients/:id/edit", AuthOAuthLive, :client_edit)
```

Initialize `editing_client: nil` in `mount/3`. In `handle_params/3`, load `Auth.OAuth.get_client(id)` for `:client_edit`; redirect to `/auth/oauth/clients` with an error flash when it is absent. Include `:client_edit` in the relevant `clients/1` and page-title branches.

- [ ] **Step 4: Add DuskMoon resource controls and an update event**

Add these controls to both create and edit forms, with `checked` driven by the selected client's assignments on edit:

```heex
<.dm_checkbox
  id="oauth-client-resource-mcp"
  name="client[resources][mcp]"
  label="MCP (/mcp)"
  checked={:mcp in selected_resources(@editing_client)}
/>
<.dm_checkbox
  id="oauth-client-resource-v1"
  name="client[resources][v1]"
  label="LLM API (/v1)"
  checked={:v1 in selected_resources(@editing_client)}
/>
```

The installed DuskMoon checkbox emits `"true"` plus a hidden `"false"`; it does not preserve a custom checkbox value. Parse the keyed map on both forms:

```elixir
defp resource_values(values) when is_map(values) do
  for {resource, enabled} <- values, truthy?(enabled), do: resource
end

defp resource_values(_values), do: []
```

On the create page, pass `resources: resource_values(Map.get(params, "resources", %{}))` from `client_attrs/1`. The edit event must call only the domain API:

```elixir
def handle_event("update-client-resources", %{"client" => params}, socket) do
  resources = resource_values(Map.get(params, "resources", %{}))

  case Auth.OAuth.update_client_resources(socket.assigns.editing_client, resources) do
    {:ok, client} ->
      Auth.Audit.record(
        "client.resources_updated",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{
          target_type: "oauth_client",
          target_id: client.id,
          metadata: %{"resources" => Enum.map(Auth.OAuth.client_resources(client), &to_string/1)}
        }
      )

      {:noreply, socket |> put_flash(:info, "OAuth client resources updated.") |> assign(:editing_client, client)}

    {:error, :https_required} ->
      {:noreply, put_flash(socket, :error, "OAuth protected resources require an HTTPS API origin.")}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "OAuth client resources could not be updated.")}
  end
end
```

Add a Resources column with `MCP`/`LLM API` badges and an Edit action. Define `selected_resources(nil)`, returning `[]`, and `selected_resources(client)`, delegating to `Auth.OAuth.client_resources/1`. Add an explicit `{:error, :https_required}` branch to the existing create event so create and edit show the same actionable HTTPS message. Do not render client secrets on edit; retain only the current one-time secret display immediately after create/rotation.

Keep the admin theme initializer aligned with DuskMoon's `ThemeSwitcher` hook: resolve `default` from the OS color scheme and retain a concrete `data-theme` value on the document root. Removing the attribute leaves DuskMoon checkbox variables undefined and makes the resource controls invisible.

- [ ] **Step 5: Run the admin tests**

Run: `devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

Expected: create, edit, metadata preservation, HTTPS, and existing client management tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_admin/assets/js/app.js \
  apps/backplane_admin/lib/backplane/admin/router.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
git commit -m "feat(admin): manage OAuth resource assignments"
```

## Task 12: Publish canonical MCP, LLM, agent, and authentication guides

**Files:**

- Modify: `apps/backplane_api/lib/backplane/api/controllers/page_controller.ex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/page_html/docs.html.heex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/page_html/home.html.heex`
- Modify: `apps/backplane_api/test/backplane/api/page_controller_test.exs`

- [ ] **Step 1: Write failing documentation contract tests**

Require canonical `/docs/mcp`, `/docs/llm`, `/docs/agents`, and `/docs/authentication` links; preserve `/docs/llama` and `/docs/auth` as aliases; assert the configured origin in examples; assert ChatGPT callback/predefined-client/PKCE guidance; assert direct PRM and canonical `/v1` probe examples; and seed known secret values then refute them from every docs page.

```elixir
test "renders ChatGPT resource OAuth setup without stored secrets", %{conn: conn} do
  old_url = Application.get_env(:backplane, :api_url)
  Application.put_env(:backplane, :api_url, "https://gateway.example.test")
  on_exit(fn ->
    if is_nil(old_url),
      do: Application.delete_env(:backplane, :api_url),
      else: Application.put_env(:backplane, :api_url, old_url)
  end)

  {:ok, %{secret: secret}} =
    Auth.OAuth.create_client(%{
      name: "Docs Secret Regression",
      redirect_uris: ["https://client.example.test/callback"],
      scopes: ["openid"],
      confidential: true,
      pkce: true
    })

  for path <- ["/docs/mcp", "/docs/llm", "/docs/agents", "/docs/authentication"] do
    html = conn |> recycle() |> get(path) |> html_response(200)
    assert html =~ "https://gateway.example.test"
    refute html =~ secret
  end

  mcp = conn |> recycle() |> get("/docs/mcp") |> html_response(200)
  assert mcp =~ "ChatGPT"
  assert mcp =~ "confidential"
  assert mcp =~ "PKCE S256"
  assert mcp =~ "/.well-known/oauth-protected-resource/mcp"
end
```

- [ ] **Step 2: Confirm canonical routes/content are absent**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/page_controller_test.exs`

Expected: `/docs/llm` and `/docs/authentication` return 404 and setup markers are absent.

- [ ] **Step 3: Make sections origin-aware and canonicalize slugs**

Replace the compile-time `@doc_sections` with `doc_sections(base_url)` so examples use `Backplane.WebOrigins.api_base_url/0`. Use canonical slugs `llm` and `authentication`. Map old aliases before lookup:

```elixir
def docs(conn, %{"section" => requested_slug}) do
  slug = Map.get(%{"llama" => "llm", "auth" => "authentication"}, requested_slug, requested_slug)
  sections = doc_sections(WebOrigins.api_base_url())

  case Enum.find(sections, &(&1.slug == slug)) do
    nil -> send_resp(conn, 404, "not found")
    section -> render_docs(conn, section, sections)
  end
end
```

Update hardcoded home cards/footer links to `/docs/llm` and `/docs/authentication`.

- [ ] **Step 4: Add ordered setup steps and copyable examples**

Extend each section with optional `steps` and `examples`, rendered as an ordered list and horizontally scrollable `<pre><code>` blocks. The MCP section must include content equivalent to:

```elixir
%{
  slug: "mcp",
  steps: [
    "Copy the exact callback URI shown in the ChatGPT app-management page.",
    "Create a confidential Backplane OAuth client, keep PKCE S256 enabled, and register that exact callback URI.",
    "Enable MCP (/mcp), assign MCP tool scopes to the client, and grant matching scopes to the signing-in user.",
    "Configure ChatGPT's MCP server URL as #{base_url}/mcp and enter the generated client ID and one-time client secret."
  ],
  examples: [
    %{
      title: "Discover MCP OAuth",
      code: "curl -i #{base_url}/mcp\ncurl #{base_url}/.well-known/oauth-protected-resource/mcp"
    }
  ]
}
```

The LLM guide must show direct PRM retrieval, unauthenticated `GET /v1`, authorize/token requests with `resource=#{base_url}/v1`, and `llm::models`/`llm::invoke`. Explain PAT/legacy compatibility. The agents guide must contain complete ChatGPT, Claude, and Codex endpoint configuration examples. The authentication guide must explain separate audiences, predefined clients, PKCE S256, refresh inheritance, revoke, HTTPS, and `invalid_target`/`invalid_token`/`insufficient_scope` troubleshooting.

Use placeholders such as `$CLIENT_ID`, `$CLIENT_SECRET`, `$CODE`, and `$ACCESS_TOKEN`; never read credentials or client secrets to render a page.

- [ ] **Step 5: Run documentation tests**

Run: `devenv shell -- mix test apps/backplane_api/test/backplane/api/page_controller_test.exs`

Expected: canonical/alias pages, configured-origin examples, and secret-leak regressions pass.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_api/lib/backplane/api/controllers/page_controller.ex \
  apps/backplane_api/lib/backplane/api/controllers/page_html/docs.html.heex \
  apps/backplane_api/lib/backplane/api/controllers/page_html/home.html.heex \
  apps/backplane_api/test/backplane/api/page_controller_test.exs
git commit -m "docs(auth): add resource OAuth setup guides"
```

## Task 13: Prove cross-surface flows, compatibility, and provider credential isolation

**Files:**

- Create: `apps/backplane_api/test/backplane/api/auth/resource_oauth_e2e_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/route_boundary_test.exs`
- Modify: `apps/backplane_llama/test/backplane/llm/streaming_integration_test.exs`
- Modify: `apps/backplane_llama/test/support/test_llm_upstream.ex`

- [ ] **Step 1: Add the true ChatGPT-style MCP E2E flow**

The test must run through `Backplane.Api.Endpoint`: unauthenticated `/mcp` challenge, MCP PRM, authorize/login with S256 and resource, code redirect, token exchange with the same resource, JWT audience assertion, authenticated initialize, filtered tools list, and allowed tool call.

```elixir
test "ChatGPT discovers and completes MCP OAuth", %{conn: conn} do
  %{client: client, user: user} = resource_principals(:mcp, ["public::echo"])

  challenge = post_mcp(conn, nil, "initialize", %{})
  assert challenge.status == 401
  assert bearer_header(challenge) =~ Resources.metadata_uri(:mcp)

  metadata = get(recycle(conn), "/.well-known/oauth-protected-resource/mcp") |> json_response(200)
  assert metadata["resource"] == Resources.uri(:mcp)

  verifier = "resource-oauth-verifier-with-at-least-43-characters"
  code = authorize_resource_with_login(conn, client, user, :mcp, verifier, nil)
  token = exchange_code(conn, client, code, verifier, Resources.uri(:mcp))

  assert {:ok, auth} = Auth.Tokens.verify_resource_access_token(token["access_token"], :mcp)
  assert auth.claims["aud"] == Resources.uri(:mcp)

  initialized = post_mcp(conn, token["access_token"], "initialize", %{})
  assert json_response(initialized, 200)["result"]["serverInfo"]["name"] == "backplane"
end
```

Implement the private helpers in this test file with real endpoint requests; do not bypass controllers or bind a JWT after signing.

- [ ] **Step 2: Add the `/v1` E2E and audience-isolation cases**

Test separate grants for `llm::models` and `llm::invoke`, `llm::*` and global `*`, canonical descriptor discovery, MCP-token rejection at `/v1`, `/v1`-token rejection at MCP, refresh inheritance, explicit matching refresh, cross-resource rejection, revoke, and immediate disabled-user/client rejection.

- [ ] **Step 3: Add the compatibility matrix**

In `resource_auth_compatibility_test.exs`, prove:

- PAT still filters MCP tools but has full `/v1` access.
- Legacy tokens retain full access to both surfaces.
- No PAT, legacy token, or enabled resource client leaves that surface open.
- Any supplied bad bearer rejects even in open mode.
- The first enabled OAuth client assignment protects only its selected resource.
- Removing the last assignment restores the remaining PAT/legacy/open policy.
- PAT/legacy-only challenges never advertise `resource_metadata`.
- Existing OAuth clients with an empty resource allowlist keep no-resource behavior and client-ID audience.

- [ ] **Step 4: Reverse the now-obsolete identity-JWT boundary assertion**

Update `route_boundary_test.exs` so a valid identity-only/client-ID-audience JWT receives `401 invalid_token` from `/mcp` and `/v1/models`, even when otherwise open. Keep `/skills` and `/host-agent` unchanged; they remain outside this feature and continue their existing behavior.

- [ ] **Step 5: Prove inbound credentials never reach providers**

The production paths already strip `authorization` and `x-api-key` in `Backplane.LLM.Router.do_proxy/7` and `do_embedding_proxy/3`; do not duplicate that code. Extend the successful capture upstream to record request headers, then send OAuth, PAT, and legacy bearer requests through an OpenAI-style provider that injects `Authorization`. In each case assert the upstream sees only the provider credential injected from the vault and never the inbound value or inbound `x-api-key`.

```elixir
refute Enum.any?(captured.headers, fn {_name, value} -> value == inbound_bearer end)
refute Enum.any?(captured.headers, fn {name, _value} -> name == "x-api-key" end)
assert {"authorization", "Bearer sk-provider-test"} in captured.headers
```

- [ ] **Step 6: Run the cross-app focused suite**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_api/test/backplane/api/auth/resource_oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs \
  apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/route_boundary_test.exs \
  apps/backplane_llama/test/backplane/llm/streaming_integration_test.exs
```

Expected: all resource, compatibility, identity, boundary, and credential-isolation tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane_api/test/backplane/api/auth/resource_oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs \
  apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/route_boundary_test.exs \
  apps/backplane_llama/test/backplane/llm/streaming_integration_test.exs \
  apps/backplane_llama/test/support/test_llm_upstream.ex
git commit -m "test(auth): cover resource OAuth end to end"
```

## Task 14: Perform scoped verification and visual QA

**Files:**

- Verify all files changed in Tasks 1–13
- Do not modify unrelated failures

- [ ] **Step 1: Format and compile with warnings as errors**

Run: `devenv shell -- mix format --check-formatted`

Run: `devenv shell -- mix compile --warnings-as-errors`

Expected: both commands exit 0.

- [ ] **Step 2: Run the complete in-scope test set**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs \
  apps/backplane_system/test/backplane/clients_test.exs \
  apps/backplane_auth/test/backplane/auth/resources_test.exs \
  apps/backplane_auth/test/backplane/auth/oauth_test.exs \
  apps/backplane_auth/test/backplane/auth/token_resources_test.exs \
  apps/backplane_auth/test/backplane/auth/tokens_test.exs \
  apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs \
  apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/login_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/token_controller_test.exs \
  apps/backplane_api/test/backplane/api/auth/oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/auth/resource_oauth_e2e_test.exs \
  apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs \
  apps/backplane_api/test/backplane/api/route_boundary_test.exs \
  apps/backplane_api/test/backplane/api/page_controller_test.exs \
  apps/backplane_mcp/test/backplane/transport/router_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs \
  apps/backplane_llama/test/backplane/llm/router_test.exs \
  apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs \
  apps/backplane_llama/test/backplane/llm/streaming_integration_test.exs \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: every in-scope test passes. If a test outside this list fails during compilation, report it and stop rather than changing out-of-scope code.

- [ ] **Step 3: Verify the route and metadata contract directly**

Run:

```bash
rg -n '/\.well-known/mcp|oauth-protected-resource|oauth-authorization-server' apps config docs
rg -n 'Backplane\.Transport\.AuthPlug' apps
```

Expected: no `/.well-known/mcp` route exists; the required discovery routes/tests/docs exist; the old auth Plug has no references.

With the public endpoint running, probe:

```bash
curl -sS http://localhost:4220/.well-known/oauth-protected-resource/mcp
curl -sS http://localhost:4220/.well-known/oauth-protected-resource/v1
curl -sS http://localhost:4220/.well-known/oauth-authorization-server
curl -i http://localhost:4220/v1
```

Expected: the metadata JSON has canonical configured resources, and protected `GET /v1` returns the expected challenge when an enabled `/v1` OAuth client exists.

- [ ] **Step 4: Inspect admin and docs at desktop and mobile widths**

Exercise `/auth/oauth/clients` create plus `/auth/oauth/clients/:id/edit`, then inspect `/docs/mcp`, `/docs/llm`, `/docs/agents`, and `/docs/authentication` at desktop and approximately 390 px width. Verify:

- DuskMoon checkbox labels and focus states are clear.
- Resource badges and the edit action are readable.
- Code blocks scroll horizontally without page overflow.
- Examples show the configured API origin.
- No stored client secret, access token, refresh token, or legacy token appears.

Capture one screenshot of the resource edit form and one of the ChatGPT MCP guide for the pull-request description.

- [ ] **Step 5: Run final change-scope detection**

Run the repository-required GitNexus change detection. Confirm the affected flows are limited to OAuth issuance/discovery, MCP authentication, `/v1` authentication, OAuth admin client configuration, and public docs. Review `git diff --check` and `git status --short`.

Expected: no whitespace errors, no unrelated files, and no uncommitted generated secrets or screenshots unless intentionally selected for the PR.
