defmodule Backplane.SkillProtocol.Wire do
  @moduledoc "Strict JSON encoding and decoding for Skill Protocol v1."

  alias Backplane.SkillProtocol.{BundleManifest, Descriptor, Error, SkillRef}

  @protocol_version "1"
  @bundle_profile "backplane.skill-bundle.v1"
  @digest ~r/^sha256:[a-f0-9]{64}$/
  @file_digest ~r/^[a-f0-9]{64}$/

  @error_codes %{
    "invalid_request" => :invalid_request,
    "invalid_document" => :invalid_document,
    "invalid_bundle" => :invalid_bundle,
    "ambiguous_skill" => :ambiguous_skill,
    "not_found" => :not_found,
    "revision_unavailable" => :revision_unavailable,
    "unauthorized" => :unauthorized,
    "forbidden" => :forbidden,
    "unsupported_protocol" => :unsupported_protocol,
    "unsupported_capability" => :unsupported_capability,
    "integrity_mismatch" => :integrity_mismatch,
    "limit_exceeded" => :limit_exceeded,
    "capacity_exceeded" => :capacity_exceeded,
    "timeout" => :timeout,
    "cancelled" => :cancelled,
    "temporarily_unavailable" => :temporarily_unavailable
  }

  @catalog_keys ~w(protocol_version data next_cursor)
  @descriptor_keys ~w(skill_id name description revision artifact_digest publication_status)
  @descriptor_extended_keys ["argument_hint" | @descriptor_keys]
  @manifest_keys ~w(protocol_version profile skill_id revision root entrypoint document_metadata artifact_format artifact_digest compressed_bytes unpacked_bytes files required_capabilities)
  @file_keys ~w(path bytes sha256)
  @error_envelope_keys ~w(protocol_version error)
  @error_keys ~w(code message retryable context)

  @spec decode_catalog(binary(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def decode_catalog(bytes, source_id) when is_binary(bytes) and is_binary(source_id) do
    with {:ok, value} <- decode_json(bytes),
         :ok <- exact_keys(value, @catalog_keys),
         %{"protocol_version" => @protocol_version, "data" => data, "next_cursor" => cursor} <-
           value,
         true <- is_list(data) and (is_binary(cursor) or is_nil(cursor)),
         {:ok, descriptors} <- decode_descriptors(data, source_id) do
      {:ok, %{data: descriptors, next_cursor: cursor}}
    else
      %{"protocol_version" => _} -> error(:unsupported_protocol, "unsupported protocol version")
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> malformed("catalog response is malformed")
    end
  end

  @spec decode_manifest(binary(), String.t(), keyword()) ::
          {:ok, BundleManifest.t()} | {:error, Error.t()}
  def decode_manifest(bytes, source_id, opts \\ []) do
    with {:ok, value} <- decode_json(bytes), do: decode_manifest_map(value, source_id, opts)
  end

  @spec decode_manifest_map(map(), String.t(), keyword()) ::
          {:ok, BundleManifest.t()} | {:error, Error.t()}
  def decode_manifest_map(value, source_id, opts \\ [])

  def decode_manifest_map(value, source_id, opts) when is_map(value) do
    with :ok <- exact_keys(value, @manifest_keys),
         %{
           "protocol_version" => @protocol_version,
           "profile" => @bundle_profile,
           "skill_id" => skill_id,
           "revision" => revision,
           "root" => root,
           "entrypoint" => "SKILL.md",
           "document_metadata" => metadata,
           "artifact_format" => "tar+gzip",
           "artifact_digest" => digest,
           "compressed_bytes" => compressed,
           "unpacked_bytes" => unpacked,
           "files" => files,
           "required_capabilities" => capabilities
         } <- value,
         :ok <- nonempty(skill_id),
         :ok <- nonempty(revision),
         :ok <- nonempty(root),
         true <- is_map(metadata),
         true <- is_binary(digest) and Regex.match?(@digest, digest),
         true <- is_integer(compressed) and compressed >= 0,
         true <- is_integer(unpacked) and unpacked >= 0,
         {:ok, inventory} <- decode_files(files),
         true <- is_list(capabilities) and Enum.all?(capabilities, &is_binary/1),
         :ok <- expected(skill_id, opts[:skill_id], :skill_id),
         :ok <- expected(revision, opts[:revision], :revision),
         :ok <- supported(capabilities, opts[:supported_capabilities] || []) do
      ref = %SkillRef{
        source_id: source_id,
        skill_id: skill_id,
        revision: revision,
        artifact_digest: digest
      }

      {:ok,
       %BundleManifest{
         protocol_version: @protocol_version,
         profile: @bundle_profile,
         ref: ref,
         root: root,
         entrypoint: "SKILL.md",
         document_metadata: metadata,
         artifact_format: "tar+gzip",
         artifact_digest: digest,
         compressed_bytes: compressed,
         unpacked_bytes: unpacked,
         files: inventory,
         required_capabilities: capabilities
       }}
    else
      %{"protocol_version" => version} when version != @protocol_version ->
        error(:unsupported_protocol, "unsupported protocol version")

      %{"profile" => profile} when profile != @bundle_profile ->
        error(:unsupported_protocol, "unsupported bundle profile")

      {:error, %Error{} = reason} ->
        {:error, reason}

      _ ->
        malformed("manifest response is malformed")
    end
  end

  def decode_manifest_map(_value, _source_id, _opts),
    do: malformed("manifest response is malformed")

  @spec decode_error(binary(), atom()) :: {:ok, Error.t()} | {:error, Error.t()}
  def decode_error(bytes, phase \\ :transport) do
    with {:ok, value} <- decode_json(bytes),
         :ok <- exact_keys(value, @error_envelope_keys),
         %{"protocol_version" => @protocol_version, "error" => error_value} <- value,
         :ok <- exact_keys(error_value, @error_keys),
         %{"code" => code, "message" => message, "retryable" => retryable} <- error_value,
         {:ok, code_atom} <- Map.fetch(@error_codes, code),
         true <- is_binary(message) and is_boolean(retryable),
         context when is_map(context) <- Map.get(error_value, "context", %{}) do
      {:ok,
       Error.new(code_atom, phase, message,
         retryable: retryable,
         context: bounded_context(context)
       )}
    else
      %{"protocol_version" => _} -> error(:unsupported_protocol, "unsupported protocol version")
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> malformed("error response is malformed")
    end
  end

  @spec manifest_map(BundleManifest.t()) :: map()
  def manifest_map(%BundleManifest{} = manifest) do
    %{
      "protocol_version" => manifest.protocol_version,
      "profile" => manifest.profile,
      "skill_id" => manifest.ref.skill_id,
      "revision" => manifest.ref.revision,
      "root" => manifest.root,
      "entrypoint" => manifest.entrypoint,
      "document_metadata" => manifest.document_metadata,
      "artifact_format" => manifest.artifact_format,
      "artifact_digest" => manifest.artifact_digest,
      "compressed_bytes" => manifest.compressed_bytes,
      "unpacked_bytes" => manifest.unpacked_bytes,
      "files" => Enum.map(manifest.files, &stringify_file/1),
      "required_capabilities" => manifest.required_capabilities
    }
  end

  defp decode_descriptors(values, source_id) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decode_descriptor(value, source_id) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      error -> error
    end
  end

  defp decode_descriptor(value, source_id) do
    with :ok <- descriptor_keys(value),
         %{
           "skill_id" => skill_id,
           "name" => name,
           "publication_status" => status
         } <- value,
         :ok <- nonempty(skill_id),
         :ok <- nonempty(name),
         true <- status in ~w(ready invalid pending withdrawn),
         description <- Map.get(value, "description"),
         argument_hint <- Map.get(value, "argument_hint"),
         revision <- Map.get(value, "revision"),
         digest <- Map.get(value, "artifact_digest"),
         true <- is_nil(description) or is_binary(description),
         true <- is_nil(argument_hint) or is_binary(argument_hint),
         true <- is_nil(revision) or is_binary(revision),
         true <- is_nil(digest) or (is_binary(digest) and Regex.match?(@digest, digest)) do
      ref = %SkillRef{
        source_id: source_id,
        skill_id: skill_id,
        revision: revision,
        artifact_digest: digest
      }

      {:ok,
       %Descriptor{
         ref: ref,
         name: name,
         description: description,
         argument_hint: argument_hint,
         path: nil,
         revision: revision,
         artifact_digest: digest,
         publication_status: status,
         precedence: 0
       }}
    else
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> malformed("catalog descriptor is malformed")
    end
  end

  defp decode_files(files) when is_list(files) do
    Enum.reduce_while(files, {:ok, [], MapSet.new()}, fn value, {:ok, acc, paths} ->
      with :ok <- exact_keys(value, @file_keys),
           %{"path" => path, "bytes" => bytes, "sha256" => digest} <- value,
           :ok <- nonempty(path),
           true <- is_integer(bytes) and bytes >= 0,
           true <- is_binary(digest) and Regex.match?(@file_digest, digest),
           false <- MapSet.member?(paths, path) do
        {:cont,
         {:ok, [%{path: path, bytes: bytes, sha256: digest} | acc], MapSet.put(paths, path)}}
      else
        {:error, %Error{} = reason} -> {:halt, {:error, reason}}
        _ -> {:halt, malformed("manifest file inventory is malformed")}
      end
    end)
    |> case do
      {:ok, inventory, _paths} -> {:ok, Enum.reverse(inventory)}
      error -> error
    end
  end

  defp decode_files(_), do: malformed("manifest file inventory is malformed")

  defp decode_json(bytes) do
    case JSON.decode(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> malformed("response is not a JSON object")
    end
  end

  defp exact_keys(value, allowed) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(allowed) or
         (allowed == @descriptor_keys and Enum.all?(Map.keys(value), &(&1 in allowed))) or
         (allowed == @error_keys and Enum.all?(Map.keys(value), &(&1 in allowed)) and
            Enum.all?(~w(code message retryable), &Map.has_key?(value, &1))) do
      :ok
    else
      malformed("response object has missing or unknown fields")
    end
  end

  defp exact_keys(_value, _allowed), do: malformed("response value is not an object")

  defp descriptor_keys(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &(&1 in @descriptor_extended_keys)),
      do: :ok,
      else: malformed("response object has missing or unknown fields")
  end

  defp descriptor_keys(_value), do: malformed("response value is not an object")

  defp expected(_actual, nil, _field), do: :ok
  defp expected(value, value, _field), do: :ok

  defp expected(actual, expected, field),
    do:
      error(:integrity_mismatch, "manifest reference does not match request", %{
        field: field,
        expected: expected,
        actual: actual
      })

  defp supported(required, available) do
    case required -- available do
      [] ->
        :ok

      missing ->
        error(:unsupported_capability, "manifest requires unsupported capabilities", %{
          required: missing
        })
    end
  end

  defp nonempty(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty(_), do: malformed("required string is empty or invalid")

  defp stringify_file(file),
    do: %{"path" => file.path, "bytes" => file.bytes, "sha256" => file.sha256}

  defp bounded_context(context) do
    context
    |> Enum.take(32)
    |> Map.new(fn {key, value} -> {String.slice(to_string(key), 0, 128), bound_value(value)} end)
  end

  defp bound_value(value) when is_binary(value), do: String.slice(value, 0, 512)
  defp bound_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp bound_value(_value), do: "[omitted]"

  defp malformed(message), do: error(:invalid_request, message)

  defp error(code, message, context \\ %{}),
    do: {:error, Error.new(code, :wire, message, context: context)}
end
