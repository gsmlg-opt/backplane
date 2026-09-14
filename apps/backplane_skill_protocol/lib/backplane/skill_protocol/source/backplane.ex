defmodule Backplane.SkillProtocol.Source.Backplane do
  @moduledoc "Thin remote source adapter for one-shot verified Skill preparation."

  alias Backplane.SkillProtocol.{Bundle, Client, Error, SkillRef, Telemetry, Wire}

  @enforce_keys [:client]
  defstruct [:client]

  @type t :: %__MODULE__{}

  @spec new(Client.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Client{} = client), do: {:ok, %__MODULE__{client: client}}

  def new(_client), do: error(:invalid_request, "client is invalid")

  @spec new!(Client.t()) :: t()
  def new!(client) do
    case new(client) do
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

    result = one_shot_prepare(source, skill_id, revision, opts)

    Telemetry.emit(:source, :prepare, result, started_at,
      metadata: prepare_metadata(source, result, skill_id, revision)
    )
  end

  defp one_shot_prepare(source, skill_id, revision, opts) do
    effective_opts = Keyword.put(opts, :cancelled?, cancellation(opts, source.client))

    with {:ok, destination} <- destination(effective_opts),
         :ok <- cancelled(effective_opts),
         {:ok, manifest} <- Client.resolve(source.client, skill_id, revision, effective_opts),
         :ok <- exact_manifest(source.client, manifest),
         :ok <- cancelled(effective_opts),
         {:ok, bytes} <- Client.artifact(source.client, manifest.ref, effective_opts),
         :ok <- cancelled(effective_opts),
         {:ok, {archive, archive_dir}} <- stage_archive(bytes) do
      try do
        with {:ok, bundle} <- Bundle.inspect(archive, Keyword.put(effective_opts, :ref, manifest.ref)),
             :ok <- same_manifest(bundle.manifest, manifest),
             do: Bundle.prepare(bundle, destination, effective_opts)
      after
        File.rm_rf(archive_dir)
      end
    end
  end

  defp destination(opts) do
    case Keyword.fetch(opts, :destination) do
      {:ok, destination} when is_binary(destination) and byte_size(destination) > 0 ->
        expanded = Path.expand(destination)

        cond do
          path_exists?(expanded) ->
            error(:invalid_request, "prepared destination already exists")

          not File.dir?(Path.dirname(expanded)) ->
            error(:invalid_request, "prepared destination parent must exist")

          true ->
            {:ok, expanded}
        end

      _ ->
        error(:invalid_request, "prepared destination is required")
    end
  end

  defp path_exists?(path), do: match?({:ok, _stat}, File.lstat(path))

  defp stage_archive(bytes) do
    with {:ok, dir} <- temporary_directory(),
         path = Path.join(dir, "artifact.tar.gz") do
      case File.write(path, bytes, [:binary, :exclusive]) do
        :ok -> {:ok, {path, dir}}
        {:error, reason} ->
          File.rm_rf(dir)
          error(:invalid_bundle, "artifact staging failed", %{reason: inspect(reason)})
      end
    else
      {:error, %Error{} = reason} -> {:error, reason}
      {:error, reason} -> error(:invalid_bundle, "artifact staging failed", %{reason: inspect(reason)})
    end
  end

  defp temporary_directory do
    Enum.reduce_while(1..5, {:error, :collision}, fn _, _acc ->
      path = Path.join(System.tmp_dir!(), "backplane-skill-protocol-source." <> random_suffix())

      case File.mkdir(path) do
        :ok -> {:halt, {:ok, path}}
        {:error, :eexist} -> {:cont, {:error, :collision}}
        {:error, reason} -> {:halt, error(:invalid_bundle, "temporary storage cannot be allocated", %{reason: inspect(reason)})}
      end
    end)
  end

  defp random_suffix, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  defp cancellation(opts, client) do
    per_call = Keyword.get(opts, :cancelled?, fn -> false end)
    fn -> per_call.() or client.cancelled?.() end
  end

  defp cancelled(opts) do
    if Keyword.get(opts, :cancelled?, fn -> false end).(), do: error(:cancelled, "preparation was cancelled"), else: :ok
  end

  defp exact_manifest(client, %{ref: %SkillRef{} = ref} = manifest) do
    cond do
      ref.source_id != client.source_id ->
        error(:integrity_mismatch, "manifest source does not match client")

      not is_binary(ref.skill_id) or not is_binary(ref.revision) ->
        error(:invalid_request, "manifest is not exact")

      ref.artifact_digest != manifest.artifact_digest ->
        error(:integrity_mismatch, "manifest digest association is invalid")

      true ->
        :ok
    end
  end

  defp exact_manifest(_client, _manifest), do: error(:invalid_request, "manifest is not exact")

  defp same_manifest(left, right) do
    if Wire.manifest_map(left) == Wire.manifest_map(right),
      do: :ok,
      else: error(:integrity_mismatch, "artifact contents do not match resolved manifest")
  end

  defp prepare_metadata(source, {:ok, %{manifest: %{ref: ref}}}, _skill_id, _revision) do
    %{
      source_id: source.client.source_id,
      skill_id: ref.skill_id,
      revision: ref.revision,
      artifact_digest: ref.artifact_digest
    }
  end

  defp prepare_metadata(source, _result, skill_id, revision) do
    %{
      source_id: source.client.source_id,
      skill_id: skill_id,
      revision: revision
    }
  end

  defp error(code, message, context \\ %{}),
    do: {:error, Error.new(code, :source, message, context: context)}
end
