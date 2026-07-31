return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        astro = {},
        svelte = {
          keys = {
            {
              "<leader>co",
              LazyVim.lsp.action["source.organizeImports"],
              desc = "Organize Imports",
            },
          },
        },
      },
    },
  },
  {
    "conform.nvim",
    opts = function(_, opts)
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.astro = { "prettier" }
      opts.formatters_by_ft.svelte = { "prettier" }
    end,
  },
}
