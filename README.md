# ks.systems/desktop

The Keystone desktop extends `ks.systems/terminal` with Hyprland session
wiring, graphical menus, graphical theme adapters, and graphical starter
templates. A desktop host always consumes the terminal product. A headless
host can consume the terminal product without this repository.

**Division of labor**: Nix owns binaries, session wiring
(greetd/uwsm/PAM/pipewire/portals), scripts/menus, and the templates
themselves. Runtime configuration — `hyprland.lua`, waybar, wofi, walker
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

`ks.systems/terminal` owns the four terminal adapters and the
`keystone-theme-switch` command. This product appends graphical adapter
requirements, a filtered Omarchy v3.0.2 base catalog, a sparse Keystone
graphical catalog, and a graphical reload hook. Every composed desktop theme
MUST satisfy both contracts. A theme switch affects new Zellij sessions. It
does not change a running session.

### The Lua runtime contract

Hyprland 0.56 loads `~/.config/hypr/hyprland.lua`. The main module applies the
base settings first. It then loads the active theme with an absolute
`loadfile` plus `pcall` and loads the seeded user and host overlays with
`pcall(require, ...)`:

```lua
local chunk = loadfile(os.getenv("HOME") .. "/.config/themes/current/hyprland.lua")
if chunk then pcall(chunk) end
pcall(require, "user") -- identity and personal rules
pcall(require, "monitors") -- Walker-managed monitor rules
pcall(require, "host") -- remaining host setup
```

Edit these files first:

- **`user.lua`** — personal binds, window rules, and compositor-local startup actions. Same on
  every machine.
- **`monitors.lua`** — monitor layout (`hl.monitor({...})` calls), also updated
  by Walker's **Save connected layout** action.
- **`host.lua`** — other compositor-local machine settings. Keep a
  `hyprland-<hostname>` stow package per host and stow the right one.

Both modules load last, so they can override the base and theme settings. A
module error remains visible in Hyprland's configuration diagnostics.

UWSM reads `.config/uwsm/env` for the common session environment and
`.config/uwsm/env-hyprland` for `HYPR*` variables. Graphical application binds
use `uwsm app --`. Home Manager owns persistent background processes as
services that require and start after `graphical-session.target`.

`hl.on("hyprland.start", ...)` MAY perform compositor-local dispatch or
configuration work. It MUST NOT launch GUI applications or long-lived
processes before the lock gate.

The required `keystone-startup-lock.service` starts after
`wayland-session-waitenv.service` and before `graphical-session.target`. The
graphical services cannot start until Hyprland exposes an observable session
lock. That first Hyprlock uses the account password to create or unlock GNOME
Keyring. Later locks MAY use the fingerprint support from the user's mutable
Hyprlock configuration. GCR is the sole desktop SSH agent and listens on
`$XDG_RUNTIME_DIR/gcr/ssh`; the desktop product disables Home Manager's
OpenSSH agent and rejects terminal SSH auto-load. Headless terminal hosts keep
their separate OpenSSH-agent policy. See `conventions/os.hyprland-autostart.md`.

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
