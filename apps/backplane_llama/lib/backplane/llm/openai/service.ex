defmodule Backplane.LLM.OpenAI.Service do
  @moduledoc """
  Explicit native OpenAI capabilities, independent of chat-model discovery.

  Each capability references an existing provider and its OpenAI API surface.
  Credentials remain in the vault; models here never enter the chat catalog.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.{CredentialPlug, Provider, ProviderApi}
  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @kinds [:decisions, :images, :speech, :transcription, :realtime]
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "llm_openai_services" do
    field :kind, Ecto.Enum, values: @kinds
    field :enabled, :boolean, default: true
    field :models, {:array, :string}, default: []
    field :default_model, :string
    field :request_timeout_ms, :integer, default: 120_000
    field :max_request_bytes, :integer, default: 50_000_000
    field :max_response_bytes, :integer, default: 100_000_000
    field :max_session_ms, :integer, default: 3_600_000
    belongs_to :provider, Provider, type: :binary_id
    timestamps()
  end

  @fields ~w(provider_id kind enabled models default_model request_timeout_ms max_request_bytes max_response_bytes max_session_ms)a
  def kinds, do: @kinds

  def changeset(service, attrs) do
    service
    |> cast(attrs, @fields)
    |> update_change(:models, &Enum.uniq/1)
    |> validate_required([
      :provider_id,
      :kind,
      :models,
      :enabled,
      :request_timeout_ms,
      :max_request_bytes,
      :max_response_bytes,
      :max_session_ms
    ])
    |> validate_length(:models, min: 1, max: 256)
    |> validate_change(:models, fn :models, models ->
      if Enum.all?(
           models,
           &(is_binary(&1) and byte_size(&1) in 1..1024 and String.trim(&1) == &1)
         ),
         do: [],
         else: [models: "must contain nonempty model identifiers without surrounding whitespace"]
    end)
    |> validate_default()
    |> validate_number(:request_timeout_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 600_000
    )
    |> validate_number(:max_request_bytes, greater_than: 0, less_than_or_equal_to: 100_000_000)
    |> validate_number(:max_response_bytes, greater_than: 0, less_than_or_equal_to: 500_000_000)
    |> validate_number(:max_session_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 7_200_000
    )
    |> validate_provider()
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :kind])
  end

  def list(kind) when kind in @kinds do
    __MODULE__
    |> where([s], s.kind == ^kind)
    |> order_by([s], s.inserted_at)
    |> preload(:provider)
    |> Repo.all()
  end

  def get(id), do: __MODULE__ |> preload(:provider) |> Repo.get(id)
  def create(attrs), do: %__MODULE__{} |> changeset(attrs) |> Repo.insert()
  def update(service, attrs), do: service |> changeset(attrs) |> Repo.update()
  def delete(service), do: Repo.delete(service)

  def enabled?(kind), do: Enum.any?(list(kind), & &1.enabled)

  def resolve(kind, model) when kind in @kinds and (is_binary(model) or is_nil(model)) do
    matches =
      kind
      |> list()
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(fn service ->
        provider = service.provider
        api = Repo.get_by(ProviderApi, provider_id: provider.id, api_surface: :openai)

        with true <-
               provider.enabled and is_nil(provider.deleted_at) and
                 is_nil(provider.host_service_id),
             %ProviderApi{enabled: true} <- api,
             :ok <- api_target(api),
             {:ok, raw} <- matching_model(service, provider, model),
             :ok <- api_key(provider) do
          [
            %{
              service: service,
              provider: provider,
              api: api,
              requested_model: model || raw,
              raw_model: raw
            }
          ]
        else
          _ -> []
        end
      end)

    case matches do
      [route] -> {:ok, route}
      [] -> {:error, :model_unavailable}
      _ -> {:error, :ambiguous_model}
    end
  end

  def resolve(_, _), do: {:error, :invalid_model}

  def auth_headers(%{provider: provider, api: api}) do
    with {:ok, credential} <- api_key_credential(provider),
         {:ok, headers} <-
           CredentialPlug.build_responses_auth_headers(
             %{provider | default_headers: %{}},
             credential
           ) do
      defaults = Map.merge(provider.default_headers || %{}, api.default_headers || %{})
      {:ok, headers ++ safe_headers(defaults)}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def url(%{api: api}, path) do
    uri = URI.parse(api.base_url)
    prefix = if uri.path in [nil, "", "/"], do: "/v1", else: String.trim_trailing(uri.path, "/")

    URI.to_string(%{
      uri
      | path: prefix <> "/" <> String.trim_leading(path, "/"),
        query: nil,
        fragment: nil
    })
  end

  defp matching_model(%{default_model: nil}, _provider, nil), do: {:error, :no_default}
  defp matching_model(service, _provider, nil), do: {:ok, service.default_model}

  defp matching_model(service, provider, model) do
    prefix = provider.name <> "/"

    raw =
      if String.starts_with?(model, prefix),
        do: String.replace_prefix(model, prefix, ""),
        else: model

    if raw in service.models, do: {:ok, raw}, else: {:error, :unknown_model}
  end

  defp validate_default(changeset) do
    default = get_field(changeset, :default_model)

    if is_nil(default) or default in (get_field(changeset, :models) || []),
      do: changeset,
      else: add_error(changeset, :default_model, "must be one of the configured models")
  end

  defp validate_provider(changeset) do
    case get_field(changeset, :provider_id) do
      nil ->
        changeset

      id ->
        with %Provider{host_service_id: nil} = provider <- Repo.get(Provider, id),
             %ProviderApi{} = api <-
               Repo.get_by(ProviderApi, provider_id: id, api_surface: :openai),
             :ok <- api_target(api),
             :ok <- api_key(provider) do
          changeset
        else
          _ ->
            add_error(
              changeset,
              :provider_id,
              "must have a direct OpenAI API surface and API-key credential"
            )
        end
    end
  end

  defp api_target(api) do
    uri = URI.parse(api.base_url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
       do: :ok,
       else: {:error, :invalid_api_target}
  end

  defp api_key(provider) do
    case api_key_credential(provider) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp api_key_credential(provider) do
    case Repo.get_by(Credential, name: provider.credential) do
      %Credential{kind: kind, metadata: metadata} = credential when kind in ["llm", "service"] ->
        if Map.get(metadata || %{}, "auth_type") in [nil, "api_key"],
          do: {:ok, credential},
          else: {:error, :unsupported_credential}

      _ ->
        {:error, :unsupported_credential}
    end
  end

  defp safe_headers(headers) do
    for {name, value} <- headers,
        key = String.downcase(to_string(name)),
        key not in ~w(authorization x-api-key api-key x-goog-api-key cookie proxy-authorization host content-length content-type connection transfer-encoding upgrade sec-websocket-key sec-websocket-protocol),
        is_binary(value),
        not String.contains?(key <> value, ["\r", "\n"]),
        do: {key, value}
  end
end
