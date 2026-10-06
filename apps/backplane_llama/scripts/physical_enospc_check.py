"""macOS physical ENOSPC check; only writes to a verified disposable 16 MiB RAM disk."""

import errno
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


if sys.platform != "darwin":
    raise SystemExit("This bounded RAM-disk check requires macOS hdiutil/diskutil")

device = None
try:
    attached = run("hdiutil", "attach", "-nomount", "ram://32768").decode()
    match = re.fullmatch(r"\s*(/dev/disk[0-9]+)\s*", attached)
    if not match:
        raise RuntimeError(f"Unexpected RAM-disk attachment response: {attached!r}")
    device = match.group(1)
    run("diskutil", "eraseVolume", "HFS+", "BPAudioENOSPC", device)
    info = plistlib.loads(run("diskutil", "info", "-plist", device))
    if not (0 < info["TotalSize"] <= 16 * 1024 * 1024):
        raise RuntimeError("Refusing to fill a volume outside the 16 MiB bound")
    mount = Path(info["MountPoint"])
    root = mount / "audio-root"
    root.mkdir(mode=0o700)
    (root / "marker-probe").mkdir(mode=0o700)
    fd = os.open(mount / "filler", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        written = 0
        for size in (65536, 512):
            while True:
                try:
                    written += os.write(fd, bytes(size))
                    if written > 16 * 1024 * 1024:
                        raise RuntimeError("RAM-disk fill exceeded its fixed bound")
                except OSError as error:
                    if error.errno != errno.ENOSPC:
                        raise
                    break
        os.fsync(fd)
    finally:
        os.close(fd)
    print(f"Physical RAM disk: capacity={info['TotalSize']} bytes; filler={written} bytes", flush=True)
    env = dict(os.environ, MIX_ENV="test", BACKPLANE_AUDIO_ENOSPC_ROOT=str(root))
    checker = Path(__file__).resolve().with_suffix(".exs")
    subprocess.run(
        ["mix", "run", str(checker)], cwd=checker.parent.parent, env=env, check=True
    )
finally:
    if device:
        run("hdiutil", "detach", device)
        print(f"Detached disposable RAM disk {device}", flush=True)
