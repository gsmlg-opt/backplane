#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/backplane_agent_runtime" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
artifact="$work_root/backplane_agent_runtime.tar"
unpacked="$work_root/unpacked"
source_dir="$work_root/source"

if command -v unbuffer >/dev/null 2>&1; then
  mix_command=(unbuffer mix)
else
  mix_command=(mix)
fi

sigma_source="${SIGMA_SOURCE:-$script_dir/../../sigma}"
require_sigma_source="${REQUIRE_SIGMA_SOURCE:-0}"

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
  --exclude='./tmp' --exclude='*.tar' -cf - . | tar -xf - -C "$source_dir"
cd "$source_dir"
MIX_ENV=dev "${mix_command[@]}" deps.get
MIX_ENV=dev "${mix_command[@]}" format --check-formatted
MIX_ENV=dev "${mix_command[@]}" compile --warnings-as-errors
MIX_ENV=dev "${mix_command[@]}" docs --warnings-as-errors
MIX_ENV=test "${mix_command[@]}" test
MIX_ENV=dev "${mix_command[@]}" hex.build --output "$artifact"

mkdir -p "$unpacked"
tar -xf "$artifact" -O contents.tar.gz | tar -xz -C "$unpacked"

test -f "$unpacked/lib/backplane/agent_runtime/tools/local_resource.ex"
test -f "$unpacked/lib/backplane/agent_runtime/tools/local_command.ex"
test -f "$unpacked/priv/local_command_launcher.sh"
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
if rg -n 'in_umbrella:|path:' "$unpacked/mix.exs"; then
  printf 'The artifact Mix manifest contains an umbrella source dependency.\n' >&2
  exit 1
fi

dependencies="$(cd "$unpacked" && MIX_ENV=prod "${mix_command[@]}" deps)"
if [[ -n "$dependencies" ]]; then
  printf 'The artifact unexpectedly resolves production dependencies:\n%s\n' "$dependencies" >&2
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

for fixture in empty_tool bundled_basic fake_backend; do
  fixture_dir="$work_root/$fixture"
  mkdir -p "$fixture_dir/lib"
  cp -R "$script_dir/../test/agent_runtime_packages/$fixture/." "$fixture_dir/"

  (
    cd "$fixture_dir"
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" deps.get
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" compile --warnings-as-errors
    module="$(printf '%s' "$fixture" | awk -F_ '{for (i=1; i<=NF; i++) printf "%s", toupper(substr($i,1,1)) substr($i,2)}')"
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" run -e "$module.verify!()"
  )

  test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"
done

(
  cd "$work_root/empty_tool"
  AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod \
    "${mix_command[@]}" run "$unpacked/examples/embedded.exs"
)
test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"

conversation_fixture="$work_root/conversation"
mkdir -p "$conversation_fixture/test/backplane/agent_runtime"
mkdir -p "$conversation_fixture/test/fixtures"
cp -R "$script_dir/../test/agent_runtime_packages/conversation/." "$conversation_fixture/"
cp "$source_dir/test/backplane/agent_runtime/conversation_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/conversation_test.exs"
cp "$source_dir/test/backplane/agent_runtime/input_schema_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/input_schema_test.exs"
cp "$source_dir/test/backplane/agent_runtime/store_conformance_test.exs" \
  "$conversation_fixture/test/backplane/agent_runtime/store_conformance_test.exs"
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
  sigma_fixture="$work_root/sigma_source"
  mkdir -p "$sigma_fixture/lib"
  cp -R "$script_dir/../test/agent_runtime_packages/sigma_source/." "$sigma_fixture/"

  (
    cd "$sigma_fixture"
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" deps.get
    AGENT_RUNTIME_PATH="$unpacked" MIX_ENV=prod "${mix_command[@]}" compile --warnings-as-errors
    AGENT_RUNTIME_PATH="$unpacked" SIGMA_SOURCE="$sigma_source" MIX_ENV=prod \
      "${mix_command[@]}" run -e 'SigmaSource.verify!()'
  )

  sigma_revision="$(git -C "$sigma_source" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  printf 'Read-only Sigma source probe passed at %s.\n' "$sigma_revision"
  test "$(sha256sum "$artifact" | cut -d ' ' -f 1)" = "$artifact_hash"
else
  printf 'Skipping optional Sigma source probe; checkout not found at %s.\n' "$sigma_source"
fi

printf 'Agent runtime package checks passed for artifact %s (%s).\n' "$artifact" "$artifact_hash"
