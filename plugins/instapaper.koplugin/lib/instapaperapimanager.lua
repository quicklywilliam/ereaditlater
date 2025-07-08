local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local sha2 = require("ffi/sha2")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local JSON = require("json")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local InstapaperAPIManager = {}
local _instance = nil

-- Settings storage is currently used for auth credentials
local function getSettings()
    local settings = LuaSettings:open(DataStorage:getSettingsDir().."/ereader.lua")
    settings:readSetting("ereader", {})
    return settings
end

-- Generic settings methods
local function getSetting(key, default)
    local settings = getSettings()
    local data = settings.data.ereader or {}
    return data[key] ~= nil and data[key] or default
end

local function setSetting(key, value)
    local settings = getSettings()
    local data = settings.data.ereader or {}
    data[key] = value
    settings:saveSetting("ereader", data)
    settings:flush()
end

local function delSetting(key)
    local settings = getSettings()
    local data = settings.data.ereader or {}
    data[key] = nil
    settings:saveSetting("ereader", data)
    settings:flush()
end

function InstapaperAPIManager:instapaperAPIManager()
    -- Return existing instance if it exists
    if _instance then
        return _instance
    end
    
    local api_manager = {}

    -- Load API keys
    local consumer_key, consumer_secret = self:loadApiKeys()
    if not consumer_key or not consumer_secret then
        logger.err("ereader: Failed to load API keys")
        return nil
    end
    
    api_manager.consumer_key = consumer_key
    api_manager.consumer_secret = consumer_secret
    api_manager.api_base = "https://www.instapaper.com"
    api_manager.ACCESS_TOKEN_URL = api_manager.api_base .. "/api/1/oauth/access_token"
    
    -- Load stored user tokens
    api_manager.oauth_token, api_manager.oauth_token_secret = self:loadTokens()
    api_manager.username = self:loadUsername()
    
    setmetatable(api_manager, self)
    self.__index = self

    -- Initialize queue
    api_manager.queued_requests = self:loadQueue()
    
    -- Store the singleton instance
    _instance = api_manager
    
    return api_manager
end

-- Queue management functions
function InstapaperAPIManager:getQueueSettings()
    return LuaSettings:open(DataStorage:getSettingsDir().."/instapaper/queue.lua")
end

function InstapaperAPIManager:saveQueue(queue)
    local settings = self:getQueueSettings()
    settings:saveSetting("queued_requests", queue)
    settings:flush()
end

function InstapaperAPIManager:loadQueue()
    local settings = self:getQueueSettings()
    return settings:readSetting("queued_requests") or {}
end


-- Token management methods
function InstapaperAPIManager:loadTokens()
    return getSetting("instapaper_oauth_token"), getSetting("oauth_token_secret")
end

function InstapaperAPIManager:loadUsername()
    return getSetting("instapaper_username")
end

function InstapaperAPIManager:saveTokens(oauth_token, oauth_token_secret)
    setSetting("instapaper_oauth_token", oauth_token)
    setSetting("instapaper_oauth_token_secret", oauth_token_secret)
    self.oauth_token = oauth_token
    self.oauth_token_secret = oauth_token_secret
end

function InstapaperAPIManager:saveUsername(username)
    setSetting("instapaper_username", username)
    self.username = username
end

function InstapaperAPIManager:cleanAll()
    delSetting("instapaper_oauth_token")
    delSetting("instapaper_oauth_token_secret")
    delSetting("instapaper_username")
    self.oauth_token = nil
    self.oauth_token_secret = nil
    self.username = nil

    -- clear request queueu
    self.queued_requests = {}
    self:saveQueue(self.queued_requests)
end

function InstapaperAPIManager:isAuthenticated()
    return self.oauth_token ~= nil and self.oauth_token_secret ~= nil
end

function InstapaperAPIManager:getUsername()
    return self.username
end

-- Load API keys with fallback support
function InstapaperAPIManager:loadApiKeys()
    local secrets = require("lib/ffi_secrets")
    local consumer_key, consumer_secret = secrets.get_secrets()
    
    if not consumer_key or not consumer_secret then
        logger.err("ereader: Failed to load API keys from any source")
        return nil, nil
    end
    
    return consumer_key, consumer_secret
end

function InstapaperAPIManager:generateTimestamp()
    return tostring(os.time())
end

