defmodule Backplane.Memory.Summaries.Summary do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_summaries" do
    field(:session_id, :string)
    field(:project, :string, default: "")
    field(:content, :string)
    field(:observation_count, :integer, default: 0)
    field(:subject_id, :string)
    field(:host_id, :string)
    field(:agent_id, :string)
    field(:processing_version, :string)
    field(:input_revision, :string)
    field(:output_revision, :string)
    field(:source_complete, :boolean, default: true)
    field(:source_gap_count, :integer, default: 0)
    field(:source_gaps, :map, default: %{"ranges" => []})
    field(:superseded_at, :utc_datetime_usec)
    field(:superseded_by_input_revision, :string)
    timestamps()
  end

  def changeset(summary, attrs) do
    attrs = canonical_or_legacy_attrs(attrs)

    summary
    |> cast(attrs, [
      :session_id,
      :project,
      :content,
      :observation_count,
      :subject_id,
      :host_id,
      :agent_id,
      :processing_version,
      :input_revision,
      :output_revision,
      :source_complete,
      :source_gap_count,
      :source_gaps,
      :superseded_at,
      :superseded_by_input_revision
    ])
    |> validate_required([
      :session_id,
      :content,
      :subject_id,
      :host_id,
      :processing_version,
      :input_revision,
      :output_revision
    ])
    |> validate_number(:observation_count, greater_than_or_equal_to: 0)
    |> validate_number(:source_gap_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:subject_id, :processing_version],
      name: :memory_summaries_subject_version_uniq
    )
  end

  defp canonical_or_legacy_attrs(attrs) when is_map(attrs) do
    if present?(attrs, :subject_id) do
      attrs
    else
      session_id = value(attrs, :session_id)
      content = value(attrs, :content)

      if non_empty?(session_id) and is_binary(content) do
        attrs
        |> put_default(:subject_id, "legacy:#{session_id}")
        |> put_default(:host_id, "legacy")
        |> put_default(:processing_version, "legacy-v0")
        |> put_default(:input_revision, legacy_input_revision(session_id))
        |> put_default(:output_revision, legacy_output_revision(content))
      else
        attrs
      end
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp put_default(attrs, key, value) when is_map_key(attrs, "session_id"),
    do: Map.put_new(attrs, Atom.to_string(key), value)

  defp put_default(attrs, key, value), do: Map.put_new(attrs, key, value)
  defp present?(attrs, key), do: non_empty?(value(attrs, key))
  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""
  @doc false
  def legacy_input_revision(session_id) do
    md5("legacy-input:#{session_id}") <> md5("legacy-input-2:#{session_id}")
  end

  @doc false
  def legacy_output_revision(content) do
    md5(content) <> md5("legacy-output-2:#{content}")
  end

  defp md5(value), do: :crypto.hash(:md5, value) |> Base.encode16(case: :lower)
end
