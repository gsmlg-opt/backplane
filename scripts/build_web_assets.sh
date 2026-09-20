#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mix do --app backplane_api phx.digest.clean
mix do --app backplane_admin phx.digest.clean

mix duskmoon_bundler.build backplane_api --tailwind
mix duskmoon_bundler.build backplane_admin --tailwind

mix do --app backplane_api phx.digest
mix do --app backplane_admin phx.digest

elixir -pa "_build/${MIX_ENV:-dev}/lib/jason/ebin" \
  scripts/verify_web_assets.exs --source .
