#!/usr/bin/env bash
# keystone-main-menu — shared subordinate Elephant/Walker menu backend.

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

notify() {
  notify-send "$@"
}

detach() {
  "$(keystone_cmd keystone-detach)" "$@"
}

screenshot_json() {
  jq -n '
    [
      {
        Text: "Snap with editing",
        Subtext: "Interactive capture with annotation flow",
        Value: "screenshot-smart",
        Icon: "document-edit-symbolic"
      },
      {
        Text: "Straight to clipboard",
        Subtext: "Interactive capture copied directly",
        Value: "screenshot-clipboard",
        Icon: "edit-copy-symbolic"
      }
    ]
  '
}

background_json() {
  "$(keystone_cmd keystone-theme-switch)" --backgrounds --json \
    | jq '
        .backgrounds
        | if length == 0 then
            [
              {
                Text: "No wallpapers found",
                Subtext: "The current theme does not provide any wallpapers",
                Value: "blocked\tBackground\tNo wallpapers were found for the current theme."
              }
            ]
          else
            map({
              Text: (.path | sub("^backgrounds/"; "")),
              Subtext: (if .current then "current wallpaper" else "set wallpaper" end),
              Value: ("background-select\t" + .path),
              Icon: "image-x-generic-symbolic"
            })
          end
      '
}

theme_json() {
  "$(keystone_cmd keystone-theme-switch)" --list --json \
    | jq '
        .themes
        | if length == 0 then
            [
              {
                Text: "No themes found",
                Subtext: "The themes directory is empty",
                Value: "blocked\tTheme\tNo themes were found."
              }
            ]
          else
            map({
              Text: .name,
              Subtext: (if .current then "current theme" else "switch theme" end),
              Value: ("theme-select\t" + .name),
              Icon: "preferences-desktop-theme-symbolic"
            })
          end
      '
}

open_menu() {
  local target="${1:-main}"
  local menu_id=""
  local prompt=""

  case "${target,,}" in
    screenshot)
      menu_id="menus:keystone-screenshot"
      prompt="Screenshot"
      ;;
    agents)
      menu_id="menus:keystone-agents"
      prompt="Agents"
      ;;
    theme)
      menu_id="menus:keystone-theme"
      prompt="Theme"
      ;;
    background)
      menu_id="menus:keystone-background"
      prompt="Background"
      ;;
    install)
      menu_id="menus:keystone-install"
      prompt="Install"
      ;;
    *)
      printf "Unknown Walker submenu: %s\n" "$target" >&2
      return 2
      ;;
  esac

  walker -q >/dev/null 2>&1 || true
  setsid "$(keystone_cmd keystone-launch-walker)" -m "$menu_id" -p "$prompt" >/dev/null 2>&1 &
}

dispatch() {
  local payload="${1:-}"
  local action="" arg1="" arg2=""

  IFS=$'\t' read -r action arg1 arg2 <<<"$payload"

  case "$action" in
    screenshot | theme | background | agents)
      ;;
    run-update)
      # CRITICAL: delegate to the dedicated update submenu's dispatch path
      # so the top-level Walker entry stays aligned with the authoritative
      # update launcher. The submenu spawns `ks update --approve` via
      # `uwsm app -- systemd-inhibit … systemd-cat -t ks-update …` (no
      # terminal); polkit prompt + notify-send make the run silent on
      # success and journaled under tag `ks-update` on failure. Any
      # change to the launch contract belongs in
      # update_menu.rs::dispatch, not duplicated here.
      #
      # The Quattro catalog hides this entry when `ks` is absent, but
      # `dispatch run-update` remains a public argv surface. Under
      # `set -euo pipefail` a missing `ks` would fail silently, so report it.
      if ! command -v ks >/dev/null 2>&1; then
        notify "Update unavailable" "This host has no keystone ks CLI."
        exit 0
      fi
      ks menu update dispatch run-update
      ;;
    screenshot-smart)
      detach "$(keystone_cmd keystone-screenshot)" smart
      ;;
    screenshot-clipboard)
      detach "$(keystone_cmd keystone-screenshot)" smart clipboard
      ;;
    theme-select)
      detach "$(keystone_cmd keystone-theme-switch)" "$arg1"
      ;;
    background-select)
      detach "$(keystone_cmd keystone-theme-switch)" --background "$arg1"
      ;;
    blocked)
      notify "$arg1" "$arg2"
      ;;
    *)
      printf "Unknown main menu action: %s\n" "$action" >&2
      exit 1
      ;;
  esac
}

case "${1:-}" in
  open-menu)
    shift
    open_menu "$@"
    ;;
  screenshot-json)
    shift
    screenshot_json "$@"
    ;;
  theme-json)
    shift
    theme_json "$@"
    ;;
  background-json)
    shift
    background_json "$@"
    ;;
  dispatch)
    shift
    dispatch "$@"
    ;;
  *)
    echo "Usage: keystone-main-menu {open-menu|screenshot-json|theme-json|background-json|dispatch} ..." >&2
    exit 1
    ;;
esac
