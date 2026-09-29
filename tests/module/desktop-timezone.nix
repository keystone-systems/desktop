{
  pkgs,
  lib,
  disabled,
  enabled,
}:
assert !disabled.keystone.desktop.timezone.enable;
assert !(disabled.systemd.services ? keystone-timezone-override);
assert enabled.keystone.desktop.timezone.enable;
# Force both generated applications during evaluation, not only their options.
assert builtins.isString
  enabled.systemd.services.keystone-timezone-override.serviceConfig.ExecStart;
assert lib.any (
  package: package.name == "keystone-timezone-menu" && builtins.isString package.drvPath
) enabled.environment.systemPackages;
assert
  enabled.keystone.desktop.timezone.overrideFile
  == "/home/testuser/.config/omarchy/timezone-override";
assert
  enabled.systemd.services.automatic-timezoned.unitConfig.ConditionPathExists
  == "!${enabled.keystone.desktop.timezone.overrideFile}";
pkgs.runCommand "desktop-timezone"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    python3 ${./desktop-timezone-test.py} ${../../modules/nixos/scripts/timezone-apply.sh}
    touch "$out"
  ''
