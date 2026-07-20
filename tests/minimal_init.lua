-- Minimal init for running plenary tests in headless mode
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

vim.cmd([[
  let g:plenary_busted_directory = 'tests/'
]])

-- Add project root and plenary to runtime path
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
local project_root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p:h:h"), ":p")
vim.opt.rtp:append(plenary_path)
vim.opt.rtp:append(project_root)
vim.opt.rtp:append(".")
