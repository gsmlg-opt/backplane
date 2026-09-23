defmodule Backplane.LLM.ProviderApi do
  @moduledoc """
  API surface configuration for an LLM provider.

  One provider can expose independent OpenAI-compatible, Anthropic Messages,
  and Google GenerateContent surfaces.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.Provider
  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_provider_apis" do
    field(:api_surface, Ecto.Enum, values: [:openai, :anthropic, :google, :antigravity])

    field(:native_protocols, {:array, Ecto.Enum},
      values: [
        :openai_chat_completions,
        :openai_responses,
        :anthropic_messages,
        :google_generate_content,
        :google_antigravity
      ],
      default: []
    )

    field(:base_url, :string)
    field(:enabled, :boolean, default: true)
    field(:default_headers, :map, default: %{})
    field(:backend_config, :map, default: %{})
    field(:model_discovery_enabled, :boolean, default: true)
    field(:model_discovery_path, :string)
    field(:last_discovered_at, :utc_datetime_usec)

    belongs_to(:provider, Provider, type: :binary_id)
    has_many(:model_surfaces, ProviderModelSurface, foreign_key: :provider_api_id)

    timestamps()
  end

  @required_fields ~w(provider_id api_surface base_url)a
  @optional_fields ~w(native_protocols enabled default_headers backend_config model_discovery_enabled model_discovery_path last_discovered_at)a

  @doc "Changeset for creating or updating a provider API surface."
  def changeset(api, attrs) do
    api
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:base_url, &trim_trailing_slash/1)
    |> put_default_native_protocols()
    |> validate_required(@required_fields)
    |> validate_length(:native_protocols, min: 1)
    |> validate_native_protocols()
    |> validate_google_version()
    |> Provider.validate_api_url(:base_url)
    |> validate_default_headers()
    |> validate_backend_config()
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :api_surface])
  end

  @doc "Create a provider API surface."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    broadcast_on_ok(result)
  end

  @doc "Update a provider API surface."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = api, attrs) do
    result =
      api
      |> changeset(attrs)
      |> Repo.update()

    broadcast_on_ok(result)
  end

  @doc "List enabled provider API surfaces with providers preloaded."
  @spec list_enabled() :: [t()]
  def list_enabled do
    __MODULE__
    |> join(:inner, [api], provider in assoc(api, :provider))
    |> where(
      [api, provider],
      api.enabled == true and provider.enabled == true and is_nil(provider.deleted_at)
    )
    |> preload([_api, provider], provider: provider)
    |> Repo.all()
  end

  @doc "List provider API surfaces for a provider."
  @spec list_for_provider(binary()) :: [t()]
  def list_for_provider(provider_id) do
    __MODULE__
    |> where([api], api.provider_id == ^provider_id)
    |> order_by([api], api.api_surface)
    |> Repo.all()
  end

  @doc "Fetch a provider API surface by id."
  @spec get(binary()) :: t() | nil
  def get(id), do: Repo.get(__MODULE__, id)

  defp trim_trailing_slash(url) when is_binary(url), do: String.trim_trailing(url, "/")
  defp trim_trailing_slash(url), do: url

  defp put_default_native_protocols(changeset) do
    case fetch_change(changeset, :native_protocols) do
      {:ok, _protocols} ->
        changeset

      :error ->
        case get_field(changeset, :native_protocols) do
          protocols when is_list(protocols) and protocols != [] ->
            changeset

          _ ->
            case get_field(changeset, :api_surface) do
              :openai -> put_change(changeset, :native_protocols, [:openai_chat_completions])
              :anthropic -> put_change(changeset, :native_protocols, [:anthropic_messages])
              :google -> put_change(changeset, :native_protocols, [:google_generate_content])
              :antigravity -> put_change(changeset, :native_protocols, [:google_antigravity])
              _ -> changeset
            end
        end
    end
  end

  defp validate_native_protocols(changeset) do
    validate_change(changeset, :native_protocols, fn :native_protocols, protocols ->
      api_surface = get_field(changeset, :api_surface)

      allowed =
        case api_surface do
          :openai -> [:openai_chat_completions, :openai_responses]
          :anthropic -> [:anthropic_messages]
          :google -> [:google_generate_content]
          :antigravity -> [:google_antigravity]
          _ -> []
        end

      if Enum.all?(protocols, &(&1 in allowed)) do
        []
      else
        [native_protocols: "must use protocols from the selected API family"]
      end
    end)
  end

  defp validate_default_headers(changeset) do
    validate_change(changeset, :default_headers, fn
      :default_headers, headers when is_map(headers) -> []
      :default_headers, _headers -> [default_headers: "must be a map"]
    end)
  end

  defp validate_backend_config(changeset) do
    validate_change(changeset, :backend_config, fn
      :backend_config, config when is_map(config) -> backend_config_errors(config, changeset)
      :backend_config, _config -> [backend_config: "must be a map"]
    end)
  end

  defp backend_config_errors(config, changeset) do
    allowed = ~w(project_id user_agent client_version)
    keys = Map.keys(config)

    cond do
      get_field(changeset, :api_surface) != :antigravity and map_size(config) > 0 ->
        [backend_config: "is only supported for Antigravity APIs"]

      Enum.any?(keys, &(not is_binary(&1) or &1 not in allowed)) ->
        [backend_config: "contains an unsupported key"]

      invalid_project?(config["project_id"]) ->
        [backend_config: "project_id must be a safe identifier"]

      invalid_header_value?(config["user_agent"]) ->
        [backend_config: "user_agent must be a safe header value"]

      invalid_header_value?(config["client_version"]) ->
        [backend_config: "client_version must be a safe header value"]

      true ->
        []
    end
  end

  defp invalid_project?(nil), do: false

  defp invalid_project?(value) when is_binary(value),
    do: not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,254}\z/, value)

  defp invalid_project?(_value), do: true

  defp invalid_header_value?(nil), do: false

  defp invalid_header_value?(value) when is_binary(value),
    do:
      value == "" or byte_size(value) > 256 or not String.valid?(value) or
        String.contains?(value, ["\r", "\n"])

  defp invalid_header_value?(_value), do: true

  defp validate_google_version(changeset) do
    if get_field(changeset, :api_surface) == :google do
      validate_change(changeset, :base_url, fn :base_url, base_url ->
        path = URI.parse(base_url).path || ""

        if String.ends_with?(String.trim_trailing(path, "/"), "/v1beta"),
          do: [],
          else: [base_url: "must end with /v1beta for Google GenerateContent"]
      end)
    else
      changeset
    end
  end

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
