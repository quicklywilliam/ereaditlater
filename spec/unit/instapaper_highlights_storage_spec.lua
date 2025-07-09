describe("Instapaper highlights storage", function()
    setup(function()
        require("commonrequire")
    end)

    local InstapaperManager, Storage
    local lfs = require("libs/libkoreader-lfs")

    setup(function()
        package.path = "plugins/ereader.koplugin/?.lua;" .. package.path
        InstapaperManager = require("InstapaperManager")
        Storage = require("lib/storage")
    end)

    it("should store and retrieve highlights from database", function()
        -- Create a fresh storage instance
        local storage = Storage:new()
        storage:init()
        
        -- Clear any existing data
        storage:clearAll()
        
        -- Load mock highlights data
        local highlights_file = "spec/front/unit/data/ereader/12345_highlights.json"
        local file = io.open(highlights_file, "r")
        assert.is_not_nil(file, "Failed to open highlights file: " .. highlights_file)
        local highlights_json = file:read("*all")
        file:close()
        
        -- Parse the JSON
        local JSONUtils = require("lib/json_utils")
        local highlights = JSONUtils.decode(highlights_json)
        local success = highlights ~= nil
        assert.is_true(success, "Failed to parse highlights JSON: " .. tostring(highlights))
        assert.is_table(highlights, "Highlights should be a table")
        assert.is_true(#highlights > 0, "Highlights array should not be empty")
        
        -- Test storing highlights
        local bookmark_id = 12345
        local store_success = storage:storeHighlights(bookmark_id, highlights)
        assert.is_true(store_success, "Failed to store highlights")
        
        -- Test retrieving highlights
        local retrieved_highlights = storage:getHighlights(bookmark_id)
        assert.is_table(retrieved_highlights, "Retrieved highlights should be a table")
        assert.equals(#highlights, #retrieved_highlights, "Number of highlights should match")
        
        -- Verify the first highlight structure
        local original_highlight = highlights[1]
        local retrieved_highlight = retrieved_highlights[1]
        assert.equals(original_highlight.highlight_id, retrieved_highlight.highlight_id, "Highlight ID should match")
        assert.equals(original_highlight.text, retrieved_highlight.text, "Highlight text should match")
        
        assert.equals(original_highlight.note, retrieved_highlight.note, "Highlight note should match")
        
        assert.equals(original_highlight.position, retrieved_highlight.position, "Highlight position should match")
        assert.equals(bookmark_id, retrieved_highlight.bookmark_id, "Bookmark ID should match")
        assert.is_not_nil(retrieved_highlight.time_created, "Time created should not be nil")
        assert.is_not_nil(retrieved_highlight.time_updated, "Time updated should not be nil")
        assert.equals("synced", retrieved_highlight.sync_status, "Sync status should be 'synced'")
        
        -- Test getting all highlights
        local all_highlights = storage:getAllHighlights()
        assert.is_table(all_highlights, "All highlights should be a table")
        assert.equals(#highlights, #all_highlights, "Total highlights count should match")
        
        -- Test deleting highlights
        local delete_success = storage:deleteHighlights(bookmark_id)
        assert.is_true(delete_success, "Failed to delete highlights")
        
        -- Verify highlights are deleted
        local empty_highlights = storage:getHighlights(bookmark_id)
        assert.equals(0, #empty_highlights, "Highlights should be empty after deletion")
        
        -- Clean up
        storage:clearAll()
    end)

    it("should handle empty highlights gracefully", function()
        local storage = Storage:new()
        storage:init()
        storage:clearAll()
        
        local bookmark_id = 12345
        
        -- Test storing empty highlights
        local store_success = storage:storeHighlights(bookmark_id, {})
        assert.is_true(store_success, "Should handle empty highlights")
        
        -- Test storing nil highlights
        local store_success2 = storage:storeHighlights(bookmark_id, nil)
        assert.is_true(store_success2, "Should handle nil highlights")
        
        -- Verify no highlights were stored
        local highlights = storage:getHighlights(bookmark_id)
        assert.equals(0, #highlights, "Should have no highlights for empty input")
        
        storage:clearAll()
    end)

    it("should handle pending and pending_delete highlights correctly", function()
        local storage = Storage:new()
        storage:init()
        storage:clearAll()

        -- Insert a pending highlight
        local pending = {
            bookmark_id = 111,
            text = "Pending highlight text",
            note = "Pending note",
            position = 0,
            time_created = os.time(),
            time_updated = os.time(),
            sync_status = "pending"
        }
        local ok, err = storage:savePendingHighlight(pending)
        assert.is_true(ok, "Failed to save pending highlight: " .. tostring(err))

        -- Insert a pending_delete highlight
        local pending_delete = {
            bookmark_id = 222,
            text = "Pending delete text",
            note = "Pending delete note",
            position = 1,
            time_created = os.time(),
            time_updated = os.time(),
            sync_status = "synced"
        }
        ok, err = storage:savePendingHighlight(pending_delete)
        assert.is_true(ok, "Failed to save highlight for pending_delete: " .. tostring(err))
        -- Mark as pending_delete
        local all = storage:getAllHighlights()
        local pd_id
        for _, h in ipairs(all) do
            if h.text == "Pending delete text" then pd_id = h.id end
        end
        assert.is_not_nil(pd_id, "Failed to find highlight for pending_delete")
        ok, err = storage:markHighlightPendingDelete(pd_id)
        assert.is_true(ok, "Failed to mark highlight as pending_delete: " .. tostring(err))

        -- Test getPendingHighlights
        local pending_highlights = storage:getPendingHighlights()
        assert.is_table(pending_highlights, "getPendingHighlights should return a table")
        assert.equals(2, #pending_highlights, "Should return both pending and pending_delete highlights")
        local found_pending, found_pending_delete = false, false
        for _, h in ipairs(pending_highlights) do
            if h.sync_status == "pending" then found_pending = true end
            if h.sync_status == "pending_delete" then found_pending_delete = true end
        end
        assert.is_true(found_pending, "Should find pending highlight")
        assert.is_true(found_pending_delete, "Should find pending_delete highlight")

        -- Test markHighlightSynced
        local id_to_sync
        for _, h in ipairs(pending_highlights) do
            if h.sync_status == "pending" then id_to_sync = h.id end
        end
        ok, err = storage:markHighlightSynced(id_to_sync, 9999)
        assert.is_true(ok, "Failed to mark highlight as synced: " .. tostring(err))
        local all2 = storage:getAllHighlights()
        local synced = false
        for _, h in ipairs(all2) do
            if h.id == id_to_sync and h.sync_status == "synced" and h.highlight_id == 9999 then synced = true end
        end
        assert.is_true(synced, "Highlight should be marked as synced with correct highlight_id")

        -- Test deleteHighlightById
        ok, err = storage:deleteHighlightById(id_to_sync)
        assert.is_true(ok, "Failed to delete highlight by id: " .. tostring(err))
        local all3 = storage:getAllHighlights()
        local still_exists = false
        for _, h in ipairs(all3) do
            if h.id == id_to_sync then still_exists = true end
        end
        assert.is_false(still_exists, "Highlight should be deleted from DB")

        storage:clearAll()
    end)
end) 