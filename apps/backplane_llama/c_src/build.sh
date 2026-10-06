#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/../priv/bin/backplane-audio-launcher"}
mkdir -p "$(dirname -- "$output")"
staging="$output.tmp.$$"
trap 'rm -f "$staging"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror "$source_dir/audio_launcher.c" -o "$staging"
chmod 755 "$staging"
mv -f "$staging" "$output"
