{
  config,
  lib,
  pkgs,
  desktopInputs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
  hyprpaperPkg = desktopInputs.hyprpaper.packages.${pkgs.stdenv.hostPlatform.system}.hyprpaper;
  keystoneLockPkg =
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.keystone-lock;
  keystoneDpmsWakePkg =
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.keystone-dpms-wake;
  hyprlandPkg = desktopInputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
  hyprpolkitagentPkg =
    desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.hyprpolkitagent;
  powerLog = pkgs.writeTextFile {
    name = "keystone-hyprland-power-log";
    executable = true;
    destination = "/bin/keystone-hyprland-power-log";
    text = ''
      #!${pkgs.python3}/bin/python3
      ${builtins.readFile ./scripts/keystone-hyprland-power-log.py}
    '';
  };
  hyprRdpPkg = desktopInputs.hypr-rdp.packages.${pkgs.stdenv.hostPlatform.system}.hypr-rdp;
  remoteDesktopCommand = pkgs.writeShellApplication {
    name = "keystone-hypr-rdp";
    text = ''
      bind_address=${
        lib.escapeShellArg (
          if cfg.remoteDesktop.bindAddress == null then "" else cfg.remoteDesktop.bindAddress
        )
      }
      if [[ -z "$bind_address" ]]; then
        if ! bind_address="$("${lib.getExe pkgs.tailscale}" ip -4 2>/dev/null)"; then
          echo "keystone-hypr-rdp: could not discover a Tailscale IPv4 address" >&2
          exit 1
        fi
      fi
      if [[ -z "$bind_address" ]]; then
        echo "keystone-hypr-rdp: Tailscale has no IPv4 address" >&2
        exit 1
      fi
      if [[ "$bind_address" == *:* ]]; then
        bind="[$bind_address]:${toString cfg.remoteDesktop.port}"
      else
        bind="$bind_address:${toString cfg.remoteDesktop.port}"
      fi

      output=${
        lib.escapeShellArg (if cfg.remoteDesktop.output == null then "" else cfg.remoteDesktop.output)
      }
      if [[ -z "$output" ]]; then
        output="$("${lib.getExe' hyprlandPkg "hyprctl"}" monitors -j \
          | "${lib.getExe pkgs.jq}" -er \
            '[.[] | select(.name | startswith("hypr-rdp") | not)][0].name // empty')"
      fi
      if [[ -z "$output" ]]; then
        echo "keystone-hypr-rdp: no existing active Hyprland output found" >&2
        exit 1
      fi

      command=(
        "${lib.getExe hyprRdpPkg}"
        --bind "$bind"
        --output "$output"
      )
      ${lib.optionalString (cfg.remoteDesktop.username != null) ''
        command+=(
          --username ${lib.escapeShellArg cfg.remoteDesktop.username}
          --password-file ${lib.escapeShellArg cfg.remoteDesktop.passwordFile}
        )
      ''}
      exec "''${command[@]}"
    '';
  };
  graphicalService = description: execStart: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      Requisite = [ "graphical-session.target" ];
    };
    Service.ExecStart = execStart;
    Install.WantedBy = [ "graphical-session.target" ];
  };
  hyprlockService =
    {
      description,
      execStart,
      conflictsWith,
    }:
    {
      Unit = {
        Description = description;
        Requires = [ "wayland-session-waitenv.service" ];
        After = [ "wayland-session-waitenv.service" ];
        PartOf = [ "wayland-session@Hyprland.target" ];
        Conflicts = [
          conflictsWith
          "wayland-session-shutdown.target"
        ];
      };
      Service = {
        ExecStart = execStart;
        Restart = "on-failure";
        RestartSec = 1;
      };
    };
