{
  description = "ks.systems/desktop — Keystone desktop environments (Hyprland session wiring, scripts, menus, theming, dotfile templates)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Used by the checks only; consumers bring their own home-manager.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    terminal = {
      url = "git+ssh://forgejo@git.ncrmro.com:2222/ks.systems/terminal.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # This flake is the single owner of the compositor pin. Tag pin (not main):
    # hyprland main has segfaulted before, and the live fleet runs the tagged
    # release. Consumers can override via `keystone.inputs.desktop.follows`.
    hyprland.url = "github:hyprwm/Hyprland?ref=v0.56.0";
    hyprpaper = {
      url = "github:hyprwm/hyprpaper?ref=v0.8.4";
      inputs.nixpkgs.follows = "hyprland/nixpkgs";
      inputs.systems.follows = "hyprland/systems";
      inputs.aquamarine.follows = "hyprland/aquamarine";
      inputs.hyprgraphics.follows = "hyprland/hyprgraphics";
      inputs.hyprlang.follows = "hyprland/hyprlang";
      inputs.hyprtoolkit.follows = "hyprland/hyprland-guiutils/hyprtoolkit";
      inputs.hyprutils.follows = "hyprland/hyprutils";
      inputs.hyprwayland-scanner.follows = "hyprland/hyprwayland-scanner";
      inputs.hyprwire.follows = "hyprland/hyprwire";
    };

    walker = {
      url = "github:abenz1267/walker";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak";

    # Quattro is the sole Omarchy source for QML, themes, templates, assets,
    # and the explicitly allowlisted compatibility scripts.
    omarchy = {
      url = "github:basecamp/omarchy/quattro";
      flake = false;
    };
    quickshell = {
      url = "git+https://git.outfoxxed.me/quickshell/quickshell?ref=refs/tags/v0.3.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      terminal,
      hyprland,
      hyprpaper,
      walker,
      nix-flatpak,
      omarchy,
      quickshell,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Inputs handed to the modules via _module.args. Named desktopInputs — a
      # distinct name that cannot collide with keystone terminal's
      # keystoneInputs at HM scope (the documented "defined multiple times"
      # trap when both module trees are active in one HM evaluation).
      desktopInputs = {
        inherit
          hyprland
          hyprpaper
          omarchy
          quickshell
          ;
        terminalThemeCatalog = terminal.lib.templatesPath + "/themes/.config/themes";
        terminalThemeNames = terminal.lib.themeNames;
        desktopSelf = self;
      };

      # nixpkgs with this flake's overlay applied, for the packages output.
      overlaidPkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
      desktopManifest = terminal.lib.dotfiles.manifestFrom ./templates;
      manifestOverlap = nixpkgs.lib.intersectLists (map (
        entry: entry.path
      ) terminal.lib.dotfiles.manifest) (map (entry: entry.path) desktopManifest);
      manifestOverlapMessage = "terminal and desktop dotfile templates overlap: ${nixpkgs.lib.concatStringsSep ", " manifestOverlap}";
    in
    {
      nixosModules = {
        default = {
          # nix-flatpak is imported here, hoisted at the flake level: deriving
          # imports from _module.args is keystone's documented infinite
          # recursion trap — flake-module imports must never depend on
          # module-system arguments.
          imports = [
            nix-flatpak.nixosModules.nix-flatpak
            ./modules/nixos/default.nix
          ];
          # Hoisted here, NEVER computed from _module.args (see above).
          _module.args.desktopInputs = desktopInputs;
          # Theming and the hyprland module reference
          # pkgs.keystone-desktop.{write-polkit-theme,hyprpolkitagent,
          # keystone-dpms-wake}; the wrapper applies the overlay so consumers
          # do not have to.
          nixpkgs.overlays = [ self.overlays.default ];
          home-manager.sharedModules = [ self.homeModules.default ];
        };
        # Bare per-DE modules, à-la-carte. They read the option surface
        # declared by modules/nixos/default.nix and expect desktopInputs in
        # _module.args — importing them standalone requires providing both.
        hyprland = ./modules/nixos/hyprland.nix;
        gnome = ./modules/nixos/gnome.nix;
        niri = ./modules/nixos/niri.nix;
      };

      homeModules.default = {
        # This flake's homeModules.default is the SOLE importer of walker's HM
        # module — a second import anywhere downstream reproduces the
        # `programs.walker.elephant` "already declared" eval error.
        imports = [
          terminal.homeModules.default
          walker.homeManagerModules.default
          ./modules/home/default.nix
        ];
        _module.args.desktopInputs = desktopInputs;
      };

      overlays.default = nixpkgs.lib.composeManyExtensions [
        terminal.overlays.default
        (import ./pkgs { inherit hyprland; })
      ];

      packages.${system} = {
        inherit (overlaidPkgs.keystone-desktop)
          keystone-dpms-wake
          keystone-lock
          keystone-suspend
          write-polkit-theme
          hyprpolkitagent
          ;

        # The composed terminal + desktop tree as one starter set. The two
        # manifests MUST NOT contain the same file path.
        dotfile-templates =
          assert nixpkgs.lib.assertMsg (manifestOverlap == [ ]) manifestOverlapMessage;
          pkgs.runCommand "keystone-dotfile-templates" { } ''
            mkdir -p $out
            cp -r ${terminal.packages.${system}.dotfile-templates}/. $out/
            cp -r ${./templates}/. $out/
          '';

        # Seed a user's dotfiles checkout with the template stow packages.
        # Templates are a starter set the user COPIES and then owns — nix
        # never links or stows them from the store. Existing files are
        # skipped unless --force is given.
        seed-dotfiles = pkgs.writeShellApplication {
          name = "seed-dotfiles";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.findutils
          ];
          text = ''
            usage() {
              echo "Usage: seed-dotfiles [--force] <dotfiles-packages-dir>" >&2
              echo "  e.g. seed-dotfiles ~/repos/\$USER/dotfiles/packages" >&2
            }

            force=0
            target=""
            for arg in "$@"; do
              case "$arg" in
                --force) force=1 ;;
                -h | --help)
                  usage
                  exit 0
                  ;;
                *) target="$arg" ;;
              esac
            done

            if [ -z "$target" ]; then
              usage
              exit 2
            fi

            templates=${self.packages.${system}.dotfile-templates}
            mkdir -p "$target"

            cd "$templates"
            find . -type f -print0 | while IFS= read -r -d "" f; do
              rel="''${f#./}"
              dest="$target/$rel"
              if [ -e "$dest" ] && [ "$force" -ne 1 ]; then
                echo "skip (exists): $rel"
                continue
              fi
              # install (not cp): store files are read-only; the seeded copy
              # must be writable — the user owns it from here on.
              install -D -m 0644 "$f" "$dest"
              echo "seeded: $rel"
            done
          '';
        };
      };

      lib = {
        templatesPath = ./templates;
        dotfiles.manifest =
          assert nixpkgs.lib.assertMsg (manifestOverlap == [ ]) manifestOverlapMessage;
          terminal.lib.dotfiles.manifest ++ desktopManifest;
      };

      checks.${system} = import ./tests {
        inherit
          self
          nixpkgs
          home-manager
          hyprland
          omarchy
          terminal
          ;
        inherit system;
      };

      formatter.${system} = pkgs.nixfmt;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixfmt
          nil
          shellcheck
          jq
        ];
      };
    };
}
