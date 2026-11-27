#!/bin/sh
set -eu

# Only shell builtins are used before exec; runtime tools need not be on PATH.
case "$0" in
  */*) launcher_dir=${0%/*} ;;
  *) launcher_dir=. ;;
esac
ROOTDIR=$(CDPATH= cd -- "$launcher_dir/.." && pwd -P)
BINDIR="$ROOTDIR/erts-@ERTS_VERSION@/bin"
EMU=beam
PROGNAME=backplane-code-mode-runner
export ROOTDIR BINDIR EMU PROGNAME
PATH=
export PATH

# Do not inherit code paths, flags, distribution or configuration from the host.
unset ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_LIBS ERL_INETRC
exec "$BINDIR/erlexec" \
  +S 1:1 +SDcpu 1 +SDio 1 +A 1 \
  -noshell -noinput \
  -config "$ROOTDIR/releases/runner" \
  -boot "$ROOTDIR/releases/backplane_code_mode_runner" \
  -boot_var RUNNER_LIB "$ROOTDIR/lib" \
  -s Elixir.Backplane.AgentRuntime.Codex.CodeMode.Runner main
