local M = {}

local config = require("conform.config")

---@type table<string, conform.FiletypeFormatter>
M.formatters_by_ft = config.formatters_by_ft

---@type table<string, conform.FormatterConfigOverride|fun(bufnr: integer): nil|conform.FormatterConfigOverride>
M.formatters = config.formatters

M.notify_on_error = config.notify_on_error
M.notify_no_formatters = config.notify_no_formatters

---@type conform.DefaultFormatOpts
M.default_format_opts = config.default_format_opts

-- Defer notifications because nvim-notify can throw errors if called immediately
-- in some contexts (e.g. inside statusline function)
local notify = vim.schedule_wrap(vim.notify)
local notify_once = vim.schedule_wrap(vim.notify_once)

---@param a table
---@param b table
---@param opts? { allow_filetype_opts?: boolean }
---@return table
local function merge_default_opts(a, b, opts)
    local allowed_default_opts = { "timeout_ms", "lsp_format", "quiet", "stop_after_first" }
    local allowed_default_filetype_opts = { "name", "id", "filter" }
    for _, key in ipairs(allowed_default_opts) do
        if a[key] == nil then
            a[key] = b[key]
        end
    end
    if opts and opts.allow_filetype_opts then
        for _, key in ipairs(allowed_default_filetype_opts) do
            if a[key] == nil then
                a[key] = b[key]
            end
        end
    end
    return a
end

