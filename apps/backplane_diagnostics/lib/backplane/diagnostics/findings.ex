defmodule Backplane.Diagnostics.Findings do
  @moduledoc "Stores rule-versioned diagnostic inference separately from source facts."

  import Ecto.Query

  alias Backplane.Repo

  defmodule Finding do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_findings" do
      field :event_key, :id
      field :occurrence_id, :id
      field :rule, :string
      field :rule_version, :integer
      field :status, :string
      field :category, :string
      field :details, :map
      field :evidence_event_ids, {:array, :integer}
    end
  end

  def for_event(id),
    do:
      Repo.all(
        from row in Finding, where: row.event_key == ^id, order_by: [row.rule, row.rule_version]
      )

  @doc false
  def project(event_key, findings, occurrence, chosen) do
    Enum.each(findings, fn finding ->
      occurrence_id = if occurrence && chosen == finding.rule, do: occurrence.id

      Repo.insert_all(
        Finding,
        [
          %{
            event_key: event_key,
            occurrence_id: occurrence_id,
            rule: finding.rule,
            rule_version: finding.version,
            status: finding.status,
            category: finding.category,
            details: finding.details,
            evidence_event_ids: finding.evidence_event_ids
          }
        ],
        on_conflict:
          {:replace, [:occurrence_id, :status, :category, :details, :evidence_event_ids]},
        conflict_target: [:event_key, :rule, :rule_version],
        log: false
      )
    end)
  end
end
