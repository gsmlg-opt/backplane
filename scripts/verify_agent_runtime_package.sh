#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/backplane_agent_runtime" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
artifact="$work_root/backplane_agent_runtime.tar"
unpacked="$work_root/unpacked"
source_dir="$work_root/source"

# Before publication, qualify Runtime against the candidate MCP source package.
# The artifact itself retains its published dependency requirement unchanged.
candidate_mcp="${MCP_PROTOCOL_SOURCE-$script_dir/../apps/backplane_mcp_protocol}"
if [[ -n "$candidate_mcp" ]]; then
  test -f "$candidate_mcp/mix.exs"
  mkdir -p "$work_root/mcp-source" "$work_root/mcp-package"
  tar -C "$candidate_mcp" --exclude='./_build' --exclude='./deps' --exclude='./doc' \
    --exclude='./tmp' --exclude='./priv/bin/backplane-mcp-stdio-guardian*' --exclude='*.tar' -cf - . \
    | tar -xf - -C "$work_root/mcp-source"
  (cd "$work_root/mcp-source" && MIX_ENV=prod mix hex.build --output "$work_root/mcp.tar")
  tar -xf "$work_root/mcp.tar" -O contents.tar.gz | tar -xz -C "$work_root/mcp-package"
  export MCP_PROTOCOL_SOURCE="$work_root/mcp-package"
fi

use_candidate_mcp() {
  if [[ -z "$candidate_mcp" ]]; then return; fi
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
if sys.argv[2] == "source":
    needle = '      {app, protocol_requirement(app)}'
    replacement = '''      if app == :backplane_mcp_protocol do
        {app, path: System.fetch_env!("MCP_PROTOCOL_SOURCE"), override: true}
      else
        {app, protocol_requirement(app)}
      end'''
else:
    needle = '{:backplane_agent_runtime, path: System.fetch_env!("AGENT_RUNTIME_PATH")}'
    replacement = needle + ',\n      {:backplane_mcp_protocol, path: System.fetch_env!("MCP_PROTOCOL_SOURCE"), override: true}'
if text.count(needle) != 1:
    raise SystemExit("candidate MCP qualification marker is missing or ambiguous")
path.write_text(text.replace(needle, replacement))
PY
}

if command -v unbuffer >/dev/null 2>&1; then
  mix_command=(unbuffer mix)
else
  mix_command=(mix)
fi

sigma_source="${SIGMA_SOURCE:-$script_dir/../../sigma}"
require_sigma_source="${REQUIRE_SIGMA_SOURCE:-0}"
pty_package_only="${PTY_PACKAGE_ONLY:-0}"
if [[ "$pty_package_only" != "0" && "$pty_package_only" != "1" ]]; then
  printf 'PTY_PACKAGE_ONLY must be 0 or 1.\n' >&2
  exit 1
fi
if [[ "$pty_package_only" == "1" && "$(uname -s)" != "Linux" ]]; then
  printf 'Native PTY package verification requires Linux.\n' >&2
  exit 1
fi

if [[ "$require_sigma_source" != "0" && "$require_sigma_source" != "1" ]]; then
  printf 'REQUIRE_SIGMA_SOURCE must be 0 or 1, got %s.\n' "$require_sigma_source" >&2
  exit 1
fi

if [[ "$require_sigma_source" == "1" && \
      (! -d "$sigma_source/apps/sigma_ai" || ! -d "$sigma_source/apps/sigma_coding") ]]; then
  printf 'Required Sigma source checkout not found at %s.\n' "$sigma_source" >&2
  exit 1
fi

# Resolve documentation-only dependencies and build without changing the checkout.
mkdir -p "$source_dir"
tar -C "$runtime_dir" --exclude='./_build' --exclude='./deps' --exclude='./doc' \
  --exclude='./tmp' --exclude='./priv/bin/backplane-local-command-pty*' --exclude='*.tar' -cf - . | tar -xf - -C "$source_dir"
cd "$source_dir"
# Build the distributable before adding qualification-only local overrides.
MIX_ENV=dev "${mix_command[@]}" hex.build --output "$artifact"
use_candidate_mcp "$source_dir/mix.exs" source
MIX_ENV=dev "${mix_command[@]}" deps.get
if [[ -n "$candidate_mcp" ]]; then MIX_ENV=dev "${mix_command[@]}" format mix.exs; fi
if [[ "$pty_package_only" == "1" ]]; then
  MIX_ENV=dev "${mix_command[@]}" format --check-formatted \
    lib/backplane/agent_runtime/tools/local_command.ex \
    lib/backplane/agent_runtime/tools/local_command/pty.ex \
    lib/backplane/agent_runtime/tools/local_command/procfs.ex \
    lib/mix/tasks/backplane.pty.build.ex \
    test/backplane/agent_runtime/tools/local_command_pty_test.exs mix.exs
