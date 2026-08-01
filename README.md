# ks.systems/desktop

The Keystone desktop as a standalone flake: Hyprland session wiring, the
Keystone menu system, theming activation, and a starter set of dotfile
templates. Extracted from [ks.systems/os](https://git.ncrmro.com/ks.systems/os)
(keystone).

**Division of labor**: Nix owns binaries, session wiring
(greetd/uwsm/PAM/pipewire/portals), scripts/menus, and the templates
themselves. Runtime configuration — `hyprland.conf`, waybar, wofi, walker
config, themes — lives in **your dotfiles repo**, seeded once from
`templates/` and yours thereafter. Nix never generates or overwrites your
editable config.

This flake owns the Hyprland compositor pin (currently v0.56.0) and the
matching hyprpaper pin — consumers get a coherent compositor/tooling set
without pinning anything themselves.

## Consumption

### Via ks.systems/os (default)

If you use keystone's `mkSystemFlake` / `nixosModules.desktop`, you already
consume this flake — keystone pins it and re-exports it with glue that wires
`keystone.desktop.user` to the admin user, enables the terminal module, and
injects the keystone-built integrations (`ks`, `agenix`, slidev). Just set:

```nix
keystone.desktop = {
  enable = true;
  user = "alice";
  environment = "hyprland"; # default; "gnome"/"niri" are minimal stubs
};
```

### Standalone (no keystone)

```nix
{
  inputs.desktop.url = "git+ssh://forgejo@git.ncrmro.com:2222/ks.systems/desktop.git";

  # in your nixosSystem modules — home-manager's NixOS module is required
  # because the desktop module registers home-manager.sharedModules:
  modules = [
    home-manager.nixosModules.home-manager
    desktop.nixosModules.default
    {
      keystone.desktop = {
        enable = true;
        user = "alice";
      };
    }
  ];
}
```

`homeModules.default` is shared into every HM user automatically. Keystone-
coupled menu surfaces (system update via `ks`, secrets via `agenix`) are
hidden automatically when `keystone.desktop.integration.{ksPackage,agenixPackage}`
are null (the standalone default).

À-la-carte per-DE modules exist as `nixosModules.{hyprland,gnome,niri}` but
`nixosModules.default` (which dispatches on `keystone.desktop.environment`)
is the supported entry point.

## Seeding your dotfiles

The templates are a **starter set you copy once** into your own dotfiles repo
(stow-package layout, as used by [GNU Stow](https://www.gnu.org/software/stow/)):

```sh
nix run git+ssh://forgejo@git.ncrmro.com:2222/ks.systems/desktop.git#seed-dotfiles -- ~/repos/<me>/dotfiles/packages
cd ~/repos/<me>/dotfiles
stow -d packages -t ~ hyprland waybar wofi walker themes
```

`seed-dotfiles` skips files that already exist; pass `--force` to overwrite.
After seeding, the files are yours — edit them freely, commit them to your
dotfiles repo, and never re-seed unless you want upstream's latest starter
state.

### The user.conf / host.conf contract

The seeded `hyprland.conf` ends with:

```
source = ~/.config/themes/current/hyprland.conf   # active theme
source = ~/.config/hypr/user.conf                 # you: identity (binds, window rules)
source = ~/.config/hypr/host.conf                 # this machine: monitors, audio, printer
```

Edit these two files first:

- **`user.conf`** — personal binds, window rules, startup dispatches. Same on
  every machine.
- **`host.conf`** — monitor layout (`monitor=desc:...` lines), default audio
  sink/source, default printer. One per machine — keep a
  `hyprland-<hostname>` stow package per host and stow the right one.

Both are sourced last, so they can override anything in the shared config.
One rule is non-negotiable: `keystone-startup-lock` must remain the first
user-visible `exec-once` in `hyprland.conf` — it is the fail-closed startup
lock (see `conventions/os.hyprland-autostart.md`). The desktop module puts
every binary the templates invoke on the system PATH, so the seeded configs
work without any per-user package management.

## Pinning / overriding the desktop version

Consumers of ks.systems/os follow os's desktop pin transitively — a
`nix flake update keystone` bumps os and its pinned desktop together. To pin
or override desktop independently in your consumer flake:

```nix
{
  inputs = {
    desktop.url = "git+ssh://forgejo@git.ncrmro.com:2222/ks.systems/desktop.git";
    keystone.inputs.desktop.follows = "desktop";
  };
}
```

For local development against a checkout, use path overrides instead of
editing inputs:

```sh
nixos-rebuild build --flake .#<host> --override-input keystone/desktop path:$HOME/repos/ks.systems/desktop
```

(ks-config users: `bin/ks-dev` applies this override automatically when the
checkout exists.)

Note the compositor pin (Hyprland v0.56.0, hyprpaper v0.8.4) lives here on
purpose — hyprctl-based scripts, the hyprpaper unit, and the compositor are
all taken from the same input, so overriding this flake's `hyprland` input
piecemeal is not recommended.

## Development

```sh
nix develop        # nixfmt, nil, shellcheck, jq
nix flake check    # template lint/contract checks + headless module evals
nix fmt            # nixfmt
```

See `AGENTS.md` for editing conventions (in particular: never probe live
Wayland sessions from checks, and never reintroduce Nix-side settings
generation) and `SPEC.md` for the full behavioral spec.
