-- Registry-driven discovery for ModMenu.
--
-- Lua in this UE4SS build has no portable directory enumeration contract. The
-- registry remains the explicit compatibility allow-list, while this module
-- discovers which registered integrations are actually installed and accepts
-- only mods whose files, settings, value types, and bounds match that contract.

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

function Discovery.discover(scriptDir, registry, bridge)
    if not nonEmptyString(scriptDir) then
        error("canonical ModMenu Scripts directory is unavailable")
    end
    if type(registry) ~= "table" then error("ModMenu registry must return a table") end
    if type(bridge) ~= "table"
        or type(bridge.readFile) ~= "function"
        or type(bridge.readSettings) ~= "function" then
        error("canonical ModMenuBridge discovery primitives are unavailable")
    end

    local accepted = {}
    local report = {
        registered = #registry,
        accepted = {},
        absent = {},
        invalid = {},
    }

    local seenMods = {}
    for index, entry in ipairs(registry) do
        local modName = type(entry) == "table" and entry.mod or nil
        if not nonEmptyString(modName) then
            report.invalid[#report.invalid + 1] = {
                mod = "registry[" .. tostring(index) .. "]",
                reason = "registered mod folder is unavailable",
            }
        elseif seenMods[modName] then
            report.invalid[#report.invalid + 1] = {
                mod = modName,
                reason = "duplicate registry entry",
            }
        else
            seenMods[modName] = true
            local targetDir = scriptDir .. "../../" .. modName .. "/Scripts/"
            local mainPresent, mainError = readPresence(bridge, targetDir .. "main.lua")
            local configPresent, configError = readPresence(bridge, targetDir .. "config.lua")

            if mainError ~= nil or configError ~= nil then
                report.invalid[#report.invalid + 1] = {
                    mod = modName,
                    reason = "installation probe failed: " .. tostring(mainError or configError),
                }
            elseif not mainPresent and not configPresent then
                report.absent[#report.absent + 1] = modName
            elseif not mainPresent or not configPresent then
                report.invalid[#report.invalid + 1] = {
                    mod = modName,
                    reason = not mainPresent and "Scripts/main.lua is missing"
                        or "Scripts/config.lua is missing",
                }
            else
                local settings, _, info = bridge.readSettings(modName, targetDir)
                if settings == nil then
                    report.invalid[#report.invalid + 1] = {
                        mod = modName,
                        reason = tostring(info and info.error or "settings are unavailable"),
                    }
                else
                    local valid, validationError = validateEntry(entry, settings)
                    if valid then
                        accepted[#accepted + 1] = entry
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
