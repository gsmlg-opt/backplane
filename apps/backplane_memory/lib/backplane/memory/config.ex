defmodule Backplane.Memory.Config do
  @moduledoc false

  @pipeline "memory.pipeline.enabled"
  @events "memory.events.enabled"
  @dual_write "memory.events.dual_write"
  @window_summaries "memory.window_summaries.enabled"
  @session_summary_v2 "memory.session_summary_v2.enabled"
  @fact_extraction_v2 "memory.fact_extraction_v2.enabled"
  @procedure_extraction_v2 "memory.procedure_extraction_v2.enabled"
  @recall_v2 "memory.recall_v2.enabled"

  def pipeline_enabled?, do: enabled?(@pipeline)
  def events_enabled?, do: pipeline_enabled?() and enabled?(@events)
  def dual_write?, do: events_enabled?() and enabled?(@dual_write)

  def window_summaries_enabled?,
    do: pipeline_enabled?() and enabled?(@window_summaries)

  def session_summary_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@session_summary_v2)

  def fact_extraction_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@fact_extraction_v2)

  def procedure_extraction_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@procedure_extraction_v2)

  def recall_v2_enabled?, do: pipeline_enabled?() and enabled?(@recall_v2)

  defp enabled?(key), do: Backplane.Settings.get(key) == true
end
