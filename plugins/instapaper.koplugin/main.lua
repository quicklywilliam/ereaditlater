local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local InstapaperManager = require("frontend/ui/instapaper/manager")

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
}

function Instapaper:init()
    self.uimanager = InstapaperManager:new()
    self.ui.menu:registerToMainMenu(self)    
end

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = "Instapaper",
        sub_item_table = {
            {
                text = "Login",
                keep_menu_open = true,
                callback = function()
                    self.uimanager:showLoginDialog()
                end,
            },
            {
                text = "Show Articles",
                keep_menu_open = true,
                callback = function()
                    self.uimanager:showArticles()
                end,
            },
        },
    }
end

return Instapaper
