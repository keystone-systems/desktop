{ pkgs, desktopInputs }:
let
  system = pkgs.stdenv.hostPlatform.system;
  quickshell = desktopInputs.quickshell.packages.${system}.quickshell;
  publicUpstreamScripts = [
    "omarchy-launch-shell"
    "omarchy-shell"
    "omarchy-shell-config"
    "omarchy-menu"
    "omarchy-menu-images"
    "omarchy-audio-input-mute"
    "omarchy-audio-output-sink"
    "omarchy-audio-output-volume"
    "omarchy-powerprofiles-list"
    "omarchy-powerprofiles-set"
    "omarchy-theme-bg-current"
    "omarchy-theme-bg-set"
    "omarchy-theme-bg-switcher"
    "omarchy-theme-color"
    "omarchy-theme-current"
    "omarchy-theme-dir"
    "omarchy-theme-list"
    "omarchy-theme-set-templates"
    "omarchy-theme-switcher"
    "omarchy-toggle"
    "omarchy-toggle-bar"
  ];
  # These commands implement enabled Quattro widgets. They belong to the
  # shell service closure, but are not Keystone's public interactive command
  # surface. Keep them out of the profile package below.
  widgetUpstreamScripts = [
    "omarchy-agent"
    "omarchy-agent-usage-update"
    "omarchy-agent-usage-claude"
    "omarchy-agent-usage-codex"
    "omarchy-agent-usage-fireworks"
    "omarchy-default-agent"
    "omarchy-cmd-missing"
    "omarchy-cmd-present"
    "omarchy-launch-tui"
    "omarchy-monitor-state"
    "omarchy-brightness-display"
    "omarchy-brightness-display-apple"
    "omarchy-brightness-display-ddc"
    "omarchy-hw-display"
    "omarchy-hyprland-monitor-focused"
    "omarchy-hyprland-monitor-focused-apple"
    "omarchy-hyprland-monitor-scaling"
    "omarchy-display-text-size"
    "omarchy-notification-send"
    "omarchy-network-status"
    "omarchy-network-band"
  ];
  upstreamScripts = publicUpstreamScripts ++ widgetUpstreamScripts;
  delegate = name: runtimeInputs: text: {
    inherit name;
    package = pkgs.writeShellApplication { inherit name runtimeInputs text; };
  };
  delegates = [
    (delegate "omarchy-theme-set" [ ] ''exec keystone-theme-switch "$@"'')
    (delegate "omarchy-update" [ ] "exec keystone-main-menu dispatch run-update")
    (delegate "omarchy-launch-floating-terminal-with-presentation"
      [
        pkgs.bash
        pkgs.ghostty
      ]
      ''
        (( $# > 0 )) || {
          echo "Usage: omarchy-launch-floating-terminal-with-presentation COMMAND [ARG ...]" >&2
          exit 2
        }
        if (( $# == 1 )); then
          command="$1"
        else
          printf -v command '%q ' "$@"
        fi
        ghostty_bin="''${KEYSTONE_GHOSTTY_BIN:-ghostty}"
        exec "$ghostty_bin" --class=org.omarchy.terminal --title=Omarchy -e bash -lc "$command"
      ''
    )
    (delegate "omarchy-update-available" [ pkgs.git ] ''
      checkout="''${KEYSTONE_CONFIG_CHECKOUT:-}"
      [[ -n "$checkout" ]] || exit 1
      [[ -d "$checkout/.git" ]] || exit 1
      git -C "$checkout" fetch --quiet origin main
      count="$(git -C "$checkout" rev-list HEAD..origin/main --count)"
      (( count > 0 ))
    '')
    (delegate "omarchy-dns" [ pkgs.networkmanager ] ''
      provider="''${1:-}"
      if [[ -z "$provider" ]]; then
        dns="$(nmcli -g IP4.DNS connection show --active 2>/dev/null | head -1)"
        case "$dns" in
          *1.1.1.1*) echo Cloudflare ;;
          *8.8.8.8*) echo Google ;;
          "") echo DHCP ;;
          *) echo Custom ;;
        esac
        exit
      fi
      case "''${provider,,}" in
        cloudflare) servers="1.1.1.1 1.0.0.1"; ignore=yes ;;
        google) servers="8.8.8.8 8.8.4.4"; ignore=yes ;;
        dhcp) servers=""; ignore=no ;;
        custom)
          echo "Custom DNS is managed declaratively on Keystone" >&2
          exit 2
          ;;
        *) echo "Usage: omarchy-dns [Cloudflare|Google|DHCP|Custom]" >&2; exit 2 ;;
      esac
      while IFS=: read -r uuid type; do
        case "$type" in 802-11-wireless|802-3-ethernet) ;; *) continue ;; esac
        nmcli connection modify "$uuid" ipv4.ignore-auto-dns "$ignore" ipv4.dns "$servers"
      done < <(nmcli -t -f UUID,TYPE connection show)
      nmcli general reload
    '')
    (delegate "omarchy-bluetooth-power" [ pkgs.bluez ] ''
      action="''${1:-}"
      case "$action" in
        on|off) exec bluetoothctl power "$action" ;;
        toggle)
          bluetoothctl show | grep -q 'Powered: yes' && exec bluetoothctl power off
          exec bluetoothctl power on
          ;;
        is-on) bluetoothctl show | grep -q 'Powered: yes' ;;
        *) echo "Usage: omarchy-bluetooth-power <on|off|toggle|is-on>" >&2; exit 2 ;;
      esac
    '')
    (delegate "omarchy-restart-bluetooth"
      [
        pkgs.bluez
        pkgs.coreutils
      ]
      ''
        bluetoothctl_bin="''${KEYSTONE_BLUETOOTHCTL_BIN:-bluetoothctl}"
        powered_off=false
        restore_bluetooth() {
          status=$?
          if [[ "$powered_off" == true ]]; then
            "$bluetoothctl_bin" power on || true
          fi
          return "$status"
        }
        trap restore_bluetooth EXIT
        "$bluetoothctl_bin" power off
        powered_off=true
        sleep 1
        "$bluetoothctl_bin" power on
        powered_off=false
        trap - EXIT
      ''
    )
    (delegate "omarchy-restart-shell" [
      pkgs.systemd
    ] "exec systemctl --user restart omarchy-shell.service")
    (delegate "omarchy-refresh-shell" [
      pkgs.systemd
    ] "exec systemctl --user reload-or-restart omarchy-shell.service")
    (delegate "omarchy-keystone-health" [ ] "exec keystone-disk-monitor json")
    (delegate "omarchy-keystone-voice" [ pkgs.procps ] ''
      if pgrep -x pw-record >/dev/null; then
        printf '{"text":"󰍬","tooltip":"Voice memo recording","class":"recording"}\n'
      else
        printf '{"text":"󰍭","tooltip":"Voice memo idle"}\n'
      fi
    '')
    (delegate "omarchy-keystone-recording" [ pkgs.procps ] ''
      pgrep -f '(^|/)gpu-screen-recorder([[:space:]]|$)' >/dev/null \
        && printf '{"text":"󰻃","tooltip":"Screen recording active","class":"recording"}\n' \
        || printf '{"text":"","tooltip":"Screen recording idle"}\n'
    '')
  ];
  publicRuntimeCommandNames = publicUpstreamScripts ++ map (entry: entry.name) delegates;
  widgetRuntimeCommandNames = widgetUpstreamScripts;
  runtimeCommandNames = publicRuntimeCommandNames ++ widgetRuntimeCommandNames;
  runtimeTree =
    pkgs.runCommand "keystone-omarchy-quattro-runtime-private"
      {
        nativeBuildInputs = [
          pkgs.makeWrapper
          pkgs.patch
          pkgs.python3
        ];
        passthru = {
          inherit quickshell;
          inherit
            publicRuntimeCommandNames
            runtimeCommandNames
            widgetRuntimeCommandNames
            ;
        };
      }
      ''
        mkdir -p "$out"
        cp -r ${desktopInputs.omarchy}/. "$out/"
        chmod -R u+w "$out"
        patch -d "$out" -p1 < ${../modules/home/patches/quattro-nixos-menu.patch}
        substituteInPlace "$out/shell/plugins/bar/Bar.qml" \
          --replace-fail \
            'outputText = data.text || String(raw || "").trim()' \
            'outputText = data.text === undefined || data.text === null ? String(raw || "").trim() : String(data.text)'
        substituteInPlace "$out/shell/plugins/bar/Bar.qml" \
          --replace-fail \
            'if ("moduleName" in target) target.moduleName = moduleName' \
            'if (!commandCustom && "moduleName" in target) target.moduleName = moduleName' \
          --replace-fail \
            'if ("settings" in target) target.settings = moduleSettings' \
            'if (!commandCustom && "settings" in target) target.settings = moduleSettings'
        rm -rf "$out/bin"
        mkdir -p "$out/bin"
        cp ${../modules/home/quattro-menu.jsonc} "$out/default/omarchy/omarchy-menu.jsonc"
        ${pkgs.lib.concatMapStringsSep "\n" (name: ''
          cp ${desktopInputs.omarchy}/bin/${name} "$out/bin/${name}"
        '') upstreamScripts}
        patchShebangs "$out/bin"
        ${pkgs.lib.concatMapStringsSep "\n" (entry: ''
          for command in ${entry.package}/bin/*; do
            ln -s "$command" "$out/bin/$(basename "$command")"
          done
        '') delegates}
      '';
  # Expose only the compatibility commands that templates and users invoke.
  # The full tree remains reachable through OMARCHY_PATH and the service PATH.
  publicRuntime =
    pkgs.runCommand "keystone-omarchy-quattro-runtime"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        passthru = {
          inherit
            publicRuntimeCommandNames
            runtimeCommandNames
            runtimeTree
            widgetRuntimeCommandNames
            ;
        };
      }
      ''
        mkdir -p "$out/bin"
        ${pkgs.lib.concatMapStringsSep "\n" (name: ''
          makeWrapper ${runtimeTree}/bin/${name} "$out/bin/${name}" \
            --prefix PATH : ${pkgs.lib.makeBinPath servicePackages}
        '') publicRuntimeCommandNames}
      '';
  runtimePackages = with pkgs; [
    quickshell
    qt6.qtimageformats
    bash
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    jq
    git
    curl
    (lib.lowPrio python3)
    ripgrep
    systemd
    procps
    util-linux
    libnotify
    desktopInputs.hyprland.packages.${system}.hyprland
    networkmanager
    iw
    iproute2
    inetutils
    bluez
    pipewire
    wireplumber
    pulseaudio
    upower
    power-profiles-daemon
    brightnessctl
    ddcutil
    wl-clipboard
    cliphist
    grim
    slurp
    satty
    imagemagick
    xdg-utils
  ];
  widgetRuntimePackages = with pkgs; [
    glib
    inotify-tools
    libxkbcommon
    uwsm
    xdg-terminal-exec
  ];
  servicePackages = runtimePackages ++ widgetRuntimePackages;
in
{
  inherit
    publicRuntime
    publicRuntimeCommandNames
    quickshell
    runtimeCommandNames
    runtimePackages
    runtimeTree
    servicePackages
    widgetRuntimeCommandNames
    widgetRuntimePackages
    ;
}
