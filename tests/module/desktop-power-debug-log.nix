{
  pkgs,
  lib,
  disabled,
  enabled,
  gnome,
}:
let
  name = "keystone-hyprland-power-log";
  present = config: builtins.hasAttr name config.systemd.user.services;
  unit = enabled.systemd.user.services.${name};
in
pkgs.runCommand "desktop-power-debug-log"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    optionDefaultOff = lib.boolToString (!disabled.keystone.desktop.powerDebug.enable);
    serviceOff = lib.boolToString (!present disabled);
    serviceOn = lib.boolToString (present enabled);
    serviceGnomeOff = lib.boolToString (!present gnome);
    sessionBound = lib.boolToString (
      lib.elem "graphical-session.target" unit.Unit.PartOf
      && lib.elem "graphical-session.target" unit.Unit.Requisite
      && lib.elem "graphical-session.target" unit.Install.WantedBy
      && lib.elem "wayland-session-waitenv.service" unit.Unit.After
      && !(unit.Unit ? Requires)
    );
    rateLimited = lib.boolToString (
      unit.Service.LogRateLimitBurst == 500 && unit.Service.LogRateLimitIntervalSec == "30s"
    );
  }
  ''
    set -eu
    for result in "$optionDefaultOff" "$serviceOff" "$serviceOn" "$serviceGnomeOff" "$sessionBound" "$rateLimited"; do
      test "$result" = true
    done
    python3 ${./desktop-power-debug-log-test.py} ${../../modules/home/scripts/keystone-hyprland-power-log.py}
    touch "$out"
  ''
