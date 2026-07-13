defmodule BackplaneMemory do
  @moduledoc false

  defdelegate version(), to: Backplane.Memory
end

defmodule BackplaneMemory.Memory do
  @moduledoc false

  defdelegate remember(content), to: Backplane.Memory.Memories
  defdelegate remember(content, opts), to: Backplane.Memory.Memories
  defdelegate get(id), to: Backplane.Memory.Memories
  defdelegate forget(id), to: Backplane.Memory.Memories
  defdelegate stats(), to: Backplane.Memory.Memories
  defdelegate list(), to: Backplane.Memory.Memories
  defdelegate list(opts), to: Backplane.Memory.Memories
  defdelegate count(), to: Backplane.Memory.Memories
  defdelegate count(opts), to: Backplane.Memory.Memories

  defdelegate maybe_detect_contradiction(memory_id, other_memory_id),
    to: Backplane.Memory.Memories

  defdelegate scope_stats(), to: Backplane.Memory.Memories
  defdelegate team_share(memory_id, team_id), to: Backplane.Memory.Memories
  defdelegate team_feed(team_id), to: Backplane.Memory.Memories
  defdelegate team_feed(team_id, limit), to: Backplane.Memory.Memories
end

defmodule BackplaneMemory.Observations do
  @moduledoc false

  defdelegate record(session_id, content), to: Backplane.Memory.Observations
  defdelegate record(session_id, content, opts), to: Backplane.Memory.Observations
  defdelegate register_session(session_id, project), to: Backplane.Memory.Observations
  defdelegate end_session(session_id), to: Backplane.Memory.Observations
  defdelegate file_history(file_paths), to: Backplane.Memory.Observations
  defdelegate file_history(file_paths, opts), to: Backplane.Memory.Observations
end

defmodule BackplaneMemory.Service do
  @moduledoc false
  @behaviour Backplane.Services.ManagedService

  defdelegate prefix(), to: Backplane.Memory.Service
  defdelegate enabled?(), to: Backplane.Memory.Service
  defdelegate tools(), to: Backplane.Memory.Service
  defdelegate resources(), to: Backplane.Memory.Service
  defdelegate read_resource(uri), to: Backplane.Memory.Service
  defdelegate prompts(), to: Backplane.Memory.Service
  defdelegate get_prompt(name, arguments), to: Backplane.Memory.Service

  defdelegate handle_remember(arguments), to: Backplane.Memory.Service
  defdelegate handle_recall(arguments), to: Backplane.Memory.Service
  defdelegate handle_list(arguments), to: Backplane.Memory.Service
  defdelegate handle_forget(arguments), to: Backplane.Memory.Service
  defdelegate handle_stats(arguments), to: Backplane.Memory.Service
  defdelegate handle_profile(arguments), to: Backplane.Memory.Service
  defdelegate handle_profile_refresh(arguments), to: Backplane.Memory.Service
  defdelegate handle_expand_query(arguments), to: Backplane.Memory.Service
  defdelegate handle_file_history(arguments), to: Backplane.Memory.Service
  defdelegate handle_facet_tag(arguments), to: Backplane.Memory.Service
  defdelegate handle_facet_query(arguments), to: Backplane.Memory.Service
  defdelegate handle_team_share(arguments), to: Backplane.Memory.Service
  defdelegate handle_team_feed(arguments), to: Backplane.Memory.Service
  defdelegate handle_lease(arguments), to: Backplane.Memory.Service
  defdelegate handle_signal_send(arguments), to: Backplane.Memory.Service
  defdelegate handle_signal_read(arguments), to: Backplane.Memory.Service
  defdelegate handle_action_create(arguments), to: Backplane.Memory.Service
  defdelegate handle_action_update(arguments), to: Backplane.Memory.Service
  defdelegate handle_frontier(arguments), to: Backplane.Memory.Service
  defdelegate handle_next(arguments), to: Backplane.Memory.Service
  defdelegate handle_smart_search(arguments), to: Backplane.Memory.Service
  defdelegate handle_sessions(arguments), to: Backplane.Memory.Service
  defdelegate handle_patterns(arguments), to: Backplane.Memory.Service
  defdelegate handle_timeline(arguments), to: Backplane.Memory.Service
  defdelegate handle_export(arguments), to: Backplane.Memory.Service
  defdelegate handle_relations(arguments), to: Backplane.Memory.Service
  defdelegate handle_compress_file(arguments), to: Backplane.Memory.Service
  defdelegate handle_audit(arguments), to: Backplane.Memory.Service
  defdelegate handle_governance_delete(arguments), to: Backplane.Memory.Service
  defdelegate handle_diagnose(arguments), to: Backplane.Memory.Service
  defdelegate handle_heal(arguments), to: Backplane.Memory.Service
  defdelegate handle_graph_query(arguments), to: Backplane.Memory.Service
  defdelegate handle_graph_stats(arguments), to: Backplane.Memory.Service
  defdelegate handle_consolidate(arguments), to: Backplane.Memory.Service
  defdelegate handle_verify(arguments), to: Backplane.Memory.Service
  defdelegate handle_slot_read(arguments), to: Backplane.Memory.Service
  defdelegate handle_slot_write(arguments), to: Backplane.Memory.Service
  defdelegate handle_slot_list(arguments), to: Backplane.Memory.Service
  defdelegate handle_enrich(arguments), to: Backplane.Memory.Service
  defdelegate handle_access_log(arguments), to: Backplane.Memory.Service
end
