defmodule Backplane.Audio.PresetSetup do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Audio.Binding
  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel}
  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Credential

  @provider_name "minimax-audio"
  @regions %{"global" => "https://api.minimax.io", "china" => "https://api.minimaxi.com"}
  @models [{"speech-2.8-turbo", :speech}, {"asr-1.0", :transcription}]
  @voices_key "llm.audio.voices"

  def provider_name, do: @provider_name
  def regions, do: @regions
  def model_name(:speech), do: "#{@provider_name}/speech-2.8-turbo"
  def model_name(:transcription), do: "#{@provider_name}/asr-1.0"

  def current do
    case Repo.get_by(Provider, name: @provider_name) do
      %Provider{preset_key: @provider_name, deleted_at: nil} = provider ->
        bindings =
          Binding
          |> where([b], b.provider_id == ^provider.id)
          |> Repo.all()

        region =
          case Enum.uniq(Enum.map(bindings, & &1.api_origin)) do
            [origin] ->
              Enum.find_value(@regions, fn {name, value} -> if value == origin, do: name end)

            _ ->
              nil
          end

        billing_label =
          case Enum.uniq(Enum.map(bindings, & &1.billing_label)) do
            [label] -> Atom.to_string(label)
            _ -> "payg"
          end

        %{
          credential: provider.credential,
          region: region,
          billing_label: billing_label,
          configured?: length(bindings) == 2
        }

      _ ->
        %{credential: nil, region: nil, billing_label: "payg", configured?: false}
    end
  end

  def save(credential_name, region, billing_label \\ "payg") do
    with :ok <- validate_input(credential_name, region, billing_label),
         {:ok, result} <-
           Repo.transaction(fn -> provision!(credential_name, region, billing_label) end) do
      case ensure_voice_policy() do
        :ok -> {:ok, result}
        {:error, reason} -> {:error, {:voice_policy_not_saved, reason}}
      end
    end
  end

  defp validate_input(credential_name, region, billing_label) do
    credential =
      if is_binary(credential_name), do: Repo.get_by(Credential, name: credential_name)

    cond do
      is_nil(credential) or credential.kind not in ["llm", "service"] or
          (credential.metadata || %{})["auth_type"] not in [nil, "api_key"] ->
        {:error, :ineligible_credential}

      not Map.has_key?(@regions, region) ->
        {:error, :invalid_region}

      billing_label not in ["payg", "subscription"] ->
        {:error, :invalid_billing_label}

      true ->
        :ok
    end
  end

  defp provision!(credential_name, region, billing_label) do
    provider = ensure_provider!(credential_name)
    assert_owned_routes!(provider)

    bindings =
      Enum.map(@models, fn {name, operation} ->
        model = ensure_model!(provider, name)
        ensure_binding!(provider, model, operation, @regions[region], billing_label)
      end)

    %{provider: provider, bindings: bindings}
  end

  defp ensure_provider!(credential_name) do
    case Repo.get_by(Provider, name: @provider_name) do
      nil ->
        %Provider{}
        |> Provider.changeset(%{
          name: @provider_name,
          preset_key: @provider_name,
          credential: credential_name
        })
        |> insert!()

      %Provider{preset_key: @provider_name, deleted_at: nil, enabled: true} = provider ->
        if provider.default_headers != %{} or not is_nil(provider.rpm_limit) or
             Repo.exists?(from a in ProviderApi, where: a.provider_id == ^provider.id) do
          Repo.rollback(:provider_conflict)
        end

        provider
        |> Provider.update_changeset(%{credential: credential_name})
        |> update!()

      _ ->
        Repo.rollback(:provider_conflict)
    end
  end

  defp assert_owned_routes!(provider) do
    names = Enum.map(@models, &elem(&1, 0))
    models = ProviderModel.list_for_provider(provider.id)

    if Enum.any?(
         models,
         &(&1.model not in names or &1.source != :manual or
             not &1.enabled or &1.metadata != %{} or &1.surfaces != [])
       ) do
      Repo.rollback(:route_conflict)
    end

    model_ids = Enum.map(models, & &1.id)

    bindings =
      Binding
      |> where([b], b.provider_id == ^provider.id)
      |> Repo.all()

    if Enum.any?(bindings, fn binding ->
         binding.provider_model_id not in model_ids or
           binding.operation != operation_for(models, binding.provider_model_id) or
           binding.native_protocol != :minimax or not binding.enabled or
           not is_nil(binding.credential_override) or binding.capabilities != %{} or
           binding.api_origin not in Map.values(@regions)
       end) or
         length(Enum.uniq(Enum.map(bindings, & &1.api_origin))) > 1 or
         length(Enum.uniq(Enum.map(bindings, & &1.billing_label))) > 1 do
      Repo.rollback(:route_conflict)
    end
  end

  defp operation_for(models, model_id) do
    case Enum.find(models, &(&1.id == model_id)) do
      nil ->
        nil

      model ->
        Enum.find_value(@models, fn {name, operation} -> if name == model.model, do: operation end)
    end
  end

  defp ensure_model!(provider, name) do
    case Repo.get_by(ProviderModel, provider_id: provider.id, model: name) do
      nil ->
        %ProviderModel{}
        |> ProviderModel.changeset(%{provider_id: provider.id, model: name, source: :manual})
        |> insert!()

      model ->
        model
    end
  end

  defp ensure_binding!(provider, model, operation, origin, billing_label) do
    attrs = %{
      provider_id: provider.id,
      provider_model_id: model.id,
      operation: operation,
      native_protocol: :minimax,
      api_origin: origin,
      enabled: true,
      billing_label: billing_label,
      capabilities: %{}
    }

    case Repo.get_by(Binding, provider_model_id: model.id, operation: operation) do
      nil -> %Binding{} |> Binding.changeset(attrs) |> insert!()
      binding -> binding |> Binding.changeset(attrs) |> update!()
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, _} -> Repo.rollback(:route_conflict)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, _} -> Repo.rollback(:route_conflict)
    end
  end

  defp ensure_voice_policy do
    case Settings.get(@voices_key) do
      nil ->
        Settings.set_if(@voices_key, %{@provider_name => voice_policy()}, [{@voices_key, nil}])

      voices when is_map(voices) ->
        if Map.has_key?(voices, @provider_name) do
          :ok
        else
          Settings.set_if(@voices_key, Map.put(voices, @provider_name, voice_policy()), [
            {@voices_key, voices}
          ])
        end

      _ ->
        {:error, :invalid_existing_voice_policy}
    end
  end

  defp voice_policy, do: %{"aliases" => %{}, "allow_native" => true}
end
