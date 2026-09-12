{
  self,
  nixpkgs,
  home-manager,
  system,
}:
let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ self.overlays.default ];
  };
  homeDirectory = "/home/testuser";
  repoPath = "${homeDirectory}/repos/testuser/dotfiles";
  templates = self.packages.${system}.dotfile-templates;
in
pkgs.testers.runNixOSTest {
  name = "keystone-desktop-template-dotfiles";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        home-manager.nixosModules.home-manager
        self.nixosModules.default
      ];

      nixpkgs.overlays = lib.mkForce [ self.overlays.default ];
      system.stateVersion = "25.05";
      users.users.testuser = {
        isNormalUser = true;
        home = homeDirectory;
        createHome = true;
      };

      keystone.desktop = {
        enable = true;
        user = "testuser";
        environment = "hyprland";
        obs.enable = false;
      };

      # A headless twin validates the installed desktop and Home Manager
      # activation without attempting to own a physical DRM seat.
      services.greetd.enable = lib.mkForce false;

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.testuser = {
          home = {
            username = "testuser";
            inherit homeDirectory;
            stateVersion = "25.05";
          };

          keystone.terminal = {
            ai.enable = false;
            git.enable = false;
            sandbox.enable = false;
            dotfiles = {
              enable = true;
              inherit repoPath;
            };
          };
          keystone.desktop.enable = true;
        };
      };
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("home-manager-testuser.service")

    source = "${repoPath}/packages/hyprland/.config/hypr/hyprland.lua"
    target = "${homeDirectory}/.config/hypr/hyprland.lua"
    machine.succeed("test -d ${repoPath}/.git")
    machine.succeed(f"test \"$(readlink -f {target})\" = \"{source}\"")
    machine.succeed(f"cmp {source} ${templates}/hyprland/.config/hypr/hyprland.lua")
    machine.succeed(f"test \"$(stat -c %U {source})\" = testuser")
    machine.succeed(f"runuser -u testuser -- test -w {source}")

    terminal_source = "${repoPath}/packages/zsh/.zshrc"
    terminal_target = "${homeDirectory}/.zshrc"
    machine.succeed(f"test \"$(readlink -f {terminal_target})\" = \"{terminal_source}\"")

    marker = "# twin-live-edit"
    machine.succeed(f"runuser -u testuser -- sh -c 'printf \"\\n{marker}\\n\" >> {source}'")
    machine.succeed(f"tail -n 1 {target} | grep -Fx \"{marker}\"")
    machine.succeed("systemctl restart home-manager-testuser.service")
    machine.wait_for_unit("home-manager-testuser.service")
    machine.succeed(f"tail -n 1 {source} | grep -Fx \"{marker}\"")
    machine.succeed(f"test \"$(readlink -f {target})\" = \"{source}\"")
    machine.fail(f"readlink -f {target} | grep -q '^/nix/store/'")
  '';
}
