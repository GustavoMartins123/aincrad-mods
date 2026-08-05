-- Folder-driven discovery for ModMenu.
--
-- There is no central allow-list and nothing to opt into. Every folder under
-- Mods/ is enumerated through IterateGameDirectories, and every one of them
-- that UE4SS would load as a Lua mod is listed, so dropping a mod into the
-- folder is the whole of installing it.
--
-- A mod is listed in one of two shapes:
--
--   configured  it ships Scripts/modmenu.lua declaring its own settings next
--               to the config.lua those settings live in, and that contract
--               validates against the mod's real effective settings. The menu
--               expands it and edits those settings.
--   basic       everything else. The menu cannot know what the mod's settings
--               mean, so it offers the one thing it does know: whether UE4SS
--               loads the mod at all, held in Mods/<Mod>/enabled.txt.
--
-- A drifted or broken contract degrades to basic and says why in the log. It
-- costs the mod its settings rows, never its place in the list.

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
    -- Optional. A mod sets this when it wants to be told, through its own
    -- Scripts/preview.lua, that its settings page is currently expanded --
    -- a live preview, typically. Declaring it is the mod's business; the menu
    -- neither knows nor cares which mods do.
    if entry.preview ~= nil and type(entry.preview) ~= "boolean" then
        return nil, entry.mod .. " preview must be boolean when declared"
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

-- Paths arrive from two unrelated sources -- Lua's own debug info and UE4SS's
-- __absolute_path -- so they are compared only in this one shape: forward
-- slashes, no trailing slash, lower case. Windows treats case as insignificant
-- and this walk must not be the one thing that disagrees.
local function normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local normalized = path:gsub("\\", "/"):gsub("/+$", ""):lower()
    if normalized == "" then return nil end
    return normalized
end

local function parentDirectory(path)
    if type(path) ~= "string" then return nil end
    return path:match("^(.*)/[^/]+$")
end

