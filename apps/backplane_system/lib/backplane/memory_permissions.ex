defmodule Backplane.MemoryPermissions do
  @moduledoc "Canonical permission classes for Backplane Memory surfaces."

  @read_tools ~w(
    memory::access_log
    memory::crystal_get
    memory::crystal_list
    memory::crystal_search
    memory::expand_query
    memory::facet_query
    memory::file_history
    memory::graph_query
    memory::graph_stats
    memory::list
    memory::lesson_recall
    memory::patterns
    memory::profile
    memory::recall
    memory::recall_explain
    memory::relations
    memory::sessions
    memory::slot_list
    memory::slot_read
    memory::smart_search
    memory::stats
    memory::activity_summary
    memory::team_feed
    memory::timeline
    memory::verify
  )

  @write_tools ~w(
    memory::compress_file
    memory::consolidate
    memory::apply
    memory::enrich
    memory::facet_tag
    memory::forget
    memory::lesson_save
    memory::lesson_strengthen
    memory::profile_refresh
    memory::remember
    memory::slot_write
    memory::team_share
  )

  @coordinate_tools ~w(
    memory::action_create
    memory::action_update
    memory::frontier
    memory::lease
    memory::next
    memory::signal_read
    memory::signal_send
  )

  @replay_tools ~w(memory::export memory::replay_sessions memory::replay_load)
  @admin_tools ~w(
    memory::audit
    memory::crystallize
    memory::diagnose
    memory::governance_delete
    memory::heal
    memory::lesson_archive
    memory::lesson_promote
    memory::replay_import
  )

  @tool_permissions Enum.reduce(
                      [
                        {"memory.read", @read_tools},
                        {"memory.write", @write_tools},
                        {"memory.coordinate", @coordinate_tools},
                        {"memory.replay", @replay_tools},
                        {"memory.admin", @admin_tools}
                      ],
                      %{},
                      fn {permission, tools}, acc ->
                        Enum.reduce(tools, acc, &Map.put(&2, &1, permission))
                      end
                    )

  @spec tool_permissions() :: %{String.t() => String.t()}
  def tool_permissions, do: @tool_permissions

  @spec for_tool(String.t()) :: {:ok, String.t()} | :error
  def for_tool(name) when is_binary(name), do: Map.fetch(@tool_permissions, name)

  @spec for_tool!(String.t()) :: String.t()
  def for_tool!(name) when is_binary(name), do: Map.fetch!(@tool_permissions, name)
end
