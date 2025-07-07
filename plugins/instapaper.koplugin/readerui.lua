local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconButton = require("ui/widget/iconbutton")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Font = require("ui/font")
local VerticalGroup = require("ui/widget/verticalgroup")
local InstapaperManager = require("instapapermanager")
local ButtonDialog = require("ui/widget/buttondialog")
local ReaderStatus = require("apps/reader/modules/readerstatus")

local ReaderInstapaper = InputContainer:extend{
    name = "readerinstapaper",
    is_instapaper_article = false,
    current_article = nil,
    toolbar_visible = false,
    toolbar_widget = nil,
}

function ReaderInstapaper:init()
    -- Check if this is an Instapaper article by examining the document file path
    if self.ui and self.ui.document and self.ui.document.file then
        local file_path = self.ui.document.file
        if string.find(file_path, "/instapaper/") or string.find(file_path, "instapaper") then
            self.is_instapaper_article = true
            logger.dbg("Instapaper: Detected Instapaper article:", file_path)
            
            -- Extract bookmark_id from file path for API calls
            local bookmark_id = self:extractBookmarkIdFromPath(file_path)
            if bookmark_id then
                self.current_article = { bookmark_id = bookmark_id }
                logger.dbg("Instapaper: Extracted bookmark_id:", bookmark_id)
            end
            
            -- Register touch zones for showing/hiding toolbar
            self:setupTouchZones()
            
            -- Safely register to main menu - check if ReaderUI is ready
            if self.ui.postInitCallback then
                -- ReaderUI is ready, register immediately
                self.ui:registerPostInitCallback(function()
                    self.ui.menu:registerToMainMenu(self)
                end)
            else
                -- ReaderUI not ready yet, schedule for later
                UIManager:scheduleIn(0.1, function()
                    if self.ui and self.ui.postInitCallback then
                        self.ui:registerPostInitCallback(function()
                            self.ui.menu:registerToMainMenu(self)
                        end)
                    end
                end)
            end
        end
    end
    
    -- If we're not in a ReaderUI context, try to auto-register when ReaderUI is created
    if not self.ui then
        self:autoRegisterWithReaderUI()
    end

    self.instapaperManager = InstapaperManager:instapaperManager()
    
    -- delegate gesture listener to readerui, use empty table instead of nil
    self.ges_events = {}
end

function ReaderInstapaper:autoRegisterWithReaderUI()
    -- Try to register ourselves with the ReaderUI when it's created
    local function checkAndRegister()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance and ReaderUI.instance.document then
            local file_path = ReaderUI.instance.document.file
            if file_path and (string.find(file_path, "/instapaper/") or string.find(file_path, "instapaper")) then
                logger.dbg("Instapaper: Auto-registering with ReaderUI")
                
                -- Create a new instance of our module
                local module_instance = ReaderInstapaper:new{
                    ui = ReaderUI.instance,
                    dialog = ReaderUI.instance,
                    view = ReaderUI.instance.view,
                    document = ReaderUI.instance.document,
                }
                
                -- Register with ReaderUI
                ReaderUI.instance:registerModule("readerinstapaper", module_instance)
                
                return true -- Stop checking
            end
        end
        return false -- Keep checking
    end
    
    -- Check immediately
    if not checkAndRegister() then
        -- If not ready yet, schedule periodic checks
        UIManager:scheduleIn(0.1, function()
            if not checkAndRegister() then
                UIManager:scheduleIn(0.5, function()
                    checkAndRegister()
                end)
            end
        end)
    end
end

function ReaderInstapaper:extractBookmarkIdFromPath(file_path)
    -- Extract bookmark_id from file path like: /path/to/instapaper/12345.html
    local bookmark_id = string.match(file_path, "/(%d+)%.html$")
    if not bookmark_id then
        -- Try alternative patterns
        bookmark_id = string.match(file_path, "instapaper[^/]*/(%d+)")
    end
    return bookmark_id
end

function ReaderInstapaper:setupTouchZones()
    if not Device:isTouchDevice() then return end
    
    -- Register a tap zone at the top of the screen to show/hide toolbar
    self.ui:registerTouchZones({
        {
            id = "instapaper_toolbar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 0.15, -- Top 15% of screen
            },
            overrides = {
                "readermenu_tap",
                "readermenu_ext_tap",
                "readerconfigmenu_tap",
                "readerconfigmenu_ext_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges) return self:onTapTopArea(ges) end,
        },
    })
end

