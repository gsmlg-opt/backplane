defmodule Backplane.Audit.SkillLoadLog do
  @moduledoc "Ecto schema for the skill_load_log audit table."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "skill_load_log" do
    field(:event_id, :string)
    field(:request_id, :string)
    field(:trace_id, :string)
    field(:mcp_request_id, :string)
    field(:skill_name, :string)
    field(:client_id, :binary_id)
    field(:client_name, :string)
    field(:loaded_deps, {:array, :string}, default: [])
    field(:inserted_at, :utc_datetime_usec)
  end

  @required ~w(skill_name)a
  @optional ~w(event_id request_id trace_id mcp_request_id client_id client_name loaded_deps)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
