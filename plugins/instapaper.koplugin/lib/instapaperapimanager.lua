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
    -- Sort parameters in the exact order InstapaperAPIManager expects
    local param_order = {
        "oauth_callback",
        "oauth_consumer_key",
        "oauth_nonce",
        "oauth_signature_method",
        "oauth_timestamp",
        "oauth_version",
        "x_auth_mode",
        "x_auth_password",
        "x_auth_username"
    }
    
    -- Build parameter string in the correct order
    local param_string = {}
    for _, key in ipairs(param_order) do
        if params[key] then
            table.insert(param_string, self:percentEncode(key) .. "=" .. self:percentEncode(params[key]))
        end
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
    -- Use the same order as the signature base string calculation
    local header_order = {
        "oauth_callback",
        "oauth_consumer_key",
        "oauth_nonce",
        "oauth_signature_method",
        "oauth_timestamp",
        "oauth_version",
        "oauth_signature"
    }
    for _, key in ipairs(header_order) do
        if params[key] then
            table.insert(header_parts, key .. '="' .. self:percentEncode(params[key]) .. '"')
        end
    end
    local header = "OAuth " .. table.concat(header_parts, ", ")

    return header
end

function InstapaperAPIManager:buildRequestBody(params)
    local body_parts = {}
    -- Use the same order as the signature calculation
    local body_order = {
        "x_auth_mode",
        "x_auth_password", 
        "x_auth_username"
    }
    for _, key in ipairs(body_order) do
        if params[key] then
            table.insert(body_parts, key .. "=" .. self:percentEncode(params[key]))
        end
    end
    return table.concat(body_parts, "&")
end

function InstapaperAPIManager:getAccessToken(username, password)
    -- Generate OAuth parameters
    local params = {
        oauth_consumer_key = self.consumer_key,
        oauth_nonce = self:generateNonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp = tostring(os.time()),
        oauth_version = "1.0",
        oauth_callback = "oob",
        x_auth_mode = "client_auth",
        x_auth_username = username,
        x_auth_password = password
    }
    
    -- Generate signature
    local signature = self:signRequest("POST", self.ACCESS_TOKEN_URL, params, self.consumer_secret)
    params.oauth_signature = signature
    
    -- Build request
    local request = {
        url = self.ACCESS_TOKEN_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Authorization"] = self:buildAuthorizationHeader(params)
        },
        body = self:buildRequestBody(params)
    }
    
    return request
end

function InstapaperAPIManager:authenticate(username, password)
    logger.dbg("instapaperAuthenticator: Starting authentication for user:", username)
    
    -- Generate OAuth parameters
    local params = {
        oauth_consumer_key = self.consumer_key,
        oauth_nonce = self:generateNonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp = tostring(os.time()),
        oauth_version = "1.0",
        oauth_callback = "oob",
        x_auth_mode = "client_auth",
        x_auth_username = username,
        x_auth_password = password
    }
    
    -- Generate signature
    local signature = self:signRequest("POST", self.ACCESS_TOKEN_URL, params, self.consumer_secret)
    params.oauth_signature = signature
    
    -- Build request
    local request = {
        url = self.ACCESS_TOKEN_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Authorization"] = self:buildAuthorizationHeader(params)
        },
        body = self:buildRequestBody(params)
    }
    
    logger.dbg("instapaperAuthenticator: Making authentication request to:", request.url)
    
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
    
    if code == 200 then
        local body = table.concat(sink)
        logger.dbg("instapaperAuthenticator: Authentication successful, response:", body)
        
        -- Parse the response which contains the access token and secret
        local response_params = {}
        for k, v in string.gmatch(body, "([^&=]+)=([^&=]+)") do
            response_params[k] = v
        end
        
        if response_params.oauth_token and response_params.oauth_token_secret then
            logger.dbg("instapaperAuthenticator: Successfully parsed OAuth tokens")
            return true, response_params
        else
            logger.err("instapaperAuthenticator: Missing OAuth tokens in response")
            return false, nil
        end
    else
        local body = table.concat(sink)
        logger.err("instapaperAuthenticator: Authentication failed with code:", code, "response:", body)
        return false, nil
    end
end

return InstapaperAPIManager
