local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")

local InstapaperManager = {}

function InstapaperManager:new()
    local manager = {}
    
    manager.is_authenticated = false
    manager.username = nil
    manager.token = nil
    manager.token_secret = nil
    
    setmetatable(manager, self)
    self.__index = self
    
    return manager
end

function InstapaperManager:showLoginDialog()
    logger.info("Show Instapaper login dialog...")

    self.login_dialog = MultiInputDialog:new {
        title = "Instapaper Login",
        fields = {
            {
                name = "username",
                text = "",
                hint = "Email",
            },
            {
                name = "password",
                text = "",
                hint = "Password",
                is_password = true,
            },
        },
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end
                },
                {
                    text = "Login",
                    callback = function()
                        local myfields = self.login_dialog:getFields()
                        self.username      = myfields[1]
                        self.password      = myfields[2]
                        self:login()
                    end
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function InstapaperManager:login()
    -- TODO: Implement actual login logic using OAuth 1.0a
    NetworkMgr:runWhenOnline(function()
        -- This is where we would implement the OAuth flow
        logger.info("Attempting to login to Instapaper...")
        
        -- For now, just simulate a successful login
        self.is_authenticated = true
        self.username = self.username
        
        -- Return a success message dialog
        UIManager:show(ConfirmBox:new{
            text = "Successfully logged in to Instapaper!",
            no_ok_button = true,
            cancel_text = "Got it",
            cancel_callback = function()
                UIManager:close(self.login_dialog)
            end
        })
    end)
end

function InstapaperManager:showArticles()
    -- TODO: Implement article listing UI
    if not self.is_authenticated then
        return self:showLoginDialog()
    end
    
    -- Return a placeholder dialog for now
    return InputDialog:new{
        title = "Instapaper Articles",
        fields = {
            {
                name = "status",
                text = "Not implemented yet",
            },
        },
        buttons = {
            {
                text = "OK",
                callback = function(dialog)
                    UIManager:close(dialog)
                end,
            },
        },
    }
end

return InstapaperManager
