{ pkgs, ... }:
{
  xdg.configFile."nvim" = {
    source = ./nvim;
    recursive = true;
  };

  home.sessionVariables.NVIM_TREESITTER_NIX = "${pkgs.vimPlugins.nvim-treesitter.withAllGrammars}";

  home.packages = with pkgs; [
    astro-language-server
    biome
    cargo
    delve
    docker-compose-language-service
    dockerfile-language-server
    fd
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
