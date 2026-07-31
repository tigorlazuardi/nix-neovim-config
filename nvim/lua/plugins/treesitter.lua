local treesitter = vim.fn.stdpath("data") .. "/nix/nvim-treesitter"

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
