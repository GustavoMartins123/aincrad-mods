-- ModMenuBridge v2.0
-- Strict runtime-settings bridge for the Echoes of Aincrad mod stack.
--
-- Each UE4SS Lua mod has an isolated Lua state. This bridge watches exactly:
--   <mod Scripts directory>/config.lua   (required)
--   <mod Scripts directory>/runtime.lua  (optional)
--
-- There are no working-directory aliases or retained substitute settings.
-- A read, parse, validation, scheduling, or activation failure invokes the
-- mod's required fail handler. A later valid file change may activate it again.

local Bridge = {}

local function readExactFile(path, required)
    if type(path) ~= "string" or path == "" then
        return nil, "canonical file path is unavailable"
    end

    local handle, openError, errorCode = io.open(path, "rb")
    if handle == nil then
        if not required and errorCode == 2 then return nil, nil end
        return nil, tostring(openError)
    end

    local ok, contents = pcall(function()
        local data = handle:read("*a")
        handle:close()
        return data
    end)
    if not ok then
        pcall(function() handle:close() end)
        return nil, tostring(contents)
    end
    if type(contents) ~= "string" then
        return nil, "file read returned no text"
    end
    return contents, nil
end

-- Kept as a public exact-path primitive for ModMenu's store.
function Bridge.readFile(path)
    return readExactFile(path, false)
end

local function evaluateTable(contents, chunkName)
    if type(contents) ~= "string" then
        return nil, "settings text is unavailable"
    end
    if type(load) ~= "function" then
        return nil, "Lua chunk loader is unavailable"
    end

    local chunk, compileError = load(contents, chunkName, "t", {})
    if chunk == nil then return nil, tostring(compileError) end
    local ok, result = pcall(chunk)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then
        return nil, "settings file must return a table"
    end
    return result, nil
end

Bridge.evaluateTable = evaluateTable

local function overlay(base, runtime)
    local merged = {}
    for key, value in pairs(base) do merged[key] = value end
    if runtime ~= nil then
        for key, value in pairs(runtime) do merged[key] = value end
    end
    return merged
end

Bridge.overlay = overlay

function Bridge.readSettings(_modName, scriptDir)
    if type(scriptDir) ~= "string" or scriptDir == "" then
        return nil, nil, {
            error = "canonical Scripts directory is unavailable",
        }
    end

    local configPath = scriptDir .. "config.lua"
    local runtimePath = scriptDir .. "runtime.lua"
    local configText, configReadError = readExactFile(configPath, true)
    local runtimeText, runtimeReadError = readExactFile(runtimePath, false)
    local fingerprint =
        tostring(configText or "") .. "\0" ..
        tostring(runtimeText or "") .. "\0" ..
        tostring(configReadError or "") .. "\0" ..
        tostring(runtimeReadError or "")

    if configText == nil then
        return nil, fingerprint, {
            error = "config.lua read failed: " .. tostring(configReadError),
            configPath = configPath,
            runtimePath = runtimePath,
        }
    end
    if runtimeReadError ~= nil then
        return nil, fingerprint, {
            error = "runtime.lua read failed: " .. tostring(runtimeReadError),
            configPath = configPath,
            runtimePath = runtimePath,
        }
    end

    local config, configError = evaluateTable(configText, "@" .. configPath)
    if config == nil then
        return nil, fingerprint, {
            error = "config.lua rejected: " .. tostring(configError),
            configPath = configPath,
            runtimePath = runtimePath,
        }
    end

    local runtime = nil
    if runtimeText ~= nil then
        local runtimeError
        runtime, runtimeError = evaluateTable(runtimeText, "@" .. runtimePath)
        if runtime == nil then
            return nil, fingerprint, {
                error = "runtime.lua rejected: " .. tostring(runtimeError),
                configPath = configPath,
                runtimePath = runtimePath,
            }
        end
    end

    return overlay(config, runtime), fingerprint, {
        error = nil,
        configPath = configPath,
        runtimePath = runtimePath,
        config = config,
        runtime = runtime,
        runtimeMissing = runtimeText == nil,
    }
end

local function requireOption(options, key, expected)
    local value = options[key]
    if type(value) ~= expected then
        return nil, key .. " must be " .. expected
    end
    if expected == "string" and value == "" then
        return nil, key .. " must not be empty"
    end
    return value, nil
end

function Bridge.attach(options)
    if type(options) ~= "table" then
        return nil, "options must be a table"
    end

    local modName, optionError = requireOption(options, "modName", "string")
    if modName == nil then return nil, optionError end
    local scriptDir
    scriptDir, optionError = requireOption(options, "scriptDir", "string")
    if scriptDir == nil then return nil, optionError end
    local loadSettings
    loadSettings, optionError = requireOption(options, "load", "function")
    if loadSettings == nil then return nil, optionError end
    local fail
    fail, optionError = requireOption(options, "fail", "function")
    if fail == nil then return nil, optionError end
    local logger
    logger, optionError = requireOption(options, "log", "function")
    if logger == nil then return nil, optionError end

    local pollMs = options.pollMs
    if type(pollMs) ~= "number" or pollMs < 100 or pollMs > 10000 then
        return nil, "pollMs must be between 100 and 10000"
    end
    local activate = options.apply
    if activate ~= nil and type(activate) ~= "function" then
        return nil, "apply must be a function when provided"
    end

    local lastFingerprint = nil
    local lastFailure = nil

    local function dispatchFailure(message)
        local failure = tostring(message)
        if failure ~= lastFailure then
            lastFailure = failure
            logger("CONFIG ERROR | " .. failure .. " | mod disabled")
        end
        local scheduled, scheduleError = pcall(function()
            ExecuteInGameThread(function()
                local ok, failError = pcall(fail, failure)
                if not ok then
                    logger("FAIL-CLOSED ERROR | " .. tostring(failError))
                end
            end)
        end)
        if not scheduled then
            logger("SCHEDULING ERROR | " .. tostring(scheduleError))
        end
    end

    local function refresh(force, isInitial)
        local settings, fingerprint, info =
            Bridge.readSettings(modName, scriptDir)
        if not force and fingerprint == lastFingerprint then return false end
        lastFingerprint = fingerprint

        if settings == nil then
            dispatchFailure(info and info.error or "settings rejected")
            return false
        end

        local scheduled, scheduleError = pcall(function()
            ExecuteInGameThread(function()
                local okLoad, loadError = pcall(loadSettings, settings, info)
                if not okLoad then
                    dispatchFailure("settings validation failed: " ..
                        tostring(loadError))
                    return
                end
                if activate ~= nil then
                    local okApply, applyError = pcall(activate, settings, info)
                    if not okApply then
                        dispatchFailure("settings activation failed: " ..
                            tostring(applyError))
                        return
                    end
                end
                lastFailure = nil
                if not isInitial then logger("settings reloaded in-game") end
            end)
        end)
        if not scheduled then
            dispatchFailure("game-thread scheduling failed: " ..
                tostring(scheduleError))
            return false
        end
        return true
    end

    refresh(true, true)

    local polling = true
    local function schedulePoll()
        if not polling then return end
        local scheduled, scheduleError = pcall(function()
            ExecuteWithDelay(pollMs, function()
                refresh(false, false)
                schedulePoll()
            end)
        end)
        if not scheduled then
            polling = false
            dispatchFailure("settings poll scheduling failed: " ..
                tostring(scheduleError))
        end
    end
    schedulePoll()

    return {
        reload = function() return refresh(true, false) end,
        stop = function() polling = false end,
        modName = modName,
    }, nil
end

return Bridge
