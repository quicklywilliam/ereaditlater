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

local ReaderEreader = InputContainer:extend{
    name = "readerereader",
    is_ereader_document = false,
    current_article = nil,
    toolbar_visible = false,
    toolbar_widget = nil,
}

function ReaderEreader:init()
    self.instapaperManager = InstapaperManager:instapaperManager()

    if self.ui and self.ui.document and self.ui.document.file then

        local file_path = self.ui.document.file
        if string.find(file_path, "/ereader/") or string.find(file_path, "ereader") then
            self.is_ereader_document = true
            logger.dbg("ereader: Detected Instapaper article:", file_path)
            
            -- Extract bookmark_id from file path for API calls
            local bookmark_id = self:extractBookmarkIdFromPath(file_path)
            if bookmark_id then
                self.current_article = { bookmark_id = bookmark_id }
                logger.dbg("ereader: Extracted bookmark_id:", bookmark_id)
            end
            
            -- Register touch zones for showing/hiding toolbar
            self:setupTouchZones()
            
            -- Safely register to main menu - check if ReaderEreader is ready
            if self.ui.postInitCallback then
                -- ReaderEreader is ready, register immediately
                self.ui:registerPostInitCallback(function()
                    self.ui.menu:registerToMainMenu(self)
                end)
            else
                -- ReaderEreader not ready yet, schedule for later
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
    
    -- If we're not in a ReaderEreader context, try to auto-register when ReaderEreader is created
    if not self.ui then
        self:autoRegisterWithReaderUI()
    end
    
    -- delegate gesture listener to ReaderEreader, use empty table instead of nil
    self.ges_events = {}
end

function ReaderEreader:autoRegisterWithReaderUI()
    -- Try to register ourselves with the ReaderEreader when it's created
    local function checkAndRegister()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance and ReaderUI.instance.document then
            local file_path = ReaderUI.instance.document.file
            if file_path and (string.find(file_path, "/ereader/") or string.find(file_path, "ereader")) then
                logger.dbg("ereader: Auto-registering with ReaderUI")
                
                -- Create a new instance of our module
                local module_instance = ReaderEreader:new{
                    ui = ReaderUI.instance,
                    dialog = ReaderUI.instance,
                    view = ReaderUI.instance.view,
                    document = ReaderUI.instance.document,
                }
                
                -- Register with ReaderEreader
                ReaderUI.instance:registerModule("readerereader", module_instance)
                
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

function ReaderEreader:extractBookmarkIdFromPath(file_path)
    -- Extract bookmark_id from file path like: /path/to/ereader/12345.html
    local bookmark_id = string.match(file_path, "/(%d+)%.html$")
    if not bookmark_id then
        -- Try alternative patterns
        bookmark_id = string.match(file_path, "ereader[^/]*/(%d+)")
    end
    return bookmark_id
end

