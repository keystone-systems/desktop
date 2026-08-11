#!/usr/bin/env bash
# keystone-share-picker — xdph custom_picker_binary replacement, walker dmenu front end.
#
# Contract (xdg-desktop-portal-hyprland v1.4.1):
#   in : env  XDPH_WINDOW_SHARING_LIST  entries "{handle}[HC>]{class}[HT>]{title}[HE>]{addr}[HA>]"
#        (addr is the Hyprland window address in decimal)
#        argv --allow-token  (present when screencopy:allow_token_by_default = true)
#   out: one line on stdout:
#        [SELECTION]r/window:{handle} | [SELECTION]r/screen:{output} | [SELECTION]r/region:{output}@{x},{y},{w},{h}
#        print nothing / exit nonzero = cancel
#
# Windows are grouped by Hyprland workspace, active workspace first ("*" marker).
# XDPH_PICKER_MENU overrides the chooser command for headless tests.
set -euo pipefail

read -ra menu_cmd <<<"${XDPH_PICKER_MENU:-walker --dmenu}"

clients=$(hyprctl -j clients)
monitors=$(hyprctl -j monitors)
active=$(hyprctl -j activeworkspace | jq -r .id)

# rows: sortkey \t label \t payload
rows=""
while IFS=$'\t' read -r handle class title addr; do
  [[ -z "$handle" ]] && continue
  # Exact join on the window address; class+title stays as the fallback for
  # entries without one (identical twins then resolve to the first match).
  ws=""
  if [[ "$addr" =~ ^[0-9]+$ ]]; then
    hex=$(printf '0x%x' "$addr")
    ws=$(jq -r --arg a "$hex" '[.[] | select(.address==$a)][0].workspace.id // empty' <<<"$clients")
  fi
  if [[ -z "$ws" ]]; then
    ws=$(jq -r --arg c "$class" --arg t "$title" \
      '[.[] | select(.class==$c and .title==$t)][0].workspace.id // empty' <<<"$clients")
  fi
  if [[ -z "$ws" ]]; then
    key="9-?"
    wslabel="?"
  elif [[ "$ws" == "$active" ]]; then
    key="0-active"
    wslabel="$ws*"
  else
    key=$(printf '1-%04d' "$ws" 2>/dev/null || echo "1-zzzz")
    wslabel="$ws"
  fi
  rows+="$key"$'\t'"[ws $wslabel] $class — $title"$'\t'"window:$handle"$'\n'
done < <(perl -e '
  my $s = $ENV{XDPH_WINDOW_SHARING_LIST} // "";
  while ($s =~ /(\d+)\[HC>\](.*?)\[HT>\](.*?)\[HE>\](.*?)\[HA>\]/gs) {
    my ($h,$c,$t,$a) = ($1,$2,$3,$4);
    $c =~ s/[\t\n]/ /g; $t =~ s/[\t\n]/ /g; $a =~ s/[^0-9]//g;
    print "$h\t$c\t$t\t$a\n";
  }')

while read -r name; do
  rows+="2"$'\t'"Screen: $name"$'\t'"screen:$name"$'\n'
done < <(jq -r '.[].name' <<<"$monitors")
rows+="3"$'\t'"Region…"$'\t'"region"$'\n'

menu=$(printf '%s' "$rows" | awk -F'\t' 'NF>=3' | sort -t$'\t' -k1,1)
choice=$(cut -f2 <<<"$menu" | "${menu_cmd[@]}") || exit 1
[[ -z "$choice" ]] && exit 1
payload=$(awk -F'\t' -v c="$choice" '$2==c {print $3; exit}' <<<"$menu")
[[ -z "$payload" ]] && exit 1

if [[ "$payload" == "region" ]]; then
  sel=$(slurp -f '%o %x %y %w %h') || exit 1
  read -r out gx gy w h <<<"$sel"
  # slurp reports layout-global coordinates; xdph wants them output-relative.
  read -r mx my < <(jq -r --arg o "$out" '.[] | select(.name==$o) | "\(.x) \(.y)"' <<<"$monitors")
  payload="region:$out@$((gx - mx)),$((gy - my)),$w,$h"
fi

echo "[SELECTION]r/$payload"
