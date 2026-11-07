#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
source_dir="$work_root/source"
unpacked="$work_root/unpacked"
artifact="$work_root/backplane_mcp_protocol.tar"

candidate_schema="${SCHEMA_SOURCE-$repo_root/apps/backplane_schema}"
if [[ -n "$candidate_schema" ]]; then
  test -f "$candidate_schema/mix.exs"
  mkdir -p "$work_root/schema-source" "$work_root/schema-package"
  tar -C "$candidate_schema" --exclude='./_build' --exclude='./deps' --exclude='./doc' \
    --exclude='./tmp' --exclude='*.tar' -cf - . \
    | tar -xf - -C "$work_root/schema-source"
  (cd "$work_root/schema-source" && MIX_ENV=prod mix hex.build --output "$work_root/schema.tar")
  tar -xf "$work_root/schema.tar" -O contents.tar.gz | tar -xz -C "$work_root/schema-package"
  export SCHEMA_SOURCE="$work_root/schema-package"
fi

use_candidate_schema() {
  if [[ -z "$candidate_schema" ]]; then return; fi
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
if sys.argv[2] == "source":
    needle = '      {:backplane_schema, "~> 1.10.58"}'
    replacement = '      if(System.get_env("SCHEMA_SOURCE"), do: {:backplane_schema, path: System.fetch_env!("SCHEMA_SOURCE"), override: true}, else: {:backplane_schema, "~> 1.10.58"})'
else:
    needle = '[protocol, {:plug, "~> 1.18"}, {:gaoxy_http, "~> 0.15.0"}]'
    replacement = '[protocol, {:backplane_schema, path: System.fetch_env!("SCHEMA_SOURCE"), override: true}, {:plug, "~> 1.18"}, {:gaoxy_http, "~> 0.15.0"}]'
if text.count(needle) != 1:
    raise SystemExit("candidate schema qualification marker is missing or ambiguous")
path.write_text(text.replace(needle, replacement))
PY
}

mkdir -p "$source_dir" "$unpacked"
tar -C "$repo_root/apps/backplane_mcp_protocol" \
  --exclude='./_build' --exclude='./deps' --exclude='./doc' --exclude='./tmp' \
  --exclude='./priv/bin/backplane-mcp-stdio-guardian*' --exclude='*.tar' -cf - . \
  | tar -xf - -C "$source_dir"

(
  cd "$source_dir"
  MIX_ENV=prod mix hex.build --output "$artifact"
  use_candidate_schema "$source_dir/mix.exs" source
  MIX_ENV=prod mix deps.get
  CC=false MIX_ENV=prod mix compile --warnings-as-errors
)
tar -xf "$artifact" -O contents.tar.gz | tar -xz -C "$unpacked"
test -f "$unpacked/c_src/stdio_guardian.c"
test -f "$unpacked/c_src/build_stdio_guardian.sh"
test -f "$unpacked/lib/mix/tasks/backplane.mcp.stdio.build.ex"
test ! -e "$unpacked/priv/bin/backplane-mcp-stdio-guardian"

mkdir -p "$work_root/consumer"
cp -R "$repo_root/test/mcp_protocol_packages/server/." "$work_root/consumer/"
use_candidate_schema "$work_root/consumer/mix.exs" consumer
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
