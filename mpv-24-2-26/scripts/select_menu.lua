local mp = require("mp")
local utils = require("mp.utils")

local function open_menu()
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        title = "Select",
        items = {
            { title = "Subtitle Line",  value = {"script-binding", "select/select-subtitle-line"} },
            { title = "Watch History",   value = {"script-binding", "select/select-watch-history"} },
            { title = "Watch Later",     value = {"script-binding", "select/select-watch-later"} },
            --To add another function/options
            --{ title = "New Item", value = {"your-command", "arg1", "arg2"} },


        }
    }))
end

mp.add_key_binding(nil, "open-select-menu", open_menu)
