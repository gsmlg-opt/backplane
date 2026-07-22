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
    assert Resources.from_uri("https://backplane.example.test/v1/") == :error
    assert Resources.from_uri("https://other.example.test/mcp") == :error
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

  test "rejects system scopes from protected resource operations" do
    for key <- Resources.keys(), scope <- ["system::*", "system::admin"] do
      refute Resources.valid_scope?(key, scope)
      refute Resources.operation_scope?(key, scope)
    end

    assert Resources.protected_operation_scope?("*")
    assert Resources.protected_operation_scope?("github::search")
    assert Resources.protected_operation_scope?("github::*")
    refute Resources.protected_operation_scope?("openid")
    refute Resources.protected_operation_scope?("system::*")
    refute Resources.protected_operation_scope?("system::admin")
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

  test "requires HTTPS for non-empty resource requests" do
    assert Resources.validate_origin([:mcp, :v1]) == :ok

    Application.put_env(:backplane, :api_url, "http://localhost:4220")
    assert Resources.validate_origin([:mcp]) == {:error, :https_required}

    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, true)

    for env <- [:dev, :test] do
      Application.put_env(:backplane, :env, env)
      assert Resources.validate_origin([:mcp]) == :ok
    end

    Application.put_env(:backplane, :env, :prod)
    assert Resources.validate_origin([:mcp]) == {:error, :https_required}
    assert Resources.validate_origin([]) == :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
