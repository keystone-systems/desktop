"""Exercise the rendered launcher without connecting to a real desktop or tailnet."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1]).read_text()


def wait_for(path):
    deadline = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {path.name}")
        time.sleep(0.01)


for scenario in ("late-ready", "shutdown-waiting", "missing-ip"):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        stub = root / "stub"
        stub.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys, time
from pathlib import Path
root = Path(os.environ["RDP_TEST_ROOT"])
name = Path(sys.argv[0]).name
if name == "tailscale":
    if sys.argv[1] == "wait":
        assert sys.argv[2] == "--timeout=0s"
        (root / "waiting").touch()
        while not (root / "ready").exists():
            time.sleep(0.01)
    else:
        assert sys.argv[1:] == ["ip", "-4"]
        if os.environ["RDP_TEST_SCENARIO"] == "missing-ip":
            sys.exit(1)
        print("100.64.1.2")
elif name == "hyprctl":
    print('[{"name":"DP-1"}]')
else:
    assert name == "hypr-rdp"
    (root / "started").write_text(json.dumps(sys.argv[1:]))
''')
        stub.chmod(0o700)
        launcher = source
        for name in ("tailscale", "hyprctl", "hypr-rdp"):
            (root / name).symlink_to(stub)
            launcher, count = re.subn(
                r'"/nix/store/[^"\n]+/bin/' + name + r'"',
                '"' + str(root / name) + '"',
                launcher,
            )
            assert count > 0, f"missing {name} in rendered launcher"
        script = root / "launcher"
        script.write_text(launcher)
        script.chmod(0o700)
        env = {k: v for k, v in os.environ.items() if k not in (
            "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR")}
        env.update(RDP_TEST_ROOT=str(root), RDP_TEST_SCENARIO=scenario)
        proc = subprocess.Popen([str(script)], env=env, start_new_session=True)
        try:
            wait_for(root / "waiting")
            assert proc.poll() is None
            assert not (root / "started").exists(), "RDP started before readiness"
            if scenario == "shutdown-waiting":
                os.killpg(proc.pid, signal.SIGTERM)
                assert proc.wait(timeout=5) != 0
                assert not (root / "started").exists()
            else:
                (root / "ready").touch()
                code = proc.wait(timeout=5)
                if scenario == "missing-ip":
                    assert code != 0
                    assert not (root / "started").exists(), "must fail closed"
                else:
                    assert code == 0
                    args = json.loads((root / "started").read_text())
                    assert args[args.index("--bind") + 1] == "100.64.1.2:3389"
                    assert args[args.index("--output") + 1] == "DP-1"
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        print(f"PASS: {scenario}")
