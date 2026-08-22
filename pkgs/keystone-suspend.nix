{
  writeShellApplication,
  coreutils,
  systemd,
  keystone-lock,
}:
writeShellApplication {
  name = "keystone-suspend";
  runtimeInputs = [
    coreutils
    systemd
    keystone-lock
  ];
  text = builtins.readFile ../modules/home/scripts/keystone-suspend.sh;
}
