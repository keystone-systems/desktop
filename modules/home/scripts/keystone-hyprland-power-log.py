#!/usr/bin/env python3
"""Forward the current Hyprland instance log to this unit's journal stdout."""

import ctypes
import os
import select
import stat as stat_module
import sys
import time
from pathlib import Path

# Keep both a single read and any incomplete log record small. Large backlogs
# are skipped to retain the newest diagnostics without unbounded work.
READ_SIZE = 64 * 1024
MAX_BACKLOG = 1024 * 1024
MAX_LINE = 4096
BURST_BYTES = 256 * 1024
BYTES_PER_SECOND = 64 * 1024 / 60
BURST_LINES = 400
LINES_PER_SECOND = 200 / 60
# MODIFY, MOVED_FROM/TO, CREATE, DELETE, DELETE_SELF, MOVE_SELF.
# ACCESS/OPEN/CLOSE would make our own reads wake this watcher.
IN_EVENTS = 0x00000002 | 0x00000FC0

libc = ctypes.CDLL(None, use_errno=True)
libc.inotify_init1.argtypes = [ctypes.c_int]
libc.inotify_init1.restype = ctypes.c_int
libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
libc.inotify_add_watch.restype = ctypes.c_int
libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]


def checked(value):
    if value < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return value


def main():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not runtime or not signature or signature in (".", "..") or "/" in signature:
        return 0
    root = Path(runtime)
    if not root.is_dir():
        return 0
    hypr = root / "hypr"
    instance = hypr / signature
    log = instance / "hyprland.log"
    inotify = checked(libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK))
    poller = select.poll()
    poller.register(inotify, select.POLLIN)
    watched = {}
    current = None
    current_id = None
    partial = b""
    discard_line = False
    last_refill = time.monotonic()
    byte_tokens = BURST_BYTES
    line_tokens = BURST_LINES

    def emit(line):
        nonlocal last_refill, byte_tokens, line_tokens
        now = time.monotonic()
        elapsed = now - last_refill
        last_refill = now
        byte_tokens = min(BURST_BYTES, byte_tokens + elapsed * BYTES_PER_SECOND)
        line_tokens = min(BURST_LINES, line_tokens + elapsed * LINES_PER_SECOND)
        if len(line) <= byte_tokens and line_tokens >= 1:
            byte_tokens -= len(line)
            line_tokens -= 1
            # stdout is collected under SyslogIdentifier by the user manager.
            sys.stdout.write(line.decode("utf-8", "replace") + "\n")
            sys.stdout.flush()

    def consume(data):
        nonlocal partial, discard_line
        fragments = data.split(b"\n")
        for fragment in fragments[:-1]:
            if not discard_line:
                line = partial + fragment
                if len(line) <= MAX_LINE:
                    emit(line.rstrip(b"\r"))
            partial = b""
            discard_line = False
        remainder = fragments[-1]
        if len(fragments) == 1:
            remainder = partial + remainder
        if len(remainder) > MAX_LINE:
            partial = b""
            discard_line = True
        elif not discard_line:
            partial = remainder

    try:
        while True:
            # Watch each existing ancestor before checking its child, so file
            # creation between the check and poll cannot be missed.
            for directory in (root, hypr, instance):
                try:
                    info = directory.stat()
                    identity = (info.st_dev, info.st_ino)
                    previous = watched.get(directory)
                    if previous is not None and previous[1] != identity:
                        libc.inotify_rm_watch(inotify, previous[0])
                        del watched[directory]
                    if directory not in watched:
                        watched[directory] = (
                            checked(libc.inotify_add_watch(inotify, os.fsencode(directory), IN_EVENTS)),
                            identity,
                        )
                except (FileNotFoundError, NotADirectoryError):
                    previous = watched.pop(directory, None)
                    if previous is not None:
                        libc.inotify_rm_watch(inotify, previous[0])
            try:
                stat = log.stat()
                identity = (stat.st_dev, stat.st_ino) if stat_module.S_ISREG(stat.st_mode) else None
            except (FileNotFoundError, NotADirectoryError):
                identity = None
            if identity != current_id:
                if current is not None:
                    os.close(current)
                current = None
                current_id = None
                partial = b""
                discard_line = False
                if identity is not None:
                    try:
                        current = os.open(log, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
                        opened = os.fstat(current)
                        if not stat_module.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != identity:
                            os.close(current)
                            current = None
                        else:
                            current_id = identity
                            start = max(0, opened.st_size - MAX_BACKLOG)
                            os.lseek(current, start, os.SEEK_SET)
                            discard_line = start > 0
                    except (FileNotFoundError, NotADirectoryError):
                        current = None
            if current is not None:
                size = os.fstat(current).st_size
                offset = os.lseek(current, 0, os.SEEK_CUR)
                if size < offset:
                    os.lseek(current, 0, os.SEEK_SET)
                    partial = b""
                    discard_line = False
                elif size - offset > MAX_BACKLOG:
                    os.lseek(current, size - MAX_BACKLOG, os.SEEK_SET)
                    partial = b""
                    discard_line = True  # skip the first, potentially partial line
                # Bound work even if the producer continuously floods the log.
                for _ in range(MAX_BACKLOG // READ_SIZE):
                    data = os.read(current, READ_SIZE)
                    if not data:
                        break
                    consume(data)
            poller.poll()  # inotify, with no periodic wakeups
            try:
                os.read(inotify, READ_SIZE)
            except BlockingIOError:
                pass
    finally:
        if current is not None:
            os.close(current)
        os.close(inotify)


if __name__ == "__main__":
    raise SystemExit(main())
