# Quattro Shell Repair

Stage: **Rereview** — PR #20 is repaired on `feat/quattro-shell`; deployment is
outside this repository's landing work.

Outcome: Keystone MUST provide an immutable Omarchy Quattro runtime, supervised
password-only startup authentication, normal interactive lock recovery,
semantic theme rendering, and a Waybar-free desktop shell. Public modules MUST
NOT assume Nicholas's fleet checkout layout.

## Current contract

- `keystone-startup-lock` invokes `keystone-lock --startup`. Startup mode MUST
  use only `keystone-hyprlock-startup.service`, whose PAM stack accepts a
  password and opens the login keyring without fingerprint authentication.
- Ordinary `keystone-lock` calls MAY recover either supervised lock unit, but
  MUST NOT replace an active startup lock. Ordinary runtime lock failure
  reports an error; only the bounded startup gate owns fail-closed session
  teardown.
- `keystone-suspend` owns interactive and lid-triggered suspend. Lid requests
  MUST be serialized, MUST establish the lock before suspend, and MUST preserve
  the explicit AC-only deadline behavior.
- Quattro owns the bar. Waybar templates, signals, commands, tests, and palette
  dependencies MUST NOT return.
- The Quattro service PATH MUST contain the immutable runtime, the Home Manager
  profile, `/run/current-system/sw/bin`, and the declared runtime tools. The
  large tool closure MUST remain service-private instead of being copied into
  the interactive Home Manager profile.
- Capture, command-widget, theme, background, and bar-toggle actions MUST use
  supported public Keystone or Quattro commands. Optional fleet update state
  MUST remain hidden unless the consumer configures an absolute checkout.
- Theme generations MUST own the five Hyprlock palette variables and Polkit
  semantic colors. Catalog themes MUST NOT carry separate Hyprlock fragments.

## Projected history

Time flows upward. The PR preserves its individual repair commits.

```text
◉  refactor(shell): retire remaining Waybar surfaces
●  fix(theme): constrain Quattro theme generation
●  fix(quattro): close the shell command environment
●  fix(hyprlock): preserve password-only startup authentication
●  test(home): evaluate expected assertion failures unchecked
●  fix(quattro): hide empty command widgets
├─╯
●  main
```

## Verification and landing

Focused lock, Quattro runtime, theme, health, template, and Waybar-retirement
checks MUST pass with the terminal repair worktree override. The full flake
check MUST then pass with the same override. After terminal lands, desktop MUST
repin terminal to merged `main`, rerun without overrides, receive a fresh
exact-head approval, and merge without squashing.

Hardware acceptance runs later from the merged `ks-config` consumer. It covers
Quattro behavior and the combined laptop power-transition cases. This plan
MUST NOT deploy a host or probe the operator's live Wayland session.
