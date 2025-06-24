local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InstapaperUIManager = require("frontend/ui/instapaper/manager")
local InstapaperManager = require("instapapermanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local Trapper = require("ui/trapper")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UI = require("ui/trapper")
local Screen = require("device").screen
local DocSettings = require("docsettings")

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    kv = nil, -- KeyValuePage
}

-- DEVELOPMENT ONLY: Load stored credentials from api_keys.txt for testing convenience
local function loadDevCredentials()
    local stored_username = ""
    local stored_password = ""
    local secrets_path = "plugins/instapaper.koplugin/secrets.txt"
    local file = io.open(secrets_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        
        for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
            if key == "instapaper_username" then
                stored_username = value
            elseif key == "instapaper_password" then
                stored_password = value
            end
        end
    end
    return stored_username, stored_password
end

function Instapaper:init()
    self.uimanager = InstapaperUIManager:new()
    self.instapaperManager = InstapaperManager:new()
    self.ui.menu:registerToMainMenu(self)    
end

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = "Instapaper",
        callback = function()
            Trapper:wrap(function()
                if self.instapaperManager:isAuthenticated() then
                    self:showArticles() 
                else
                    self:showLoginDialog()
                end
            end)
        end,
    }
end

function Instapaper:showLoginDialog()
    -- DEVELOPMENT ONLY: Pre-fill credentials for testing
    local stored_username, stored_password = loadDevCredentials()

    self.kv = KeyValuePage:new{
        title = _("Instapaper"),
        value_overflow_align = "right",
        callback_return = function()
            UIManager:close(self.kv)
        end,    
    }
    UIManager:show(self.kv)
    
    self.login_dialog = MultiInputDialog:new{
        title = _("Instapaper Login"),
        fields = {
            {
                text = stored_username,
                hint = _("Username"),
            },
            {
                text = stored_password,
                text_type = "password",
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        local username = fields[1]:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
                        local password = fields[2]
                        
                        if username == "" or password == "" then
                            UIManager:show(ConfirmBox:new{
                                text = _("Please enter both username and password."),
                                ok_text = _("OK"),
                            })
                            return
                        end
                        
                        UIManager:close(self.login_dialog)
                        
                        -- Show loading message
                        local info = InfoMessage:new{ text = _("Authenticating") }
                        UIManager:show(info)
                        
                        -- Perform authentication
                        local success = self.instapaperManager:authenticate(username, password)

                        UIManager:close(info)

                        if success then
                            self.instapaperManager:syncReads()
                            self:showArticles()
                        else 
                            UIManager:show(ConfirmBox:new{
                                text = _("Authentication failed. Please check your username and password."),
                                ok_text = _("OK"),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function Instapaper:showArticles()
    if self.kv then
        UIManager:close(self.kv)
    end

    -- Get articles from database store
    local articles = self.instapaperManager:getArticles()
    
    logger.dbg("instapaper: Got", #articles, "articles from database")
    
    -- Build display data
    local kv_pairs = {}
        
    if articles and #articles > 0 then        
        for i = 1, #articles do
            local article = articles[i]

            local isDownloaded = ""
            if article.html_size and article.html_size > 0 then
                 isDownloaded = "⬇️ "
            end
            local title = (isDownloaded .. article.title) or "Untitled"
            -- Extract domain from URL
            local domain = self.instapaperManager.getDomain(article.url)
            local description = domain or "No URL"
            kv_pairs[#kv_pairs + 1] = { 
                title,
                description,
                callback = function()
                    self:showArticleContent(article)
                end
            }
        end

        kv_pairs[#kv_pairs + 1] = { "Articles", #articles .. " articles" }
    else
        kv_pairs[#kv_pairs + 1] = { "Articles", "No articles synced yet" }
    end

    self.kv = KeyValuePage:new{
        title = _("Instapaper"),
        title_bar_left_icon = "appbar.menu",
        title_bar_left_icon_tap_callback = function()
            local last_sync = self.instapaperManager:getLastSyncTime()
            local sync_string = "Never"
            if last_sync then
                local sync_time = os.date("%Y-%m-%d %H:%M:%S", tonumber(last_sync))
                sync_string = ("Last Sync: " .. sync_time)
            end
            local Menu = require("ui/widget/menu")
            local menu_container = Menu:new{
                title = _("Settings"),
                width = Screen:getWidth() * 0.8,
                height = Screen:getHeight() * 0.8,
                item_table = {
                    {
                        text = sync_string,
                    },
                    {
                        text = _("Sync"),
                        callback = function()
                            local info = InfoMessage:new{ text = _("Syncing articles...") }
                            UIManager:show(info)
                            
                            -- Perform sync
                            local success = self.instapaperManager:syncReads()
                            
                            UIManager:close(info)
                            
                            if success then
                                UIManager:show(InfoMessage:new{ 
                                    text = _("Sync completed successfully!"),
                                    timeout = 2
                                })
                                -- Refresh the display
                                self:showArticles()
                            else
                                UIManager:show(ConfirmBox:new{
                                    text = _("Sync failed. Please try again."),
                                    ok_text = _("OK"),
                                })
                            end
                        end,
                    },
                    {   
                        text = _("Logged in as " .. self.instapaperManager.username or "unknown user"),
                    },
                    {
                        text = _("Log out"),
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Logout of Instapaper?"),
                                ok_text = _("Logout"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    self.instapaperManager:logout()
                                    self:showLoginDialog()
                                end,
                            })
                        end,
                    },
                },
            }
            UIManager:show(menu_container)
        end,
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
        callback_return = function()
            UIManager:close(self.kv)
        end,    
    }

    -- Forward key events from KeyValuePage to Instapaper for dev shortcuts
    self.kv.onKeyPress = function(widget, key, mods, is_repeat)
        if self.onKeyPress then
            return self:onKeyPress(key, mods, is_repeat)
        end
        return false
    end
  
    UIManager:show(self.kv)
end

function Instapaper:showArticleContent(article)
    -- Show loading message
    local info = InfoMessage:new{ text = _("Downloading article...") }
    UIManager:show(info)
    UIManager:nextTick(function()
        -- Download and get article content
        local success, result = self.instapaperManager:downloadArticle(article.bookmark_id)
        UIManager:close(info)
        if not success then
            UIManager:show(ConfirmBox:new{
                text = _("Failed to load article: ") .. (result or _("Unknown error")),
                ok_text = _("OK"),
            })
            return
        end
        -- Get the file path from storage
        local file_path = self.instapaperManager.storage:getArticleFilePath(article.bookmark_id)
        if not file_path then
            UIManager:show(ConfirmBox:new{
                text = _("Article file not found"),
                ok_text = _("OK"),
            })
            return
        end
        
        -- Store the current article for the ReaderUI module
        self.current_article = article
        
        -- Open the stored HTML file directly in KOReader
        local ReaderUI = require("apps/reader/readerui")
        local doc_settings = DocSettings:open(file_path)
        local current_rotation = Screen:getRotationMode()
        doc_settings:saveSetting("kopt_rotation_mode", current_rotation)
        doc_settings:saveSetting("copt_rotation_mode", current_rotation)
        doc_settings:flush()
        ReaderUI:showReader(file_path)


        -- Register our Instapaper module after ReaderUI is created
        UIManager:scheduleIn(0.1, function()
            if ReaderUI.instance then
                local ReaderInstapaper = require("readerui")
                local module_instance = ReaderInstapaper:new{
                    ui = ReaderUI.instance,
                    dialog = ReaderUI.instance,
                    view = ReaderUI.instance.view,
                    document = ReaderUI.instance.document,
                }
                ReaderUI.instance:registerModule("instapaper", module_instance)
                logger.dbg("Instapaper: Registered ReaderInstapaper module")
            end
        end)

        -- update the article list to show the downloaded article
        self:showArticles()
    end)
end

function Instapaper:onKeyPress(key, mods, is_repeat)
    -- Development feature: F4 rotates the device 90º
    if key.key == "F4" then
        UIManager:close(self.kv)
        UIManager:nextTick(function()
            local current = Screen:getRotationMode()
            local new_mode = (current + 1) % 4
            Screen:setRotationMode(new_mode)
            self:showArticles()
        end)
        return true
    end
    return false
end

return Instapaper
