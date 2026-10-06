defmodule Backplane.Audio.Resolver do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Audio.{Binding, Config, Error}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderModel, ProviderModelSurface}
  alias Backplane.Repo

  @operations [:speech, :transcription]

  def resolve(operation, public_model)
      when operation in @operations and is_binary(public_model) do
    if Config.enabled?() do
      resolve_name(operation, public_model, [])
    else
      {:error,
       Error.new(503, "Audio is disabled", "model", "audio_disabled", "service_unavailable_error")}
    end
  end

  def resolve(_, _),
    do: {:error, Error.new(400, "Invalid audio operation or model", "model", "invalid_parameter")}

  @spec available_models(:speech | :transcription) :: [String.t()]
  def available_models(operation) when operation in @operations do
    provider_aliases = MapSet.new(ModelAlias.provider_names())

    names =
      Binding.list()
      |> Enum.filter(fn binding ->
        binding.operation == operation and binding.enabled and binding.provider.enabled and
          is_nil(binding.provider.deleted_at) and binding.provider_model.enabled
      end)
      |> Enum.flat_map(fn binding ->
        qualified = "#{binding.provider.name}/#{binding.provider_model.model}"

        if MapSet.member?(provider_aliases, binding.provider.name),
          do: [qualified, binding.provider_model.model],
          else: [qualified]
      end)

    (names ++ Enum.map(ModelAlias.list(), & &1.alias))
    |> Enum.uniq()
    |> Enum.filter(&match?({:ok, _}, resolve_name(operation, &1, [])))
    |> Enum.sort()
  end

  def resolve_voice(%{provider: %Provider{name: name}}, public_voice)
      when is_binary(public_voice) do
    policy = Config.voices()[name] || %{}
    aliases = policy["aliases"] || %{}

    cond do
      is_binary(aliases[public_voice]) -> {:ok, aliases[public_voice]}
      policy["allow_native"] == true -> {:ok, public_voice}
      true -> {:error, Error.new(400, "Unknown voice", "voice", "unknown_voice")}
    end
  end

  def validate_request(%{binding: %{operation: :speech}, capabilities: caps}, request) do
    minimum = caps["speed_min"] || 0.5
    maximum = caps["speed_max"] || 2.0

    cond do
      request.speed < minimum or request.speed > maximum ->
        {:error,
         Error.new(400, "speed is unsupported by this model", "speed", "unsupported_parameter")}

      request.response_format not in (caps["output_formats"] || ~w(mp3 opus aac flac wav pcm)) ->
        {:error,
         Error.new(
           400,
           "response_format is unsupported by this model",
           "response_format",
           "unsupported_parameter"
         )}

      true ->
        :ok
    end
  end

  def validate_request(%{binding: %{operation: :transcription}, capabilities: caps}, request) do
    languages =
      caps["languages"] || ~w(zh yue en ja ko th vi id ms fil ar tr fr de es it pt pl ru uk)

    if is_nil(request.language) or request.language in languages,
      do: :ok,
      else:
        {:error,
         Error.new(
           400,
           "language is unsupported by this model",
           "language",
           "unsupported_parameter"
         )}
  end

  defp resolve_name(operation, name, seen) do
    if Enum.member?(seen, name) do
      {:error, Error.new(400, "Model alias loop", "model", "alias_loop")}
    else
      seen = [name | seen]

      case String.split(name, "/", parts: 2) do
        [provider_name, model] -> resolve_prefixed(operation, provider_name, model)
        [_] -> resolve_alias(operation, name, seen)
      end
    end
  end

  defp resolve_alias(operation, name, seen) do
    case ModelAlias.target_for(name) do
      target when is_binary(target) ->
        case Ecto.UUID.cast(target) do
          {:ok, id} -> resolve_model_id(operation, id)
          :error -> resolve_name(operation, target, seen)
        end

      nil ->
        results = Enum.map(ModelAlias.provider_names(), &resolve_prefixed(operation, &1, name))

        Enum.find(results, &match?({:ok, _}, &1)) ||
          Enum.find(results, &match?({:error, %{status: 400}}, &1)) || not_found()
    end
  end

  defp resolve_model_id(operation, id) do
    case Repo.get(ProviderModel, id) do
      %ProviderModel{} = model -> resolve_model(operation, model)
      nil -> not_found()
    end
  end

  defp resolve_prefixed(operation, provider_name, model_name) when model_name != "" do
    model =
      ProviderModel
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.name == ^provider_name and m.model == ^model_name)
      |> Repo.one()

    if model, do: resolve_model(operation, model), else: not_found()
  end

  defp resolve_prefixed(_, _, _), do: not_found()

  defp resolve_model(operation, model) do
    provider = Repo.get(Provider, model.provider_id)

    cond do
      is_nil(provider) or not provider.enabled or not is_nil(provider.deleted_at) or
          not model.enabled ->
        not_found()

      binding = Binding.enabled_for_model(model.id, operation) ->
        credential_ref = binding.credential_override || provider.credential

        {:ok,
         %{
           provider: provider,
           provider_model: model,
           binding: binding,
           model: model.model,
           credential_ref: credential_ref,
           api_origin: binding.api_origin,
           capabilities: binding.capabilities || %{}
         }}

      Repo.exists?(
        from b in Binding, where: b.provider_model_id == ^model.id and b.operation == ^operation
      ) ->
        not_found()

      Repo.exists?(from b in Binding, where: b.provider_model_id == ^model.id and b.enabled) ->
        {:error,
         Error.new(
           400,
           "Model does not support this audio operation",
           "model",
           "operation_mismatch"
         )}

      Repo.exists?(
        from s in ProviderModelSurface, where: s.provider_model_id == ^model.id and s.enabled
      ) ->
        {:error, Error.new(400, "Model does not support audio", "model", "operation_mismatch")}

      true ->
        not_found()
    end
  end

  defp not_found, do: {:error, Error.new(404, "Model not found", "model", "model_not_found")}
end
