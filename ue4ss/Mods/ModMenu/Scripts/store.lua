-- ModMenu store — reads the effective settings of every registered mod and
-- persists menu changes.
--
-- Menu changes are written to Mods/<Mod>/Scripts/runtime.lua and never to
-- config.lua. config.lua stays exactly as the player wrote it, comments and all,
-- and remains the documented place to set defaults; runtime.lua is applied on
-- top of it by ModMenuBridge, so it always wins until it is reset from the menu.

local Store = {}

local bridge = nil
local modmenuScriptDir = nil

-- `dir` is ModMenu's own Scripts/ directory; every other mod is resolved
-- relative to it so nothing depends on UE4SS's working directory.
function Store.init(dir, loadedBridge)
    modmenuScriptDir = dir
    bridge = loadedBridge
end

function Store.scriptDirFor(modName)
    if modmenuScriptDir == nil then return nil end
    return modmenuScriptDir .. "../../" .. modName .. "/Scripts/"
end

local function runtimePathFor(modName)
    local dir = Store.scriptDirFor(modName)
    if dir == nil then return nil end
    return dir .. "runtime.lua"
end

Store.runtimePathFor = runtimePathFor

-- An integral value is written without a decimal point so the file stays
-- readable; nothing downstream distinguishes 1 from 1.0, every consumer either
-- does plain arithmetic on it or runs it through tonumber.
local function renderValue(value)
    local kind = type(value)
    if kind == "boolean" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "number" then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    if value % 1 == 0 and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.10g", value)
end

Store.renderValue = renderValue

function Store.serialize(values)
    local keys = {}
    for key, value in pairs(values) do
        if type(key) == "string" and renderValue(value) ~= nil then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local lines = {
        "-- Written by the in-game Mods menu.",
        "-- Applied on top of config.lua. Delete this file, or use Reset in the",
        "-- menu, to go back to whatever config.lua says.",
        "",
        "return {",
    }
    for _, key in ipairs(keys) do
        lines[#lines + 1] = string.format("    %s = %s,", key, renderValue(values[key]))
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

local function readTable(path)
    if bridge == nil or path == nil then return nil end
    local contents = bridge.readFile(path)
    if contents == nil then return nil end
    local result = bridge.evaluateTable(contents, "@" .. path)
    return result
end

-- Only the menu's own overrides, without config.lua underneath.
function Store.readRuntime(modName)
    return readTable(runtimePathFor(modName)) or {}
end

-- What the mod is actually running with: config.lua overlaid with runtime.lua.
function Store.readEffective(modName)
    if bridge == nil then return {} end
    local settings = bridge.readSettings(modName, Store.scriptDirFor(modName))
    return settings or {}
end

-- Resolves the value a single setting should display: the override if one
-- exists, otherwise config.lua, otherwise the registry default.
function Store.valueOf(effective, setting)
    -- Written out rather than folded into an `and`/`or` chain: a stored `false`
    -- would collapse to nil there and read back as the default, which silently
    -- pins every disabled setting to ON.
    local value = nil
    if effective ~= nil then value = effective[setting.key] end
    if value == nil then return setting.default end
    if setting.type == "bool" then return value ~= false end
    if setting.type == "number" then
        local number = tonumber(value)
        if number == nil then return setting.default end
        return number
    end
    return value
end

local function writeFile(path, contents)
    if path == nil then return false, "no path" end
    local handle, openError = io.open(path, "wb")
    if handle == nil then return false, tostring(openError) end
    local ok, writeError = pcall(function()
        handle:write(contents)
        handle:close()
    end)
    if not ok then
        pcall(function() handle:close() end)
        return false, tostring(writeError)
    end
    return true, nil
end

function Store.writeRuntime(modName, values)
    return writeFile(runtimePathFor(modName), Store.serialize(values))
end

--========================================================--
--                 UE4SS LOAD STATE                       --
--========================================================--
-- Whether a mod is switched on is UE4SS's business, not this menu's, and UE4SS
-- decides it from the presence of Mods/<Mod>/enabled.txt. Reading a mod's own
-- ENABLED setting instead would report a mod as ON while UE4SS was not loading
-- it at all, which is exactly the sort of lie a settings menu must not tell.

function Store.enabledPathFor(modName)
    local dir = Store.scriptDirFor(modName)
    if dir == nil then return nil end
    -- scriptDirFor points at Scripts/; enabled.txt sits beside it in the mod root.
    return dir .. "../enabled.txt"
end

function Store.isModEnabled(modName)
    local path = Store.enabledPathFor(modName)
    if path == nil or bridge == nil then return nil end
    return bridge.readFile(path) ~= nil
end

function Store.setModEnabled(modName, enabled)
    local path = Store.enabledPathFor(modName)
    if path == nil then return false, "no path" end

    if enabled then
        if bridge ~= nil and bridge.readFile(path) ~= nil then return true, nil end
        return writeFile(path, "")
    end

    local removed = false
    pcall(function() removed = os.remove(path) == true end)
    if removed then return true, nil end
    -- Report honestly rather than claim success: an enabled.txt that could not
    -- be deleted means UE4SS will still load the mod next launch.
    if bridge ~= nil and bridge.readFile(path) == nil then return true, nil end
    return false, "could not remove enabled.txt"
end

-- Persists one changed setting, leaving every other override in place.
function Store.setValue(modName, key, value)
    local values = Store.readRuntime(modName)
    values[key] = value
    return Store.writeRuntime(modName, values)
end

-- Drops every override for a mod so config.lua is back in charge. The file is
-- emptied rather than deleted when os.remove is unavailable, which is equivalent
-- for the bridge and avoids depending on a sandboxed os library.
function Store.resetMod(modName)
    local path = runtimePathFor(modName)
    if path == nil then return false, "no path" end
    if bridge ~= nil and bridge.readFile(path) == nil then return true, nil end

    local removed = false
    pcall(function() removed = os.remove(path) == true end)
    if removed then return true, nil end
    return Store.writeRuntime(modName, {})
end

return Store
