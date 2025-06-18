local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local sha2 = require("ffi/sha2")

local Instapaper = {}

function Instapaper:generateTimestamp()
    return tostring(os.time())
end

function Instapaper:generateNonce()
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

function Instapaper:percentEncode(str)
    if not str then return "" end
    
    -- Convert to string if not already
    str = tostring(str)
    
    -- OAuth 1.0a requires double encoding of certain characters
    local encoded = str:gsub("([^A-Za-z0-9%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    
    return encoded
end

function Instapaper:generateSignatureBaseString(method, url, params)
    -- Sort parameters in the exact order Instapaper expects
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

-- Pure Lua SHA1 implementation using sha2 library
local function sha1(data)
    local sha2 = require("ffi/sha2")
    -- Use sha2's SHA1 function and convert hex to binary
    local hex_result = sha2.sha1(data)
    
    -- Convert hex string to binary
    local result = ""
    for i = 1, #hex_result, 2 do
        local byte = tonumber(hex_result:sub(i, i+1), 16)
        result = result .. string.char(byte)
    end
    
    return result
end

-- Pure Lua HMAC-SHA1 implementation
local function hmac_sha1(key, message)
    local bit = require("bit")
    local blocksize = 64
    
    -- If key is longer than block size, hash it
    if #key > blocksize then
        key = sha1(key)
    end
    
    -- Pad key to block size
    key = key .. string.rep("\0", blocksize - #key)
    
    -- Create outer and inner padding
    local o_key_pad = ""
    local i_key_pad = ""
    for i = 1, blocksize do
        local k = string.byte(key, i)
        o_key_pad = o_key_pad .. string.char(bit.bxor(k, 0x5c))
        i_key_pad = i_key_pad .. string.char(bit.bxor(k, 0x36))
    end
    
    -- Calculate inner and outer hashes
    local inner = sha1(i_key_pad .. message)
    local digest = sha1(o_key_pad .. inner)
    
    return digest
end

function Instapaper:signRequest(method, url, params, consumer_secret, token_secret)
    -- Generate signature base string
    local base_string = self:generateSignatureBaseString(method, url, params)
    
    -- Create signing key
    local encoded_consumer = self:percentEncode(consumer_secret)
    local encoded_token = token_secret and self:percentEncode(token_secret) or ""
    local signing_key = encoded_consumer .. "&" .. encoded_token
        
    local signature = hmac_sha1(signing_key, base_string)
    
    local sha2 = require("ffi/sha2")
    local encoded = sha2.bin_to_base64(signature)
        
    return encoded
end

function Instapaper:new(consumer_key, consumer_secret)
    local oauth = {}
    
    oauth.consumer_key = consumer_key
    oauth.consumer_secret = consumer_secret
    oauth.api_base = "https://www.instapaper.com"
    oauth.ACCESS_TOKEN_URL = oauth.api_base .. "/api/1/oauth/access_token"
    
    setmetatable(oauth, self)
    self.__index = self
    
    return oauth
end

function Instapaper:buildAuthorizationHeader(params)
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

function Instapaper:buildRequestBody(params)
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

function Instapaper:getAccessToken(username, password)
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

return Instapaper
