defmodule Backplane.Git.ResolverTest do
  use ExUnit.Case, async: true

  alias Backplane.Git.Resolver
  alias Backplane.Git.Providers.{GitHub, GitLab}

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
end
