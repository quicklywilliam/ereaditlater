local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local sha2 = require("ffi/sha2")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local InstapaperAPIManager = {}

function InstapaperAPIManager:new()
    local api_manager = {}

    -- Load API keys
    local consumer_key, consumer_secret = self:loadApiKeys()
    if not consumer_key or not consumer_secret then
        logger.err("instapaper: Failed to load API keys")

        return nil
    end
    
    api_manager.consumer_key = consumer_key
    api_manager.consumer_secret = consumer_secret
    api_manager.api_base = "https://www.instapaper.com"
    api_manager.ACCESS_TOKEN_URL = api_manager.api_base .. "/api/1/oauth/access_token"
    
    setmetatable(api_manager, self)
    self.__index = self
    
    return api_manager
end

-- Load API keys from file
function InstapaperAPIManager:loadApiKeys()
    local secrets_path = "plugins/instapaper.koplugin/secrets.txt"
    local file = io.open(secrets_path, "r")
    if not file then
        logger.err("instapaper: Could not open secrets.txt")
        return nil, nil, nil, nil
    end
    
    local content = file:read("*all")
    file:close()
    
    local consumer_key = ""
    local consumer_secret = ""
    
    -- Parse the content looking for all keys
    for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
        if key == "instapaper_ouath_consumer_key" then
            consumer_key = value
        elseif key == "instapaper_oauth_consumer_secret" then
            consumer_secret = value
        end
    end
    
    if consumer_key == "" or consumer_secret == "" then
        logger.err("instapaper: Could not find both consumer_key and consumer_secret in secrets.txt")
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
    
    if code == 200 then
        return true, body
    else
        logger.err("instapaper: Request failed with code:", code, "response:", body)
        return false, body
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
    local success, body = self:executeRequest(request)
    
    if success then        
        -- Parse the response which contains the access token and secret
        local response_params = {}
        for k, v in string.gmatch(body, "([^&=]+)=([^&=]+)") do
            response_params[k] = v
        end
        
        if response_params.oauth_token and response_params.oauth_token_secret then
            return true, response_params
        else
            logger.err("instapaperAuthenticator: Missing OAuth tokens in response")
            return false, nil
        end
    else
        return false, nil
    end
end

function InstapaperAPIManager:getArticles(oauth_token, oauth_token_secret)    
    -- Generate OAuth parameters with API-specific additions
    local params = self:generateOAuthParams({
        oauth_token = oauth_token
    })
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/list", params, oauth_token_secret)
    local success, body = self:executeRequest(request)
    
    if success then
        -- Parse JSON response
        local JSON = require("json")
        local success, output = pcall(JSON.decode, body)
        
        if success and output then
            local articles = {}
            for _, item in ipairs(output) do
                if item.type == "bookmark" then
                    table.insert(articles, item)
                else
                    --meta and user objects… just ignore them for now
                end
            end
            return true, articles
        else
            return false, nil
        end
    else
        return false, nil
    end
end

function InstapaperAPIManager:getArticleText(bookmark_id, oauth_token, oauth_token_secret)
    -- Generate OAuth parameters including bookmark_id for signature
    local params = self:generateOAuthParams({
        oauth_token = oauth_token,
        bookmark_id = tostring(bookmark_id)
    })
    
    -- Build and execute request (POST with all params in signature)
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/get_text", params, oauth_token_secret)
    local success, body = self:executeRequest(request)
    
    if success then
        return true, body
    else
        return false, nil
    end
end

function InstapaperAPIManager:archiveArticle(bookmark_id, oauth_token, oauth_token_secret)    
    -- Generate OAuth parameters including bookmark_id for signature
    local params = self:generateOAuthParams({
        oauth_token = oauth_token,
        bookmark_id = tostring(bookmark_id)
    })
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/archive", params, oauth_token_secret)
    local success, body = self:executeRequest(request)
    
    if success then
        logger.dbg("instapaper: Archive response", body)
        return true
    else
        return false
    end
end

function InstapaperAPIManager:favoriteArticle(bookmark_id, oauth_token, oauth_token_secret)    
    -- Generate OAuth parameters including bookmark_id for signature
    local params = self:generateOAuthParams({
        oauth_token = oauth_token,
        bookmark_id = tostring(bookmark_id)
    })
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/star", params, oauth_token_secret)
    local success, body = self:executeRequest(request)
    
    if success then
        return true
    else
        return false
    end
end

function InstapaperAPIManager:unfavoriteArticle(bookmark_id, oauth_token, oauth_token_secret)    
    -- Generate OAuth parameters including bookmark_id for signature
    local params = self:generateOAuthParams({
        oauth_token = oauth_token,
        bookmark_id = tostring(bookmark_id)
    })
    
    -- Build and execute request
    local request = self:buildOAuthRequest("POST", self.api_base .. "/api/1/bookmarks/unstar", params, oauth_token_secret)
    local success, body = self:executeRequest(request)
    
    if success then
        return true
    else
        return false
    end
end

return InstapaperAPIManager


