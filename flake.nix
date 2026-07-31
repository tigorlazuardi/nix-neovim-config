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
      pkgs = nixpkgs.legacyPackages.${system};
      treesitterWithAllGrammars = pkgs.callPackage ./nix/treesitter-with-all-grammars.nix { };
    in
    {
      homeModules.default = import ./home.nix;

      checks.${system} = {
        home =
          (home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeModules.default
              {
                home.username = "test";
                home.homeDirectory = "/home/test";
                home.stateVersion = "25.11";
              }
            ];
          }).activationPackage;

        treesitter-grammars = pkgs.runCommand "check-nvim-treesitter-grammars" { } ''
          parser_count=$(find ${treesitterWithAllGrammars}/parser -maxdepth 1 -name '*.so' | wc -l)
          test "$parser_count" -gt 0
          touch "$out"
        '';
      };
    };
}
