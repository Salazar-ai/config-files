return {
  "mikavilpas/yazi.nvim",

  keys = {
    {
      "<leader>e",
      "<cmd>Yazi<CR>",
      desc = "Open Yazi file manager",
    },
  },

  config = function()
    require("yazi").setup({})
  end,
}

