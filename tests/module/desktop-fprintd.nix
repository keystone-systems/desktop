# desktop-fprintd — regression guard for the fprintd daemon + CLI wiring.
#
# The Walker fingerprint menu spawns `ghostty -e bash -lc '... fprintd-enroll'`
# for the actual enrollment step. That terminal does NOT inherit the wrapper's
# runtimeInputs PATH. The NixOS service owns one full provider package; a
# bin-only projection supplies the interactive clients without publishing a
# second copy of its D-Bus activation metadata.
#
# Ported from ks.systems/os during the desktop extraction: the eval is now a
# standalone consumer of this flake's nixosModules.default (no keystone.os in
# scope — home-manager's NixOS module is imported directly because the
# desktop module sets home-manager.sharedModules).
#
# Build: nix build .#checks.x86_64-linux.desktop-fprintd
{
  pkgs,
  lib,
  self,
  nixpkgs,
  home-manager,
  system,
}:
let
  result = nixpkgs.lib.nixosSystem {
    modules = [
      home-manager.nixosModules.home-manager
      self.nixosModules.default
      {
        nixpkgs.hostPlatform = system;
        system.stateVersion = "25.05";
        boot.loader.systemd-boot.enable = true;

        fileSystems."/" = {
          device = "/dev/vda1";
          fsType = "ext4";
        };

        users.users.testuser = {
          isNormalUser = true;
          initialPassword = "testpass";
        };

        keystone.desktop = {
          enable = true;
          user = "testuser";
        };
      }
    ];
  };

  fprintdEnabled = result.config.services.fprintd.enable;

  systemPackageNames = map (p: lib.getName p) result.config.environment.systemPackages;
  fprintdCliInSystemPackages = builtins.elem "keystone-fprintd-cli" systemPackageNames;
  fullFprintdProviderPaths = lib.unique (
    map toString (
      lib.filter (package: lib.getName package == "fprintd") result.config.environment.systemPackages
    )
  );
  fullFprintdProviderCount = lib.length fullFprintdProviderPaths;
  fprintdCli = lib.findFirst (
    p: lib.getName p == "keystone-fprintd-cli"
  ) (throw "keystone-fprintd-cli is missing") result.config.environment.systemPackages;
in
pkgs.runCommand "desktop-fprintd-check" { } ''
  errors=0

  if [ "${lib.boolToString fprintdEnabled}" = "true" ]; then
    echo "PASS: services.fprintd.enable is true when keystone.desktop.enable = true"
  else
    echo "FAIL: services.fprintd.enable must be true on desktop hosts — enrollment terminal inherits user PATH, not wrapper runtimeInputs" >&2
    errors=$((errors + 1))
  fi

  if [ "${lib.boolToString fprintdCliInSystemPackages}" = "true" ]; then
    echo "PASS: bin-only fprintd clients are in environment.systemPackages"
  else
    echo "FAIL: bin-only fprintd clients must be globally available" >&2
    errors=$((errors + 1))
  fi

  if [ "${toString fullFprintdProviderCount}" != 1 ]; then
    echo "FAIL: expected one distinct fprintd provider path, found ${toString fullFprintdProviderCount}" >&2
    errors=$((errors + 1))
  fi

  for command in fprintd-delete fprintd-enroll fprintd-list fprintd-verify; do
    test -x ${fprintdCli}/bin/$command || {
      echo "FAIL: bin-only fprintd projection omits $command" >&2
      errors=$((errors + 1))
    }
  done
  if [ -e ${fprintdCli}/share ]; then
    echo "FAIL: bin-only fprintd projection exposes non-binary metadata" >&2
    errors=$((errors + 1))
  fi

  if [ "$errors" -gt 0 ]; then
    exit 1
  fi

  touch "$out"
''