else
  MIX_ENV=dev "${mix_command[@]}" format --check-formatted
fi
MIX_ENV=dev "${mix_command[@]}" compile --warnings-as-errors
MIX_ENV=dev "${mix_command[@]}" backplane.mcp.stdio.build
if [[ "$(uname -s)" == "Linux" ]]; then
  MIX_ENV=dev "${mix_command[@]}" backplane.pty.build
  python3 test/native/pty_protocol_test.py
  "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 \
    test/native/pty_identity_test.c -o "$work_root/pty-identity-test"
  "$work_root/pty-identity-test"
fi
if [[ "$pty_package_only" == "1" ]]; then
  MIX_ENV=test "${mix_command[@]}" test test/backplane/agent_runtime/tools/local_command_pty_test.exs
else
MIX_ENV=dev "${mix_command[@]}" docs --warnings-as-errors
if [[ -n "${COREUTILS:-}" || "$(command -v coreutils || true)" != "" ]]; then
  MIX_ENV=test "${mix_command[@]}" test
else
  printf 'Skipping Linux-only LocalCommand tests: COREUTILS is unavailable on this host.\n'
  test_files="$(find test -name '*_test.exs' \
    ! -path 'test/backplane/agent_runtime/tools/local_command_test.exs' \
    ! -path 'test/backplane/agent_runtime/tools/local_command_cleanup_test.exs')"
  MIX_ENV=test "${mix_command[@]}" test ${test_files}
fi
MIX_ENV=test python3 test/fixtures/run_plugin_completion_cold.py "$work_root/cold-plugin-completion"
MIX_ENV=test python3 test/fixtures/run_goal_settlement_cold.py "$work_root/cold-goal-settlement"
MIX_ENV=test python3 test/fixtures/run_goal_host_settlement_cold.py "$work_root/cold-goal-host-settlement"
fi
mkdir -p "$unpacked"
tar -xf "$artifact" -O contents.tar.gz | tar -xz -C "$unpacked"

test -f "$unpacked/lib/backplane/agent_runtime/tools/local_resource.ex"
test -f "$unpacked/lib/backplane/agent_runtime/tools/local_command.ex"
test -f "$unpacked/priv/local_command_launcher.sh"
test -f "$unpacked/c_src/local_command_pty.c"
test -f "$unpacked/c_src/build_pty.sh"
test -f "$unpacked/lib/mix/tasks/backplane.pty.build.ex"
test ! -e "$unpacked/priv/bin/backplane-local-command-pty"
test -f "$unpacked/priv/codex/profile.json"
test -f "$unpacked/priv/codex/code_mode_worker.js"
test -f "$unpacked/priv/codex/source-inventory.json"
test -f "$unpacked/lib/backplane/agent_runtime/codex/services.ex"
test -f "$unpacked/lib/backplane/agent_runtime/codex/web.ex"
test -f "$unpacked/lib/backplane/agent_runtime/codex/image.ex"
test -f "$unpacked/lib/backplane/agent_runtime/codex/hosted.ex"
test -f "$unpacked/CHANGELOG.md"
test -f "$unpacked/README.md"
test -f "$unpacked/EMBEDDING.md"
test -f "$unpacked/PERSISTENCE.md"
test -f "$unpacked/SCHEMAS.md"
test -f "$unpacked/examples/embedded.exs"
test "$(rg -c 'app: :backplane_agent_runtime' "$unpacked/mix.exs")" = "1"
if rg -n 'Backplane\.AgentTools|backplane_agent_tools' "$unpacked"; then
  printf 'The artifact contains an obsolete tools application or namespace.\n' >&2
  exit 1
