-- ModMenuBridge v1.0
-- Shared runtime-settings bridge for the Echoes of Aincrad mod stack.
--
-- UE4SS runs every Lua mod in its own isolated state, so ModMenu cannot call
-- into SpeedMod (or any other mod) directly. Instead each mod attaches to this
-- bridge, which watches that mod's own settings files and re-applies them while
-- the game is running.
--
-- Two files per mod, both optional:
--   Scripts/config.lua   hand-written by the player. Never rewritten by ModMenu.
--   Scripts/runtime.lua  written by ModMenu when a value is changed in-game.
--                        Applied on top of config.lua, so it always wins.
--
-- Change detection is content-based: the bridge re-reads both files on a slow
-- poll and only reloads when the bytes actually differ. That means editing
-- config.lua by hand in a text editor also hot-reloads, with no game restart.
--
-- Usage from a mod's main.lua:
--
--   local Bridge = ... -- see loadBridge() pattern in the mods that use this
--   Bridge.attach({
--       modName = "SpeedMod",
--       scriptDir = getScriptDirectory(),
--       load = function(external) applyExternalConfig(external) end,
--       apply = function() applySpeedConfig() end,
--   })
--
-- `load` receives the merged table (config.lua overlaid with runtime.lua) and is
-- responsible for validating it, exactly as the mod already does at startup.
-- `apply` runs afterwards on the game thread, for mods that need to push the new
-- values into live engine state.

local Bridge = {}

local DEFAULT_POLL_MS = 750

-- Reading a file that does not exist is the normal case for runtime.lua, so a
-- miss must be silent rather than an error.
local function readFile(path)
    if type(path) ~= "string" then return nil end
    local ok, contents = pcall(function()
        local handle = io.open(path, "rb")
        if handle == nil then return nil end
        local data = handle:read("*a")
        handle:close()
        return data
    end)
    if ok then return contents end
    return nil
end

Bridge.readFile = readFile

