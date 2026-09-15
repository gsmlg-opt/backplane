#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/backplane_agent_runtime" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
artifact="$work_root/backplane_agent_runtime.tar"
unpacked="$work_root/unpacked"

if command -v unbuffer >/dev/null 2>&1; then
  mix_command=(unbuffer mix)
else
  mix_command=(mix)
fi

cd "$runtime_dir"
"${mix_command[@]}" format --check-formatted
"${mix_command[@]}" compile --warnings-as-errors
"${mix_command[@]}" test
"${mix_command[@]}" hex.build --output "$artifact"

mkdir -p "$unpacked"
tar -xf "$artifact" -O contents.tar.gz | tar -xz -C "$unpacked"

test -f "$unpacked/lib/backplane/agent_runtime/tools/local_resource.ex"
test -f "$unpacked/lib/backplane/agent_runtime/tools/local_command.ex"
test -f "$unpacked/priv/local_command_launcher.sh"
test -f "$unpacked/CHANGELOG.md"
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

printf 'Agent runtime package checks passed for artifact %s (%s).\n' "$artifact" "$artifact_hash"
