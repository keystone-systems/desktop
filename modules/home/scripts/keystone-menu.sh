#!/usr/bin/env bash

set -euo pipefail

keystone_cmd() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return 0
  fi

  if [[ -x "$HOME/.local/bin/$command_name" ]]; then
    printf "%s\n" "$HOME/.local/bin/$command_name"
    return 0
  fi

  printf "Unable to locate %s\n" "$command_name" >&2
  exit 1
}

set_default_agent() {
  local agent_file="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/defaults/agent"
  local agent="${1:-}"
  local target_dir
  local temporary=""

  if (( $# == 0 )); then
    if [[ -f "$agent_file" ]]; then
      IFS= read -r agent < "$agent_file" || true
      [[ -z "$agent" ]] || printf '%s\n' "$agent"
    fi
    return 0
  fi

  if (( $# != 1 )); then
    printf 'Usage: keystone-menu default-agent [agent]\n' >&2
    return 2
  fi

  case "$agent" in
    agy | claude | codex | copilot | crush | grok | hermes | omp | opencode | ori | pi) ;;
    *)
      printf 'Unsupported default agent: %s\n' "$agent" >&2
      return 2
      ;;
  esac

  if ! command -v "$agent" >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/$agent" ]]; then
    printf 'Default agent is not installed: %s\n' "$agent" >&2
    return 1
  fi

  target_dir="${agent_file%/*}"
  mkdir -p -- "$target_dir"
  temporary="$(mktemp "$target_dir/.agent.XXXXXX")"
  trap "rm -f -- $(printf '%q' "$temporary")" EXIT
  chmod 0600 "$temporary"
  printf '%s\n' "$agent" > "$temporary"
  mv -fT -- "$temporary" "$agent_file"
  trap - EXIT
  temporary=""
}

case "${1:-main}" in
  main | Main | go | Go | root | Root | "")
    exec "$(keystone_cmd omarchy-menu)" toggle
    ;;
  apps | Apps)
    exec "$(keystone_cmd omarchy-menu)" toggle apps
    ;;
  system | System)
    exec "$(keystone_cmd omarchy-menu)" toggle system
    ;;
  setup | Setup)
    exec "$(keystone_cmd omarchy-menu)" toggle setup
    ;;
  learn | Learn)
    exec "$(keystone_cmd omarchy-menu)" toggle learn
    ;;
  capture | Capture)
    exec "$(keystone_cmd omarchy-menu)" toggle trigger.capture
    ;;
  toggle | Toggle)
    exec "$(keystone_cmd omarchy-menu)" toggle trigger.toggle
    ;;
  style | Style)
    exec "$(keystone_cmd omarchy-menu)" toggle style
    ;;
  photos | Photos)
    exec "$(keystone_cmd keystone-photos-menu)" prompt-query
    ;;
  agents | Agents)
    exec "$(keystone_cmd keystone-main-menu)" open-menu agents
    ;;
  screenshot | Screenshot)
    exec "$(keystone_cmd keystone-main-menu)" open-menu screenshot
    ;;
  screenrecord | Screenrecord)
    exec "$(keystone_cmd keystone-screenrecord)"
    ;;
  idle-toggle)
    exec "$(keystone_cmd keystone-idle-toggle)"
    ;;
  nightlight-toggle)
    exec "$(keystone_cmd keystone-nightlight-toggle)"
    ;;
  bar-toggle)
    exec "$(keystone_cmd omarchy-toggle-bar)"
    ;;
  bar-settings)
    exec "$(keystone_cmd omarchy-shell)" shell summon omarchy.bar-settings '{}'
    ;;
  theme | Theme)
    exec "$(keystone_cmd keystone-main-menu)" open-menu theme
    ;;
  background | Background)
    exec "$(keystone_cmd keystone-main-menu)" open-menu background
    ;;
  monitors | Monitors)
    exec "$(keystone_cmd keystone-monitor-menu)" open-menu
    ;;
  wifi | Wifi | network | Network)
    exec "$(keystone_cmd keystone-wifi-menu)" open-menu
    ;;
  audio | Audio)
    exec "$(keystone_cmd keystone-audio-menu)" open-menu
    ;;
  printers | Printers | printer | Printer)
    exec "$(keystone_cmd keystone-printer-menu)" open-menu
    ;;
  hardware | Hardware)
    exec "$(keystone_cmd keystone-hardware-menu)" open-menu
    ;;
  fingerprint | Fingerprint)
    exec "$(keystone_cmd keystone-fingerprint-menu)" open-menu
    ;;
  accounts | Accounts)
    exec "$(keystone_cmd keystone-accounts-menu)" open-menu
    ;;
  secrets | Secrets)
    exec "$(keystone_cmd keystone-secrets-menu)" open-menu
    ;;
  default-agent)
    shift
    set_default_agent "$@"
    ;;
  install | Install)
    exec "$(keystone_cmd keystone-main-menu)" open-menu install
    ;;
  update | Update)
    exec "$(keystone_cmd keystone-main-menu)" dispatch run-update
    ;;
  keybindings | Keybindings)
    exec "$(keystone_cmd keystone-menu-keybindings)"
    ;;
  docs-keystone)
    exec "$(keystone_cmd xdg-open)" https://ks.systems
    ;;
  docs-hyprland)
    exec "$(keystone_cmd xdg-open)" https://wiki.hypr.land/
    ;;
  docs-nixos)
    exec "$(keystone_cmd xdg-open)" https://wiki.nixos.org/
    ;;
  about | About)
    exec "$(keystone_cmd xdg-open)" https://ks.systems
    ;;
  remove-info)
    exec "$(keystone_cmd notify-send)" "Remove software with Nix" \
      "Edit the owning Nix configuration, then rebuild the system."
    ;;
  lock | Lock)
    exec "$(keystone_cmd keystone-lock)"
    ;;
  suspend | Suspend)
    exec "$(keystone_cmd keystone-suspend)"
    ;;
  logout | Logout)
    exec "$(keystone_cmd loginctl)" terminate-user "$USER"
    ;;
  restart | Restart | reboot | Reboot)
    exec "$(keystone_cmd systemctl)" reboot
    ;;
  shutdown | Shutdown | poweroff | Poweroff)
    exec "$(keystone_cmd systemctl)" poweroff
    ;;
  *)
    printf "Unknown Keystone menu route: %s\n" "$1" >&2
    exit 2
    ;;
esac
