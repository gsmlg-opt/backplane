defmodule Backplane.SkillProtocol.Source.Backplane do
  @moduledoc "Thin remote source adapter combining the v1 client with exact verified caching."

  alias Backplane.SkillProtocol.{Cache, Client, Error, Telemetry}

  @enforce_keys [:client, :cache, :offline_policy]
  defstruct [:client, :cache, :offline_policy]

  @type t :: %__MODULE__{}

  @spec new(Client.t(), Cache.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Client{} = client, %Cache{} = cache, opts \\ []) do
    policy = Keyword.get(opts, :offline_policy, :disabled)

    if policy == :disabled or
         match?({:age_bounded, age} when is_integer(age) and age >= 0, policy) do
      {:ok, %__MODULE__{client: client, cache: cache, offline_policy: policy}}
    else
      {:error, Error.new(:invalid_request, :source, "offline policy is invalid")}
    end
  end

  @spec new!(Client.t(), Cache.t(), keyword()) :: t()
  def new!(client, cache, opts \\ []) do
    case new(client, cache, opts) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, reason.message
    end
  end

  def catalog(%__MODULE__{client: client}, opts \\ []), do: Client.catalog(client, opts)

  def resolve(%__MODULE__{client: client}, skill_id, revision \\ nil, opts \\ []),
    do: Client.resolve(client, skill_id, revision, opts)

  @spec prepare(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Backplane.SkillProtocol.PreparedSkill.t()} | {:error, Error.t()}
  def prepare(%__MODULE__{} = source, skill_id, revision \\ nil, opts \\ []) do
    started_at = Telemetry.start()

    {result, cache_outcome} =
      case online_prepare(source, skill_id, revision, opts) do
        {:ok, prepared} ->
          {{:ok, prepared}, :online}

        {:error, %Error{} = reason} ->
          record_terminal(source, skill_id, revision, reason)
          result = maybe_offline(source, skill_id, revision, reason)
          outcome = if match?({:ok, _prepared}, result), do: :offline_hit, else: :error
          {result, outcome}
      end

    Telemetry.emit(:source, :prepare, result, started_at,
      metadata: prepare_metadata(source, result, skill_id, revision, cache_outcome)
    )
  end

  defp online_prepare(source, skill_id, revision, opts) do
    with {:ok, manifest} <- Client.resolve(source.client, skill_id, revision, opts),
         {:ok, bytes} <- Client.artifact(source.client, manifest.ref),
         do: Cache.install(source.cache, source.client, manifest, bytes)
  end

  defp maybe_offline(
         %__MODULE__{offline_policy: {:age_bounded, max_age}} = source,
         skill_id,
         revision,
         %Error{retryable: true} = online_error
       )
       when is_binary(revision) do
    case Cache.offline(source.cache, source.client, skill_id, revision, max_age) do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, %Error{code: code} = blocked}
      when code in [:unauthorized, :forbidden, :revision_unavailable, :integrity_mismatch] ->
        {:error, blocked}

      {:error, _reason} ->
        {:error, online_error}
    end
  end

  defp maybe_offline(_source, _skill_id, _revision, online_error), do: {:error, online_error}

  defp record_terminal(source, skill_id, revision, %Error{code: code})
       when is_binary(revision) and
              code in [
                :unauthorized,
                :forbidden,
                :not_found,
                :revision_unavailable,
                :integrity_mismatch
              ] do
    Cache.record_block(source.cache, source.client, skill_id, revision, code)
  end

  defp record_terminal(_source, _skill_id, _revision, _reason), do: :ok

  defp prepare_metadata(source, {:ok, %{manifest: %{ref: ref}}}, _skill_id, _revision, outcome) do
    %{
      source_id: source.client.source_id,
      skill_id: ref.skill_id,
      revision: ref.revision,
      artifact_digest: ref.artifact_digest,
      cache_outcome: outcome
    }
  end

  defp prepare_metadata(source, _result, skill_id, revision, outcome) do
    %{
      source_id: source.client.source_id,
      skill_id: skill_id,
      revision: revision,
      cache_outcome: outcome
    }
  end
end
