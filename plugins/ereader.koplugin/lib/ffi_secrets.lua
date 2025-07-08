local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

-- Try to load the compiled secrets library
local function try_load_compiled_library()
    local current_dir = lfs.currentdir()
    
    local success, instapapersecrets = pcall(function()
        return ffi.load(current_dir .. "/plugins/instapaper.koplugin/lib/instapapersecrets.so")
    end)
    
    if success then
        logger.dbg("ereader: Successfully loaded compiled secrets library")
        ffi.cdef[[
            const char *get_instapaper_consumer_key();
            const char *get_instapaper_consumer_secret();
            ]]
        return instapapersecrets
    else
        logger.dbg("ereader: Failed to load compiled secrets library:", lib)
        logger.dbg("ereader: This is expected if the library is not available for this platform")
        return nil
    end
end

-- Try to read secrets from text file
local function try_read_text_file()
    -- Look for secrets file in user's config directory
    local home = os.getenv("HOME")
    local secrets_path = home and (home .. "/.config/koreader/secrets.txt") or "secrets.txt"
    
    local file = io.open(secrets_path, "r")
    if not file then
        logger.dbg("ereader: Could not open secrets.txt at " .. secrets_path)
        return nil, nil
    end
    
    local content = file:read("*all")
    file:close()
    
    local consumer_key = ""
    local consumer_secret = ""
    
    -- Parse the content looking for keys
    for key, value in string.gmatch(content, '"([^"]+)"%s*=%s*"([^"]+)"') do
        if key == "instapaper_ouath_consumer_key" then
            consumer_key = value
        elseif key == "instapaper_oauth_consumer_secret" then
            consumer_secret = value
        end
    end
    
    if consumer_key == "" or consumer_secret == "" then
        logger.dbg("ereader: Could not find both consumer_key and consumer_secret in secrets.txt")
        return nil, nil
    end
    
    logger.dbg("ereader: Successfully loaded secrets from text file at " .. secrets_path)
    return consumer_key, consumer_secret
end

-- Main function to get secrets with fallback
function M.get_secrets()
    -- Try compiled library first
    local lib = try_load_compiled_library()
    if lib then
        local success, key, secret = pcall(function()
            return ffi.string(lib.get_instapaper_consumer_key()),
                   ffi.string(lib.get_instapaper_consumer_secret())
        end)
        
        if success and key and secret and key ~= "" and secret ~= "" then
            return key, secret
        else
            logger.dbg("ereader: Compiled library returned empty or invalid secrets")
        end
    end
    
    -- Fall back to text file
    local key, secret = try_read_text_file()
    if key and secret then
        return key, secret
    end
    
    -- Neither method worked
    return nil, nil
end

-- Function to check if secrets are available
function M.has_secrets()
    local key, secret = M.get_secrets()
    return key ~= nil and secret ~= nil
end

return M 