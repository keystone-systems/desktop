"""Exercise the rendered launcher without a real desktop or tailnet."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
for scenario in ("ready", "missing-ip"):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        stub = root / "stub"
        stub.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
from pathlib import Path
root = Path(os.environ["RDP_TEST_ROOT"])
name = Path(sys.argv[0]).name
if name == "tailscale":
    assert sys.argv[1:] == ["ip", "-4"], "no readiness wait allowed"
    assert not (root / "queried").exists(), "no retries allowed"
    (root / "queried").touch()
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
                '"' + str(root / name) + '"', launcher)
            assert count > 0, f"missing {name} in rendered launcher"
        script = root / "launcher"
        script.write_text(launcher)
        script.chmod(0o700)
        env = {k: v for k, v in os.environ.items() if k not in (
            "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR")}
        env.update(RDP_TEST_ROOT=str(root), RDP_TEST_SCENARIO=scenario)
        result = subprocess.run([str(script)], env=env, timeout=5)
        assert (root / "queried").exists()
        if scenario == "missing-ip":
            assert result.returncode != 0
            assert not (root / "started").exists(), "must fail closed"
        else:
            assert result.returncode == 0
            args = json.loads((root / "started").read_text())
            assert args[args.index("--bind") + 1] == "100.64.1.2:3389"
            assert args[args.index("--output") + 1] == "DP-1"
        print(f"PASS: {scenario}")
