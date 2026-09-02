# Omarchy repository audit: `b86d4505..b71dcad9`

Keystone pins Omarchy's non-flake source at
`b71dcad96e9d0b2962b7d225828a5cb6000ad720`. The complete range from the
previous deployed source, `b86d4505c11b71f90b7bd14d6a80676863a70775`, is
177 commits across 235 paths, with 14,784 insertions and 576 deletions.

The upstream `quattro` branch had moved to `d3d23fdddef846ebb98b52122a6ece66211c0daf`
when this pin was implemented on 2026-09-02. That newer range is intentionally
not consumed: `b71dcad9` is the reviewed historical target, remains fetchable,
and is the only source represented by this audit.

## Adapter boundary

`lib/quattro-runtime.nix` copies the repository, makes the immutable staging
tree writable, deletes the complete upstream `bin/`, and restores only its
explicit public and widget command allowlists. It overwrites
`default/omarchy/omarchy-menu.jsonc` with Keystone's catalog. Everything else
is immutable source or data; copying it does not install `etc/`, run
`install/` or `migrations/`, expose an omitted command, or activate an upstream
test.

The machine-readable [path manifest](audits/omarchy-b86d4505-b71dcad9.tsv)
records the full base and target revisions before classifying every changed
path into exactly one category. Both the runtime contract and the standalone
audit checker require its target to equal the Omarchy revision in `flake.lock`:

| Category | Paths | Meaning |
| --- | ---: | --- |
| `executed` | 37 | Allowlisted command or QML reachable by Keystone's enabled shell |
| `copied-inactive` | 70 | Immutable data, documentation, system/installer material, or a disabled QML plugin |
| `overwritten` | 1 | Upstream menu catalog replaced by Keystone before publication |
| `excluded-command` | 40 | Upstream implementation removed with `bin/`; a name can exist only as a separately proven Keystone delegate |
| `upstream-test-only` | 87 | Audit oracle, not part of Keystone's activated behavior |

The top-level diff reproduces these source totals:

| Surface | Paths | Insertions | Deletions | Boundary |
| --- | ---: | ---: | ---: | --- |
| `.github/`, `README.md`, `agents/`, `docs/`, `manual/` | 11 | 81 | 14 | copied inactive governance and manuals |
| `bin/` | 46 | 2,407 | 331 | six allowlisted; forty excluded |
| `default/` | 15 | 118 | 20 | copied inactive except the overwritten menu |
| `etc/` | 7 | 119 | 6 | copied, never installed into `/etc` |
| `install/` | 14 | 212 | 31 | copied, never invoked |
| `migrations/` | 15 | 1,164 | 0 | copied, never invoked |
| `shell/` | 40 | 289 | 2 | enabled QML plus explicitly disabled plugin code |
| `test/` | 87 | 10,394 | 172 | upstream-only test evidence |

## Changed allowlisted commands

Exactly six changed commands survive the `bin/` deletion. Their compatibility
contracts are asserted against the packaged runtime:

- `omarchy-agent` keeps prompted Ori sessions interactive, refuses a selected
  executable that is absent, and can name Hermes only when the `hermes`
  executable is already present.
- `omarchy-agent-usage-codex` starts the read-only Codex app server with the
  supported `on-request` approval policy.
- `omarchy-brightness-display-apple` uses only `$XDG_RUNTIME_DIR` for its cache
  and accepts cached values only when they name a `hiddev` character device.
- `omarchy-default-agent` is used without a mutating argument by the current
  shell. Its installer helpers are excluded; the adapted-menu follow-up replaces
  selection with Keystone's installed-executable-only delegate.
- `omarchy-hyprland-monitor-scaling` rejects connector names outside
  `[A-Za-z0-9._-]` before interpolating them into Hyprland Lua.
- `omarchy-toggle-bar` writes the state flag and then invokes
  `omarchy.bar syncHidden`, so rapid changes converge without restarting the
  shell.

No installer, migration, `pacman`, `yay`, or full upstream `bin/` is included
in either runtime allowlist. The audit checker derives the allowlists from the
Nix source, intersects them with the Git range, and requires all other changed
implementations to remain excluded. `omarchy-dns` is the sole same-name case:
the upstream privileged implementation is excluded, while the runtime creates
an external store symlink to Keystone's Nix-built NetworkManager delegate. The
runtime contract verifies both its provenance and its behavior.

## QML boundary

The enabled shell consumes changed shared UI, bar, agents, menu, image-picker,
media, and panel code. Changes under clipboard, developer gallery, emoji,
lock, notification, OSD, Polkit, and reminder plugins are copied but inactive
because Keystone's editable `shell.json` disables those owners. Keystone
continues to own Hyprlock, Hypridle, Mako, SwayOSD, Polkit, night-light, and
clipboard services.

The compatibility check requires the exact disabled-plugin set, the upstream
plain-text QML scanner, and the notification sanitizer test. The last remains
defense-in-depth evidence for copied code even though Mako is the active
notification owner.

## Reproduction

Run the static audit against any Git checkout containing both commits:

```sh
./tests/quattro-repository-audit.sh /path/to/omarchy
```

The checker proves the commit count and diff totals, exact 235-path coverage,
unique classifications, allowlisted/excluded command partition, overwritten
menu, upstream-test boundary, and disabled-plugin classification. It performs
no build, evaluation, installation, or activation.
