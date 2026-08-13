defmodule Backplane.Memory.Lessons.Lesson do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:memory_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @type t :: %__MODULE__{}

  schema "memory_lessons" do
    field(:status, :string)
    field(:context, :string)
    field(:source_kind, :string)
    field(:reinforcement_count, :integer, default: 0)
    field(:contradiction_count, :integer, default: 0)
    field(:decay_rate, :float, default: 0.0)
    field(:last_reinforced_at, :utc_datetime_usec)
    field(:last_applied_at, :utc_datetime_usec)
    field(:last_decayed_at, :utc_datetime_usec)
    field(:promoted_at, :utc_datetime_usec)
    field(:promoted_by, :string)
    field(:promotion_reason, :string)
    timestamps()
  end

  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, __schema__(:fields) -- [:created_at, :updated_at])
    |> validate_required([:memory_id, :status, :source_kind])
    |> validate_inclusion(:status, ~w(candidate active disputed superseded archived))
    |> validate_inclusion(:source_kind, ~w(manual correction crystal consolidation))
    |> validate_number(:reinforcement_count, greater_than_or_equal_to: 0)
    |> validate_number(:contradiction_count, greater_than_or_equal_to: 0)
    |> validate_number(:decay_rate, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:memory_id)
    |> check_constraint(:status, name: :memory_lessons_status_check)
    |> check_constraint(:source_kind, name: :memory_lessons_source_kind_check)
    |> check_constraint(:reinforcement_count, name: :memory_lessons_counts_nonnegative)
    |> check_constraint(:decay_rate, name: :memory_lessons_decay_rate_nonnegative)
  end
end
