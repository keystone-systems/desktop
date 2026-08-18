# DPMS wake recovery watchdog (ks-config#6, fix b — defense in depth).
# After resume/DPMS-on, an amdgpu DP connector can stay wedged: hyprland
# believes the output is active while the kernel reports it disabled. This
# watchdog detects that state and bounces DPMS a bounded number of times.
# The root-cause fix (amdgpu.dcdebugmask=0x800) lives in the host config and
# must not be removed in favor of this script.
{
  writeShellApplication,
  hyprlandPkg,
  jq,
  brightnessctl,
  coreutils,
  util-linux,
}:
writeShellApplication {
  name = "keystone-dpms-wake";
  # hyprctl comes from the same flake input as the compositor so IPC always
  # matches the running Hyprland version.
  runtimeInputs = [
    hyprlandPkg
    jq
    brightnessctl
    coreutils
    util-linux
  ];
  text = ''
    # Every action is journal-tagged for issue-#6 forensics:
    #   journalctl --user -t keystone-dpms-wake
    log() {
      logger -t keystone-dpms-wake -- "$*" || true
    }

    # hyprctl dispatch takes Lua since Hyprland 0.56, so the legacy
    # `dispatch dpms on` string is a Lua syntax error rather than an unknown
    # dispatcher. Every call here is `|| log`-guarded, which is precisely how
    # that breakage stayed invisible across the 0.56 migration: the watchdog
    # ran, logged a failure nobody read, and recovered nothing.
    dpms() {
      hyprctl dispatch "hl.dsp.dpms({ action = \"$1\" })" >/dev/null 2>&1 ||
        log "dpms $1 dispatch failed"
    }

    # Preserve today's on-resume semantics first: wake the outputs and
    # restore brightness.
    log "wake: dpms on; brightnessctl -r"
    dpms on
    brightnessctl -r >/dev/null 2>&1 || log "brightnessctl -r failed"

    # Give DRM connectors time to settle before judging them wedged.
    sleep 2

    # Env-overridable sysfs root so the smoke test can point at a fake tree.
    SYSFS_DRM="''${KEYSTONE_DPMS_SYSFS:-/sys/class/drm}"

    # Print the names of wedged connectors, one per line. A connector is
    # wedged only when hyprland reports the output active (dpmsStatus ==
    # true) while the kernel reports it disabled — requiring both guards
    # against lids and deliberately-off monitors flapping the retry loop.
    wedged_connectors() {
      local monitors_json conn_dir kernel_enabled name hypr_active
      if ! monitors_json="$(hyprctl monitors -j 2>/dev/null)"; then
        log "hyprctl monitors -j failed; skipping wedge check"
        return 0
      fi
      for conn_dir in "$SYSFS_DRM"/card*-*; do
        [ -d "$conn_dir" ] || continue
        [ -f "$conn_dir/status" ] || continue
        [ "$(cat "$conn_dir/status")" = "connected" ] || continue
        [ -f "$conn_dir/enabled" ] || continue
        kernel_enabled="$(cat "$conn_dir/enabled")"
        name="$(basename "$conn_dir")"
        name="''${name#card*-}"
        hypr_active="$(jq -r --arg n "$name" \
          '[.[] | select(.name == $n) | .dpmsStatus] | first // empty' \
          <<<"$monitors_json" || true)"
        if [ "$hypr_active" = "true" ] && [ "$kernel_enabled" = "disabled" ]; then
          printf '%s\n' "$name"
        fi
      done
    }

    wedged="$(wedged_connectors)"
    if [ -z "$wedged" ]; then
      log "all connectors healthy after wake"
      exit 0
    fi

    attempt=0
    while [ -n "$wedged" ] && [ "$attempt" -lt 3 ]; do
      attempt=$((attempt + 1))
      log "wedged connectors: $(printf '%s ' "$wedged") — dpms off/on retry $attempt/3"
      dpms off
      sleep 0.5
      dpms on
      sleep 2
      wedged="$(wedged_connectors)"
    done

    if [ -n "$wedged" ]; then
      log "still wedged after 3 retries: $(printf '%s ' "$wedged") — falling back to hyprctl reload"
      hyprctl reload >/dev/null 2>&1 || log "hyprctl reload failed"
      log "gave up after reload fallback; connectors may still be wedged"
    else
      log "recovered after $attempt retry cycle(s)"
    fi

    # Never fail the hypridle hook.
    exit 0
  '';
}
