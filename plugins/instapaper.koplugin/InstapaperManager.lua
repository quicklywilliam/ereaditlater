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
local util = require("util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local socket = require("socket")

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
    
    -- Clean up thumbnail files
    self:clearThumbnails()
    
    logger.dbg("instapaper: Logged out and cleared tokens")
end

function InstapaperManager:clearThumbnails()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    
    local thumbnail_dir = DataStorage:getDataDir() .. "/instapaper/thumbnails"
    
    -- Check if thumbnail directory exists
    if not lfs.attributes(thumbnail_dir, "mode") then
        logger.dbg("instapaper: No thumbnail directory to clean up")
        return
    end
    
    -- Remove all thumbnail files
    local count = 0
    for file in lfs.dir(thumbnail_dir) do
        if file ~= "." and file ~= ".." and file:match("_thumbnail%.jpg$") then
            local filepath = thumbnail_dir .. "/" .. file
            local success, err = os.remove(filepath)
            if success then
                count = count + 1
            else
                logger.warn("instapaper: Failed to remove thumbnail file:", filepath, err)
            end
        end
    end
    
    -- Try to remove the thumbnail directory itself
    lfs.rmdir(thumbnail_dir)
    
    logger.dbg("instapaper: Cleaned up", count, "thumbnail files")
end

function InstapaperManager:authenticate(username, password)
    if not username or not password then
        logger.err("instapaper: Username and password required for authentication")
        return false
    end
    
    self.username = username
    
    logger.dbg("instapaper: Starting OAuth xAuth authentication for user:", username)
    
    local success, params, error_message = self.instapaper_api_manager:authenticate(username, password)
    
    if success and params then
        logger.dbg("instapaper: Authentication successful")
        self.token = params.oauth_token
        self.token_secret = params.oauth_token_secret
        self.is_authenticated = true
        
        self:saveTokens(self.token, self.token_secret)
        self:saveUsername(username)
        
        return true, nil
    else
        logger.err("instapaper: Authentication failed:", error_message)
        self.is_authenticated = false
        
        return false, error_message
    end
end

function InstapaperManager:syncReads()
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot sync reads - not authenticated")
        return false
    end
    
    logger.dbg("instapaper: Syncing reads from Instapaper...")
    
    local success, articles, error_message = self.instapaper_api_manager:getArticles(self.token, self.token_secret)
    
    if success and articles then
        -- Store articles in database
        for _, article in ipairs(articles) do
            self.storage:storeArticleMetadata(article)
        end
        logger.dbg("instapaper: Successfully synced", #articles, "articles to database")
        return true, nil
    else
        logger.err("instapaper: Failed to sync reads")
        return false, error_message
    end
end

function InstapaperManager:getArticles()
    return self.storage:getArticles()
end

function InstapaperManager:getLastSyncTime()
    return self.storage:getLastSyncTime()
end

function InstapaperManager:processHtmlImages(html_content, bookmark_id)
    local external_images = {}
    html_content:gsub('<img([^>]+)>', function(img_attrs)
        local src = img_attrs:match('src="([^"]+)"')
        if src and (src:sub(1, 7) == "http://" or src:sub(1, 8) == "https://") then
            table.insert(external_images, src)
        end
    end)
    
    if #external_images == 0 then
        return html_content
    end
    
    local thumbnail_saved = false
    
    local processed_html = html_content:gsub('<img([^>]+)>', function(img_attrs)
        local src = img_attrs:match('src="([^"]+)"')
        if not src then return string.format('<img%s>', img_attrs) end
        if src:sub(1, 5) == "data:" or src:sub(1, 1) == "/" or src:sub(1, 1) == "." then
            return string.format('<img%s>', img_attrs)
        end
        if src:sub(1, 7) == "http://" or src:sub(1, 8) == "https://" then
            local image_data, content_type = self:downloadImageWithFallback(src, 1024 * 1024)
            if image_data then
                if not thumbnail_saved then
                    if self:saveThumbnailImageToFile(image_data, bookmark_id) then
                        thumbnail_saved = true
                    end
                end
                local data_uri = self:saveImageToDataUri(image_data, content_type, src)
                if data_uri then
                    local new_attrs = img_attrs:gsub('src="([^"]+)"', string.format('src="%s"', data_uri))
                    return string.format('<img%s>', new_attrs)
                else
                    logger.warn("instapaper: Failed to convert image to data URI, removing img tag:", src)
                    return ""
                end
            else
                logger.warn("instapaper: Failed to download image, removing img tag:", src)
                return ""
            end
        end
        return string.format('<img%s>', img_attrs)
    end)
    return processed_html
end


function InstapaperManager:downloadImage(url, max_size)
    if not NetworkMgr:isOnline() then
        logger.warn("instapaper: No network connectivity available")
        return nil, nil
    end
    
    local response_body = {}
    socketutil:set_timeout(10, 30)
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        headers = { ["User-Agent"] = "KOReader/1.0" }
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("instapaper: Request interrupted:", status or code)
        return nil, nil
    end
    if code >= 400 and code < 500 then
        logger.warn("instapaper: HTTP error:", status or code)
        return nil, nil
    end
    if headers == nil then
        logger.warn("instapaper: No HTTP headers:", status or code or "network unreachable")
        return nil, nil
    end
    if code ~= 200 then
        logger.warn("instapaper: Failed to download image:", url, "HTTP code:", code)
        return nil, nil
    end
    local image_data = table.concat(response_body)
    if #image_data == 0 then
        logger.warn("instapaper: Empty image data for:", url)
        return nil, nil
    end
    local size_limit = max_size or 1024 * 1024
    if #image_data > size_limit then
        logger.warn("instapaper: Image too large:", url, "size:", #image_data, "limit:", size_limit)
        return nil, nil
    end
    local content_type = headers and headers["content-type"]
    if content_type and not content_type:match("^image/") then
        logger.warn("instapaper: Content-Type is not an image:", content_type, "for URL:", url)
        return nil, nil
    end
    return image_data, content_type
end

function InstapaperManager:downloadImageWithFallback(url, max_size)
    local image_data, content_type = self:downloadImage(url, max_size)
    if image_data then return image_data, content_type end
    if url:sub(1, 8) == "https://" then
        local http_url = "http://" .. url:sub(9)
        return self:downloadImage(http_url, max_size)
    end
    return nil, nil
end

function InstapaperManager:saveImageToDataUri(image_data, content_type, url)
    local mime = require("mime")
    local mime_type = "image/jpeg"
    if content_type then
        mime_type = content_type:match("^([^;]+)")
    else
        local ext = url:match("%.([^%.?]+)")
        if ext then
            ext = ext:lower()
            if ext == "png" then mime_type = "image/png"
            elseif ext == "gif" then mime_type = "image/gif"
            elseif ext == "webp" then mime_type = "image/webp"
            elseif ext == "svg" then mime_type = "image/svg+xml"
            end
        end
    end
    local base64_data = mime.b64(image_data)
    return string.format("data:%s;base64,%s", mime_type, base64_data)
end

function InstapaperManager:saveThumbnailImageToFile(image_data, bookmark_id)
    local RenderImage = require("ui/renderimage")
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    
    local image_bb = RenderImage:renderImageData(image_data, #image_data)
    if not image_bb then
        logger.warn("instapaper: Failed to render image")
        return false
    end
    
    -- Crop
    local orig_w, orig_h = image_bb:getWidth(), image_bb:getHeight()
    local crop_size = math.min(orig_w, orig_h)
    local crop_x = math.floor((orig_w - crop_size) / 2)
    local crop_y = math.floor((orig_h - crop_size) / 2)
    
    local cropped_bb = image_bb:viewport(crop_x, crop_y, crop_size, crop_size)
    
    -- Scale
    local thumbnail_bb = RenderImage:scaleBlitBuffer(cropped_bb, 90, 90)
    
    -- Save
    local thumbnail_dir = DataStorage:getDataDir() .. "/instapaper/thumbnails"
    if not lfs.attributes(thumbnail_dir, "mode") then 
        lfs.mkdir(thumbnail_dir)
    end
    local thumbnail_filename = string.format("%s/%s_thumbnail.jpg", thumbnail_dir, bookmark_id)

    local save_success, err = thumbnail_bb:writeToFile(thumbnail_filename, "jpg", 85)
    
    image_bb:free()
    cropped_bb:free()
    thumbnail_bb:free()
        
    if save_success then
        logger.dbg("instapaper: Saved thumbnail:", thumbnail_filename)
        return true
    else
        logger.warn("instapaper: Failed to save thumbnail:", thumbnail_filename, "Error:", err)
        return false
    end
end

function InstapaperManager:addArticle(url)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot add article - not authenticated")
        return false, "Not authenticated"
    end

    logger.dbg("instapaper: Adding article:", url)
    local success, error_message = self.instapaper_api_manager:addArticle(url, self.token, self.token_secret)
    if success then
        logger.dbg("instapaper: Successfully added article:", url)
        return true, nil
    else
        logger.err("instapaper: Failed to add article:", url)
        return false, error_message
    end
end

function InstapaperManager:downloadArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot download article - not authenticated")
        return false, "Not authenticated"
    end
    -- Check if we already have this article
    local existing = self.storage:getArticle(bookmark_id)
    if existing then
        -- Load the HTML content from file
        local html_content = self.storage:getArticleHTML(existing.html_filename)
        if html_content and #html_content > 0 then
            -- Add HTML content to the existing article data
            existing.html = html_content
            logger.dbg("instapaper: Article already downloaded:", bookmark_id)
            return true, existing
        else
            logger.dbg("instapaper: Article exists but has no HTML content, will download")
        end
    end
    -- Find the article metadata from our database store
    local article_meta = self.storage:getArticle(bookmark_id)
    if not article_meta then
        logger.err("instapaper: Article not found in database:", bookmark_id)
        return false, "Article not found"
    end
    -- Download article text from API
    logger.dbg("instapaper: Downloading article text for:", bookmark_id)
    local success, html_content, error_message = self.instapaper_api_manager:getArticleText(bookmark_id, self.token, self.token_secret)
    if not success or not html_content then
        if error_message then
            logger.err("instapaper: Failed to download article text:", bookmark_id, ":", error_message)
            return false, error_message
        else 
            logger.err("instapaper: Failed to download article text:", bookmark_id)
            return false, "Failed to download article"
        end
    end
    -- If the HTML does not contain a <body> tag, wrap it
    if not html_content:find("<body", 1, true) then
        html_content = "<html><body>" .. html_content .. "</body></html>"
    end
    -- Prepend header to HTML (inside body)
    local header_html = InstapaperManager.makeHtmlHeader(article_meta.title, article_meta.url)
    html_content = html_content:gsub("(<body[^>]*>)", "%1" .. header_html, 1)
    -- Check if HTML already contains data URIs (images already processed)
    local has_data_uris = html_content:find("data:image/")
    if has_data_uris then
        logger.dbg("instapaper: HTML already contains data URIs, skipping image processing")
    else
        -- Process images in the HTML content
        logger.dbg("instapaper: Processing images in HTML content")
        html_content = self:processHtmlImages(html_content, bookmark_id)
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

function InstapaperManager.getDomain(url)
    if not url or url == "" then return "" end
    local domain = url:match("://([^/]+)")
    if domain then
        return domain
    else
        return url
    end
end

local function escapeHtml(str)
    if not str then return "" end
    return (str:gsub("[&<>\"]", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
    }))
end

function InstapaperManager.makeHtmlHeader(title, url)
    local domain = InstapaperManager.getDomain(url)
    return string.format([[<div style="margin-bottom:2em"><h1 style="font-size:1.5em;font-weight:bold;margin-bottom:0.2em;">%s</h1><div style="font-size:0.8em;color:#444;font-family:sans-serif;">%s</div></div>]],
        escapeHtml(title or "Untitled"), escapeHtml(domain or ""))
end

function InstapaperManager:archiveArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot archive article - not authenticated")
        return false
    end
    logger.dbg("instapaper: Archiving article:", bookmark_id)
    local success, error_message = self.instapaper_api_manager:archiveArticle(bookmark_id, self.token, self.token_secret)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "archived", true)
        logger.dbg("instapaper: Successfully archived article:", bookmark_id)
        return true, nil
    else
        logger.err("instapaper: Failed to archive article:", bookmark_id)
        return false, error_message
    end
end

function InstapaperManager:favoriteArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot favorite article - not authenticated")
        return false
    end
    logger.dbg("instapaper: Favoriting article:", bookmark_id)
    local success, error_message = self.instapaper_api_manager:favoriteArticle(bookmark_id, self.token, self.token_secret)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "starred", true)
        logger.dbg("instapaper: Successfully favorited article:", bookmark_id)
        return true, nil
    else
        logger.err("instapaper: Failed to favorite article:", bookmark_id)
        return false, error_message
    end
end

function InstapaperManager:unfavoriteArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("instapaper: Cannot unfavorite article - not authenticated")
        return false
    end
    logger.dbg("instapaper: Unfavoriting article:", bookmark_id)
    local success, error_message = self.instapaper_api_manager:unfavoriteArticle(bookmark_id, self.token, self.token_secret)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "starred", false)
        logger.dbg("instapaper: Successfully unfavorited article:", bookmark_id)
        return true, nil
    else
        logger.err("instapaper: Failed to unfavorite article:", bookmark_id)
        return false, error_message
    end
end

function InstapaperManager:getArticleMetadata(bookmark_id)
    return self.storage:getArticle(bookmark_id)
end

function InstapaperManager:getArticleThumbnail(bookmark_id)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    
    -- Generate thumbnail filename
    local thumbnail_filename = string.format("%s/instapaper/thumbnails/%s_thumbnail.jpg", 
        DataStorage:getDataDir(), bookmark_id)
    
    -- Check if thumbnail file exists
    if lfs.attributes(thumbnail_filename, "mode") then
        return thumbnail_filename
    else
        return nil
    end
end

return InstapaperManager
