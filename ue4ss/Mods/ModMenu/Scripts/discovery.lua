-- Folder-driven discovery for ModMenu.
--
-- There is no central allow-list. Every folder under Mods/ is enumerated
-- through IterateGameDirectories, and a mod appears in the menu by shipping
-- Scripts/modmenu.lua inside its own folder, declaring its own settings next
-- to the config.lua those settings live in. Nothing outside a mod's folder
-- has to be edited to add it, remove it, or move it.
--
-- Opting in is not the same as being accepted: a manifest is still validated
-- against the mod's real effective settings, so a contract that has drifted
-- from the config it describes is reported and skipped rather than shown.

local Discovery = {}

local APPLY_MODES = {
    live = true,
    menu = true,
    restart = true,
}

local SETTING_TYPES = {
    bool = true,
    number = true,
    choice = true,
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function containsValue(options, value)
    for _, option in ipairs(options) do
        if option.value == value then return true end
    end
    return false
end

local function validateChoice(setting, value)
    if type(setting.options) ~= "table" or #setting.options == 0 then
        return nil, setting.key .. " choice has no options"
    end

    local values = {}
    for index, option in ipairs(setting.options) do
        if type(option) ~= "table" then
            return nil, string.format("%s option %d must be a table", setting.key, index)
        end
        if option.value == nil then
            return nil, string.format("%s option %d has no value", setting.key, index)
        end
        if not nonEmptyString(option.label) then
            return nil, string.format("%s option %d has no label", setting.key, index)
        end
        local identity = type(option.value) .. "\0" .. tostring(option.value)
        if values[identity] then
            return nil, setting.key .. " has duplicate choice values"
        end
        values[identity] = true
    end

    if not containsValue(setting.options, value) then
        return nil, setting.key .. " value is not present in its registered choices"
    end
    return true, nil
end

local function validateNumber(setting, value)
    if not finiteNumber(value) then
        return nil, setting.key .. " must resolve to a finite number"
    end
    if setting.min ~= nil and not finiteNumber(setting.min) then
        return nil, setting.key .. " min must be a finite number"
    end
    if setting.max ~= nil and not finiteNumber(setting.max) then
        return nil, setting.key .. " max must be a finite number"
    end
    if setting.min ~= nil and setting.max ~= nil and setting.min > setting.max then
        return nil, setting.key .. " min must not exceed max"
    end
    if setting.step ~= nil and (not finiteNumber(setting.step) or setting.step <= 0) then
        return nil, setting.key .. " step must be a positive finite number"
    end
    if setting.min ~= nil and value < setting.min then
        return nil, setting.key .. " is below the registered minimum"
    end
    if setting.max ~= nil and value > setting.max then
        return nil, setting.key .. " is above the registered maximum"
    end
    if setting.format ~= nil and not nonEmptyString(setting.format) then
        return nil, setting.key .. " format must be a non-empty string"
    end
    return true, nil
end

local function validateSetting(setting, effective, knownSettings)
    if type(setting) ~= "table" then return nil, "setting must be a table" end
    if not nonEmptyString(setting.key) then return nil, "setting key is unavailable" end
    if not setting.key:match("^[A-Z][A-Z0-9_]*$") then
        return nil, "invalid setting key: " .. setting.key
    end
    if not nonEmptyString(setting.label) then
        return nil, setting.key .. " label is unavailable"
    end
    if not SETTING_TYPES[setting.type] then
        return nil, setting.key .. " has an unsupported setting type"
    end
    if setting.apply ~= nil and not APPLY_MODES[setting.apply] then
        return nil, setting.key .. " has an unsupported apply mode"
    end

    local value = effective[setting.key]
    if value == nil then return nil, "missing effective setting: " .. setting.key end

    if setting.type == "bool" then
        if type(value) ~= "boolean" then
            return nil, setting.key .. " must resolve to boolean"
        end
    elseif setting.type == "number" then
        local ok, err = validateNumber(setting, value)
        if not ok then return nil, err end
    elseif setting.type == "choice" then
        if type(value) ~= "string" and type(value) ~= "number" then
            return nil, setting.key .. " must resolve to a string or number choice"
        end
        local ok, err = validateChoice(setting, value)
        if not ok then return nil, err end
    end

    for _, relation in ipairs({ "floorKey", "ceilingKey" }) do
        local related = setting[relation]
        if related ~= nil then
            if not nonEmptyString(related) or knownSettings[related] == nil then
                return nil, setting.key .. " references unknown " .. relation
            end
            local relatedValue = effective[related]
            if not finiteNumber(value) or not finiteNumber(relatedValue) then
                return nil, setting.key .. " relation requires numeric effective values"
            end
            if relation == "floorKey" and value < relatedValue then
                return nil, setting.key .. " is below " .. related
            end
            if relation == "ceilingKey" and value > relatedValue then
                return nil, setting.key .. " is above " .. related
            end
        end
    end

    return true, nil
end

local function validateEntry(entry, effective)
    if type(entry) ~= "table" then return nil, "registry entry must be a table" end
    if not nonEmptyString(entry.mod) then return nil, "registered mod folder is unavailable" end
    if not entry.mod:match("^[%w_.-]+$") then
        return nil, "registered mod folder contains unsupported characters"
    end
    if not nonEmptyString(entry.label) then return nil, entry.mod .. " label is unavailable" end
    if not nonEmptyString(entry.summary) then return nil, entry.mod .. " summary is unavailable" end
    if not APPLY_MODES[entry.apply] then
        return nil, entry.mod .. " has an unsupported apply mode"
    end
    if type(entry.settings) ~= "table" or #entry.settings == 0 then
        return nil, entry.mod .. " has no registered settings"
    end
    if type(effective) ~= "table" then
        return nil, entry.mod .. " effective settings are unavailable"
    end

    local knownSettings = {}
    for _, setting in ipairs(entry.settings) do
        if type(setting) ~= "table" or not nonEmptyString(setting.key) then
            return nil, entry.mod .. " contains an invalid setting declaration"
        end
        if knownSettings[setting.key] ~= nil then
            return nil, entry.mod .. " contains duplicate setting " .. setting.key
        end
        knownSettings[setting.key] = setting
    end

    local enabled = knownSettings.ENABLED
    if enabled == nil or enabled.type ~= "bool" then
        return nil, entry.mod .. " must register ENABLED as a boolean setting"
    end

    for _, setting in ipairs(entry.settings) do
        local ok, err = validateSetting(setting, effective, knownSettings)
        if not ok then return nil, entry.mod .. ": " .. tostring(err) end
    end

    return true, nil
end

local function readPresence(bridge, path)
    local contents, readError = bridge.readFile(path)
    if readError ~= nil then return nil, tostring(readError) end
    return contents ~= nil, nil
end

-- Directory keys that are metadata rather than a subdirectory.
local RESERVED_KEYS = {
    __name = true,
    __absolute_path = true,
    __files = true,
}

-- IterateGameDirectories keys directories by their real name, so the walk has
-- to be case-tolerant: the loader folder is "ue4ss" on some installs and
-- "UE4SS" on others, and neither spelling is ours to assume.
local function childDirectory(parent, name)
    if type(parent) ~= "table" then return nil end
    local direct = parent[name]
    if type(direct) == "table" then return direct end
    local wanted = name:lower()
    for key, value in pairs(parent) do
        if not RESERVED_KEYS[key] and type(key) == "string"
            and type(value) == "table" and key:lower() == wanted then
            return value
        end
    end
    return nil
end

-- Every folder under Mods/, by name. This is what makes a central allow-list
-- unnecessary: the installed set is read off disk instead of declared.
local function installedModNames()
    if type(IterateGameDirectories) ~= "function" then
        return nil, "this UE4SS build does not expose IterateGameDirectories"
    end

    local ok, directories = pcall(IterateGameDirectories)
    if not ok or type(directories) ~= "table" then
        return nil, "IterateGameDirectories returned no directory tree"
    end

    -- .Game.Binaries.<platform>.ue4ss.Mods -- the platform folder is whatever
    -- this build ships (Win64, WinGDK, ...), so it is taken as the single
    -- child rather than named.
    local binaries = childDirectory(childDirectory(directories, "Game"),
        "Binaries")
    local platform = nil
    if type(binaries) == "table" then
        for key, value in pairs(binaries) do
            if not RESERVED_KEYS[key] and type(value) == "table" then
                platform = value
                break
            end
        end
    end
    local mods = childDirectory(childDirectory(platform, "ue4ss"), "Mods")
    if type(mods) ~= "table" then
        return nil, "the Mods directory was not found in the game tree"
    end

    local names = {}
    for key, value in pairs(mods) do
        if not RESERVED_KEYS[key] and type(value) == "table"
            and type(key) == "string" and key:match("^[%w_.-]+$") then
            names[#names + 1] = key
        end
    end
    table.sort(names)
    return names, nil
end

Discovery.installedModNames = installedModNames

-- A mod declares its own menu contract in Scripts/modmenu.lua, inside its own
-- folder, next to the config.lua that contract describes. Nothing outside the
-- mod has to know it exists.
local function readManifest(bridge, targetDir, modName)
    local contents, readError = bridge.readFile(targetDir .. "modmenu.lua")
    if readError ~= nil then
        return nil, "modmenu.lua could not be read: " .. tostring(readError)
    end
    if contents == nil then return nil, nil end

    local manifest, parseError =
        bridge.evaluateTable(contents, "@" .. modName .. "/modmenu.lua")
    if manifest == nil then
        return nil, "modmenu.lua is invalid: " .. tostring(parseError)
    end
    if manifest.mod ~= nil and manifest.mod ~= modName then
        return nil, "modmenu.lua names a different mod: " ..
            tostring(manifest.mod)
    end
    -- The folder is the identity. A manifest that had to repeat it could
    -- disagree with it, and copying a mod to a new folder would break it.
    manifest.mod = modName
    return manifest, nil
end

function Discovery.discover(scriptDir, bridge)
    if not nonEmptyString(scriptDir) then
        error("canonical ModMenu Scripts directory is unavailable")
    end
    if type(bridge) ~= "table"
        or type(bridge.readFile) ~= "function"
        or type(bridge.readSettings) ~= "function"
        or type(bridge.evaluateTable) ~= "function" then
        error("canonical ModMenuBridge discovery primitives are unavailable")
    end

    local accepted = {}
    local report = {
        registered = 0,
        accepted = {},
        absent = {},
        invalid = {},
    }

    local names, enumerationError = installedModNames()
    if names == nil then
        report.invalid[#report.invalid + 1] = {
            mod = "<Mods directory>",
            reason = tostring(enumerationError),
        }
        return accepted, report
    end
    report.registered = #names

    for _, modName in ipairs(names) do
        local targetDir = scriptDir .. "../../" .. modName .. "/Scripts/"
        local mainPresent, mainError =
            readPresence(bridge, targetDir .. "main.lua")
        local configPresent, configError =
            readPresence(bridge, targetDir .. "config.lua")

        if mainError ~= nil or configError ~= nil then
            report.invalid[#report.invalid + 1] = {
                mod = modName,
                reason = "installation probe failed: " ..
                    tostring(mainError or configError),
            }
        elseif not mainPresent or not configPresent then
            -- Not every folder under Mods/ is a settings-bearing Lua mod, and
            -- one that is not simply has nothing to show here.
            report.absent[#report.absent + 1] = modName
        else
            local manifest, manifestError =
                readManifest(bridge, targetDir, modName)
            if manifestError ~= nil then
                report.invalid[#report.invalid + 1] = {
                    mod = modName,
                    reason = manifestError,
                }
            elseif manifest == nil then
                -- Installed, but has not opted into the menu.
                report.absent[#report.absent + 1] = modName
            else
                local settings, _, info =
                    bridge.readSettings(modName, targetDir)
                if settings == nil then
                    report.invalid[#report.invalid + 1] = {
                        mod = modName,
                        reason = tostring(info and info.error
                            or "settings are unavailable"),
                    }
                else
                    local valid, validationError =
                        validateEntry(manifest, settings)
                    if valid then
                        accepted[#accepted + 1] = manifest
                        report.accepted[#report.accepted + 1] = modName
                    else
                        report.invalid[#report.invalid + 1] = {
                            mod = modName,
                            reason = tostring(validationError),
                        }
                    end
                end
            end
        end
    end

    return accepted, report
end

function Discovery.reportFingerprint(report)
    local parts = {
        tostring(report and report.registered or 0),
        table.concat(report and report.accepted or {}, ","),
        table.concat(report and report.absent or {}, ","),
    }
    for _, item in ipairs(report and report.invalid or {}) do
        parts[#parts + 1] = tostring(item.mod) .. "=" .. tostring(item.reason)
    end
    return table.concat(parts, "\0")
end

return Discovery
