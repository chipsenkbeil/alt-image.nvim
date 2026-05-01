-- Auto-loaded by Neovim's runtimepath. Keep this file deliberately small —
-- it should not eagerly `require()` the alt-img modules. Each command's
-- callback defers to `lua/alt-img/_cmd.lua` so the plugin only pays its
-- module-load cost when the user actually invokes a command (or sets
-- vim.ui.img to one of our providers).

if vim.g.loaded_alt_img then
    return
end
vim.g.loaded_alt_img = true

vim.api.nvim_create_user_command("AltImg", function(opts)
    require("alt-img._cmd").dispatch(opts)
end, {
    nargs = "*",
    desc = "alt-img diagnostics and runtime control",
    complete = function(arg_lead, line, pos)
        return require("alt-img._cmd").complete(arg_lead, line, pos)
    end,
})
