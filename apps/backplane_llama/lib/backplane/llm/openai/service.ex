defmodule Backplane.LLM.OpenAI.Service do
  @moduledoc """
  Explicit native OpenAI capabilities, independent of chat-model discovery.

  Each capability references an existing provider and its OpenAI API surface.
  Credentials remain in the vault; models here never enter the chat catalog.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.{CredentialPlug, HeaderPolicy, Provider, ProviderApi}
  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @kinds [:decisions, :images, :embeddings, :speech, :transcription, :realtime]
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "llm_openai_services" do
    field :kind, Ecto.Enum, values: @kinds
    field :enabled, :boolean, default: true
    field :models, {:array, :string}, default: []
    field :model_policy, Ecto.Enum, values: [:passthrough, :allowlist], default: :passthrough
    field :image_generation_enabled, :boolean, default: true
    field :image_edit_enabled, :boolean, default: true
    field :default_model, :string
    field :request_timeout_ms, :integer, default: 120_000
    field :max_request_bytes, :integer, default: 50_000_000
    field :max_response_bytes, :integer, default: 100_000_000
    field :realtime_max_input_bytes, :integer, default: 536_870_912
    field :realtime_max_output_bytes, :integer, default: 536_870_912
    field :max_session_ms, :integer, default: 3_600_000
    belongs_to :provider, Provider, type: :binary_id
    timestamps()
  end

  @fields ~w(provider_id kind enabled models model_policy image_generation_enabled image_edit_enabled default_model request_timeout_ms max_request_bytes max_response_bytes realtime_max_input_bytes realtime_max_output_bytes max_session_ms)a
  def kinds, do: @kinds

  def changeset(service, attrs) do
    service
    |> cast(attrs, @fields)
    |> infer_model_policy(attrs)
    |> update_change(:models, &Enum.uniq/1)
    |> validate_required([
      :provider_id,
      :kind,
      :model_policy,
      :image_generation_enabled,
      :image_edit_enabled,
      :enabled,
      :request_timeout_ms,
      :max_request_bytes,
      :max_response_bytes,
      :max_session_ms
    ])
    |> validate_length(:models, max: 256)
    |> validate_model_policy()
    |> validate_change(:models, fn :models, models ->
      if is_list(models) and
           Enum.all?(
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
    |> validate_realtime_budgets()
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

  def list_for_provider(provider_id) do
    __MODULE__ |> where([service], service.provider_id == ^provider_id) |> Repo.all()
  end

  def eligible_provider?(%Provider{host_service_id: nil} = provider) do
    with %ProviderApi{} = api <-
           Repo.get_by(ProviderApi, provider_id: provider.id, api_surface: :openai),
         :ok <- api_target(api),
         :ok <- api_key(provider) do
      true
    else
      _ -> false
    end
  end

  def eligible_provider?(_provider), do: false

  def get(id), do: __MODULE__ |> preload(:provider) |> Repo.get(id)
  def create(attrs), do: %__MODULE__{} |> changeset(attrs) |> Repo.insert()
  def update(service, attrs), do: service |> changeset(attrs) |> Repo.update()
  def delete(service), do: Repo.delete(service)

  def enabled?(kind), do: Enum.any?(list(kind), & &1.enabled)

  @doc "Lists explicitly configured, locally eligible Realtime model IDs."
  def realtime_models do
    for service <- list(:realtime),
        service.enabled,
        match?({:ok, _}, eligible_api(service.provider)),
        model <- configured_models(service),
        id = "#{service.provider.name}/#{model}",
        byte_size(id) <= 1024 do
      %{"id" => id, "object" => "model", "owned_by" => service.provider.name}
    end
    |> Enum.sort_by(& &1["id"])
  end

  def resolve(kind, model, operation \\ nil)

  def resolve(kind, model, operation)
      when kind in @kinds and (is_binary(model) or is_nil(model)) do
    do_resolve(kind, model, operation, :all)
  end

  def resolve(_, _, _), do: {:error, :invalid_model}

  @doc """
  Resolves only explicit native matches (configured default for omitted model,
  provider-qualified native service, or allowlisted model), excluding generic
  `:passthrough` matching for bare/unqualified model names.
  """
  def resolve_explicit(kind, model, operation \\ nil)

  def resolve_explicit(kind, model, operation)
      when kind in @kinds and (is_binary(model) or is_nil(model)) do
    do_resolve(kind, model, operation, :explicit_only)
  end

  def resolve_explicit(_, _, _), do: {:error, :invalid_model}

  defp do_resolve(kind, model, operation, mode) do
    requested_provider = requested_provider(model)

    matches =
      kind
      |> list()
      |> Enum.filter(fn service ->
        service.enabled and operation_enabled?(service, operation) and
          (is_nil(requested_provider) or service.provider.name == requested_provider) and
          explicit_mode_allowed?(service, model, requested_provider, mode)
      end)
      |> Enum.flat_map(fn service ->
        provider = service.provider

        with {:ok, raw} <- matching_model(service, provider, model),
             {:ok, api} <- eligible_api(provider) do
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

  defp explicit_mode_allowed?(_service, _model, _requested_provider, :all), do: true
  defp explicit_mode_allowed?(_service, nil, _requested_provider, :explicit_only), do: true

  defp explicit_mode_allowed?(_service, _model, requested_provider, :explicit_only)
       when is_binary(requested_provider),
       do: true

  defp explicit_mode_allowed?(%{model_policy: :allowlist}, _model, nil, :explicit_only), do: true
  defp explicit_mode_allowed?(_service, _model, nil, :explicit_only), do: false

  defp configured_models(%{model_policy: :allowlist, models: models}), do: models
  defp configured_models(%{default_model: model}), do: List.wrap(model)

  defp eligible_api(%Provider{enabled: true, deleted_at: nil, host_service_id: nil} = provider) do
    with %ProviderApi{enabled: true} = api <-
           Repo.get_by(ProviderApi, provider_id: provider.id, api_surface: :openai),
         :ok <- api_target(api),
         :ok <- api_key(provider) do
      {:ok, api}
    else
      _ -> :error
    end
  end

  defp eligible_api(_provider), do: :error

  def auth_headers(%{provider: provider, api: api}) do
    with {:ok, credential} <- api_key_credential(provider),
         {:ok, headers} <-
           CredentialPlug.build_responses_auth_headers(
             %{provider | default_headers: %{}},
             credential
           ) do
      defaults =
        HeaderPolicy.merge_defaults(
          provider.default_headers,
          api.default_headers,
          surface: :openai_native
        )

      {:ok, HeaderPolicy.merge_ordered([defaults, headers], keep_nil: true)}
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

    if raw != "" and (service.model_policy == :passthrough or raw in service.models),
      do: {:ok, raw},
      else: {:error, :unknown_model}
  end

  defp validate_default(changeset) do
    default = get_field(changeset, :default_model)

    if is_nil(default) or get_field(changeset, :model_policy) == :passthrough or
         default in (get_field(changeset, :models) || []),
       do: changeset,
       else: add_error(changeset, :default_model, "must be one of the configured models")
  end

  defp requested_provider(nil), do: nil

  defp requested_provider(model) do
    Provider
    |> select([provider], provider.name)
    |> Repo.all()
    |> Enum.find(&String.starts_with?(model, &1 <> "/"))
  end

  defp operation_enabled?(%{kind: :images} = service, :image_generation),
    do: service.image_generation_enabled

  defp operation_enabled?(%{kind: :images} = service, :image_edit),
    do: service.image_edit_enabled

  defp operation_enabled?(_service, nil), do: true
  defp operation_enabled?(_service, _operation), do: false

  defp infer_model_policy(%{data: %{id: nil}} = changeset, attrs) do
    if not Map.has_key?(attrs, :model_policy) and not Map.has_key?(attrs, "model_policy") and
         get_field(changeset, :models) not in [nil, []],
       do: put_change(changeset, :model_policy, :allowlist),
       else: changeset
  end

  defp infer_model_policy(changeset, _attrs), do: changeset

  defp validate_model_policy(changeset) do
    if get_field(changeset, :model_policy) == :allowlist,
      do: validate_length(changeset, :models, min: 1),
      else: changeset
  end

  defp validate_realtime_budgets(changeset) do
    if get_field(changeset, :kind) == :realtime do
      changeset
      |> validate_required([:realtime_max_input_bytes, :realtime_max_output_bytes])
      |> validate_number(:realtime_max_input_bytes,
        greater_than: 0,
        less_than_or_equal_to: 2_147_483_647
      )
      |> validate_number(:realtime_max_output_bytes,
        greater_than: 0,
        less_than_or_equal_to: 2_147_483_647
      )
      |> check_constraint(:realtime_max_input_bytes,
        name: :llm_openai_services_realtime_input_budget_check
      )
      |> check_constraint(:realtime_max_output_bytes,
        name: :llm_openai_services_realtime_output_budget_check
      )
    else
      changeset
    end
  end

  defp validate_provider(changeset) do
    if get_field(changeset, :enabled), do: validate_enabled_provider(changeset), else: changeset
  end

  defp validate_enabled_provider(changeset) do
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
end
