defmodule Backplane.Memory.SharedCommands.Receipt do
  @moduledoc "Final, content-free outcomes of version-bound shared Memory commands."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_access_commands" do
    field(:host_id, :binary_id)
    field(:access_id, :binary_id)
    field(:command_id, :binary_id)
    field(:memory_space_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:authority_version, :integer)
    field(:operation, :string)
    field(:payload_digest, :binary)
    field(:status, :string)
    field(:canonical_id, :binary_id)
    field(:revision, :integer)
    field(:error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
