# desktop-setup-menu-entries — behavioral gate on keystone-setup-menu
# entries-json, uncovered since bac8383 rewrote it.
#
# bac8383 split backend resolution into a soft `keystone_lookup` (Hardware,
# Secrets — legitimately absent) and a fatal `keystone_cmd` (the seven that must
# always be there). Under `set -e` a fatal lookup empties the WHOLE menu, so the
# soft/fatal split needs both directions asserted.
#
# The harness stubs each backend on PATH, then runs the script. No module
# evaluation and no display are involved.
#
# Build: nix build .#checks.x86_64-linux.desktop-setup-menu-entries
{ pkgs, lib }:
pkgs.runCommand "desktop-setup-menu-entries"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      jq
    ];
  }
  ''
    set -uo pipefail

    setup_script="${../..}/modules/home/scripts/keystone-setup-menu.sh"

    export HOME="$PWD/home"
    mkdir -p "$HOME/.local/bin" "$PWD/bin"
    export PATH="$PWD/bin:${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
      ]
    }"

    errors=0

    stub() {
      printf '#!%s\nexit 0\n' "${pkgs.bash}/bin/bash" > "$PWD/bin/$1"
      chmod +x "$PWD/bin/$1"
    }

    assert_entries() {
      local label="$1" expected="$2" actual

      if ! actual="$(bash "$setup_script" entries-json | jq -r '[.[].Text] | join(",")')"; then
        echo "FAIL($label): entries-json failed to run" >&2
        errors=$((errors + 1))
        return
      fi

      if [ "$actual" != "$expected" ]; then
        echo "FAIL($label): setup menu entry list mismatch" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        errors=$((errors + 1))
        return
      fi

      echo "PASS($label): $expected"
    }

    # ── Case 1: only the unconditional backends ──
    # Hardware needs keystone-hardware-menu (ksPackage), Secrets needs
    # keystone-secrets-menu (agenixPackage). Both absent -> both entries gone,
    # the seven mandatory entries unaffected.
    for backend in \
      keystone-audio-menu \
      keystone-monitor-menu \
      keystone-printer-menu \
      keystone-fingerprint-menu \
      keystone-accounts-menu \
      keystone-wifi-menu \
      keystone-setup-menu; do
      stub "$backend"
    done
    export KEYSTONE_SYSTEM_FLAKE_POINTER_FILE="$PWD/no-such-pointer"

    assert_entries "no-optional-backends" \
      "Audio,Monitors,Printer,Fingerprint,Accounts,Wifi,Bluetooth"

    # Previews must point at the resolved backend, not at a bare name — a
    # Walker preview runs with the launcher's PATH, not the menu's.
    if ! bash "$setup_script" entries-json \
      | jq -e --arg audio "$PWD/bin/keystone-audio-menu summary" \
          '.[0].Text == "Audio" and .[0].Preview == $audio' >/dev/null; then
      echo "FAIL(no-optional-backends): Audio preview must be the resolved backend path plus ' summary'" >&2
      errors=$((errors + 1))
    fi

    # ── Case 2: every backend present, agenix repo reachable ──
    stub keystone-hardware-menu
    stub keystone-secrets-menu
    mkdir -p "$PWD/flake/agenix-secrets"
    printf '%s\n' "$PWD/flake" > "$PWD/pointer"
    export KEYSTONE_SYSTEM_FLAKE_POINTER_FILE="$PWD/pointer"

    assert_entries "all-backends" \
      "Audio,Monitors,Printer,Hardware,Fingerprint,Accounts,Secrets,Wifi,Bluetooth"

    # ── Case 3: secrets backend installed but no agenix repo to point at ──
    # Secrets drops out; Hardware, which has no such requirement, stays.
    mkdir -p "$PWD/empty-flake"
    printf '%s\n' "$PWD/empty-flake" > "$PWD/pointer"

    assert_entries "secrets-without-repo" \
      "Audio,Monitors,Printer,Hardware,Fingerprint,Accounts,Wifi,Bluetooth"

    # ── Case 4: a MANDATORY backend missing is fatal, not silent ──
    # An empty or truncated menu must never be served as if it were correct.
    rm "$PWD/bin/keystone-audio-menu"
    if bash "$setup_script" entries-json >/dev/null 2>"$PWD/stderr.txt"; then
      echo "FAIL(missing-mandatory-backend): entries-json must exit non-zero when keystone-audio-menu is absent" >&2
      errors=$((errors + 1))
    elif ! grep -F 'Unable to locate keystone-audio-menu' "$PWD/stderr.txt" >/dev/null; then
      echo "FAIL(missing-mandatory-backend): expected an 'Unable to locate keystone-audio-menu' diagnostic" >&2
      errors=$((errors + 1))
    else
      echo "PASS(missing-mandatory-backend): entries-json fails loudly"
    fi

    if [ "$errors" -gt 0 ]; then
      echo "FAIL: $errors setup-menu case(s) wrong" >&2
      exit 1
    fi

    touch "$out"
  ''
