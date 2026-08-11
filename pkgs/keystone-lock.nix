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
  text = builtins.readFile ../modules/home/scripts/keystone-lock.sh;
  meta.description = "Establish and verify a Hyprland session lock";
  meta.license = lib.licenses.mit;
}
