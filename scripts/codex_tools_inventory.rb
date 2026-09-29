#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"

ROOT = Pathname.new(__dir__).parent.realpath
LOCK_PATH = ROOT.join("docs/agent-runtime/codex-tools/source-lock.json")
LEDGER_PATH = ROOT.join("docs/agent-runtime/codex-tools/coverage-ledger.json")
MANIFEST_PATH = ROOT.join("docs/agent-runtime/codex-tools/local-source-manifest.json")
UPSTREAM_INVENTORY_PATH = ROOT.join("apps/backplane_agent_runtime/priv/codex/source-inventory.json")
REQUIRED_BACKPLANE_SHA = "7e3d81e18ddd612e20a8e11b60f3e1ad7d3bcb6d"
LEDGER_COMPATIBILITY_TOOLS = %w[web::fetch web::search web::x_search].freeze

SOURCE_ENTRIES = [
  ["exec_command", "codex-rs/core/src/tools/handlers/shell_spec.rs", "create_exec_command_tool", "environment and configured shell mode"],
  ["write_stdin", "codex-rs/core/src/tools/handlers/shell_spec.rs", "create_write_stdin_tool", "resumable command mode"],
  ["request_permissions", "codex-rs/core/src/tools/handlers/shell_spec.rs", "create_request_permissions_tool", "RequestPermissionsTool and environment"],
  ["apply_patch", "codex-rs/core/src/tools/handlers/apply_patch_spec.rs", "create_apply_patch_freeform_tool", "environment and model apply-patch support"],
  ["update_plan", "codex-rs/core/src/tools/handlers/plan_spec.rs", "create_update_plan_tool", "update_plan_enabled"],
  ["view_image", "codex-rs/core/src/tools/handlers/view_image_spec.rs", "create_view_image_tool", "ViewImage and environment"],
  ["new_context", "codex-rs/core/src/tools/handlers/new_context_window_spec.rs", "create_new_context_window_tool", "TokenBudget; direct model only"],
  ["get_context_remaining", "codex-rs/core/src/tools/handlers/get_context_remaining_spec.rs", "create_get_context_remaining_tool", "TokenBudget"],
  ["request_user_input", "codex-rs/core/src/tools/handlers/request_user_input_spec.rs", "create_request_user_input_tool", "experimental_request_user_input_enabled; direct model only"],
  ["request_user_input_async", "codex-rs/core/src/tools/handlers/request_user_input_async.rs", "request_user_input_async", "root agent and model support; direct model only"],
  ["send_message_to_user_async", "codex-rs/core/src/tools/handlers/send_message_to_user_async.rs", "send_message_to_user_async", "root agent and feature/model support; direct model only"],
  ["wait_for_environment", "codex-rs/core/src/tools/handlers/wait_for_environment.rs", "wait_for_environment", "DeferredExecutor"],
  ["clock::curr_time", "codex-rs/core/src/tools/handlers/current_time.rs", "curr_time", "CurrentTimeReminder or model clock support"],
  ["clock::sleep", "codex-rs/core/src/tools/handlers/sleep.rs", "create_sleep_tool", "SleepTool and configured mode; direct model only"],
  ["list_mcp_resources", "codex-rs/core/src/tools/handlers/mcp_resource_spec.rs", "create_list_mcp_resources_tool", "configured MCP server"],
  ["list_mcp_resource_templates", "codex-rs/core/src/tools/handlers/mcp_resource_spec.rs", "create_list_mcp_resource_templates_tool", "configured MCP server"],
  ["read_mcp_resource", "codex-rs/core/src/tools/handlers/mcp_resource_spec.rs", "create_read_mcp_resource_tool", "configured MCP server"],
  ["multi_agent_v1::spawn_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_spawn_agent_tool_v1", "collaboration V1"],
  ["multi_agent_v1::send_input", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_send_input_tool_v1", "collaboration V1"],
  ["multi_agent_v1::resume_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_resume_agent_tool", "collaboration V1"],
  ["multi_agent_v1::close_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_close_agent_tool_v1", "collaboration V1"],
  ["multi_agent_v1::wait_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_wait_agent_tool_v1", "collaboration V1"],
  ["spawn_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_spawn_agent_tool_v2", "collaboration V2; plain or host-configured namespace"],
  ["send_message", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_send_message_tool", "collaboration V2 direct messaging"],
  ["followup_task", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_followup_task_tool", "collaboration V2 direct messaging"],
  ["interrupt_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_interrupt_agent_tool_v2", "collaboration V2"],
  ["list_agents", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_list_agents_tool", "collaboration V2"],
  ["wait_agent", "codex-rs/core/src/tools/handlers/multi_agents_spec.rs", "create_wait_agent_tool_v2", "configured collaboration V2 wait; plain or host-configured namespace"],
  ["exec", "codex-rs/core/src/tools/code_mode/execute_spec.rs", "create_code_mode_tool", "CodeMode or CodeModeOnly"],
  ["wait", "codex-rs/core/src/tools/code_mode/wait_spec.rs", "create_wait_tool", "CodeMode continuation"],
  ["tool_search", "codex-rs/core/src/tools/handlers/tool_search_spec.rs", "create_tool_search_tool", "search support plus deferred tools"],
  ["list_available_plugins_to_install", "codex-rs/core/src/tools/handlers/list_available_plugins_to_install_spec.rs", "create_list_available_plugins_to_install_tool", "ToolSuggest list presentation"],
  ["request_plugin_install", "codex-rs/core/src/tools/handlers/request_plugin_install_spec.rs", "create_request_plugin_install_tool", "ToolSuggest candidates"],
  ["test_sync_tool", "codex-rs/core/src/tools/handlers/test_sync_spec.rs", "create_test_sync_tool", "experimental_supported_tools contains test_sync_tool", "test_only"],
  ["image_gen::imagegen", "codex-rs/ext/image-generation/src/tool.rs", "imagegen_tool_spec", "ImageGeneration, provider auth/capability, namespace tools, image modality"],
  ["web::run", "codex-rs/ext/web-search/src/tool.rs", "fn spec", "StandaloneWebSearch or Responses Lite plus provider search capability"],
  ["web_search", "codex-rs/core/src/tools/hosted_spec.rs", "create_web_search_tool", "provider hosted web_search and non-lite response mode"],
  ["get_goal", "codex-rs/ext/goal/src/spec.rs", "create_get_goal_tool", "goal extension installed"],
  ["create_goal", "codex-rs/ext/goal/src/spec.rs", "create_create_goal_tool", "goal extension installed"],
  ["update_goal", "codex-rs/ext/goal/src/spec.rs", "create_update_goal_tool", "goal extension installed"],
  ["memories::add_ad_hoc_note", "codex-rs/ext/memories/src/tools/ad_hoc_note.rs", "AddAdHocNoteTool", "MemoryTool and memories enabled with dedicated tools"],
  ["memories::list", "codex-rs/ext/memories/src/tools/list.rs", "ListTool", "MemoryTool and memories enabled with dedicated tools"],
  ["memories::read", "codex-rs/ext/memories/src/tools/read.rs", "ReadTool", "MemoryTool and memories enabled with dedicated tools"],
  ["memories::search", "codex-rs/ext/memories/src/tools/search.rs", "SearchTool", "MemoryTool and memories enabled with dedicated tools"],
  ["skills::list", "codex-rs/ext/skills/src/tools/list.rs", "ListTool", "skills extension configured with visible catalog"],
  ["skills::read", "codex-rs/ext/skills/src/tools/read.rs", "ReadTool", "skills extension configured with visible catalog"],
  ["history::list_windows", "codex-rs/ext/history-notes/src/tools.rs", "HistoryListWindows", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["history::list_items", "codex-rs/ext/history-notes/src/tools.rs", "HistoryListItems", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["history::read_item", "codex-rs/ext/history-notes/src/tools.rs", "HistoryReadItem", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["history::search_contents", "codex-rs/ext/history-notes/src/tools.rs", "HistorySearchContents", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["notes::list_files_by_prefix", "codex-rs/ext/history-notes/src/tools.rs", "NotesListFilesByPrefix", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["notes::read_file", "codex-rs/ext/history-notes/src/tools.rs", "NotesReadFile", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["notes::search_contents", "codex-rs/ext/history-notes/src/tools.rs", "NotesSearchContents", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["notes::append_to_file", "codex-rs/ext/history-notes/src/tools.rs", "NotesAppendToFile", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["notes::write_file", "codex-rs/ext/history-notes/src/tools.rs", "NotesWriteFile", "history-notes extension, Codex backend auth, token budget configuration; direct model only"],
  ["<board-namespace-or-plain>::create_channel", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "create_channel", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::get_channels", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "get_channels", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::list_threads", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "list_threads", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::search_posts", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "search_posts", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::read_thread", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "read_thread", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::read_post", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "read_post", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::subscribe", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "subscribe", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::unsubscribe", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "unsubscribe", "message-board backend available; host-configured optional namespace"],
  ["<board-namespace-or-plain>::post", "codex-rs/ext/agent-message-board/src/tools/spec.rs", "post", "message-board backend available; host-configured optional namespace"],
  ["dynamic::<host-defined>", "codex-rs/core/src/tools/spec_plan.rs", "append_dynamic_tool_runtimes", "host dynamic function or namespace"],
  ["mcp::<server-defined>", "codex-rs/core/src/tools/spec_plan.rs", "apply_mcp_tool_exposure_policy", "authorized MCP catalog; direct/deferred/code-mode policy"]
].freeze

def git(*args, chdir: ROOT.to_s)
  output, status = Open3.capture2e("git", *args, chdir: chdir)
  abort "git #{args.join(' ')} failed: #{output}" unless status.success?
  output.strip
end

def git_success?(*args, chdir: ROOT.to_s)
  _output, status = Open3.capture2e("git", *args, chdir: chdir)
  status.success?
end

def write_json(path, value)
  File.write(path, JSON.pretty_generate(value) + "\n")
end

def source_files
  roots = [ROOT.join("apps/backplane_agent_runtime/lib"), ROOT.join("apps/backplane_agent_runtime/priv")]
  roots.flat_map { |root| root.exist? ? root.find.select(&:file?) : [] }
       .select { |path| %w[.ex .exs .sh].include?(path.extname) }
       .sort
end

def local_manifest(lock)
  files = source_files.map do |path|
    {
      "path" => path.relative_path_from(ROOT).to_s,
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => path.size
    }
  end

  codex_root = ENV["CODEX_SOURCE_ROOT"]
  codex = {"required_commit" => lock.fetch("codex").fetch("required_commit"), "status" => "blocked"}
  if codex_root && File.directory?(codex_root)
    observed = git("rev-parse", "HEAD", chdir: codex_root)
    codex["observed_commit"] = observed
    codex["status"] = observed == codex["required_commit"] ? "available_exact_pin" : "blocked_wrong_revision"
  else
    codex["status"] = "blocked_missing_exact_checkout"
  end

  {
    "schema" => "backplane.codex-tools.local-source-manifest/v1",
    "backplane_baseline_commit" => lock.fetch("backplane").fetch("required_commit"),
    "backplane_baseline_is_ancestor" =>
      git_success?("merge-base", "--is-ancestor", REQUIRED_BACKPLANE_SHA, "HEAD"),
    "source_files" => files,
    "codex" => codex,
    "authority" => "Observed Backplane files only; this manifest does not establish Codex completeness or parity."
  }
end

def upstream_inventory(lock)
  codex_root = ENV["CODEX_SOURCE_ROOT"]
  abort "CODEX_SOURCE_ROOT must name the exact pinned Codex checkout" unless codex_root && File.directory?(codex_root)
  observed = git("rev-parse", "HEAD", chdir: codex_root)
  required = lock.fetch("codex").fetch("required_commit")
  abort "Codex HEAD #{observed} does not match #{required}" unless observed == required

  entries = SOURCE_ENTRIES.map do |name, relative, symbol, exposure, classification|
    path = Pathname.new(codex_root).join(relative)
    abort "missing pinned source #{relative}" unless path.file?
    source = path.read
    symbol_parts = symbol.split("/")
    abort "source symbol missing for #{name}: #{symbol}" unless symbol_parts.all? { |part| source.include?(part) }
    {
      "public_name" => name,
      "source_path" => relative,
      "constructor_or_registration" => symbol,
      "source_sha256" => Digest::SHA256.file(path).hexdigest,
      "exposure_conditions" => exposure,
      "classification" => classification || "production"
    }
  end

  {
    "schema" => "backplane.codex-tools.source-inventory/v1",
    "codex_commit" => observed,
    "registration_entrypoint" => "codex-rs/core/src/tools/spec_plan.rs::build_tool_router",
    "registration_audit" => {
      "source_path" => "codex-rs/core/src/tools/spec_plan.rs",
      "source_sha256" => Digest::SHA256.file(Pathname.new(codex_root).join("codex-rs/core/src/tools/spec_plan.rs")).hexdigest,
      "method" => "reviewed table with source substring assertions; constructors are not executed"
    },
    "entries" => entries,
    "authority" => "Reviewed exact-source records, not generated behavioral contracts. Availability and parity remain separate claims."
  }
end

def check_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  abort "invalid JSON #{path}: #{e.message}"
end

def check!
  lock = check_json(LOCK_PATH)
  ledger = check_json(LEDGER_PATH)
  manifest = check_json(MANIFEST_PATH)
  upstream = check_json(UPSTREAM_INVENTORY_PATH)
  abort "Backplane baseline #{REQUIRED_BACKPLANE_SHA} is not an ancestor of HEAD" unless git_success?("merge-base", "--is-ancestor", REQUIRED_BACKPLANE_SHA, "HEAD")
  abort "ledger has no families" unless ledger.fetch("families").is_a?(Array) && !ledger.fetch("families").empty?
  required = %w[
    tools
    inventory available admitted exposed contract_status execution_status availability parity
    deviation
  ]
  coverage_statuses = %w[confirmed partial pending blocked]
  contract_statuses = %w[missing exported verified]
  execution_statuses = %w[
    not_implemented partial reference_verified backend_verified provider_hosted test_only
  ]
  availabilities = %w[
    available missing_backend unsupported_platform unsupported_provider disabled_profile denied_policy
  ]
  parity_statuses = %w[exact_for_profile adapted divergent unverified]
  ledger.fetch("families").each do |family|
    missing = required - family.keys
    abort "family #{family["id"]} missing #{missing.join(', ')}" unless missing.empty?
    abort "family #{family["id"]} has invalid coverage status" unless %w[inventory available admitted exposed].all? { |key| coverage_statuses.include?(family[key]) }
    abort "family #{family["id"]} has invalid contract status" unless contract_statuses.include?(family["contract_status"])
    abort "family #{family["id"]} has invalid execution status" unless execution_statuses.include?(family["execution_status"])
    abort "family #{family["id"]} has invalid availability" unless availabilities.include?(family["availability"])
    abort "family #{family["id"]} has invalid parity" unless parity_statuses.include?(family["parity"])
  end
  abort "local source manifest is stale" unless manifest == local_manifest(lock)
  abort "source lock pin changed" unless lock.fetch("backplane").fetch("required_commit") == REQUIRED_BACKPLANE_SHA
  abort "exact Codex source was not recorded" unless manifest.dig("codex", "status") == "available_exact_pin"
  abort "upstream inventory pin changed" unless upstream["codex_commit"] == lock.dig("codex", "required_commit")
  abort "upstream inventory is stale" unless upstream == upstream_inventory(lock)
  inventory_names = upstream.fetch("entries").map { |entry| entry.fetch("public_name") }
  ledger_names = ledger.fetch("families").flat_map { |family| family.fetch("tools") }.uniq
  missing_names = inventory_names - ledger_names
  unexpected_names = ledger_names - inventory_names - LEDGER_COMPATIBILITY_TOOLS
  abort "ledger omits pinned tools: #{missing_names.join(', ')}" unless missing_names.empty?
  abort "ledger has unexpected tools: #{unexpected_names.join(', ')}" unless unexpected_names.empty?
  missing_compatibility = LEDGER_COMPATIBILITY_TOOLS - ledger_names
  abort "ledger omits compatibility tools: #{missing_compatibility.join(', ')}" unless missing_compatibility.empty?
  puts "codex-tools inventory check: PASS (#{ledger.fetch("families").length} families; #{upstream.fetch("entries").length} exact-source entries)"
end

mode = ARGV.fetch(0, "--check")
lock = check_json(LOCK_PATH)
case mode
when "--generate"
  write_json(MANIFEST_PATH, local_manifest(lock))
  write_json(UPSTREAM_INVENTORY_PATH, upstream_inventory(lock))
  puts "wrote #{MANIFEST_PATH.relative_path_from(ROOT)}"
  puts "wrote #{UPSTREAM_INVENTORY_PATH.relative_path_from(ROOT)}"
when "--check"
  check!
else
  abort "usage: #{File.basename(__FILE__)} [--generate|--check]"
end
