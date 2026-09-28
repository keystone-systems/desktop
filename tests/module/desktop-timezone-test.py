"""Exercise timezone transitions without accessing the host bus."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    override = root / "timezone"
    log = root / "calls"
    script = root / "apply.sh"
    script.write_text(Path(sys.argv[1]).read_text().replace("@overrideFile@", str(override)))
    for command, body in {
        "systemctl": '\n'.join([
            'printf "systemctl %s\\n" "$*" >> "$CALL_LOG"',
            '# Simulate startup blocked behind the caller until it exits.',
            'if [[ "$1" == start ]]; then sleep 30; fi',
        ]),
        "timedatectl": '\n'.join([
            'if [[ "$1" == list-timezones ]]; then printf "Asia/Tokyo\\nUTC\\n"; exit; fi',
            'printf "timedatectl %s\\n" "$*" >> "$CALL_LOG"',
        ]),
    }.items():
        path = root / command
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)
    env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CALL_LOG=str(log))
    def run():
        return subprocess.run(["bash", str(script)], env=env, capture_output=True, timeout=2)

    assert run().returncode == 0, "Automatic mode must return before the daemon starts"
    assert log.read_text() == "systemctl --no-block start automatic-timezoned.service\n"
    log.unlink()
    override.write_text("Asia/Tokyo\n")
    assert run().returncode == 0
    assert log.read_text().splitlines() == [
        "systemctl stop automatic-timezoned.service",
        "timedatectl set-timezone Asia/Tokyo",
    ]
    log.unlink()
    override.write_text("Invalid/Zone\n")
    assert run().returncode != 0
    assert not log.exists(), "Invalid zones must not change the running service or timezone"
