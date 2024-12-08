if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("conform.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
    return
end

vim.api.nvim_create_user_command("Conform", function(args)
    local cmd = args.fargs[1]
    if cmd == "info" then
        require("conform.health").show_window()
    elseif cmd == "fmt" then
        require("conform").format({
            stop_after_first = true,
            undojoin = true,
        }, function(err, did_edit)
            if err then
                vim.notify("Conform: failed to format", vim.log.levels.ERROR)
            elseif did_edit then
                vim.notify("Conform: formated the buffer")
            else
                vim.notify("Conform: nothing to do")
            end
        end)
    end
end, {
    nargs = 1,
    complete = function(lead, _, _)
        return vim.tbl_filter(function(x)
            return x:match(lead)
        end, { "fmt", "info" })
    end,
})
