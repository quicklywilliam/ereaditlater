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
local Device = require("device")
local ListView = require("ui/widget/listview")
local ImageWidget = require("ui/widget/imagewidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local IconButton = require("ui/widget/iconbutton")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local TitleBar = require("ui/widget/titlebar")
local OverlapGroup = require("ui/widget/overlapgroup")
local Button = require("ui/widget/button")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")


local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    list_view = nil, -- KeyValuePage
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
    
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)    
    end

    if self.ui and self.ui.link then
        self.ui.link:addToExternalLinkDialog("instapaper", function(this, link_url)
            return {
                text = _("Save to Instapaper"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    this.ui:handleEvent(Event:new("AddToInstapaper", link_url))
                end,
            }
        end)
    end
end

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = "Instapaper",
        callback = function()
            Trapper:wrap(function()
                self:showUI()
            end)
        end,
    }
end

function Instapaper:showUI() 
    if self.instapaperManager:isAuthenticated() then
        self:showArticles() 
    else
        self:showLoginDialog()
    end
end

function Instapaper:showLoginDialog()
    -- DEVELOPMENT ONLY: Pre-fill credentials for testing
    local stored_username, stored_password = loadDevCredentials()

    self.list_view = KeyValuePage:new{
        title = _("Instapaper"),
        value_overflow_align = "right",
        callback_return = function()
            UIManager:close(self.list_view)
        end,    
    }
    UIManager:show(self.list_view)
    
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
                        
                        
                        -- Show loading message
                        local info = InfoMessage:new{ text = _("Logging in...") }
                        UIManager:show(info)
                        
                        -- Perform authentication
                        local success, error_message = self.instapaperManager:authenticate(username, password)

                        UIManager:close(info)

                        if success then
                            UIManager:close(self.login_dialog)

                            self.instapaperManager:syncReads()
                            self:showArticles()
                        else 
                            UIManager:show(ConfirmBox:new{
                                text = _("Could not log in: " .. error_message),
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

-- Create a custom article item widget
local ArticleItem = InputContainer:extend{
    name = "article_item",
    article = nil,
    width = nil,
    height = nil,
    background = nil,
    callback = nil,
}

function ArticleItem:init()
    self.dimen = Geom:new{x = 0, y = 0, w = self.width, h = self.height}
    
    -- Create article content
    local title_text = self.article.title or "Untitled"
    local domain = self.instapaperManager.getDomain(self.article.url) or "No URL"
    
    -- Download status indicator
    local download_icon = nil
    local is_downloaded = self.article.html_size and self.article.html_size > 0
    if is_downloaded then
        download_icon = TextWidget:new{
            alignment = "left",
            text = "⇩",
            face = Font:getFace("infont", 20),
            max_width = Screen:scaleBySize(20),
        }
    end
    
    -- Thumbnail widget
    local thumbnail_size = Screen:scaleBySize(60)
    local thumbnail_path = self.instapaperManager:getArticleThumbnail(self.article.bookmark_id)
    local thumbnail_widget
    
    if thumbnail_path then
        -- Create image widget with actual thumbnail
        thumbnail_widget = ImageWidget:new{
            file = thumbnail_path,
            width = thumbnail_size,
            height = thumbnail_size,
            scale_factor = nil, -- Scale to fit
        }
    elseif is_downloaded then
        -- Create placeholder with grey background
        thumbnail_widget = Button:new{
            icon = "notice-question",
            bordersize = 3,
            border_color = Blitbuffer.COLOR_DARK_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            width = thumbnail_size,
            height = thumbnail_size,
        }
    else
        -- Creat an empty placeholder with grey background
        thumbnail_widget = Button:new{
            text = "",
            bordersize = 3,
            border_color = Blitbuffer.COLOR_DARK_GRAY,
            background = Blitbuffer.COLOR_GRAY_E,
            width = thumbnail_size,
            height = thumbnail_size,
        } 
    end
    
    -- Title widget
    local title_widget = TextWidget:new{
        text = title_text,
        fgcolor = is_downloaded and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        face = Font:getFace("x_smalltfont", 16),
        max_width = self.width - thumbnail_size - Screen:scaleBySize(60), -- Leave space for thumbnail and download icon
        width = self.width - thumbnail_size - Screen:scaleBySize(60),
    }
    
    -- Domain widget
    local domain_widget = TextWidget:new{
        text = domain,
        fgcolor = is_downloaded and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
        face = Font:getFace("infont", 14),
        max_width = self.width - thumbnail_size - Screen:scaleBySize(60), -- Leave space for thumbnail and download icon
        width = self.width - thumbnail_size - Screen:scaleBySize(60),
    }
    
    -- Layout: title and domain stacked vertically
    local text_group = VerticalGroup:new{
        align = "left",
        title_widget,
        VerticalSpan:new{ height = Screen:scaleBySize(4) },
        domain_widget,
    }
    
    -- Main content with thumbnail on the left and download icon on the right
    local content_group
    if download_icon then
        content_group = OverlapGroup:new {
            dimen = self.dimen:copy(),
            HorizontalGroup:new{
                align = "top",
                thumbnail_widget,
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                text_group,
            },
            RightContainer:new{
                align = "center",
                dimen = Geom:new{ w = self.width - Screen:scaleBySize(20), h = self.height },
                download_icon,
            },
        }
    else
        content_group = HorizontalGroup:new{
            align = "top",
            thumbnail_widget,
            HorizontalSpan:new{ width = Screen:scaleBySize(10) },
            text_group,
        }
    end
    
    -- Container with background and padding
    self[1] = FrameContainer:new{
        background = self.background or Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        width = self.width,
        height = self.height,
        content_group,
    }
    
    -- Register touch events - only handle taps, not swipes
    if Device:isTouchDevice() then
        self.ges_events.TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
        -- Don't register swipe events to avoid blocking ListView swipes
    end
end

function ArticleItem:onTapSelect(arg, ges_ev)
    if self.callback then
        self.callback()
    end
    return true
end

-- Don't handle swipe events - let them pass through to ListView
function ArticleItem:onSwipe(arg, ges_ev)
    return false -- Let the event bubble up to parent
end

function Instapaper:showArticles()
    if self.list_view then
        UIManager:close(self.list_view)
    end

    -- Get articles from database store
    local articles = self.instapaperManager:getArticles()
    
    logger.dbg("instapaper: Got", #articles, "articles from database")
    
    -- Create article item widgets
    local items = {}
    local item_height = Screen:scaleBySize(80) -- Fixed height for all items
    local width = Screen:getWidth()
    
    if articles and #articles > 0 then
        for i = 1, #articles do
            local article = articles[i]
            local background = (i % 2 == 0) and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE
            
            local item = ArticleItem:new{
                width = width,
                height = item_height,
                background = background,
                article = article,
                instapaperManager = self.instapaperManager,
                callback = function()
                    self:showArticleContent(article)
                end,
            }
            table.insert(items, item)
        end
    else
        -- Show "no articles" message
        local no_articles_item = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = Screen:scaleBySize(20),
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = item_height },
                TextWidget:new{
                    text = _("No articles synced yet"),
                    face = Font:getFace("cfont"),
                },
            },
        }
        table.insert(items, no_articles_item)
    end
    
    -- Create header with title and menu button
    local header_height = Screen:scaleBySize(50)
    local header = TitleBar:new{
        width = width,
        align = "left",
        title = _("Instapaper"),
        subtitle = #articles .. " articles",
        subtitle_face = Font:getFace("xx_smallinfofont", 14),
        title_top_padding = Screen:scaleBySize(4),
        title_bottom_padding = Screen:scaleBySize(4),
        title_subtitle_v_padding = Screen:scaleBySize(0),
        button_padding = Screen:scaleBySize(10),
        left_icon_size_ratio = 1,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showMenu()
        end,
        right_icon = "close",
        right_icon_tap_callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Quit Instapaper and return to Kobo?"),
                icon = "notice-question",
                ok_text = _("Quit"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    -- Exit KOReader entirely
                    os.exit(0)
                end,
            })
        end,
        show_parent = self,
    }
    local header_height = header:getHeight()
    
    -- Create ListView
    local list_height = Screen:getHeight() - header_height
    local list_view = ListView:new{
        width = width,
        height = list_height,
        items = items,
        padding = 0,
        page_update_cb = function(curr_page, total_pages)
            -- Trigger screen refresh when page changes
            UIManager:setDirty(self.list_view, function()
                return "ui", self.list_view.dimen
            end)
        end,
    }
    
    -- Create main container
    self.list_view = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = 0,
        width = width,
        VerticalGroup:new{
            align = "left",
            header,
            list_view,
        },
    }
    
    -- Forward key events for dev shortcuts and page navigation
    self.list_view.onKeyPress = function(widget, key, mods, is_repeat)
        -- Handle page navigation
        if key.key == "Left" or key.key == "Up" or key.key == "RPgBack" then
            list_view:prevPage()
            return true
        elseif key.key == "Right" or key.key == "Down" or key.key == "RPgFwd" then
            list_view:nextPage()
            return true
        end
        
        -- Handle dev shortcuts
        if self.onKeyPress then
            return self:onKeyPress(key, mods, is_repeat)
        end
        return false
    end
    
    self.list_view.onSetRotationMode = function(widget, mode)
        Screen:setRotationMode(mode)
        UIManager:nextTick(function()
            self:showArticles()
        end)
        return true
    end


    UIManager:show(self.list_view)
