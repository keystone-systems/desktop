{
  config,
  lib,
  pkgs,
  desktopInputs,
  ...
}:
let
  cfg = config.keystone.desktop;
  themeCfg = config.keystone.terminal.theme;
  omarchyThemeNames = lib.intersectLists desktopInputs.terminalThemeNames (
    builtins.attrNames (
      lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${desktopInputs.omarchy}/themes")
    )
  );
  omarchyThemeCatalog = pkgs.linkFarm "omarchy-theme-catalog" (
    map (name: {
      inherit name;
      path = "${desktopInputs.omarchy}/themes/${name}";
    }) omarchyThemeNames
  );
  writePolkitThemePackage =
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.write-polkit-theme;
  writePolkitTheme = "${writePolkitThemePackage}/bin/keystone-write-polkit-theme";
  quattro = import ../../../lib/quattro-runtime.nix { inherit pkgs desktopInputs; };
  renderer = pkgs.writeShellApplication {
    name = "keystone-theme-render";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      if [ "$#" -ne 2 ]; then
        echo "Usage: keystone-theme-render THEME GENERATION" >&2
        exit 2
      fi
      theme="$1"
      generation="$2"
      tmp_home="$(mktemp -d)"
      trap 'rm -rf "$tmp_home"' EXIT
      mkdir -p "$tmp_home/.local/state/omarchy/current" "$tmp_home/.config/omarchy/themed"
      ln -s "$generation" "$tmp_home/.local/state/omarchy/current/next-theme"
      cp ${./templates}/*.tpl "$tmp_home/.config/omarchy/themed/"
      # Hyprlock consumes only the generated palette variables. Discard a
      # catalog-provided full config so the semantic template always wins.
      rm -f "$generation/hyprlock.conf"
      HOME="$tmp_home" OMARCHY_PATH="${quattro.runtimeTree}" \
        PATH="${quattro.runtimeTree}/bin:$PATH" \
        ${quattro.runtimeTree}/bin/omarchy-theme-set-templates
      # Product-owned notification actions must reach existing hosts through
      # the immutable generation. Append the shared core directly so Mako does
      # not depend on a one-time seed or a mutable Stow path being present.
      cat ${../../../templates/themes/.local/share/omarchy/default/mako/core.ini} \
        >> "$generation/mako.ini"
      # Hyprlock treats `#` as a comment marker when a variable expands, even
      # though direct color fields accept rgb(#rrggbb). Normalize rendered hex
      # colors to its canonical rgb(rrggbb) form before the generation lands.
      sed -i -E 's/rgb\(#([0-9a-fA-F]{6})\)/rgb(\1)/g' "$generation/hyprlock.conf"
      printf '%s\n' "$theme" > "$generation/theme.name"
    '';
  };
  hook = pkgs.writeShellApplication {
    name = "keystone-theme-hook";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.glib
      pkgs.libnotify
      pkgs.procps
      pkgs.systemd
      quattro.runtimeTree
    ];
    text = ''
      if [ "$#" -ne 2 ]; then
        echo "Usage: keystone-theme-hook THEME_NAME THEME_PATH" >&2
        exit 2
      fi
      theme_name="$1"
      theme_path="$2"
      config_home="${config.xdg.configHome}"
      runtime_dir="$config_home/keystone/current"
      omarchy_state="${config.xdg.stateHome}/omarchy/current"
      mkdir -p "$runtime_dir"
      mkdir -p "$omarchy_state"
      ln -sfn "$theme_path" "$omarchy_state/theme"
      printf '%s\n' "$theme_name" > "$omarchy_state/theme.name"

      ${writePolkitTheme} "$theme_path" "$runtime_dir/polkit.json"

      background="$(${pkgs.jq}/bin/jq -r '.background // empty' "$theme_path/.keystone-theme.json")"
      if [ -n "$background" ] && [ -f "$theme_path/$background" ]; then
        ln -sfn "$theme_path/$background" "$runtime_dir/background"
        ln -sfn "$theme_path/$background" "$omarchy_state/background"
      fi

      # Home Manager activation may run without a graphical session or GNOME
      # schemas. dconf.settings above remains authoritative; these calls only
      # refresh a live session and MUST NOT abort the transactional switch.
      if grep -Eq '^(mode|theme_type)[[:space:]]*=[[:space:]]*"light"' "$theme_path/colors.toml"; then
        gsettings set org.gnome.desktop.interface color-scheme prefer-light 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme Adwaita 2>/dev/null || true
      else
        gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark 2>/dev/null || true
      fi
      gsettings set org.gnome.desktop.interface icon-theme "$(<"$theme_path/icons.theme")" 2>/dev/null || true

      systemctl --user restart hyprpaper.service 2>/dev/null || true
      systemctl --user restart mako.service walker.service hyprpolkitagent.service 2>/dev/null || true
      omarchy-shell -q shell reloadConfig 2>/dev/null || true
      pkill -SIGUSR2 ghostty 2>/dev/null || true
      "${
        desktopInputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland
      }/bin/hyprctl" reload 2>/dev/null || true
      notify-send "Theme Changed" "Switched to $theme_name theme" -t 3000 2>/dev/null || true
    '';
  };
  lightThemes = [
    "catppuccin-latte"
    "flexoki-light"
    "rose-pine"
  ];
  isLightTheme = builtins.elem themeCfg.name lightThemes;
in
{
  config = lib.mkIf (cfg.enable && cfg.environment == "hyprland") {
    keystone.terminal.theme.catalogs = [
      {
        name = "terminal";
        path = desktopInputs.terminalThemeCatalog;
      }
      {
        name = "omarchy";
        path = omarchyThemeCatalog;
      }
      {
        name = "desktop";
        path = desktopInputs.desktopSelf.lib.templatesPath + "/themes/.config/themes";
      }
    ];
    keystone.terminal.theme.adapters = lib.mkAfter [
      {
        source = "mako.ini";
        target = "${config.xdg.configHome}/mako/config";
      }
    ];
    keystone.terminal.theme.requiredPaths = lib.mkAfter [
      "hyprland.lua"
      "colors.toml"
      "shell.toml"
      "swayosd.css"
      "walker.css"
      "hyprlock.conf"
      "chromium.theme"
      "ghostty.conf"
      "icons.theme"
      "backgrounds"
      "wofi.css"
      "clipse.toml"
    ];
    keystone.terminal.theme.renderHooks = [ renderer ];
    keystone.terminal.theme.postSwitchHooks = [ hook ];

    gtk = {
      enable = true;
      theme = {
        name = if isLightTheme then "Adwaita" else "Adwaita-dark";
        package = pkgs.gnome-themes-extra;
      };
      gtk4.theme = lib.mkDefault null;
    };
    dconf.settings."org/gnome/desktop/interface" = {
      color-scheme = if isLightTheme then "prefer-light" else "prefer-dark";
      gtk-theme = if isLightTheme then "Adwaita" else "Adwaita-dark";
    };
  };
}
