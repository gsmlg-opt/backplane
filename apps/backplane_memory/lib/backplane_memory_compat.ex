defmodule BackplaneMemory do
  @moduledoc false

  defdelegate version(), to: Backplane.Memory
end

defmodule BackplaneMemory.Memory do
  @moduledoc false

  def remember(_content), do: {:error, :unauthorized}
  def remember(_content, _opts), do: {:error, :unauthorized}
  def get(_id), do: {:error, :unauthorized}
  def forget(_id), do: {:error, :unauthorized}
  def stats, do: {:error, :unauthorized}
  def list, do: {:error, :unauthorized}
  def list(_opts), do: {:error, :unauthorized}
  def count, do: {:error, :unauthorized}
  def count(_opts), do: {:error, :unauthorized}

  @deprecated "Use Backplane.Memory.Memories.Relations.create_candidate/3"
  def maybe_detect_contradiction(_memory_id, _other_memory_id), do: {:error, :unauthorized}

  def scope_stats, do: {:error, :unauthorized}
  def team_share(_memory_id, _team_id), do: {:error, :unauthorized}
  def team_feed(_team_id), do: {:error, :unauthorized}
  def team_feed(_team_id, _limit), do: {:error, :unauthorized}
end

defmodule BackplaneMemory.Observations do
  @moduledoc false

  def record(_session_id, _content), do: {:error, :unauthorized}
  def record(_session_id, _content, _opts), do: {:error, :unauthorized}
  def register_session(_session_id, _project), do: {:error, :unauthorized}
  def end_session(_session_id), do: {:error, :unauthorized}
  def file_history(_file_paths), do: {:error, :unauthorized}
  def file_history(_file_paths, _opts), do: {:error, :unauthorized}
end

defmodule BackplaneMemory.Service do
  @moduledoc false
  @behaviour Backplane.Services.ManagedService

  defdelegate prefix(), to: Backplane.Memory.Service
  defdelegate enabled?(), to: Backplane.Memory.Service
  defdelegate tools(), to: Backplane.Memory.Service
  defdelegate call(name, arguments, auth), to: Backplane.Memory.Service
  defdelegate resources(), to: Backplane.Memory.Service
  defdelegate resources(auth), to: Backplane.Memory.Service
  defdelegate read_resource(uri), to: Backplane.Memory.Service
  defdelegate read_resource(uri, auth), to: Backplane.Memory.Service
  defdelegate prompts(), to: Backplane.Memory.Service
  defdelegate get_prompt(name, arguments), to: Backplane.Memory.Service
  defdelegate get_prompt(name, arguments, auth), to: Backplane.Memory.Service

  for handler <- ~w(
        handle_remember handle_recall handle_list handle_forget handle_stats
        handle_profile handle_profile_refresh handle_expand_query handle_file_history
        handle_facet_tag handle_facet_query handle_team_share handle_team_feed
        handle_lease handle_signal_send handle_signal_read handle_action_create
        handle_action_update handle_frontier handle_next handle_smart_search
        handle_sessions handle_patterns handle_timeline handle_export handle_relations
        handle_compress_file handle_audit handle_governance_delete handle_diagnose
        handle_heal handle_graph_query handle_graph_stats handle_consolidate handle_verify
        handle_slot_read handle_slot_write handle_slot_list handle_enrich handle_access_log
      )a do
    def unquote(handler)(_arguments), do: {:error, :unauthorized}
  end
end
