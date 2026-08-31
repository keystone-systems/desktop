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

case "${1:-main}" in
  main | Main | go | Go | "")
    exec "$(keystone_cmd keystone-main-menu)" open-menu
    ;;
  system | System)
    exec "$(keystone_cmd keystone-main-menu)" open-menu system
    ;;
  setup | Setup)
    exec "$(keystone_cmd keystone-main-menu)" open-menu setup
    ;;
  learn | Learn)
    exec "$(keystone_cmd keystone-main-menu)" open-menu learn
    ;;
  capture | Capture)
    exec "$(keystone_cmd keystone-main-menu)" open-menu capture
    ;;
  photos | Photos)
    exec "$(keystone_cmd keystone-photos-menu)" prompt-query
    ;;
  screenshot | Screenshot)
    exec "$(keystone_cmd keystone-main-menu)" open-menu screenshot
    ;;
  toggle | Toggle)
    exec "$(keystone_cmd keystone-main-menu)" open-menu toggle
    ;;
  style | Style)
    exec "$(keystone_cmd keystone-main-menu)" open-menu style
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
  *)
    exec "$(keystone_cmd keystone-main-menu)" open-menu
    ;;
esac
