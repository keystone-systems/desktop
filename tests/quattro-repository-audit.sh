#!/usr/bin/env bash

set -euo pipefail

desktop_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$desktop_root/docs/audits/omarchy-b86d4505-b71dcad9.tsv"
upstream_repo="${1:?Usage: tests/quattro-repository-audit.sh PATH_TO_OMARCHY_GIT_CHECKOUT}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

base="$(awk -F '\t' '$1 == "# base" { print $2 }' "$manifest")"
target="$(awk -F '\t' '$1 == "# target" { print $2 }' "$manifest")"
[[ "$base" == b86d4505c11b71f90b7bd14d6a80676863a70775 ]] \
  || fail "the manifest base is not the deployed audited source"
[[ "$target" == b71dcad96e9d0b2962b7d225828a5cb6000ad720 ]] \
  || fail "the manifest target is not the reviewed source"

lock_target="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["nodes"]["omarchy"]["locked"]["rev"])' "$desktop_root/flake.lock")"
[[ "$lock_target" == "$target" ]] \
  || fail "flake.lock Omarchy rev $lock_target does not match manifest target $target"

git -C "$upstream_repo" cat-file -e "$base^{commit}"
git -C "$upstream_repo" cat-file -e "$target^{commit}"

commit_count="$(git -C "$upstream_repo" rev-list --count "$base..$target")"
[[ "$commit_count" == 177 ]] || fail "expected 177 commits, found $commit_count"

shortstat="$(git -C "$upstream_repo" diff --shortstat "$base" "$target")"
[[ "$shortstat" == *'235 files changed, 14784 insertions(+), 576 deletions(-)'* ]] \
  || fail "unexpected range totals: $shortstat"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/quattro-repository-audit.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

git -C "$upstream_repo" diff --name-status "$base" "$target" \
  >"$scratch/upstream-name-status"
awk -F '\t' '$1 !~ /^#/ && $1 != "status" { print $1 "\t" $3 }' "$manifest" \
  >"$scratch/manifest-name-status"
diff -u "$scratch/upstream-name-status" "$scratch/manifest-name-status" \
  || fail "the path manifest does not exactly cover the audited range"

[[ "$(awk -F '\t' '$1 !~ /^#/ && $1 != "status" { count++ } END { print count + 0 }' "$manifest")" == 235 ]] \
  || fail "the manifest does not contain 235 paths"
[[ "$(awk -F '\t' '$1 !~ /^#/ && $1 != "status" { seen[$3]++ } END { for (path in seen) if (seen[path] != 1) bad++ } END { print bad + 0 }' "$manifest")" == 0 ]] \
  || fail "the manifest contains duplicate paths"
awk -F '\t' '
  NR == 1 {
    if ($0 != "# base\tb86d4505c11b71f90b7bd14d6a80676863a70775") exit 1
    next
  }
  NR == 2 {
    if ($0 != "# target\tb71dcad96e9d0b2962b7d225828a5cb6000ad720") exit 1
    next
  }
  NR == 3 {
    if ($0 != "status\tcategory\tpath") exit 1
    next
  }
  NR > 3 {
    if ($1 !~ /^(A|M|D)$/) exit 1
    if ($2 !~ /^(executed|copied-inactive|overwritten|excluded-command|upstream-test-only)$/) exit 1
    if (NF != 3) exit 1
  }
' "$manifest" || fail "the manifest has an invalid row"

for expected in \
  'copied-inactive 70' \
  'excluded-command 40' \
  'executed 37' \
  'overwritten 1' \
  'upstream-test-only 87'; do
  category="${expected% *}"
  count="${expected#* }"
  actual="$(awk -F '\t' -v category="$category" '$1 !~ /^#/ && $1 != "status" && $2 == category { count++ } END { print count + 0 }' "$manifest")"
  [[ "$actual" == "$count" ]] || fail "$category has $actual paths, expected $count"
done

# Reproduce the adapter boundary instead of trusting a second handwritten list.
awk '
  /^(  )?(publicUpstreamScripts|widgetUpstreamScripts) = \[/ { capture = 1; next }
  capture && /^  \];/ { capture = 0; next }
  capture { print }
' "$desktop_root/lib/quattro-runtime.nix" \
  | sed -n 's/^[[:space:]]*"\([^"]*\)"$/\1/p' \
  | sort -u >"$scratch/allowlisted-commands"

git -C "$upstream_repo" diff --name-only "$base" "$target" \
  | sed -n 's#^bin/##p' | sort -u >"$scratch/changed-bin"
comm -12 "$scratch/changed-bin" "$scratch/allowlisted-commands" \
  >"$scratch/expected-executed-bin"
awk -F '\t' '$1 !~ /^#/ && $1 != "status" && $2 == "executed" && $3 ~ /^bin\// { sub("^bin/", "", $3); print $3 }' "$manifest" \
  | sort -u >"$scratch/audited-executed-bin"
diff -u "$scratch/expected-executed-bin" "$scratch/audited-executed-bin" \
  || fail "changed allowlisted commands are not classified exactly as executed"

comm -23 "$scratch/changed-bin" "$scratch/allowlisted-commands" \
  >"$scratch/expected-excluded-bin"
awk -F '\t' '$1 !~ /^#/ && $1 != "status" && $2 == "excluded-command" { sub("^bin/", "", $3); print $3 }' "$manifest" \
  | sort -u >"$scratch/audited-excluded-bin"
diff -u "$scratch/expected-excluded-bin" "$scratch/audited-excluded-bin" \
  || fail "the excluded command classification does not match the runtime allowlist"

if grep -Eq '(^|[-])(install|migrate|pacman|yay|upgrade)([-]|$)' "$scratch/allowlisted-commands"; then
  fail "an installer, migration, or Arch package-manager command is allowlisted"
fi

awk -F '\t' '$1 !~ /^#/ && $1 != "status" && $3 ~ /^test\// && $2 != "upstream-test-only" { exit 1 }' "$manifest" \
  || fail "an upstream test has an active runtime classification"
awk -F '\t' '$1 !~ /^#/ && $1 != "status" && $3 == "default/omarchy/omarchy-menu.jsonc" && $2 == "overwritten" { found = 1 } END { exit !found }' "$manifest" \
  || fail "the upstream menu is not classified as overwritten"

for prefix in \
  shell/plugins/clipboard/ \
  shell/plugins/dev-gallery/ \
  shell/plugins/emojis/ \
  shell/plugins/lock/ \
  shell/plugins/notifications/ \
  shell/plugins/osd/ \
  shell/plugins/polkit/ \
  shell/plugins/reminders/; do
  awk -F '\t' -v prefix="$prefix" '
    $1 !~ /^#/ && $1 != "status" && index($3, prefix) == 1 && $2 != "copied-inactive" { exit 1 }
  ' "$manifest" || fail "disabled plugin path $prefix is not copied-inactive"
done

printf 'PASS: Omarchy %s..%s audit is complete (177 commits, 235 paths, 14784 insertions, 576 deletions)\n' \
  "${base:0:8}" "${target:0:8}"
