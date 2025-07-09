local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")

local Storage = {}

-- Database schema version
local DB_SCHEMA_VERSION = 4

-- Database schema for Instapaper articles
local INSTAPAPER_DB_SCHEMA = [[
    -- Articles table - stores metadata and sync information
    CREATE TABLE IF NOT EXISTS articles (
        id                  INTEGER PRIMARY KEY,
        bookmark_id         INTEGER UNIQUE NOT NULL,  -- Instapaper's bookmark ID
        title              TEXT NOT NULL,
        url                TEXT NOT NULL,
        html_filename      TEXT NOT NULL,            -- Local HTML file name
        html_size          INTEGER DEFAULT 0,        -- Size of HTML file in bytes
        progress           REAL DEFAULT 0.0,         -- Reading progress (0.0 to 1.0)
        starred            INTEGER DEFAULT 0,        -- 0 = false, 1 = true
        is_archived        INTEGER DEFAULT 0,        -- 0 = false, 1 = true
        time_added         INTEGER NOT NULL,         -- Unix timestamp when added to Instapaper
        time_updated       INTEGER NOT NULL,         -- Unix timestamp when last updated
        time_synced        INTEGER DEFAULT 0,        -- Unix timestamp when last synced
        sync_status        TEXT DEFAULT 'pending',   -- 'pending', 'synced', 'error'
        error_message      TEXT,                     -- Error message if sync failed
        word_count         INTEGER DEFAULT 0,        -- Estimated word count
        reading_time       INTEGER DEFAULT 0         -- Estimated reading time in minutes
    );
    
    -- Create indexes for better performance
    CREATE INDEX IF NOT EXISTS idx_articles_bookmark_id ON articles(bookmark_id);
    CREATE INDEX IF NOT EXISTS idx_articles_sync_status ON articles(sync_status);
    CREATE INDEX IF NOT EXISTS idx_articles_time_added ON articles(time_added);
    CREATE INDEX IF NOT EXISTS idx_articles_progress ON articles(progress);
    
    -- Highlights table - stores highlights from Instapaper articles
    CREATE TABLE IF NOT EXISTS highlights (
        id                  INTEGER PRIMARY KEY,
        bookmark_id         INTEGER NOT NULL,        -- Instapaper's bookmark ID
        highlight_id        INTEGER,                 -- Instapaper's highlight ID (Can be NULL for pending uploads)
        text                TEXT NOT NULL,           -- Highlighted text
        note                TEXT,                    -- User's note (can be NULL)
        position            INTEGER DEFAULT 0,       -- Text position in the article
        time_created        INTEGER NOT NULL,        -- Unix timestamp when created
        time_updated        INTEGER NOT NULL,        -- Unix timestamp when last updated
        sync_status         TEXT DEFAULT 'synced',   -- 'synced', 'pending', 'pending_delete', 'error'
        UNIQUE(bookmark_id, highlight_id)
    );
    
    -- Create indexes for highlights table
    CREATE INDEX IF NOT EXISTS idx_highlights_bookmark_id ON highlights(bookmark_id);
    CREATE INDEX IF NOT EXISTS idx_highlights_highlight_id ON highlights(highlight_id);
    CREATE INDEX IF NOT EXISTS idx_highlights_sync_status ON highlights(sync_status);
]]

function Storage:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    o.base_dir = DataStorage:getSettingsDir() .. "/ereader"
    o.db_location = o.base_dir .. "/instapaper.sqlite"
    o.instapaper_dir = o.base_dir .. "/instapaper"
    o.thumbnail_dir = o.instapaper_dir .. "/thumbnails"
    o.db_conn = nil
    o.initialized = false
    
    return o
end

function Storage:init()
    if self.initialized then
        return
    end
    
    logger.dbg("ereader: Initializing storage at", self.db_location)
    
    -- Ensure base directory exists before creating articles directory
    if not lfs.attributes(self.base_dir, "mode") then
        lfs.mkdir(self.base_dir)
        logger.dbg("ereader: Created base directory:", self.base_dir)
    end
    -- Create articles directory if it doesn't exist
    if not lfs.attributes(self.instapaper_dir, "mode") then
        lfs.mkdir(self.instapaper_dir)
        logger.dbg("ereader: Created articles directory:", self.instapaper_dir)
    end

    -- Create thumnails directory if needed
    if not lfs.attributes(self.thumbnail_dir, "mode") then 
        lfs.mkdir(self.thumbnail_dir)
        logger.dbg("ereader: Created thumbnails directory:", self.thumbnail_dir)
    end
    
    -- Initialize database
    self:createDB()
    self.initialized = true