function ReaderInstapaper:onTapTopArea(ges)
    if not self.is_instapaper_article then
        return false
    end
    
    if self.toolbar_visible then
        self:hideToolbar()
    else
        self:showToolbar()
    end
    return true
end

function ReaderInstapaper:showToolbar()
    if not self.is_instapaper_article or self.toolbar_visible then
        return
    end
    
    logger.dbg("Instapaper: Showing toolbar")
    
    local toolbar_height = Screen:scaleBySize(50)
    local button_size = Screen:scaleBySize(40)
    local screen_width = Screen:getWidth()
    local padding = Screen:scaleBySize(20)

    local function makeLabeledButton(icon, label, callback)
        local icon_widget = IconButton:new{
            icon = icon,
            width = button_size,
            height = button_size,
            callback = callback,
        }
        local label_widget = TextWidget:new{
            text = label,
            face = Font:getFace("xx_smallinfofont"),
            padding = 5,
            align = "left",
            valign = "center",
        }
        local group = HorizontalGroup:new{
            align = "center",
            icon_widget,
            label_widget,
            selectable = true,
            onTapSelect = callback,
        }
   
        
        return group
    end

    -- Create buttons
    local buttons = {
        makeLabeledButton("chevron.left", "Back", function() self:onBackToArticles() end),
        makeLabeledButton("appbar.filebrowser", "Archive", function() self:onArchiveArticle() end),
    }
    local meta = self.instapaperManager:getArticleMetadata(self.current_article.bookmark_id)
    if meta and meta.starred then
        table.insert(buttons, makeLabeledButton("star.full", "Unfavorite", function() 
            self:onUnfavoriteArticle() 
        end))
    else 
        table.insert(buttons, makeLabeledButton("star.empty", "Favorite", function() 
            self:onFavoriteArticle()
        end))
    end

    -- Calculate total button width
    local total_button_width = 0
    for _, btn in ipairs(buttons) do
        total_button_width = total_button_width + btn:getSize().w
    end

    local available_width = screen_width - 2 * padding
    local num_gaps = #buttons + 1
    local gap_width = math.max(0, math.floor((available_width - total_button_width) / num_gaps))

    -- Build toolbar items with gaps
    local toolbar_items = {}
    table.insert(toolbar_items, HorizontalSpan:new{ width = gap_width })
    for i, btn in ipairs(buttons) do
        table.insert(toolbar_items, btn)
        if i < #buttons then
            table.insert(toolbar_items, HorizontalSpan:new{ width = gap_width })
        end
    end
    table.insert(toolbar_items, HorizontalSpan:new{ width = gap_width })

    local buttons_group = HorizontalGroup:new(toolbar_items)

    -- Create toolbar container
    local toolbar_container = CenterContainer:new{
        dimen = Geom:new{
            w = screen_width,
            h = toolbar_height,
        },
        buttons_group,
    }

    -- Add background frame
    self.toolbar_widget = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        toolbar_container,
    }

    -- Position toolbar at top of screen
    self.toolbar_widget.dimen = Geom:new{
        x = 0,
        y = 0,
        w = screen_width,
        h = toolbar_height,
    }

    -- Overlay: covers everything except the toolbar area
    local overlay = InputContainer:new{}
    local screen_height = Screen:getHeight()
    overlay.selectable = true
    overlay.dimen = Geom:new{ x = 0, y = toolbar_height, w = screen_width, h = screen_height - toolbar_height }

    overlay:registerTouchZones({
        {
            id = "toolbar_hide",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            handler = function(ges)
                if ges.pos.y >= toolbar_height then
                    logger.dbg("instapaper: Tap on overlay")
                    self:hideToolbar() 
                end
            end,
        },
    })
    
    -- OverlapGroup: overlay is below, toolbar is above
    self.toolbar_root = VerticalGroup:new{
        self.toolbar_widget,
        overlay,
    }
    self.toolbar_root.dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height }

    UIManager:show(self.toolbar_root)
    self.toolbar_visible = true
end

function ReaderInstapaper:hideToolbar()
    if not self.toolbar_visible then
        return
    end
    
    logger.dbg("Instapaper: Hiding toolbar")
    
    if self.toolbar_root then
        UIManager:close(self.toolbar_root)
        self.toolbar_root = nil
        UIManager:forceRePaint()
    end
    self.toolbar_widget = nil
    self.toolbar_visible = false
end

