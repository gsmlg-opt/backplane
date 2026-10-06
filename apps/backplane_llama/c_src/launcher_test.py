"""Standalone native gate; Python is a test dependency only.
Run: python3 launcher_test.py ABS_LAUNCHER ABS_FFMPEG ABS_FFPROBE
"""
import os
import pathlib
import signal
import struct
import subprocess
import sys
import tempfile
import time

launcher, ffmpeg, ffprobe = map(os.path.realpath, sys.argv[1:4])


def start(root, mode, target, args=(), deadline=3000, limit=1000000):
    return subprocess.Popen([launcher, '--mode', mode, '--workdir', root,
        '--deadline-ms', str(deadline), '--max-file-bytes', str(limit),
        '--stderr-bytes', '4096', '--', target, *args],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, 'AUDIO_TEST_SECRET': 'must-not-reach-worker'})


def frame(p):
    size = p.stdout.read(4)
    if not size:
        return None
    assert len(size) == 4
    n, = struct.unpack('!I', size)
    assert 1 <= n <= 4100, n
    data = p.stdout.read(n)
    assert len(data) == n
    return data


def finish(p):
    frames = []
    while (f := frame(p)) is not None:
        frames.append(f)
    p.wait(timeout=5)
    errors = p.stderr.read()
    assert not errors, errors
    terminal = [f for f in frames if f[:1] == b'X']
    assert len(terminal) == 1, frames
    assert len(terminal[0]) == 7 and terminal[0][-1] == 1, frames
    assert sum(len(f) - 1 for f in frames if f[:1] == b'D') <= 4096
    return frames


def success(frames):
    assert not [f for f in frames if f[:1] == b'E'], frames
    assert frames[-1] == b'X' + struct.pack('!I', 0) + b'\x00\x01', frames


def live(pid):
    # A reparented zombie is not a live media worker.
    r = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
    return bool(r.stdout.strip()) and not r.stdout.strip().startswith('Z')


with tempfile.TemporaryDirectory(prefix='audio-native-') as parent:
    root = os.path.join(parent, 'worker')
    os.mkdir(root, 0o700)
    success(finish(start(root, 'selftest', launcher)))
    marker = pathlib.Path(root + '.cleanup-confirmed')
    assert marker.read_text() == 'clean\n'
    assert marker.stat().st_mode & 0o777 == 0o600
    print('PASS confinement/selftest and unforgeable cleanup sidecar', flush=True)
    out = os.path.join(root, 'sample.wav')
    success(finish(start(root, 'convert', ffmpeg, ['-nostdin', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1', '-threads', '1', '-y', out], deadline=10000)))
    assert pathlib.Path(out).read_bytes().startswith(b'RIFF')
    report = os.path.join(root, 'probe.json')
    success(finish(start(root, 'probe', ffprobe, ['-v', 'error', '-show_format', '-show_streams',
        '-of', 'json', '-o', report, out], deadline=10000)))
    assert b'pcm_s16le' in pathlib.Path(report).read_bytes()
    print('PASS real ffmpeg/ffprobe', flush=True)
    for action in ('cancel', 'eof', 'timeout', 'helper-kill'):
        p = start(root, 'convert', launcher, ['--internal-hold'], deadline=200 if action == 'timeout' else 10000)
        f = frame(p)
        assert f[:1] == b'S', f
        pid, pgid = struct.unpack('!II', f[1:])
        assert pid == pgid
        assert not marker.exists(), 'stale cleanup evidence survived launch'
        if action == 'cancel':
            p.stdin.write(b'\x00\x00\x00\x01C'); p.stdin.flush()
        elif action == 'eof':
            p.stdin.close()
        elif action == 'helper-kill':
            p.kill()
        frames = finish(p)
        assert any(f == b'E' + (b'timeout' if action == 'timeout' else b'cancelled') for f in frames), frames
        assert not live(pid), (action, pid)
        assert marker.read_text() == 'clean\n'
        print('PASS lifecycle ' + action, flush=True)
    frames = finish(start(root, 'convert', launcher, ['--internal-flood'], deadline=1000))
    assert any(f[:1] == b'D' for f in frames)
    print('PASS bounded diagnostics', flush=True)
    frames = finish(start(root, 'convert', launcher, ['--internal-large-file'], limit=8192))
    assert b'Eoutput_limit' in frames, frames
    assert pathlib.Path(root, 'large').stat().st_size <= 8192
    print('PASS output limit', flush=True)
    if sys.platform == 'darwin':
        frames = finish(start(root, 'convert', launcher, ['--internal-thread-flood']))
        assert b'Eresource_limit' in frames, frames
        assert marker.read_text() == 'clean\n'
        print('PASS sampled Darwin thread bound', flush=True)
