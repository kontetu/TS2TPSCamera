-- Settings persistence: validates against config.lua, writes a plain Lua table file.
local config = require("config")
local M = {}

function M.defaults()
    local t = {}
    for _, e in ipairs(config.entries) do t[e.key] = e.default end
    return t
end

-- Return `value` coerced to a valid value for `entry`, or the default.
function M.sanitize_value(entry, value)
    if entry.kind == "bool" then
        if type(value) == "boolean" then return value end
        return entry.default
    end
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return entry.default end
    if value < entry.min then return entry.min end
    if value > entry.max then return entry.max end
    return value
end

function M.sanitize(t)
    local out = {}
    for _, e in ipairs(config.entries) do out[e.key] = M.sanitize_value(e, t and t[e.key]) end
    -- keep the pitch limits consistent
    if out.pitch_min >= out.pitch_max then out.pitch_min, out.pitch_max = config.by_key.pitch_min.default, config.by_key.pitch_max.default end
    return out
end

function M.serialise(t)
    local keys = {}
    for _, e in ipairs(config.entries) do keys[#keys + 1] = e.key end
    local lines = { "return {" }
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "boolean" then lines[#lines + 1] = string.format("    %s = %s,", k, tostring(v))
        elseif type(v) == "number" then lines[#lines + 1] = string.format("    %s = %.6g,", k, v) end
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

-- Parse a settings file's text without executing arbitrary code (empty environment).
function M.parse(text)
    local chunk = load(text, "settings", "t", {})
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then return result end
    return nil
end

function M.load(path)
    local file = io.open(path, "r")
    if not file then return M.defaults() end
    local text = file:read("a")
    file:close()
    return M.sanitize(M.parse(text) or {})
end

function M.save(path, t)
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then return false end
    file:write(M.serialise(M.sanitize(t)))
    file:close()
    os.remove(path)
    return os.rename(tmp, path) and true or false
end

return M
