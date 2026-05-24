defmodule Backplane.Audit.ToolCallLog do
  @moduledoc "Ecto schema for the tool_call_log audit table."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tool_call_log" do
    field(:tool_name, :string)
    field(:client_id, :binary_id)
    field(:client_name, :string)
    field(:duration_us, :integer)
    field(:status, :string)
    field(:error_message, :string)
    field(:arguments_hash, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  @required ~w(tool_name status)a
  @optional ~w(client_id client_name duration_us error_message arguments_hash)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["ok", "error"])
  end
end
