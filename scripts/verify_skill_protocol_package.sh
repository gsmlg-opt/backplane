#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="$repo_root/apps/backplane_skill_protocol"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/backplane-skill-protocol.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT
mkdir -p "$repo_root/tmp"
artifact_root="$(mktemp -d "$repo_root/tmp/skill-protocol-package.XXXXXX")"

copy_package() {
  local destination="$1"
  mkdir -p "$destination"
  tar -C "$package_root" \
    --exclude='./_build' --exclude='./deps' --exclude='./tmp' --exclude='./mix.lock' \
    -cf - . | tar -C "$destination" -xf -
}

copied="$work_root/copied-package"
copy_package "$copied"
(
  cd "$copied"
  mix deps.get
  mix compile --warnings-as-errors
  mix test
  MIX_ENV=prod mix compile --warnings-as-errors

  artifact="$artifact_root/backplane_skill_protocol-0.1.0.tar"
  unpacked="$artifact_root/unpacked"
  mix hex.build --output "$artifact"
  mix hex.build --unpack --output "$unpacked"

  test -f "$artifact"
  tar -tf "$artifact" | grep -qx 'contents.tar.gz'
  test -f "$unpacked/README.md"
  test -f "$unpacked/priv/schemas/catalog-v1.schema.json"
  test ! -e "$unpacked/c_src"
  test ! -e "$unpacked/Makefile"
  test ! -e "$unpacked/lib/backplane/skill_protocol/cache"
  test ! -e "$unpacked/priv/cache_native_lock.so"
)

snapshot="$work_root/source"
copy_package "$snapshot/apps/backplane_skill_protocol"
(
  cd "$snapshot"
  git init -q
  git config user.email verifier@backplane.invalid
  git config user.name "Backplane verifier"
  git add apps/backplane_skill_protocol
  git commit -qm "test: snapshot skill protocol package"
)
snapshot_ref="$(git -C "$snapshot" rev-parse HEAD)"

consumer="$work_root/consumer"
(
  cd "$work_root"
  mix new consumer --sup >/dev/null
)
apply_mix="$consumer/mix.exs"
SKILL_PROTOCOL_SNAPSHOT="$snapshot" SKILL_PROTOCOL_REF="$snapshot_ref" \
  perl -0pi -e 's{defp deps do\n    \[\n}{defp deps do\n    [\n      {:backplane_skill_protocol, git: "$ENV{SKILL_PROTOCOL_SNAPSHOT}", sparse: "apps/backplane_skill_protocol", ref: "$ENV{SKILL_PROTOCOL_REF}"},\n}' "$apply_mix"

(
  cd "$consumer"
  MIX_ENV=prod mix deps.get
  MIX_ENV=prod mix compile --warnings-as-errors
  SKILL_PROTOCOL_VERIFY_ROOT="$work_root/consumer-verification" \
    MIX_ENV=prod mix run "$repo_root/scripts/skill_protocol_consumer_verify.exs"
  deps_tree="$work_root/consumer-deps-tree.txt"
  mix deps.tree >"$deps_tree"
  grep -q backplane_skill_protocol "$deps_tree"
  if grep -Eq 'backplane_(skills|system)|ecto|postgrex|phoenix' "$deps_tree"; then
    echo "consumer unexpectedly pulled a Backplane host or database dependency" >&2
    exit 1
  fi
)

artifact="$artifact_root/backplane_skill_protocol-0.1.0.tar"
checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"
echo "Skill Protocol package artifact: $artifact"
echo "Skill Protocol package SHA-256: $checksum"
echo "Skill Protocol copied-package and Git-subdirectory consumer verification passed"
