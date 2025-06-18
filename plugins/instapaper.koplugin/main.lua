local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InstapaperUIManager = require("frontend/ui/instapaper/manager")
local InstapaperManager = require("instapapermanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local Trapper = require("ui/trapper")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UI = require("ui/trapper")

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    kv = nil, -- KeyValuePage
}

-- DEVELOPMENT ONLY: Load stored credentials from api_keys.txt for testing convenience
local function loadDevCredentials()
    local stored_username = ""
    local stored_password = ""
    local secrets_path = "plugins/instapaper.koplugin/secrets.txt"
    local file = io.open(secrets_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        
        for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
            if key == "instapaper_username" then
                stored_username = value
            elseif key == "instapaper_password" then
                stored_password = value
            end
        end
    end
    return stored_username, stored_password
end

function Instapaper:init()
    self.uimanager = InstapaperUIManager:new()
    self.instapaperManager = InstapaperManager:new()
    self.ui.menu:registerToMainMenu(self)    
end

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = "Instapaper",
        callback = function()
            Trapper:wrap(function()
                if self.instapaperManager:isAuthenticated() then
                    self:showArticles() 
                else
                    self:showLoginDialog()
                end
            end)
        end,
    }
end

function Instapaper:showLoginDialog()
    -- DEVELOPMENT ONLY: Pre-fill credentials for testing
    local stored_username, stored_password = loadDevCredentials()

    self.kv = KeyValuePage:new{
        title = _("Instapaper"),
        value_overflow_align = "right",
        callback_return = function()
            UIManager:close(self.kv)
        end,    
    }
    UIManager:show(self.kv)
    
    self.login_dialog = MultiInputDialog:new{
        title = _("Instapaper Login"),
        fields = {
            {
                text = stored_username,
                hint = _("Username"),
            },
            {
                text = stored_password,
                text_type = "password",
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        local username = fields[1]:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
                        local password = fields[2]
                        
                        if username == "" or password == "" then
                            UIManager:show(ConfirmBox:new{
                                text = _("Please enter both username and password."),
                                ok_text = _("OK"),
                            })
                            return
                        end
                        
                        UIManager:close(self.login_dialog)
                        
                        -- Show loading message
                        local info = InfoMessage:new{ text = _("Authenticating") }
                        UIManager:show(info)
                        
                        -- Perform authentication
                        local success = self.instapaperManager:authenticate(username, password)

                        UIManager:close(info)

                        if success then
                            self:showArticles()
                        else 
                            UIManager:show(ConfirmBox:new{
                                text = _("Authentication failed. Please check your username and password."),
                                ok_text = _("OK"),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function Instapaper:showArticles()
    if self.kv then
        UIManager:close(self.kv)
    end

    local status_text = "Authenticated as " .. (self.instapaperManager.username or "unknown user")

    self.kv = KeyValuePage:new{
        title = _("Instapaper"),
        title_bar_left_icon = "appbar.menu",
        title_bar_left_icon_tap_callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Logout of Instapaper?"),
                ok_text = _("Logout"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    self.instapaperManager:logout()
                    self:showLoginDialog()
                end,
            })
        end,
        value_overflow_align = "right",
        kv_pairs = {
            { "Status", status_text }
        },
        callback_return = function()
            UIManager:close(self.kv)
        end,    
    }
    UIManager:show(self.kv)
end

return Instapaper
