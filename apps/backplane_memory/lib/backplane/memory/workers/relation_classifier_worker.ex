defmodule Backplane.Memory.Workers.RelationClassifierWorker do
  @moduledoc "Oban worker for evidence-backed automatic memory relation candidates."

  use Oban.Worker,
    queue: :memory_relation_classifier,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:memory_id, :processing_version, :evidence_revision]
    ]

  alias Backplane.Memory.Config
  alias Backplane.Memory.Memories.RelationClassifier

  @processing_version "relation-classifier-v1"

  def processing_version, do: @processing_version

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "memory_id" => memory_id,
          "processing_version" => @processing_version,
          "evidence_revision" => evidence_revision,
          "partition" => partition
        }
      })
      when is_binary(memory_id) and is_binary(evidence_revision) and is_map(partition) do
    Backplane.Memory.PipelineTelemetry.span("relation.classifier", partition, fn ->
      if Config.relation_classifier_enabled?(),
        do: RelationClassifier.process(memory_id, partition: partition),
        else: :ok
    end)
  end

  if Mix.env() == :test do
    def perform(%Oban.Job{
          args: %{
            "memory_id" => memory_id,
            "processing_version" => @processing_version,
            "evidence_revision" => evidence_revision
          }
        })
        when is_binary(memory_id) and is_binary(evidence_revision) do
      if Config.relation_classifier_enabled?(),
        do: RelationClassifier.process(memory_id),
        else: :ok
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  def enqueue(memory_id, evidence_revision, partition)
      when is_binary(memory_id) and is_binary(evidence_revision) and is_map(partition) do
    %{
      memory_id: memory_id,
      processing_version: @processing_version,
      evidence_revision: evidence_revision,
      partition: partition
    }
    |> new()
    |> Oban.insert()
  end

  if Mix.env() == :test do
    def enqueue(memory_id, evidence_revision)
        when is_binary(memory_id) and is_binary(evidence_revision) do
      enqueue(memory_id, evidence_revision, %{})
    end
  end
end
