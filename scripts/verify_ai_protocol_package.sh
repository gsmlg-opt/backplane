#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="$repo_root/apps/backplane_ai_protocol"
consumer_fixture="$repo_root/test/ai_protocol_packages/google_codec_consumer"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/backplane-ai-protocol.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

mkdir -p "$repo_root/tmp"
artifact_root="$(mktemp -d "$repo_root/tmp/ai-protocol-package.XXXXXX")"
artifact="$artifact_root/backplane_ai_protocol-1.7.0.tar"
unpacked="$artifact_root/unpacked"

(
  cd "$package_root"
  mix hex.build --output "$artifact"
)

test -f "$artifact"
tar -tf "$artifact" | grep -qx 'contents.tar.gz'
artifact_checksum_before="$(shasum -a 256 "$artifact" | awk '{print $1}')"
mkdir -p "$unpacked"
tar -xOf "$artifact" contents.tar.gz | tar -xz -C "$unpacked"
test -f "$unpacked/mix.exs"
test -f "$unpacked/lib/backplane/ai_protocol/codec/google.ex"

consumer="$work_root/google_codec_consumer"
cp -R "$consumer_fixture" "$consumer"

(
  cd "$consumer"
  export AI_PROTOCOL_PACKAGE_PATH="$unpacked"
  MIX_ENV=test mix deps.get
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix test

  deps_tree="$work_root/consumer-deps-tree.txt"
  MIX_ENV=prod mix deps.tree >"$deps_tree"
  grep -q backplane_ai_protocol "$deps_tree"

  if grep -Eq 'backplane_(system|llama|api|admin)|ecto|postgrex|phoenix' "$deps_tree"; then
    echo "consumer unexpectedly pulled a Backplane host, database, or Phoenix dependency" >&2
    exit 1
  fi
)

artifact_checksum_after="$(shasum -a 256 "$artifact" | awk '{print $1}')"
test "$artifact_checksum_before" = "$artifact_checksum_after"
echo "AI Protocol package artifact: $artifact"
echo "AI Protocol package SHA-256: $artifact_checksum_after"
echo "AI Protocol packaged consumer verification passed"