end

function Instapaper:showMenu()
    local last_sync = self.instapaperManager:getLastSyncTime()
    local sync_string = "Sync"
    if last_sync then
        local sync_time = os.date("%m-%d %H:%M", tonumber(last_sync))
        sync_string = ("Sync (last: " .. sync_time .. ")")
    end
    local Menu = require("ui/widget/menu")
    local menu_container = Menu:new{
        width = Screen:getWidth() * 0.8,
        height = Screen:getHeight() * 0.8,
        is_enable_shortcut = false,
        item_table = {
            {
                text = sync_string,
                callback = function()
                    local info = InfoMessage:new{ text = _("Syncing articles...") }
                    UIManager:show(info)
                    
                    -- Perform sync
                    local success, error_message = self.instapaperManager:syncReads()
                    
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
                            text = _("Sync failed: " .. error_message),
                            ok_text = _("OK"),
                        })
                    end
                end,
            },
            {
                text = _("Log out (" .. (self.instapaperManager.instapaper_api_manager.username or "unknown user") .. ")"),
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
            {
                text = _("Exit to KOReader"),
                callback = function()
                    UIManager:close(menu_container)
                    -- Close the current Instapaper UI
                    if self.list_view then
                        UIManager:close(self.list_view)
                    end
                    -- Open the File Manager
                    local FileManager = require("apps/filemanager/filemanager")
                    FileManager:showFiles()
                end,
            },
        },
    }
    UIManager:show(menu_container)
