#!/usr/bin/env sh
set -eu
if [ "$(uname -s)" != Linux ]; then
  echo 'The optional LocalCommand PTY helper requires Linux.' >&2
  exit 1
fi
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/../priv/bin/backplane-local-command-pty"}
mkdir -p "$(dirname -- "$output")"
artifact=$(mktemp "${output}.tmp.XXXXXX")
trap 'rm -f "$artifact"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 \
  "$source_dir/local_command_pty.c" -o "$artifact"
chmod 755 "$artifact"
"$artifact" --probe
mv -f "$artifact" "$output"
