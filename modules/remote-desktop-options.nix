{ lib }:
with lib;
{
  enable = mkEnableOption "the Hyprland RDP server";

  bindAddress = mkOption {
    type = types.nullOr (types.strMatching ".+");
    default = null;
    example = "127.0.0.1";
    description = ''
      Address on which hypr-rdp listens. When null, the service discovers and
      binds the host's Tailscale IPv4 address at runtime. Set this to a loopback
      address to require an SSH tunnel. Binding a LAN, VPN, wildcard, or public
      address without credentials allows every client that can reach the port
      to control the unlocked desktop.
    '';
  };

  port = mkOption {
    type = types.port;
    default = 3389;
    description = "TCP port on which hypr-rdp listens.";
  };

  output = mkOption {
    type = types.nullOr (types.strMatching ".+");
    default = null;
    example = "DP-1";
    description = ''
      Existing Hyprland output to capture. When null, the service selects the
      first active output that it did not create itself. Hyprland has no
      primary-output flag, so this ordered active output is Keystone's portable
      definition of the primary display. The service never creates a headless
      output by default.
    '';
  };

  username = mkOption {
    type = types.nullOr (types.strMatching ".+");
    default = null;
    description = ''
      RDP username. Authentication is enabled only when both this option and
      passwordFile are set.
    '';
  };

  passwordFile = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "/run/secrets/hypr-rdp-password";
    description = ''
      Absolute path to a runtime file containing the RDP password. The password
      MUST come from a secret manager and MUST NOT be written as Nix text or
      otherwise copied into the Nix store.
    '';
  };
}
