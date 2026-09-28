set -euo pipefail

# @applyCommand@ is the packaged privileged apply command (shell-quoted).
# @overrideFile@ is the configured editable timezone file (shell-quoted).
override_file=@overrideFile@
apply=@applyCommand@

selection=$(
  { printf 'Automatic\n'; timedatectl list-timezones; } \
    | keystone-launch-walker --dmenu --placeholder "Time zone (current: $(timedatectl show --property=Timezone --value))"
) || exit 0
[[ -n $selection ]] || exit 0

if [[ $selection != Automatic ]] && ! timedatectl list-timezones | grep -Fx -- "$selection" >/dev/null; then
  notify-send "Time zone" "Invalid timezone: $selection"
  exit 1
fi

previous=$(mktemp)
trap 'rm -f -- "$previous"' EXIT
had_override=false
if [[ -e $override_file ]]; then
  cp -- "$override_file" "$previous"
  had_override=true
fi

if [[ $selection == Automatic ]]; then
  rm -f -- "$override_file"
else
  mkdir -p -- "$(dirname -- "$override_file")"
  temp=$(mktemp "${override_file}.XXXXXX")
  printf '%s\n' "$selection" > "$temp"
  chmod 644 "$temp"
  mv -f -- "$temp" "$override_file"
fi

if ! pkexec "$apply"; then
  if [[ $had_override == true ]]; then
    cp -- "$previous" "$override_file"
  else
    rm -f -- "$override_file"
  fi
  notify-send "Time zone" "Could not apply the selection"
  exit 1
fi

notify-send "Time zone" "$(timedatectl show --property=Timezone --value)"
