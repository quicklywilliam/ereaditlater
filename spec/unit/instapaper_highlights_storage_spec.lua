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
end) 