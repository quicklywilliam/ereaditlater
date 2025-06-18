local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Instapaper = require("lib/instapaper")

local InstapaperManager = {}

function InstapaperManager:new()
    local manager = {}
    
    manager.is_authenticated = false
    manager.username = nil
    manager.token = nil
    manager.token_secret = nil
    manager.instapaper = nil
    manager.consumer_key = ""
    manager.consumer_secret = ""
    
    manager.kv = nil
    
    -- Read API keys from file
    local api_keys_path = "plugins/instapaper.koplugin/api_keys.txt"
    local file = io.open(api_keys_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        
        -- Parse the content looking for consumer_key and consumer_secret
        for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
            if key == "instapaper_ouath_consumer_key" then
                manager.consumer_key = value
            elseif key == "instapaper_oauth_consumer_secret" then
                manager.consumer_secret = value
            elseif key == "instapaper_username" then
                manager.username = value
            elseif key == "instapaper_password" then
                manager.password = value
            end
        end
        
        if manager.consumer_key == "" or manager.consumer_secret == "" then
            logger.warn("instapaper: Could not find both consumer_key and consumer_secret in api_keys.txt")
        end
    else
        logger.warn("instapaper: Could not open api_keys.txt")
    end
    
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
                text = self.username,
                hint = "Email",
            },
            {
                name = "password",
                text = self.password,
                hint = "Password",
                text_type = "password",
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
                    
                    self.username = fields[1]
                    self.password = fields[2]
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
    NetworkMgr:runWhenOnline(function()
        self.instapaper = Instapaper:new(self.consumer_key, self.consumer_secret)
        
        local request = self.instapaper:getAccessToken(self.username, self.password)
        
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        
        local sink = {}
        socketutil:set_timeout(10, 30)
        local http_request = {
            url = request.url,
            method = request.method,
            headers = request.headers,
            sink = ltn12.sink.table(sink),
            source = request.body and ltn12.source.string(request.body) or nil
        }
        
        local code, headers, status = socket.skip(1, http.request(http_request))
        socketutil:reset_timeout()
        
        if code == 200 then
            local body = table.concat(sink)
            -- Parse the response which contains the access token and secret
            local params = {}
            for k, v in string.gmatch(body, "([^&=]+)=([^&=]+)") do
                params[k] = v
            end
            
            self.is_authenticated = true
            self.token = params.oauth_token
            self.token_secret = params.oauth_token_secret
            
            UIManager:show(ConfirmBox:new{
                text = "Successfully logged in to Instapaper!",
                no_ok_button = true,
                cancel_text = "Got it",
                cancel_callback = function()
                    UIManager:close(self.login_dialog)
                end
            })
        else
            local body = table.concat(sink)
            
            UIManager:show(ConfirmBox:new{
                text = "Login failed: " .. (body or "Unknown error") .. "\n Code: " .. code,
                no_ok_button = true,
                cancel_text = "Got it",
                cancel_callback = function()
                    UIManager:close(self.login_dialog)
                end
            })
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
        kv_pairs = {
            { "Status", self.is_authenticated and "Authenticated" or "Not authenticated" },
            { "Consumer Key", self.consumer_key },
            { "Consumer Secret", self.consumer_secret },
            { "Access Token", self.token or "None" },
            { "Token Secret", self.token_secret or "None" }
        },
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
