{
  writeShellApplication,
  coreutils,
  systemd,
  util-linux,
  keystone-lock,
}:
writeShellApplication {
  name = "keystone-suspend";
  runtimeInputs = [
    coreutils
    systemd
    util-linux
    keystone-lock
  ];
  text = builtins.readFile ../modules/home/scripts/keystone-suspend.sh;
}
