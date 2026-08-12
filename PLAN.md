# Hyprlock Recovery Program

Stage: **Program** — one production desktop fix crosses four repositories.

Outcome: a stale `hyprlock` PID MUST NOT block later locks. Startup and
pre-sleep failures MUST fail closed. An idle or interactive failure MUST report
the error without closing applications.

## Evidence

- A Hyprlock process survived suspend with no Hyprlock layer and
  `LockedHint=no`.
- Every idle and sleep hook uses `pidof hyprlock || hyprlock`. The stale PID
  therefore suppresses all later launches.
- `keystone-startup-lock` also treats an existing or stable PID as success.
  This contradicts its fail-closed contract.
- The System menu bypasses the shared lock behavior and launches bare
  `hyprlock`.
- The lid binding is the only lock request that still runs when the user has
  disabled Hypridle. It MUST remain and MUST complete the lock before suspend.

## Claude Opus Simplification Review

Claude Opus reviewed this plan and the current repository as a read-only,
skeptical maintainer. Its verdict was: **the root cause is correct, but the
first design was overcomplicated**.

Accepted review changes:

- Use one `keystone-lock` command and one optional `--fail-closed` flag.
- Do not inspect, serialize, terminate, or replace Hyprlock PIDs.
- Let the Wayland session-lock protocol arbitrate concurrent launches.
- Recheck real lock state after launch. A losing concurrent launcher can still
  succeed because another launcher established the lock.
- Keep retry behavior only in the startup wrapper.
- Do not change logind `InhibitDelayMaxSec`; pre-sleep verification MUST fit
  inside its existing delay.
- Make Keystone own lid suspend: logind ignores the event and the lid-close
  binding locks successfully before it requests suspend.
- Route the System menu through the same command.
- Resolve the logind session from `XDG_SESSION_ID`, with the user's display
  session as fallback.
- Add journal logging that can explain the next failure.
- Reduce the test matrix to four stub-driven behavioral cases plus static
  configuration guards.

The review's full output remains in the agent session transcript. It made no
file changes.

## Projected Git Graphs

Landing mode: preserve every planned commit. Do not squash a multi-commit
lane.

### `ks.systems/desktop`

```text
◇  next patch
│
○  fix(hypridle): route every lock path through keystone-lock
◉  fix(startup-lock): require an observable lock state  eae33a9
●  feat(lock): add a verified session-lock helper  7661638
●  feat(hyprland): seed xdph.conf with walker picker  1165030
```

Branch: `fix/hyprlock-recovery`.

### `ncrmro/dotfiles`

```text
◇  next patch
│
○  fix(hyprland): use keystone-lock for every lock path
●  feat(bin): add a stow package for plain scripts  e55bce9
```

Branch: `fix/hyprlock-recovery`.

### `ks.systems/os`

```text
◇  next patch
│
○  chore(flake): bump desktop for lock recovery
●  chore: bump desktop for walker share picker  f04afb5f
```

Branch: `chore/desktop-lock-recovery`.

### `ncrmro/ks-config`

```text
◇  next patch
│
○  chore(flake): bump keystone for lock recovery
●  feat(ocean): trust catalog-deploy OIDC subject  85d2283
```

Branch: `chore/desktop-lock-recovery`.

## Core Design

### `keystone-lock`

Add one desktop-owned command:

```text
keystone-lock [--fail-closed]
```

The command MUST:

1. Resolve the logind session from `XDG_SESSION_ID`. If it is absent, use the
   user's display session from `loginctl show-user`.
2. Treat only `LockedHint=yes` or a Hyprlock layer as success.
3. Return success immediately when the session is already locked.
4. Launch Hyprlock without checking for another Hyprlock PID.
5. Poll real lock state for at most three seconds.
6. Recheck lock state after the launched process exits or loses the
   session-lock race.
7. Log decisions under the `keystone-lock` journal tag.
8. On ordinary failure, send a critical notification and return nonzero.
9. With `--fail-closed`, attempt the same Hyprland, UWSM, and logind session
   termination sequence used by `keystone-startup-lock`, then return nonzero.

The command MUST NOT use `pidof`, `pgrep`, `pkill`, `flock`, or a PID-stability
heuristic. A stale, inert process can remain until logout; it is not a source
of lock truth.

