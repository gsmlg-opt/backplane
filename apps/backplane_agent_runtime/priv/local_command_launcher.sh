#!/bin/sh
set -eu

prefix=BACKPLANE_LOCAL_COMMAND
nonce=$1
shift

printf '%s %s %s\n' "$prefix" "$nonce" "$$"

if ! IFS= read -r acknowledgement; then
  exit 125
fi

if [ "$acknowledgement" != "$prefix ACK $nonce $$" ]; then
  exit 126
fi

exec "$@"
