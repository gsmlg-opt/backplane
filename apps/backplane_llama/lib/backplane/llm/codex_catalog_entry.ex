defmodule Backplane.LLM.CodexCatalogEntry do
  @moduledoc "Persisted Codex model exposure policy."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_codex_catalog_entries" do
    field(:public_model_id, :string)
    field(:source_model, :string)
    field(:display_name, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: false)
    field(:priority, :integer, default: 100)
    field(:context_window_override, :integer)
    field(:reasoning_metadata, :map, default: %{})
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(public_model_id source_model)a
  @optional_fields ~w(display_name description enabled priority context_window_override reasoning_metadata metadata)a

  @doc "Changeset for a Codex exposure policy entry."
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:public_model_id, &trim/1)
    |> update_change(:source_model, &trim/1)
    |> update_change(:display_name, &trim_or_nil/1)
    |> update_change(:description, &trim_or_nil/1)
    |> validate_required(@required_fields)
    |> validate_format(:public_model_id, ~r/^[^\s]+$/, message: "must not contain whitespace")
    |> validate_number(:priority,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 2_147_483_647
    )
    |> validate_number(:context_window_override, greater_than: 0)
    |> validate_map(:reasoning_metadata)
    |> validate_map(:metadata)
    |> unique_constraint(:public_model_id)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn
      ^field, value when is_map(value) -> []
      ^field, _value -> [{field, "must be a map"}]
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value
end
