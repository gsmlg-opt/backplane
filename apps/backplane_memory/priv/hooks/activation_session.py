from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid


STATE_VERSION = 1
MAX_SESSION_ID_BYTES = 512
MAX_STATE_BYTES = 2048
STATE_DIR_NAME = "backplane-memory-hooks"
VALID_SOURCES = {"startup", "resume", "clear", "compact"}
STATE_ERRORS = (OSError, ValueError, TypeError, UnicodeError)


def _valid_id(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        return False

    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return False

    return len(encoded) <= MAX_SESSION_ID_BYTES


def _digest(claude_session_id):
    return hashlib.sha256(claude_session_id.encode("utf-8")).hexdigest()


def _state_root():
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
    if xdg_runtime:
        base = Path(xdg_runtime)
        name = STATE_DIR_NAME
    else:
        base = Path(os.environ.get("TMPDIR") or "/tmp")
        name = f"{STATE_DIR_NAME}-{os.getuid()}"

    root = base / name
    try:
        os.mkdir(root, 0o700)
    except FileExistsError:
        pass

    fd = _open_no_follow(
        root,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        details = os.fstat(fd)
        if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid():
            raise OSError("activation state root is not owned by the current user")

        os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _open_no_follow(path, flags, mode=0o600, *, dir_fd=None):
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags, mode, dir_fd=dir_fd)


@contextmanager
def _locked(claude_digest):
    root_fd = _state_root()
    lock_fd = None
    lock_file = None
    locked = False
    try:
        lock_fd = _open_no_follow(
            f"{claude_digest}.lock",
            os.O_RDWR | os.O_CREAT,
            dir_fd=root_fd,
        )
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
            raise OSError("activation lock is not a regular file")

        os.fchmod(lock_fd, 0o600)
        lock_file = os.fdopen(lock_fd, "r+b")
        lock_fd = None
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        locked = True
        yield root_fd
    finally:
        try:
            if lock_file is not None:
                try:
                    if locked:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                finally:
                    lock_file.close()
            elif lock_fd is not None:
                os.close(lock_fd)
        finally:
            os.close(root_fd)


def _record_name(claude_digest):
    return f"{claude_digest}.json"


def _read_record(root_fd, claude_digest):
    try:
        fd = _open_no_follow(
            _record_name(claude_digest),
            os.O_RDONLY | getattr(os, "O_NONBLOCK", 0),
            dir_fd=root_fd,
        )
    except FileNotFoundError:
        return None

    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None

        with os.fdopen(fd, "rb") as state_file:
            fd = None
            raw = state_file.read(MAX_STATE_BYTES + 1)
    finally:
        if fd is not None:
            os.close(fd)

    if len(raw) > MAX_STATE_BYTES:
        return None

    try:
        record = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError, RecursionError):
        return None

    expected_keys = {"version", "claude_session_sha256", "memory_session_id"}
    if not isinstance(record, dict) or set(record) != expected_keys:
        return None
    if type(record["version"]) is not int or record["version"] != STATE_VERSION:
        return None
    if record["claude_session_sha256"] != claude_digest:
        return None
    if not _valid_id(record["memory_session_id"]):
        return None

    return record


def _write_record(root_fd, claude_digest, memory_session_id):
    record = {
        "version": STATE_VERSION,
        "claude_session_sha256": claude_digest,
        "memory_session_id": memory_session_id,
    }
    encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_STATE_BYTES:
        raise ValueError("activation state exceeds bound")

    temporary_name = f".{claude_digest}.{uuid.uuid4().hex}.tmp"
    fd = _open_no_follow(
        temporary_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        dir_fd=root_fd,
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as temporary_file:
            fd = None
            temporary_file.write(encoded)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(
            temporary_name,
            _record_name(claude_digest),
            src_dir_fd=root_fd,
            dst_dir_fd=root_fd,
        )
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temporary_name, dir_fd=root_fd)
        except FileNotFoundError:
            pass


def establish(claude_session_id, source):
    if (
        not _valid_id(claude_session_id)
        or not isinstance(source, str)
        or source not in VALID_SOURCES
    ):
        return None

    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root_fd:
            if source == "compact":
                record = _read_record(root_fd, claude_digest)
                return record["memory_session_id"] if record else None

            memory_session_id = claude_session_id
            if source == "resume":
                memory_session_id = f"claude-run-{claude_digest[:12]}-{uuid.uuid4()}"

            _write_record(root_fd, claude_digest, memory_session_id)
            return memory_session_id
    except STATE_ERRORS:
        return None


def resolve(claude_session_id):
    if not _valid_id(claude_session_id):
        return None

    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root_fd:
            record = _read_record(root_fd, claude_digest)
            return record["memory_session_id"] if record else None
    except STATE_ERRORS:
        return None


def prepare_end(claude_session_id):
    if not _valid_id(claude_session_id):
        return None

    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root_fd:
            record = _read_record(root_fd, claude_digest)
            if record is None:
                return None

            return claude_digest, record["memory_session_id"]
    except STATE_ERRORS:
        return None


def cleanup(claude_digest, memory_session_id):
    if (
        not isinstance(claude_digest, str)
        or len(claude_digest) != 64
        or any(character not in "0123456789abcdef" for character in claude_digest)
        or not _valid_id(memory_session_id)
    ):
        return False

    try:
        with _locked(claude_digest) as root_fd:
            record = _read_record(root_fd, claude_digest)
            if record is None or record["memory_session_id"] != memory_session_id:
                return False

            os.unlink(_record_name(claude_digest), dir_fd=root_fd)
            return True
    except STATE_ERRORS:
        return False


def send_json(memory_url, endpoint, body):
    try:
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        result = subprocess.run(
            [
                "curl",
                "-sf",
                "-m",
                "2.0",
                "-X",
                "POST",
                memory_url.rstrip("/") + endpoint,
                "-H",
                "Content-Type: application/json",
                "--data-binary",
                "@-",
            ],
            input=encoded,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except (AttributeError, OSError, TypeError, UnicodeError, ValueError, subprocess.SubprocessError):
        return False


def request_json(memory_url, endpoint, body, timeout_seconds=1.5):
    """POST JSON with a bounded deadline and decode a JSON object response."""
    try:
        timeout = min(max(float(timeout_seconds), 0.05), 1.5)
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        result = subprocess.run(
            [
                "curl",
                "-sf",
                "-m",
                str(timeout),
                "-X",
                "POST",
                memory_url.rstrip("/") + endpoint,
                "-H",
                "Content-Type: application/json",
                "--data-binary",
                "@-",
            ],
            input=encoded,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
        )

        if result.returncode != 0:
            return None

        response = json.loads(result.stdout.decode("utf-8"))
        return response if isinstance(response, dict) else None
    except (
        AttributeError,
        OSError,
        TypeError,
        UnicodeError,
        ValueError,
        subprocess.SubprocessError,
    ):
        return None
