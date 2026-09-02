# Omarchy Quattro compatibility boundary

Keystone uses Omarchy's `quattro` branch as the sole source of shell QML,
themes, templates, assets, and approved helper scripts. Quickshell comes from
its official `v0.3.1` flake and follows Keystone's `nixpkgs` input.

The packaged runtime preserves the upstream tree except for `bin/`. Keystone
replaces that directory with an explicit allowlist, patches script shebangs,
and supplies narrow delegates for operations Keystone owns. The shared
runtime-package manifest gives the shell service its private command closure.
The NixOS global profile receives only the bin-only public wrappers; the
service keeps Quickshell, widget helpers, and its larger client-tool closure in
its private `PATH`.

The current source update is pinned at `b71dcad9`. Its complete 177-commit,
235-path boundary and reproducer are recorded in the
[repository audit](quattro-repository-audit.md). Any later upstream head needs
a new delta classification before the lock moves again.

The shell service uses a closed command environment: the immutable Quattro
runtime comes first, followed by the Home Manager profile, the active NixOS
system profile, and the declared runtime packages. Quattro capture, command,
theme, and background actions enter Keystone through the public
`keystone-menu` command so background changes refresh Keystone's managed
wallpaper link.

Keystone owns service lifecycle, theme generations and rollback, privileged
operations, and package or system updates. It does not package Quattro's
installation, migration, package-manager, or system-management scripts; does
not provide a fake `pacman`; and does not permit writes to the immutable
`OMARCHY_PATH`.

The following upstream command names are compatibility surfaces:

- `omarchy-theme-set` delegates to `keystone-theme-switch`.
- `omarchy-update` delegates to Keystone's guarded update-menu dispatch.
- `omarchy-update-available` is active only when
  `keystone.desktop.integration.configCheckout` names an absolute checkout.
  The option defaults to `null`; without it the widget produces no output and
  stays hidden.
- NetworkManager, BlueZ, PipeWire, and power-profile delegates retain their
  upstream names while using NixOS-managed services.
- Theme and background pickers remain upstream behind `keystone-menu` and
  operate on Keystone's active Omarchy-compatible state tree.

Keystone continues to own Hypridle, Hyprlock, Mako, SwayOSD, Polkit,
night-light, Hyprpaper, clipboard, and related graphical services. Their
corresponding Quattro plugins are disabled in the editable Stow-managed
`~/.config/omarchy/shell.json`.
