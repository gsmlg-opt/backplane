defmodule Backplane.Memory.CurrentContext do
  @moduledoc "The current-memory eligibility boundary, separate from operator history."
  import Ecto.Query
  @policy "current_context.v1"
  def policy_version, do: @policy

  def query(query) do
    now = DateTime.utc_now()

    where(
      query,
      [m],
      is_nil(m.deleted_at) and m.effective_support and
        (is_nil(m.expires_at) or m.expires_at > ^now) and
        m.lifecycle_state not in ["superseded", "archived", "tombstoned"]
    )
    |> where(
      [m],
      fragment("bpm_memory_current_supported(?)", m)
    )
  end

  def metadata(memory) do
    context = get_in(memory.metadata || %{}, ["current_context"]) || %{}

    %{
      "policy_version" => @policy,
      "trust" => context["trust"] || "candidate_inference",
      "source_refs" => context["source_refs"] || [],
      "support_complete" => Map.get(context, "support_complete", false),
      "independent_support" => Map.get(context, "independent_support", false),
      "effective_support" => memory.effective_support,
      "lifecycle_state" => memory.lifecycle_state,
      "expires_at" => memory.expires_at && DateTime.to_iso8601(memory.expires_at),
      "valid_until" => if(context["independent_support"], do: nil, else: context["valid_until"])
    }
  end

  def result(memory) do
    metadata = metadata(memory)

    %{
      policy_version: metadata["policy_version"],
      trust: metadata["trust"],
      source_refs: metadata["source_refs"],
      support_complete: metadata["support_complete"],
      independent_support: metadata["independent_support"],
      effective_support: metadata["effective_support"],
      lifecycle_state: metadata["lifecycle_state"],
      expires_at: metadata["expires_at"],
      valid_until: metadata["valid_until"],
      revision: DateTime.to_unix(memory.updated_at, :microsecond)
    }
  end
end