-- Every mod in this stack resolves its own script directory the same way, but
-- UE4SS's working directory is not guaranteed, so keep the relative fallbacks.
local function candidatePaths(modName, scriptDir, fileName)
    local candidates = {}
    local seen = {}

    local function add(path)
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            candidates[#candidates + 1] = path
        end
    end

    if type(scriptDir) == "string" and scriptDir ~= "" then
        add(scriptDir .. fileName)
    end
    if type(modName) == "string" and modName ~= "" then
        add("Mods/" .. modName .. "/Scripts/" .. fileName)
        add("Mods\\" .. modName .. "\\Scripts\\" .. fileName)
    end
    add(fileName)

    return candidates
end

Bridge.candidatePaths = candidatePaths

-- Returns the raw text and the path it came from, so callers can report which
-- file actually won when the working directory is ambiguous.
local function readFirstExisting(modName, scriptDir, fileName)
    for _, path in ipairs(candidatePaths(modName, scriptDir, fileName)) do
        local contents = readFile(path)
        if contents ~= nil then return contents, path end
    end
    return nil, nil
end

Bridge.readFirstExisting = readFirstExisting

-- A settings file is player-editable, so a syntax error is expected sooner or
-- later. Never let it escape: the caller keeps running with its previous values.
local function evaluateTable(contents, chunkName)
    if type(contents) ~= "string" or contents == "" then return nil, nil end

    local loader = load or loadstring
    if loader == nil then return nil, "no Lua chunk loader available" end

    local chunk, compileError = loader(contents, chunkName)
    if chunk == nil then return nil, tostring(compileError) end

    local ok, result = pcall(chunk)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then
        return nil, "settings file did not return a table"
    end
    return result, nil
end

Bridge.evaluateTable = evaluateTable

-- Shallow merge is deliberate. Every tunable in this stack is a scalar or a
-- whole table the mod replaces wholesale (EXCLUDE_QUEST_IDS, FREE_ROAM_QUESTS),
-- so a deep merge would only make partial overrides harder to reason about.
local function overlay(base, override)
    local merged = {}
    if type(base) == "table" then
        for key, value in pairs(base) do merged[key] = value end
    end
    if type(override) == "table" then
        for key, value in pairs(override) do merged[key] = value end
    end
    return merged
end

Bridge.overlay = overlay

-- Reads config.lua + runtime.lua and returns the merged table plus the combined
-- raw text used as the change-detection fingerprint.
function Bridge.readSettings(modName, scriptDir)
    local configText, configPath = readFirstExisting(modName, scriptDir, "config.lua")
    local runtimeText, runtimePath = readFirstExisting(modName, scriptDir, "runtime.lua")

    local fingerprint = tostring(configText or "") .. "\0" .. tostring(runtimeText or "")

    local config, configError = evaluateTable(configText, "@" .. tostring(configPath or "config.lua"))
    local runtime, runtimeError = evaluateTable(runtimeText, "@" .. tostring(runtimePath or "runtime.lua"))

    return overlay(config, runtime), fingerprint, {
        configPath = configPath,
        runtimePath = runtimePath,
        configError = configError,
        runtimeError = runtimeError,
        hasConfig = config ~= nil,
        hasRuntime = runtime ~= nil,
        -- The unmerged halves, so a caller can recompose them differently. attach
        -- uses this to keep the last good overrides when runtime.lua is caught
        -- mid-write.
        config = config,
        runtime = runtime,
        runtimeMissing = runtimeText == nil,
    }
end

-- Attaches a mod to the bridge.
--
-- options.modName   string   folder name under Mods/, used for path fallbacks
-- options.scriptDir string   optional absolute directory of the mod's Scripts/
-- options.load      function receives the merged settings table
-- options.apply     function optional; runs on the game thread after load
-- options.pollMs    number   optional poll interval, defaults to 750ms
-- options.log       function optional logger, receives a single string
--
-- Returns a table with a `reload()` method for callers that want to force a
-- refresh (for example from their own console command).
function Bridge.attach(options)
    if type(options) ~= "table" then return nil end

    local modName = options.modName
    local scriptDir = options.scriptDir
    local pollMs = tonumber(options.pollMs) or DEFAULT_POLL_MS
    local logger = type(options.log) == "function" and options.log or function(message)
        print(string.format("[%s/ModMenu] %s\n", tostring(modName), tostring(message)))
    end

    local lastFingerprint = nil
    local reportedConfigError = nil
    local reportedRuntimeError = nil
    local lastGoodRuntime = nil

    local function refresh(isInitial)
        local settings, fingerprint, info = Bridge.readSettings(modName, scriptDir)

        if not isInitial and fingerprint == lastFingerprint then return false end
        lastFingerprint = fingerprint

        -- ModMenu rewrites runtime.lua on every keypress, so this poll can catch
        -- the file half-written. Dropping to config.lua for one cycle would show
        -- up as a visible lurch in whatever the mod controls, so a file that is
        -- present but unparseable keeps the last overrides that did parse. A file
        -- that is genuinely gone is a reset and must clear them.
        if info.runtimeError ~= nil then
            if lastGoodRuntime ~= nil then
                settings = Bridge.overlay(info.config, lastGoodRuntime)
            end
        elseif info.runtimeMissing then
            lastGoodRuntime = nil
        else
            lastGoodRuntime = info.runtime
        end

        -- Only report a broken settings file once per distinct error, otherwise a
        -- typo left in the file would spam the log on every poll.
        if info.configError ~= nil and info.configError ~= reportedConfigError then
            reportedConfigError = info.configError
            logger("config.lua ignored: " .. info.configError)
        elseif info.configError == nil then
            reportedConfigError = nil
        end
        if info.runtimeError ~= nil and info.runtimeError ~= reportedRuntimeError then
            reportedRuntimeError = info.runtimeError
            logger("runtime.lua ignored: " .. info.runtimeError)
        elseif info.runtimeError == nil then
            reportedRuntimeError = nil
        end

        if not info.hasConfig and not info.hasRuntime then return false end

        if type(options.load) == "function" then
            local ok, err = pcall(options.load, settings, info)
            if not ok then
                logger("failed to apply settings: " .. tostring(err))
                return false
            end
        end

        -- Engine state must only be touched from the game thread. The file poll
        -- itself runs async, so hop threads before the mod pushes values into
        -- live objects.
        if type(options.apply) == "function" then
            local scheduled = pcall(function()
                ExecuteInGameThread(function()
                    local ok, err = pcall(options.apply, settings, info)
                    if not ok then logger("failed to activate settings: " .. tostring(err)) end
                end)
            end)
            if not scheduled then
                local ok, err = pcall(options.apply, settings, info)
                if not ok then logger("failed to activate settings: " .. tostring(err)) end
            end
        end

        if not isInitial then
            logger("settings reloaded in-game")
        end
        return true
    end

    -- The initial pass records the fingerprint without claiming a reload, so the
    -- mod's own startup log stays the single source of truth for load-time values.
    pcall(refresh, true)

    local looping = pcall(function()
        LoopAsync(pollMs, function()
            pcall(refresh, false)
            return false
        end)
    end)
    if not looping then
        logger("runtime settings watch unavailable; values apply on restart only")
    end

    return {
        reload = function() return refresh(true) end,
        modName = modName,
    }
end

return Bridge
