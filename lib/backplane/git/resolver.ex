defmodule Backplane.Git.Resolver do
  @moduledoc """
  Resolves repository strings like "github:owner/repo" or "gitlab:group/project"
  to {provider_module, config, repo_id} tuples.

  Supports named instances: "github.enterprise:owner/repo" looks up the
  "enterprise" instance from config.
  """

  alias Backplane.Git.Providers.{GitHub, GitLab}

  @doc """
  Resolves a repo string to a provider module, config, and repo ID.

  ## Format

      "provider:owner/repo"
      "provider.instance:owner/repo"

  ## Examples

      iex> Backplane.Git.Resolver.resolve("github:elixir-lang/elixir")
      {:ok, {Backplane.Git.Providers.GitHub, %{token: "...", api_url: "..."}, "elixir-lang/elixir"}}

  """
  @spec resolve(String.t()) :: {:ok, {module(), map(), String.t()}} | {:error, atom()}
  def resolve(repo_string) do
    case String.split(repo_string, ":", parts: 2) do
      [provider_part, repo_id] when repo_id != "" ->
        resolve_provider(provider_part, repo_id)

      _ ->
        {:error, :invalid_format}
    end
  end

  defp resolve_provider(provider_part, repo_id) do
    {provider_type, instance_name} = parse_provider_part(provider_part)

    case provider_type do
      "github" ->
        case find_instance(:github, instance_name) do
          {:ok, config} -> {:ok, {GitHub, config, repo_id}}
          {:error, _} = err -> err
        end

      "gitlab" ->
        case find_instance(:gitlab, instance_name) do
          {:ok, config} -> {:ok, {GitLab, config, repo_id}}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :unknown_provider}
    end
  end

  defp parse_provider_part(part) do
    case String.split(part, ".", parts: 2) do
      [provider, instance] -> {provider, instance}
      [provider] -> {provider, "default"}
    end
  end

  defp find_instance(provider_type, instance_name) do
    providers = Application.get_env(:backplane, :git_providers, %{})
    instances = Map.get(providers, provider_type, [])

    case Enum.find(instances, fn inst -> inst.name == instance_name end) do
      nil ->
        {:error, :unknown_provider}

      instance ->
        config = %{
          token: instance.token,
          api_url: instance.api_url
        }

        {:ok, config}
    end
  end
end
