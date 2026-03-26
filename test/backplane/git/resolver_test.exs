defmodule Backplane.Git.ResolverTest do
  use ExUnit.Case, async: false

  alias Backplane.Git.Providers.{GitHub, GitLab}
  alias Backplane.Git.Resolver

  setup do
    # Set up test provider config
    providers = %{
      github: [
        %{name: "default", token: "gh-token-123", api_url: "https://api.github.com"}
      ],
      gitlab: [
        %{name: "default", token: "gl-token-456", api_url: "https://gitlab.com/api/v4"},
        %{
          name: "internal",
          token: "gl-internal-789",
          api_url: "https://gitlab.internal.co/api/v4"
        }
      ]
    }

    Application.put_env(:backplane, :git_providers, providers)

    on_exit(fn ->
      Application.delete_env(:backplane, :git_providers)
    end)

    :ok
  end

  test "resolves github:owner/repo to GitHub provider" do
    assert {:ok, {GitHub, config, "elixir-lang/elixir"}} =
             Resolver.resolve("github:elixir-lang/elixir")

    assert config.token == "gh-token-123"
    assert config.api_url == "https://api.github.com"
  end

  test "resolves gitlab:group/project to GitLab provider" do
    assert {:ok, {GitLab, config, "my-group/my-project"}} =
             Resolver.resolve("gitlab:my-group/my-project")

    assert config.token == "gl-token-456"
    assert config.api_url == "https://gitlab.com/api/v4"
  end

  test "resolves named instance gitlab.internal:group/project" do
    assert {:ok, {GitLab, config, "infra/tools"}} =
             Resolver.resolve("gitlab.internal:infra/tools")

    assert config.token == "gl-internal-789"
    assert config.api_url == "https://gitlab.internal.co/api/v4"
  end

  test "returns error for unknown provider" do
    assert {:error, :unknown_provider} = Resolver.resolve("bitbucket:owner/repo")
  end

  test "returns error for invalid format" do
    assert {:error, :invalid_format} = Resolver.resolve("no-colon-here")
    assert {:error, :invalid_format} = Resolver.resolve("github:")
  end

  test "returns error for github instance not found by name" do
    # "github.enterprise" looks up the "enterprise" named instance under :github.
    # Our setup only has "default", so this should return :unknown_provider.
    assert {:error, :unknown_provider} = Resolver.resolve("github.enterprise:owner/repo")
  end

  test "returns error for gitlab instance not found by name" do
    # "gitlab.missing" looks up the "missing" named instance under :gitlab.
    # Our setup has "default" and "internal" but not "missing".
    assert {:error, :unknown_provider} = Resolver.resolve("gitlab.missing:group/project")
  end

  test "returns error for gitlab when no providers configured" do
    Application.put_env(:backplane, :git_providers, %{})

    assert {:error, :unknown_provider} = Resolver.resolve("gitlab:group/project")
  end

  test "returns error for github when no providers configured" do
    Application.put_env(:backplane, :git_providers, %{})

    assert {:error, :unknown_provider} = Resolver.resolve("github:owner/repo")
  end

  test "propagates gitlab error tuple from find_instance" do
    # When the instance list for :gitlab is empty, find_instance/2 returns
    # {:error, :unknown_provider} and resolve_provider/2 propagates it.
    Application.put_env(:backplane, :git_providers, %{github: [], gitlab: []})

    assert {:error, :unknown_provider} = Resolver.resolve("gitlab:group/repo")
  end

  test "propagates github error tuple from find_instance" do
    Application.put_env(:backplane, :git_providers, %{github: [], gitlab: []})

    assert {:error, :unknown_provider} = Resolver.resolve("github:owner/repo")
  end
end
