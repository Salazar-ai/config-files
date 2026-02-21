vim.g.mapleader = " "

vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })
 
vim.api.nvim_set_keymap('n', '<Esc><Esc>', ':nohlsearch<CR>', {noremap = true, silent = true})
-- Save with Space + w
vim.keymap.set("n", "<leader>w", ":w<CR>")

-- Quit with Space + q
vim.keymap.set("n", "<leader>q", ":q<CR>")

-- No more :q!
vim.keymap.set("n", "<leader>Q", ":q!<CR>")

-- Clear search highlight
vim.keymap.set("n", "<leader>h", ":nohlsearch<CR>")


-- Use system clipboard
vim.opt.clipboard = "unnamedplus"

-- Backspace works normally
vim.opt.backspace = "indent,eol,start"

-- Keep cursor centered
vim.opt.scrolloff = 8

-- Better movement with wrapped lines
vim.keymap.set("n", "j", "gj")
vim.keymap.set("n", "k", "gk")

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- Tabs & indentation
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true

-- Better searching
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- UI tweaks
vim.opt.cursorline = true
vim.opt.termguicolors = true
vim.opt.wrap = false

-- Faster response
vim.opt.timeoutlen = 300

require("config.lazy")