function InstapaperAPIManager:generateNonce()
    -- Generate a random 32-character alphanumeric string
    local nonce = {}
    for i = 1, 32 do
        local char = math.random(0, 61)
        if char < 10 then
            table.insert(nonce, string.char(char + 48))  -- 0-9
        elseif char < 36 then
            table.insert(nonce, string.char(char + 55))  -- A-Z
        else
            table.insert(nonce, string.char(char + 61))  -- a-z
        end
    end
    return table.concat(nonce)
end

function InstapaperAPIManager:percentEncode(str)
    if not str then return "" end
    
    -- Convert to string if not already
    str = tostring(str)
    
    -- OAuth 1.0a requires double encoding of certain characters
    local encoded = str:gsub("([^A-Za-z0-9%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    
    return encoded
end

function InstapaperAPIManager:generateSignatureBaseString(method, url, params)
    -- Sort parameters alphabetically for all requests
    local sorted_params = {}
    for key, value in pairs(params) do
        table.insert(sorted_params, {key = key, value = value})
    end
    
    table.sort(sorted_params, function(a, b) return a.key < b.key end)
    
    -- Build parameter string in alphabetical order
    local param_string = {}
    for _, param in ipairs(sorted_params) do
        table.insert(param_string, self:percentEncode(param.key) .. "=" .. self:percentEncode(param.value))
    end
    
    -- Build signature base string
    local base_string = string.upper(method) .. "&" ..
           self:percentEncode(url) .. "&" ..
           self:percentEncode(table.concat(param_string, "&"))

    
    return base_string
end

function InstapaperAPIManager:signRequest(method, url, params, consumer_secret, token_secret)
    -- Generate signature base string
    local base_string = self:generateSignatureBaseString(method, url, params)
    
    -- Create signing key
    local encoded_consumer = self:percentEncode(consumer_secret)
    local encoded_token = token_secret and self:percentEncode(token_secret) or ""
    local signing_key = encoded_consumer .. "&" .. encoded_token

    
    local sha2 = require("ffi/sha2")
    local hex_result = sha2.hmac(sha2.sha1, signing_key, base_string)
    local signature = sha2.hex_to_bin(hex_result)
    
    -- Base64 encode the signature
    local encoded = sha2.bin_to_base64(signature)
        
    return encoded
end

function InstapaperAPIManager:buildAuthorizationHeader(params)
    local header_parts = {}
    
    -- Build header with all OAuth parameters in alphabetical order
    local oauth_params = {}
    for key, value in pairs(params) do
        if key:match("^oauth_") then
            table.insert(oauth_params, {key = key, value = value})
        end
    end
    
    -- Sort OAuth parameters alphabetically
    table.sort(oauth_params, function(a, b) return a.key < b.key end)
    
    for _, param in ipairs(oauth_params) do
        table.insert(header_parts, param.key .. '="' .. self:percentEncode(param.value) .. '"')
    end
    
    local header = "OAuth " .. table.concat(header_parts, ", ")
    
    return header
end

function InstapaperAPIManager:buildRequestBody(params)
    local body_parts = {}
    -- Use the same order as the signature calculation

    for key, value in pairs(params) do
        table.insert(body_parts, key .. "=" .. self:percentEncode(params[key]))
    end

    return table.concat(body_parts, "&")
end

-- Generic OAuth request builder
function InstapaperAPIManager:buildOAuthRequest(method, url, params, token_secret)
    -- Generate signature
    local signature = self:signRequest(method, url, params, self.consumer_secret, token_secret)
    params.oauth_signature = signature
    
    -- Build request
    local request = {
        url = url,
        method = method,
        headers = {
            ["Authorization"] = self:buildAuthorizationHeader(params)
        }
    }
    
    -- Add body for POST requests
    if method == "POST" then
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = self:buildRequestBody(params)
    end
    
    return request
end

-- Helper method for queueable API requests
function InstapaperAPIManager:executeQueueableRequest(endpoint, additional_params)
    if not self:isAuthenticated() then
        return false, "Not authenticated"
    end
    
    -- Build parameters with oauth_token
    local params = {
        oauth_token = self.oauth_token
    }
    -- Add any additional parameters
    for key, value in pairs(additional_params) do
        params[key] = value
    end
    
    -- Check if we're online
    if not NetworkMgr:isOnline() then
        -- Queue the request for later
        self:addToQueue(self.api_base .. endpoint, params)
        return true, nil
    end
    
    -- Generate OAuth parameters and execute request
    local oauth_params = self:generateOAuthParams(params)
    local request = self:buildOAuthRequest("POST", self.api_base .. endpoint, oauth_params, self.oauth_token_secret)
    local success, body, error_message = self:executeRequest(request)
    
    if success then
        return true, nil, false
    else
        return false, error_message, false
    end
end

-- Generate common OAuth parameters
function InstapaperAPIManager:generateOAuthParams(additional_params)
    local params = {
        oauth_consumer_key = self.consumer_key,
        oauth_nonce = self:generateNonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp = tostring(os.time()),
        oauth_version = "1.0"
    }
    
    -- Add any additional parameters
    if additional_params then
        for key, value in pairs(additional_params) do
            params[key] = value
        end
    end
    
    return params
end

-- Generic HTTP request executor
function InstapaperAPIManager:executeRequest(request)
    if not NetworkMgr:isOnline() then
        
        return false,{}, "Your ereader is not currently online. Please connect to wifi and try again."
    end

    -- Make the request
    local sink = {}
    socketutil:set_timeout(10, 30)
    local http_request = {
        url = request.url,
        method = request.method,
        headers = request.headers,
        sink = ltn12.sink.table(sink),
        source = request.body and ltn12.source.string(request.body) or nil
    }
    
    local code, headers, status = socket.skip(1, http.request(http_request))
    socketutil:reset_timeout()
    
    local body = table.concat(sink)
    
    if type(code) == "number" and code >= 200 and code < 300 then
        return true, body, nil
    else
        local error_message = nil

        logger.err("ereader: Request failed with code:", code, "response:", body)
        if body then
            local decodesuccess, output = pcall(JSON.decode, body)

            if decodesuccess and output ~= nil then
                for _, item in ipairs(output) do
                    if item.type == "error" then
                        if item.message and #item.message > 0 then
                            error_message = item.message
                        end
                    end
                end
            end

            if not error_message then
                if type(code) == "string" then
                    error_message = code
                elseif type(code) == "number" then
                    if code == 401 then
                        error_message = "Authentication failed, check your username and password and try again."
                    else
                        error_message = "There is a problem with the server, please try again later." 
                    end
                else
                    error_message = "Unknown error"
                end
            end

            return false, body, error_message
        else 
            return false, {}, error_message
        end
    end
end

function InstapaperAPIManager:authenticate(username, password)    
    -- Generate OAuth parameters with auth-specific additions
    local authorization_params = self:generateOAuthParams({
        oauth_callback = "oob",
        x_auth_mode = "client_auth",
        x_auth_username = username,
        x_auth_password = password
    })
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.ACCESS_TOKEN_URL, authorization_params, nil)
    local success, body, error_message = self:executeRequest(request)
    
    if success then        
        -- Parse the response which contains the access token and secret
        local response_params = {}
        for k, v in string.gmatch(body, "([^&=]+)=([^&=]+)") do
            response_params[k] = v
        end
        
        if response_params.oauth_token and response_params.oauth_token_secret then
            self:saveTokens(response_params.oauth_token, response_params.oauth_token_secret)
            self:saveUsername(username)
            return true, response_params, nil
        else
            logger.err("instapaperAuthenticator: Missing OAuth tokens in response")
            return false, {}, "Missing OAuth tokens in response"
        end
    else
        return false, {}, error_message
    end
