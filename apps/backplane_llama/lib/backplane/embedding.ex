defmodule Backplane.Embedding do
  @moduledoc """
  Embedding-only provider and model context.
  """

  import Ecto.Query

  alias Backplane.Embedding.Model
  alias Backplane.Embedding.Provider
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @type model_id :: String.t()

  @doc "List active embedding providers with models preloaded."
  @spec list_providers() :: [Provider.t()]
  def list_providers do
    Provider
    |> where([provider], is_nil(provider.deleted_at))
    |> order_by([provider], provider.name)
    |> preload(:models)
    |> Repo.all()
  end

  @doc "List enabled embedding models with active providers preloaded."
  @spec list_enabled_models() :: [Model.t()]
  def list_enabled_models do
    Model
    |> join(:inner, [model], provider in assoc(model, :provider))
    |> where(
      [model, provider],
      model.enabled == true and provider.enabled == true and is_nil(provider.deleted_at)
    )
    |> order_by([model, provider], [provider.name, model.model])
    |> preload([_model, provider], provider: provider)
    |> Repo.all()
  end

  @doc "Get a single embedding model whose provider is still active."
  @spec get_model(binary()) :: Model.t() | nil
  def get_model(id) do
    Model
    |> join(:inner, [model], provider in assoc(model, :provider))
    |> where([_model, provider], is_nil(provider.deleted_at))
    |> preload([_model, provider], provider: provider)
    |> Repo.get(id)
  end

  @doc "Create an embedding provider and its first model."
  @spec create_provider_with_model(map()) ::
          {:ok, %{provider: Provider.t(), model: Model.t()}} | {:error, map()}
  def create_provider_with_model(attrs) do
    Repo.transaction(fn ->
      with {:ok, provider} <-
             %Provider{}
             |> Provider.changeset(provider_attrs(attrs))
             |> Repo.insert(),
           {:ok, model} <-
             %Model{}
             |> Model.changeset(model_attrs(provider, attrs))
             |> Repo.insert() do
        %{provider: provider, model: model}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
      end
    end)
  end

  @doc "Update an embedding provider and one of its models together."
  @spec update_provider_with_model(Model.t(), map()) ::
          {:ok, %{provider: Provider.t(), model: Model.t()}} | {:error, map()}
  def update_provider_with_model(%Model{} = model, attrs) do
    Repo.transaction(fn ->
      model = Repo.preload(model, :provider)

      with %Provider{} = provider <- model.provider,
           {:ok, provider} <-
             provider
             |> Provider.changeset(provider_attrs(attrs))
             |> Repo.update(),
           {:ok, model} <-
             model
             |> Model.changeset(model_attrs(provider, attrs))
             |> Repo.update() do
        %{provider: provider, model: %{model | provider: provider}}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset_errors(changeset))
        _ -> Repo.rollback(%{"provider" => "not found"})
      end
    end)
  end

  @doc "Soft-delete an embedding provider and exclude its models from resolution."
  @spec soft_delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_provider(%Provider{} = provider) do
    provider
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), enabled: false)
    |> Repo.update()
  end

  @doc "Resolve `provider/model` to an enabled embedding provider and raw model id."
  @spec resolve_model(model_id()) :: {:ok, Provider.t(), String.t()} | {:error, :no_provider}
  def resolve_model(model_id) when is_binary(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [provider_name, raw_model] ->
        resolve_prefixed(provider_name, raw_model)

      _ ->
        {:error, :no_provider}
    end
  end

  @doc "Build OpenAI-compatible embedding auth headers for a provider."
  @spec build_auth_headers(Provider.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{} = provider) do
    case Credentials.fetch_with_meta(provider.credential) do
      {:ok, token, meta} ->
        headers =
          [{"authorization", "Bearer #{token}"}] ++
            meta.extra_headers ++
            default_header_pairs(provider.default_headers)

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Render the stable model id used by memory.embed_model."
  @spec model_id(Model.t()) :: String.t()
  def model_id(%Model{provider: %Provider{} = provider} = model),
    do: "#{provider.name}/#{model.model}"

  defp resolve_prefixed(provider_name, raw_model) do
    query =
      Model
      |> join(:inner, [model], provider in assoc(model, :provider))
      |> where(
        [model, provider],
        provider.name == ^provider_name and provider.enabled == true and
          is_nil(provider.deleted_at) and model.model == ^raw_model and model.enabled == true
      )
      |> preload([_model, provider], provider: provider)

    case Repo.one(query) do
      %Model{provider: provider} -> {:ok, provider, raw_model}
      nil -> {:error, :no_provider}
    end
  end

  defp provider_attrs(attrs) do
    %{
      name: attrs["name"],
      credential: attrs["credential"],
      base_url: attrs["base_url"],
      enabled: truthy?(attrs["enabled"]),
      default_headers: decode_json_map(attrs["default_headers"])
    }
  end

  defp model_attrs(provider, attrs) do
    %{
      provider_id: provider.id,
      model: attrs["model"],
      display_name: blank_to_nil(attrs["display_name"]),
      enabled: truthy?(attrs["model_enabled"]),
      metadata: decode_json_map(attrs["metadata"])
    }
  end

  defp default_header_pairs(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp default_header_pairs(_headers), do: []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_), do: false

  defp decode_json_map(value) when value in [nil, ""], do: %{}

  defp decode_json_map(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.new(fn {key, messages} -> {Atom.to_string(key), Enum.join(messages, ", ")} end)
  end
end
