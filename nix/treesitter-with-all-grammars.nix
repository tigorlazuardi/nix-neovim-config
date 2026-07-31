{
  symlinkJoin,
  vimPlugins,
}:
let
  treesitter = vimPlugins.nvim-treesitter.withAllGrammars;
in
symlinkJoin {
  name = "nvim-treesitter-with-all-grammars";
  paths = [ treesitter ] ++ treesitter.dependencies;
}
