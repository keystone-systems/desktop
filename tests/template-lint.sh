#!/usr/bin/env bash
set -euo pipefail
if grep -rnE '/home/|ncrmro|desc:.*Dell|voice-memo' "${1:?template directory required}"; then
  echo 'FAIL: personal literals found in templates/' >&2
  exit 1
else
  status=$?
  [[ $status == 1 ]] || exit "$status"
fi
echo 'PASS: templates are free of personal literals'
