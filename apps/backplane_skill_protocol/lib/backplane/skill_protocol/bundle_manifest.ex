defmodule Backplane.SkillProtocol.BundleManifest do
  @moduledoc "Immutable inventory and identity for one exact Skill bundle."

  @enforce_keys [
    :protocol_version,
    :profile,
    :root,
    :entrypoint,
    :artifact_format,
    :artifact_digest,
    :compressed_bytes,
    :unpacked_bytes,
    :files
  ]
  defstruct [
    :protocol_version,
    :profile,
    :ref,
    :root,
    :entrypoint,
    :document_metadata,
    :artifact_format,
    :artifact_digest,
    :compressed_bytes,
    :unpacked_bytes,
    required_capabilities: [],
    files: []
  ]

  @type t :: %__MODULE__{}
end