end

function Instapaper:showArticleContent(article)
    -- Show loading message
    local info = InfoMessage:new{ text = _("Downloading article...") }
    UIManager:show(info)
    
    UIManager:scheduleIn(0.1, function()
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

--- Handler for our button in the ReaderUI's link menu
function Instapaper:onAddToInstapaper(url)
    if not NetworkMgr:isOnline() then
        -- currently there is no way to add an article to an offline queue, so we just show a message
        UIManager:show(InfoMessage:new{
            text = "Your ereader is currently offline. Connect to wifi and try again.",
            icon = "wifi.open.0",
        })
        return
    end

    local success, error_message = self.instapaperManager:addArticle(url)

    if success then
        UIManager:show(InfoMessage:new{
            text = "Saved to Instapaper",
            icon = "check",
            timeout = 1,
        })
    else
        UIManager:show(InfoMessage:new{
            text = "Error saving to Instapaper: " .. error_message,
            icon = "notice-error",
        })
    end
    return true
end

function Instapaper:onKeyPress(key, mods, is_repeat)

    if Device:isEmulator() and (key.key == "F4") then
        for l, v in pairs(key.modifiers) do
            if v then
                return false
            end
        end
        local current = Screen:getRotationMode()
        local new_mode = (current + 1) % 4
        self.list_view.onSetRotationMode(self.list_view, new_mode)
        return true
    end
    return false
end

return Instapaper
