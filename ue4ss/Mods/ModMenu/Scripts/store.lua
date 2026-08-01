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
    if type(dir) ~= "string" or dir == "" then
        error("canonical ModMenu Scripts directory is unavailable")
    end
    if type(loadedBridge) ~= "table" then
        error("canonical ModMenuBridge is unavailable")
    end
    modmenuScriptDir = dir
    bridge = loadedBridge
end

function Store.scriptDirFor(modName)
    if type(modName) ~= "string" or modName == "" then
        error("registered mod name is unavailable")
    end
    if modmenuScriptDir == nil then
        error("store has not been initialized")
    end
    return modmenuScriptDir .. "../../" .. modName .. "/Scripts/"
end

local function runtimePathFor(modName)
    return Store.scriptDirFor(modName) .. "runtime.lua"
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
    if type(values) ~= "table" then error("runtime values must be a table") end
    local keys = {}
    for key, value in pairs(values) do
        if type(key) ~= "string" or key == "" then
            error("runtime keys must be non-empty strings")
        end
        if not key:match("^[A-Z][A-Z0-9_]*$") then
            error("invalid runtime key: " .. key)
        end
        if renderValue(value) == nil then
            error("unsupported runtime value for " .. key)
        end
        keys[#keys + 1] = key
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

local function readOptionalTable(path)
    local contents, readError = bridge.readFile(path)
    if readError ~= nil then
        return nil, "read failed: " .. tostring(readError)
    end
    if contents == nil then return {}, nil end
    local result, evaluationError = bridge.evaluateTable(contents, "@" .. path)
    if result == nil then
        return nil, "settings rejected: " .. tostring(evaluationError)
    end
    return result, nil
end

-- Only the menu's own overrides, without config.lua underneath.
function Store.readRuntime(modName)
    return readOptionalTable(runtimePathFor(modName))
end

-- What the mod is actually running with: config.lua overlaid with runtime.lua.
function Store.readEffective(modName)
    local settings, _, info =
        bridge.readSettings(modName, Store.scriptDirFor(modName))
    if settings == nil then
        error(tostring(modName) .. " settings unavailable: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    return settings
end

-- Resolves the exact effective value. Missing or invalid values are errors:
-- the menu must not display or persist a substitute.
function Store.valueOf(effective, setting)
    if type(effective) ~= "table" then error("effective settings are unavailable") end
    if type(setting) ~= "table" or type(setting.key) ~= "string" then
        error("registry setting is invalid")
    end
    local value = effective[setting.key]
    if value == nil then error("missing effective setting: " .. setting.key) end
    if setting.type == "bool" then
        if type(value) ~= "boolean" then error(setting.key .. " must be boolean") end
        return value
    end
    if setting.type == "number" then
        if type(value) ~= "number" then error(setting.key .. " must be numeric") end
        return value
    end
    if setting.type == "choice" then
        if type(value) ~= "string" and type(value) ~= "number" then
            error(setting.key .. " has an invalid choice value")
        end
        return value
    end
    error("unsupported registry setting type: " .. tostring(setting.type))
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

local function removeFile(path)
    local contents, readError = bridge.readFile(path)
    if readError ~= nil then
        return false, "state read failed: " .. tostring(readError)
    end
    if contents == nil then return true, nil end
    local removed, removeError = os.remove(path)
    if removed == true then return true, nil end
    return false, tostring(removeError)
end

-- runtime.lua is watched from independent Lua states. Writing it directly with
-- "wb" briefly exposes a valid but incomplete table to those readers. Publish
-- a complete staged file under a transaction lock, then replace the canonical
-- file while readers deliberately keep their last validated configuration.
local function writeRuntimeTransaction(path, contents)
    local nextPath = path .. ".next"
    local lockPath = path .. ".lock"

    local lockText, lockReadError = bridge.readFile(lockPath)
    if lockReadError ~= nil then
        return false, "transaction lock read failed: " .. tostring(lockReadError)
    end
    if lockText ~= nil then
        return false, "runtime transaction lock already exists: " .. lockPath
    end

    local stagedText, stagedReadError = bridge.readFile(nextPath)
    if stagedReadError ~= nil then
        return false, "staged runtime read failed: " .. tostring(stagedReadError)
    end
    if stagedText ~= nil then
        return false, "staged runtime already exists: " .. nextPath
    end

    local previousText, previousReadError = bridge.readFile(path)
    if previousReadError ~= nil then
        return false, "current runtime read failed: " .. tostring(previousReadError)
    end

    local staged, stageError = writeFile(nextPath, contents)
    if not staged then
        return false, "could not stage runtime: " .. tostring(stageError)
    end

    local locked, lockError = writeFile(
        lockPath,
        "ModMenu runtime transaction in progress\n"
    )
    if not locked then
        local removed, removeError = removeFile(nextPath)
        if not removed then
            return false, "could not create transaction lock (" ..
                tostring(lockError) .. "); staged cleanup failed: " ..
                tostring(removeError)
        end
        return false, "could not create transaction lock: " .. tostring(lockError)
    end

    local function rollback()
        local targetRemoved, targetRemoveError = removeFile(path)
        if not targetRemoved then
            return false, "target cleanup failed: " .. tostring(targetRemoveError)
        end
        if previousText ~= nil then
            local restored, restoreError = writeFile(path, previousText)
            if not restored then
                return false, "previous runtime restore failed: " ..
                    tostring(restoreError)
            end
        end
        return true, nil
    end

    local targetRemoved, targetRemoveError = removeFile(path)
    if not targetRemoved then
        local stagedRemoved, stagedRemoveError = removeFile(nextPath)
        local lockRemoved, lockRemoveError = removeFile(lockPath)
        return false, string.format(
            "canonical runtime removal failed (%s); cleanup staged=%s lock=%s",
            tostring(targetRemoveError),
            tostring(stagedRemoved and "ok" or stagedRemoveError),
            tostring(lockRemoved and "ok" or lockRemoveError)
        )
    end

    local published, publishError = os.rename(nextPath, path)
    if published ~= true then
        local rolledBack, rollbackError = rollback()
        local stagedRemoved, stagedRemoveError = removeFile(nextPath)
        local lockRemoved, lockRemoveError = removeFile(lockPath)
        return false, string.format(
            "runtime publish failed (%s); rollback=%s staged=%s lock=%s",
            tostring(publishError),
            tostring(rolledBack and "ok" or rollbackError),
            tostring(stagedRemoved and "ok" or stagedRemoveError),
            tostring(lockRemoved and "ok" or lockRemoveError)
        )
    end

    local lockRemoved, lockRemoveError = removeFile(lockPath)
    if not lockRemoved then
        local rolledBack, rollbackError = rollback()
        local secondRemoval, secondRemovalError = removeFile(lockPath)
        return false, string.format(
            "transaction lock removal failed (%s); rollback=%s lock cleanup=%s",
            tostring(lockRemoveError),
            tostring(rolledBack and "ok" or rollbackError),
            tostring(secondRemoval and "ok" or secondRemovalError)
        )
    end

    local revPath = path:gsub("runtime%.lua$", "runtime.rev")
    writeFile(revPath, tostring(os.time()) .. "." .. tostring(math.random(1000, 9999)))

    return true, nil
end

function Store.writeRuntime(modName, values)
    local ok, serialized = pcall(function() return Store.serialize(values) end)
    if not ok then
        return false, "runtime serialization failed: " .. tostring(serialized)
    end
    return writeRuntimeTransaction(runtimePathFor(modName), serialized)
end

--========================================================--
--                 UE4SS LOAD STATE                       --
--========================================================--
-- Whether a mod is switched on is UE4SS's business, not this menu's, and UE4SS
-- decides it from the presence of Mods/<Mod>/enabled.txt. Reading a mod's own
-- ENABLED setting instead would report a mod as ON while UE4SS was not loading
-- it at all, which is exactly the sort of lie a settings menu must not tell.

function Store.enabledPathFor(modName)
    -- scriptDirFor points at Scripts/; enabled.txt sits beside it in the mod root.
    return Store.scriptDirFor(modName) .. "../enabled.txt"
end

function Store.isModEnabled(modName)
    local path = Store.enabledPathFor(modName)
    local contents, readError = bridge.readFile(path)
    if readError ~= nil then
        error("enabled.txt state read failed: " .. tostring(readError))
    end
    return contents ~= nil
end

function Store.setModEnabled(modName, enabled)
    local path = Store.enabledPathFor(modName)
    if type(enabled) ~= "boolean" then return false, "enabled state must be boolean" end

    if enabled then
        local existing, readError = bridge.readFile(path)
        if readError ~= nil then
            return false, "enabled.txt state read failed: " .. tostring(readError)
        end
        if existing ~= nil then return true, nil end
        return writeFile(path, "enabled\n")
    end

    local existing, readError = bridge.readFile(path)
    if readError ~= nil then
        return false, "enabled.txt state read failed: " .. tostring(readError)
    end
    if existing == nil then return true, nil end

    local removed, removeError = os.remove(path)
    if removed == true then return true, nil end
    return false, "could not remove enabled.txt: " .. tostring(removeError)
end

-- Changes the launch marker and, for a mod that has a settings contract, its
-- live ENABLED override as one transaction. If either write fails, restore the
-- previous runtime table and launch marker.
--
-- A mod without a contract has no runtime.lua of ours to write: enabled.txt is
-- the whole of its state, and this must not plant a settings file inside a mod
-- that never asked for one.
function Store.setEnabledState(modName, runtimeKey, enabled)
    if runtimeKey == nil then
        return Store.setModEnabled(modName, enabled)
    end
    if type(runtimeKey) ~= "string" or runtimeKey == "" then
        return false, "registered mod has no canonical ENABLED key"
    end

    local wasEnabled = Store.isModEnabled(modName)
    if type(wasEnabled) ~= "boolean" then
        return false, "could not read current enabled.txt state"
    end

    local previousRuntime, runtimeReadError = Store.readRuntime(modName)
    if previousRuntime == nil then
        return false, "runtime read failed: " .. tostring(runtimeReadError)
    end
    local nextRuntime = {}
    for key, value in pairs(previousRuntime) do
        nextRuntime[key] = value
    end
    nextRuntime[runtimeKey] = enabled

    local runtimeWritten, runtimeError =
        Store.writeRuntime(modName, nextRuntime)
    if not runtimeWritten then
        return false, "runtime update failed: " .. tostring(runtimeError)
    end

    local markerWritten, markerError = Store.setModEnabled(modName, enabled)
    if markerWritten then return true, nil end

    local runtimeRolledBack, runtimeRollbackError =
        Store.writeRuntime(modName, previousRuntime)
    local markerRolledBack, markerRollbackError =
        Store.setModEnabled(modName, wasEnabled)
    if not runtimeRolledBack or not markerRolledBack then
        return false, string.format(
            "enabled.txt update failed (%s); rollback failed (runtime=%s, marker=%s)",
            tostring(markerError),
            tostring(runtimeRollbackError),
            tostring(markerRollbackError)
        )
    end
    return false, "enabled.txt update failed: " .. tostring(markerError)
end

-- Persists one changed setting, leaving every other override in place.
function Store.setValue(modName, key, value)
    local values, runtimeReadError = Store.readRuntime(modName)
    if values == nil then
        return false, "runtime read failed: " .. tostring(runtimeReadError)
    end
    values[key] = value
    return Store.writeRuntime(modName, values)
end

-- Drops every override for a mod so config.lua is back in charge.
function Store.resetMod(modName)
    local path = runtimePathFor(modName)
    local existing, readError = bridge.readFile(path)
    if readError ~= nil then
        return false, "runtime read failed: " .. tostring(readError)
    end
    if existing == nil then return true, nil end

    local removed, removeError = os.remove(path)
    if removed == true then
        local revPath = path:gsub("runtime%.lua$", "runtime.rev")
        writeFile(revPath, tostring(os.time()) .. "." .. tostring(math.random(1000, 9999)))
        return true, nil
    end
    return false, "could not remove runtime.lua: " .. tostring(removeError)
end

return Store
