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
  writePolkitTheme = "${
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.write-polkit-theme
  }/bin/keystone-write-polkit-theme";
  hook = pkgs.writeShellApplication {
    name = "keystone-theme-hook";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.glib
      pkgs.jq
      pkgs.libnotify
      pkgs.procps
      pkgs.systemd
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
      mkdir -p "$runtime_dir" "$config_home/mako"

      ${writePolkitTheme} "$theme_path" "$runtime_dir/polkit.json"
      ln -sfn "$theme_path/mako.ini" "$config_home/mako/config"

      background="$(${pkgs.jq}/bin/jq -r '.background // empty' "$theme_path/.keystone-theme.json")"
      if [ -n "$background" ] && [ -f "$theme_path/$background" ]; then
        ln -sfn "$theme_path/$background" "$runtime_dir/background"
      fi

      # Home Manager activation may run without a graphical session or GNOME
      # schemas. dconf.settings above remains authoritative; these calls only
      # refresh a live session and MUST NOT abort the transactional switch.
      if [ -f "$theme_path/light.mode" ]; then
        gsettings set org.gnome.desktop.interface color-scheme prefer-light 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme Adwaita 2>/dev/null || true
      else
        gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark 2>/dev/null || true
      fi
      gsettings set org.gnome.desktop.interface icon-theme "$(<"$theme_path/icons.theme")" 2>/dev/null || true

      systemctl --user restart hyprpaper.service 2>/dev/null || true
      systemctl --user reload waybar.service 2>/dev/null || true
      systemctl --user restart mako.service walker.service hyprpolkitagent.service 2>/dev/null || true
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
        path = ../../.. + "/templates/themes/.config/themes";
      }
    ];
    keystone.terminal.theme.requiredPaths = lib.mkAfter [
      "hyprland.lua"
      "waybar.css"
      "mako.ini"
      "swayosd.css"
      "walker.css"
      "hyprlock.conf"
      "chromium.theme"
      "ghostty.conf"
      "icons.theme"
      "backgrounds"
    ];
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
