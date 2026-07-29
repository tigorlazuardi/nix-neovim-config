{
  description = "LazyVim config as a Home Manager module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      system = "x86_64-linux";
    in
    {
      homeModules.default = import ./home.nix;

      checks.${system}.home = (home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [
          self.homeModules.default
          {
            home.username = "test";
            home.homeDirectory = "/home/test";
            home.stateVersion = "25.11";
          }
        ];
      }).activationPackage;
    };
}
