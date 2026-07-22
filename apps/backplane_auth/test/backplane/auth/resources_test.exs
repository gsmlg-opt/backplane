defmodule Backplane.Auth.ResourcesTest do
  use ExUnit.Case, async: false

  alias Backplane.Auth.Resources

  setup do
    old_url = Application.get_env(:backplane, :api_url)
    old_env = Application.get_env(:backplane, :env)
    old_override = Application.get_env(:backplane_auth, :allow_insecure_resource_origins)

    Application.put_env(:backplane, :api_url, "https://backplane.example.test")
    Application.put_env(:backplane, :env, :test)
    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, false)

    on_exit(fn ->
      restore(:backplane, :api_url, old_url)
      restore(:backplane, :env, old_env)
      restore(:backplane_auth, :allow_insecure_resource_origins, old_override)
    end)
  end

  test "builds the two canonical resource surfaces" do
    assert Resources.keys() == [:mcp, :v1]
    assert Resources.path(:mcp) == "/mcp"
    assert Resources.path(:v1) == "/v1"

    assert Resources.uri(:mcp) == "https://backplane.example.test/mcp"
    assert Resources.uri(:v1) == "https://backplane.example.test/v1"

    assert Resources.metadata_uri(:mcp) ==
             "https://backplane.example.test/.well-known/oauth-protected-resource/mcp"

    assert Resources.metadata_uri(:v1) ==
             "https://backplane.example.test/.well-known/oauth-protected-resource/v1"

    assert Resources.documentation_uri(:mcp) == "https://backplane.example.test/docs/mcp"
    assert Resources.documentation_uri(:v1) == "https://backplane.example.test/docs/llm"

    assert Resources.from_uri(Resources.uri(:mcp)) == {:ok, :mcp}
    assert Resources.from_uri(Resources.uri(:v1)) == {:ok, :v1}

    for invalid <- [
          "https://backplane.example.test/v1/",
          "https://other.example.test/mcp",
          "https://backplane.example.test/mcp?operation=list",
          "https://backplane.example.test/v1#models",
          "https://backplane.example.test:444/v1",
          "https://user@backplane.example.test/mcp",
          "https://backplane.example.test/%6Dcp",
          "https://backplane.example.test/v1/../v1"
        ] do
      assert Resources.from_uri(invalid) == :error
    end
  end

  test "normalizes and deduplicates resource keys" do
    assert Resources.normalize_keys([:v1, "mcp", :mcp, "v1", :v1]) == {:ok, [:mcp, :v1]}
    assert Resources.normalize_keys([]) == {:ok, []}
  end

  test "rejects invalid resource keys" do
    for invalid <- ["api", :api, nil, 1] do
      assert Resources.normalize_keys([invalid]) == {:error, :invalid_resource}
    end

    assert Resources.normalize_keys(["mcp", "api"]) == {:error, :invalid_resource}
  end

  test "keeps identity scopes valid but classifies operation scopes per resource" do
    for scope <- ["openid", "profile", "email"] do
      assert Resources.valid_scope?(:mcp, scope)
      assert Resources.valid_scope?(:v1, scope)
      refute Resources.operation_scope?(:mcp, scope)
      refute Resources.operation_scope?(:v1, scope)
    end

    assert Resources.valid_scope?(:mcp, "github::search")
    assert Resources.valid_scope?(:mcp, "github::*")
    assert Resources.valid_scope?(:mcp, "llm::models")
    assert Resources.valid_scope?(:mcp, "*")

    for scope <- ["llm::models", "llm::invoke", "llm::*", "*"] do
      assert Resources.valid_scope?(:v1, scope)
      assert Resources.operation_scope?(:v1, scope)
    end

    assert Resources.operation_scope?(:mcp, "github::search")
    assert Resources.operation_scope?(:mcp, "github::*")
    refute Resources.valid_scope?(:v1, "github::search")
    refute Resources.operation_scope?(:v1, "github::search")

    for invalid <- ["github:search", "github::search::issues", "github::", "::search"] do
      refute Resources.valid_scope?(:mcp, invalid)
      refute Resources.protected_operation_scope?(invalid)
    end
  end

  test "rejects malformed protected operation scopes" do
    for invalid <- [
          "github::search*",
          "github::**",
          "*::search",
          "github ::search",
          "github::search issues",
          "github::search/issues",
          "github::search\n",
          "github::search::issues"
        ] do
      refute Resources.valid_scope?(:mcp, invalid)
      refute Resources.operation_scope?(:mcp, invalid)
      refute Resources.protected_operation_scope?(invalid)
    end

    for invalid <- ["llm::admin", "llm::models::extra"] do
      refute Resources.valid_scope?(:v1, invalid)
      refute Resources.operation_scope?(:v1, invalid)
    end
  end

  test "rejects system scopes from protected resource operations" do
    for key <- Resources.keys(), scope <- ["system::*", "system::admin", "system::future"] do
      refute Resources.valid_scope?(key, scope)
      refute Resources.operation_scope?(key, scope)
    end

    assert Resources.protected_operation_scope?("*")
    assert Resources.protected_operation_scope?("github::search")
    assert Resources.protected_operation_scope?("github::*")
    refute Resources.protected_operation_scope?("openid")
    refute Resources.protected_operation_scope?("system::*")
    refute Resources.protected_operation_scope?("system::admin")
    refute Resources.protected_operation_scope?("system::future")
  end

  test "defaults omitted scopes to the resource-operation intersection only" do
    client = ["openid", "github::*", "llm::invoke", "llm::invoke", "system::*"]
    user = ["openid", "github::*", "llm::invoke", "system::*", "user::only"]

    assert Resources.default_scopes(:mcp, client, user) ==
             {:ok, ["github::*", "llm::invoke"]}

    assert Resources.default_scopes(:v1, client, user) == {:ok, ["llm::invoke"]}
  end

  test "fails omitted-scope resolution when no operation scope intersects" do
    assert Resources.default_scopes(:v1, ["openid"], ["openid"]) ==
             {:error, :invalid_scope}

    assert Resources.default_scopes(:mcp, ["github::*"], ["llm::invoke"]) ==
             {:error, :invalid_scope}
  end

  test "keeps wildcard defaults as exact intersections" do
    assert Resources.default_scopes(:mcp, ["*", "github::*"], ["*", "github::*"]) ==
             {:ok, ["*", "github::*"]}

    assert Resources.default_scopes(:mcp, ["*"], ["github::*"]) ==
             {:error, :invalid_scope}

    assert Resources.default_scopes(:v1, ["*", "llm::*"], ["*", "llm::*"]) ==
             {:ok, ["*", "llm::*"]}

    assert Resources.default_scopes(:v1, ["llm::*"], ["llm::invoke"]) ==
             {:error, :invalid_scope}

    assert Resources.default_scopes(:v1, ["llm::invoke"], ["llm::*"]) ==
             {:error, :invalid_scope}
  end

  test "requires HTTPS for non-empty resource requests" do
    assert Resources.validate_origin([:mcp, :v1]) == :ok

    Application.put_env(:backplane, :api_url, "http://localhost:4220")
    assert Resources.validate_origin([:mcp]) == {:error, :https_required}

    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, true)

    for env <- [:dev, :test] do
      Application.put_env(:backplane, :env, env)
      assert Resources.validate_origin([:mcp]) == :ok
    end

    for env <- [:prod, :staging, nil] do
      Application.put_env(:backplane, :env, env)
      assert Resources.validate_origin([:mcp]) == {:error, :https_required}
    end

    assert Resources.validate_origin([]) == :ok
  end

  test "requires a canonical HTTPS origin" do
    for invalid <- [
          "https:opaque",
          "https:///missing-host",
          "https://backplane.example.test:bad",
          "https://backplane example.test",
          "https://user@backplane.example.test",
          "https://backplane.example.test/api",
          "https://backplane.example.test?tenant=one",
          "https://backplane.example.test#fragment"
        ] do
      Application.put_env(:backplane, :api_url, invalid)
      assert Resources.validate_origin([:mcp]) == {:error, :https_required}
    end
  end

  test "accepts canonical HTTPS origins with valid ports" do
    Application.put_env(:backplane, :api_url, "https://backplane.example.test:8443")
    assert Resources.validate_origin([:mcp, :v1]) == :ok
  end

  test "never permits other schemes through the insecure local override" do
    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, true)
    Application.put_env(:backplane, :api_url, "ftp://localhost:4220")

    for env <- [:dev, :test] do
      Application.put_env(:backplane, :env, env)
      assert Resources.validate_origin([:mcp]) == {:error, :https_required}
    end
  end

  test "permits insecure origins only for local hosts in dev and test" do
    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, true)

    for env <- [:dev, :test], origin <- local_http_origins() do
      Application.put_env(:backplane, :env, env)
      Application.put_env(:backplane, :api_url, origin)
      assert Resources.validate_origin([:mcp]) == :ok
    end

    Application.put_env(:backplane, :env, :test)
    Application.put_env(:backplane, :api_url, "http://backplane.example.test:4220")
    assert Resources.validate_origin([:mcp]) == {:error, :https_required}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp local_http_origins do
    ["http://localhost:4220", "http://127.0.0.1:4220", "http://[::1]:4220"]
  end
end
