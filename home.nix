{ pkgs, ... }:
{
  xdg.configFile."nvim" = {
    source = ./nvim;
    recursive = true;
  };

  home.packages = with pkgs; [
    biome
    cargo
    go
    gopls
    lsof
    statix
    typescript-go
    typescript-language-server
    unzip
  ];
}
