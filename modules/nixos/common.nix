# Keystone Desktop — DE-agnostic system configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
  # Expose only interactive fingerprint clients. Installing pkgs.fprintd
  # wholesale here would also project its D-Bus activation metadata into the
  # global system profile while services.fprintd already owns the daemon.
  fprintdCli = pkgs.runCommand "keystone-fprintd-cli" { } ''
    mkdir -p "$out/bin"
    for command in fprintd-delete fprintd-enroll fprintd-list fprintd-verify; do
      ln -s ${pkgs.fprintd}/bin/$command "$out/bin/$command"
    done
  '';
in
{
  config = mkIf cfg.enable {
    # Walker dispatches `ks update --approve` through `systemd-inhibit`
    # so suspend/shutdown can't wedge a switch. systemd-inhibit runs
    # without AllowInteractive, and walker.service lives in user@.service
    # (no logind seat session), so polkit's subject.active and
    # subject.local are both false for it. Grant the admin user the
    # inhibit-* actions directly — gating on session attributes would
    # re-break walker.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "${cfg.user}" &&
            action.id.indexOf("org.freedesktop.login1.inhibit-") == 0) {
          return polkit.Result.YES;
        }
      });
    '';

    # Flatpak support (declarative via nix-flatpak). Enabled only where a host
    # actually declares flatpaks: nix-flatpak's installer unit fetches from the
    # network on every boot, so on a host with an empty package list it is pure
    # cost, and on a host with no egress at first boot it fails and leaves the
    # system degraded.
    services.flatpak.enable = mkDefault (config.services.flatpak.packages != [ ]);

    # That installer reaches flathub but ships ordered only after
    # multi-user.target, with Restart=on-failure and RestartSec=60s. It races
    # DHCP on a cold boot and then flaps between failed and activating --
    # observed failing in one disko-VM run and absent from the next. Wait for
    # routable connectivity instead of retrying into a dead network.
    systemd.services.flatpak-managed-install = mkIf config.services.flatpak.enable {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };

    # Mesa and GPU drivers for Wayland compositors (Hyprland requires DRM/KMS).
    # Enables virtio-gpu support in VMs and hardware GPU on bare metal.
    hardware.graphics.enable = mkDefault true;

    # Pipewire audio stack
    security.rtkit.enable = mkDefault true;
    services.pulseaudio.enable = mkDefault false;
    services.pipewire = {
      enable = mkDefault true;
      alsa.enable = mkDefault true;
      pulse.enable = mkDefault true;
      jack.enable = mkDefault true;
    };
    services.pipewire.wireplumber.extraConfig."10-keystone-disable-alsa-midi-bridge" =
      mkIf (!cfg.audio.alsaMidiBridge.enable)
        {
          "wireplumber.profiles".main."monitor.alsa-midi" = "disabled";
        };
    # NixOS grants direct realtime priority, negative nice levels, and the
    # larger memlock allowance needed by JACK clients through this group.
    # RTKit remains enabled for ordinary clients, but cannot safely mediate
    # every foreign callback-thread implementation (notably WineASIO).
    users.users.${cfg.user}.extraGroups = [ "pipewire" ];

    # Bluetooth
    hardware.bluetooth.enable = mkDefault true;
    services.blueman.enable = mkDefault true;

    # Fingerprint reader daemon — required for fprintd-enroll/verify/delete to
    # find the D-Bus service. PAM integration (fprintAuth) is intentionally
    # deferred; enable the daemon first so enrollment via the Walker menu works.
    services.fprintd.enable = mkDefault true;

    # One NixOS service module owns each D-Bus provider. Quattro consumes the
    # client binaries through its private service PATH and does not publish
    # daemon metadata through environment.systemPackages.
    services.power-profiles-daemon.enable = mkDefault true;
    services.colord.enable = mkDefault true;

    # Desktop applications use the Secret Service API for local credentials
    # such as Chromium's Safe Storage key. The daemon starts with the desktop
    # session and the Hyprland module below wires its login keyring to the
    # verified startup lock password.
    services.gnome.gnome-keyring.enable = mkDefault true;

    # GCR is the only SSH agent on Keystone desktops. The startup Hyprlock PAM
    # service unlocks GNOME Keyring, which then supplies the passphrase GCR
    # needs for the user's software SSH key. mkForce is intentional: nixpkgs'
    # GNOME desktop-manager module also defines this option as mkDefault true,
    # and the desktop product owns this invariant in every environment.
    services.gnome.gcr-ssh-agent.enable = mkForce true;

    # Keep the login keyring password synchronized with account password
    # changes made through passwd.
    security.pam.services.passwd.enableGnomeKeyring = mkDefault true;

    # Printing (CUPS + Avahi/mDNS discovery)
    services.printing.enable = mkDefault true;
    services.avahi = {
      enable = mkDefault true;
      nssmdns4 = mkDefault true;
      openFirewall = mkDefault true;
    };

    # Networking (for laptops, portables, and thin clients)
    networking.networkmanager.enable = mkDefault true;
    # NOTE: the systemd-resolved default and the /etc/resolv.conf
    # direct-symlink mode (Tailscale MagicDNS) intentionally do NOT live here —
    # they write keystone.os options, so they belong to ks.systems/os's
    # desktop glue module.

    # Fonts
    fonts.packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
      nerd-fonts.jetbrains-mono
      nerd-fonts.caskaydia-mono
    ];

    # System packages for desktop environment (DE-agnostic)
    environment.systemPackages =
      with pkgs;
      [
        # Screen recording
        gpu-screen-recorder

        # Media
        ## Video Editor
        ## kdenlive disabled: broken in nixpkgs unstable (missing shaderc link in ffmpeg-full)
        # kdePackages.kdenlive
        ## Video Player
        mpv

        # Browser
        chromium

        # File management
        nautilus
        file-roller
        sushi
        loupe

        # Fingerprint CLI tools — enrollment terminal inherits user PATH, not
        # the wrapper's runtimeInputs, so the binaries must be globally present.
        fprintdCli

        # System utilities
        pavucontrol
        networkmanagerapplet
        # blueberry was removed from nixpkgs (unmaintained upstream);
        # blueman is the supported replacement.
        blueman

        # XDG portals and desktop integration
        xdg-utils
        xdg-user-dirs

        # GTK themes and cursor themes
        gnome-themes-extra
        adwaita-icon-theme
      ]
      ++ optionals cfg.obs.enable [
        (wrapOBS {
          plugins =
            with obs-studio-plugins;
            [
              obs-pipewire-audio-capture
            ]
            ++ optionals (cfg.obs.gpuType == "amd") [
              obs-vaapi
              obs-vkcapture
            ]
            ++ optionals (cfg.obs.gpuType == "intel") [
              obs-vaapi
            ]
            ++ optionals (cfg.obs.gpuType == "nvidia") [
              obs-vkcapture
            ];
        })
      ];

    # Enable polkit
    security.polkit.enable = mkDefault true;

    # XDG portal configuration
    xdg.portal = {
      enable = mkDefault true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
      ];
    };

    # This allows shell scripts to resolve /bin/bash
    systemd.tmpfiles.rules = [
      "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    ];

    # OOM Killer configuration
    # Prioritize killing docker/podman rootless processes over Hyprland.
    # Hyprland (via UWSM wayland-wm@ template) uses the systemd default of 0.
    # Setting docker/podman to +1000 ensures they are killed first in OOM scenarios.
    #
    # NOTE: We cannot set OOMScoreAdjust for wayland-wm@Hyprland directly because
    # NixOS creates a replacement unit instead of a drop-in override, which removes
    # ExecStart and breaks the UWSM template-based service entirely.
    systemd.user.services = {
      docker.serviceConfig.OOMScoreAdjust = 1000;
      podman.serviceConfig.OOMScoreAdjust = 1000;
    };
  };
}
