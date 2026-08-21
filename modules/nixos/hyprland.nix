# Keystone Desktop — Hyprland environment (full implementation).
{
  config,
  lib,
  options,
  pkgs,
  desktopInputs,
  ...
}:
with lib;
let
  cfg = config.keystone.desktop;
  # CRITICAL: XDG_SESSION_CLASS=user must be in the command environment so pam_systemd.so
  # sees it before registering the logind session. The PAM class= argument alone is not
  # sufficient — pam_systemd gives XDG_SESSION_CLASS env var highest precedence.
  # Without this, the session registers as Class=greeter on seat0, causing polkit's
  # allow_active=yes policy to deny access — breaking pcscd, YubiKey PIV, and power management.
  # uwsm 0.26.4 (nixpkgs 26.11) gained a readability check in
  # `check_path()`. Resolving the bare name "Hyprland" lands on
  # `/run/wrappers/bin/Hyprland` (setuid wrapper, mode 4750), which
  # has no read bit, so env-preloader fails before Hyprland starts.
  # Pass the unwrapped binary path; this drops CAP_SYS_NICE but
  # keeps the compositor launchable.
  hyprlandCmd = "env XDG_SESSION_CLASS=user uwsm start -F ${config.programs.hyprland.package}/bin/Hyprland";
in
{
  config = mkIf (cfg.enable && cfg.environment == "hyprland") {
    # Hyprland with UWSM (using official flake for latest features)
    programs.hyprland = {
      enable = mkDefault true;
      withUWSM = mkDefault true;
      package = mkDefault desktopInputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      portalPackage = mkDefault pkgs.xdg-desktop-portal-hyprland; # Use stable nixpkgs version to fix Qt version mismatch
    };

    # hyprlock's binary is installed below, but the PAM stack is system state
    # that only the NixOS module provides. Without it hyprlock logs
    # `Pam module "/etc/pam.d/hyprlock" does not exist!` and falls back to
    # /etc/pam.d/su, where auth fails as pam_unix(su:auth) and the screen
    # cannot be unlocked. The generated service also picks up fprintd, which
    # the shared hyprlock.conf expects (auth:fingerprint:enabled).
    # See ks-config#6.
    programs.hyprlock.enable = mkDefault true;

    # greetd opens the long-lived graphical session without a password, so
    # gnome-keyring-daemon starts in the locked state and the first Hyprlock
    # authentication below supplies the password that creates or unlocks the
    # login keyring.
    security.pam.services = {
      # Inert on pins where greetd substacks `login` (the daemon is started by
      # the login stack, which upstream gnome-keyring.nix already enables, and
      # which tests/default.nix asserts against). Retained for pins where
      # greetd renders its own stack.
      greetd.enableGnomeKeyring = mkDefault true;

      # Password authentication on any later lock can unlock a keyring that
      # was explicitly locked or restarted. The user's normal Hyprlock config
      # remains free to offer native parallel fingerprint authentication.
      hyprlock.enableGnomeKeyring = mkDefault true;

      # The first visible authentication surface after boot is Hyprlock, but
      # it must collect the account password: a fingerprint carries no
      # PAM_AUTHTOK and cannot unlock an encrypted login keyring. This service
      # is selected only by keystone-lock --startup's Nix-owned config.
      hyprlock-startup = {
        enableGnomeKeyring = mkDefault true;
        fprintAuth = mkForce false;
      };
    };

    # programs.hyprlock enables the NixOS services.hypridle module. That
    # module installs an /etc/systemd/user drop-in whose PATH overrides the
    # PATH on the Home Manager hypridle unit below it, so the keystone hooks
    # must be added here to survive; otherwise the before-sleep lock fails as
    # "command not found" and sleep continues without an established session
    # lock. hyprctl is deliberately inherited from the upstream
    # services.hypridle path, so the hypridle-hook-path check pins it against
    # the rendered unit and an upstream change fails loudly. hyprlock and
    # procps arrive the same way but stay unpinned — no hook invokes them by
    # bare name (keystone-lock wraps hyprlock via runtimeInputs).
    # Gated at the attrset, not on `.path`: `services.hypridle.path = mkIf ...`
    # would still create the `hypridle` attribute and render an ExecStart-less
    # unit into /etc/systemd/user on a host that opts out.
    systemd.user.services = mkIf config.services.hypridle.enable {
      hypridle.path = with pkgs; [
        keystone-desktop.keystone-dpms-wake
        keystone-desktop.keystone-lock
        brightnessctl
      ];
    };

    # Hyprland owns lid suspend so it can establish a verified session lock
    # before requesting sleep. logind must not race the lid binding.
    services.logind.settings.Login.HandleLidSwitch = mkDefault "ignore";

    # Greetd launches the user's Hyprland session directly. Startup
    # authentication happens inside Hyprland via keystone-startup-lock, which
    # MUST fail closed if hyprlock cannot come up securely.
    #
    # CRITICAL: use initial_session for autologin. default_session is the
    # greeter session and can register as Class=greeter, which prevents logind
    # from handing DRM devices to Hyprland and breaks active-user polkit
    # checks. default_session is kept as an agreety fallback for the case
    # where initial_session fails before autologin succeeds.
    services.greetd = {
      enable = mkDefault true;
      settings = {
        default_session = {
          command = mkDefault "${pkgs.greetd}/bin/agreety --cmd '${hyprlandCmd}'";
          user = mkDefault "greeter";
        };
        initial_session = {
          command = mkDefault hyprlandCmd;
          user = mkDefault cfg.user;
        };
      };
    };

    # The desktop session depends on Home Manager activation having already
    # materialized mutable theme links like ~/.config/themes/current
    # and ~/.config/keystone/current/background. Without explicit ordering,
    # display-manager can start the Hyprland session before home-manager-$user
    # has finished on a fresh install, which leaves the first session without
    # wallpaper and increases the chance of startup errors in user services.
    systemd.services."home-manager-${cfg.user}" = mkIf (options ? home-manager) {
      before = [ "display-manager.service" ];
    };
    systemd.services.display-manager = mkIf (options ? home-manager) {
      wants = [ "home-manager-${cfg.user}.service" ];
      after = [ "home-manager-${cfg.user}.service" ];
    };

    # Configure PAM to register greetd session as wayland type
    # This enables loginctl lock-session to work properly
    #
    # Recent nixpkgs' greetd module sets `useDefaultRules = false` and swaps
    # the stack for `login` include/substack rules, so the built-in `systemd`
    # session rule (and its auto-assigned order) no longer exists — there a
    # settings-only definition would create a partial rule and fail eval, and
    # we must define the rule fully, ordered before the login include so this
    # pam_systemd (carrying our type/class args) is the one that registers
    # the logind session; login's own pam_systemd is then a no-op.
    #
    # On OLDER nixpkgs (pre-rework, e.g. keystone's own channel pin) there is
    # no `login` rule at all: the default auto-ordered `systemd` session rule
    # still exists, so we must only amend its settings — reading
    # `rules.session.login.order` unconditionally is an eval error there
    # ("attribute 'login' missing"). Guard every full-definition attr with
    # mkIf hasLogin: the attr NAMES stay static (only their definition lists
    # become empty), which is what keeps this free of module-system recursion.
    security.pam.services.greetd.rules.session.systemd =
      let
        sess = config.security.pam.services.greetd.rules.session;
        hasLogin = sess ? login;
      in
      {
        control = mkIf hasLogin "optional";
        modulePath = mkIf hasLogin "${config.systemd.package}/lib/security/pam_systemd.so";
        order = mkIf hasLogin (sess.login.order - 10);
        settings = {
          type = "wayland";
          # Belt-and-suspenders: also set class=user in PAM for any code path that doesn't
          # inherit the env var. The env var takes precedence per pam_systemd docs.
          class = "user";
        };
      };

    # The complete OS-level Hyprland tool set. Runtime config comes from the
    # user's stowed dotfiles (seeded from templates/), which invoke these by
    # bare name — every binary a template references must be present here
    # (enforced by the template-binaries check).
    environment.systemPackages = with pkgs; [
      hyprlock
      hypridle
      hyprsunset
      hyprpicker
      # Match the HM hyprpaper unit's ExecStart package so the daemon and any
      # hyprpaper CLI invocations agree on IPC.
      desktopInputs.hyprpaper.packages.${stdenv.hostPlatform.system}.hyprpaper
      keystone-desktop.hyprpolkitagent
      keystone-desktop.keystone-dpms-wake
      keystone-desktop.keystone-lock
      waybar
      wofi
      mako
      swayosd
      libnotify
      wl-clipboard
      wl-clip-persist
      clipse
      grim
      slurp
      satty
      wayfreeze
      brightnessctl
      playerctl
    ];
    # xdg-desktop-portal-hyprland stays wired via programs.hyprland.portalPackage.
  };
}
