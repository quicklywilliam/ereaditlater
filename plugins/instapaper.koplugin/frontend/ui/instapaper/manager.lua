local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local KeyValuePage = require("ui/widget/keyvaluepage")
local InstapaperOAuth = require("lib/oauth")
local InstapaperManager = {}

function InstapaperManager:new()
    local manager = {}
    
    manager.is_authenticated = false
    manager.username = nil
    manager.token = nil
    manager.token_secret = nil
    manager.oauth = nil

    manager.consumer_key = ""
    manager.consumer_secret = ""
    
    setmetatable(manager, self)
    self.__index = self
    
    return manager
end

function InstapaperManager:showLoginDialog()
    self.login_dialog = MultiInputDialog:new{
        title = "Login",
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
                        local fields = self.login_dialog:getFields()
                        self.username = fields.username
                        self.password = fields.password
                        self:login()
                    end
                },
            },
        }
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function InstapaperManager:login()
    if not self.consumer_key or not self.consumer_secret then
        UIManager:show(ConfirmBox:new{
            text = "Please enter your Consumer Key and Secret",
            no_ok_button = true,
            cancel_text = "Got it",
            cancel_callback = function()
                UIManager:close(self.login_dialog)
            end
        })
        return
    end

    end)
end

function InstapaperManager:showArticles()
    local UI = require("ui/trapper")

    if self.kv then
        UIManager:close(self.kv)
    end

    self.kv = KeyValuePage:new{
        title = _("Instapaper"),
        value_overflow_align = "right",
        kv_pairs = view_content,
        callback_return = function()
            UIManager:close(self.kv)
        end
    }
    UIManager:show(self.kv)

    if not self.is_authenticated then
        return self:showLoginDialog()
    end
end

return InstapaperManager
