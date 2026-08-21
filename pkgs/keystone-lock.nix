{
  coreutils,
  hyprlandPkg,
  hyprlock,
  jq,
  lib,
  libnotify,
  systemd,
  uwsm,
  writeShellApplication,
}:
let
  startupConfig = ./keystone-hyprlock-startup.conf;
  # The startup lock's config is Nix-owned: overwrite the variable
  # unconditionally so no ambient value can select the config for the
  # password-only boot lock. Only tests that execute the source script
  # directly (tests/module/desktop-lock-recovery.nix) inject their own.
  text = ''
    export KEYSTONE_LOCK_STARTUP_CONFIG=${startupConfig}
    ${builtins.readFile ../modules/home/scripts/keystone-lock.sh}
  '';
in
writeShellApplication {
  name = "keystone-lock";
  runtimeInputs = [
    coreutils
    hyprlandPkg
    hyprlock
    jq
    libnotify
    systemd
    uwsm
  ];
  inherit text;
  # `text` is exposed so the desktop-gnome-keyring check can assert the
  # unconditional export without building the compositor closure.
  passthru = { inherit startupConfig text; };
  meta.description = "Establish and verify a Hyprland session lock";
  meta.license = lib.licenses.mit;
}
