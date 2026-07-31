return {
  -- Nix owns editor binaries; LSP clients resolve tools from PATH.
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
}