-- Every folder under Mods/, by name. This is what makes a central allow-list
-- unnecessary: the installed set is read off disk instead of declared.
--
-- The descent is driven by this mod's own absolute path, not by an assumed
-- .Game.Binaries.<platform>.ue4ss.Mods shape. Binaries/ is not guaranteed to
-- hold the platform folder alone -- on this install it also holds six loose
-- mod folders -- so treating it as a single child walked into whichever one
-- pairs() happened to yield first and reported the Mods directory as missing.
-- ModMenu already knows exactly where it was loaded from; that is a fact about
-- the install rather than a guess about the loader, so it drives the walk.
local function installedModNames(scriptDir)
    if type(IterateGameDirectories) ~= "function" then
        return nil, "this UE4SS build does not expose IterateGameDirectories"
    end

    local ok, directories = pcall(IterateGameDirectories)
    if not ok or type(directories) ~= "table" then
        return nil, "IterateGameDirectories returned no directory tree"
    end

    -- The game folder is keyed "Game" whatever it is really called.
    local root = childDirectory(directories, "Game")
    if type(root) ~= "table" then
        return nil, "the game directory tree has no Game folder"
    end
    local rootPath = normalizePath(root.__absolute_path)
    if rootPath == nil then
        return nil, "the game directory tree exposes no absolute path"
    end

    -- <Mods>/ModMenu/Scripts/ -> <Mods>
    local modsRoot = parentDirectory(parentDirectory(normalizePath(scriptDir)))
    if modsRoot == nil then
        return nil, "there is no Mods directory above " .. tostring(scriptDir)
    end

    if modsRoot:sub(1, #rootPath) ~= rootPath
        or modsRoot:sub(#rootPath + 1, #rootPath + 1) ~= "/" then
        return nil, string.format(
            "the Mods directory (%s) is not inside the game tree (%s)",
            modsRoot, rootPath)
    end

    local mods = root
    local relative = modsRoot:sub(#rootPath + 2)
    for segment in relative:gmatch("[^/]+") do
        mods = childDirectory(mods, segment)
        if type(mods) ~= "table" then
            return nil, string.format(
                "the game tree stops at %s on the way to %s", segment, relative)
        end
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

-- Mods named in Mods/mods.txt or Mods/mods.json are the loader's own suite
-- entries -- BPModLoaderMod, BPML_GenericFunctions, Keybinds. UE4SS switches
-- those from those files, not from a per-folder enabled.txt, so an ON/OFF row
-- here could not tell the truth about them and they are left out entirely.
-- This menu is for mods the player drops into the folder.
local function suiteManagedNames(bridge, modsDir)
    local managed = {}

    local listText = bridge.readFile(modsDir .. "mods.txt")
    if type(listText) == "string" then
        for line in listText:gmatch("[^\r\n]+") do
            if line:match("^%s*;") == nil then
                -- "<Name> : <0 or 1>"
                local name = line:match("^%s*([%w_.-]+)%s*:")
                if name ~= nil then managed[name] = true end
            end
        end
    end

    -- Read for its names only; the enabled flag beside them is not this menu's
    -- to interpret, so no JSON parser has to be right about anything else.
    local jsonText = bridge.readFile(modsDir .. "mods.json")
    if type(jsonText) == "string" then
        for name in jsonText:gmatch('"mod_name"%s*:%s*"([^"]+)"') do
            managed[name] = true
        end
    end

    return managed
end

-- ModMenu's own folder, taken from the Scripts directory it was loaded from so
-- that renaming the folder cannot make the menu list itself. Switching this mod
-- off from inside its own panel would close the only door back in.
local function owningModName(scriptDir)
    return scriptDir:match("([^\\/]+)[\\/][Ss]cripts[\\/]$")
end

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

-- A mod without a usable settings contract still belongs in the list: UE4SS
-- loads it, so the player has to be able to switch it off from here. It simply
-- has nothing to expand, and its only value is the enabled.txt marker -- which
-- UE4SS reads once at startup, hence the restart marker.
local function basicEntry(modName)
    return {
        mod = modName,
        label = modName,
        summary = "No in-game settings.",
        apply = "restart",
        settings = {},
        configured = false,
        -- No manifest, so nothing was declared: no rows to expand and nothing
        -- to be told about.
        preview = false,
    }
end

-- Returns the entry to list, plus a reason when a mod meant to be configured
-- had to fall back to on/off. The reason is for the log; the entry is shown
-- either way.
local function describeMod(bridge, targetDir, modName)
    local manifest, manifestError = readManifest(bridge, targetDir, modName)
    if manifestError ~= nil then
        return basicEntry(modName), manifestError
    end
    if manifest == nil then
        -- Installed, and simply has no settings to offer.
        return basicEntry(modName), nil
    end

    local configPresent, configError =
        readPresence(bridge, targetDir .. "config.lua")
    if configError ~= nil then
        return basicEntry(modName),
            "config.lua could not be read: " .. tostring(configError)
    end
    if not configPresent then
        return basicEntry(modName),
            "modmenu.lua declares settings but there is no config.lua"
    end

    local settings, _, info = bridge.readSettings(modName, targetDir)
    if settings == nil then
        return basicEntry(modName),
            tostring(info and info.error or "settings are unavailable")
    end

    local valid, validationError = validateEntry(manifest, settings)
    if not valid then
        return basicEntry(modName), tostring(validationError)
    end

    manifest.configured = true
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
        configured = {},
        basic = {},
        skipped = {},
        invalid = {},
    }

    local names, enumerationError = installedModNames(scriptDir)
    if names == nil then
        report.invalid[#report.invalid + 1] = {
            mod = "<Mods directory>",
            reason = tostring(enumerationError),
        }
        return accepted, report
    end

    local modsDir = scriptDir .. "../../"
    local suiteManaged = suiteManagedNames(bridge, modsDir)
    local ownName = owningModName(scriptDir)

    for _, modName in ipairs(names) do
        local targetDir = modsDir .. modName .. "/Scripts/"

        if modName == ownName or suiteManaged[modName] then
            report.skipped[#report.skipped + 1] = modName
        else
            local mainPresent, mainError =
                readPresence(bridge, targetDir .. "main.lua")

            if mainError ~= nil then
                -- A folder that cannot even be probed is one this menu has no
                -- business claiming to switch.
                report.invalid[#report.invalid + 1] = {
                    mod = modName,
                    reason = "installation probe failed: " .. tostring(mainError),
                }
                report.skipped[#report.skipped + 1] = modName
            elseif not mainPresent then
                -- Not every folder under Mods/ is a UE4SS Lua mod. shared/ is
                -- a library folder, not something to switch on and off.
                report.skipped[#report.skipped + 1] = modName
            else
                local entry, reason = describeMod(bridge, targetDir, modName)
                if reason ~= nil then
                    report.invalid[#report.invalid + 1] = {
                        mod = modName,
                        reason = reason,
                    }
                end

                accepted[#accepted + 1] = entry
                report.registered = report.registered + 1
                if entry.configured then
                    report.configured[#report.configured + 1] = modName
                else
                    report.basic[#report.basic + 1] = modName
                end
            end
        end
    end

    return accepted, report
end

function Discovery.reportFingerprint(report)
    local parts = {
        tostring(report and report.registered or 0),
        table.concat(report and report.configured or {}, ","),
        table.concat(report and report.basic or {}, ","),
        table.concat(report and report.skipped or {}, ","),
    }
    for _, item in ipairs(report and report.invalid or {}) do
        parts[#parts + 1] = tostring(item.mod) .. "=" .. tostring(item.reason)
    end
    return table.concat(parts, "\0")
end

return Discovery
