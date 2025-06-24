local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Storage = {}

-- Database schema version
local DB_SCHEMA_VERSION = 3

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
]]

function Storage:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    
    o.db_location = DataStorage:getSettingsDir() .. "/instapaper.sqlite"
    o.articles_dir = DataStorage:getFullDataDir() .. "/instapaper"
    o.db_conn = nil
    o.initialized = false
    
    return o
end

function Storage:init()
    if self.initialized then
        return
    end
    
    logger.dbg("Instapaper: Initializing storage at", self.db_location)
    
    -- Create articles directory if it doesn't exist
    if not lfs.attributes(self.articles_dir, "mode") then
        lfs.mkdir(self.articles_dir)
        logger.dbg("Instapaper: Created articles directory:", self.articles_dir)
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
            
            logger.dbg("Instapaper: Database upgraded and recreated")
        else
            -- Schema is up to date, just close and return
            db_conn:close()
            logger.dbg("Instapaper: Database schema is up to date")
            return
        end
        
        db_conn:close()
    else
        -- Database doesn't exist, create new one
        logger.dbg("Instapaper: Creating new database")
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
        logger.dbg("Instapaper: New database created")
    end
    
    logger.dbg("Instapaper: Database initialized at", self.db_location)
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
    local filepath = self.articles_dir .. "/" .. filename
    
    -- Write HTML file
    local file = io.open(filepath, "w")
    if not file then
        logger.err("Instapaper: Failed to create HTML file:", filepath)
        self:closeDB()
        return false, "Failed to create HTML file"
    end
    
    file:write(html_content)
    file:close()
    
    local file_size = lfs.attributes(filepath, "size") or 0
    
    -- Insert or update article metadata in database
    local stmt = self.db_conn:prepare([[
        INSERT OR REPLACE INTO articles (
            bookmark_id, title, url, html_filename, html_size,
            starred, is_archived, time_added, time_updated, time_synced,
            sync_status, word_count, reading_time
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    local current_time = os.time()
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
        logger.err("Instapaper: Failed to store article metadata:", err)
        -- Clean up the HTML file if database insert failed
        os.remove(filepath)
        self:closeDB()
        return false, "Failed to store article metadata: " .. tostring(err)
    end
    
    self:closeDB()
    logger.dbg("Instapaper: Stored article:", article_data.title, "as", filename)
    return true, filename
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
        logger.err("Instapaper: Failed to store article metadata:", err)
        self:closeDB()
        return false, "Failed to store article metadata: " .. tostring(err)
    end
    
    self:closeDB()
    logger.dbg("Instapaper: Stored article metadata:", article_data.title, "with bookmark_id:", article_data.bookmark_id)
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
    local filepath = self.articles_dir .. "/" .. html_filename
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end
    
    local content = file:read("*a")
    file:close()
    return content
end

-- Get full file path for an article
function Storage:getArticleFilePath(bookmark_id)
    local article = self:getArticle(bookmark_id)
    if article and article.html_filename then
        return self.articles_dir .. "/" .. article.html_filename
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
        logger.err("Instapaper: Failed to update progress:", err)
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
    logger.dbg("Instapaper: Retrieved", #articles, "articles from database")
    return articles
end

-- Clear all articles from database and filesystem
function Storage:clearAll()
    self:openDB()
    
    -- Get all filenames to delete
    local stmt = self.db_conn:prepare([[
        SELECT html_filename FROM articles WHERE html_filename IS NOT NULL
    ]])
    
    local filenames = {}
    local row = stmt:reset():step()
    while row do
        table.insert(filenames, row[1])
        row = stmt:step()
    end
    
    -- Delete HTML files
    for _, filename in ipairs(filenames) do
        local filepath = self.articles_dir .. "/" .. filename
        os.remove(filepath)
    end
    
    -- Clear database
    self.db_conn:exec("DELETE FROM articles")
    
    self:closeDB()
    logger.dbg("Instapaper: Cleared all articles from database and filesystem")
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

function Storage:updateArticleStatus(bookmark_id, status_type, value)
    self:openDB()
    local field
    if status_type == "starred" then
        field = "starred"
    elseif status_type == "archived" then
        field = "is_archived"
    else
        self:closeDB()
        logger.err("Instapaper: Unknown status_type for updateArticleStatus: " .. tostring(status_type))
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
        logger.err("Instapaper: Failed to update article status:", err)
        self:closeDB()
        return false, err
    end
    self:closeDB()
    logger.dbg("Instapaper: Updated article status:", bookmark_id, field, value)
    return true
end

return Storage 