end

function Storage:createDB()
    local db_exists = lfs.attributes(self.db_location, "mode") ~= nil
    
    if db_exists then
        -- Try to open existing database and check version
        local db_conn = SQ3.open(self.db_location)
        
        -- Make it WAL if possible for better concurrency
        if Device:canUseWAL() then
            db_conn:exec("PRAGMA journal_mode=WAL;")
        else
            db_conn:exec("PRAGMA journal_mode=TRUNCATE;")
        end
        
        -- Check version and upgrade if needed
        local db_version = tonumber(db_conn:rowexec("PRAGMA user_version;")) or 0
        if db_version < DB_SCHEMA_VERSION then
            logger.info("Instapaper: Upgrading database schema from version", db_version, "to", DB_SCHEMA_VERSION)
            
            -- Close the connection and delete the old database
            db_conn:close()
            os.remove(self.db_location)
            
            -- Reopen and create new database with updated schema
            db_conn = SQ3.open(self.db_location)
            if Device:canUseWAL() then
                db_conn:exec("PRAGMA journal_mode=WAL;")
            else
                db_conn:exec("PRAGMA journal_mode=TRUNCATE;")
            end
            
            -- Create schema
            db_conn:exec(INSTAPAPER_DB_SCHEMA)
            
            -- Set the new version
            db_conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
            
            logger.dbg("ereader: Database upgraded and recreated")
        else
            -- Schema is up to date, just close and return
            db_conn:close()
            logger.dbg("ereader: Database schema is up to date")
            return
        end
        
        db_conn:close()
    else
        -- Database doesn't exist, create new one
        logger.dbg("ereader: Creating new database")
        local db_conn = SQ3.open(self.db_location)
        
        -- Make it WAL if possible for better concurrency
        if Device:canUseWAL() then
            db_conn:exec("PRAGMA journal_mode=WAL;")
        else
            db_conn:exec("PRAGMA journal_mode=TRUNCATE;")
        end
        
        -- Create schema
        db_conn:exec(INSTAPAPER_DB_SCHEMA)
        
        -- Set the version
        db_conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
        
        db_conn:close()
        logger.dbg("ereader: New database created")
    end
    
    logger.dbg("ereader: Database initialized at", self.db_location)
end

function Storage:openDB()
    if not self.db_conn then
        self.db_conn = SQ3.open(self.db_location)
        self.db_conn:set_busy_timeout(5000) -- 5 seconds timeout
    end
end

function Storage:closeDB()
    if self.db_conn then
        self.db_conn:close()
        self.db_conn = nil
    end
end

-- Generate a safe filename from title and ID
function Storage:generateFilename(bookmark_id)
    return string.format("%d.html", bookmark_id)
end

