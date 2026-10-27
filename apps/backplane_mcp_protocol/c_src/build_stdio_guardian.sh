#!/bin/sh
set -eu
case "$(uname -s)" in Linux|Darwin) ;; *) echo 'Verified MCP stdio requires Linux or macOS' >&2; exit 1 ;; esac
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/../priv/bin/backplane-mcp-stdio-guardian"}
mkdir -p "$(dirname -- "$output")"
staged="$output.tmp.$$"
trap 'rm -f -- "$staged"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror "$source_dir/stdio_guardian.c" -o "$staged"
chmod 755 "$staged"
"$staged" --probe
mv -f -- "$staged" "$output"
