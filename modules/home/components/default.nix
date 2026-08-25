{
  ...
}:
{
  imports = [
    ./btop.nix
    ./clipboard.nix
    ./ghostty.nix
    ./launcher.nix
    ./mako.nix
    ./screenshot.nix
    ./swayosd.nix
  ];

  # Components don't need their own options - they're enabled by keystone.desktop.enable
  # (and, being Hyprland session content, keystone.desktop.environment == "hyprland").
}
