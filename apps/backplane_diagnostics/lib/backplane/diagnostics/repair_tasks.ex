defmodule Backplane.Diagnostics.RepairTasks do
  @moduledoc "Read-only implementation guidance associated with a verified structured analysis."

  import Ecto.Query

  alias Backplane.Repo

  defmodule Task do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_repair_tasks" do
      field :issue_id, :id
      field :analysis_id, :id
      field :evidence_bundle_id, :id
      field :body, :map
      field :expired_at, :utc_datetime_usec
      field :inserted_at, :utc_datetime_usec
    end
  end

  @doc "Returns the latest repair task record and its retention state."
  def get(issue_id) do
    Task
    |> where([task], task.issue_id == ^issue_id)
    |> order_by([task], desc: task.id)
    |> limit(1)
    |> Repo.one(log: false)
  end

  @doc false
  def store!(job, bundle, output, now) do
    version =
      bundle.payload["references"]
      |> Enum.find_value(%{}, fn entry ->
        if entry["kind"] == "event" and is_map(entry["version"]), do: entry["version"]
      end)

    Repo.insert!(
      %Task{
        issue_id: job.issue_id,
        analysis_id: job.id,
        evidence_bundle_id: bundle.id,
        inserted_at: now,
        body: %{
          "target_repository" => version["repository"],
          "fault_sha" => version["git_sha"],
          "suggested_implementation_base" => version["git_sha"],
          "dependency_versions" => Map.take(version, ~w(runtime adapter release)),
          "facts" => output["facts"],
          "impact" => output["impact"],
          "hypotheses" => output["hypotheses"],
          "verified_root_cause" => nil,
          "reproduction" => output["reproduction"],
          "repair" => output["repair"],
          "regression_tests" => output["regression_tests"],
          "acceptance" => output["acceptance"],
          "limitations" => output["limitations"],
          "occurrence_ids" => bundle.payload["occurrence_ids"],
          "requires_human_review" => true
        }
      },
      log: false
    )
  end
end