in
{
  # Session wiring only. Hyprland/hypridle/hyprlock/hyprpaper settings
  # are NOT generated here — editable configuration comes from the user's
  # stowed dotfiles (seed with `nix run .#seed-dotfiles`). Nix owns the
  # binaries (OS-level) and these hand-written user units.
  config = mkIf (cfg.enable && cfg.environment == "hyprland") {
    home.packages = [ keystoneLockPkg ] ++ lib.optional cfg.remoteDesktop.enable hyprRdpPkg;

    # Generic session invariants are immutable runtime wiring. UWSM inherits
    # profile PATH and XDG_DATA_DIRS from the user manager; reconstructing
    # either here duplicates profile entries and makes activation order part of
    # the session contract. Terminal remains the sole owner of EDITOR.
    xdg.configFile."uwsm/env".text = ''
      export GDK_SCALE=2
      export XCURSOR_SIZE=24
      export XCURSOR_THEME=Adwaita
      export GDK_BACKEND=wayland,x11
      export QT_QPA_PLATFORM="wayland;xcb"
      export QT_STYLE_OVERRIDE=kvantum
      export SDL_VIDEODRIVER=wayland
      export MOZ_ENABLE_WAYLAND=1
      export ELECTRON_OZONE_PLATFORM_HINT=wayland
      export OZONE_PLATFORM=wayland
      export CHROMIUM_FLAGS="--enable-features=UseOzonePlatform --ozone-platform=wayland --gtk-version=4"
      export XCOMPOSEFILE="$HOME/.XCompose"
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
    '';

    # Run before Home Manager links the generated file. Remove only the exact
    # retired Stow source and the exact broken legacy HM generation target;
    # every other filesystem type or symlink target fails closed.
    home.activation.keystoneUwsmEnvironmentOwnership = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      source ${../../lib/keystone-uwsm-migrate.sh}
    '';

    # UWSM session target fix: greetd starts wayland-session-envelope@ but not
    # wayland-session@ which is what binds to graphical-session.target.
    # hypridle and other services depend on graphical-session.target, so we need
    # to ensure wayland-session@ is started when the envelope starts.
    # See: https://github.com/hyprwm/Hyprland/issues/9342
    systemd.user.targets."wayland-session-envelope@Hyprland" = {
      Unit = {
        Wants = [ "wayland-session@Hyprland.target" ];
      };
    };

    # This one-shot is a required transaction gate. UWSM first publishes and
    # verifies WAYLAND_DISPLAY. The lock must then become observable before
    # graphical-session.target can activate any user-visible service.
    systemd.user.services.keystone-startup-lock = {
      Unit = {
        Description = "Verify the startup session lock";
        Requires = [ "wayland-session-waitenv.service" ];
        After = [ "wayland-session-waitenv.service" ];
        Before = [ "graphical-session.target" ];
        Conflicts = [ "wayland-session-shutdown.target" ];
        OnFailure = [ "wayland-session-shutdown.target" ];
        OnFailureJobMode = "replace-irreversibly";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${config.home.profileDirectory}/bin/keystone-startup-lock";
        RemainAfterExit = true;
      };
      Install.RequiredBy = [ "graphical-session.target" ];
    };

    # Hyprlock must run under the user manager, not as a child of whichever
    # caller happened to request a lock. In particular, a recovery requested
    # over SSH otherwise inherits a remote logind session and fprintd rejects
    # native fingerprint verification. Restarting only on failure preserves a
    # normal successful unlock while automatically replacing a crashed lock
    # client. The Hyprland template enables allow_session_lock_restore so that
    # replacement can take ownership without unlocking the compositor.
    systemd.user.services.keystone-hyprlock = hyprlockService {
      description = "Keystone Hyprlock session lock";
      execStart = keystoneLockPkg.normalCommand;
      conflictsWith = "keystone-hyprlock-startup.service";
    };

    systemd.user.services.keystone-hyprlock-startup = hyprlockService {
      description = "Keystone password-only startup lock";
      execStart = keystoneLockPkg.startupCommand;
      conflictsWith = "keystone-hyprlock.service";
    };

    systemd.user.services.keystone-audio-defaults =
      mkIf (cfg.audio.defaults.sink != null || cfg.audio.defaults.source != null)
        {
          Unit = {
            Description = "Apply Keystone audio defaults";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
            Requisite = [ "graphical-session.target" ];
          };
          Service = {
            Type = "oneshot";
            Environment =
              lib.optional (
                cfg.audio.defaults.sink != null
              ) "KEYSTONE_AUDIO_DEFAULT_SINK=${cfg.audio.defaults.sink}"
              ++ lib.optional (
                cfg.audio.defaults.source != null
              ) "KEYSTONE_AUDIO_DEFAULT_SOURCE=${cfg.audio.defaults.source}";
            ExecStart = "${config.home.profileDirectory}/bin/keystone-audio-menu apply-config-defaults";
            RemainAfterExit = true;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

    systemd.user.services.keystone-printer-default = mkIf (cfg.printer.default != null) {
      Unit = {
        Description = "Apply the Keystone printer default";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        Environment = [ "KEYSTONE_PRINTER_DEFAULT=${cfg.printer.default}" ];
        ExecStart = "${config.home.profileDirectory}/bin/keystone-printer-menu apply-config-defaults";
        RemainAfterExit = true;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.hypridle = {
      Unit = {
        Description = "Hyprland idle manager";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hypridle}/bin/hypridle";
        Restart = "on-failure";
        RestartSec = "1s";
        # hypridle runs every listener command through /bin/sh, so the command
        # resolves against THIS unit's PATH. The systemd user manager gives a
        # closed PATH that holds only the session packages — `environment.
        # systemPackages` does not reach a user service. Every binary the
        # stowed hypridle.conf invokes by bare name must therefore be listed
        # here, or the listener silently fails with "command not found" while
        # the `||` fallback hides it. This is how keystone-dpms-wake stayed
        # unreachable for weeks despite being installed system-wide.
        Environment = [
          "PATH=${
            makeBinPath [
              keystoneDpmsWakePkg
              keystoneLockPkg
              hyprlandPkg
              pkgs.brightnessctl
              pkgs.procps
              pkgs.coreutils
            ]
          }"
        ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.hyprpaper = {
      Unit = {
        Description = "Hyprland wallpaper daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service.ExecStart = "${hyprpaperPkg}/bin/hyprpaper";
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.keystone-hyprland-power-log = mkIf cfg.powerDebug.enable {
      Unit = {
        Description = "Preserve existing Hyprland compositor logs";
        PartOf = [ "graphical-session.target" ];
        After = [
          "graphical-session.target"
          "wayland-session-waitenv.service"
        ];
        Requisite = [ "graphical-session.target" ];
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 3;
      };
      Service = {
        ExecStart = "${powerLog}/bin/keystone-hyprland-power-log";
        SyslogIdentifier = "keystone-hyprland-power-log";
        Nice = 10;
        CPUQuota = "5%";
        MemoryMax = "64M";
        LogRateLimitIntervalSec = "30s";
        LogRateLimitBurst = 500;
        Restart = "on-failure";
        RestartSec = "30s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.hyprsunset =
      lib.recursiveUpdate
        (graphicalService "Hyprland blue-light filter" "${pkgs.hyprsunset}/bin/hyprsunset")
        {
          Service.ExecCondition = "${pkgs.bash}/bin/bash -c 'for card in /sys/class/drm/card*/device/driver; do readlink -f \"$card\" 2>/dev/null; done | grep -q virtio && exit 1 || exit 0'";
        };

    systemd.user.services.hyprpolkitagent = graphicalService "Hyprland polkit authentication agent" "${hyprpolkitagentPkg}/libexec/hyprpolkitagent";

    systemd.user.services.keystone-hypr-rdp = mkIf cfg.remoteDesktop.enable (
      lib.recursiveUpdate (graphicalService "Hyprland RDP server" (lib.getExe remoteDesktopCommand)) {
        Service = {
          TimeoutStopSec = "5s";
          UMask = "0077";
        };
      }
    );

  };
}
