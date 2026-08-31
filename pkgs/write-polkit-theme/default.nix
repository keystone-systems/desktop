{
  writeShellApplication,
  jq,
}:
# Single source of truth for the keystone polkit-theme JSON generator.
# Both production (modules/home/theming/default.nix — the home.activation
# script and the keystone-theme-switch wrapper) and the dev smoke test
# (ks.systems/os bin/dev/test-polkit-theme.sh) call this binary, so the smoke
# test exercises the same logic that ships.
writeShellApplication {
  name = "keystone-write-polkit-theme";
  runtimeInputs = [ jq ];
  text = ''
    if [[ $# -ne 2 ]]; then
      echo "Usage: keystone-write-polkit-theme <theme-path> <output-path>" >&2
      exit 2
    fi

    theme_path="$1"
    output_path="$2"
    colors_file="$theme_path/colors.toml"
    is_light=false

    declare -A theme_colors=()

    if [[ -f "$colors_file" ]]; then
      while IFS='=' read -r key value; do
        key="''${key//[\"\' ]/}"
        [[ -n "$key" && "$key" != \#* ]] || continue
        if [[ "$value" == *[\"\']* ]]; then
          value="''${value#*[\"\']}"
          value="''${value%%[\"\']*}"
        else
          value="''${value#"''${value%%[![:space:]]*}"}"
          value="''${value%"''${value##*[![:space:]]}"}"
        fi
        [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        theme_colors["$key"]="$value"
      done < "$colors_file"
    fi

    # Normalise to #RRGGBB. The QML in packages/hyprpolkitagent/main.qml
    # binds the values from polkit.json straight into Qt color properties
    # (`color: theme.text`, etc.). Qt's QColor parser accepts `#RRGGBB`
    # and named colours but does NOT accept CSS-style `rgb(r, g, b)` /
    # `rgba(r, g, b, a)` strings — when parsing fails, the bound colour is
    # invalid and Qt renders it as black. Convert semantic palette values to
    # hex once on the way out.
    to_hex() {
      local val="$1"
      [[ -z "$val" ]] && return 0
      if [[ "$val" =~ ^rgba?\(([[:space:]]*[0-9]+)[[:space:]]*,([[:space:]]*[0-9]+)[[:space:]]*,([[:space:]]*[0-9]+)([[:space:]]*,.*)?\)$ ]]; then
        printf '#%02X%02X%02X' \
          "$(( BASH_REMATCH[1] ))" \
          "$(( BASH_REMATCH[2] ))" \
          "$(( BASH_REMATCH[3] ))"
        return 0
      fi
      printf '%s' "$val"
    }

    mode="''${theme_colors[mode]:-''${theme_colors[theme_type]:-}}"
    if [[ "$mode" == "light" || -f "$theme_path/light.mode" ]]; then
      is_light=true
    fi

    # Polkit is a semantic theme consumer. It must not inherit presentation
    # choices from a retired bar stylesheet or from Hyprlock's full-screen
    # layout. Missing optional roles fall back within the semantic palette.
    background="''${theme_colors[background]:-#111827}"
    surface="''${theme_colors[lighter_background]:-$background}"
    accent="''${theme_colors[accent]:-''${theme_colors[blue]:-#7c3aed}}"
    border="$accent"
    text="''${theme_colors[foreground]:-#e5e7eb}"
    muted_text="''${theme_colors[muted]:-''${theme_colors[dark_foreground]:-$text}}"
    placeholder="$muted_text"
    if [[ "$is_light" == true ]]; then
      default_error="#b42318"
    else
      default_error="#fb7185"
    fi
    error="''${theme_colors[red]:-$default_error}"

    background="$(to_hex "$background")"
    surface="$(to_hex "$surface")"
    border="$(to_hex "$border")"
    accent="$(to_hex "$accent")"
    text="$(to_hex "$text")"
    placeholder="$(to_hex "$placeholder")"
    muted_text="$(to_hex "$muted_text")"
    error="$(to_hex "$error")"

    mkdir -p "$(dirname "$output_path")"
    jq -n \
      --arg background "$background" \
      --arg surface "$surface" \
      --arg border "$border" \
      --arg accent "$accent" \
      --arg text "$text" \
      --arg mutedText "$muted_text" \
      --arg placeholder "$placeholder" \
      --arg error "$error" \
      --argjson light "$is_light" \
      '{
        background: $background,
        surface: $surface,
        border: $border,
        accent: $accent,
        text: $text,
        mutedText: $mutedText,
        placeholder: $placeholder,
        error: $error,
        light: $light
      }' > "$output_path"
  '';
}
