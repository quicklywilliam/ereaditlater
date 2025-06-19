local _ = require("gettext")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")
local KeyValuePage = require("ui/widget/keyvaluepage")
local InstapaperAPIManager = require("lib/instapaperapimanager")
local Storage = require("lib/storage")
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
    
    if o.is_authenticated then
        logger.dbg("instapaper: Loaded stored tokens")
    else
        logger.dbg("instapaper: No stored tokens found, not authenticated")
    end

    self.storage = Storage:new()
    self.storage:init()
    
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
    -- Clear database storage
    self.storage:clearAll()
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
        -- Store articles in database
        for _, article in ipairs(articles) do
            self.storage:storeArticleMetadata(article)
        end
        logger.dbg("instapaper: Successfully synced", #articles, "articles to database")
        return true
    else
        logger.err("instapaper: Failed to sync reads")
        return false
    end
end

function InstapaperManager:getArticles()
    return self.storage:getArticles()
end

function InstapaperManager:getLastSyncTime()
    return self.storage:getLastSyncTime()
end

function InstapaperManager:downloadArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot download article - not authenticated")
        return false, "Not authenticated"
    end
    
    -- Check if we already have this article
    local existing = self.storage:getArticle(bookmark_id)
    if existing and existing.html then
        logger.dbg("instapaper: Article already downloaded:", bookmark_id)
        return true, existing
    end
    
    -- Find the article metadata from our database store
    local article_meta = self.storage:getArticle(bookmark_id)
    
    if not article_meta then
        logger.err("instapaper: Article not found in database:", bookmark_id)
        return false, "Article not found"
    end
    
    -- Download article text from API
    logger.dbg("instapaper: Downloading article text for:", bookmark_id)
    local success, html_content = self.instapaper_api_manager:getArticleText(bookmark_id, self.token, self.token_secret)
    
    if not success or not html_content then
        logger.err("instapaper: Failed to download article text:", bookmark_id)
        return false, "Failed to download article"
    end
    
    -- Store the article
    local store_success, filename = self.storage:storeArticle(article_meta, html_content)
    if not store_success then
        logger.err("instapaper: Failed to store article:", bookmark_id)
        return false, "Failed to store article"
    end
    
    logger.dbg("instapaper: Successfully downloaded and stored article:", bookmark_id)
    
    -- Return the stored article
    local stored_article = self.storage:getArticle(bookmark_id)
    return true, stored_article
end

return InstapaperManager