function ReaderInstapaper:onBackToArticles()
    logger.dbg("Instapaper: Back to articles")
    self:hideToolbar()
    
    -- Close current reader and return to Instapaper plugin
    self.ui:onClose()
    
    -- Refresh the Instapaper list view if callback is provided
    if self.refresh_callback then
        UIManager:scheduleIn(0.2, function()
            self.refresh_callback()
        end)
    end
end

function ReaderInstapaper:onArchiveArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot archive: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("Instapaper: Archiving article", self.current_article.bookmark_id)
    
    -- Show loading message
    local info = InfoMessage:new{ text = _("Archiving article...") }
    UIManager:show(info)
    
    -- Perform archive action
    UIManager:nextTick(function()
        local success, error_message, did_enqueue = self.instapaperManager:archiveArticle(self.current_article.bookmark_id)
        UIManager:close(info)
        
        if success then
            UIManager:show(InfoMessage:new{
                text = (did_enqueue and "Article will be archived in next sync") or "Article archived",
                timeout = 2,
            })
            -- Return to articles list
            self:onBackToArticles()
        else
            UIManager:show(ConfirmBox:new{
                text = _("Failed to archive article: " .. error_message),
                ok_text = _("OK"),
            })
        end
    end)
end

function ReaderInstapaper:onFavoriteArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot favorite: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("Instapaper: Favoriting article", self.current_article.bookmark_id)
    
    -- Show loading message
    local info = InfoMessage:new{ text = _("Favoriting article...") }
    UIManager:show(info)
    
    -- Perform favorite action
    UIManager:nextTick(function()
        local success, error_message, did_enqueue = self.instapaperManager:favoriteArticle(self.current_article.bookmark_id)
        UIManager:close(info)
        
        if success then
            UIManager:nextTick(function()
                if self.toolbar_visible then
                    -- rerender toolbar to show the new button
                    self:hideToolbar()
                    self:showToolbar()
                end
            end)
            
            UIManager:show(InfoMessage:new{
                text = (did_enqueue and "Article will be favorited in next sync") or "Article favorited",
                timeout = 2,
            })
        else
            UIManager:show(ConfirmBox:new{
                text = _("Failed to favorite article: " .. error_message),
                ok_text = _("OK"),
            })
        end
    end)
end

function ReaderInstapaper:onUnfavoriteArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot unfavorite: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("Instapaper: Unfavoriting article", self.current_article.bookmark_id)
    
    -- Show loading message
    local info = InfoMessage:new{ text = _("Unfavoriting article...") }
    UIManager:show(info)
    
    -- Perform favorite action
    UIManager:nextTick(function()
        local success, error_message, did_enqueue = self.instapaperManager:unfavoriteArticle(self.current_article.bookmark_id)
        UIManager:close(info)
        
        if success then
            UIManager:nextTick(function()
                if self.toolbar_visible then
                    -- rerender toolbar to show the new button
                    self:hideToolbar()
                    self:showToolbar()
                end
            end)
            
            UIManager:show(InfoMessage:new{
                text = (did_enqueue and "Article will be unfavorited in next sync") or "Article unfavorited",
                timeout = 2,
            })
        else
            UIManager:show(ConfirmBox:new{
                text = _("Failed to unfavorite article: " .. error_message),
                ok_text = _("OK"),
            })
        end
    end)
end

local function showInstapaperEndOfBookDialog(self)
    local button_dialog
    button_dialog = ButtonDialog:new{
        name = "end_document_instapaper",
        title = _("You've reached the end of the article."),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Archive"),
                    callback = function()
                        UIManager:close(button_dialog)
                        if self.ui.readerinstapaper then
                            self.ui.readerinstapaper:onArchiveArticle()
                        end
                    end,
                },
                {
                    text = _("Return to list"),
                    callback = function()
                        UIManager:close(button_dialog)
                        if self.ui.readerinstapaper then
                            self.ui.readerinstapaper:onBackToArticles()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(button_dialog)
end

-- Monkey patch ReaderStatus:onEndOfBook for Instapaper UI
local orig_onEndOfBook = ReaderStatus.onEndOfBook
function ReaderStatus:onEndOfBook(...)
    if self.ui and self.ui.readerinstapaper and self.ui.readerinstapaper.name == "readerreaderinstapaper" then
        showInstapaperEndOfBookDialog(self)
    else
        orig_onEndOfBook(self, ...)
    end
end


function ReaderInstapaper:onClose()
    self:hideToolbar()
    
    -- Refresh the Instapaper list view if callback is provided
    if self.refresh_callback then
        UIManager:scheduleIn(0.2, function()
            self.refresh_callback()
        end)
    end
end

return ReaderInstapaper 