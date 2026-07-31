{ pkgs, ... }:
let
  treesitterWithAllGrammars = pkgs.callPackage ./nix/treesitter-with-all-grammars.nix { };
in
{
  xdg.configFile."nvim" = {
    source = ./nvim;
    recursive = true;
  };

  xdg.dataFile."nvim/nix/nvim-treesitter".source = treesitterWithAllGrammars;

  home.packages = with pkgs; [
    astro-language-server
    biome
    cargo
    delve
    docker-compose-language-service
    dockerfile-language-server
    fd
    gcc
    git
    go
    gofumpt
    golangci-lint
    gomodifytags
    gopls
    gotools
    hadolint
    impl
    lazygit
    lsof
    lua-language-server
    markdown-toc
    markdownlint-cli2
    nil
    nixfmt
    nodejs
    prettier
    ripgrep
    shfmt
    sops
    sqlfluff
    statix
    stylua
    svelte-language-server
    tailwindcss-language-server
    taplo
    tree-sitter
    typescript-go
    unzip
    vscode-langservers-extracted
    yaml-language-server
  ];
}
