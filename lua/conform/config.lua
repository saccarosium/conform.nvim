local defaults = {
    formatters_by_ft = {
        bash = { "shfmt" },
        c = { lsp_fallback = "prefer" },
        cpp = { lsp_fallback = "prefer" },
        lua = { "stylua" },
        python = { "black" },
        rust = { lsp_fallback = "prefer" },
        sh = { "shfmt" },
        typst = { "typstyle" },
    },
    formatters = {},
    notify_on_error = true,
    notify_no_formatters = true,
    default_format_opts = {},
}

local function is_dict_like_table(tbl)
    return type(tbl) == "table" and (not vim.islist(tbl) or vim.tbl_isempty(tbl))
end

local function get_config()
    local user_config = vim.g.conform or {}
    if type(user_config) == "function" then
        user_config = user_config()
    end

    assert(is_dict_like_table(user_config), "Malformed config")

    ---@param conf? conform.FiletypeFormatter
    local function check_for_default_opts(conf)
        if not conf or type(conf) ~= "table" then
            return
        end
        for k in pairs(conf) do
            if type(k) == "string" then
                vim.notify(
                    string.format(
                        'conform.setup: the "_" and "*" keys in formatters_by_ft do not support configuring format options, such as "%s"',
                        k
                    ),
                    vim.log.levels.WARN
                )
                break
            end
        end
    end

    local config = vim.tbl_deep_extend("force", defaults, user_config)
    check_for_default_opts(config.formatters_by_ft["_"])
    check_for_default_opts(config.formatters_by_ft["*"])

    if config.log_level then
        require("conform.log").level = config.log_level
    end

    if type(config.format_on_save) == "boolean" then
        config.format_on_save = {}
    end

    return config
end

return get_config()
