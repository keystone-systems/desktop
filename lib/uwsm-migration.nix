{ pkgs }:
pkgs.writeShellApplication {
  name = "keystone-uwsm-migrate";
  runtimeInputs = [ pkgs.coreutils ];
  text = builtins.readFile ./keystone-uwsm-migrate.sh;
}
