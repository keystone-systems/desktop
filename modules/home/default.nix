{
  config,
  desktopInputs,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
in
{
  imports = [
    ./components
    ./hyprland.nix
    ./quattro.nix
    ./scripts
    ./theming
    # The flake wrapper imports ks.systems/terminal before this module.
    # Desktop extends that product and does not declare terminal options.
  ];

  options.keystone.desktop = {
    enable = mkEnableOption "Keystone Desktop - Core desktop packages and utilities for Home Manager";

    powerDebug.enable = mkEnableOption ''
      journal capture of existing Hyprland compositor logs for power debugging
    '';

    environment = mkOption {
      type = types.enum [
        "hyprland"
        "gnome"
        "niri"
      ];
      default = "hyprland";
      description = ''
        Desktop environment this Home Manager configuration targets. All
        Hyprland session wiring (user units, menus, scripts, theming) is
        applied only when this is "hyprland".
      '';
    };

    health = {
      battery = {
        warningPercent = mkOption {
          type = types.ints.between 1 100;
          default = 20;
          description = "Battery percentage that triggers a low-battery warning.";
        };

        criticalPercent = mkOption {
          type = types.ints.between 1 100;
          default = 10;
          description = "Battery percentage that triggers a critical low-battery warning.";
        };
      };

      disk = {
        allLocalFilesystems = mkOption {
          type = types.bool;
          default = true;
          description = "Monitor all local filesystem mounts as well as path, plus explicit quotas on unmounted ZFS datasets and zvol parents. Memory filesystems are excluded.";
        };

        path = mkOption {
          type = types.str;
          default = "/";
          description = "Filesystem path monitored for low free space.";
        };

        warningUsedPercent = mkOption {
          type = types.ints.between 1 100;
          default = 80;
          description = "Disk utilization percentage that triggers a warning.";
        };

        criticalUsedPercent = mkOption {
          type = types.ints.between 1 100;
          default = 90;
          description = "Disk utilization percentage that triggers a critical warning.";
        };
      };
    };

    uhk = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Install the Ultimate Hacking Keyboard agent";
      };
    };

    audio = {
      defaults = {
        sink = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default output device name to apply at desktop session start.";
        };

        source = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default input device name to apply at desktop session start.";
        };
      };
    };

    printer = {
      default = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default CUPS printer name to apply at desktop session start.";
      };
    };

    remoteDesktop = import ../remote-desktop-options.nix { inherit lib; };

    # Optional Quattro QML catalog surfaces. The shell service receives static
    # KEYSTONE_MENU_SHOW_* capability flags; guarded rows never point at a
    # command omitted from the Home Manager profile.
    photos.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Show the Photos entry in the Quattro Trigger menu.";
    };

    agents.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Show the Agents entry in the Quattro Trigger menu.";
    };

    # NOTE: no startupLockCommand option. The required systemd user unit owns
    # this security-critical fail-closed gate. A Home Manager option would let
    # a consumer weaken the invariant that graphical-session.target starts
    # only after an observable lock exists.

    integration = {
      configCheckout = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Absolute path to a Keystone fleet configuration checkout used by
          the optional Quattro update indicator. When null, the shell receives
          no checkout environment variable and the indicator stays inactive.
        '';
      };

      ksPackage = mkOption {
        type = types.nullOr types.package;
        default = pkgs.keystone.ks or null;
        defaultText = literalExpression "pkgs.keystone.ks or null";
        description = ''
          The keystone `ks` CLI package. Menus and scripts that shell out to
          `ks` are omitted when this is null (standalone use without the
          keystone overlay).
        '';
      };

      agenixPackage = mkOption {
        type = types.nullOr types.package;
        default = pkgs.keystone.agenix or null;
        defaultText = literalExpression "pkgs.keystone.agenix or null";
        description = ''
          The agenix CLI package used by the secrets menu. The menu is omitted
          when this is null.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    keystone.terminal = {
      enable = mkDefault true;
      ssh.authSock = mkDefault "%t/gcr/ssh";
      dotfiles = {
        bootstrap.template =
          desktopInputs.desktopSelf.packages.${pkgs.stdenv.hostPlatform.system}.dotfile-templates;
        packages = mkAfter [
          "hyprland"
          "omarchy"
          "walker"
          "wofi"
        ];
      };
    };

    assertions = [
      {
        assertion = cfg.health.battery.criticalPercent < cfg.health.battery.warningPercent;
        message = "keystone.desktop.health.battery.criticalPercent must be below warningPercent";
      }
      {
        assertion = cfg.health.disk.warningUsedPercent < cfg.health.disk.criticalUsedPercent;
        message = "keystone.desktop.health.disk.warningUsedPercent must be below criticalUsedPercent";
      }
      {
        assertion = lib.hasPrefix "/" cfg.health.disk.path;
        message = "keystone.desktop.health.disk.path must be an absolute path";
      }
      {
        assertion =
          cfg.integration.configCheckout == null || lib.hasPrefix "/" cfg.integration.configCheckout;
        message = "keystone.desktop.integration.configCheckout must be null or an absolute path";
      }
      {
        assertion = !config.keystone.terminal.sshAutoLoad.enable;
        message = "A Keystone desktop cannot enable keystone.terminal.sshAutoLoad; GCR is the only SSH agent for desktop users.";
      }
      {
        assertion = (cfg.remoteDesktop.username == null) == (cfg.remoteDesktop.passwordFile == null);
        message = "keystone.desktop.remoteDesktop.username and passwordFile must be set together";
      }
      {
        assertion = !cfg.remoteDesktop.enable || cfg.environment == "hyprland";
        message = "keystone.desktop.remoteDesktop requires keystone.desktop.environment = \"hyprland\"";
      }
      {
        assertion =
          cfg.remoteDesktop.passwordFile == null || lib.hasPrefix "/" cfg.remoteDesktop.passwordFile;
        message = "keystone.desktop.remoteDesktop.passwordFile must be null or an absolute path";
      }
      {
        assertion =
          cfg.remoteDesktop.passwordFile == null
          || (
            !builtins.hasContext cfg.remoteDesktop.passwordFile
            && !lib.hasPrefix "${builtins.storeDir}/" cfg.remoteDesktop.passwordFile
          );
        message = "keystone.desktop.remoteDesktop.passwordFile must be a runtime path outside the Nix store and must not carry Nix string context";
      }
    ];

    warnings =
      lib.optional
        (
          cfg.remoteDesktop.enable
          && cfg.remoteDesktop.username == null
          && (
            cfg.remoteDesktop.bindAddress == null
            || !lib.elem cfg.remoteDesktop.bindAddress [
              "127.0.0.1"
              "::1"
            ]
          )
        )
        ''
          keystone.desktop.remoteDesktop is reachable beyond loopback without RDP
          credentials. Any client that can reach ${
            if cfg.remoteDesktop.bindAddress == null then
              "the runtime Tailscale IPv4 address"
            else
              cfg.remoteDesktop.bindAddress
          }:${toString cfg.remoteDesktop.port}
          can view and control the active desktop. Configure username and
          passwordFile, or bind to loopback and use an SSH tunnel.
        '';

    # A terminal-only host may use Home Manager's OpenSSH agent. Desktops use
    # GCR exclusively so GNOME Keyring is the only passphrase store.
    services.ssh-agent.enable = mkForce false;

    # UHK Agent copies firmware docs from the Nix store into ~/.config/uhk-agent.
    # Those source files are read-only, and the app preserves that mode, which
    # breaks later updates when it tries to refresh docs for the current firmware.
    home.activation.keystoneUhkAgentCacheFix = mkIf cfg.uhk.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        uhk_cache_dir="$HOME/.config/uhk-agent/smart-macro-docs"
        if [ -d "$uhk_cache_dir" ]; then
          ${pkgs.findutils}/bin/find "$uhk_cache_dir" -type d -exec ${pkgs.coreutils}/bin/chmod u+rwx {} +
          ${pkgs.findutils}/bin/find "$uhk_cache_dir" -type f -exec ${pkgs.coreutils}/bin/chmod u+rw {} +
        fi
      ''
    );

    home.packages = optionals cfg.uhk.enable [
      pkgs.uhk-agent
    ];
  };
}
