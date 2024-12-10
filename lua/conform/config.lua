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
        json = { "prettierd", "prettier", "jq", "fixjson" },
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
    local config = vim.tbl_deep_extend("force", defaults, user_config)

    if config.log_level then
        require("conform.log").level = config.log_level
    end

    return config
end

return get_config()
