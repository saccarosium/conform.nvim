local notify = vim.schedule_wrap(vim.notify)
local notify_once = vim.schedule_wrap(vim.notify_once)

vim.defer_fn(function()
    if vim.fn.has("nvim-0.10") == 0 then
        notify("conform.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
        return
    end

    local config = require("conform.config")

    local aug = vim.api.nvim_create_augroup("Conform", { clear = true })
    if config.format_on_save then
        vim.api.nvim_create_autocmd("BufWritePre", {
            desc = "Format on save",
            pattern = "*",
            group = aug,
            callback = function(args)
                if not vim.api.nvim_buf_is_valid(args.buf) or vim.bo[args.buf].buftype ~= "" then
                    return
                end
                local format_args, callback = config.format_on_save, nil
                if type(format_args) == "function" then
                    format_args, callback = format_args(args.buf)
                end
                if format_args then
                    if format_args.async then
                        notify_once(
                            "Conform format_on_save cannot use async=true. Use format_after_save instead.",
                            vim.log.levels.ERROR
                        )
                    end
                    require("conform").format(
                        vim.tbl_deep_extend("force", format_args, {
                            buf = args.buf,
                            async = false,
                        }),
                        callback
                    )
                end
            end,
        })

        vim.api.nvim_create_autocmd("VimLeavePre", {
            desc = "conform.nvim hack to work around Neovim bug",
            pattern = "*",
            group = aug,
            callback = function()
                -- HACK: Work around https://github.com/neovim/neovim/issues/21856
                -- causing exit code 134 on :wq
                vim.cmd.sleep({ args = { "1m" } })
            end,
        })
    end

    if config.format_after_save then
        if type(config.format_after_save) == "boolean" then
            config.format_after_save = {}
        end
        local exit_timeout = 1000
        local num_running_format_jobs = 0
        vim.api.nvim_create_autocmd("BufWritePost", {
            desc = "Format after save",
            pattern = "*",
            group = aug,
            callback = function(args)
                if
                    not vim.api.nvim_buf_is_valid(args.buf)
                    or vim.b[args.buf].conform_applying_formatting
                    or vim.bo[args.buf].buftype ~= ""
                then
                    return
                end
                local format_args, callback = config.format_after_save, nil
                if type(format_args) == "function" then
                    format_args, callback = format_args(args.buf)
                end
                if format_args then
                    exit_timeout = format_args.timeout_ms or exit_timeout
                    num_running_format_jobs = num_running_format_jobs + 1
                    if format_args.async == false then
                        notify_once(
                            "Conform format_after_save cannot use async=false. Use format_on_save instead.",
                            vim.log.levels.ERROR
                        )
                    end
                    M.format(
                        vim.tbl_deep_extend("force", format_args, {
                            buf = args.buf,
                            async = true,
                        }),
                        function(err)
                            num_running_format_jobs = num_running_format_jobs - 1
                            if not err and vim.api.nvim_buf_is_valid(args.buf) then
                                vim.api.nvim_buf_call(args.buf, function()
                                    vim.b[args.buf].conform_applying_formatting = true
                                    vim.cmd.update()
                                    vim.b[args.buf].conform_applying_formatting = false
                                end)
                            end
                            if callback then
                                callback(err)
                            end
                        end
                    )
                end
            end,
        })

        vim.api.nvim_create_autocmd("BufWinLeave", {
            desc = "conform.nvim store changedtick for use during Neovim exit",
            pattern = "*",
            group = aug,
            callback = function(args)
                -- We store this because when vim is exiting it will set changedtick = -1 for visible
                -- buffers right after firing BufWinLeave
                vim.b[args.buf].last_changedtick = vim.api.nvim_buf_get_changedtick(args.buf)
            end,
        })

        vim.api.nvim_create_autocmd("VimLeavePre", {
            desc = "conform.nvim wait for running formatters before exit",
            pattern = "*",
            group = aug,
            callback = function()
                if num_running_format_jobs == 0 then
                    return
                end
                local uv = vim.uv or vim.loop
                local start = uv.hrtime() / 1e6
                vim.wait(exit_timeout, function()
                    return num_running_format_jobs == 0
                end, 10)
                local elapsed = uv.hrtime() / 1e6 - start
                if elapsed > 200 then
                    local log = require("conform.log")
                    log.warn("Delayed Neovim exit by %dms to wait for formatting to complete", elapsed)
                end
                -- HACK: Work around https://github.com/neovim/neovim/issues/21856
                -- causing exit code 134 on :wq
                vim.cmd.sleep({ args = { "1m" } })
            end,
        })
    end

    vim.api.nvim_create_user_command("ConformInfo", function()
        require("conform.health").show_window()
    end, { desc = "Show information about Conform formatters" })

    vim.api.nvim_create_user_command("Conform", function()
        require("conform").format({
            stop_after_first = true,
            undojoin = true,
        }, function(err, did_edit)
            if err then
                vim.notify("Conform: failed to format the buffer", vim.log.levels.ERROR)
            elseif did_edit then
                vim.notify("Conform: formated the buffer successfully")
            elseif not did_edit then
                vim.notify("Conform: nothing to do")
            end
        end)
    end, { desc = "Format current buffer" })
end, 0)
