# Checks for ks.systems/desktop.
#
# Called from flake.nix as:
#   import ./tests { inherit self nixpkgs home-manager; system = "x86_64-linux"; }
#
# Checks evaluate or render the public contract and may execute isolated,
# headless fixtures. No check connects to the developer's active compositor.
# The nixosSystem evals below intentionally consume nixosModules.default /
# homeModules.default exactly the way an external consumer would, so contract
# regressions fail here first.
{
  self,
  nixpkgs,
  home-manager,
  hyprland,
  omarchy,
  terminal,
  system,
}:
let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ self.overlays.default ];
  };
  lib = nixpkgs.lib;

  templates = ../templates;
  terminalTemplatePaths = map (entry: entry.path) terminal.lib.dotfiles.manifest;
  desktopTemplatePaths = map (file: lib.removePrefix "${toString templates}/" (toString file)) (
    lib.filesystem.listFilesRecursive templates
  );
  templateOverlap = lib.intersectLists terminalTemplatePaths desktopTemplatePaths;
  # Minimal headless consumer eval, one per desktop environment. Imports the
  # home-manager NixOS module because nixosModules.default sets
  # home-manager.sharedModules (standalone consumers carry home-manager
  # themselves; via ks.systems/os it comes from the os module set).
  mkEval =
    environment:
    nixpkgs.lib.nixosSystem {
      modules = [
        home-manager.nixosModules.home-manager
        self.nixosModules.default
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "25.05";
          boot.loader.systemd-boot.enable = true;
          fileSystems."/" = {
            device = "/dev/vda1";
            fsType = "ext4";
          };
          users.users.testuser.isNormalUser = true;
          keystone.desktop = {
            enable = true;
            user = "testuser";
            inherit environment;
          };
        }
      ];
    };

  evalHyprland = mkEval "hyprland";
  evalGnome = mkEval "gnome";
  evalNiri = mkEval "niri";

  # GCR must be the SSH agent in every environment. Forcing the GNOME eval
  # matters on its own: nixpkgs' GNOME desktop-manager defines this option
  # itself, so a same-priority definition here would be an eval error that only
  # the gnome branch reaches.
  gcrDisabledEnvironments = lib.attrNames (
    lib.filterAttrs (_: eval: !eval.config.services.gnome.gcr-ssh-agent.enable) {
      hyprland = evalHyprland;
      gnome = evalGnome;
      niri = evalNiri;
    }
  );

  # Every binary the templates invoke by bare name (hyprland.lua binds,
  # hypridle.conf hooks, and shell command widgets). These MUST be
  # OS-level packages — the stowed configs run outside any HM wrapper PATH.
  # Guards the extraction risk of silently losing a binary that was HM-only
  # before (e.g. hyprpicker).
  templateBinaries = [
    # The pinned flake names its package quickshell-wrapped while providing
    # the bare `quickshell` command used by the Quattro launcher.
    "quickshell-wrapped"
    "wofi"
    "mako"
    "hyprlock"
    "hypridle"
    "hyprpaper"
    "hyprsunset"
    "hyprpicker"
    "grim"
    "slurp"
    "satty"
    "brightnessctl"
    "playerctl"
    "wl-clip-persist"
    "clipse"
    "keystone-dpms-wake"
    "keystone-lock"
    "keystone-suspend"
  ];
  systemPackageNames = map lib.getName evalHyprland.config.environment.systemPackages;
  missingBinaries = lib.filter (name: !(lib.elem name systemPackageNames)) templateBinaries;
  # Commands the stowed hypridle.conf invokes by bare name, mapped to the
  # package that must supply them. Asserted against the RENDERED unit (below)
  # rather than the pre-merge option: the drop-in NixOS generates is what
  # overrides the Home Manager unit PATH, and the option merges whether or not
  # the service is enabled, so an option-level check passes vacuously.
  # hyprctl is why this maps commands to packages instead of listing names —
  # it ships inside the package named "hyprland".
  hypridleHookPackages = {
    inherit (evalHyprland.pkgs) brightnessctl;
    inherit (evalHyprland.pkgs.keystone-desktop) keystone-dpms-wake keystone-lock;
    hyprctl = evalHyprland.config.programs.hyprland.package;
  };
  hypridleUnitText = evalHyprland.config.systemd.user.units."hypridle.service".text;
  dpmsWakeText = evalHyprland.pkgs.keystone-desktop.keystone-dpms-wake.text;
  # Matching each package's real store path keeps this exact (no version
  # guessing) and keeps the comparison at eval time: only the plain command
  # names survive into the derivation, so the check never pulls the compositor
  # into its closure. The needle is context-stripped because lib.hasInfix
  # compiles it into a regex, and Nix rejects store-path context there.
  missingHypridleHookBinaries = lib.attrNames (
    lib.filterAttrs (
      _: pkg: !(lib.hasInfix (builtins.unsafeDiscardStringContext "${pkg}/bin") hypridleUnitText)
    ) hypridleHookPackages
  );

  # greetd and gdm must never both be configured (or both be missing) for a
  # selected environment — every DE branch is mkIf-gated on the enum.
  mkDisplayManagerXorCheck =
    name: eval:
    let
      greetd = eval.config.services.greetd.enable;
      gdm = eval.config.services.displayManager.gdm.enable;
    in
    pkgs.runCommand "${name}" { } ''
      if [ "${lib.boolToString greetd}" = "${lib.boolToString gdm}" ]; then
        echo "FAIL(${name}): expected exactly one of greetd/gdm; got greetd=${lib.boolToString greetd} gdm=${lib.boolToString gdm}" >&2
        exit 1
      fi
      echo "PASS(${name}): greetd=${lib.boolToString greetd} gdm=${lib.boolToString gdm}"
      touch "$out"
    '';

  hasStubWarning = eval: lib.any (w: lib.hasInfix "stub" w) eval.config.warnings;

  mkStubWarningGate =
    name: eval: check:
    if hasStubWarning eval then
      check
    else
      pkgs.runCommand name { } ''
        echo "FAIL(${name}): expected a 'stub' entry in config.warnings for this environment" >&2
        exit 1
      '';

  # Standalone home-manager eval with the public desktop overlay, one per
  # consumer scenario.
  mkHomeConfig =
    module:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.default
        {
          home.username = "testuser";
          home.homeDirectory = "/home/testuser";
          home.stateVersion = "25.05";
        }
        module
      ];
    };

  # homeManagerConfiguration always applies the assertions gate before
  # exposing config, while its `check` argument controls module type checking.
  # Reproduce Home Manager's raw module evaluation with check=false only for
  # the intentional assertion-failure fixture below.
  uncheckedHomeLib = import "${home-manager}/modules/lib/stdlib-extended.nix" lib;
  uncheckedHomeModules = import "${home-manager}/modules/modules.nix" {
    inherit pkgs;
    check = false;
    lib = uncheckedHomeLib;
  };
  mkUncheckedHomeConfig =
    module:
    uncheckedHomeLib.evalModules {
      class = "homeManager";
      modules = [
        {
          imports = [
            self.homeModules.default
            {
              home.username = "testuser";
              home.homeDirectory = "/home/testuser";
              home.stateVersion = "25.05";
              nixpkgs = {
                config = lib.mkDefault pkgs.config;
                inherit (pkgs) overlays;
              };
            }
            module
          ];
        }
      ]
      ++ uncheckedHomeModules;
      specialArgs.modulesPath = "${home-manager}/modules";
    };

  # Includes the terminal overlay, but not the ks.systems/os overlay. This
  # proves that the integration options (ksPackage/agenixPackage) are
  # null-tolerant. Forcing every home.packages name and user unit instantiates
  # the full surface without building anything.
  homeStandalone = mkHomeConfig {
    keystone.terminal.git.enable = false;
    keystone.desktop.enable = true;
  };
  homeSshAgentEnabled = homeStandalone.config.services.ssh-agent.enable;
  homeSshAuthSock = homeStandalone.config.keystone.terminal.ssh.authSock;
  # A desktop must refuse terminal SSH auto-load outright: it would start a
  # second agent against a second passphrase store. Matched on the message so
  # an unrelated assertion failure cannot make this pass vacuously.
  homeSshAutoLoadConflict = mkUncheckedHomeConfig {
    keystone.desktop.enable = true;
    keystone.terminal.sshAutoLoad.enable = true;
  };
  sshAutoLoadConflictRejected = lib.any (
    a: !a.assertion && lib.hasInfix "sshAutoLoad" a.message
  ) homeSshAutoLoadConflict.config.assertions;
  homeStandalonePackageNames = map lib.getName homeStandalone.config.home.packages;
  themeCatalogNames = map (
    catalog: catalog.name
  ) homeStandalone.config.keystone.terminal.theme.catalogs;
  themeAdapters = homeStandalone.config.keystone.terminal.theme.adapters;
  terminalAdapterSources = [
    "zellij.kdl"
    "helix.toml"
    "btop.theme"
    "lazygit.yml"
    "."
  ];
  graphicalAdapterSources = lib.subtractLists terminalAdapterSources (
    map (adapter: adapter.source) themeAdapters
  );
  graphicalContractPaths = lib.unique (
    homeStandalone.config.keystone.terminal.theme.requiredPaths ++ graphicalAdapterSources
  );
  themeRenderHook = builtins.head homeStandalone.config.keystone.terminal.theme.renderHooks;
  themePostSwitchHook =
    lib.findFirst (hook: lib.getName hook == "keystone-theme-hook")
      (throw "desktop theme hook is missing")
      homeStandalone.config.keystone.terminal.theme.postSwitchHooks;
  writePolkitThemePackage = pkgs.keystone-desktop.write-polkit-theme;
  makoAdapters = lib.filter (adapter: adapter.source == "mako.ini") themeAdapters;
  homeStandaloneUnits = lib.attrNames homeStandalone.config.systemd.user.services;
  startupLockUnit = homeStandalone.config.systemd.user.services.keystone-startup-lock;
  omarchyShellUnit = homeStandalone.config.systemd.user.services.omarchy-shell;
  makoUnit = homeStandalone.config.systemd.user.services.mako;
  omarchyRuntime = builtins.dirOf (builtins.dirOf (builtins.head omarchyShellUnit.Service.ExecStart));
  omarchyRuntimePackage = lib.findFirst (
    package: lib.getName package == "keystone-omarchy-quattro-runtime"
  ) (throw "Quattro runtime package is missing") evalHyprland.config.environment.systemPackages;
  omarchyPrivateRuntimePackage = omarchyRuntimePackage.runtimeTree;
  keystoneMenuPackage = lib.findFirst (
    package: lib.getName package == "keystone-menu"
  ) (throw "keystone-menu package is missing") homeStandalone.config.home.packages;
  templateRuntimeCommands = [
    "omarchy-toggle-bar"
    "omarchy-launch-floating-terminal-with-presentation"
    "omarchy-update"
  ];
  quattroRuntimeInstalled = lib.elem "keystone-omarchy-quattro-runtime" systemPackageNames;
  omarchyShellPath = lib.findFirst (
    value: lib.hasPrefix "PATH=" value
  ) "" omarchyShellUnit.Service.Environment;
  makoServicePath = lib.findFirst (
    value: lib.hasPrefix "PATH=" value
  ) "" makoUnit.Service.Environment;
  persistentGraphicalServices = [
    "hypridle"
    "hyprpaper"
    "hyprsunset"
    "hyprpolkitagent"
    "mako"
    "swayosd"
    "omarchy-shell"
    "wl-clip-persist"
    "clipse-listen"
    "walker"
    "elephant"
  ];
  missingGraphicalServices = lib.filter (
    name: !(builtins.hasAttr name homeStandalone.config.systemd.user.services)
  ) persistentGraphicalServices;
  misorderedGraphicalServices = lib.filter (
    name:
    if builtins.hasAttr name homeStandalone.config.systemd.user.services then
      let
        unit = homeStandalone.config.systemd.user.services.${name};
      in
      !(lib.elem "graphical-session.target" unit.Unit.After)
      || !(lib.elem "graphical-session.target" unit.Unit.PartOf)
      || !(lib.elem "graphical-session.target" unit.Unit.Requisite)
      || !(lib.elem "graphical-session.target" unit.Install.WantedBy)
    else
      false
  ) persistentGraphicalServices;
  missingGraphicalServiceExecStarts = lib.filter (
    name:
    if builtins.hasAttr name homeStandalone.config.systemd.user.services then
      let
        execStart = homeStandalone.config.systemd.user.services.${name}.Service.ExecStart or null;
      in
      if builtins.isString execStart then
        execStart == ""
      else if builtins.isList execStart then
        execStart == [ ] || lib.any (entry: entry == "") execStart
      else
        true
    else
      false
  ) persistentGraphicalServices;

  # The EXACT set of keystone-owned commands the HM tree installs when both
  # integration packages are null. Post-extraction every linked command is a
  # single writeShellScriptBin named after the command, so lib.getName on a
  # home.packages entry IS the command name.
  #
  # This list is a contract, not a snapshot: adding a command means adding a
  # line here, and a command that starts requiring `ks` must MOVE to
  # ksOnlyCommands below (SPEC.md 116-123 — ks-dependent surfaces are hidden
  # per ENTRY, the command itself stays installed).
  expectedStandaloneCommands = [
    "keystone-accounts-menu"
    # Ungated deliberately: its only external tool is agentctl, so the ks gate
    # was hiding a surface that works perfectly well without `ks`.
    "keystone-agent-menu"
    "keystone-audio-menu"
    "keystone-audio-switch"
    "keystone-battery-monitor"
    "keystone-context"
    "keystone-desktop-config"
    "keystone-detach"
    "keystone-disk-monitor"
    "keystone-ensure-paths"
    "keystone-fingerprint-menu"
    "keystone-idle-toggle"
    "keystone-launch-walker"
    "keystone-lock"
    # Mod+Escape entrypoint backend. MUST be installed with ksPackage null —
    # keystone-menu.sh execs it from every case arm, so gating the package
    # kills the whole Mod+Escape surface instead of hiding one entry.
    "keystone-main-menu"
    "keystone-menu"
    "keystone-menu-keybindings"
    "keystone-monitor-menu"
    "keystone-nightlight-toggle"
    "keystone-notes-inbox"
    "keystone-printer-menu"
    "keystone-screenrecord"
    "keystone-screenshot"
    "keystone-setup-menu"
    "keystone-share-picker"
    "keystone-startup-lock"
    "keystone-sync-agent-assets"
    "keystone-theme-switch"
    "keystone-wifi-menu"
    "keystone-zellij-new-tab-prompt"
    "keystone-zide"
  ];

  # Commands whose runtimeInputs contain cfg.integration.{ks,agenix}Package.
  # They cannot be built at all when the package is null, so they MUST be
  # absent here — their menu entries are hidden by env var instead.
  ksOnlyCommands = [
    "keystone-hardware-menu"
    "keystone-package-menu"
    "keystone-photos-menu"
    "keystone-secrets-menu"
  ];

  actualStandaloneCommands = lib.sort lib.lessThan (
    lib.unique (
      lib.filter (
        name: lib.hasPrefix "keystone-" name && name != "keystone-omarchy-quattro-runtime"
      ) homeStandalonePackageNames
    )
  );
  missingStandaloneCommands = lib.subtractLists actualStandaloneCommands expectedStandaloneCommands;
  unexpectedStandaloneCommands = lib.subtractLists expectedStandaloneCommands actualStandaloneCommands;
  leakedKsCommands = lib.filter (n: lib.elem n actualStandaloneCommands) ksOnlyCommands;

  # Full-surface HM eval for the stow-collision check: every option that can
  # contribute files is switched on (integration packages are stand-ins just
  # to un-gate the ks/agenix-dependent scripts and menus).
  homeFull = mkHomeConfig {
    keystone.terminal.git.enable = false;
    keystone.desktop = {
      enable = true;
      environment = "hyprland";
      browser = "chromium";
      uhk.enable = true;
      photos.enable = true;
      agents.enable = true;
      audio.defaults = {
        sink = "test-sink";
        source = "test-source";
      };
      printer.default = "test-printer";
      integration = {
        configCheckout = "/srv/keystone-config";
        ksPackage = pkgs.hello;
        agenixPackage = pkgs.hello;
      };
    };
  };
  configuredDefaultServices = {
    audio = homeFull.config.systemd.user.services.keystone-audio-defaults;
    printer = homeFull.config.systemd.user.services.keystone-printer-default;
  };
  configuredOmarchyShellEnvironment =
    homeFull.config.systemd.user.services.omarchy-shell.Service.Environment;
  renderServiceValue = value: if builtins.isList value then lib.concatStringsSep " " value else value;
  configuredDefaultServiceErrors = lib.filter (error: error != null) (
    lib.mapAttrsToList (
      name: unit:
      if
        lib.elem "graphical-session.target" unit.Unit.After
        && lib.elem "graphical-session.target" unit.Unit.PartOf
        && lib.elem "graphical-session.target" unit.Unit.Requisite
        && lib.elem "graphical-session.target" unit.Install.WantedBy
        && unit.Service.Type == "oneshot"
        && unit.Service.RemainAfterExit
        && lib.hasSuffix " apply-config-defaults" (renderServiceValue unit.Service.ExecStart)
      then
        null
      else
        name
    ) configuredDefaultServices
  );

  # Directories owned by the user's stowed dotfiles. Nix (home.file /
  # xdg.configFile) must never write under them — a managed entry there
  # recreates the stow-collision class the extraction eliminated.
  stowedConfigDirs = [
    "hypr"
    "wofi"
    "walker"
  ];
  underStowedDir =
    prefix: name:
    lib.any (d: name == "${prefix}${d}" || lib.hasPrefix "${prefix}${d}/" name) stowedConfigDirs;
  stowCollisions =
    lib.filter (underStowedDir ".config/") (lib.attrNames homeFull.config.home.file)
    ++ map (n: "xdg.configFile:${n}") (
      lib.filter (underStowedDir "") (lib.attrNames homeFull.config.xdg.configFile)
    );

  # PAM text of the greetd service as rendered for the hyprland eval — forced
  # here so the eval-hyprland check catches both eval failures (e.g. the
  # rules.session.login attr missing on older nixpkgs) and rendering
  # regressions of the session-class rule.
  greetdPamText = evalHyprland.config.security.pam.services.greetd.text;
  loginPamText = evalHyprland.config.security.pam.services.login.text;
  hyprlockPamText = evalHyprland.config.security.pam.services.hyprlock.text;
  startupPamText = evalHyprland.config.security.pam.services.hyprlock-startup.text;
  passwdPamText = evalHyprland.config.security.pam.services.passwd.text;
  logindSettings = evalHyprland.config.services.logind.settings.Login;
  upowerEnabled = evalHyprland.config.services.upower.enable;
