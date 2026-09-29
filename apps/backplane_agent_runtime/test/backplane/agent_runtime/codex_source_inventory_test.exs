defmodule Backplane.AgentRuntime.CodexSourceInventoryTest do
  use ExUnit.Case, async: true

  @inventory_path Path.expand("../../../priv/codex/source-inventory.json", __DIR__)

  test "packaged exact-source inventory pins critical public contracts" do
    inventory = @inventory_path |> File.read!() |> JSON.decode!()
    assert inventory["codex_commit"] == "46fdd5ef39735f4159cdcf0ec5e85c10521494e5"

    entries = Map.new(inventory["entries"], &{&1["public_name"], &1})

    assert %{"source_path" => "codex-rs/core/src/tools/handlers/new_context_window_spec.rs"} =
             entries["new_context"]

    assert Map.has_key?(entries, "exec")
    assert Map.has_key?(entries, "wait")
    assert Map.has_key?(entries, "image_gen::imagegen")
    assert Map.has_key?(entries, "web_search")
    assert Map.has_key?(entries, "list_mcp_resources")
    assert Map.has_key?(entries, "request_plugin_install")
    assert %{"classification" => "test_only"} = entries["test_sync_tool"]
    assert Map.has_key?(entries, "clock::curr_time")
    assert Map.has_key?(entries, "clock::sleep")
    assert map_size(entries) == 66
    refute Map.has_key?(entries, "extension::<contributor-defined>")

    assert Enum.all?(
             ~w(
               get_goal create_goal update_goal
               memories::add_ad_hoc_note memories::list memories::read memories::search
               skills::list skills::read
               history::list_windows history::list_items history::read_item history::search_contents
               notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file
             ),
             &Map.has_key?(entries, &1)
           )

    assert Enum.count(entries, fn {name, _entry} ->
             String.starts_with?(name, "<board-namespace-or-plain>::")
           end) == 9

    assert Enum.all?(inventory["entries"], fn entry ->
             String.match?(entry["source_sha256"], ~r/\A[0-9a-f]{64}\z/) and
               entry["constructor_or_registration"] != "" and
               entry["exposure_conditions"] != "" and
               entry["classification"] in ["production", "test_only"]
           end)
  end

  test "V1 and V2 collaboration names remain separately inventoried" do
    inventory = @inventory_path |> File.read!() |> JSON.decode!()
    names = MapSet.new(inventory["entries"], & &1["public_name"])

    assert MapSet.subset?(
             MapSet.new(
               ~w(multi_agent_v1::spawn_agent multi_agent_v1::send_input multi_agent_v1::resume_agent multi_agent_v1::close_agent multi_agent_v1::wait_agent)
             ),
             names
           )

    assert MapSet.subset?(
             MapSet.new(
               ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
             ),
             names
           )
  end
end
