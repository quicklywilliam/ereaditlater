local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local Trapper = require("ui/trapper")
local InstapaperManager = require("frontend/ui/instapaper/manager")

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    kv = nil, -- KeyValuePage
}

function Instapaper:init()
    self.uimanager = InstapaperManager:new()
    self.ui.menu:registerToMainMenu(self)    
end

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = "Instapaper",
        callback = function()
            Trapper:wrap(function()
                self.uimanager:showArticles()
            end)
        end,
    }
end

return Instapaper