end

function InstapaperAPIManager:getArticles(limit, have)    
    if not self:isAuthenticated() then
        return false, {}, "Not authenticated"
    end
    
    -- Generate OAuth parameters with API-specific additions
    local params = self:generateOAuthParams({
        oauth_token = self.oauth_token,
        limit = limit or 100
    })
    
    -- Add 'have' parameter if provided
    if have and #have > 0 then
        local have_string = ""
        for _, id in ipairs(have) do
            have_string = have_string .. string.format("%d,", id)
        end
        params.have = have_string
    else 
        params.have = ""
    end
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/list", params, self.oauth_token_secret)
    local success, body, error_message = self:executeRequest(request)
    
    if success then
        local success, output = pcall(JSON.decode, body)
        
        
        if success and output then
            local articles = {}
            local deleted_ids = {}
            for _, item in ipairs(output) do
                logger.dbg("ereader: item.type", item.type)
                if item.type == "bookmark" then
                    if item.starred and (item.starred == 1 or item.starred == "1")  then
                        -- instapaper API (sometimes?) returns starred as a string, which is "fun"
                        item.starred = true
                    else
                        item.starred = false
                    end

                    table.insert(articles, item)
                elseif item.type == "meta" then
                    logger.dbg("ereader: deleted_ids", item.delete_ids)
                    -- Despite API docs, Instapaper currently returns deleted_ids as a comma-separated string of deleted IDs
                    if type(item.delete_ids) == "string" and item.delete_ids ~= "" then
                        for id_str in item.delete_ids:gmatch("([^,]+)") do
                            local id = tonumber(id_str:match("^%s*(.-)%s*$")) -- trim whitespace and convert to number
                            if id then
                                table.insert(deleted_ids, id)
                            end
                        end
                    elseif type(item.delete_ids) == "table" then
                        -- If the API ever starts returning a table, just use it directly
                        deleted_ids = item.delete_ids
                    end
                else 
                    --user object… just ignore them for now
                end
            end
            
            return true, articles, deleted_ids, nil
        else
            return false, {}, {},  "Failed to parse response"
        end
    else
        return false, {}, {}, error_message
    end