-- Store an article's HTML content and metadata
function Storage:storeArticle(article_data, html_content)
    self:openDB()
    local filename = self:generateFilename(article_data.bookmark_id)
    local filepath = self.instapaper_dir .. "/" .. filename

    -- Write HTML file
    local file = io.open(filepath, "w")
    if not file then
        logger.err("ereader: Failed to create HTML file:", filepath)
        self:closeDB()
        return false, "Failed to create HTML file"
    end
    file:write(html_content)
    file:close()
    local file_size = lfs.attributes(filepath, "size") or 0

    -- Check if article exists
    local existing = self:getArticle(article_data.bookmark_id)
    self:openDB() -- re-open after getArticle

    if existing then
        -- Get schema fields from the database
        local schema_fields = {}
        do
            local stmt = self.db_conn:prepare("PRAGMA table_info(articles)")
            local row = stmt:step()
            while row do
                schema_fields[row[2]] = true
                row = stmt:step()
            end
        end

        -- Build dynamic UPDATE statement
        local fields, values = {}, {}
        for k, v in pairs(article_data) do
            if k ~= "bookmark_id" and schema_fields[k] then
                local t = type(v)
                if t == "boolean" then
                    v = v and 1 or 0
                elseif t ~= "string" and t ~= "number" then
                    logger.err("ereader: Skipping field " .. k .. " of unsupported type: " .. t)
                    goto continue
                end
                table.insert(fields, k .. " = ?")
                table.insert(values, v)
                ::continue::
            end
        end
        -- Always update html_filename and html_size
        table.insert(fields, "html_filename = ?")
        table.insert(values, filename)
        table.insert(fields, "html_size = ?")
        table.insert(values, file_size)
        -- Always update time_updated
        table.insert(fields, "time_updated = ?")
        table.insert(values, os.time())

        local sql = "UPDATE articles SET " .. table.concat(fields, ", ") .. " WHERE bookmark_id = ?"
        table.insert(values, article_data.bookmark_id)

        local stmt = self.db_conn:prepare(sql)
        local ok, err = pcall(function()
            stmt:reset():bind(table.unpack(values)):step()
        end)
        if not ok then
            logger.err("ereader: Failed to update article metadata:", err)
            self:closeDB()
            return false, "Failed to update article metadata: " .. tostring(err)
        end
        self:closeDB()
        logger.dbg("ereader: Updated article:", article_data.title, "as", filename)
        return true, filepath
    else
        -- Insert new article (full set of fields)
        local current_time = os.time()
        local stmt = self.db_conn:prepare([[
            INSERT INTO articles (
                bookmark_id, title, url, html_filename, html_size,
                starred, is_archived, time_added, time_updated, time_synced,
                sync_status, word_count, reading_time
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        local ok, err = pcall(function()
            stmt:reset():bind(
                article_data.bookmark_id,
                article_data.title,
                article_data.url,
                filename,
                file_size,
                article_data.starred and 1 or 0,
                article_data.type == "archive" and 1 or 0,
                article_data.time or current_time,
                article_data.time_updated or current_time,
                current_time,
                "synced",
                article_data.word_count or 0,
                article_data.reading_time or 0
            ):step()
        end)
        if not ok then
            logger.err("ereader: Failed to store article metadata:", err)
            os.remove(filepath)
            self:closeDB()
            return false, "Failed to store article metadata: " .. tostring(err)
        end
        self:closeDB()
        logger.dbg("ereader: Stored article:", article_data.title, "as", filename)
        return true, filepath
    end
end

-- Store article metadata only (without HTML content)
function Storage:storeArticleMetadata(article_data)
    self:openDB()
    
    -- Insert or update article metadata in database
    local stmt = self.db_conn:prepare([[
        INSERT OR REPLACE INTO articles (
            bookmark_id, title, url, html_filename, html_size,
            starred, is_archived, time_added, time_updated, time_synced,
            sync_status, word_count, reading_time
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    local current_time = os.time()
    local filename = self:generateFilename(article_data.bookmark_id, article_data.title)
    
    local ok, err = pcall(function()
        stmt:reset():bind(
            article_data.bookmark_id,
            article_data.title,
            article_data.url,
            filename,
            0, -- html_size (will be updated when HTML is downloaded)
            article_data.starred and 1 or 0,
            article_data.type == "archive" and 1 or 0,
            article_data.time or current_time,
            article_data.time_updated or current_time,
            current_time,
            "synced",
            article_data.word_count or 0,
            article_data.reading_time or 0
        ):step()
    end)
    
    if not ok then
        logger.err("ereader: Failed to store article metadata:", err)
        self:closeDB()
        return false, "Failed to store article metadata: " .. tostring(err)
    end
    
    self:closeDB()
    logger.dbg("ereader: Stored article metadata:", article_data.title, "with bookmark_id:", article_data.bookmark_id)
    return true
end

-- Get article metadata by Instapaper ID
function Storage:getArticle(bookmark_id)
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        SELECT * FROM articles WHERE bookmark_id = ?
    ]])
    
    local row = stmt:reset():bind(bookmark_id):step()
    self:closeDB()
    
    if row then
        return {
            id = row[1],
            bookmark_id = row[2],
            title = row[3],
            url = row[4],
            html_filename = row[5],
            html_size = row[6],
            progress = row[7],
            starred = row[8] == 1,
            is_archived = row[9] == 1,
            time_added = row[10],
            time_updated = row[11],
            time_synced = row[12],
            sync_status = row[13],
            error_message = row[14],
            word_count = row[15],
            reading_time = row[16]
        }
    end
    
    return nil
end


-- Get article HTML content
function Storage:getArticleHTML(html_filename)
    local filepath = self.instapaper_dir .. "/" .. html_filename
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    
    local content = file:read("*a")
    file:close()
    return content
end

-- Get full file path for an article, if the file exists
function Storage:getArticleFilePathIfExists(bookmark_id)
    local existing = self:getArticle(bookmark_id)

    if not existing or not existing.html_filename then
        return nil
    end
    
    local filepath = self.instapaper_dir .. "/" .. existing.html_filename
    if lfs.attributes(filepath, "mode") then
        return filepath
    end
    return nil
end

-- Update reading progress
function Storage:updateProgress(bookmark_id, progress)
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        UPDATE articles SET progress = ?, time_updated = ? WHERE bookmark_id = ?
    ]])
    
    local ok, err = pcall(function()
        stmt:reset():bind(progress, os.time(), bookmark_id):step()
    end)
    
    if not ok then
        logger.err("ereader: Failed to update progress:", err)
        self:closeDB()
        return false
    end
    
    self:closeDB()
    return true
end

-- Get all articles
function Storage:getArticles()
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        SELECT * FROM articles WHERE is_archived = 0 ORDER BY time_added DESC
    ]])
    
    local articles = {}
    local row = stmt:reset():step()
    while row do
        local article = {
            id = row[1],
            bookmark_id = row[2],
            title = row[3],
            url = row[4],
            html_filename = row[5],
            html_size = row[6],
            progress = row[7],
            starred = row[8] == 1,
            is_archived = row[9] == 1,
            time_added = row[10],
            time_updated = row[11],
            time_synced = row[12],
            sync_status = row[13],
            error_message = row[14],
            word_count = row[15],
            reading_time = row[16]
        }
        
        -- Ensure required fields are not nil
        article.title = article.title or "Untitled"
        article.url = article.url or ""
        
        table.insert(articles, article)
        row = stmt:step()
    end
    
    self:closeDB()
    logger.dbg("ereader: Retrieved", #articles, "articles from database")
    return articles
end

-- Get all bookmark IDs from the database
function Storage:getAllUnarchivedBookmarkIds()
    self:openDB()

    local stmt = self.db_conn:prepare([[
        SELECT bookmark_id FROM articles WHERE is_archived = 0
    ]])
    
    local bookmark_ids = {}
    local row = stmt:reset():step()
    while row do
        table.insert(bookmark_ids, row[1])
        row = stmt:step()
    end
    
    self:closeDB()
    logger.dbg("ereader: Retrieved", #bookmark_ids, "bookmark IDs from database")
    return bookmark_ids
end

-- Delete article by bookmark_id
function Storage:deleteArticle(bookmark_id)
    self:openDB()
    
    -- Get the HTML filename before deleting
    local stmt = self.db_conn:prepare([[
        SELECT html_filename FROM articles WHERE bookmark_id = ?
    ]])
    
    local row = stmt:reset():bind(bookmark_id):step()
    local html_filename = row and row[1]
    
    -- Delete highlights first
    local delete_highlights_stmt = self.db_conn:prepare([[
        DELETE FROM highlights WHERE bookmark_id = ?
    ]])
    
    local ok, err = pcall(function()
        delete_highlights_stmt:reset():bind(bookmark_id):step()
    end)
    
    if not ok then
        logger.warn("ereader: Failed to delete highlights from database:", err)
    end
    
    -- Delete from database
    local delete_stmt = self.db_conn:prepare([[
        DELETE FROM articles WHERE bookmark_id = ?
    ]])
    
    local ok, err = pcall(function()
        delete_stmt:reset():bind(bookmark_id):step()
    end)
    
    if not ok then
        logger.err("ereader: Failed to delete article from database:", err)
        self:closeDB()
        return false, err
    end
    
    -- Delete HTML file if it exists
    if html_filename then
        local filepath = self.instapaper_dir .. "/" .. html_filename
        local success, err = os.remove(filepath)
        if not success and err ~= "No such file or directory" then
            logger.warn("ereader: Failed to delete HTML file:", filepath, err)
        end
    end
    
    -- Delete thumbnail if it exists
    local thumbnail_path = self:getArticleThumbnail(bookmark_id)
    if thumbnail_path then
        local success, err = os.remove(thumbnail_path)
        if not success and err ~= "No such file or directory" then
            logger.warn("ereader: Failed to delete thumbnail:", thumbnail_path, err)
        end
    end
    
    self:closeDB()
    logger.dbg("ereader: Deleted article with bookmark_id:", bookmark_id)
    return true
end

-- Clear all articles from database and filesystem
function Storage:clearAll()
    self:clearThumbnails()
    
    -- Remove all html files and sdr directories
    for file in lfs.dir(self.instapaper_dir) do
        if file ~= "." and file ~= ".." then
            local filepath = self.instapaper_dir .. "/" .. file
            local attr = lfs.attributes(filepath)
            
            if attr then
                if file:match(".html$") and attr.mode == "file" then
                    -- Remove HTML files
                    local success, err = os.remove(filepath)
                    if not success then
                        logger.warn("ereader: Failed to remove html file:", filepath, err)
                    end
                elseif file:match(".sdr$") and attr.mode == "directory" then
                    -- Remove SDR directories using ffiUtil.purgeDir
                    local success, err = ffiUtil.purgeDir(filepath)
                    if not success then
                        logger.warn("ereader: Failed to remove sdr directory:", filepath, err)
                    end
                end
            end
        end
    end

    self:openDB()
    
    -- Clear database
    self.db_conn:exec("DELETE FROM articles")
    self.db_conn:exec("DELETE FROM highlights")
    
    self:closeDB()
    logger.dbg("ereader: Cleared all articles from database and filesystem")
end

-- Get the last sync time from the database
function Storage:getLastSyncTime()
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        SELECT MAX(time_synced) FROM articles
    ]])
    
    local row = stmt:reset():step()
    self:closeDB()
    
    if row and row[1] then
        return row[1]
    end
    
    return nil
