# Checks for ks.systems/desktop.
#
# Called from flake.nix as:
#   import ./tests { inherit self nixpkgs home-manager; system = "x86_64-linux"; }
#
# Everything here is eval-only or grep-only — no check builds a compositor.
# The nixosSystem evals below intentionally consume the flake's public
# contract (nixosModules.default / homeModules.default) exactly the way an
# external consumer would, so contract regressions fail here first.
{
  self,
  nixpkgs,
  home-manager,
  hyprland,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

  templates = ../templates;

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

  # Every binary the templates invoke by bare name (hyprland.conf binds and
  # exec-once, hypridle.conf hooks, waybar on-click handlers). These MUST be
  # OS-level packages — the stowed configs run outside any HM wrapper PATH.
  # Guards the extraction risk of silently losing a binary that was HM-only
  # before (e.g. hyprpicker).
  templateBinaries = [
    "waybar"
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
  ];
  systemPackageNames = map lib.getName evalHyprland.config.environment.systemPackages;
  missingBinaries = lib.filter (name: !(lib.elem name systemPackageNames)) templateBinaries;

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

  # Standalone home-manager eval against VANILLA nixpkgs — no keystone
  # overlay, so pkgs.keystone.* does not exist. Proves the integration
  # options (ksPackage/agenixPackage) are null-tolerant and nothing else in
  # the HM tree reaches for keystone-owned packages. Forcing every
  # home.packages name and user unit instantiates the full surface without
  # building anything.
  homeStandalone = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home.username = "testuser";
        home.homeDirectory = "/home/testuser";
        home.stateVersion = "25.05";
        keystone.desktop.enable = true;
      }
    ];
  };
  homeStandalonePackageNames = map lib.getName homeStandalone.config.home.packages;
  homeStandaloneUnits = lib.attrNames homeStandalone.config.systemd.user.services;
  startupLockUnit = homeStandalone.config.systemd.user.services.keystone-startup-lock;
  persistentGraphicalServices = [
    "hypridle"
    "hyprpaper"
    "hyprsunset"
    "hyprpolkitagent"
    "mako"
    "swayosd"
    "waybar"
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
    "keystone-theme-switch"
    "keystone-wifi-menu"
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
    lib.unique (lib.filter (lib.hasPrefix "keystone-") homeStandalonePackageNames)
  );
  missingStandaloneCommands = lib.subtractLists actualStandaloneCommands expectedStandaloneCommands;
  unexpectedStandaloneCommands = lib.subtractLists expectedStandaloneCommands actualStandaloneCommands;
  leakedKsCommands = lib.filter (n: lib.elem n actualStandaloneCommands) ksOnlyCommands;

  # Full-surface HM eval for the stow-collision check: every option that can
  # contribute files is switched on (integration packages are stand-ins just
  # to un-gate the ks/agenix-dependent scripts and menus).
  homeFull = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home.username = "testuser";
        home.homeDirectory = "/home/testuser";
        home.stateVersion = "25.05";
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
            ksPackage = pkgs.hello;
            agenixPackage = pkgs.hello;
          };
        };
      }
    ];
  };
  configuredDefaultServices = {
    audio = homeFull.config.systemd.user.services.keystone-audio-defaults;
    printer = homeFull.config.systemd.user.services.keystone-printer-default;
  };
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
    "waybar"
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
  logindLidSwitch = evalHyprland.config.services.logind.settings.Login.HandleLidSwitch;
in
{
  # No personal literal may survive the template scrub: absolute home paths,
  # the upstream author's identity, hardware serials, or personal waybar
  # modules.
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

  template-binaries =
    pkgs.runCommand "template-binaries"
      {
        missing = lib.concatStringsSep " " missingBinaries;
      }
      ''
        if [ -n "$missing" ]; then
          echo "FAIL: template-invoked binaries missing from environment.systemPackages: $missing" >&2
          exit 1
        fi
        echo "PASS: all template-invoked binaries are OS-level packages"
        touch "$out"
      '';

  logind-lid-owner =
    pkgs.runCommand "logind-lid-owner"
      {
        inherit logindLidSwitch;
      }
      ''
        if [ "$logindLidSwitch" != "ignore" ]; then
          echo "FAIL: logind must ignore lid events so lock verification precedes suspend" >&2
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
      }
      ''
        echo "home.packages (vanilla nixpkgs, no keystone overlay):"
        echo "$packageNames"
        echo "systemd user services:"
        echo "$unitNames"
        echo "keystone commands installed: $actual"

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
  # dotfile directories (.config/{hypr,waybar,wofi,walker}) — those paths
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
