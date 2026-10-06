# Audio native launcher

Build with `sh apps/backplane_llama/c_src/build.sh`. The app's custom Mix compiler
always rebuilds for the current target and atomically replaces
`priv/bin/backplane-audio-launcher`; generated host binaries are not source files.
Requires a C11 compiler and target OS headers; no Python production dependency.

Run the standalone native gate:

```sh
python3 apps/backplane_llama/c_src/launcher_test.py \
  "$PWD/apps/backplane_llama/priv/bin/backplane-audio-launcher" \
  "$(command -v ffmpeg)" "$(command -v ffprobe)"
```

Run Linux tests as the same unprivileged UID model as the gateway release, on
native arm64 and amd64 hosts. User-mode CPU emulation cannot establish native
seccomp ABI compatibility. No privileged containers or extra capabilities are
required. Landlock ABI 3 or newer is mandatory; unavailable confinement fails
closed.

The command accepts separate `--mode`, `--workdir`, `--deadline-ms`,
`--max-file-bytes`, `--stderr-bytes` tokens, followed by `--` and a trusted absolute
executable plus fixed argument vector. Workdir and its parent must be canonical,
owned by the invoking UID, and private (0700). Media is file-backed, stdout goes
to `/dev/null`, stderr is a bounded tail of at most 4096 bytes. The file limit is
per written file and does not reject larger pre-existing read-only inputs.

The guardian alone reads packet4 stdin. EOF or a cancellation packet cancels the
worker. Packet4 output is `S + u32be PID + u32be PGID`, optional `D + diagnostic`,
optional `E + stable code`, then `X + u32be exit + u8 signal + u8 cleanup`. Errors
include `resource_limit` for Darwin's sampled memory/thread enforcement. Cleanup
0 always means quarantine; an unknown exit status uses `UINT32_MAX`. Never
release resources merely on receiving E or on the initial helper exiting.

The initial helper owns a private lifeline pipe. Its death leaves a guardian to
terminate and reap the media worker. The guardian holds the unreaped group leader
while sending the final group kill, preventing PID/PGID reuse during cleanup.
Linux additionally sets the worker's parent-death signal. Workers cannot fork or
leave their process group. The guardian writes the atomic mode0600 sibling
`<workdir>.cleanup-confirmed` only after reap, outside the worker's writable tree;
old evidence is removed before launch. The caller must serialize use of a
workdir and quarantine missing evidence after helper failure.

Linux uses exact executable/resolved-library Landlock rules, a minimal exec
environment, architecture-checked seccomp, and kernel AS/CPU/FSIZE/NOFILE/CORE/
NPROC limits. Seccomp permits libc threads. It rejects process creation, network
sockets, process-group changes, signals to unrelated processes, ptrace, io_uring,
and alternate syscall ABIs. NPROC is a per-UID kernel bound; it is not a
per-request thread quota and privileged UIDs can bypass it. Production must use
an unprivileged dedicated gateway UID.

Darwin uses sandbox-exec with exact non-system library paths, OS library/cache
roots, no Mach service lookup, and no network or process fork. Reading the root
directory itself is needed by dyld; recursive root access is not allowed. Darwin
rejects usable RLIMIT_AS limits, so the guardian checks RSS <= 2 GiB and <= 64
threads every approximately 20 ms. This is sampled enforcement with possible
overshoot, unlike Linux's hard address-space limit. CPU/file/fd/core limits apply
on both platforms. No shell or uploaded filename enters command construction.

`selftest` executes the launcher's own denial checks under identical confinement;
readiness must additionally exercise actual FFmpeg/ffprobe codec capabilities.