end

-- Save thumbnail image to file
function Storage:saveThumbnailImageToFile(image_data, bookmark_id)
    local RenderImage = require("ui/renderimage")
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    
    local image_bb = RenderImage:renderImageData(image_data, #image_data)
    if not image_bb then
        logger.warn("ereader: Failed to render image")
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
    local thumbnail_filename = string.format("%s/%s_thumbnail.jpg", self.thumbnail_dir, bookmark_id)
    local save_success, err = thumbnail_bb:writeToFile(thumbnail_filename, "jpg", 85)
    
    image_bb:free()
    cropped_bb:free()
    thumbnail_bb:free()
        
    if save_success then
        logger.dbg("ereader: Saved thumbnail:", thumbnail_filename)
        return true
    else
        logger.warn("ereader: Failed to save thumbnail:", thumbnail_filename, "Error:", err)
        return false
    end
end

-- Get article thumbnail file path
function Storage:getArticleThumbnail(bookmark_id)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    
    -- Generate thumbnail filename
    local thumbnail_filename = string.format("%s/%s_thumbnail.jpg", 
    self.thumbnail_dir, bookmark_id)
    
    -- Check if thumbnail file exists
    if lfs.attributes(thumbnail_filename, "mode") then
        return thumbnail_filename
    else
        return nil
    end
end

-- Clear all thumbnail files
function Storage:clearThumbnails()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
        
    -- Check if thumbnail directory exists
    if not lfs.attributes(self.thumbnail_dir, "mode") then
        logger.dbg("ereader: No thumbnail directory to clean up")
        return
    end
    
    -- Remove all thumbnail files
    local count = 0
    for file in lfs.dir(self.thumbnail_dir) do
        if file ~= "." and file ~= ".." and file:match("_thumbnail%.jpg$") then
            local filepath = self.thumbnail_dir .. "/" .. file
            local success, err = os.remove(filepath)
            if success then
                count = count + 1
            else
                logger.warn("ereader: Failed to remove thumbnail file:", filepath, err)
            end
        end
    end
    
    logger.dbg("ereader: Cleaned up", count, "thumbnail files")
end

function Storage:updateArticleStatus(bookmark_id, status_type, value)
    self:openDB()
    local field
    if status_type == "starred" then
        field = "starred"
    elseif status_type == "archived" then
        field = "is_archived"
    else
        self:closeDB()
        logger.err("ereader: Unknown status_type for updateArticleStatus: " .. tostring(status_type))
        return false, "Unknown status_type: " .. tostring(status_type)
    end
    
    local stmt = self.db_conn:prepare(string.format(
        "UPDATE articles SET %s = ?, time_updated = ? WHERE bookmark_id = ?",
        field
    ))
    local ok, err = pcall(function()
        stmt:reset():bind(value and 1 or 0, os.time(), bookmark_id):step()
    end)
    if not ok then
        logger.err("ereader: Failed to update article status:", err)
        self:closeDB()
        return false, err
    end
    self:closeDB()
    logger.dbg("ereader: Updated article status:", bookmark_id, field, value)
    return true
end

-- Store highlights for an article
function Storage:storeHighlights(bookmark_id, highlights)
    -- Ensure bookmark_id is a number
    bookmark_id = tonumber(bookmark_id)
    if not bookmark_id then
        logger.err("ereader: Invalid bookmark_id:", bookmark_id)
        return false, "Invalid bookmark_id"
    end
    
    if not highlights or #highlights == 0 then
        logger.dbg("ereader: No highlights to store for bookmark_id:", bookmark_id)
        return true
    end
    
    self:openDB()
    
    -- First, delete existing synced highlights for this article. We re-add them below since some of them may have since been removed
    local delete_stmt = self.db_conn:prepare([[ 
        DELETE FROM highlights WHERE bookmark_id = ? AND (sync_status = 'synced')
    ]])
    
    local ok, err = pcall(function()
        delete_stmt:reset():bind(bookmark_id):step()
    end)
    
    if not ok then
        logger.err("ereader: Failed to delete existing highlights:", err)
        return false, "Failed to delete existing highlights: " .. tostring(err)
    end
    
    -- Query for all highlights for this bookmark_id with sync_status = 'pending_delete'
    local pending_delete_ids = {}
    local pending_delete_stmt = self.db_conn:prepare([[SELECT highlight_id FROM highlights WHERE bookmark_id = ? AND sync_status = 'pending_delete']])
    local row = pending_delete_stmt:reset():bind(bookmark_id):step()
    while row do
        logger.dbg("ereader: Found pending delete:", tonumber(row[1]))
        if row[1] then
            pending_delete_ids[tonumber(row[1])] = true
        end
        row = pending_delete_stmt:step()
    end
    
    -- Insert new highlights, skipping those marked pending_delete
    local insert_stmt = self.db_conn:prepare([[
        INSERT INTO highlights (
            bookmark_id, highlight_id, text, note, position, 
            time_created, time_updated, sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    local current_time = os.time()
    local inserted_count = 0
    
    for _, highlight in ipairs(highlights) do
        local highlight_id = tonumber(highlight.highlight_id) or 0
        -- Skip highlights marked pending_delete
        if highlight_id ~= 0 and pending_delete_ids[highlight_id] then
            logger.dbg("ereader: Skipping restore of highlight marked pending_delete:", highlight_id)
            goto continue
        end
        local text = tostring(highlight.text or "")
        local note = highlight.note
        local position = tonumber(highlight.position) or 0
        local time_created = tonumber(highlight.time) or current_time
        local ok, err = pcall(function()
            insert_stmt:reset():bind(
                bookmark_id,
                highlight_id,
                text,
                note,
                position,
                time_created,
                current_time,
                "synced"
            ):step()
        end)
        if not ok then
            logger.err("ereader: Failed to insert highlight:", err)
            self:closeDB()
            return false, "Failed to insert highlight: " .. tostring(err)
        end
        inserted_count = inserted_count + 1
        ::continue::
    end
    
    self:closeDB()
    logger.dbg("ereader: Stored", inserted_count, "highlights for bookmark_id:", bookmark_id)
    return true
end

-- Get highlights for an article
function Storage:getHighlights(bookmark_id)
    self:openDB()
    local stmt = self.db_conn:prepare([[SELECT * FROM highlights WHERE bookmark_id = ? AND (sync_status IS NULL OR sync_status != 'pending_delete') ORDER BY position ASC]])
    local highlights = {}
    local row = stmt:reset():bind(bookmark_id):step()
    while row do
        local highlight = {
            id = row[1],
            bookmark_id = row[2],
            highlight_id = row[3],
            text = row[4],
            note = row[5],
            position = row[6],
            time_created = row[7],
            time_updated = row[8],
            sync_status = row[9]
        }
        table.insert(highlights, highlight)
        row = stmt:step()
    end
    self:closeDB()
    logger.dbg("ereader: Retrieved", #highlights, "highlights for bookmark_id:", bookmark_id)
    return highlights
end

-- Delete highlights for an article
function Storage:deleteHighlights(bookmark_id)
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        DELETE FROM highlights WHERE bookmark_id = ?
    ]])
    
    local ok, err = pcall(function()
        stmt:reset():bind(bookmark_id):step()
    end)
    
    if not ok then
        logger.err("ereader: Failed to delete highlights:", err)
        self:closeDB()
        return false, "Failed to delete highlights: " .. tostring(err)
    end
    
    self:closeDB()
    logger.dbg("ereader: Deleted highlights for bookmark_id:", bookmark_id)
    return true
end

-- Get all highlights from the database
function Storage:getAllHighlights()
    self:openDB()
    
    local stmt = self.db_conn:prepare([[
        SELECT * FROM highlights ORDER BY bookmark_id ASC, position ASC
    ]])
    
    local highlights = {}
    local row = stmt:reset():step()
    while row do
        local highlight = {
            id = row[1],
            bookmark_id = row[2],
            highlight_id = row[3],
            text = row[4],
            note = row[5],
            position = row[6],
            time_created = row[7],
            time_updated = row[8],
            sync_status = row[9]
        }
        table.insert(highlights, highlight)
        row = stmt:step()
    end
    
    self:closeDB()
    logger.dbg("ereader: Retrieved", #highlights, "highlights from database")
    return highlights
end

function Storage:savePendingHighlight(highlight)
    self:openDB()
    local insert_stmt = self.db_conn:prepare([[ 
        INSERT INTO highlights (
            bookmark_id, highlight_id, text, note, position, 
            time_created, time_updated, sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    local current_time = os.time()
    local bookmark_id = tonumber(highlight.bookmark_id) or 0
    local text = tostring(highlight.text or "")
    local note = highlight.note
    local position = tonumber(highlight.position) or 0
    local time_created = tonumber(highlight.time_created) or current_time
    local time_updated = tonumber(highlight.time_updated) or current_time
    local sync_status = "pending"
    local ok, err = pcall(function()
        insert_stmt:reset():bind(
            bookmark_id,
            nil,  -- highlight_id is NULL for pending highlights
            text,
            note,
            position,
            time_created,
            time_updated,
            sync_status
        ):step()
    end)
    self:closeDB()
    if not ok then
        logger.err("ereader: Failed to insert pending highlight:", err)
        return false, err
    end
    logger.dbg("ereader: Saved pending highlight for bookmark_id:", bookmark_id, "text:", text)
    return true
end

function Storage:markHighlightPendingDelete(id)
    self:openDB()
    local stmt = self.db_conn:prepare([[UPDATE highlights SET sync_status = 'pending_delete' WHERE id = ?]])
    local ok, err = pcall(function()
        stmt:reset():bind(id):step()
    end)
    self:closeDB()
    if not ok then
        logger.err("ereader: Failed to mark highlight as pending_delete:", err)
        return false, err
    end
    logger.dbg("ereader: Marked highlight as pending_delete:", id)
    return true
end

return Storage 