---Get the configured formatter filetype for a buffer
---@param bufnr? integer
---@return nil|string filetype or nil if no formatter is configured. Can be "_".
local function get_matching_filetype(bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    local filetypes = vim.split(vim.bo[bufnr].filetype, ".", { plain = true })
    table.insert(filetypes, "_")
    for _, filetype in ipairs(filetypes) do
        local ft_formatters = M.formatters_by_ft[filetype]
        -- Sometimes people put an empty table here, and that should not count as configuring formatters
        -- for a filetype.
        if ft_formatters and not vim.tbl_isempty(ft_formatters) then
            return filetype
        end
    end
end

---@private
---@param bufnr? integer
---@return string[]
function M.list_formatters_for_buffer(bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    local formatters = {}
    local seen = {}

    local dedupe_formatters = function(names, collect)
        for _, name in ipairs(names) do
            if not seen[name] then
                table.insert(collect, name)
                seen[name] = true
            end
        end
    end

    local filetypes = {}
    local matching_filetype = get_matching_filetype(bufnr)
    if matching_filetype then
        table.insert(filetypes, matching_filetype)
    end
    table.insert(filetypes, "*")

    for _, ft in ipairs(filetypes) do
        local ft_formatters = M.formatters_by_ft[ft]
        if ft_formatters then
            if type(ft_formatters) == "function" then
                dedupe_formatters(ft_formatters(bufnr), formatters)
            else
                dedupe_formatters(ft_formatters, formatters)
            end
        end
    end

    return formatters
end

---@param bufnr? integer
---@return nil|conform.DefaultFiletypeFormatOpts
local function get_opts_from_filetype(bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    local matching_filetype = get_matching_filetype(bufnr)
    if not matching_filetype then
        return nil
    end

    local ft_formatters = M.formatters_by_ft[matching_filetype]
    assert(ft_formatters ~= nil, "get_matching_filetype ensures formatters_by_ft has key")
    if type(ft_formatters) == "function" then
        ft_formatters = ft_formatters(bufnr)
    end
    return merge_default_opts({}, ft_formatters, { allow_filetype_opts = true })
end

---@param bufnr integer
---@param mode "v"|"V"
---@return conform.Range {start={row,col}, end={row,col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
    -- [bufnum, lnum, col, off]; both row and column 1-indexed
    local start = vim.fn.getpos("v")
    local end_ = vim.fn.getpos(".")
    local start_row = start[2]
    local start_col = start[3]
    local end_row = end_[2]
    local end_col = end_[3]

    -- A user can start visual selection at the end and move backwards
    -- Normalize the range to start < end
    if start_row == end_row and end_col < start_col then
        end_col, start_col = start_col, end_col
    elseif end_row < start_row then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end
    if mode == "V" then
        start_col = 1
        local lines = vim.api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
        end_col = #lines[1]
    end
    return {
        ["start"] = { start_row, start_col - 1 },
        ["end"] = { end_row, end_col - 1 },
    }
end

---@private
---@param names conform.FiletypeFormatterInternal
---@param bufnr integer
---@param warn_on_missing boolean
---@return conform.FormatterInfo[]
function M.resolve_formatters(names, bufnr, warn_on_missing)
    local all_info = {}

    local add_info = function(info, warn)
        if info.available then
            table.insert(all_info, info)
        elseif warn then
            notify(string.format("Formatter '%s' unavailable: %s", info.name, info.available_msg), vim.log.levels.WARN)
        end
        return info.available
    end

    for _, name in ipairs(names) do
        if type(name) == "string" then
            local info = M.get_formatter_info(name, bufnr)
            add_info(info, warn_on_missing)
        end

        if not vim.tbl_isempty(all_info) then
            break
        end
    end
    return all_info
end

---Check if there are any formatters configured specifically for the buffer's filetype
---@param bufnr integer
---@return boolean
local function has_filetype_formatters(bufnr)
    local matching_filetype = get_matching_filetype(bufnr)
    return matching_filetype ~= nil and matching_filetype ~= "_"
end

---@param opts table
---@return boolean
local function has_lsp_formatter(opts)
    local lsp_format = require("conform.lsp_format")
    return not vim.tbl_isempty(lsp_format.get_format_clients(opts))
end

local has_notified_ft_no_formatters = {}

---Format a buffer
---@param opts? conform.FormatOpts
---@param callback? fun(err: nil|string, did_edit: nil|boolean) Called once formatting has completed
---@return boolean True if any formatters were attempted
function M.format(opts, callback)
    if vim.fn.has("nvim-0.10") == 0 then
        notify_once("conform.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
        if callback then
            callback("conform.nvim requires Neovim 0.10+")
        end
        return false
    end
    opts = opts or {}
    local has_explicit_formatters = opts.formatters ~= nil
    -- If formatters were not passed in directly, fetch any options from formatters_by_ft
    if not has_explicit_formatters then
        merge_default_opts(opts, get_opts_from_filetype(opts.bufnr) or {}, { allow_filetype_opts = true })
    end
    merge_default_opts(opts, M.default_format_opts)
    ---@type {timeout_ms: integer, bufnr: integer, async: boolean, dry_run: boolean, lsp_format: "never"|"first"|"last"|"prefer"|"fallback", quiet: boolean, stop_after_first: boolean, formatters?: string[], range?: conform.Range, undojoin: boolean}
    opts = vim.tbl_extend("keep", opts, {
        timeout_ms = 1000,
        bufnr = 0,
        async = false,
        dry_run = false,
        lsp_format = "never",
        quiet = false,
        undojoin = false,
        stop_after_first = false,
    })
    if opts.bufnr == 0 then
        opts.bufnr = vim.api.nvim_get_current_buf()
    end

    -- For backwards compatibility
    ---@diagnostic disable-next-line: undefined-field
    if opts.lsp_fallback == true then
        opts.lsp_format = "fallback"
    ---@diagnostic disable-next-line: undefined-field
    elseif opts.lsp_fallback == "always" then
        opts.lsp_format = "last"
    end

    local mode = vim.api.nvim_get_mode().mode
    if not opts.range and mode == "v" or mode == "V" then
        opts.range = range_from_selection(opts.bufnr, mode)
    end
    callback = callback or function(_, _) end
    local errors = require("conform.errors")
    local log = require("conform.log")
    local lsp_format = require("conform.lsp_format")
    local runner = require("conform.runner")

    local formatter_names = opts.formatters or M.list_formatters_for_buffer(opts.bufnr)
    local formatters = M.resolve_formatters(formatter_names, opts.bufnr, not opts.quiet and has_explicit_formatters)
    local has_lsp = has_lsp_formatter(opts)

    ---Handle errors and maybe run LSP formatting after cli formatters complete
    ---@param err? conform.Error
    ---@param did_edit? boolean
    local function handle_result(err, did_edit)
        if err then
            local level = errors.level_for_code(err.code)
            log.log(level, err.message)
            ---@type boolean?
            local should_notify = not opts.quiet and level >= vim.log.levels.WARN
            -- Execution errors have special handling. Maybe should reconsider this.
            local notify_msg = err.message
            if errors.is_execution_error(err.code) then
                should_notify = should_notify and M.notify_on_error and not err.debounce_message
                notify_msg = "Formatter failed. See :ConformInfo for details"
            end
            if should_notify then
                notify(notify_msg, level)
            end
        end
        local err_message = err and err.message
        if not err_message and not vim.api.nvim_buf_is_valid(opts.bufnr) then
            err_message = "buffer was deleted"
        end
        if err_message then
            return callback(err_message)
        end

        if opts.dry_run and did_edit then
            callback(nil, true)
        elseif opts.lsp_format == "last" and has_lsp then
            log.debug("Running LSP formatter on %s", vim.api.nvim_buf_get_name(opts.bufnr))
            lsp_format.format(opts, callback)
        else
            callback(nil, did_edit)
        end
    end

    ---Run the resolved formatters on the buffer
    local function run_cli_formatters(cb)
        local resolved_names = vim.tbl_map(function(f)
            return f.name
        end, formatters)
        log.debug("Running formatters on %s: %s", vim.api.nvim_buf_get_name(opts.bufnr), resolved_names)
        ---@type conform.RunOpts
        local run_opts = { exclusive = true, dry_run = opts.dry_run, undojoin = opts.undojoin }
        if opts.async then
            runner.format_async(opts.bufnr, formatters, opts.range, run_opts, cb)
        else
            local err, did_edit = runner.format_sync(opts.bufnr, formatters, opts.timeout_ms, opts.range, run_opts)
            cb(err, did_edit)
        end
    end

    -- check if formatters were configured for this buffer's filetype specifically (i.e. not the "_"
    -- or "*" formatters) AND that at least one of the configured formatters is available
    local any_formatters = has_filetype_formatters(opts.bufnr) and not vim.tbl_isempty(formatters)

    if has_lsp and (opts.lsp_format == "prefer" or (opts.lsp_format ~= "never" and not any_formatters)) then
        -- LSP formatting only
        log.debug("Running LSP formatter on %s", vim.api.nvim_buf_get_name(opts.bufnr))
        lsp_format.format(opts, callback)
        return true
    elseif has_lsp and opts.lsp_format == "first" then
        -- LSP formatting, then other formatters
        log.debug("Running LSP formatter on %s", vim.api.nvim_buf_get_name(opts.bufnr))
        lsp_format.format(opts, function(err, did_edit)
            if err or (did_edit and opts.dry_run) then
                return callback(err, did_edit)
            end
            run_cli_formatters(function(err2, did_edit2)
                handle_result(err2, did_edit or did_edit2)
            end)
        end)
        return true
    elseif not vim.tbl_isempty(formatters) then
        run_cli_formatters(handle_result)
        return true
    else
        local level = has_explicit_formatters and "warn" or "debug"
        log[level]("Formatters unavailable for %s", vim.api.nvim_buf_get_name(opts.bufnr))

        local ft = vim.bo[opts.bufnr].filetype
        if
            not vim.tbl_isempty(formatter_names)
            and not has_notified_ft_no_formatters[ft]
            and not opts.quiet
            and M.notify_no_formatters
        then
            notify(string.format("Formatters unavailable for %s file", ft), vim.log.levels.WARN)
            has_notified_ft_no_formatters[ft] = true
        end

        callback("No formatters available for buffer")
        return false
    end
end

---Process lines with formatters
---@private
---@param formatter_names string[]
---@param lines string[]
---@param opts? conform.FormatLinesOpts
---@param callback? fun(err: nil|conform.Error, lines: nil|string[]) Called once formatting has completed
---@return nil|conform.Error error Only present if async = false
---@return nil|string[] new_lines Only present if async = false
function M.format_lines(formatter_names, lines, opts, callback)
    ---@type {timeout_ms: integer, bufnr: integer, async: boolean, quiet: boolean, stop_after_first: boolean}
    opts = vim.tbl_extend("keep", opts or {}, {
        timeout_ms = 1000,
        bufnr = 0,
        async = false,
        quiet = false,
        stop_after_first = false,
    })
    callback = callback or function(_, _) end
    local errors = require("conform.errors")
    local log = require("conform.log")
    local runner = require("conform.runner")
    local formatters = M.resolve_formatters(formatter_names, opts.bufnr, not opts.quiet)
    if vim.tbl_isempty(formatters) then
        callback(nil, lines)
        return
    end

    ---@param err? conform.Error
    ---@param new_lines? string[]
    local handle_err = function(err, new_lines)
        if err then
            local level = errors.level_for_code(err.code)
            log.log(level, err.message)
        end
        callback(err, new_lines)
    end

    ---@type conform.RunOpts
    local run_opts = { exclusive = false, dry_run = false, undojoin = false }
    if opts.async then
        runner.format_lines_async(opts.bufnr, formatters, nil, lines, run_opts, handle_err)
    else
        local err, new_lines = runner.format_lines_sync(opts.bufnr, formatters, opts.timeout_ms, nil, lines, run_opts)
        handle_err(err, new_lines)
        return err, new_lines
    end
end

---Retrieve the available formatters for a buffer
---@param bufnr? integer
---@return conform.FormatterInfo[]
function M.list_formatters(bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    local formatters = M.list_formatters_for_buffer(bufnr)
    return M.resolve_formatters(formatters, bufnr, false, false)
end

---Get the exact formatters that will be run for a buffer.
---@param bufnr? integer
---@return conform.FormatterInfo[]
---@return boolean lsp Will use LSP formatter
---@note
--- This accounts for stop_after_first, lsp fallback logic, etc.
function M.list_formatters_to_run(bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    ---@type {bufnr: integer, lsp_format: conform.LspFormatOpts, stop_after_first: boolean}
    local opts = vim.tbl_extend(
        "keep",
        get_opts_from_filetype(bufnr) or {},
        M.default_format_opts,
        { stop_after_first = false, lsp_format = "never", bufnr = bufnr }
    )
    local formatter_names = M.list_formatters_for_buffer(bufnr)
    local formatters = M.resolve_formatters(formatter_names, bufnr, false, opts.stop_after_first)

    local has_lsp = has_lsp_formatter(opts)
    local any_formatters = has_filetype_formatters(opts.bufnr) and not vim.tbl_isempty(formatters)

    if has_lsp and (opts.lsp_format == "prefer" or (opts.lsp_format ~= "never" and not any_formatters)) then
        return {}, true
    elseif has_lsp and opts.lsp_format == "first" then
        return formatters, true
    elseif not vim.tbl_isempty(formatters) then
        return formatters, opts.lsp_format == "last" and has_lsp
    else
        return {}, false
    end
end

---List information about all filetype-configured formatters
---@return conform.FormatterInfo[]
function M.list_all_formatters()
    local formatters = {}

    for _, ft_formatters in pairs(M.formatters_by_ft) do
        if type(ft_formatters) == "function" then
            ft_formatters = ft_formatters(0)
        end

        for _, formatter in ipairs(ft_formatters) do
            formatters[formatter] = true
        end
    end

    ---@type conform.FormatterInfo[]
    local all_info = {}
    for formatter in pairs(formatters) do
        local info = M.get_formatter_info(formatter)
        table.insert(all_info, info)
    end

    table.sort(all_info, function(a, b)
        return a.name < b.name
    end)

    return all_info
end

---@private
---@param formatter string
---@param bufnr? integer
---@return nil|conform.FormatterConfig
function M.get_formatter_config(formatter, bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    ---@type nil|conform.FormatterConfigOverride|fun(bufnr: integer): nil|conform.FormatterConfigOverride
    local override = M.formatters[formatter]
    if type(override) == "function" then
        override = override(bufnr)
    end

    if override and override.command and override.format then
        local msg = string.format("Formatter '%s' cannot define both 'command' and 'format' function", formatter)
        notify_once(msg, vim.log.levels.ERROR)
        return nil
    end

    ---@type nil|conform.FormatterConfig
    local config = override
    if not override or override.inherit ~= false then
        local ok, mod_config = pcall(require, "conform.formatters." .. formatter)
        if ok then
            if override then
                config = require("conform.util").merge_formatter_configs(mod_config, override)
            else
                config = mod_config
            end
        elseif override then
            if override.command or override.format then
                config = override
            else
                local msg = string.format(
                    "Formatter '%s' missing built-in definition\nSet `command` to get rid of this error.",
                    formatter
                )
                notify_once(msg, vim.log.levels.ERROR)
                return nil
            end
        else
            return nil
        end
    end

    if config and config.stdin == nil then
        config.stdin = true
    end

    return config
end

---Get information about a formatter (including availability)
---@param formatter string The name of the formatter
---@param bufnr? integer
---@return conform.FormatterInfo
function M.get_formatter_info(formatter, bufnr)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end
    local formatter_config = M.get_formatter_config(formatter, bufnr)
    if not formatter_config then
        return {
            name = formatter,
            command = formatter,
            available = false,
            available_msg = "Unknown formatter. Formatter config missing or incomplete",
            error = true,
        }
    end

    local ctx = require("conform.runner").build_context(bufnr, formatter_config)

    local available = true
    local available_msg = nil
    if formatter_config.format then
        ---@cast config conform.LuaFormatterConfig
        if formatter_config.condition and not formatter_config:condition(ctx) then
            available = false
            available_msg = "Condition failed"
        end
        return {
            name = formatter,
            command = formatter,
            available = available,
            available_msg = available_msg,
        }
    end

    local command = formatter_config.command
    if type(command) == "function" then
        ---@cast config conform.JobFormatterConfig
        command = command(formatter_config, ctx)
    end

    if vim.fn.executable(command) == 0 then
        available = false
        available_msg = "Command not found"
    elseif formatter_config.condition and not formatter_config.condition(formatter_config, ctx) then
        available = false
        available_msg = "Condition failed"
    end
    local cwd = nil
    if formatter_config.cwd then
        ---@cast config conform.JobFormatterConfig
        cwd = formatter_config.cwd(formatter_config, ctx)
        if available and not cwd and formatter_config.require_cwd then
            available = false
            available_msg = "Root directory not found"
        end
    end

    ---@type conform.FormatterInfo
    return {
        name = formatter,
        command = command,
        cwd = cwd,
        available = available,
        available_msg = available_msg,
    }
end

return M