Package one derivation through the desktop overlay and flake package output.
Install that same output where NixOS and Home Manager callers require it. Do
not create separate OS and Home Manager implementations.

### Startup

- Keep `keystone-startup-lock` as the first user-visible Hyprland `exec-once`.
- Keep its monitor-readiness gate and fail-closed termination sequence.
- Remove the existing-PID and stable-PID success paths.
- Call `keystone-lock` for each bounded startup attempt.
- Allow up to three three-second attempts after the compositor-readiness gate.
- Startup can take about 20 seconds in the worst case: 10 seconds for
  readiness, 9 seconds for lock attempts, and retry delays.
- Only an observable lock state can complete startup.

### Idle, lid, and interactive hooks

Update the reusable templates and active dotfiles together:

- `lock_cmd=keystone-lock`.
- The 300-second listener runs `keystone-lock`.
- `before_sleep_cmd=keystone-lock --fail-closed`.
- Set logind `HandleLidSwitch=ignore` so it cannot race the lock command.
- The lid-close binding runs
  `keystone-lock --fail-closed && systemctl suspend`.
- Keep the lid-open DPMS binding.
- The System menu's lock action runs `keystone-lock`.
- The System menu's suspend action runs
  `keystone-lock --fail-closed && systemctl suspend`.
- Keep the 300-second lock and 330-second DPMS timeouts.
- Do not change `keystone-dpms-wake` behavior in this incident.

Do not add a logind timeout override. Hypridle with `inhibit_sleep=3` holds its
delay inhibitor until the Wayland lock notification. The pre-sleep command has
one three-second attempt and then immediately starts fail-closed termination.
This leaves the remaining normal logind delay for teardown.

## Verification

Add one stub-driven shell check with four cases:

1. `LockedHint=yes`: return success and do not launch Hyprlock.
2. Hyprlock layer present with `LockedHint=no`: return success and do not
   launch Hyprlock.
3. Stale PID with no lock: ignore the PID, launch Hyprlock, observe a real lock,
   and return success without killing the stale process.
4. No lock appears: ordinary mode notifies and does not terminate the session;
   `--fail-closed` attempts session termination.

Static checks MUST prove:

- no `pidof hyprlock` remains in desktop templates;
- every template-invoked `keystone-lock` is installed;
- startup lock remains the first user-visible `exec-once`;
- startup has no PID-only or stable-PID success path;
- the lid lock and System menu lock use `keystone-lock`;
- active dotfiles match the template lock behavior.

Run:

```sh
cd ~/repos/ks.systems/desktop.worktrees/fix/hyprlock-recovery
nix develop --command nix flake check

cd ~/repos/ks.systems/os.worktrees/chore/desktop-lock-recovery
nix develop --command nix flake check

cd ~/repos/ncrmro/ks-config.worktrees/chore/desktop-lock-recovery
devenv shell -- ./bin/ks-dev --build ncrmro-laptop
```

The lockfile updates MUST target only `desktop` in `ks.systems/os` and
`keystone` in `ks-config`.

The startup change MUST receive isolated VM or test-host validation before the
laptop deploy. Tests MUST NOT attach Hyprlock or Hyprctl to the operator's live
session.

## Landing and Deployment

1. Land desktop.
2. Land the OS desktop-input update.
3. Land the `ks-config` Keystone-input update after the laptop build succeeds.
4. Stop before YubiKey approval. The user runs:

   ```sh
   cd ~/repos/ncrmro/ks-config
   ks-dev ncrmro-laptop
   ```

5. Only after deployment succeeds, land and pull the dotfiles change. Landing
   it earlier would make every lock hook call a missing binary and fail open.
6. Reload Hyprland and restart Hypridle.
7. Verify System menu lock, `loginctl lock-session`, idle lock, startup lock,
   and lid suspend/resume.
8. Check `journalctl --user -t keystone-lock -t keystone-startup-lock` for
   failed observations, launch races, and surviving stale processes.

## Recovery Notes

Removing PID-stability success strengthens startup security but increases the
risk of an autologin loop when no observable lock can form. Before deployment,
record and verify the TTY recovery path: stop the greetd/Hyprland session,
select the previous NixOS generation, and rebuild after diagnosis.
