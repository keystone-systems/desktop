set -euo pipefail

# @overrideFile@ is the configured editable timezone file (shell-quoted).
override_file=@overrideFile@

if [[ ! -e $override_file ]]; then
  # This oneshot runs before multi-user.target; automatic-timezoned runs after it.
  # Queue startup without waiting for that target to finish.
  systemctl --no-block start automatic-timezoned.service
  exit 0
fi

zone=$(cat -- "$override_file")
if [[ -z $zone ]] || ! timedatectl list-timezones | grep -Fx -- "$zone" >/dev/null; then
  echo "Invalid timezone override in $override_file" >&2
  exit 1
fi

systemctl stop automatic-timezoned.service
timedatectl set-timezone "$zone"
