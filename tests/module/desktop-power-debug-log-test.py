"""Headless fixture for the event-driven Hyprland log reader."""

import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time


def read_line(process, timeout=4):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    assert ready, "timed out waiting for captured log"
    return process.stdout.readline().strip()


with tempfile.TemporaryDirectory() as temporary:
    runtime = pathlib.Path(temporary)
    instance = runtime / "hypr" / "current"
    other = runtime / "hypr" / "stale"
    other.mkdir(parents=True)
    (other / "hyprland.log").write_text("wrong-instance\n")
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), HYPRLAND_INSTANCE_SIGNATURE="current")
    process = subprocess.Popen(
        [sys.executable, sys.argv[1]],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        time.sleep(0.1)
        assert process.poll() is None, process.stderr.read()
        instance.mkdir()
        log = instance / "hyprland.log"
        log.write_text("first-existing-line\n")
        assert read_line(process) == "first-existing-line"
        with log.open("a") as stream:
            stream.write("appended-line\n")
        assert read_line(process) == "appended-line"
        # Reads must not create a self-triggered inotify busy loop.
        def cpu_ticks():
            fields = pathlib.Path(f"/proc/{process.pid}/stat").read_text().split()
            return int(fields[13]) + int(fields[14])

        before = cpu_ticks()
        time.sleep(0.5)
        assert cpu_ticks() - before < 5, "log watcher spins while idle"
        log.write_text("replacement-line\n")
        assert read_line(process) == "replacement-line"
        with log.open("a") as stream:
            stream.write("x" * 5000 + "\nshort-after-long\n")
        assert read_line(process) == "short-after-long"
        assert process.poll() is None
    finally:
        process.terminate()
        process.wait(timeout=4)
