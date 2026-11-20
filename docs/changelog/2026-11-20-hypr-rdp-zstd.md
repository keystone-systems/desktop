# Provide libzstd to the Hyprland RDP build

Expose the packaged Hyprland RDP server with its system libzstd build
dependency. The workstation build requires
`zstd-sys` to find libzstd through pkg-config. Home Manager uses the
patched package with the existing service configuration.

Built Hyprland RDP against the workstation Nixpkgs pin.
