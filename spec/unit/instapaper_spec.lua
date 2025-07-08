describe("Instapaper offline queueing", function()
    setup(function()
        require("commonrequire")
        
    end)

    local InstapaperManager, InstapaperAPIManager, NetworkMgr, orig_isOnline

    setup(function()
        package.path = "plugins/ereader.koplugin/?.lua;" .. package.path
        InstapaperManager = require("InstapaperManager")
        InstapaperAPIManager = require("lib/instapaperapimanager")
        NetworkMgr = require("ui/network/manager")
        -- Patch NetworkMgr for mocking
        orig_isOnline = NetworkMgr.isOnline
    end)

    teardown(function()
        -- Restore original NetworkMgr
        if orig_isOnline then
            NetworkMgr.isOnline = orig_isOnline
        end
    end)

    it("should queue requests when offline and process them when online", function()
        -- Create a fresh API manager instance
        local api_manager = InstapaperAPIManager:instapaperAPIManager()
        -- Clear any existing queue
        api_manager:cleanAll()
        assert.are.same({}, api_manager.queued_requests)

        -- Mock authentication
        api_manager.oauth_token = "dummy_token"
        api_manager.oauth_token_secret = "dummy_secret"

        -- Simulate offline
        NetworkMgr.isOnline = function() return false end

        -- Add an article (should be queued)
        local url = "https://example.com/article"
        local success, err, did_enqueue = api_manager:addArticle(url)
        assert.is_true(success)
        assert.is_nil(err)
        assert.is_true(did_enqueue or #api_manager.queued_requests > 0)
        assert.equals(1, #api_manager.queued_requests)
        assert.equals(url, api_manager.queued_requests[1].params.url)

        -- Simulate online
        NetworkMgr.isOnline = function() return true end
        -- Mock executeRequest to always succeed
        local orig_executeRequest = api_manager.executeRequest
        api_manager.executeRequest = function() return true, "OK", nil end

        -- Process queued requests
        local errors = api_manager:processQueuedRequests()
        assert.are.same({}, errors)
        assert.equals(0, #api_manager.queued_requests)

        -- Restore
        api_manager.executeRequest = orig_executeRequest
    end)

    it("should serialize and deserialize the offline queue correctly", function()
        local api_manager = InstapaperAPIManager:instapaperAPIManager()
        api_manager:cleanAll()
        assert.are.same({}, api_manager.queued_requests)

        -- Add a fake request to the queue
        local queued_request = {
            url = "https://example.com/api",
            params = { foo = "bar", num = 42 },
            timestamp = os.time(),
        }
        table.insert(api_manager.queued_requests, queued_request)
        api_manager:saveQueue(api_manager.queued_requests)

        -- Clear in-memory queue
        api_manager.queued_requests = {}
        assert.equals(0, #api_manager.queued_requests)

        -- Reload from storage
        local loaded_queue = api_manager:loadQueue()
        assert.equals(1, #loaded_queue)
        assert.equals(queued_request.url, loaded_queue[1].url)
        assert.same(queued_request.params, loaded_queue[1].params)
        assert.equals(queued_request.timestamp, loaded_queue[1].timestamp)
    end)

    it("should not crash when socket.skip returns a string error code", function()
        local api_manager = InstapaperAPIManager:instapaperAPIManager()
        api_manager.oauth_token = "dummy_token"
        api_manager.oauth_token_secret = "dummy_secret"
        -- Mock NetworkMgr to be online
        NetworkMgr.isOnline = function() return true end
        -- Patch socket.skip to return a string error code
        local socket = require("socket")
        local orig_skip = socket.skip
        socket.skip = function() return "string_error_code", nil, nil end
        -- Try to add an article (triggers executeQueueableRequest -> executeRequest)
        local ok, err = api_manager:addArticle("https://example.com/test")
        -- The test is successful if it does not crash
        assert.is_false(ok)
        assert.is_string(err)
        -- Restore
        socket.skip = orig_skip
    end)

    describe("article downloading", function()
        local InstapaperManager, InstapaperAPIManager, NetworkMgr, orig_isOnline, orig_getArticleText, orig_downloadImage, orig_storeArticle, orig_getArticleHTML, orig_getArticle, orig_storeArticleMetadata, orig_isAuthenticated
        local dummy_bookmark_id = 12345
        local dummy_article = {
            bookmark_id = dummy_bookmark_id,
            title = "Test Article",
            url = "https://example.com/test",
            starred = false,
            type = nil,
            time = os.time(),
            time_updated = os.time(),
            word_count = 100,
            reading_time = 1
        }
        before_each(function()
            package.path = "plugins/ereader.koplugin/?.lua;" .. package.path
            InstapaperManager = require("InstapaperManager"):instapaperManager()
            InstapaperAPIManager = require("lib/instapaperapimanager")
            NetworkMgr = require("ui/network/manager")
            -- Patch NetworkMgr for mocking
            orig_isOnline = NetworkMgr.isOnline
            NetworkMgr.isOnline = function() return true end
            -- Patch API and storage methods
            orig_getArticleText = InstapaperManager.instapaper_api_manager.getArticleText
            orig_downloadImage = InstapaperManager.downloadImageWithFallback
            orig_storeArticle = InstapaperManager.storage.storeArticle
            orig_getArticleHTML = InstapaperManager.storage.getArticleHTML
            orig_getArticle = InstapaperManager.storage.getArticle
            orig_storeArticleMetadata = InstapaperManager.storage.storeArticleMetadata
            -- Clean storage
            InstapaperManager.storage:clearAll()
            orig_isAuthenticated = InstapaperManager.isAuthenticated
            InstapaperManager.isAuthenticated = function() return true end
        end)
        after_each(function()
            NetworkMgr.isOnline = orig_isOnline
            InstapaperManager.instapaper_api_manager.getArticleText = orig_getArticleText
            InstapaperManager.downloadImageWithFallback = orig_downloadImage
            InstapaperManager.storage.storeArticle = orig_storeArticle
            InstapaperManager.storage.getArticleHTML = orig_getArticleHTML
            InstapaperManager.storage.getArticle = orig_getArticle
            InstapaperManager.storage.storeArticleMetadata = orig_storeArticleMetadata
            InstapaperManager.storage:clearAll()
            InstapaperManager.isAuthenticated = orig_isAuthenticated
        end)

        it("downloads and stores a new article", function()
            -- Simulate article metadata in DB
            InstapaperManager.storage:storeArticleMetadata(dummy_article)
            -- Mock API to return HTML
            InstapaperManager.instapaper_api_manager.getArticleText = function(_, bookmark_id)
                assert.equals(dummy_bookmark_id, bookmark_id)
                return true, "<body>hello world</body>", nil
            end
            -- Mock image download to do nothing
            InstapaperManager.downloadImageWithFallback = function() return nil, nil end
            -- Spy on storeArticle
            local stored_html
            InstapaperManager.storage.storeArticle = function(_, meta, html)
                stored_html = html
                return true, "test.html"
            end
            -- Download
            local ok, article = InstapaperManager:downloadArticle(dummy_bookmark_id)
            assert.is_true(ok)
            assert.is_table(article)
            assert.is_truthy(stored_html)
            assert.matches("hello world", stored_html)
        end)

        it("downloads images and updates HTML to use local data URI", function()
            InstapaperManager.storage:storeArticleMetadata(dummy_article)
            -- HTML with image
            local img_url = "https://example.com/image.jpg"
            InstapaperManager.instapaper_api_manager.getArticleText = function(_, bookmark_id)
                return true, '<body><img src="'..img_url..'">hello</body>', nil
            end
            -- Mock image download to return dummy data
            InstapaperManager.downloadImageWithFallback = function(_, url)
                assert.equals(img_url, url)
                return "imagedata", "image/jpeg"
            end
            -- Spy on storeArticle
            local stored_html
            InstapaperManager.storage.storeArticle = function(_, meta, html)
                stored_html = html
                return true, "test.html"
            end
            -- Download
            local ok, article = InstapaperManager:downloadArticle(dummy_bookmark_id)
            assert.is_true(ok)
            assert.is_table(article)
            assert.is_truthy(stored_html)
            assert.matches("data:image/jpeg;base64", stored_html)
            assert.not_matches(img_url, stored_html)
        end)

        it("returns already stored article from filesystem without re-downloading", function()
            -- Simulate article and HTML already stored
            InstapaperManager.storage:storeArticleMetadata(dummy_article)
            local html_content = "<body>cached content</body>"
            InstapaperManager.storage.storeArticle = function() error("should not be called") end
            InstapaperManager.instapaper_api_manager.getArticleText = function() error("should not be called") end
            InstapaperManager.storage.getArticle = function(_, bookmark_id)
                return {
                    bookmark_id = bookmark_id,
                    title = dummy_article.title,
                    url = dummy_article.url,
                    html_filename = "test.html"
                }
            end
            InstapaperManager.storage.getArticleHTML = function(_, filename)
                assert.equals("test.html", filename)
                return html_content
            end
            -- Download
            local ok, article = InstapaperManager:downloadArticle(dummy_bookmark_id)
            assert.is_true(ok)
            assert.is_table(article)
            assert.equals(html_content, article.html)
        end)
    end)
end) 