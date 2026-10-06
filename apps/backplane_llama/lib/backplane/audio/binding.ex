defmodule Backplane.Audio.Binding do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.{Provider, ProviderModel}
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_audio_bindings" do
    field :operation, Ecto.Enum, values: [:speech, :transcription]
    field :native_protocol, Ecto.Enum, values: [:minimax]
    field :api_origin, :string
    field :enabled, :boolean, default: false
    field :credential_override, :string
    field :billing_label, Ecto.Enum, values: [:subscription, :payg], default: :payg
    field :capabilities, :map, default: %{}
    belongs_to :provider, Provider, type: :binary_id
    belongs_to :provider_model, ProviderModel, type: :binary_id
    timestamps()
  end

  @required ~w(provider_id provider_model_id operation native_protocol api_origin)a
  @optional ~w(enabled credential_override billing_label capabilities)a
  @capability_keys ~w(native_formats output_formats input_formats languages speed_min speed_max streaming)
  @speech_formats ~w(mp3 opus aac flac wav pcm)
  @allow_loopback Mix.env() in [:dev, :test]
  @input_formats ~w(flac mp3 mp4 mpeg mpga m4a ogg wav webm)

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_origin()
    |> validate_capabilities()
    |> validate_credential()
    |> validate_model_provider()
    |> foreign_key_constraint(:provider_id)
    |> foreign_key_constraint(:provider_model_id, name: :llm_audio_bindings_model_provider_fkey)
    |> unique_constraint([:provider_model_id, :operation])
  end

  def create(attrs) do
    %__MODULE__{} |> changeset(attrs) |> Repo.insert() |> broadcast_on_ok()
  end

  def update(%__MODULE__{} = binding, attrs) do
    binding |> changeset(attrs) |> Repo.update() |> broadcast_on_ok()
  end

  def delete(%__MODULE__{} = binding) do
    binding |> Repo.delete() |> broadcast_on_ok()
  end

  def list do
    __MODULE__ |> preload([:provider, :provider_model]) |> Repo.all()
  end

  def enabled_for_model(provider_model_id, operation)
      when operation in [:speech, :transcription] do
    __MODULE__
    |> where(
      [b],
      b.provider_model_id == ^provider_model_id and b.operation == ^operation and b.enabled
    )
    |> Repo.one()
  end

  defp validate_origin(changeset) do
    validate_change(changeset, :api_origin, fn :api_origin, origin ->
      uri = URI.parse(origin)

      loopback_http? =
        Application.get_env(:backplane_llama, :audio_allow_http_loopback, false) and
          uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
          @allow_loopback

      if (uri.scheme == "https" or loopback_http?) and is_binary(uri.host) and uri.host != "" and
           uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
           uri.path in [nil, "", "/", "/v1", "/v1/"] do
        []
      else
        [
          api_origin:
            "must be an HTTPS origin with optional /v1 prefix and no credentials, query, or fragment"
        ]
      end
    end)
  end

  defp validate_capabilities(changeset) do
    capabilities = get_field(changeset, :capabilities)
    operation = get_field(changeset, :operation)

    if is_map(capabilities) and Enum.all?(Map.keys(capabilities), &(&1 in @capability_keys)) and
         valid_capabilities?(capabilities, operation) do
      changeset
    else
      add_error(changeset, :capabilities, "contains unsupported capability values")
    end
  end

  defp valid_capabilities?(capabilities, :speech) do
    list_subset?(capabilities["native_formats"], ~w(mp3 pcm flac wav opus)) and
      list_subset?(capabilities["output_formats"], @speech_formats) and
      absent?(capabilities["input_formats"]) and absent?(capabilities["languages"]) and
      valid_speed_range?(capabilities) and
      optional_boolean?(capabilities["streaming"])
  end

  defp valid_capabilities?(capabilities, :transcription) do
    list_subset?(capabilities["input_formats"], @input_formats) and
      list_subset?(
        capabilities["languages"],
        ~w(zh yue en ja ko th vi id ms fil ar tr fr de es it pt pl ru uk)
      ) and
      absent?(capabilities["native_formats"]) and absent?(capabilities["output_formats"]) and
      absent?(capabilities["speed_min"]) and absent?(capabilities["speed_max"]) and
      capabilities["streaming"] in [nil, false]
  end

  defp valid_capabilities?(_, _), do: false
  defp list_subset?(nil, _allowed), do: true
  defp list_subset?(value, allowed) when is_list(value), do: Enum.all?(value, &(&1 in allowed))
  defp list_subset?(_, _), do: false
  defp absent?(nil), do: true
  defp absent?(_), do: false

  defp valid_speed_range?(capabilities) do
    minimum = if is_nil(capabilities["speed_min"]), do: 0.5, else: capabilities["speed_min"]
    maximum = if is_nil(capabilities["speed_max"]), do: 2.0, else: capabilities["speed_max"]

    is_number(minimum) and is_number(maximum) and
      minimum >= 0.5 and maximum <= 2.0 and minimum <= maximum
  end

  defp optional_boolean?(nil), do: true
  defp optional_boolean?(value), do: is_boolean(value)

  defp validate_credential(changeset) do
    case get_field(changeset, :credential_override) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :credential_override, nil)

      name ->
        if Credentials.exists?(name),
          do: changeset,
          else: add_error(changeset, :credential_override, "credential not found")
    end
  end

  defp validate_model_provider(changeset) do
    provider_id = get_field(changeset, :provider_id)
    model_id = get_field(changeset, :provider_model_id)

    case {provider_id, model_id} do
      {provider_id, model_id} when is_binary(provider_id) and is_binary(model_id) ->
        case Repo.get(ProviderModel, model_id) do
          %ProviderModel{provider_id: ^provider_id} -> changeset
          _ -> add_error(changeset, :provider_model_id, "does not belong to provider")
        end

      _ ->
        changeset
    end
  end

  defp broadcast_on_ok({:ok, _} = result) do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    result
  end

  defp broadcast_on_ok(result), do: result
end