end

function InstapaperAPIManager:getArticleText(bookmark_id)
    if not self:isAuthenticated() then
        return false, {}, "Not authenticated"
    end
    
    -- Generate OAuth parameters including bookmark_id for signature
    local params = self:generateOAuthParams({
        oauth_token = self.oauth_token,
        bookmark_id = tostring(bookmark_id)
    })
    
    -- Build and execute request (POST with all params in signature)
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/get_text", params, self.oauth_token_secret)
    local success, body, error_message = self:executeRequest(request)
    
    if success then
        return true, body, nil
    else
        return false, {}, error_message
    end
end

function InstapaperAPIManager:addArticle(url)
    return self:executeQueueableRequest("/api/1/bookmarks/add", {url = url})
end

function InstapaperAPIManager:archiveArticle(bookmark_id)    
    return self:executeQueueableRequest("/api/1/bookmarks/archive", {bookmark_id = tostring(bookmark_id)})
end

function InstapaperAPIManager:favoriteArticle(bookmark_id)    
    return self:executeQueueableRequest("/api/1/bookmarks/star", {bookmark_id = tostring(bookmark_id)})
end

function InstapaperAPIManager:unfavoriteArticle(bookmark_id)    
    return self:executeQueueableRequest("/api/1/bookmarks/unstar", {bookmark_id = tostring(bookmark_id)})
end

-- Queue management methods
function InstapaperAPIManager:addToQueue(url, params)
    local queued_request = {
        url = url,
        params = params,
        timestamp = os.time()
    }
    table.insert(self.queued_requests, queued_request)
    self:saveQueue(self.queued_requests)
    logger.dbg("ereader: Added request to queue, queue size:", #self.queued_requests)
end

function InstapaperAPIManager:processQueuedRequests()
    if #self.queued_requests == 0 then
        return {}
    end
    
    logger.dbg("ereader: Processing", #self.queued_requests, "queued requests")
    
    local errors = {}
    local processed_count = 0
    
    -- Process requests FIFO
    local i = 1
    while i <= #self.queued_requests do
        local queued_request = self.queued_requests[i]
        
        -- Rebuild the request with fresh OAuth parameters
        local oauth_params = self:generateOAuthParams(queued_request.params)
        local request = self:buildOAuthRequest("POST", queued_request.url, oauth_params, self.oauth_token_secret)
        local success, _, error_message = self:executeRequest(request)
        
        if success then
            table.remove(self.queued_requests, i)
            processed_count = processed_count + 1
            logger.dbg("ereader: Successfully processed queued request")
        else
            table.insert(errors, {
                url = queued_request.url,
                params = queued_request.params,
                error = error_message or "Unknown error"
            })
            logger.warn("ereader: Failed to process queued request:", error_message)
            i = i + 1 -- Move to next request
        end
    end
    
    -- Save updated queue
    self:saveQueue(self.queued_requests)
    
    logger.dbg("ereader: Processed", processed_count, "requests,", #errors, "errors")
    return errors
end

return InstapaperAPIManager


