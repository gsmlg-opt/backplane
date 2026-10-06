"""Standalone native gate; Python is a test dependency only.
Run: python3 launcher_test.py ABS_LAUNCHER ABS_FFMPEG ABS_FFPROBE
"""
import os
import pathlib
import resource
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


def pressure_failure(p, stderr):
    stderr.seek(0, os.SEEK_END)
    stderr.seek(max(stderr.tell() - 4096, 0))
    return {'returncode': p.poll(), 'stderr': stderr.read().decode('utf-8', errors='replace'),
        'host_nproc': resource.getrlimit(resource.RLIMIT_NPROC),
        'host_as': resource.getrlimit(resource.RLIMIT_AS)}


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
    source = os.path.join(root, 'input.media')
    success(finish(start(root, 'convert', ffmpeg, ['-nostdin', '-hide_banner', '-v', 'error',
        '-threads', '1', '-f', 'lavfi', '-i',
        'sine=frequency=440:sample_rate=24000:duration=0.5', '-c:a', 'flac', '-f', 'flac', source],
        deadline=10000)))
    report = os.path.join(root, 'probe.json')
    success(finish(start(root, 'probe', ffprobe, ['-v', 'error', '-protocol_whitelist', 'file,pipe',
        '-f', 'flac', '-show_streams', '-show_format', '-of', 'json', '-o', report, '-i', source],
        deadline=10000)))
    assert b'flac' in pathlib.Path(report).read_bytes()
    decoded = os.path.join(root, 'decoded.pcm')
    success(finish(start(root, 'convert', ffmpeg, ['-nostdin', '-hide_banner', '-v', 'error',
        '-threads', '1', '-filter_threads', '1', '-xerror', '-err_detect', 'explode',
        '-protocol_whitelist', 'file,pipe', '-f', 'flac', '-i', source, '-map', '0:a:0',
        '-vn', '-sn', '-dn', '-c:a', 'pcm_s16le', '-f', 's16le', decoded], deadline=10000)))
    assert pathlib.Path(decoded).stat().st_size > 0
    print('PASS bounded ffprobe and full decode pipeline', flush=True)
    if sys.platform == 'linux':
        # RLIMIT_NPROC counts every thread with the real UID, including BEAM.
        # Ordinary Python threads stay outside the media worker's guardian.
        pressure_code = """
import threading
hold = threading.Event()
threads = [threading.Thread(target=hold.wait) for _ in range(128)]
for thread in threads:
    thread.start()
hold.wait()
"""
        # Use CPython's platform default stack: tiny custom stacks are not
        # portable across architectures. A file prevents crash dumps filling a pipe.
        pressure_stderr = tempfile.TemporaryFile()
        pressure = subprocess.Popen([sys.executable, '-X', 'faulthandler', '-c', pressure_code],
            stdout=subprocess.DEVNULL, stderr=pressure_stderr)
        try:
            tasks = pathlib.Path(f'/proc/{pressure.pid}/task')
            until = time.monotonic() + 5
            while len(list(tasks.iterdir())) <= 64 and time.monotonic() < until:
                assert pressure.poll() is None, pressure_failure(pressure, pressure_stderr)
                time.sleep(0.01)
            assert len(list(tasks.iterdir())) > 64, pressure_failure(pressure, pressure_stderr)
            pressure_output = os.path.join(root, 'uid-pressure.wav')
            success(finish(start(root, 'convert', ffmpeg, ['-nostdin', '-v', 'error',
                '-f', 'lavfi', '-i', 'sine=duration=0.1', '-threads', '1',
                pressure_output], deadline=10000)))
            assert pathlib.Path(pressure_output).read_bytes().startswith(b'RIFF')
            print('PASS other same-UID threads do not consume the worker budget', flush=True)
        finally:
            pressure.terminate()
            try:
                pressure.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pressure.kill()
                pressure.wait(timeout=5)
            pressure_stderr.close()
    for action in ('cancel', 'eof', 'timeout', 'helper-kill'):
        p = start(root, 'convert', launcher, ['--internal-hold'], deadline=200 if action == 'timeout' else 10000)
        f = frame(p)
        assert f[:1] == b'S', f
        pid, pgid = struct.unpack('!II', f[1:])
        assert pid == pgid
        if action == 'cancel' and sys.platform == 'linux':
            limits = pathlib.Path(f'/proc/{pid}/limits').read_text()
            process_limit = next(line for line in limits.splitlines()
                if line.startswith('Max processes'))
            inherited = ['unlimited' if value == resource.RLIM_INFINITY else str(value)
                for value in resource.getrlimit(resource.RLIMIT_NPROC)]
            assert process_limit.split()[2:4] == inherited, process_limit
            address_limit = next(line for line in limits.splitlines()
                if line.startswith('Max address space'))
            assert address_limit.split()[3:5] == [str(2 * 1024**3)] * 2, address_limit
            print(f'PASS actual Linux limits: {process_limit}; {address_limit}', flush=True)
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
    frames = finish(start(root, 'convert', launcher, ['--internal-thread-flood']))
    assert b'Eresource_limit' in frames, frames
    assert marker.read_text() == 'clean\n'
    print('PASS sampled per-worker thread bound', flush=True)
