# Native desktop CI

Main pushes, same-repository pull requests, and manual dispatch run
`bin/check-native` on the native Linux runner. The check parses tracked Nix and Bash
scripts and reuses the template privacy lint, timezone transition fixture, and
Hyprland power log fixture. The fixtures run without an active desktop.
Nix parsing uses the runner binary directly without fetching flake inputs.

NixOS and Home Manager module evaluation, generated unit and launcher checks,
the dependency closure, and the dotfiles VM remain in the flake suite. Run
`nix flake check` for that coverage.

Verified the shared template lint with its Nix build and ran ShellCheck on both
new shell scripts. The native job retains its same-repository PR guard.
