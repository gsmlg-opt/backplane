#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
source_dir="$work_root/source"
unpacked="$work_root/unpacked"
artifact="$work_root/backplane_mcp_protocol.tar"
mkdir -p "$source_dir" "$unpacked"
tar -C "$repo_root/apps/backplane_mcp_protocol" \
  --exclude='./_build' --exclude='./deps' --exclude='./doc' --exclude='./tmp' \
  --exclude='./priv/bin/backplane-mcp-stdio-guardian*' --exclude='*.tar' -cf - . \
  | tar -xf - -C "$source_dir"

(
  cd "$source_dir"
  MIX_ENV=prod mix deps.get
  CC=false MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix hex.build --output "$artifact"
)
tar -xf "$artifact" -O contents.tar.gz | tar -xz -C "$unpacked"
test -f "$unpacked/c_src/stdio_guardian.c"
test -f "$unpacked/c_src/build_stdio_guardian.sh"
test -f "$unpacked/lib/mix/tasks/backplane.mcp.stdio.build.ex"
test ! -e "$unpacked/priv/bin/backplane-mcp-stdio-guardian"

mkdir -p "$work_root/consumer"
cp -R "$repo_root/test/mcp_protocol_packages/server/." "$work_root/consumer/"
(
  cd "$work_root/consumer"
  export MCP_PROTOCOL_PATH="$unpacked" MIX_ENV=prod
  mix deps.get
  CC=false mix compile --warnings-as-errors
  mix backplane.mcp.stdio.build
  mix run verify.exs
)

(
  cd "$source_dir"
  MIX_ENV=test mix deps.get
  MIX_ENV=test mix backplane.mcp.stdio.build
  python3 test/native/stdio_guardian_protocol_test.py priv/bin/backplane-mcp-stdio-guardian
  MIX_ENV=test mix test test/backplane/mcp_protocol/transport/stdio_cleanup_test.exs
)

printf 'MCP extracted package, standalone dependency graph and native cleanup checks passed.\n'
