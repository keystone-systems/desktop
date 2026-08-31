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
  hyprlockExecutable = lib.getExe hyprlock;
  normalCommand = "${hyprlockExecutable} --immediate-render";
  startupCommand = "${normalCommand} --config ${startupConfig}";
  text = builtins.readFile ../modules/home/scripts/keystone-lock.sh;
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
  # Expose the fixed commands so the Home Manager units and rendered-config
  # checks use exactly the same Hyprlock binary and startup config.
  passthru = {
    inherit
      hyprlockExecutable
      normalCommand
      startupCommand
      startupConfig
      text
      ;
  };
  meta.description = "Establish and verify a Hyprland session lock";
  meta.license = lib.licenses.mit;
}
