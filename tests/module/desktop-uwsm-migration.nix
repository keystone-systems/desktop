{ pkgs }:
let
  migration = import ../../lib/uwsm-migration.nix { inherit pkgs; };
  homeManagerFiles = pkgs.runCommand "home-manager-files" { } ''
    mkdir -p "$out/.config/uwsm"
    printf 'generated UWSM environment\n' > "$out/.config/uwsm/env"
  '';
in
pkgs.runCommand "desktop-uwsm-migration" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
  migrate=${migration}/bin/keystone-uwsm-migrate

  new_home() {
    case_home="$TMPDIR/home-$1"
    mkdir -p "$case_home/.config/uwsm" "$case_home/.config/systemd/user"
  }

  expect_success() {
    HOME="$case_home" "$migrate"
  }

  expect_refusal() {
    if HOME="$case_home" "$migrate" >"$TMPDIR/refusal.log" 2>&1; then
      echo "FAIL: migration accepted $1" >&2
      exit 1
    fi
    grep -Fq 'Refusing UWSM ownership migration:' "$TMPDIR/refusal.log"
  }

  new_home absent
  expect_success

  new_home stow-valid
  mkdir -p "$case_home/repo/packages/hyprland-common/.config/uwsm"
  touch "$case_home/repo/packages/hyprland-common/.config/uwsm/env"
  ln -s "$case_home/repo/packages/hyprland-common/.config/uwsm/env" \
    "$case_home/.config/uwsm/env"
  expect_success
  test ! -e "$case_home/.config/uwsm/env"

  new_home stow-broken
  ln -s ../../repo/packages/hyprland-common/.config/uwsm/env \
    "$case_home/.config/uwsm/env"
  expect_success
  test ! -L "$case_home/.config/uwsm/env"

  new_home home-manager-owned
  ln -s ${homeManagerFiles}/.config/uwsm/env "$case_home/.config/uwsm/env"
  original_target="$(readlink -- "$case_home/.config/uwsm/env")"
  expect_success
  expect_success
  test -L "$case_home/.config/uwsm/env"
  test "$(readlink -- "$case_home/.config/uwsm/env")" = "$original_target"

  new_home home-manager-old-generation
  ln -s /nix/store/00000000000000000000000000000000-home-manager-files/.config/uwsm/env \
    "$case_home/.config/uwsm/env"
  expect_success
  test -L "$case_home/.config/uwsm/env"

  for kind in regular directory foreign-valid foreign-broken; do
    new_home "env-$kind"
    case "$kind" in
      regular) touch "$case_home/.config/uwsm/env" ;;
      directory) mkdir "$case_home/.config/uwsm/env" ;;
      foreign-valid)
        touch "$case_home/foreign"
        ln -s "$case_home/foreign" "$case_home/.config/uwsm/env"
        ;;
      foreign-broken) ln -s ../../unrelated/env "$case_home/.config/uwsm/env" ;;
    esac
    expect_refusal "generic env $kind"
    test -e "$case_home/.config/uwsm/env" || test -L "$case_home/.config/uwsm/env"
  done

  new_home legacy-known
  ln -s /nix/store/00000000000000000000000000000000-home-manager-files/.config/systemd/user/hyprland-session.target \
    "$case_home/.config/systemd/user/hyprland-session.target"
  expect_success
  test ! -L "$case_home/.config/systemd/user/hyprland-session.target"

  for kind in regular directory valid foreign-broken; do
    new_home "legacy-$kind"
    target="$case_home/.config/systemd/user/hyprland-session.target"
    case "$kind" in
      regular) touch "$target" ;;
      directory) mkdir "$target" ;;
      valid)
        touch "$case_home/valid-target"
        ln -s "$case_home/valid-target" "$target"
        ;;
      foreign-broken) ln -s /nix/store/unrelated-target "$target" ;;
    esac
    expect_refusal "legacy target $kind"
    test -e "$target" || test -L "$target"
  done

  # Refusing the legacy target MUST leave a recognized env handoff untouched.
  new_home atomic-refusal
  ln -s ../../repo/packages/hyprland-common/.config/uwsm/env \
    "$case_home/.config/uwsm/env"
  ln -s /nix/store/unrelated-target \
    "$case_home/.config/systemd/user/hyprland-session.target"
  expect_refusal "partial migration"
  test -L "$case_home/.config/uwsm/env"

  # Home Manager defines run as a dry-run-aware command wrapper. Sourcing the
  # migration into its activation shell MUST preserve both recognized targets
  # when that wrapper declines to execute mutations.
  new_home dry-run
  ln -s ../../repo/packages/hyprland-common/.config/uwsm/env \
    "$case_home/.config/uwsm/env"
  ln -s /nix/store/00000000000000000000000000000000-home-manager-files/.config/systemd/user/hyprland-session.target \
    "$case_home/.config/systemd/user/hyprland-session.target"
  HOME="$case_home" MIGRATION_SOURCE=${../../lib/keystone-uwsm-migrate.sh} \
    ${pkgs.bash}/bin/bash -c '
      run() { printf "dry-run:"; printf " %s" "$@"; printf "\n"; }
      source "$MIGRATION_SOURCE"
    ' > "$TMPDIR/dry-run.log"
  test -L "$case_home/.config/uwsm/env"
  test -L "$case_home/.config/systemd/user/hyprland-session.target"
  test "$(grep -c '^dry-run: rm -- ' "$TMPDIR/dry-run.log")" -eq 2

  touch "$out"
''
