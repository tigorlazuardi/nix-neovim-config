local treesitter = assert(vim.env.NVIM_TREESITTER_NIX, "NVIM_TREESITTER_NIX is not set; activate Home Manager")

return {
  {
    "nvim-treesitter/nvim-treesitter",
    dir = treesitter,
    build = false,
    -- Nix bundles every grammar; an empty list prevents network installs.
    opts = function(_, opts)
      opts.ensure_installed = {}
    end,
  },
}
