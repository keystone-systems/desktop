#!/usr/bin/env bash

set -euo pipefail

refuse() {
  printf 'Refusing UWSM ownership migration: %s\n' "$1" >&2
  exit 1
}

remove_path() {
  if declare -F run >/dev/null; then
    run rm -- "$1"
  else
    rm -- "$1"
  fi
}

env_target="${HOME}/.config/uwsm/env"
remove_env=false
if [[ -e "$env_target" || -L "$env_target" ]]; then
  [[ -L "$env_target" ]] || refuse "$env_target is not a symlink"
  env_raw_target="$(readlink -- "$env_target")"
  case "$env_raw_target" in
    */packages/hyprland-common/.config/uwsm/env)
      remove_env=true
      ;;
    /nix/store/*-home-manager-files/.config/uwsm/env)
      # Current and prior Home Manager generations already own this path.
      # Leaving the link intact makes repeated activations idempotent and lets
      # Home Manager replace an old generation through its normal link phase.
      ;;
    *)
      refuse "$env_target points to an unrecognized target: $env_raw_target"
      ;;
  esac
fi

legacy_target="${HOME}/.config/systemd/user/hyprland-session.target"
remove_legacy=false
if [[ -e "$legacy_target" || -L "$legacy_target" ]]; then
  [[ -L "$legacy_target" ]] || refuse "$legacy_target is not a symlink"
  [[ ! -e "$legacy_target" ]] || refuse "$legacy_target is still a valid symlink"
  legacy_raw_target="$(readlink -- "$legacy_target")"
  case "$legacy_raw_target" in
    /nix/store/*-home-manager-files/.config/systemd/user/hyprland-session.target)
      remove_legacy=true
      ;;
    *)
      refuse "$legacy_target is an unrelated broken symlink: $legacy_raw_target"
      ;;
  esac
fi

# Complete validation before changing either target. This keeps a foreign
# legacy target from partially completing the coordinated ownership handoff.
[[ "$remove_env" == false ]] || remove_path "$env_target"
[[ "$remove_legacy" == false ]] || remove_path "$legacy_target"
