local _ = require("gettext")
local UIManager = require("ui/uimanager")

local InstapaperUIManager = {}

function InstapaperUIManager:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    return o
end

return InstapaperUIManager
