local JSON = require("json")

local JSONUtils = {}

-- Wrapper around JSON.decode that fixes the null -> function bug
function JSONUtils.decode(json_string)
    local success, result = pcall(JSON.decode, json_string)
    if not success then
        return nil, result
    end
    
    -- Recursively fix null values that became functions
    local function fix_null_values(obj)
        if type(obj) == "table" then
            for k, v in pairs(obj) do
                if type(v) == "function" then
                    -- This was likely a null value in the JSON
                    obj[k] = nil
                elseif type(v) == "table" then
                    fix_null_values(v)
                end
            end
        elseif type(obj) == "function" then
            -- This was likely a null value in the JSON
            return nil
        end
        return obj
    end
    
    return fix_null_values(result)
end

-- Wrapper around JSON.encode (in case we need it)
function JSONUtils.encode(obj)
    return JSON.encode(obj)
end

return JSONUtils 