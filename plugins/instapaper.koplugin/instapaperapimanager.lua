local _ = require("gettext")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local KeyValuePage = require("ui/widget/keyvaluepage")
local InstapaperAuthenticator = require("lib/instapaperAuthenticator")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local InstapaperAPIManager = {}

function InstapaperAPIManager:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    -- Initialize with stored tokens and username
    o.token, o.token_secret = o:loadTokens()
    o.username = o:loadUsername()
    o.is_authenticated = o:isAuthenticated()
    
    if o.is_authenticated then
        logger.dbg("instapaper: Loaded stored tokens, authenticated as", o.username or "unknown user")
    else
        logger.dbg("instapaper: No stored tokens found, not authenticated")
    end
    
    return o
end


-- Plugin-specific settings storage
local function getSettings()
    local settings = LuaSettings:open(DataStorage:getSettingsDir().."/instapaper.lua")
    settings:readSetting("instapaper", {})
    return settings
end

-- Generic settings methods
function InstapaperAPIManager:getSetting(key, default)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    return data[key] ~= nil and data[key] or default
end

function InstapaperAPIManager:setSetting(key, value)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    data[key] = value
    settings:saveSetting("instapaper", data)
    settings:flush()
end

function InstapaperAPIManager:delSetting(key)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    data[key] = nil
    settings:saveSetting("instapaper", data)
    settings:flush()
end

-- Token-specific methods (using the generic methods)
function InstapaperAPIManager:loadTokens()
    return self:getSetting("oauth_token"), self:getSetting("oauth_token_secret")
end

function InstapaperAPIManager:loadUsername()
    return self:getSetting("username")
end

function InstapaperAPIManager:saveTokens(oauth_token, oauth_token_secret)
    self:setSetting("oauth_token", oauth_token)
    self:setSetting("oauth_token_secret", oauth_token_secret)
end

function InstapaperAPIManager:saveUsername(username)
    self:setSetting("username", username)
end

function InstapaperAPIManager:clearTokens()
    self:delSetting("oauth_token")
    self:delSetting("oauth_token_secret")
    self:delSetting("username")
end

-- Load API keys from file
local function loadApiKeys()
    local secrets_path = "plugins/instapaper.koplugin/secrets.txt"
    local file = io.open(secrets_path, "r")
    if not file then
        logger.err("instapaper: Could not open secrets.txt")
        return nil, nil, nil, nil
    end
    
    local content = file:read("*all")
    file:close()
    
    local consumer_key = ""
    local consumer_secret = ""
    
    -- Parse the content looking for all keys
    for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
        if key == "instapaper_ouath_consumer_key" then
            consumer_key = value
        elseif key == "instapaper_oauth_consumer_secret" then
            consumer_secret = value
        end
    end
    
    if consumer_key == "" or consumer_secret == "" then
        logger.err("instapaper: Could not find both consumer_key and consumer_secret in secrets.txt")
        return nil, nil
    end
    
    return consumer_key, consumer_secret
end

function InstapaperAPIManager:isAuthenticated()
    local oauth_token, oauth_token_secret = self:loadTokens()
    return oauth_token ~= nil and oauth_token_secret ~= nil
end

function InstapaperAPIManager:logout()
    self:clearTokens()
    self.token = nil
    self.token_secret = nil
    self.is_authenticated = false
    self.username = nil
    logger.dbg("instapaper: Logged out and cleared tokens")
end

function InstapaperAPIManager:authenticate(username, password)
    if not username or not password then
        logger.err("instapaper: Username and password required for authentication")
        return false
    end
    
    self.username = username
    
    -- Load API keys
    local consumer_key, consumer_secret = loadApiKeys()
    if not consumer_key or not consumer_secret then
        logger.err("instapaper: Failed to load API keys")

        return false
    end
    
    logger.dbg("instapaper: Starting OAuth xAuth authentication for user:", username)
    
    local instapaper = InstapaperAuthenticator:new(consumer_key, consumer_secret)
    local success, params = instapaper:authenticate(username, password)
    
    if success and params then
        logger.dbg("instapaper: Authentication successful")
        self.token = params.oauth_token
        self.token_secret = params.oauth_token_secret
        self.is_authenticated = true
        
        self:saveTokens(self.token, self.token_secret)
        self:saveUsername(username)
        
        return true
    else
        logger.err("instapaper: Authentication failed")
        self.is_authenticated = false
        
        return false
    end
end

return InstapaperAPIManager