fi
# Check evaluated standalone configuration, not inactive umbrella source branches.
manifest_guard="$work_root/verify_manifest.exs"
cat > "$manifest_guard" <<'MANIFEST_GUARD'
Mix.start()
root = Path.expand(hd(System.argv()))
Mix.Project.in_project(:backplane_agent_runtime, root, fn _ ->
  config = Mix.Project.config()
  unless config[:app] == :backplane_agent_runtime, do: raise("unexpected package app")
  if config[:apps_path], do: raise("artifact is an active umbrella project")
  for dependency <- config[:deps] || [] do
    options = dependency |> Tuple.to_list() |> List.last()
    if is_list(options) and (Keyword.has_key?(options, :path) or Keyword.get(options, :in_umbrella, false)) do
      raise "artifact has an active local dependency: #{inspect(elem(dependency, 0))}"
    end
  end
  for key <- [:build_path, :deps_path, :config_path, :lockfile], value = config[key], is_binary(value) do
    path = Path.expand(value, root)
    unless path == root or String.starts_with?(path, root <> "/"), do: raise("artifact has external #{key}")
  end
  IO.puts("Standalone manifest dependencies and paths: PASS")
end)
MANIFEST_GUARD
elixir "$manifest_guard" "$unpacked"

dependencies="$(cd "$unpacked" && MIX_ENV=prod "${mix_command[@]}" deps.tree --only prod)"
if ! grep -q 'jsonschex ~> 0.10.0' <<<"$dependencies"; then
  printf 'The artifact is missing its required JSON Schema production dependency:\n%s\n' "$dependencies" >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(backplane_(system|api|admin|mcp|llama|skills)|phoenix(_[a-z_]+)?|ecto(_[a-z_]+)?|postgrex)([[:space:]]|$)' <<<"$dependencies"; then
  printf 'The artifact unexpectedly resolves umbrella or server dependencies:\n%s\n' "$dependencies" >&2
  exit 1
fi

for boundary_file in kernel.ex tool_effects.ex tool_registry.ex; do
  if rg -n 'AgentRuntime\.Tools\.(LocalResource|LocalCommand)' \
    "$unpacked/lib/backplane/agent_runtime/$boundary_file"; then
    printf 'Generic runtime layer depends on a concrete bundled tool.\n' >&2
    exit 1
  fi
done

artifact_hash="$(sha256sum "$artifact" | cut -d ' ' -f 1)"

fixtures=(empty_tool bundled_basic fake_backend pty_basic)
if [[ "$pty_package_only" == "1" ]]; then fixtures=(pty_basic); fi
for fixture in "${fixtures[@]}"; do
  if [[ "$fixture" == "pty_basic" && "$(uname -s)" != "Linux" ]]; then
    printf 'Skipping pty_basic consumer: first-party PTY requires native Linux.\n'
    continue
  fi
  if [[ "$fixture" == "bundled_basic" && -z "${COREUTILS:-}" && "$(uname -s)" != "Linux" ]]; then
    printf 'Skipping bundled_basic consumer: Linux LocalCommand backend is unavailable on this host.\n'
    continue
  fi

  fixture_dir="$work_root/$fixture"
  mkdir -p "$fixture_dir/lib"
  cp -R "$script_dir/../test/agent_runtime_packages/$fixture/." "$fixture_dir/"
  use_candidate_mcp "$fixture_dir/mix.exs" consumer

  (
    cd "$fixture_dir"
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" deps.get
    # Prove normal compilation does not require the optional C compiler.
    AGENT_RUNTIME_PATH="$unpacked" CC=false MIX_ENV=prod "${mix_command[@]}" compile --warnings-as-errors
    if [[ "$fixture" == "pty_basic" ]]; then
      AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" backplane.pty.build
    fi
    module="$(printf '%s' "$fixture" | awk -F_ '{for (i=1; i<=NF; i++) printf "%s", toupper(substr($i,1,1)) substr($i,2)}')"
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" run -e "$module.verify!()"
  )

  test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"
done

if [[ "$pty_package_only" == "1" ]]; then
  printf 'Native PTY source/package checks passed for artifact %s (%s).\n' "$artifact" "$artifact_hash"
  exit 0
fi

(
  cd "$work_root/empty_tool"
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod \
    "${mix_command[@]}" run "$unpacked/examples/embedded.exs"
)
test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"

codex_example_output="$(
  cd "$work_root/empty_tool"
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod \
    "${mix_command[@]}" run "$unpacked/examples/codex_local.exs"
)"
printf '%s\n' "$codex_example_output"
if ! grep -q 'Codex Conversation example: PASS' <<<"$codex_example_output"; then
  printf 'Codex example did not verify the public Conversation path.\n' >&2
  exit 1
