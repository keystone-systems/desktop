# ks.systems/desktop — Editing Guide

This repo is the extracted Keystone desktop: Nix owns **binaries, session
wiring (greetd/uwsm/PAM/pipewire/portals), scripts/menus, and theming
activation**; runtime configuration (hyprland.conf, waybar, wofi, walker
config, themes) is owned by the **user's dotfiles**, seeded once from
`templates/` via `nix run .#seed-dotfiles`. Do not reintroduce Nix-side
settings generation (`wayland.windowManager.hyprland.settings`,
`programs.waybar`, `programs.hyprlock`, `services.hypridle.settings`, …) —
that tree was verified dead in production and deliberately deleted during the
extraction. Config changes go to `templates/` (and the user's own dotfiles);
wiring changes go to `modules/`.

Conventions: this repo follows ks.systems/os conventions
(`code.shell-scripts`, `process.enable-by-default`) plus the locally-enforced
[`conventions/os.hyprland-autostart.md`](conventions/os.hyprland-autostart.md).
Formatting is nixfmt everywhere; shell scripts use `writeShellApplication`
(shellcheck-clean).

## Layout

| Path | Contents |
| --- | --- |
| `modules/nixos/` | `default.nix` (option surface + DE dispatch), `common.nix` (DE-agnostic), `hyprland.nix` (full), `gnome.nix`/`niri.nix` (stubs) |
| `modules/home/` | `default.nix` (HM option surface), `hyprland.nix` (session units), `components/`, `scripts/`, `theming/` |
| `pkgs/` | overlay: `pkgs.keystone-desktop.{write-polkit-theme,hyprpolkitagent,keystone-dpms-wake}` |
| `templates/` | user-agnostic stow-layout dotfile starter set (see README seed contract) |
| `tests/` | eval/grep checks wired into `checks.x86_64-linux` |

## NixOS Level (`modules/nixos/`)

```nix
keystone.desktop = {
  enable = true;
  user = "alice";              # Primary desktop user for the session
  environment = "hyprland";    # "hyprland" (full) | "gnome" | "niri" (stubs)
  obs.enable = true;           # OBS Studio (default: true, disable per-host)
};
```

**Included at NixOS level**: Hyprland + UWSM, greetd session launch (agreety
default session + `initial_session` auto-login into a locked session), startup
`hyprlock` authentication (`programs.hyprlock.enable` provides
`/etc/pam.d/hyprlock`), PipeWire audio, Bluetooth, CUPS printing,
NetworkManager, flatpak, Nerd Fonts (JetBrains Mono, Caskaydia Mono), polkit,
OOM protection (Docker/Podman get `OOMScoreAdjust = 1000`), OBS Studio with
PipeWire audio capture, and **every binary the templates invoke by bare name**
(waybar, wofi, mako, hypr* tools, grim/slurp/satty, clipse, brightnessctl,
playerctl, keystone-dpms-wake, …). The `template-binaries` check enforces that
union — stowed configs run outside any HM wrapper PATH.

**Security invariant**: when `keystone.desktop.enable = true`, the session MUST
fail closed if startup `hyprlock` cannot start. Missing theme or wallpaper state
MUST NOT expose an unlocked desktop.

**DE dispatch invariant**: every DE branch is `mkIf`-gated on the
`environment` enum; greetd and gdm must never both be configured (the
`eval-*` checks assert this). Stubs warn, they do not assert — a stub that
evaluates and minimally works beats a hard fail.

OS-level changes require a full `nixos-rebuild switch` — not just `ks build`.

## Validation safety

Desktop validation MUST NOT probe real Wayland binaries against the developer's
active session. Tools such as `hyprlock`, `hyprpaper`, `hypridle`, and
`hyprctl` will attach to the current compositor when environment variables such
as `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, and `XDG_RUNTIME_DIR` are
in scope.

When validating generated desktop config:

1. Prefer rendered-config assertions first.
2. Run real-binary smoke tests only in an isolated environment that does not
   inherit the live session variables above.
3. Prefer Nix check derivations or other non-interactive test wrappers over
   ad hoc terminal probes on the developer machine.
4. If a real session is required, use a dedicated test compositor or test host
   — never the operator's current unlocked desktop session.

CRITICAL: live-session validation can lock the operator screen, kill the active
wallpaper process, or otherwise mutate the running desktop while debugging.

## Home-Manager Level (`modules/home/`)

Session wiring only — units, scripts, menus, theming activation. Components:

| Component  | File                        | Key Detail                                              |
| ---------- | --------------------------- | ------------------------------------------------------- |
| Session    | `hyprland.nix`              | hypridle/hyprpaper/waybar user units + envelope target  |
| Launcher   | `components/launcher.nix`   | walker/elephant units + `keystone-*.lua` menus; sole importer of the walker HM module; `programs.walker.enable = false` (config from dotfiles) |
| Screenshot | `components/screenshot.nix` | `keystone-screenshot` wrapper (grim + slurp + satty)    |
| Mako       | `components/mako.nix`       | Notification daemon (themed)                            |
| Clipboard  | `components/clipboard.nix`  | clipse + wl-clipboard + wl-clip-persist wiring          |
| SwayOSD    | `components/swayosd.nix`    | Volume/brightness OSD service                           |
| Btop       | `components/btop.nix`       | System monitor (themed)                                 |
| Ghostty    | `components/ghostty.nix`    | JetBrains Mono Nerd Font, 12pt, 0.95 opacity            |
| Scripts    | `scripts/`                  | `keystone-*.sh` menus/utilities (shellcheck-enforced)   |
| Theming    | `theming/`                  | theme activation + `keystone-theme-switch`              |

Keystone-coupled packages are nullable:
`keystone.desktop.integration.{ksPackage,agenixPackage}` default to
`pkgs.keystone.* or null`; menus needing a null package are omitted (same
env-var gating as photos/agents). The `home-standalone` check evals the HM
tree against vanilla nixpkgs to keep this decoupling honest.

**Arg-name rule**: flake inputs reach modules via `_module.args.desktopInputs`
(hoisted in the flake wrappers, NEVER computed inside modules — recursion
trap). The name deliberately differs from keystone terminal's
`keystoneInputs` to avoid the "defined multiple times" HM-scope collision.

## Templates (`templates/`)

Stow-package layout, copied (never linked) into a user's dotfiles repo. Keep
them user-agnostic: no absolute home paths, no personal identifiers, no
hardware serials (`template-lint` enforces). `keystone-startup-lock` must stay
the first user-visible `exec-once` (`template-startup-lock` enforces; see the
autostart convention). Personal/host-specific matter belongs in the `user.conf`
/ `host.conf` extension points, not in the shared files.

## Theming

Themes are owned by the dotfiles repository (seeded from
`templates/themes/`) and stowed into `~/.config/themes/<name>/`; the active
theme is symlinked at `~/.config/themes/current/` and switched at runtime via
`keystone-theme-switch <name>` — no rebuild. Startup `hyprlock` must never
depend on mutable theme/wallpaper symlinks for password entry.

Available themes: tokyo-night (default), kanagawa, catppuccin,
catppuccin-latte, ethereal, everforest, flexoki-light, gruvbox, hackerman,
matte-black, nord, osaka-jade, ristretto, rose-pine, royal-green.

## Key bindings note

Bindings live in the template `hyprland.conf`, not in Nix.
**CRITICAL keyboard note**: `altwin:swap_alt_win` is enabled in the template
input block — the physical Alt key (thumb-accessible) triggers `$mod`
(`SUPER`) bindings, while physical Super + arrows send Alt + arrows for
browser back/forward. `ctrl:nocaps` remaps Caps Lock to Control.