function ReaderEreader:setupTouchZones()
    if not Device:isTouchDevice() then return end
    
    -- Register a tap zone at the top of the screen to show/hide toolbar
    self.ui:registerTouchZones({
        {
            id = "ereader_toolbar_tap",
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

function ReaderEreader:onTapTopArea(ges)
    if not self.is_ereader_document then
        return false
    end
    
    if self.toolbar_visible then
        self:hideToolbar()
    else
        self:showToolbar()
    end
    return true
end

function ReaderEreader:showToolbar()
    if not self.is_ereader_document or self.toolbar_visible then
        return
    end
    
    logger.dbg("ereader: Showing toolbar")
    
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
                    logger.dbg("ereader: Tap on overlay")
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

function ReaderEreader:hideToolbar()
    if not self.toolbar_visible then
        return
    end
    
    logger.dbg("ereader: Hiding toolbar")
    
    if self.toolbar_root then
        UIManager:close(self.toolbar_root)
        self.toolbar_root = nil
        UIManager:forceRePaint()
    end
    self.toolbar_widget = nil
    self.toolbar_visible = false
end

function ReaderEreader:onBackToArticles()
    logger.dbg("ereader: Back to articles")

    -- Close current reader and return to ereader plugin
    self:onClose()
    self.ui:onClose()
end

function ReaderEreader:onArchiveArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot archive: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("ereader: Archiving article", self.current_article.bookmark_id)
    
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

function ReaderEreader:onFavoriteArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot favorite: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("ereader: Favoriting article", self.current_article.bookmark_id)
    
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

function ReaderEreader:onUnfavoriteArticle()
    if not self.current_article or not self.current_article.bookmark_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot unfavorite: article not found"),
            timeout = 2,
        })
        return
    end
    
    logger.dbg("ereader: Unfavoriting article", self.current_article.bookmark_id)
    
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

function ReaderEreader:loadHighlights()
    if not self.current_article or not self.current_article.bookmark_id then
        logger.warn("ereader: No current article or bookmark_id for loading highlights")
        return
    end
    
    -- Remove existing Instapaper highlights before adding new ones
    if self.ui and self.ui.annotation and self.ui.annotation.annotations then
        logger.dbg("ereader: Remove existing highlights")
        for i = #self.ui.annotation.annotations, 1, -1 do
            if self.ui.annotation.annotations[i].is_from_ereader then
                table.remove(self.ui.annotation.annotations, i)
            end
        end
    end
    
    local highlights = self.instapaperManager:getStoredArticleHighlights(self.current_article.bookmark_id)
    if not highlights or #highlights == 0 then
        logger.dbg("ereader: No stored highlights to load for bookmark_id:", self.current_article.bookmark_id)
        return
    end
    for _, ereader_highlight in ipairs(highlights) do
        local search_results = self.ui.document:findAllText(ereader_highlight.text, false, 0, 100, false)
        local pos = tonumber(ereader_highlight.position)
        if search_results and pos and pos >= 0 and search_results[pos + 1] then
            local result = search_results[pos + 1]
            local start_xp = result.start
            local end_xp = result["end"]
            local chapter = nil
            if self.ui.toc then
                local page = self.ui.document:getPageFromXPointer(start_xp)
                if page then
                    chapter = self.ui.toc:getTocTitleByPage(page)
                end
            end
            local datetime = ereader_highlight.timestamp
            if datetime and type(datetime) == "number" then
                datetime = os.date("%Y-%m-%d %H:%M:%S", datetime)
            elseif not datetime then
                datetime = os.date("%Y-%m-%d %H:%M:%S")
            end
            local page_number = self.ui.document:getPageFromXPointer(start_xp)
            local annotation = {
                drawer = "lighten",
                page = start_xp,
                pos0 = start_xp,
                pos1 = end_xp,
                pageno = page_number,
                text = ereader_highlight.text,
                chapter = chapter,
                datetime = datetime,
                note = ereader_highlight.note,
                color = "yellow",
                is_from_ereader = true,
                ereader_highlight_id = ereader_highlight.id, -- keep track of ereader's id so we can match it later
            }
            if self.ui.annotation and self.ui.annotation.addItem then
                self.ui.annotation:addItem(annotation)
            end
        else
            logger.warn("ereader: Could not find occurrence #" .. tostring(pos) .. " of text '" .. tostring(ereader_highlight.text) .. "' in document for highlight.")
        end
    end
    logger.dbg("ereader: Loaded", #highlights, "highlights for bookmark_id:", self.current_article.bookmark_id)
    if self.ui and self.ui.view then
        UIManager:setDirty(self.ui.view.dialog, "ui")
    end
end

function ReaderEreader:convertAnnotationToPendingHighlight(annotation)
    local bookmark_id = self.current_article and tonumber(self.current_article.bookmark_id)
    if not bookmark_id then
        logger.warn("ereader: No valid bookmark_id for annotation, skipping save.")
        return nil
    end

    -- Find the incident index (position) of this highlight in the document
    local text = annotation.text
    local pos0 = annotation.pos0 or annotation.page
    local position = nil
    if text and pos0 and self.ui and self.ui.document then
        local search_results = self.ui.document:findAllText(text, false, 0, 100, false)
        for idx, result in ipairs(search_results or {}) do
            if result.start == pos0 then
                position = idx - 1  -- Instapaper uses 0-based index
                break
            end
        end
    end
    -- Fallback if not found
    if not position then position = 0 end

    -- Convert datetime string to timestamp if needed
    local time_created = annotation.datetime
    if type(time_created) == "string" then
        local y, m, d, H, M, S = string.match(time_created, "(\\d+)%-(\\d+)%-(\\d+) (\\d+):(\\d+):(\\d+)")
        if y and m and d and H and M and S then
            time_created = os.time{year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=tonumber(H), min=tonumber(M), sec=tonumber(S)}
        else
            time_created = os.time()
        end
    elseif type(time_created) ~= "number" then
        time_created = os.time()
    end

    return {
        bookmark_id = bookmark_id,
        text = annotation.text,
        note = annotation.note,
        position = position,
        time_created = time_created,
        time_updated = os.time(),
        sync_status = "pending",
    }
end

-- Update saveHighlights to use the conversion
function ReaderEreader:syncAnnotationsWithEreaderHighlights()
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations) then
        return
    end
    logger.dbg("ereader: syncAnnotationsWithEreaderHighlights")
    local annotations = self.ui.annotation.annotations
    local bookmark_id = self.current_article and tonumber(self.current_article.bookmark_id)
    if not bookmark_id then
        logger.warn("ereader: No valid bookmark_id for annotation sync, aborting.")
        return
    end
    -- Fetch all ereader highlights for this article
    local ereader_highlights = self.instapaperManager:getStoredArticleHighlights(bookmark_id)
    -- Build a map from ereader_highlight_id to highlight object
    local ereader_highlights_by_id = {}
    for _, local_hl in ipairs(ereader_highlights) do
        if local_hl.id then
            ereader_highlights_by_id[tostring(local_hl.id)] = local_hl
        end
    end
    for i = #annotations, 1, -1 do
        local ann = annotations[i]
        if ann.drawer == "highlight" or ann.drawer == "lighten" then
            if ann.ereader_highlight_id then
                ereader_highlights_by_id[tostring(ann.ereader_highlight_id)] = nil
            else
                -- If no ereader_highlight_id is set, it needs to be saved as a pending highlight
                if not ann.is_from_ereader then
                    logger.dbg("ereader: Found unsynced highlight, saving as pending", ann.text)
                    local pending = self:convertAnnotationToPendingHighlight(ann)
                    if pending then
                        local ok, err = pcall(function()
                            self.instapaperManager:savePendingHighlight(pending)
                        end)
                        if not ok then
                            logger.warn("ereader: Failed to save pending highlight:", err)
                        end
                    end
                else
                    logger.warn("ereader: Annotation marked as from ereader but missing ereader_highlight_id…", ann.text)
                end
            end
        end
    end
    
    -- Any highlights remaining in ereader_highlights_by_id no longer have corresponding annotations, which means the user deleted them.
    for _, local_hl in pairs(ereader_highlights_by_id) do
        logger.dbg("ereader: Deleting local highlight not present in UI:", local_hl.text)
        pcall(function()
            self.instapaperManager:deleteHighlight(local_hl)
        end)
    end
end

local function showEreaderEndOfBookDialog(self)
    local button_dialog
    button_dialog = ButtonDialog:new{
        name = "end_document_ereader",
        title = _("You've reached the end of the article."),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Archive"),
                    callback = function()
                        UIManager:close(button_dialog)
                        if self.ui.readerereader then
                            self.ui.readerereader:onArchiveArticle()
                        end
                    end,
                },
                {
                    text = _("Return to list"),
                    callback = function()
                        UIManager:close(button_dialog)
                        if self.ui.readerereader then
                            self.ui.readerereader:onBackToArticles()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(button_dialog)
end

-- Monkey patch ReaderStatus:onEndOfBook for ReaderEreader UI
local orig_onEndOfBook = ReaderStatus.onEndOfBook
function ReaderStatus:onEndOfBook(...)
    if self.ui and self.ui.readerereader and self.ui.readerereader.name == "readerreaderereader" then
        showEreaderEndOfBookDialog(self)
    else
        orig_onEndOfBook(self, ...)
    end
end


-- Call syncHighlightsWithEreaderStorage from onClose
function ReaderEreader:onClose()
    logger.dbg("ereader: onClose")
    self:syncAnnotationsWithEreaderHighlights()
    self:hideToolbar()
    -- Refresh the Ereader list view if callback is provided
    if self.refresh_callback then
        UIManager:scheduleIn(0.2, function()
            self.refresh_callback()
        end)
    end
end

return ReaderEreader