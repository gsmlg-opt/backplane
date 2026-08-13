defmodule Backplane.Memory.Slots.Slot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_slots" do
    field(:name, :string)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:content, :string, default: "")
    field(:updated_at, :utc_datetime_usec)
    field(:updated_by, :string)
    field(:size_limit_chars, :integer, default: 2000)
  end

  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [
      :name,
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :content,
      :updated_at,
      :updated_by,
      :size_limit_chars
    ])
    |> validate_required([:name])
    |> validate_content_size()
  end

  defp validate_content_size(changeset) do
    case {get_field(changeset, :content), get_field(changeset, :size_limit_chars)} do
      {content, limit} when is_binary(content) and is_integer(limit) ->
        if String.length(content) > limit do
          add_error(changeset, :content, "exceeds size limit of #{limit} chars")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
