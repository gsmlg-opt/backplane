#!/usr/bin/env bash
# Sets one unified version across the Backplane release applications.
# backplane_mcp_protocol is an independently versioned Hex package and is skipped.
#
# Usage: scripts/set-version.sh <version>   (leading "v" is stripped)
set -euo pipefail

version="${1:?usage: scripts/set-version.sh <version>}"
version="${version#v}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.+-]+)?$ ]]; then
  echo "Invalid semantic version: $version" >&2
  exit 1
fi

updated=0

for file in mix.exs apps/*/mix.exs; do
  if [[ "$file" == "apps/backplane_mcp_protocol/mix.exs" ]]; then
    continue
  fi

  sed -i.bak -E \
    -e "s/^([[:space:]]*version:[[:space:]]*)\"[^\"]+\"/\1\"$version\"/" \
    -e "s/^([[:space:]]*@version[[:space:]]+)\"[^\"]+\"/\1\"$version\"/" \
    "$file"
  rm -f "$file.bak"

  if grep -Eq "^[[:space:]]*(version:[[:space:]]*|@version[[:space:]]+)\"$version\"" "$file"; then
    updated=$((updated + 1))
  else
    echo "No version field updated in $file" >&2
    exit 1
  fi
done

echo "Set version $version in $updated mix.exs files"
