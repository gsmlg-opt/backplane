#!/usr/bin/env sh
set -eu
case "$(uname -s)" in Linux|Darwin) ;; *) echo 'LocalCommand requires Linux or macOS.' >&2; exit 1 ;; esac
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/../priv/bin/backplane-local-command-session"}
mkdir -p "$(dirname -- "$output")"
artifact=$(mktemp "${output}.tmp.XXXXXX")
trap 'rm -f "$artifact"' EXIT HUP INT TERM
set -- "$source_dir/local_command_session.c"
if [ "$(uname -s)" = Darwin ]; then
  set -- "$@" "$source_dir/local_command_pipe_macos.c" -lproc
fi
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 \
  "$@" -o "$artifact"
chmod 755 "$artifact"
"$artifact" --probe
if [ "$(uname -s)" = Darwin ]; then "$artifact" --probe-pipe; fi
mv -f "$artifact" "$output"