fi
test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"

conversation_fixture="$work_root/conversation"
mkdir -p "$conversation_fixture/test/backplane/agent_runtime"
mkdir -p "$conversation_fixture/test/fixtures"
cp -R "$script_dir/../test/agent_runtime_packages/conversation/." "$conversation_fixture/"
use_candidate_mcp "$conversation_fixture/mix.exs" consumer
cp "$source_dir/test/backplane/agent_runtime/conversation_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/conversation_test.exs"
cp "$source_dir/test/backplane/agent_runtime/conversation_rejections_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/conversation_rejections_test.exs"
cp "$source_dir/test/backplane/agent_runtime/provider_output_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/provider_output_test.exs"
cp "$source_dir/test/backplane/agent_runtime/input_schema_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/input_schema_test.exs"
cp "$source_dir/test/backplane/agent_runtime/store_conformance_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/store_conformance_test.exs"
mkdir -p "$conversation_fixture/test/backplane/agent_runtime/codex"
for collaboration_test in codex_multi_agent_profile_test.exs codex_multi_agent_close_test.exs conversation_multi_agent_rejections_test.exs; do
  cp "$source_dir/test/backplane/agent_runtime/$collaboration_test" \
    "$conversation_fixture/test/backplane/agent_runtime/$collaboration_test"
done
for collaboration_test in multi_agent_v2_lifecycle_test.exs multi_agent_observer_test.exs multi_agent_mailbox_test.exs multi_agent_birth_test.exs multi_agent_rejection_proofs_test.exs; do
  cp "$source_dir/test/backplane/agent_runtime/codex/$collaboration_test" \
    "$conversation_fixture/test/backplane/agent_runtime/codex/$collaboration_test"
done
cp "$source_dir/test/fixtures/sigma_builtin_tool_schemas.exs" \
  "$conversation_fixture/test/fixtures/sigma_builtin_tool_schemas.exs"
cp "$source_dir/test/fixtures/issue_46_tool_schemas.exs" \
  "$conversation_fixture/test/fixtures/issue_46_tool_schemas.exs"
cp "$source_dir/test/fixtures/issue_46_live_catalog.json" \
  "$conversation_fixture/test/fixtures/issue_46_live_catalog.json"

(
  cd "$conversation_fixture"
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=test "${mix_command[@]}" deps.get
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=test "${mix_command[@]}" compile --warnings-as-errors
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=test "${mix_command[@]}" test
)
test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"

if [[ -d "$sigma_source/apps/sigma_ai" && -d "$sigma_source/apps/sigma_coding" ]]; then
  # Sigma's provider validates tool calls through its separate AI Protocol dependency.
  # Supply that actual package to the consumer without adding it to Runtime itself.
  ai_protocol_artifact="$work_root/backplane_ai_protocol.tar"
  ai_protocol_unpacked="$work_root/ai_protocol"
  (
    cd "$script_dir/../apps/backplane_ai_protocol"
    MIX_ENV=prod "${mix_command[@]}" hex.build --output "$ai_protocol_artifact"
  )
  mkdir -p "$ai_protocol_unpacked"
  tar -xf "$ai_protocol_artifact" -O contents.tar.gz | tar -xz -C "$ai_protocol_unpacked"

  sigma_fixture="$work_root/sigma_source"
  mkdir -p "$sigma_fixture/lib"
  cp -R "$script_dir/../test/agent_runtime_packages/sigma_source/." "$sigma_fixture/"
  use_candidate_mcp "$sigma_fixture/mix.exs" consumer

  (
    cd "$sigma_fixture"
    export AGENT_RUNTIME_PATH="$unpacked" AI_PROTOCOL_PATH="$ai_protocol_unpacked"
    MIX_ENV=prod "${mix_command[@]}" deps.get
    MIX_ENV=prod "${mix_command[@]}" compile --warnings-as-errors
    SIGMA_SOURCE="$sigma_source" MIX_ENV=prod \
      "${mix_command[@]}" run -e 'SigmaSource.verify!()'
  )

  sigma_revision="$(git -C "$sigma_source" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  printf 'Read-only Sigma source probe passed at %s.\n' "$sigma_revision"
  test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"
else
  printf 'Skipping optional Sigma source probe; checkout not found at %s.\n' "$sigma_source"
fi

printf 'Agent runtime package checks passed for artifact %s (%s).\n' "$artifact" "$artifact_hash"
