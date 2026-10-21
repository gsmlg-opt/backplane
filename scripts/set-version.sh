#!/usr/bin/env bash
# Sets the root version and selected app versions. With no app selection (or
# "all"), updates every app and the backplane_mcp_protocol install examples.
#
# Usage: scripts/set-version.sh <version> [all | app ...] (leading "v" is stripped)
set -euo pipefail

version="${1:?usage: scripts/set-version.sh <version> [all | app ...]}"
version="${version#v}"
shift

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.+-]+)?$ ]]; then
  echo "Invalid semantic version: $version" >&2
  exit 1
fi

files=(mix.exs)
update_mcp_examples=false

if [[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == "all" ) ]]; then
  files+=(apps/*/mix.exs)
  update_mcp_examples=true
else
  for app in "$@"; do
    if [[ ! "$app" =~ ^[a-z][a-z0-9_]*$ || "$app" == "all" || ! -f "apps/$app/mix.exs" ]]; then
      echo "Invalid or unknown app: $app" >&2
      exit 1
    fi

    files+=("apps/$app/mix.exs")
    if [[ "$app" == "backplane_mcp_protocol" ]]; then
      update_mcp_examples=true
    fi
  done
fi

examples=(
  apps/backplane_mcp_protocol/README.md
  apps/backplane_mcp_protocol/pages/introduction.md
  apps/backplane_mcp_protocol/pages/building-a-server.md
)

# Validate the complete selection before changing even the root manifest.
for file in "${files[@]}"; do
  if [[ ! -f "$file" ]] || ! grep -Eq '^[[:space:]]*(version:[[:space:]]*|@version[[:space:]]+)"[^"]+"' "$file"; then
    echo "No version field in $file" >&2
    exit 1
  fi
done

if [[ "$update_mcp_examples" == "true" ]]; then
  for file in "${examples[@]}"; do
    if [[ ! -f "$file" ]] || ! grep -Eq 'backplane_mcp_protocol, "~> [^"]+"' "$file"; then
      echo "No backplane_mcp_protocol install version in $file" >&2
      exit 1
    fi
  done
fi

updated=0

for file in "${files[@]}"; do
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

if [[ "$update_mcp_examples" == "true" ]]; then
  for file in "${examples[@]}"; do
    sed -i.bak -E \
      "s/(backplane_mcp_protocol, \"~> )[^\"]+/\1$version/" \
      "$file"
    rm -f "$file.bak"

    if ! grep -Fq "backplane_mcp_protocol, \"~> $version\"" "$file"; then
      echo "No backplane_mcp_protocol install version updated in $file" >&2
      exit 1
    fi
  done
fi

echo "Set version $version in $updated mix.exs files"
