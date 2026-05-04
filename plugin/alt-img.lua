if vim.g.loaded_alt_img then
    return
end
vim.g.loaded_alt_img = true

vim.api.nvim_set_hl(0, "AltImgPlaceholder", { default = true, link = "Comment" })

vim.api.nvim_create_user_command("AltImg", function(opts)
    require("alt-img._core.cmd").dispatch(opts)
end, {
    nargs = "*",
    desc = "alt-img diagnostics and runtime control",
    complete = function(arg_lead, line, pos)
        return require("alt-img._core.cmd").complete(arg_lead, line, pos)
    end,
})
