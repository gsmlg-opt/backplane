#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/backplane_agent_runtime" && pwd)"
tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/backplane_agent_tools" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$runtime_dir"
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix hex.build

cd "$tools_dir"
mix format --check-formatted
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix hex.build

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

runtime_artifact="$work_root/backplane_agent_runtime-0.1.0.tar"
tools_artifact="$work_root/backplane_agent_tools-0.1.0.tar"

mkdir -p "$work_root/local_hex/backplane_agent_runtime"
mkdir -p "$work_root/local_hex/backplane_agent_tools"

tar -xf "$runtime_dir/backplane_agent_runtime-0.1.0.tar" -O contents.tar.gz | \
  tar -xz -C "$work_root/local_hex/backplane_agent_runtime"
tar -xf "$tools_dir/backplane_agent_tools-0.1.0.tar" -O contents.tar.gz | \
  tar -xz -C "$work_root/local_hex/backplane_agent_tools"

for fixture in runtime_only runtime_plus_tools; do
  fixture_dir="$work_root/$fixture"
  mkdir -p "$fixture_dir/lib"
  cp -R "$script_dir/../test/agent_runtime_packages/$fixture/." "$fixture_dir/"

  runtime_path="$work_root/local_hex/backplane_agent_runtime"
  tools_path="$work_root/local_hex/backplane_agent_tools"

  sed -i.bak \
    -e "s#path: [\"'][^\"']*[\"']#path: \"$runtime_path\"#g" \
    -e "s#path: [\"'][^\"']*[\"']#path: \"$tools_path\"#g" \
    "$fixture_dir/mix.exs"
  rm "$fixture_dir/mix.exs.bak"

  (cd "$fixture_dir" && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile --warnings-as-errors && MIX_ENV=prod mix run -e 'IO.puts("artifact consumer passed")')
done

printf 'Agent runtime package checks passed.\n'
