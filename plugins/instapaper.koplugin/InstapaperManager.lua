local _ = require("gettext")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local KeyValuePage = require("ui/widget/keyvaluepage")
local InstapaperAPIManager = require("lib/instapaperapimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local InstapaperManager = {}

function InstapaperManager:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    self.instapaper_api_manager = InstapaperAPIManager:new()
    
    -- Initialize with stored tokens and username
    o.token, o.token_secret = o:loadTokens()
    o.username = o:loadUsername()
    o.is_authenticated = o:isAuthenticated()
    
    -- In-memory data store for articles
    o.articles = {}
    o.last_sync_time = nil
    
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
function InstapaperManager:getSetting(key, default)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    return data[key] ~= nil and data[key] or default
end

function InstapaperManager:setSetting(key, value)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    data[key] = value
    settings:saveSetting("instapaper", data)
    settings:flush()
end

function InstapaperManager:delSetting(key)
    local settings = getSettings()
    local data = settings.data.instapaper or {}
    data[key] = nil
    settings:saveSetting("instapaper", data)
    settings:flush()
end

-- Token-specific methods (using the generic methods)
function InstapaperManager:loadTokens()
    return self:getSetting("oauth_token"), self:getSetting("oauth_token_secret")
end

function InstapaperManager:loadUsername()
    return self:getSetting("username")
end

function InstapaperManager:saveTokens(oauth_token, oauth_token_secret)
    self:setSetting("oauth_token", oauth_token)
    self:setSetting("oauth_token_secret", oauth_token_secret)
end

function InstapaperManager:saveUsername(username)
    self:setSetting("username", username)
end

function InstapaperManager:clearTokens()
    self:delSetting("oauth_token")
    self:delSetting("oauth_token_secret")
    self:delSetting("username")
end

function InstapaperManager:isAuthenticated()
    local oauth_token, oauth_token_secret = self:loadTokens()
    return oauth_token ~= nil and oauth_token_secret ~= nil
end

function InstapaperManager:logout()
    self:clearTokens()
    self.token = nil
    self.token_secret = nil
    self.is_authenticated = false
    self.username = nil
    -- Clear in-memory data store
    self.articles = {}
    self.last_sync_time = nil
    logger.dbg("instapaper: Logged out and cleared tokens")
end

function InstapaperManager:authenticate(username, password)
    if not username or not password then
        logger.err("instapaper: Username and password required for authentication")
        return false
    end
    
    self.username = username
    
    logger.dbg("instapaper: Starting OAuth xAuth authentication for user:", username)
    
    local success, params = self.instapaper_api_manager:authenticate(username, password)
    
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

function InstapaperManager:syncReads()
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot sync reads - not authenticated")
        return false
    end
    
    logger.dbg("instapaper: Syncing reads from Instapaper...")
    
    local success, articles = self.instapaper_api_manager:getArticles(self.token, self.token_secret)
    
    if success and articles then
        self.articles = articles
        self.last_sync_time = os.time()
        logger.dbg("instapaper: Successfully synced", #articles, "articles")
        return true
    else
        logger.err("instapaper: Failed to sync reads")
        return false
    end
end

function InstapaperManager:getArticles()
    return self.articles
end

function InstapaperManager:getLastSyncTime()
    return self.last_sync_time
end

return InstapaperManager