in
{
  # No personal literal may survive the template scrub: absolute home paths,
  # the upstream author's identity, hardware serials, or personal modules.
  template-lint =
    pkgs.runCommand "template-lint"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
      }
      ''
        if grep -rnE "/home/|ncrmro|desc:.*Dell|voice-memo" ${templates}; then
          echo "FAIL: personal literals found in templates/ (see matches above)" >&2
          exit 1
        fi
        echo "PASS: templates are free of personal literals"
        touch "$out"
      '';

  theme-graphical-contract =
    pkgs.runCommand "theme-graphical-contract"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.mako
          writePolkitThemePackage
          themeRenderHook
        ];
      }
      ''
        themes=${templates}/themes/.config/themes
        expected="${lib.concatStringsSep " " terminal.lib.themeNames}"
        catalogs="${lib.concatStringsSep " " themeCatalogNames}"

        test "$catalogs" = "terminal omarchy desktop" || {
          echo "FAIL: effective theme catalog order is '$catalogs'" >&2
          exit 1
        }

        semantic_templates=${../modules/home/theming/templates}
        while IFS= read -r adapter; do
          catalog_adapters="$(find "$themes" -type f -name "$adapter" -print)"
          if [ -n "$catalog_adapters" ]; then
            echo "FAIL: desktop catalog still owns generated adapter $adapter:" >&2
            echo "$catalog_adapters" >&2
            exit 1
          fi
        done < <(find "$semantic_templates" -type f -name '*.tpl' -printf '%f\n' \
          | sed 's/\.tpl$//' | sort)
        catalog_clip_legacy="$(find "$themes" -type f -name clipse.json -print)"
        if [ -n "$catalog_clip_legacy" ]; then
          echo "FAIL: desktop catalog still carries the retired Clipse JSON adapter:" >&2
          echo "$catalog_clip_legacy" >&2
          exit 1
        fi

        for theme in $expected; do
          generation="$TMPDIR/rendered/$theme"
          mkdir -p "$generation"
          for source in "${terminal.lib.templatesPath}/themes/.config/themes/$theme" "${omarchy}/themes/$theme" "$themes/$theme"; do
            if [ -d "$source" ]; then
              cp -r "$source"/. "$generation"/
              chmod -R u+w "$generation"
            fi
          done
          keystone-theme-render "$theme" "$generation"
          if grep -q '^include=' "$generation/mako.ini"; then
            echo "FAIL: $theme Mako adapter still depends on an external include" >&2
            exit 1
          fi
          grep -Fq "on-button-left=exec sh -c 'makoctl dismiss --all; keystone-menu wifi'" \
            "$generation/mako.ini" || {
            echo "FAIL: $theme Mako adapter omits the product-owned Wi-Fi action" >&2
            exit 1
          }
          grep -Fq "on-button-left=exec sh -c 'makoctl dismiss --all; omarchy-launch-floating-terminal-with-presentation omarchy-update'" \
            "$generation/mako.ini" || {
            echo "FAIL: $theme Mako adapter omits the product-owned update action" >&2
            exit 1
          }
          grep -Eq '^background-color=#[0-9a-fA-F]{6}$' "$generation/mako.ini" || {
            echo "FAIL: $theme Mako adapter does not contain a rendered semantic background" >&2
            exit 1
          }
          if grep -q '{{' "$generation/mako.ini"; then
            echo "FAIL: $theme Mako adapter contains unresolved template values" >&2
            exit 1
          fi
          for variable in color inner_color outer_color font_color check_color; do
            grep -Eq '^\$'"$variable"'[[:space:]]*=[[:space:]]*rgba?\([^)]+\)$' \
              "$generation/hyprlock.conf" || {
              echo "FAIL: $theme does not render Hyprlock variable \$$variable" >&2
              exit 1
            }
          done
          if grep -Ev '^\$(color|inner_color|outer_color|font_color|check_color)[[:space:]]*=[[:space:]]*rgba?\([^)]+\)$|^[[:space:]]*$' \
            "$generation/hyprlock.conf"; then
            echo "FAIL: $theme renders non-palette Hyprlock configuration" >&2
            exit 1
          fi
          if [ "$(grep -Ec '^\$' "$generation/hyprlock.conf")" -ne 5 ] \
            || grep -q '{{' "$generation/hyprlock.conf"; then
            echo "FAIL: $theme Hyprlock palette is incomplete or unresolved" >&2
            exit 1
          fi
          if grep -Eq '^\$[^=]+=[[:space:]]*rgb\(#' "$generation/hyprlock.conf"; then
            echo "FAIL: $theme leaves comment-prefixed hex in a Hyprlock variable" >&2
            exit 1
          fi
          for path in ${lib.concatStringsSep " " graphicalContractPaths}; do
            test -e "$generation/$path" || {
              echo "FAIL: $theme does not contain $path" >&2
              exit 1
            }
          done
          for path in zellij.kdl helix.toml btop.theme lazygit.yml; do
            test ! -e "$themes/$theme/$path" || {
              echo "FAIL: desktop still owns terminal adapter $theme/$path" >&2
              exit 1
            }
          done
        done

        # Mako 1.11 parses configuration before attempting D-Bus or Wayland.
        # Run it with deliberately nonexistent isolated endpoints: reaching the
        # connection failure without "Failed to parse config" proves the
        # complete generated adapter is loadable without touching the session.
        mako_home="$TMPDIR/mako-home"
        mako_runtime="$TMPDIR/mako-runtime"
        mkdir -p "$mako_home" "$mako_runtime"
        probe_mako_config() {
          local config_file="$1"
          local error_log="$2"
          local status
          set +e
          HOME="$mako_home" \
            XDG_RUNTIME_DIR="$mako_runtime" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$TMPDIR/missing-bus" \
            WAYLAND_DISPLAY=keystone-missing \
            timeout --kill-after=1s 2s ${pkgs.mako}/bin/mako \
              --config "$config_file" > /dev/null 2> "$error_log"
          status=$?
          set -e
          test "$status" -ne 0 || {
            echo "FAIL: isolated Mako unexpectedly stayed running" >&2
            exit 1
          }
        }

        invalid_mako="$TMPDIR/invalid-mako.ini"
        printf '%s\n' 'keystone-invalid-option=true' > "$invalid_mako"
        probe_mako_config "$invalid_mako" "$TMPDIR/invalid-mako.log"
        grep -Fq 'Failed to parse config' "$TMPDIR/invalid-mako.log" || {
          echo "FAIL: pinned Mako probe cannot detect an invalid config" >&2
          exit 1
        }

        rendered_mako="$TMPDIR/rendered/$theme/mako.ini"
        probe_mako_config "$rendered_mako" "$TMPDIR/rendered-mako.log"
        if grep -Eq 'Failed to parse config|Unable to open .* for reading' \
          "$TMPDIR/rendered-mako.log"; then
          echo "FAIL: pinned Mako cannot load the self-contained generated adapter" >&2
          cat "$TMPDIR/rendered-mako.log" >&2
          exit 1
        fi

        # Pin the current include semantics as an upstream compatibility fact,
        # even though the production generation no longer depends on them.
        cp ${templates}/themes/.local/share/omarchy/default/mako/core.ini \
          "$mako_home/core.ini"
        printf '%s\n' 'include=~/core.ini' > "$TMPDIR/included-mako.ini"
        probe_mako_config "$TMPDIR/included-mako.ini" "$TMPDIR/included-mako.log"
        if grep -Eq 'Failed to parse config|Unable to open .* for reading' \
          "$TMPDIR/included-mako.log"; then
          echo "FAIL: pinned Mako no longer expands and loads include=~/..." >&2
          cat "$TMPDIR/included-mako.log" >&2
          exit 1
        fi

        semantic="$TMPDIR/semantic-theme"
        mkdir -p "$semantic"
        cat > "$semantic/colors.toml" <<'EOF'
        background = "#010203"
        lighter_background = "#111213"
        foreground = "#f1f2f3"
        muted = "#818283"
        accent = "#a1a2a3"
        red = "#d1d2d3"
        mode = "light"
        EOF
        printf '%s\n' '$color = rgb(000000)' > "$semantic/hyprlock.conf"
        keystone-write-polkit-theme "$semantic" "$semantic/polkit.json"
        jq -e '
          .background == "#010203" and
          .surface == "#111213" and
          .text == "#f1f2f3" and
          .mutedText == "#818283" and
          .accent == "#a1a2a3" and
          .error == "#d1d2d3" and
          .light == true
        ' "$semantic/polkit.json" >/dev/null

        actual="$(find "$themes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
        expected_sorted="$(printf '%s\n' $expected | sort | tr '\n' ' ' | sed 's/ $//')"
        test "$actual" = "$expected_sorted" || {
          echo "FAIL: theme set is '$actual'; expected '$expected_sorted'" >&2
          exit 1
        }

        touch "$out"
      '';

  theme-adapter-transaction =
    pkgs.runCommand "theme-adapter-transaction"
      {
        nativeBuildInputs = [ pkgs.keystone-terminal.theme-selector ];
        makoTarget = if makoAdapters == [ ] then "" else (builtins.head makoAdapters).target;
      }
      ''
        test "$makoTarget" = /home/testuser/.config/mako/config

        root="$TMPDIR/theme-adapter"
        mkdir -p "$root/catalog/first" "$root/catalog/second" "$root/config/mako" "$root/hook/bin"
        printf first > "$root/catalog/first/mako.ini"
        printf second > "$root/catalog/second/mako.ini"
        printf '%s\n' '#!${pkgs.runtimeShell}' '[ "$1" != second ]' > "$root/hook/bin/keystone-theme-hook"
        chmod +x "$root/hook/bin/keystone-theme-hook"

        export KEYSTONE_STATE_HOME="$root/state"
        export KEYSTONE_THEME_CATALOGS="$(printf 'desktop\t%s' "$root/catalog")"
        export KEYSTONE_THEME_ADAPTERS="$(printf 'mako.ini\t%s' "$root/config/mako/config")"
        export KEYSTONE_THEME_REQUIRED_PATHS=""
        keystone-theme-selector select first
        before="$(readlink -f "$root/config/mako/config")"
        if KEYSTONE_THEME_HOOKS="$root/hook" keystone-theme-selector select second; then
          echo "FAIL: accepted the failing graphical hook" >&2
          exit 1
        fi
        test "$(readlink -f "$root/config/mako/config")" = "$before"
        test "$(cat "$root/config/mako/config")" = first
        touch "$out"
      '';

  template-non-overlap =
    pkgs.runCommand "template-non-overlap"
      {
        overlap = lib.concatStringsSep " " templateOverlap;
      }
      ''
        if [ -n "$overlap" ]; then
          echo "FAIL: terminal and desktop templates overlap: $overlap" >&2
          exit 1
        fi
        touch "$out"
      '';

  retired-bar-surfaces =
    pkgs.runCommand "retired-bar-surfaces"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        legacy='[Ww][Aa][Yy][Bb][Aa][Rr]'
        if rg -n "$legacy" \
          ${../modules} ${templates} ${../lib} ${../pkgs} ${../tests} ${../flake.nix}; then
          echo "FAIL: retired shell-bar integration remains in an executable or test surface" >&2
          exit 1
        fi
        touch "$out"
      '';

  # The startup lock is a required transaction gate after UWSM has published
  # WAYLAND_DISPLAY and before any graphical-session service can start.
  template-startup-lock =
    pkgs.runCommand "template-startup-lock"
      {
        after = lib.concatStringsSep " " startupLockUnit.Unit.After;
        before = lib.concatStringsSep " " startupLockUnit.Unit.Before;
        requires = lib.concatStringsSep " " startupLockUnit.Unit.Requires;
        requiredBy = lib.concatStringsSep " " startupLockUnit.Install.RequiredBy;
        onFailure = lib.concatStringsSep " " startupLockUnit.Unit.OnFailure;
        onFailureJobMode = startupLockUnit.Unit.OnFailureJobMode;
        execStart = startupLockUnit.Service.ExecStart;
      }
      ''
        test "$after" = wayland-session-waitenv.service
        test "$requires" = wayland-session-waitenv.service
        test "$before" = graphical-session.target
        test "$requiredBy" = graphical-session.target
        test "$onFailure" = wayland-session-shutdown.target
        test "$onFailureJobMode" = replace-irreversibly
        case "$execStart" in
          */bin/keystone-startup-lock) ;;
          *) echo "FAIL: unexpected startup lock command: $execStart" >&2; exit 1 ;;
        esac
        echo "PASS: startup lock gates graphical-session.target after UWSM readiness"
        touch "$out"
      '';

  desktop-session-lifecycle =
    pkgs.runCommand "desktop-session-lifecycle"
      {
        missing = lib.concatStringsSep " " missingGraphicalServices;
        missingExecStarts = lib.concatStringsSep " " missingGraphicalServiceExecStarts;
        misordered = lib.concatStringsSep " " misorderedGraphicalServices;
        hyprsunsetCondition = homeStandalone.config.systemd.user.services.hyprsunset.Service.ExecCondition;
        configuredDefaultServiceErrors = lib.concatStringsSep " " configuredDefaultServiceErrors;
        standaloneHasAudioDefaults = lib.boolToString (
          builtins.hasAttr "keystone-audio-defaults" homeStandalone.config.systemd.user.services
        );
        standaloneHasPrinterDefault = lib.boolToString (
          builtins.hasAttr "keystone-printer-default" homeStandalone.config.systemd.user.services
        );
        audioDefaultsExecStart = renderServiceValue configuredDefaultServices.audio.Service.ExecStart;
        printerDefaultExecStart = renderServiceValue configuredDefaultServices.printer.Service.ExecStart;
        audioDefaultsEnvironment = lib.concatStringsSep " " configuredDefaultServices.audio.Service.Environment;
        printerDefaultEnvironment = lib.concatStringsSep " " configuredDefaultServices.printer.Service.Environment;
      }
      ''
        if [ -n "$missing" ]; then
          echo "FAIL: persistent graphical services missing: $missing" >&2
          exit 1
        fi
        if [ -n "$misordered" ]; then
          echo "FAIL: graphical services do not follow the lock gate: $misordered" >&2
          exit 1
        fi
        if [ -n "$missingExecStarts" ]; then
          echo "FAIL: persistent graphical services have no effective ExecStart: $missingExecStarts" >&2
          exit 1
        fi
        if [ -n "$configuredDefaultServiceErrors" ]; then
          echo "FAIL: configured default services violate the graphical-session contract: $configuredDefaultServiceErrors" >&2
          exit 1
        fi
        test "$standaloneHasAudioDefaults" = false
        test "$standaloneHasPrinterDefault" = false
        case "$audioDefaultsExecStart" in
          */bin/keystone-audio-menu\ apply-config-defaults) ;;
          *) echo "FAIL: unexpected audio defaults command: $audioDefaultsExecStart" >&2; exit 1 ;;
        esac
        case "$printerDefaultExecStart" in
          */bin/keystone-printer-menu\ apply-config-defaults) ;;
          *) echo "FAIL: unexpected printer default command: $printerDefaultExecStart" >&2; exit 1 ;;
        esac
        test "$audioDefaultsEnvironment" = "KEYSTONE_AUDIO_DEFAULT_SINK=test-sink KEYSTONE_AUDIO_DEFAULT_SOURCE=test-source"
        test "$printerDefaultEnvironment" = "KEYSTONE_PRINTER_DEFAULT=test-printer"
        case "$hyprsunsetCondition" in
          *virtio*) ;;
          *) echo "FAIL: hyprsunset lost its virtio exclusion" >&2; exit 1 ;;
        esac
        touch "$out"
      '';

  quattro-runtime-contract =
    pkgs.runCommand "quattro-runtime-contract"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.git
          pkgs.jq
          pkgs.gnugrep
        ];
        shellExecStartCount = toString (lib.length omarchyShellUnit.Service.ExecStart);
        inherit omarchyShellPath;
        enabledWidgetCommands = lib.concatStringsSep "\n" [
          "bash"
          "find"
          "inotifywait"
          "keystone-menu"
          "omarchy-agent"
          "omarchy-agent-usage-update"
          "omarchy-brightness-display"
          "omarchy-display-text-size"
          "omarchy-dns"
          "omarchy-hyprland-monitor-scaling"
          "omarchy-keystone-health"
          "omarchy-keystone-recording"
          "omarchy-keystone-voice"
          "omarchy-launch-floating-terminal-with-presentation"
          "omarchy-monitor-state"
          "omarchy-network-band"
          "omarchy-network-status"
          "omarchy-update"
          "omarchy-update-available"
          "wl-copy"
          "xkbcli"
        ];
        expectedRuntimeCommands = lib.concatStringsSep "\n" omarchyRuntimePackage.runtimeCommandNames;
        expectedWidgetRuntimeCommands = lib.concatStringsSep "\n" omarchyRuntimePackage.widgetRuntimeCommandNames;
        passAsFile = [
          "enabledWidgetCommands"
          "expectedRuntimeCommands"
          "expectedWidgetRuntimeCommands"
        ];
        themeHook = themePostSwitchHook;
        homeProfileBin = "${homeStandalone.config.home.profileDirectory}/bin";
        keystoneMenuBin = "${keystoneMenuPackage}/bin";
        standaloneShellEnvironment = lib.concatStringsSep "\n" omarchyShellUnit.Service.Environment;
        configuredShellEnvironment = lib.concatStringsSep "\n" configuredOmarchyShellEnvironment;
      }
      ''
        runtime=${omarchyRuntime}
        public_runtime=${omarchyRuntimePackage}
        shell_config=${templates}/omarchy/.config/omarchy/shell.json
        test "$runtime" = "${omarchyPrivateRuntimePackage}"
        test -x "$runtime/bin/omarchy-launch-shell"
        test -x "$runtime/bin/omarchy-shell"
        test -x "$runtime/bin/omarchy-theme-set-templates"
        test -x "$runtime/bin/omarchy-toggle"
        test -x "$runtime/bin/omarchy-toggle-bar"
        test "$shellExecStartCount" = 1
        case "$omarchyShellPath" in
          PATH="$runtime/bin":"$homeProfileBin":/run/current-system/sw/bin:*) ;;
          *) echo "FAIL: omarchy-shell PATH is not rooted in runtime, Home Manager, and the system profile: $omarchyShellPath" >&2; exit 1 ;;
        esac
        case "$omarchyShellPath" in
          *${pkgs.xdg-utils}/bin*) ;;
          *) echo "FAIL: omarchy-shell PATH omits xdg-utils" >&2; exit 1 ;;
        esac
        test ! -e "$runtime/bin/pacman"
        test ! -e "$runtime/bin/yay"
        find "$runtime/bin" -mindepth 1 -maxdepth 1 \
          \( -type f -o -type l \) -printf '%f\n' | sort \
          > "$TMPDIR/actual-runtime-commands"
        sort "$expectedRuntimeCommandsPath" > "$TMPDIR/expected-runtime-commands"
        diff -u "$TMPDIR/expected-runtime-commands" "$TMPDIR/actual-runtime-commands"

        # The enabled layout is the source of the custom command-widget
        # contract. Derive both exec and click commands instead of maintaining
        # a second copy that could silently drift from shell.json.
        jq -r '
          [.bar.layout[][]
            | select(.type == "command")
            | .exec, .onClick
            | select(. != null)
            | split(" ")[0]]
          | unique[]
        ' "$shell_config" > "$TMPDIR/configured-command-widget-commands"
        printf '%s\n' \
          keystone-menu \
          omarchy-keystone-health \
          omarchy-keystone-recording \
          omarchy-keystone-voice \
          | sort -u > "$TMPDIR/expected-command-widget-commands"
        diff -u "$TMPDIR/expected-command-widget-commands" \
          "$TMPDIR/configured-command-widget-commands"

        jq -e '
          [.bar.layout[][] | .id]
          | contains(["omarchy.agents", "omarchy.monitor", "omarchy.network"])
        ' "$shell_config" >/dev/null

        # Pin every literal command edge in the three enabled upstream widget
        # implementations plus the registry watcher. If upstream changes a
        # command, the focused contract must be updated deliberately.
        widget_sources="$runtime/shell/plugins/agents $runtime/shell/plugins/panels/monitor $runtime/shell/plugins/panels/network $runtime/shell/services/PluginRegistry.qml $runtime/shell/plugins/bar/widgets/KeyboardLayout.qml"
        for command in \
          omarchy-agent omarchy-agent-usage-update \
          omarchy-brightness-display omarchy-display-text-size \
          omarchy-hyprland-monitor-scaling omarchy-monitor-state \
          omarchy-dns omarchy-launch-floating-terminal-with-presentation \
          omarchy-network-band omarchy-network-status wl-copy \
          inotifywait xkbcli; do
          grep -R -Fq "$command" $widget_sources || {
            echo "FAIL: enabled widget contract no longer references $command" >&2
            exit 1
          }
        done

        service_path="''${omarchyShellPath#PATH=}"
        service_path="$service_path:$keystoneMenuBin"
        while IFS= read -r command; do
          PATH="$service_path" command -v "$command" >/dev/null || {
            echo "FAIL: enabled widget command $command is absent from the Quattro service PATH" >&2
            exit 1
          }
        done < "$enabledWidgetCommandsPath"

        # Transitive upstream helpers share the private runtime with QML, but
        # MUST NOT leak into the system or Home Manager profile package.
        while IFS= read -r command; do
          test -x "$runtime/bin/$command" || {
            echo "FAIL: widget helper $command is absent from the private runtime" >&2
            exit 1
          }
          test ! -e "$public_runtime/bin/$command" || {
            echo "FAIL: private widget helper $command leaked into the public profile" >&2
            exit 1
          }
        done < "$expectedWidgetRuntimeCommandsPath"
        grep -Fq 'omarchy-cmd-present' "$runtime/bin/omarchy-network-status"
        if grep -R -nE '(^|[^[:alnum:]_])(pacman|yay)([^[:alnum:]_]|$)|/(usr|etc)/' "$runtime/bin" \
          | grep -vF 'Path("/etc/localtime")'; then
          echo "FAIL: curated runtime retains an Arch or privileged-filesystem assumption" >&2
          exit 1
        fi
        jq -e '.disabledPlugins | length == 11' "$shell_config" >/dev/null
        jq -e '.bar.layout.left == [{"id":"omarchy.menu"},{"id":"omarchy.workspaces"}]' "$shell_config" >/dev/null
        jq -e '.bar.layout.center[] | select(.id == "keystone.voice" and .type == "command")' "$shell_config" >/dev/null
        jq -e '.bar.layout.center[] | select(.id == "keystone.recording" and .type == "command")' "$shell_config" >/dev/null
        jq -e '.bar.layout.right[] | select(.id == "keystone.health" and .type == "command")' "$shell_config" >/dev/null
        jq -e '[.bar.layout.center[] | select(.id | startswith("keystone.")) | select(.onClick == "keystone-menu capture")] | length == 2' "$shell_config" >/dev/null
        jq -e '
          .["trigger.capture"].action == "keystone-menu capture"
          and .["trigger.toggle"].action == "keystone-menu toggle"
          and .["style.theme"].action == "keystone-menu theme"
          and .["style.background"].action == "keystone-menu background"
          and .["setup.monitors"].action == "keystone-menu monitors"
          and .["setup.network"].action == "keystone-menu wifi"
          and .["setup.audio"].action == "keystone-menu audio"
        ' ${../modules/home/quattro-menu.jsonc} >/dev/null
        grep -Fq 'data.text === undefined || data.text === null' "$runtime/shell/plugins/bar/Bar.qml"
        if grep -q '^KEYSTONE_CONFIG_CHECKOUT=' <<<"$standaloneShellEnvironment"; then
          echo "FAIL: standalone shell received a config checkout" >&2
          exit 1
        fi
        grep -Fqx 'KEYSTONE_CONFIG_CHECKOUT=/srv/keystone-config' \
          <<<"$configuredShellEnvironment"
        if grep -R -n 'repos/ncrmro/ks-config' ${../lib} ${../modules} ${../templates}; then
          echo "FAIL: public desktop surfaces retain a personal config checkout" >&2
          exit 1
        fi

        mkdir -p "$TMPDIR/fake-bin"

        # The pinned upstream uses `omarchy-shell shell reloadConfig`, and its
        # CLI accepts `-q` before the target. Exercise the packaged copy and
        # assert the exact argv it forwards to Quickshell IPC.
        grep -Fq 'omarchy-shell shell reloadConfig' ${omarchy}/bin/omarchy-shell-config
        grep -Fq 'omarchy-shell -q shell reloadConfig 2>/dev/null || true' \
          "$themeHook/bin/keystone-theme-hook"
        mkdir -p "$TMPDIR/ipc-bin"
        cat > "$TMPDIR/ipc-bin/timeout" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s\n' "$@" > "$SHELL_IPC_LOG"
        printf '%s\n' ok
        EOF
        chmod +x "$TMPDIR/ipc-bin/timeout"
        SHELL_IPC_LOG="$TMPDIR/shell-ipc.log" \
          OMARCHY_PATH="$runtime" \
          WAYLAND_DISPLAY=keystone-test \
          XDG_RUNTIME_DIR="$TMPDIR/runtime" \
          PATH="$TMPDIR/ipc-bin" \
          "$runtime/bin/omarchy-shell" -q shell reloadConfig
        printf '%s\n' \
          '--kill-after=1s' \
          '2s' \
          'qs' \
          'ipc' \
          '-n' \
          '-p' \
          "$runtime/shell" \
          'call' \
          '--' \
          'shell' \
          'reloadConfig' \
          > "$TMPDIR/expected-shell-ipc.log"
        diff -u "$TMPDIR/expected-shell-ipc.log" "$TMPDIR/shell-ipc.log"

        recording_pid=
        voice_pid=
        cleanup_widgets() {
          for pid in "$recording_pid" "$voice_pid"; do
            if [ -n "$pid" ]; then
              kill "$pid" 2>/dev/null || true
              wait "$pid" 2>/dev/null || true
            fi
          done
        }
        trap cleanup_widgets EXIT

        cat > "$TMPDIR/fake-bin/keystone-main-menu" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s %s\n' "''${0##*/}" "$*"
        EOF
        chmod +x "$TMPDIR/fake-bin/keystone-main-menu"
        for backend in keystone-monitor-menu keystone-wifi-menu keystone-audio-menu; do
          ln -s keystone-main-menu "$TMPDIR/fake-bin/$backend"
        done
        invoke_menu() {
          HOME="$TMPDIR/home" PATH="$TMPDIR/fake-bin:$PATH" \
            ${pkgs.bash}/bin/bash ${../modules/home/scripts/keystone-menu.sh} "$1"
        }
        test "$(invoke_menu theme)" = "keystone-main-menu open-menu theme"
        test "$(invoke_menu background)" = "keystone-main-menu open-menu background"
        test "$(invoke_menu monitors)" = "keystone-monitor-menu open-menu"
        test "$(invoke_menu wifi)" = "keystone-wifi-menu open-menu"
        test "$(invoke_menu network)" = "keystone-wifi-menu open-menu"
        test "$(invoke_menu audio)" = "keystone-audio-menu open-menu"

        bluetooth_log="$TMPDIR/bluetooth.log"
        cat > "$TMPDIR/fake-bin/bluetoothctl" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s\n' "$*" >> "$TEST_BLUETOOTH_LOG"
        if [ "''${TEST_BLUETOOTH_FAIL_FIRST_ON:-}" = 1 ] \
          && [ "$*" = "power on" ] \
          && [ ! -e "$TEST_BLUETOOTH_FAILURE_MARKER" ]; then
          touch "$TEST_BLUETOOTH_FAILURE_MARKER"
          exit 1
        fi
        EOF
        chmod +x "$TMPDIR/fake-bin/bluetoothctl"
        TEST_BLUETOOTH_LOG="$bluetooth_log" \
          KEYSTONE_BLUETOOTHCTL_BIN="$TMPDIR/fake-bin/bluetoothctl" \
          "$runtime/bin/omarchy-restart-bluetooth"
        printf '%s\n' 'power off' 'power on' > "$TMPDIR/expected-bluetooth.log"
        diff -u "$TMPDIR/expected-bluetooth.log" "$bluetooth_log"
        : > "$bluetooth_log"
        if TEST_BLUETOOTH_LOG="$bluetooth_log" \
          TEST_BLUETOOTH_FAIL_FIRST_ON=1 \
          TEST_BLUETOOTH_FAILURE_MARKER="$TMPDIR/bluetooth-first-on-failed" \
          KEYSTONE_BLUETOOTHCTL_BIN="$TMPDIR/fake-bin/bluetoothctl" \
          "$runtime/bin/omarchy-restart-bluetooth"; then
          echo "FAIL: Bluetooth restart hid a failed power-on attempt" >&2
          exit 1
        fi
        printf '%s\n' 'power off' 'power on' 'power on' \
          > "$TMPDIR/expected-bluetooth.log"
        diff -u "$TMPDIR/expected-bluetooth.log" "$bluetooth_log"

        ghostty_log="$TMPDIR/ghostty.log"
        cat > "$TMPDIR/fake-bin/ghostty" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s\n' "$@" > "$TEST_GHOSTTY_LOG"
        EOF
        chmod +x "$TMPDIR/fake-bin/ghostty"
        TEST_GHOSTTY_LOG="$ghostty_log" \
          KEYSTONE_GHOSTTY_BIN="$TMPDIR/fake-bin/ghostty" \
          "$runtime/bin/omarchy-launch-floating-terminal-with-presentation" \
          printf visible
        printf '%s\n' \
          '--class=org.omarchy.terminal' \
          '--title=Omarchy' \
          '-e' \
          'bash' \
          '-lc' \
          'printf visible ' > "$TMPDIR/expected-ghostty.log"
        diff -u "$TMPDIR/expected-ghostty.log" "$ghostty_log"
        TEST_GHOSTTY_LOG="$ghostty_log" \
          KEYSTONE_GHOSTTY_BIN="$TMPDIR/fake-bin/ghostty" \
          "$runtime/bin/omarchy-launch-floating-terminal-with-presentation" \
          "omarchy-dns Custom"
        test "$(tail -n 1 "$ghostty_log")" = "omarchy-dns Custom"
        if KEYSTONE_GHOSTTY_BIN="$TMPDIR/fake-bin/ghostty" \
          "$runtime/bin/omarchy-launch-floating-terminal-with-presentation"; then
          echo "FAIL: floating terminal accepted an empty command" >&2
          exit 1
        fi

        grep -R -l 'omarchy-launch-floating-terminal-with-presentation' "$runtime/shell" \
          | sed "s#$runtime/##" | sort > "$TMPDIR/floating-terminal-callers"
        printf '%s\n' \
          'shell/plugins/bar/widgets/SystemUpdate.qml' \
          'shell/plugins/panels/network/Panel.qml' \
          > "$TMPDIR/expected-floating-terminal-callers"
        diff -u "$TMPDIR/expected-floating-terminal-callers" \
          "$TMPDIR/floating-terminal-callers"

        cat > "$TMPDIR/fake-bin/keystone-disk-monitor" <<'EOF'
        #!${pkgs.runtimeShell}
        test "$1" = json
        printf '%s\n' '{"text":"","class":"healthy","tooltip":"ok"}'
        EOF
        chmod +x "$TMPDIR/fake-bin/keystone-disk-monitor"
        PATH="$TMPDIR/fake-bin:$PATH" "$runtime/bin/omarchy-keystone-health" \
          | jq -e '.class == "healthy"' >/dev/null

        idle_recording="$($runtime/bin/omarchy-keystone-recording)"
        jq -e '.text == "" and .tooltip == "Screen recording idle"' \
          <<<"$idle_recording" >/dev/null
        ${pkgs.coreutils}/bin/mkfifo "$TMPDIR/recording-blocker"
        ${pkgs.bash}/bin/bash -c \
          'read -r _ <"$1"' /nix/store/test/bin/gpu-screen-recorder \
          "$TMPDIR/recording-blocker" &
        recording_pid=$!
        for _ in $(${pkgs.coreutils}/bin/seq 1 20); do
          active_recording="$($runtime/bin/omarchy-keystone-recording)"
          jq -e '.class == "recording"' <<<"$active_recording" >/dev/null && break
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        jq -e '.text != "" and .class == "recording"' \
          <<<"$active_recording" >/dev/null
        kill "$recording_pid"
        wait "$recording_pid" 2>/dev/null || true
        recording_pid=

        idle_voice="$($runtime/bin/omarchy-keystone-voice)"
        jq -e '.tooltip == "Voice memo idle"' <<<"$idle_voice" >/dev/null
        cp ${pkgs.bash}/bin/bash "$TMPDIR/fake-bin/pw-record"
        ${pkgs.coreutils}/bin/mkfifo "$TMPDIR/voice-blocker"
        "$TMPDIR/fake-bin/pw-record" -c \
          'read -r _ <"$1"' pw-record "$TMPDIR/voice-blocker" &
        voice_pid=$!
        for _ in $(${pkgs.coreutils}/bin/seq 1 20); do
          active_voice="$($runtime/bin/omarchy-keystone-voice)"
          jq -e '.class == "recording"' <<<"$active_voice" >/dev/null && break
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        jq -e '.tooltip == "Voice memo recording" and .class == "recording"' \
          <<<"$active_voice" >/dev/null
        kill "$voice_pid"
        wait "$voice_pid" 2>/dev/null || true
        voice_pid=

        update_output="$TMPDIR/update-output"
        if env -u KEYSTONE_CONFIG_CHECKOUT \
          "$runtime/bin/omarchy-update-available" >"$update_output"; then
          echo "FAIL: update indicator activated without a configured checkout" >&2
          exit 1
        fi
        test ! -s "$update_output"

        bare="$TMPDIR/remote.git"
        checkout="$TMPDIR/ks-config"
        git init --bare "$bare"
        git init -b main "$checkout"
        git -C "$checkout" config user.name test
        git -C "$checkout" config user.email test@example.invalid
        touch "$checkout/first"
        git -C "$checkout" add first
        git -C "$checkout" commit -m first
        git -C "$checkout" remote add origin "$bare"
        git -C "$checkout" push -u origin main
        other="$TMPDIR/other"
        git clone -b main "$bare" "$other"
        git -C "$other" config user.name test
        git -C "$other" config user.email test@example.invalid
        touch "$other/second"
        git -C "$other" add second
        git -C "$other" commit -m second
        git -C "$other" push
        KEYSTONE_CONFIG_CHECKOUT="$checkout" "$runtime/bin/omarchy-update-available"
        touch "$out"
      '';

  quattro-readonly-command-properties =
    pkgs.runCommand "quattro-readonly-command-properties"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.python3
        ];
      }
      ''
        runtime=${omarchyRuntime}
        cp -r "$runtime/shell" "$TMPDIR/shell"
        chmod -R u+w "$TMPDIR/shell"

        # Loading the full Bar requires Quickshell's PanelWindow backend. Build
        # a compositor-free harness from the packaged source instead: copy the
        # exact ModuleSlot.injectProps function and exact CustomCommandModule
        # component, then instantiate them through the production Loader path.
        # This remains an executable component regression, not a source grep.
        python3 - "$TMPDIR/shell/plugins/bar/Bar.qml" "$TMPDIR/shell/shell.qml" <<'PY'
        from pathlib import Path
        import sys

        source = Path(sys.argv[1]).read_text()
        def unique_start(text, marker, scope_name):
            count = text.count(marker)
            if count != 1:
                raise RuntimeError(f"expected one {scope_name}, found {count}")
            return text.index(marker)

        module_start = unique_start(source, "  component ModuleSlot: Item {", "ModuleSlot component")
        custom_start = unique_start(
            source,
            "  component CustomCommandModule: WidgetButton {",
            "CustomCommandModule component",
        )
        module_scope = source[module_start:custom_start]
        inject_marker = "    function injectProps() {"
        inject_start = module_start + unique_start(
            module_scope, inject_marker, "ModuleSlot.injectProps function"
        )
        inject_end = source.index("\n\n    Component {", inject_start)
        inject = source[inject_start:inject_end]
        declarations = []
        for declaration in (
            "readonly property string moduleName:",
            "readonly property var moduleSettings:",
            "readonly property string customType:",
            "readonly property bool commandCustom:",
        ):
            matches = [line for line in module_scope.splitlines() if declaration in line]
            if len(matches) != 1:
                raise RuntimeError(
                    f"expected one ModuleSlot {declaration} declaration, found {len(matches)}"
                )
            declarations.append(matches[0])

        classifier_marker = "  function customModuleType(entry) {"
        classifier_start = unique_start(source, classifier_marker, "customModuleType classifier")
        classifier_end = source.index("\n\n  function customModuleSource", classifier_start)
        classifier = source[classifier_start:classifier_end]
        custom_end = source.rfind("\n}")
        custom = source[custom_start:custom_end]
        for declaration in (
            "readonly property string moduleName:",
            "readonly property var settings:",
        ):
            count = custom.count(declaration)
            if count != 1:
                raise RuntimeError(
                    f"expected one CustomCommandModule {declaration} declaration, found {count}"
                )

        fixture = r"""import QtQuick
        import Quickshell
        import Quickshell.Io
        import qs.Commons
        import qs.Ui
        import "plugins/bar/BarModel.js" as BarModel

        ShellRoot {
          Item {
            id: root

            property string fontFamily: Style.font.family
            property color barForeground: Color.foreground
            property color urgent: Color.urgent
            property bool vertical: false
            property int barSize: Style.bar.sizeHorizontal
            property bool foregroundAnimationEnabled: false

            function entryId(entry) { return String(entry.id || "") }
            function entrySettings(entry) {
              var settings = {}
              for (var key in entry) {
                if (key !== "id" && key !== "type") settings[key] = entry[key]
              }
              return settings
            }
            function run(command) {}
            function runProcess(process) { process.running = true }
            function registerClickTarget(target) {}
            function unregisterClickTarget(target) {}
            function showTooltip(target, text) {}
            function hideTooltip(target) {}

        """ + classifier + r"""

            component ModuleSlot: Item {
              id: slot

              required property var entry
              readonly property var activeItem: componentLoader.item

        """ + "\n".join(declarations) + r"""

              Loader {
                id: componentLoader
                sourceComponent: slot.commandCustom ? customCommandModuleComponent : writableModuleComponent
                onLoaded: {
                  slot.injectProps()
                  Qt.callLater(slot.injectProps)
                }
              }

        """ + inject + r"""

              Component {
                id: customCommandModuleComponent
                CustomCommandModule { entry: slot.entry }
              }

              Component {
                id: writableModuleComponent
                QtObject {
                  property var bar: null
                  property string moduleName: ""
                  property var settings: null
                }
              }
            }

        """ + custom + r"""

            ModuleSlot {
              id: commandProbe
              entry: ({
                id: "keystone.readonly-probe",
                type: "command",
                exec: "",
                text: "probe"
              })
            }

            ModuleSlot {
              id: writableProbe
              entry: ({
                id: "keystone.writable-probe",
                type: "registered",
                text: "assigned"
              })
            }

            Timer {
              interval: 250
              running: true
              onTriggered: {
                if (!commandProbe.commandCustom || writableProbe.commandCustom) {
                  console.error("KEYSTONE_PROBE_FAILED: production commandCustom discriminator changed")
                } else if (!commandProbe.activeItem || !writableProbe.activeItem) {
                  console.error("KEYSTONE_PROBE_FAILED: command component was not instantiated")
                } else {
                  var moduleNameReadonly = false
                  var settingsReadonly = false
                  try {
                    commandProbe.activeItem.moduleName = "mutation-must-fail"
                  } catch (error) {
                    moduleNameReadonly = String(error).indexOf("read-only property") !== -1
                  }
                  try {
                    commandProbe.activeItem.settings = ({ text: "mutation-must-fail" })
                  } catch (error) {
                    settingsReadonly = String(error).indexOf("read-only property") !== -1
                  }

                  if (!moduleNameReadonly || !settingsReadonly) {
                    console.error("KEYSTONE_PROBE_FAILED: command properties are not readonly")
                  } else if (writableProbe.activeItem.moduleName !== "keystone.writable-probe") {
                    console.error("KEYSTONE_PROBE_FAILED: writable moduleName was not injected")
                  } else if (!writableProbe.activeItem.settings || writableProbe.activeItem.settings.text !== "assigned") {
                    console.error("KEYSTONE_PROBE_FAILED: writable settings were not injected")
                  } else if (writableProbe.activeItem.bar !== root) {
                    console.error("KEYSTONE_PROBE_FAILED: writable bar was not injected")
                  } else {
                    console.log("KEYSTONE_PROBE_OK")
                  }
                }
                Qt.quit()
              }
            }
          }
        }
        """
        Path(sys.argv[2]).write_text(fixture)
        PY

        mkdir -p "$TMPDIR/home" "$TMPDIR/runtime"
        set +e
        HOME="$TMPDIR/home" \
          XDG_RUNTIME_DIR="$TMPDIR/runtime" \
          OMARCHY_PATH="$runtime" \
          QT_QPA_PLATFORM=offscreen \
          QS_DISABLE_FILE_WATCHER=1 \
          ${pkgs.coreutils}/bin/timeout 10s \
          ${omarchyPrivateRuntimePackage.quickshell}/bin/quickshell -n -p "$TMPDIR/shell" \
          >"$TMPDIR/quickshell.log" 2>&1
        status=$?
        set -e
        cat "$TMPDIR/quickshell.log"
        if [ "$status" -ne 0 ]; then
          echo "FAIL: headless commandCustom fixture exited with $status" >&2
          exit "$status"
        fi
        if grep -F 'Cannot assign to read-only property' "$TMPDIR/quickshell.log"; then
          echo "FAIL: commandCustom construction wrote a readonly property" >&2
          exit 1
        fi
        if grep -F 'KEYSTONE_PROBE_FAILED:' "$TMPDIR/quickshell.log"; then
          echo "FAIL: packaged commandCustom fixture did not preserve readonly bindings" >&2
          exit 1
        fi
        grep -Fq 'KEYSTONE_PROBE_OK' "$TMPDIR/quickshell.log" || {
          echo "FAIL: packaged commandCustom fixture did not instantiate" >&2
          exit 1
        }
        touch "$out"
      '';

  template-binaries =
    pkgs.runCommand "template-binaries"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
        missing = lib.concatStringsSep " " missingBinaries;
        runtime = omarchyRuntimePackage;
        runtimeCommands = lib.concatStringsSep " " templateRuntimeCommands;
        runtimeInstalled = lib.boolToString quattroRuntimeInstalled;
        coreIni = "${templates}/themes/.local/share/omarchy/default/mako/core.ini";
        homeProfile = homeStandalone.config.home.path;
        profileBin = "${homeStandalone.config.home.profileDirectory}/bin";
        inherit makoServicePath;
      }
      ''
        if [ -n "$missing" ]; then
          echo "FAIL: template-invoked binaries missing from environment.systemPackages: $missing" >&2
          exit 1
        fi
        if [ "$runtimeInstalled" != true ]; then
          echo "FAIL: the Quattro runtime is not installed at OS level" >&2
          exit 1
        fi
        for command in $runtimeCommands; do
          test -x "$runtime/bin/$command" || {
            echo "FAIL: template command $command is missing from the Quattro runtime" >&2
            exit 1
          }
        done
        test -x ${evalHyprland.pkgs.mako}/bin/makoctl || {
          echo "FAIL: the notification template action requires makoctl" >&2
          exit 1
        }
        test -x "$homeProfile/bin/keystone-menu" || {
          echo "FAIL: the notification template action requires the public Keystone menu command" >&2
          exit 1
        }
        mako_path="''${makoServicePath#PATH=}"
        IFS=: read -r shell_bin mako_bin service_profile_bin extra_path <<< "$mako_path"
        test -x "$shell_bin/sh"
        test -x "$mako_bin/makoctl"
        test "$service_profile_bin" = "$profileBin"
        test -z "$extra_path"
        if grep -Eq 'omarchy-(notification-dismiss|launch-wifi)' "$coreIni"; then
          echo "FAIL: notification actions still depend on missing legacy commands" >&2
          exit 1
        fi

        wifi_action="$(grep -A1 -F '[summary~="Setup Wi-Fi"]' "$coreIni" | tail -n1 | cut -d "'" -f2)"
        update_action="$(grep -A1 -F '[summary~="Update System"]' "$coreIni" | tail -n1 | cut -d "'" -f2)"
        test -n "$wifi_action"
        test -n "$update_action"
        mkdir -p "$TMPDIR/action-bin"
        cat > "$TMPDIR/action-bin/action-command" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s %s\n' "''${0##*/}" "$*" >> "$ACTION_LOG"
        EOF
        chmod +x "$TMPDIR/action-bin/action-command"
        for command in makoctl keystone-menu \
          omarchy-launch-floating-terminal-with-presentation omarchy-update; do
          ln -s action-command "$TMPDIR/action-bin/$command"
        done
        export ACTION_LOG="$TMPDIR/actions.log"
        PATH="$TMPDIR/action-bin" ${pkgs.runtimeShell} -c "$wifi_action"
        PATH="$TMPDIR/action-bin" ${pkgs.runtimeShell} -c "$update_action"
        printf '%s\n' \
          'makoctl dismiss --all' \
          'keystone-menu wifi' \
          'makoctl dismiss --all' \
          'omarchy-launch-floating-terminal-with-presentation omarchy-update' \
          > "$TMPDIR/expected-actions.log"
        diff -u "$TMPDIR/expected-actions.log" "$ACTION_LOG"
        echo "PASS: all template-invoked binaries are OS-level packages"
        touch "$out"
      '';

  logind-lid-owner =
    pkgs.runCommand "logind-lid-owner"
      {
        inherit (logindSettings)
          HandleLidSwitch
          HandleLidSwitchExternalPower
          HandleLidSwitchDocked
          ;
      }
      ''
        # expect: assert an eval-time value matches.
        expect() { [ "$2" = "$3" ] || { echo "FAIL: $1" >&2; exit 1; }; }

        expect "Hyprland owns lid handling on battery" "$HandleLidSwitch" ignore
        expect "Hyprland owns lid handling on AC" "$HandleLidSwitchExternalPower" ignore
        expect "Hyprland owns lid handling while docked" "$HandleLidSwitchDocked" ignore
        touch "$out"
      '';

  upower-daemon-contract =
    pkgs.runCommand "upower-daemon-contract"
      {
        enabled = lib.boolToString upowerEnabled;
      }
      ''
        if [ "$enabled" != "true" ]; then
          echo "FAIL: the battery monitor client requires the UPower D-Bus daemon" >&2
          exit 1
        fi
        touch "$out"
      '';

  hypridle-hook-path =
    pkgs.runCommand "hypridle-hook-path"
      {
        hypridleEnabled = lib.boolToString evalHyprland.config.services.hypridle.enable;
        missing = lib.concatStringsSep " " missingHypridleHookBinaries;
      }
      ''
        if [ "$hypridleEnabled" != "true" ]; then
          echo "FAIL: services.hypridle is disabled, so no NixOS drop-in corrects the hypridle unit PATH" >&2
          exit 1
        fi
        if [ -n "$missing" ]; then
          echo "FAIL: rendered hypridle unit PATH is missing hook commands: $missing" >&2
          exit 1
        fi
        touch "$out"
      '';

  dpms-dispatch-contract =
    pkgs.runCommand "dpms-dispatch-contract"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
        inherit dpmsWakeText;
        passAsFile = [ "dpmsWakeText" ];
      }
      ''
        if ! grep -Fq 'hyprctl dispatch "hl.dsp.dpms({ action = \"$1\" })"' "$dpmsWakeTextPath"; then
          echo "FAIL: keystone-dpms-wake does not use Hyprland's typed DPMS dispatcher" >&2
          exit 1
        fi
        if grep -Eq '^[[:space:]]*hyprctl dispatch[[:space:]]+dpms([[:space:]]|$)' "$dpmsWakeTextPath"; then
          echo "FAIL: keystone-dpms-wake uses the legacy bare DPMS dispatcher" >&2
          exit 1
        fi
        touch "$out"
      '';

  # eval-hyprland: display-manager xor plus the greetd PAM contract.
  # Forcing security.pam.services.greetd.text makes this check fail loudly on
  # any nixpkgs where the session rule breaks (the login-include rework moved
  # under our feet once already); the ordering assertion pins the invariant
  # that OUR pam_systemd (class=user type=wayland) registers the logind
  # session before login's include gets a chance to.
  eval-hyprland =
    pkgs.runCommand "eval-hyprland"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
        greetd = lib.boolToString evalHyprland.config.services.greetd.enable;
        gdm = lib.boolToString evalHyprland.config.services.displayManager.gdm.enable;
        pamText = greetdPamText;
        passAsFile = [ "pamText" ];
      }
      ''
        if [ "$greetd" = "$gdm" ]; then
          echo "FAIL(eval-hyprland): expected exactly one of greetd/gdm; got greetd=$greetd gdm=$gdm" >&2
          exit 1
        fi

        echo "rendered /etc/pam.d/greetd:"
        cat "$pamTextPath"

        # The wayland-class pam_systemd session rule must render.
        sysline="$(grep -nE '^session .*pam_systemd\.so' "$pamTextPath" \
          | grep 'class=user' | grep 'type=wayland' | head -n1 | cut -d: -f1)"
        if [ -z "$sysline" ]; then
          echo "FAIL(eval-hyprland): no 'session ... pam_systemd.so ... class=user type=wayland' line in greetd PAM text" >&2
          exit 1
        fi

        # When the login include exists (post-rework nixpkgs), our pam_systemd
        # must precede it so it wins session registration.
        incline="$(grep -nE '^session[[:space:]]+include[[:space:]]+login' "$pamTextPath" \
          | head -n1 | cut -d: -f1)"
        if [ -n "$incline" ] && [ "$incline" -le "$sysline" ]; then
          echo "FAIL(eval-hyprland): 'session include login' (line $incline) renders before pam_systemd class=user (line $sysline)" >&2
          exit 1
        fi

        echo "PASS(eval-hyprland): greetd=$greetd gdm=$gdm; pam_systemd line $sysline; login include line ''${incline:-<absent>}"
        touch "$out"
      '';

  desktop-gnome-keyring =
    pkgs.runCommand "desktop-gnome-keyring"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
        keyringEnabled = lib.boolToString evalHyprland.config.services.gnome.gnome-keyring.enable;
        gcrDisabled = lib.concatStringsSep " " gcrDisabledEnvironments;
        openSshAgentEnabled = lib.boolToString homeSshAgentEnabled;
        sshAuthSock = homeSshAuthSock;
        sshAutoLoadRejected = lib.boolToString sshAutoLoadConflictRejected;
        nixosCompatSocketPresent = lib.boolToString (
          builtins.hasAttr "gcr-ssh-agent-compat.socket" evalHyprland.config.systemd.user.units
        );
        nixosCompatServicePresent = lib.boolToString (
          builtins.hasAttr "gcr-ssh-agent-compat.service" evalHyprland.config.systemd.user.units
        );
        homeCompatSocketPresent = lib.boolToString (
          builtins.hasAttr "gcr-ssh-agent-compat" homeStandalone.config.systemd.user.sockets
        );
        homeCompatServicePresent = lib.boolToString (
          builtins.hasAttr "gcr-ssh-agent-compat" homeStandalone.config.systemd.user.services
        );
        gcrSocket = "${evalHyprland.config.services.gnome.gcr-ssh-agent.package}/share/systemd/user/gcr-ssh-agent.socket";
        uwsmEnv = "${templates}/hyprland/.config/uwsm/env";
        normalLockExecStart =
          homeStandalone.config.systemd.user.services.keystone-hyprlock.Service.ExecStart;
        startupLockExecStart =
          homeStandalone.config.systemd.user.services.keystone-hyprlock-startup.Service.ExecStart;
        expectedNormalLockExecStart = evalHyprland.pkgs.keystone-desktop.keystone-lock.normalCommand;
        expectedStartupLockExecStart = evalHyprland.pkgs.keystone-desktop.keystone-lock.startupCommand;
        normalLockRestart = homeStandalone.config.systemd.user.services.keystone-hyprlock.Service.Restart;
        startupLockRestart =
          homeStandalone.config.systemd.user.services.keystone-hyprlock-startup.Service.Restart;
        normalLockRestartSec = toString homeStandalone.config.systemd.user.services.keystone-hyprlock.Service.RestartSec;
        startupLockRestartSec = toString homeStandalone.config.systemd.user.services.keystone-hyprlock-startup.Service.RestartSec;
        normalLockPartOf = lib.concatStringsSep " " homeStandalone.config.systemd.user.services.keystone-hyprlock.Unit.PartOf;
        startupLockPartOf = lib.concatStringsSep " " homeStandalone.config.systemd.user.services.keystone-hyprlock-startup.Unit.PartOf;
        normalLockConflicts = lib.concatStringsSep " " homeStandalone.config.systemd.user.services.keystone-hyprlock.Unit.Conflicts;
        startupLockConflicts = lib.concatStringsSep " " homeStandalone.config.systemd.user.services.keystone-hyprlock-startup.Unit.Conflicts;
        greetdPam = greetdPamText;
        loginPam = loginPamText;
        hyprlockPam = hyprlockPamText;
        startupPam = startupPamText;
        passwdPam = passwdPamText;
        startupConfig = evalHyprland.pkgs.keystone-desktop.keystone-lock.startupConfig;
        passAsFile = [
          "greetdPam"
          "loginPam"
          "hyprlockPam"
          "startupPam"
          "passwdPam"
        ];
      }
      ''
        # require/refute: assert a pattern is present in / absent from a file.
        require() { grep -Eq "$2" "$3" || { echo "FAIL: $1" >&2; exit 1; }; }
        refute() { grep -Eq "$2" "$3" && { echo "FAIL: $1" >&2; exit 1; }; :; }
        # expect: assert an eval-time value matches.
        expect() { [ "$2" = "$3" ] || { echo "FAIL: $1" >&2; exit 1; }; }

        expect "GNOME Keyring is not enabled for the desktop" "$keyringEnabled" true
        if [ -n "$gcrDisabled" ]; then
          echo "FAIL: GCR is not the SSH agent on these desktop environments: $gcrDisabled" >&2
          exit 1
        fi
        expect "the Home Manager OpenSSH agent is enabled" "$openSshAgentEnabled" false
        expect "desktop services do not use the canonical GCR socket" "$sshAuthSock" '%t/gcr/ssh'
        expect "desktop configuration accepts terminal SSH auto-load" "$sshAutoLoadRejected" true
        expect "the NixOS legacy compatibility socket still exists" "$nixosCompatSocketPresent" false
        expect "the NixOS legacy compatibility service still exists" "$nixosCompatServicePresent" false
        expect "the Home Manager legacy compatibility socket still exists" "$homeCompatSocketPresent" false
        expect "the Home Manager legacy compatibility service still exists" "$homeCompatServicePresent" false

        if grep -R -nE '%t/ssh[-]agent' ${../modules} ${../templates}; then
          echo "FAIL: desktop modules or templates still reference the legacy SSH-agent socket" >&2
          exit 1
        fi

        require "the GCR vendor socket lacks its canonical listener" \
          '^ListenStream=%t/gcr/ssh$' "$gcrSocket"
        require "the GCR vendor socket does not export its canonical path" \
          'SSH_AUTH_SOCK=%t/gcr/ssh' "$gcrSocket"
        require "the UWSM template does not export the canonical GCR socket" \
          '^export SSH_AUTH_SOCK="\$XDG_RUNTIME_DIR/gcr/ssh"$' "$uwsmEnv"

        expect "normal Hyprlock service does not use the packaged command" \
          "$normalLockExecStart" "$expectedNormalLockExecStart"
        expect "startup Hyprlock service does not use the Nix-owned startup config" \
          "$startupLockExecStart" "$expectedStartupLockExecStart"
        expect "normal Hyprlock is not restarted after crashes" "$normalLockRestart" on-failure
        expect "startup Hyprlock is not restarted after crashes" "$startupLockRestart" on-failure
        expect "normal Hyprlock restart delay changed" "$normalLockRestartSec" 1
        expect "startup Hyprlock restart delay changed" "$startupLockRestartSec" 1
        expect "normal Hyprlock is not bound to the Wayland session" \
          "$normalLockPartOf" wayland-session@Hyprland.target
        expect "startup Hyprlock is not bound to the Wayland session" \
          "$startupLockPartOf" wayland-session@Hyprland.target
        for conflict in keystone-hyprlock-startup.service wayland-session-shutdown.target; do
          case " $normalLockConflicts " in
            *" $conflict "*) ;;
            *) echo "FAIL: normal Hyprlock lacks $conflict" >&2; exit 1 ;;
          esac
        done
        for conflict in keystone-hyprlock.service wayland-session-shutdown.target; do
          case " $startupLockConflicts " in
            *" $conflict "*) ;;
            *) echo "FAIL: startup Hyprlock lacks $conflict" >&2; exit 1 ;;
          esac
        done

        require "greetd does not enter the login PAM session" \
          '^session[[:space:]]+include[[:space:]]+login' "$greetdPamPath"
        require "the login PAM session does not start GNOME Keyring" \
          '^session[[:space:]]+optional.*pam_gnome_keyring\.so.*auto_start' "$loginPamPath"
        require "normal Hyprlock lacks GNOME Keyring authentication" \
          '^auth[[:space:]]+optional.*pam_gnome_keyring\.so' "$hyprlockPamPath"
        require "normal Hyprlock lacks fingerprint authentication" \
          '^auth[[:space:]]+sufficient.*pam_fprintd\.so' "$hyprlockPamPath"
        require "startup Hyprlock lacks GNOME Keyring authentication" \
          '^auth[[:space:]]+optional.*pam_gnome_keyring\.so' "$startupPamPath"
        require "startup Hyprlock lacks password authentication" \
          '^auth[[:space:]].*pam_unix\.so' "$startupPamPath"
        refute "startup Hyprlock permits fingerprint authentication" \
          'pam_fprintd\.so' "$startupPamPath"
        require "passwd lacks GNOME Keyring password synchronization" \
          '^password[[:space:]]+optional.*pam_gnome_keyring\.so.*use_authtok' "$passwdPamPath"

        require "startup config selects the wrong PAM service" \
          '^    module=hyprlock-startup$' "$startupConfig"
        require "startup config permits native fingerprint authentication" \
          '^    enabled=false$' "$startupConfig"
        require "startup config lacks a password input" \
          '^input-field \{' "$startupConfig"
        refute "startup config depends on mutable user state or commands" \
          '(^|[[:space:]])source[[:space:]]*=|\$HOME|exec\(' "$startupConfig"

        touch "$out"
      '';
  eval-gnome = mkStubWarningGate "eval-gnome" evalGnome (
    mkDisplayManagerXorCheck "eval-gnome" evalGnome
  );
  eval-niri = mkStubWarningGate "eval-niri" evalNiri (mkDisplayManagerXorCheck "eval-niri" evalNiri);

  # Null-tolerance contract. With integration.ksPackage and
  # integration.agenixPackage null (vanilla nixpkgs, no keystone overlay) the
  # installed command set must match expectedStandaloneCommands EXACTLY.
  # Failing only on absence would let a ks-gated command silently disappear;
  # failing only on presence would let an unbuildable one silently appear.
  home-standalone =
    pkgs.runCommand "home-standalone"
      {
        packageNames = lib.concatStringsSep "\n" homeStandalonePackageNames;
        unitNames = lib.concatStringsSep "\n" homeStandaloneUnits;
        actual = lib.concatStringsSep " " actualStandaloneCommands;
        missing = lib.concatStringsSep " " missingStandaloneCommands;
        unexpected = lib.concatStringsSep " " unexpectedStandaloneCommands;
        leaked = lib.concatStringsSep " " leakedKsCommands;
        homePath = homeStandalone.config.home.path;
      }
      ''
        echo "home.packages (vanilla nixpkgs, no keystone overlay):"
        echo "$packageNames"
        echo "systemd user services:"
        echo "$unitNames"
        echo "keystone commands installed: $actual"
        test -d "$homePath"

        errors=0

        if [ -n "$missing" ]; then
          echo "FAIL(home-standalone): commands MISSING with ksPackage/agenixPackage null: $missing" >&2
          echo "  A command that stops being installed when ks is null takes its whole Walker surface with it." >&2
          errors=$((errors + 1))
        fi

        if [ -n "$unexpected" ]; then
          echo "FAIL(home-standalone): UNEXPECTED commands installed: $unexpected" >&2
          echo "  Add them to expectedStandaloneCommands (or to ksOnlyCommands if they need ks/agenix)." >&2
          errors=$((errors + 1))
        fi

        if [ -n "$leaked" ]; then
          echo "FAIL(home-standalone): ks/agenix-only commands installed with a null package: $leaked" >&2
          errors=$((errors + 1))
        fi

        if [ "$errors" -gt 0 ]; then
          exit 1
        fi

        echo "PASS(home-standalone): installed command set matches the null-integration contract"
        touch "$out"
      '';

  # Successor of keystone's hyprland-config-smoke collision guard: with the
  # FULL HM option surface enabled, nix must own zero files under the stowed
  # dotfile directories (.config/{hypr,wofi,walker}) — those paths
  # belong exclusively to the user's stowed dotfiles, and any home.file /
  # xdg.configFile entry there collides with stow at activation time.
  home-stow-collision =
    pkgs.runCommand "home-stow-collision"
      {
        collisions = lib.concatStringsSep " " stowCollisions;
      }
      ''
        if [ -n "$collisions" ]; then
          echo "FAIL: HM module writes into stowed dotfile paths: $collisions" >&2
          exit 1
        fi
        echo "PASS: no home.file/xdg.configFile entries under stowed dotfile directories"
        touch "$out"
      '';

  desktop-walker-surfaces = import ./module/desktop-walker-surfaces.nix { inherit pkgs; };
  desktop-health-monitor = import ./module/desktop-health-monitor.nix { inherit pkgs; };
  desktop-lock-recovery = import ./module/desktop-lock-recovery.nix { inherit pkgs; };
  desktop-hyprland-lua = import ./module/desktop-hyprland-lua.nix {
    inherit pkgs hyprland system;
  };
  desktop-main-menu-entries = import ./module/desktop-main-menu-entries.nix {
    inherit
      pkgs
      lib
      self
      home-manager
      ;
  };
  desktop-setup-menu-entries = import ./module/desktop-setup-menu-entries.nix { inherit pkgs lib; };
  desktop-fprintd = import ./module/desktop-fprintd.nix {
    inherit
      pkgs
      lib
      self
      nixpkgs
      home-manager
      system
      ;
  };
}
