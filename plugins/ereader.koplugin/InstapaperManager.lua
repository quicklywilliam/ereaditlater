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
local util = require("util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local socket = require("socket")

local InstapaperManager = {}
local _manager_instance = nil

function InstapaperManager:instapaperManager()
    -- Return existing instance if it exists
    if _manager_instance then
        return _manager_instance
    end
    
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    o.instapaper_api_manager = InstapaperAPIManager:instapaperAPIManager()

    o.storage = Storage:new()
    o.storage:init()
    
    -- Store the singleton instance
    _manager_instance = o
    
    return o
end




function InstapaperManager:isAuthenticated()
    return self.instapaper_api_manager:isAuthenticated()
end

function InstapaperManager:logout()
    self.instapaper_api_manager:cleanAll()
    self.storage:clearAll()
    

    
    logger.dbg("ereader: Logged out and cleared tokens")
end

function InstapaperManager:authenticate(username, password)
    if not username or not password then
        logger.err("ereader: Username and password required for authentication")
        return false
    end
    
    logger.dbg("ereader: Starting OAuth xAuth authentication for user:", username)
    
    local success, params, error_message = self.instapaper_api_manager:authenticate(username, password)
    
    if success and params then
        logger.dbg("ereader: Authentication successful")
        
        return true, nil
    else
        logger.err("ereader: Authentication failed:", error_message)
        
        return false, error_message
    end
end

function InstapaperManager:synchWithAPI()
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot sync - not authenticated")
        return false
    end
    
    logger.dbg("ereader: Syncing reads from Instapaper...")
    
    -- Process any queued offline requests first
    local queue_errors = self.instapaper_api_manager:processQueuedRequests()
    if #queue_errors > 0 then
        logger.warn("ereader: Some queued requests failed:", #queue_errors, "errors")
        for _, error_info in ipairs(queue_errors) do
            logger.warn("ereader: Queued request failed:", error_info.error)
        end
    end

    -- Now process any unsynced annotations
    -- Sync pending and pending_delete highlights with Instapaper API
    local pending_highlights = self.storage:getPendingHighlights()
    for _, highlight in ipairs(pending_highlights) do
        if highlight.sync_status == 'pending' then
            -- Add highlight to Instapaper
            local ok, highlight_id, err = self.instapaper_api_manager:addHighlight(highlight)
            if ok and highlight_id then
                self.storage:markHighlightSynced(highlight.id, highlight_id)
                logger.dbg("ereader: Synced highlight to Instapaper:", highlight.text)
            else
                logger.warn("ereader: Failed to sync highlight to Instapaper:", highlight.text, err)
            end
        elseif highlight.sync_status == 'pending_delete' and highlight.highlight_id then
            -- Delete highlight from Instapaper
            local ok, err = self.instapaper_api_manager:deleteHighlight(highlight.highlight_id)
            if ok then
                self.storage:deleteHighlightById(highlight.id)
                logger.dbg("ereader: Deleted highlight from Instapaper and local DB:", highlight.text)
            else
                logger.warn("ereader: Failed to delete highlight from Instapaper:", highlight.text, err)
            end
        end
    end
    
    local existing_bookmark_ids = self.storage:getAllUnarchivedBookmarkIds(false)
    logger.dbg("ereader: Found", #existing_bookmark_ids, "existing articles in database")
    
    -- Call API with 'have' parameter to get new articles and deleted IDs
    -- The 'have' parameter tells Instapaper which articles we already have,
    -- so it only returns new articles and a list of deleted article IDs
    local success, articles, highlights, deleted_ids, error_message = self.instapaper_api_manager:getArticles(200, existing_bookmark_ids)
    
    if success then
        local new_count = 0
        local deleted_count = 0
        
        -- Store new articles in database
        if articles then
            for _, article in ipairs(articles) do
                self.storage:storeArticleMetadata(article)
                new_count = new_count + 1
            end
        end

        -- Store new highlights in our database
        logger.dbg("ereader: highlights ", highlights)
        if highlights then
            -- Group highlights by bookmark_id since they come as a flat array
            local highlights_by_bookmark = {}
            for _, highlight in ipairs(highlights) do
                logger.dbg("ereader: highlight")

                local bookmark_id = highlight.bookmark_id
                if not highlights_by_bookmark[bookmark_id] then
                    highlights_by_bookmark[bookmark_id] = {}
                end
                table.insert(highlights_by_bookmark[bookmark_id], highlight)
            end
            
            local highlights_count = 0
            for bookmark_id, article_highlights in pairs(highlights_by_bookmark) do
                local success = self.storage:storeHighlights(bookmark_id, article_highlights)
                if success then
                    highlights_count = highlights_count + #article_highlights
                else
                    logger.warn("ereader: Failed to store highlights for bookmark_id:", bookmark_id)
                end
            end
            logger.dbg("ereader: Stored", highlights_count, "highlights from", #highlights, "articles")
        end
        
        -- Handle deleted articles - remove them from our local database
        if deleted_ids and #deleted_ids > 0 then
            for _, bookmark_id in ipairs(deleted_ids) do
                local delete_success = self.storage:deleteArticle(bookmark_id)
                if delete_success then
                    deleted_count = deleted_count + 1
                else
                    logger.warn("ereader: Failed to delete article:", bookmark_id)
                end
            end
        end
        
        logger.dbg("ereader: Successfully synced", new_count, "new articles, deleted", deleted_count, "articles")
        return true, nil
    else
        logger.err("ereader: Failed to sync reads:", error_message)
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
                    if self.storage:saveThumbnailImageToFile(image_data, bookmark_id) then
                        thumbnail_saved = true
                    end
                end
                local data_uri = self:saveImageToDataUri(image_data, content_type, src)
                if data_uri then
                    local new_attrs = img_attrs:gsub('src="([^"]+)"', string.format('src="%s"', data_uri))
                    return string.format('<img%s>', new_attrs)
                else
                    logger.warn("ereader: Failed to convert image to data URI, removing img tag:", src)
                    return ""
                end
            else
                logger.warn("ereader: Failed to download image, removing img tag:", src)
                return ""
            end
        end
        return string.format('<img%s>', img_attrs)
    end)
    return processed_html
end


function InstapaperManager:downloadImage(url, max_size)
    if not NetworkMgr:isOnline() then
        logger.warn("ereader: No network connectivity available")
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
        logger.warn("ereader: Request interrupted:", status or code)
        return nil, nil
    end
    if code >= 400 and code < 500 then
        logger.warn("ereader: HTTP error:", status or code)
        return nil, nil
    end
    if headers == nil then
        logger.warn("ereader: No HTTP headers:", status or code or "network unreachable")
        return nil, nil
    end
    if code ~= 200 then
        logger.warn("ereader: Failed to download image:", url, "HTTP code:", code)
        return nil, nil
    end
    local image_data = table.concat(response_body)
    if #image_data == 0 then
        logger.warn("ereader: Empty image data for:", url)
        return nil, nil
    end
    local size_limit = max_size or 1024 * 1024
    if #image_data > size_limit then
        logger.warn("ereader: Image too large:", url, "size:", #image_data, "limit:", size_limit)
        return nil, nil
    end
    local content_type = headers and headers["content-type"]
    if content_type and not content_type:match("^image/") then
        logger.warn("ereader: Content-Type is not an image:", content_type, "for URL:", url)
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



function InstapaperManager:addArticle(url)
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot add article - not authenticated")
        return false, "Not authenticated"
    end

    logger.dbg("ereader: Adding article:", url)
    local success, error_message, did_enqueue = self.instapaper_api_manager:addArticle(url)
    if success then
        logger.dbg("ereader: Successfully added article:", url)
        return true, nil, did_enqueue
    else
        logger.err("ereader: Failed to add article:", url)
        return false, error_message, false
    end
end

function InstapaperManager:getCachedArticleFilePath(bookmark_id)
    return self.storage:getArticleFilePathIfExists(bookmark_id)
end

function InstapaperManager:downloadArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot download article - not authenticated")
        return false, nil, "Not authenticated"
    end

    -- Find the article metadata from our database store
    local article_meta = self.storage:getArticle(bookmark_id)
    if not article_meta then
        logger.err("ereader: Article not found in database:", bookmark_id)
        return false, nil, "Article not found"
    end
    -- Download article text from API
    logger.dbg("ereader: Downloading article text for:", bookmark_id)
    local success, html_content, error_message = self.instapaper_api_manager:getArticleText(bookmark_id)
    if not success or not html_content then
        if error_message then
            logger.err("ereader: Failed to download article text:", bookmark_id, ":", error_message)
            return false, nil, error_message
        else 
            logger.err("ereader: Failed to download article text:", bookmark_id)
            return false, nil, "Failed to download article"
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
        logger.dbg("ereader: HTML already contains data URIs, skipping image processing")
    else
        -- Process images in the HTML content
        logger.dbg("ereader: Processing images in HTML content")
        html_content = self:processHtmlImages(html_content, bookmark_id)
    end
    -- Store the article
    local store_success, filepath = self.storage:storeArticle(article_meta, html_content)
    if not store_success then
        logger.err("ereader: Failed to store article:", bookmark_id)
        return false, nil, "Failed to store article"
    end
    logger.dbg("ereader: Successfully downloaded and stored article:", bookmark_id)
    return true, filepath, nil
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
        logger.err("ereader: Cannot archive article - not authenticated")
        return false
    end
    logger.dbg("ereader: Archiving article:", bookmark_id)
    local success, error_message, did_enqueue = self.instapaper_api_manager:archiveArticle(bookmark_id)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "archived", true)
        logger.dbg("ereader: Successfully archived article:", bookmark_id)
        return true, nil, did_enqueue
    else
        logger.err("ereader: Failed to archive article:", bookmark_id)
        return false, error_message, false
    end
end

function InstapaperManager:favoriteArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot favorite article - not authenticated")
        return false
    end
    logger.dbg("ereader: Favoriting article:", bookmark_id)
    local success, error_message, did_enqueue = self.instapaper_api_manager:favoriteArticle(bookmark_id)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "starred", true)
        logger.dbg("ereader: Successfully favorited article:", bookmark_id)
        return true, nil, did_enqueue
    else
        logger.err("ereader: Failed to favorite article:", bookmark_id)
        return false, error_message, false
    end
end

function InstapaperManager:unfavoriteArticle(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot unfavorite article - not authenticated")
        return false
    end
    logger.dbg("ereader: Unfavoriting article:", bookmark_id)
    local success, error_message, did_enqueue = self.instapaper_api_manager:unfavoriteArticle(bookmark_id)
    if success then
        self.storage:updateArticleStatus(bookmark_id, "starred", false)
        logger.dbg("ereader: Successfully unfavorited article:", bookmark_id)
        return true, nil, did_enqueue
    else
        logger.err("ereader: Failed to unfavorite article:", bookmark_id)
        return false, error_message, false
    end
end

function InstapaperManager:getArticleMetadata(bookmark_id)
    return self.storage:getArticle(bookmark_id)
end

function InstapaperManager:getArticleThumbnail(bookmark_id)
    return self.storage:getArticleThumbnail(bookmark_id)
end

function InstapaperManager:getArticleHighlights(bookmark_id)
    if not self:isAuthenticated() then
        logger.err("ereader: Cannot fetch highlights - not authenticated")
        return false, "Not authenticated"
    end
    
    logger.dbg("ereader: Fetching highlights for bookmark_id:", bookmark_id)
    
    local success, highlights, error_message = self.instapaper_api_manager:getHighlights(bookmark_id)
    if not success then
        logger.err("ereader: Failed to fetch highlights:", error_message)
        return false, error_message
    end
    
    -- Store highlights in database
    local store_success = self.storage:storeHighlights(bookmark_id, highlights)
    if not store_success then
        logger.warn("ereader: Failed to store highlights in database for bookmark_id:", bookmark_id)
    end
    
    logger.dbg("ereader: Successfully fetched and stored", #highlights, "highlights for bookmark_id:", bookmark_id)
    return true, nil
end

function InstapaperManager:getStoredArticleHighlights(bookmark_id)
    return self.storage:getHighlights(bookmark_id)
end

function InstapaperManager:savePendingHighlight(highlight)
    return self.storage:savePendingHighlight(highlight)
end

function InstapaperManager:deleteHighlight(highlight)
    if highlight.sync_status == 'pending' then
        -- Just delete from storage
        return self.storage:deleteHighlight(highlight.id)
    else
        -- Mark as pending_delete for future sync with Instapaper API
        return self.storage:markHighlightPendingDelete(highlight.id)
    end
end

return InstapaperManager
