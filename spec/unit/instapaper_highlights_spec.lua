describe("Instapaper highlights API (mocked)", function()
    setup(function()
        require("commonrequire")
    end)

    local InstapaperManager, InstapaperAPIManager
    local lfs = require("libs/libkoreader-lfs")

    setup(function()
        package.path = "plugins/ereader.koplugin/?.lua;" .. package.path
        InstapaperManager = require("InstapaperManager")
        InstapaperAPIManager = require("lib/instapaperapimanager")
    end)

    it("should fetch highlights for an article # 12345 and validate response (mocked)", function()
        -- Path to the mock highlights file
        local highlights_file = "spec/front/unit/data/ereader/12345_highlights.json"
        local file = io.open(highlights_file, "r")
        assert.is_not_nil(file, "Failed to open highlights file: " .. highlights_file)
        local highlights_response = file:read("*all")
        file:close()
        
        -- Patch executeRequest to return the file contents as a successful HTTP response
        local api_manager = InstapaperAPIManager:instapaperAPIManager()
        local orig_executeRequest = api_manager.executeRequest
        

        api_manager.oauth_token = "dummy_token"
        api_manager.oauth_token_secret = "dummy_secret"
        
        api_manager.executeRequest = function(_, ...)
            return true, highlights_response, nil
        end

        -- Call the real getHighlights
        local success, response, error_message = api_manager:getHighlights(12345)
        
        -- Restore original executeRequest
        api_manager.executeRequest = orig_executeRequest

        assert.is_true(success, "Mocked API call failed: " .. (error_message or "unknown error"))
        assert.is_table(response, "Response should be a table")
        assert.is_true(#response > 0, "Response should not be empty")

    end)
end) 