#!/usr/bin/env bash
# Sets one unified version across the umbrella: the root mix.exs, every
# apps/*/mix.exs, and published backplane_mcp_protocol install examples.
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

for file in \
  apps/backplane_mcp_protocol/README.md \
  apps/backplane_mcp_protocol/pages/introduction.md \
  apps/backplane_mcp_protocol/pages/building-a-server.md; do
  sed -i.bak -E \
    "s/(backplane_mcp_protocol, \"~> )[^\"]+/\1$version/" \
    "$file"
  rm -f "$file.bak"

  if ! grep -Fq "backplane_mcp_protocol, \"~> $version\"" "$file"; then
    echo "No backplane_mcp_protocol install version updated in $file" >&2
    exit 1
  fi
done

echo "Set version $version in $updated mix.exs files"
