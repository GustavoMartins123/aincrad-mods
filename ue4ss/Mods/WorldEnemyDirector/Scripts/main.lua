local MOD_NAME = "WorldEnemyDirector"
local MOD_VERSION = "1.7.2"

print(string.format("[%s] Loading v%s\n", MOD_NAME, MOD_VERSION))

-- The directory containing this script is the only accepted configuration
-- root. Failure to resolve it is fatal; no working-directory path is used.
local sourceInfo = debug.getinfo(1, "S")
if type(sourceInfo) ~= "table" or type(sourceInfo.source) ~= "string" then
    error("[" .. MOD_NAME .. "] CONFIG ERROR | script source is unavailable")
end
local sourcePath = sourceInfo.source
if sourcePath:sub(1, 1) == "@" then sourcePath = sourcePath:sub(2) end
local SCRIPT_DIR = sourcePath:match("^(.*[\\/])")
if type(SCRIPT_DIR) ~= "string" or SCRIPT_DIR == "" then
    error("[" .. MOD_NAME .. "] CONFIG ERROR | canonical script directory is unavailable")
end

local CONFIG_PATH = SCRIPT_DIR .. "config.lua"
local RUNTIME_PATH = SCRIPT_DIR .. "runtime.lua"
local RUNTIME_LOCK_PATH = RUNTIME_PATH .. ".lock"

local STARTUP_SETTLE_MS = 2000
local RESTART_SETTLE_MS = 1500
local QUEST_TELEPORT_SETTLE_MS = 2000
local STABILITY_SAMPLES_REQUIRED = 3
local DISCOVERY_STABILIZE_MS = 2000
local SETTINGS_POLL_MS = 1000
local SPAWN_INITIALIZE_MS = 8000
-- How close a newly seen enemy must be to where a request asked for one
-- The spawn point is lifted off the navmesh surface before the actor is
-- created. Spawning a character capsule exactly on the ground fails the
-- collision check; this was in the mod originally and its removal is what
-- silently stopped multiplication.
local SPAWN_Z_OFFSET_CM = 40.0
local SPAWN_COLLISION_ALWAYS = 1
local SPAWN_SCALE_MULTIPLY_ROOT = 1
-- Requests allowed to expire unmatched, in a row, before multiplication is
-- declared non-functional for this session.
local UNMATCHED_SPAWN_GIVE_UP = 12
-- How often origins near the hero are revisited when nothing was freed.
local ORIGIN_SWEEP_MS = 3000
local NAV_ATTEMPTS_PER_PASS = 1
local NAV_MAX_ATTEMPTS = 12
local NAV_MIN_SEPARATION_CM = 150.0
local MAX_DISCOVERY_PER_TICK = 2
local GAMEPLAY_MOD_ADDITIVE = 0
local SPAWN_ON_SERVER = 0
local INITIAL_STATE_PROWL = 0
local SPAWN_COLLISION_ADJUST_OR_REJECT = 3
local GAS_VALUE_EPSILON = 0.01
local ENEMY_ROLE_NONE = 0
local ENEMY_ROLE_BOSS = 3

local GAS_ATTRIBUTE_NAMES = {
    health = "Health",
    maxHealth = "MaxHealth",
    attack = "ATK",
    baseAttack = "BaseATK",
    defence = "Def",
    baseDefence = "BaseDEF",
}

local PALETTE = {
    crimson = { R = 0.85, G = 0.04, B = 0.08, A = 1.0 },
    emerald = { R = 0.03, G = 0.80, B = 0.20, A = 1.0 },
    azure = { R = 0.04, G = 0.28, B = 0.95, A = 1.0 },
    gold = { R = 1.00, G = 0.58, B = 0.04, A = 1.0 },
    violet = { R = 0.56, G = 0.08, B = 0.92, A = 1.0 },
    cyan = { R = 0.02, G = 0.90, B = 0.90, A = 1.0 },
    white = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
}
local PALETTE_NAMES = {
    "crimson", "emerald", "azure", "gold", "violet", "cyan", "white",
}

local SCHEMA = {
    ENABLED = { kind = "boolean" },
    SPAWN_MULTIPLIER = { kind = "number", minimum = 1, maximum = 8, integer = true },
    MAX_ACTIVE_EXTRAS = { kind = "number", minimum = 0, maximum = 200, integer = true },
    SPAWN_RADIUS = { kind = "number", minimum = 100.0, maximum = 1500.0 },
    RANDOMIZE_EXTRA_SPECIES = { kind = "boolean" },
    INCLUDE_BOSSES = { kind = "boolean" },
    SCALE_MIN = { kind = "number", minimum = 0.25, maximum = 4.0 },
    SCALE_MAX = { kind = "number", minimum = 0.25, maximum = 4.0 },
    COLOR_MODE = { kind = "choice", values = { off = true, fixed = true, random = true } },
    COLOR_PRESET = { kind = "choice", values = PALETTE },
    COLOR_PARAMETER_NAME = { kind = "string" },
    HEALTH_MULTIPLIER = { kind = "number", minimum = 0.10, maximum = 10.0 },
    ATTACK_MULTIPLIER = { kind = "number", minimum = 0.10, maximum = 10.0 },
    DEFENCE_MULTIPLIER = { kind = "number", minimum = 0.10, maximum = 10.0 },
    MOVE_SPEED_MULTIPLIER = { kind = "number", minimum = 0.25, maximum = 3.0 },
    XP_MULTIPLIER = { kind = "number", minimum = 0.0, maximum = 10.0 },
    POLL_MS = { kind = "number", minimum = 100, maximum = 2000, integer = true },
    DESPAWN_RADIUS = { kind = "number", minimum = 1500.0, maximum = 30000.0 },
    DEBUG_LOGS = { kind = "boolean" },
}

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local CONFIG = nil
local configDigest = nil
local configHealthy = false
local elapsedMs = 0
local lastSettingsCheckMs = -SETTINGS_POLL_MS

local function dbg(message)
    if CONFIG ~= nil and CONFIG.DEBUG_LOGS then log(message) end
end

local function readFile(path, required)
    local handle, openError, errorCode = io.open(path, "rb")
    if handle == nil then
        if not required and errorCode == 2 then return nil, nil end
        return nil, tostring(openError)
    end
    local ok, contents = pcall(function()
        local value = handle:read("*a")
        handle:close()
        return value
    end)
    if not ok then
        pcall(function() handle:close() end)
        return nil, tostring(contents)
    end
    if type(contents) ~= "string" then return nil, "file read returned no text" end
    return contents, nil
end

local function evaluateTable(contents, path)
    if type(load) ~= "function" then return nil, "Lua chunk loader is unavailable" end
    local chunk, compileError = load(contents, "@" .. path, "t", {})
    if chunk == nil then return nil, tostring(compileError) end
    local ok, value = pcall(chunk)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "table" then
        return nil, path .. " must return a table"
    end
    return value, nil
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function validateOne(key, value, rule)
    if rule.kind == "boolean" then
        if type(value) ~= "boolean" then return nil, key .. " must be boolean" end
        return value, nil
    end
    if rule.kind == "string" then
        if type(value) ~= "string" or value == "" then
            return nil, key .. " must be a non-empty string"
        end
        return value, nil
    end
    if rule.kind == "choice" then
        if type(value) ~= "string" or rule.values[value] == nil then
            return nil, key .. " has an unsupported value: " .. tostring(value)
        end
        return value, nil
    end
    if rule.kind == "number" then
        if not finiteNumber(value) then return nil, key .. " must be a finite number" end
        if value < rule.minimum or value > rule.maximum then
            return nil, string.format(
                "%s must be between %s and %s",
                key,
                tostring(rule.minimum),
                tostring(rule.maximum)
            )
        end
        if rule.integer and value % 1 ~= 0 then return nil, key .. " must be an integer" end
        return value, nil
    end
    return nil, "invalid schema for " .. key
end

local function validateSettings(base, runtime)
    for key, _ in pairs(base) do
        if SCHEMA[key] == nil then return nil, "unknown config.lua key: " .. tostring(key) end
    end
    for key, _ in pairs(runtime) do
        if SCHEMA[key] == nil then return nil, "unknown runtime.lua key: " .. tostring(key) end
    end

    local merged = {}
    for key, rule in pairs(SCHEMA) do
        if base[key] == nil then return nil, "missing config.lua key: " .. key end
        local value = base[key]
        if runtime[key] ~= nil then value = runtime[key] end
        local checked, valueError = validateOne(key, value, rule)
        if valueError ~= nil then return nil, valueError end
        merged[key] = checked
    end

    if merged.SCALE_MIN > merged.SCALE_MAX then
        return nil, "SCALE_MIN must be less than or equal to SCALE_MAX"
    end
    return merged, nil
end

local RUNTIME_REV_PATH = SCRIPT_DIR .. "runtime.rev"

local function loadSettings()
    local revContents, _ = readFile(RUNTIME_REV_PATH, false)
    local transactionContents, transactionReadError =
        readFile(RUNTIME_LOCK_PATH, false)
    if transactionReadError ~= nil then
        return nil, nil,
            "cannot read runtime transaction lock: " ..
                tostring(transactionReadError),
            false
    end
    if transactionContents ~= nil then
        return nil, "TRANSACTION-ACTIVE\0" .. transactionContents, nil, true
    end

    local configContents, configReadError = readFile(CONFIG_PATH, true)
    if configContents == nil then return nil, nil, "cannot read config.lua: " .. configReadError end

    local runtimeContents, runtimeReadError = readFile(RUNTIME_PATH, false)
    if runtimeReadError ~= nil then
        return nil, nil, "cannot read runtime.lua: " .. runtimeReadError
    end

    local digest = tostring(revContents or "") .. "\0" .. configContents .. "\0" .. (runtimeContents or "")
    if digest == configDigest and configHealthy then
        return nil, digest, nil, false
    end

    local base, baseError = evaluateTable(configContents, CONFIG_PATH)
    if base == nil then return nil, nil, baseError end

    local runtime = {}
    if runtimeContents ~= nil then
        local parsed, runtimeError = evaluateTable(runtimeContents, RUNTIME_PATH)
        if parsed == nil then return nil, nil, runtimeError end
        runtime = parsed
    end

    local merged, validationError = validateSettings(base, runtime)
    if merged == nil then return nil, nil, validationError end
    return merged, digest, nil, false
end

local function isValid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function enemyOperational(enemy)
    if not isValid(enemy) then return false, "enemy object is invalid" end
    local ok, initialized, dead, healthZero = pcall(function()
        return enemy.bInitialized, enemy:IsDead(), enemy:IsHealthZero()
    end)
    if not ok then
        return false, "canonical enemy lifecycle state is unreadable"
    end
    if initialized ~= true then return false, "enemy is not initialized" end
    if dead == true or healthZero == true then return false, "enemy is dead" end
    return true, nil
end

local function objectKey(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function firstErrorLine(value)
    local message = tostring(value):gsub("\r", "")
    message = message:match("([^\n]+)") or "unknown error"
    if #message > 320 then
        message = message:sub(1, 320) .. "..."
    end
    return message
end

local function summarizeSpawnCallError(value)
    local message = tostring(value):gsub("\r", "")
    local summary = firstErrorLine(message)
    local property = message:match(
        "Property%s*%([^%)]*%):%s*([^\n]+)"
    )
    if type(property) == "string" and property ~= "" then
        summary = summary .. " | property=" .. property
    end
    local stack = message:match(
        "LUA Stack dump %-%> START%-+%s*(.-)%s*" ..
        "LUA Stack dump %-%> END"
    )
    if type(stack) == "string" and stack ~= "" then
        stack = stack:gsub("[%s\t]+", " ")
        if #stack > 180 then stack = stack:sub(1, 180) .. "..." end
        summary = summary .. " | remaining-stack=" .. stack
    end
    return summary
end

local function resolveExactObject(fullName)
    if type(fullName) ~= "string" or fullName == "" then
        return nil, "canonical object name is missing"
    end
    local path = fullName:match("^%S+%s+(.+)$")
    if path == nil or path == "" then
        return nil, "canonical object path is malformed: " .. fullName
    end
    local ok, object = pcall(StaticFindObject, path)
    if not ok then
        return nil, "StaticFindObject failed for " .. path .. ": " ..
            firstErrorLine(object)
    end
    if type(object) ~= "userdata" or not isValid(object) then
        return nil, "StaticFindObject did not return a live UObject for " .. path
    end
    if objectKey(object) ~= fullName then
        return nil, "StaticFindObject identity mismatch for " .. path
    end
    return object, nil
end

local function classData(enemy)
    local ok, classObject, className = pcall(function()
        local class = enemy:GetClass()
        return class, class:GetFullName()
    end)
    if not ok or not isValid(classObject) or type(className) ~= "string" then
        return nil, nil, "GetClass failed"
    end
    return classObject, className, nil
end

local function vector(value)
    local ok, x, y, z = pcall(function()
        return tonumber(value.X), tonumber(value.Y), tonumber(value.Z)
    end)
    if not ok or not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then
        return nil
    end
    return { X = x, Y = y, Z = z }
end

local function actorLocation(actor)
    local ok, value = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok then return nil, tostring(value) end
    local parsed = vector(value)
    if parsed == nil then return nil, "K2_GetActorLocation returned an invalid vector" end
    return parsed, nil
end

local states = {}
local origins = {}
local classCatalog = {}
local classOrder = {}
local protectedBossClasses = {}
local gasAttributesByClass = {}
local readinessStabilitySamples = 0
local objectQueue = {}
local spawnQueue = {}
local pendingSpawns = {}
local discoveryBatch = false
local discoveryReadyAtMs = nil
local generation = 1
local worldPaused = true
local resumeAtMs = STARTUP_SETTLE_MS
local rescanRequested = false
local worldFault = nil
local awaitingTravelRestart = false

local materialLibrary = nil
local materialInterface = nil
local navigationSystem = nil
local gameplayStatics = nil
local worldPartitionSubsystem = nil
local streamingGateReported = false
local spawnContractVerified = false
-- Consecutive spawn requests that expired without ever being matched to a
-- new enemy. A spawn API that quietly does nothing looks exactly like this.
local unmatchedSpawnStreak = 0
local spawningProvenInert = false
local cachedHero = nil
local nextOriginSweepMs = 0
local spawnOrderProbeIds = nil
local spawnOrderProbeReported = false
local disableWorld
-- Assigned below; called from registerEnemy, which is defined before it.
local activateSpawnedEnemy
local releaseWorldForTravel
local gcScheduled = false

local function scheduleReferenceCollection()
    if gcScheduled then return end
    gcScheduled = true
    ExecuteWithDelay(1, function()
        gcScheduled = false
    end)
end

local function clearWorldReferences()
    states = {}
    origins = {}
    classCatalog = {}
    classOrder = {}
    protectedBossClasses = {}
    gasAttributesByClass = {}
    readinessStabilitySamples = 0
    objectQueue = {}
    spawnQueue = {}
    pendingSpawns = {}
    discoveryBatch = false
    discoveryReadyAtMs = nil
    worldFault = nil
    navigationSystem = nil
    gameplayStatics = nil
    worldPartitionSubsystem = nil
    spawnContractVerified = false
    unmatchedSpawnStreak = 0
    spawningProvenInert = false
    cachedHero = nil
    nextOriginSweepMs = 0
end

local function beginTravel(reason)
    if awaitingTravelRestart and worldPaused and resumeAtMs == nil then return end
    generation = generation + 1
    awaitingTravelRestart = true
    worldPaused = true
    resumeAtMs = nil
    local released, releaseFailures = 0, 0
    if releaseWorldForTravel ~= nil then
        released, releaseFailures =
            releaseWorldForTravel("world transition: " .. reason)
    end
    clearWorldReferences()
    scheduleReferenceCollection()
    if releaseFailures > 0 then
        log(string.format(
            "TRAVEL CLEANUP ERROR | %s | released=%d failed=%d",
            reason,
            released,
            releaseFailures
        ))
    end
    log(string.format(
        "TRAVEL START | %s | owned references released=%d | native references cleared",
        reason,
        released
    ))
end

local function beginRestartSettle()
    local followedTravel = awaitingTravelRestart
    awaitingTravelRestart = false
    worldPaused = true
    local requestedResumeAtMs = elapsedMs + RESTART_SETTLE_MS
    if resumeAtMs == nil or resumeAtMs < requestedResumeAtMs then
        resumeAtMs = requestedResumeAtMs
    end

    if followedTravel then
        clearWorldReferences()
        scheduleReferenceCollection()
        log("TRAVEL SETTLE | ClientRestart after travel | waiting 5 seconds")
        return
    end

    log(string.format(
        "WORLD QUARANTINE | ClientRestart without travel | retained states=%d pending=%d queued=%d",
        (function()
            local count = 0
            for _, _ in pairs(states) do count = count + 1 end
            return count
        end)(),
        #pendingSpawns,
        #spawnQueue
    ))
end

local function beginSameWorldSettle(reason)
    if awaitingTravelRestart and worldPaused and resumeAtMs == nil then return end
    worldPaused = true
    local requestedResumeAtMs = elapsedMs + QUEST_TELEPORT_SETTLE_MS
    if resumeAtMs == nil or resumeAtMs < requestedResumeAtMs then
        resumeAtMs = requestedResumeAtMs
    end
    log(string.format(
        "WORLD QUARANTINE | %s | retained states and waiting %d seconds",
        tostring(reason),
        QUEST_TELEPORT_SETTLE_MS / 1000
    ))
end

local function beginQuestTeleportSettle()
    beginSameWorldSettle("ServerNotifyQuestTeleportOut")
end

local function resolveMaterialApi()
    if isValid(materialLibrary) and isValid(materialInterface) then return true, nil end
    local ok, library, interface = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"),
            StaticFindObject("/Script/ROD.RODMaterialParameterInterface")
    end)
    if not ok or not isValid(library) or not isValid(interface) then
        return false, "canonical material API objects are unavailable"
    end
    materialLibrary = library
    materialInterface = interface
    return true, nil
end

-- Reports, once per session, what the engine itself passes to RODSpawnActor.
--
-- This exists because the argument layout cannot be read back on this build:
-- ForEachProperty is not exposed on a UFunction here, and passing the six values
-- in the order the header declares them lands the collision-handling enum on
-- InInstigator. Watching a real call is the remaining source of truth. The game
-- spawns constantly, so this costs one natural spawn to answer.
--
-- Strictly read-only: it observes, logs one line, and unregisters itself. It
-- never alters the call it is watching.
local function describeSpawnArgument(value)
    if value == nil then return "nil" end
    local unwrapped = value
    local unwrapOk, inner = pcall(function() return value:get() end)
    if unwrapOk and inner ~= nil then unwrapped = inner end

    local kind = type(unwrapped)
    if kind ~= "userdata" and kind ~= "table" then
        return kind .. "(" .. tostring(unwrapped) .. ")"
    end

    local nameOk, fullName = pcall(function() return unwrapped:GetFullName() end)
    if nameOk and type(fullName) == "string" and fullName ~= "" then
        return "object[" .. fullName .. "]"
    end
    -- Structs have no GetFullName. Name them by a field only they carry.
    for field, label in pairs({
        Translation = "FTransform",
        DefaultSpawnOn = "FRODSpawnActorOption",
    }) do
        local fieldOk, fieldValue = pcall(function() return unwrapped[field] end)
        if fieldOk and fieldValue ~= nil then return "struct[" .. label .. "]" end
    end
    return kind .. "[unidentified]"
end

local function armSpawnOrderProbe()
    if spawnOrderProbeIds ~= nil or spawnOrderProbeReported then return end

    local ok, idsOrError = pcall(function()
        local preId, postId = RegisterHook(
            "/Script/ROD.RODGameState:RODSpawnActor",
            function(_self, a, b, c, d, e, f)
                if spawnOrderProbeReported then return end
                spawnOrderProbeReported = true
                log("SPAWN PROBE | engine call arguments:"
                    .. " 1=" .. describeSpawnArgument(a)
                    .. " 2=" .. describeSpawnArgument(b)
                    .. " 3=" .. describeSpawnArgument(c)
                    .. " 4=" .. describeSpawnArgument(d)
                    .. " 5=" .. describeSpawnArgument(e)
                    .. " 6=" .. describeSpawnArgument(f))
                -- Unregistering from inside the callback is not safe; the flag
                -- above makes every later call a single comparison, and the
                -- next world teardown releases the hook.
            end
        )
        return { pre = preId, post = postId }
    end)
    if not ok then
        log("SPAWN PROBE | could not watch RODSpawnActor: " .. tostring(idsOrError))
        return
    end
    spawnOrderProbeIds = idsOrError
    log("SPAWN PROBE | watching the next engine RODSpawnActor call")
end

-- The local host controller, which owns ServerDebugEnemySpawn. Resolved fresh
-- each time rather than cached: it is replaced across travel, and a stale one
-- would send the RPC into a dead world.
local function resolveLocalController()
    local ok, controller = pcall(FindFirstOf, "RODInGamePlayerController")
    if not ok or not isValid(controller) then return nil end
    return controller
end

local function resolveSpawnApi()
    if not isValid(navigationSystem) then
        navigationSystem = nil
        local navOk, nav = pcall(
            StaticFindObject,
            "/Script/NavigationSystem.Default__NavigationSystemV1"
        )
        if not navOk then
            return false, "NavigationSystemV1 lookup failed: " .. tostring(nav)
        end
        if not isValid(nav) then
            return false, "canonical NavigationSystemV1 object is unavailable"
        end
        navigationSystem = nav
    end

    -- Spawning goes through the engine's deferred pair,
    -- BeginDeferredActorSpawnFromClass + FinishSpawningActor. That is what this
    -- mod used before the spawn path was rewritten, and it is the only one of
    -- the three that works here:
    --
    --   * ARODGameState:RODSpawnActor cannot be called from Lua on this build.
    --     Every argument was verified correct and in order and the rejection
    --     never moved off "[push_objectproperty] ... :InInstigator". The
    --     FRODSpawnActorOption table is the only thing left between the two
    --     calls, and no readable property in the game holds a real one to borrow.
    --   * ARODInGamePlayerController:ServerDebugEnemySpawn returns without error
    --     and creates nothing, despite having a real native symbol.
    --
    -- The deferred pair also returns the actor it created, so ownership is exact
    -- and nothing has to be matched by guesswork afterwards.
    if not isValid(gameplayStatics) then
        gameplayStatics = nil
        local ok, library = pcall(
            StaticFindObject,
            "/Script/Engine.Default__GameplayStatics"
        )
        if not ok or not isValid(library) then
            return false, "canonical GameplayStatics spawn API is unavailable"
        end
        gameplayStatics = library
        if not spawnContractVerified then
            spawnContractVerified = true
            log("SPAWN CONTRACT | GameplayStatics deferred spawn is available")
            armSpawnOrderProbe()
        end
    end
    return true, nil
end

local function gameplayAttributeName(attribute)
    local ok, name = pcall(function()
        return attribute.AttributeName:ToString()
    end)
    if not ok or type(name) ~= "string" or name == "" then
        return nil, "FGameplayAttribute.AttributeName is unreadable"
    end
    return name, nil
end

local function gameplayAttributeFromArrayElement(parameter, index)
    local ok, attribute = pcall(function()
        return parameter:get()
    end)
    if not ok or attribute == nil then
        return nil, "attribute " .. tostring(index) ..
            ": TArray element could not be read through RemoteUnrealParam.get"
    end
    return attribute, nil
end

local function readGasValue(gas, key)
    local attribute = gas.attributes[key]
    if attribute == nil then return nil, "missing GAS attribute " .. tostring(key) end
    local found = {}
    local ok, value = pcall(function()
        return gas.abilitySystem:GetGameplayAttributeValue(attribute, found)
    end)
    if not ok then return nil, tostring(value) end
    if found.bFound ~= true then
        return nil, "AbilitySystem rejected GAS attribute " .. GAS_ATTRIBUTE_NAMES[key]
    end
    if not finiteNumber(value) then
        return nil, GAS_ATTRIBUTE_NAMES[key] .. " returned a non-numeric GAS value"
    end
    return value, nil
end

local function snapshotGas(enemy, className)
    local okSystem, abilitySystem = pcall(function() return enemy.AbilitySystem end)
    if not okSystem or not isValid(abilitySystem) then
        return nil, "required enemy AbilitySystem is unavailable"
    end

    local attributes = nil
    if className ~= nil and gasAttributesByClass[className] ~= nil then
        attributes = gasAttributesByClass[className]
    else
        local reflected = {}
        local okAttributes, attributesError =
            pcall(function() abilitySystem:GetAllAttributes(reflected) end)
        if not okAttributes then
            return nil, "GetAllAttributes failed: " .. tostring(attributesError)
        end

        local wanted = {}
        for key, name in pairs(GAS_ATTRIBUTE_NAMES) do wanted[name] = key end
        attributes = {}
        for index = 1, #reflected do
            local attribute, elementError =
                gameplayAttributeFromArrayElement(reflected[index], index)
            if attribute == nil then return nil, elementError end
            local name, nameError = gameplayAttributeName(attribute)
            if name == nil then
                return nil, "attribute " .. tostring(index) .. ": " .. nameError
            end
            local key = wanted[name]
            if key ~= nil then
                if attributes[key] ~= nil then
                    return nil, "duplicate GAS attribute " .. name
                end
                attributes[key] = attribute
            end
        end

        for key, name in pairs(GAS_ATTRIBUTE_NAMES) do
            if attributes[key] == nil then
                return nil, "required GAS attribute is absent: " .. name
            end
        end

        if className ~= nil then
            gasAttributesByClass[className] = attributes
        end
    end

    local gas = {
        abilitySystem = abilitySystem,
        attributes = attributes,
        baseline = {},
        applied = { maxHealth = 0.0, baseAttack = 0.0, baseDefence = 0.0 },
    }
    for key, _ in pairs(GAS_ATTRIBUTE_NAMES) do
        local value, valueError = readGasValue(gas, key)
        if value == nil then return nil, valueError end
        gas.baseline[key] = value
    end
    if gas.baseline.maxHealth <= 0.0 then
        return nil, "baseline MaxHealth must be greater than zero"
    end
    return gas, nil
end

local function snapshotEnemy(enemy)
    local classObj, className = classData(enemy)
    local ok, mesh, meshScale, maxHealth, attack, defence, experience,
        movingSpeed, goldenGateBoss, enemyRole,
        bossEventSequence, bossFinisherSequence =
        pcall(function()
            local enemyMesh = enemy.Mesh
            return enemyMesh,
                enemyMesh.RelativeScale3D,
                enemy.MaxHelth,
                enemy.AttackPower,
                enemy.DefencePower,
                enemy.ExperiencePoint,
                enemy.MovingSpeed,
                enemy.GoldenGateBoss,
                enemy.EnemyRole,
                enemy.BossEventSequence,
                enemy.BossFinisherLevelSequence
        end)
    if not ok then return nil, "required enemy fields are unreadable" end
    if not isValid(mesh) then return nil, "required skeletal mesh is unavailable" end
    local parsedMeshScale = vector(meshScale)
    if parsedMeshScale == nil then
        return nil, "skeletal mesh RelativeScale3D is invalid"
    end
    for key, value in pairs({
        MaxHelth = maxHealth,
        AttackPower = attack,
        DefencePower = defence,
        ExperiencePoint = experience,
        MovingSpeed = movingSpeed,
    }) do
        if not finiteNumber(value) then return nil, key .. " is not numeric" end
    end
    if type(goldenGateBoss) ~= "boolean" then
        return nil, "GoldenGateBoss is not boolean"
    end
    if not finiteNumber(enemyRole)
        or enemyRole % 1 ~= 0
        or enemyRole < ENEMY_ROLE_NONE
        or enemyRole > ENEMY_ROLE_BOSS then
        return nil, "EnemyRole is outside the reflected EEnemyRole contract"
    end
    local gas, gasError = snapshotGas(enemy, className)
    if gas == nil then return nil, gasError end

    -- Protection is for the mission's own boss, not for anything the data
    -- happens to label EnemyRole_Boss.
    --
    -- That role is worn by field elites too — BP_E001004, a big boar, carries it
    -- — and treating it as "boss" pulled ordinary elites out of the spawn
    -- catalog entirely and left them unmutated. What separates a real boss is
    -- its staging: BossEventSequence and BossFinisherLevelSequence are the
    -- cinematics a mission boss owns and an elite does not, and GoldenGateBoss
    -- marks the floor boss outright. The role is kept in the snapshot for
    -- diagnostics, but it no longer decides anything on its own.
    local hasBossStaging = isValid(bossEventSequence)
        or isValid(bossFinisherSequence)
    local isBoss = goldenGateBoss or hasBossStaging
    return {
        mesh = mesh,
        meshScale = parsedMeshScale,
        MaxHelth = maxHealth,
        AttackPower = attack,
        DefencePower = defence,
        ExperiencePoint = experience,
        MovingSpeed = movingSpeed,
        enemyRole = enemyRole,
        goldenGateBoss = goldenGateBoss,
        hasBossStaging = hasBossStaging,
        isBoss = isBoss,
        gas = gas,
    }, nil
end

local function roundedProduct(value, multiplier)
    return math.max(0, math.floor(value * multiplier + 0.5))
end

local function colorFor(state)
    local name = CONFIG.COLOR_PRESET
    if CONFIG.COLOR_MODE == "random" then
        if state.colorRoll == nil then state.colorRoll = math.random(1, #PALETTE_NAMES) end
        name = PALETTE_NAMES[state.colorRoll]
    end
    return PALETTE[name]
end

local function copyColor(value)
    if value == nil then return nil end
    return { R = value.R, G = value.G, B = value.B, A = value.A }
end

local function gasValues(gas)
    local values = {}
    for key, _ in pairs(GAS_ATTRIBUTE_NAMES) do
        local value, valueError = readGasValue(gas, key)
        if value == nil then error(valueError) end
        values[key] = value
    end
    return values
end

local function applyGasDelta(state, key, delta)
    if math.abs(delta) <= GAS_VALUE_EPSILON then return end
    local gas = state.baseline.gas
    local before, beforeError = readGasValue(gas, key)
    if before == nil then error(beforeError) end
    state.object:ApplyInstantGameplayEffect(
        delta,
        gas.attributes[key],
        GAMEPLAY_MOD_ADDITIVE
    )
    local after, afterError = readGasValue(gas, key)
    if after == nil then error(afterError) end
    local expected = before + delta
    local tolerance = math.max(GAS_VALUE_EPSILON, math.abs(expected) * 0.0001)
    if math.abs(after - expected) > tolerance then
        error(string.format(
            "%s GAS write was rejected (expected %.3f, received %.3f)",
            GAS_ATTRIBUTE_NAMES[key],
            expected,
            after
        ))
    end
end

local function setGasValue(state, key, target)
    if key == "health" then target = math.max(0.0, target) end
    local gas = state.baseline.gas
    local current, currentError = readGasValue(gas, key)
    if current == nil then error(currentError) end
    applyGasDelta(state, key, target - current)
end

local function retargetDerivedGasStat(state, finalKey, baseKey, multiplier, appliedKey)
    local gas = state.baseline.gas
    local current, currentError = readGasValue(gas, finalKey)
    if current == nil then error(currentError) end
    local desired = gas.baseline[finalKey] * multiplier
    local firstDelta = desired - current
    if math.abs(firstDelta) <= GAS_VALUE_EPSILON then return end
    applyGasDelta(state, baseKey, firstDelta)
    local actual, actualError = readGasValue(gas, finalKey)
    if actual == nil then error(actualError) end
    local tolerance = math.max(GAS_VALUE_EPSILON, math.abs(desired) * 0.0001)

    local totalBaseDelta = firstDelta
    if math.abs(actual - desired) > tolerance then
        local response = actual - current
        if math.abs(response) <= GAS_VALUE_EPSILON then
            error(string.format(
                "%s did not respond to %s",
                GAS_ATTRIBUTE_NAMES[finalKey],
                GAS_ATTRIBUTE_NAMES[baseKey]
            ))
        end
        local slope = response / firstDelta
        if not finiteNumber(slope) or math.abs(slope) <= GAS_VALUE_EPSILON then
            error(GAS_ATTRIBUTE_NAMES[finalKey] ..
                " returned an invalid base-attribute coefficient")
        end
        local correction = (desired - actual) / slope
        applyGasDelta(state, baseKey, correction)
        totalBaseDelta = totalBaseDelta + correction
        actual, actualError = readGasValue(gas, finalKey)
        if actual == nil then error(actualError) end
    end

    if math.abs(actual - desired) > tolerance then
        error(string.format(
            "%s did not follow %s (expected %.3f, received %.3f)",
            GAS_ATTRIBUTE_NAMES[finalKey],
            GAS_ATTRIBUTE_NAMES[baseKey],
            desired,
            actual
        ))
    end
    gas.applied[appliedKey] = gas.applied[appliedKey] + totalBaseDelta
end

local function retargetGas(state, healthMultiplier, attackMultiplier, defenceMultiplier)
    local gas = state.baseline.gas
    local currentHealth, healthError = readGasValue(gas, "health")
    if currentHealth == nil then error(healthError) end
    local currentMaxHealth, maxHealthError = readGasValue(gas, "maxHealth")
    if currentMaxHealth == nil then error(maxHealthError) end
    if currentMaxHealth <= 0.0 then error("current GAS MaxHealth must be greater than zero") end

    local healthRatio = math.max(0.0, math.min(1.0, currentHealth / currentMaxHealth))
    local desiredMaxHealthDelta = gas.baseline.maxHealth * (healthMultiplier - 1.0)
    applyGasDelta(
        state,
        "maxHealth",
        desiredMaxHealthDelta - gas.applied.maxHealth
    )
    gas.applied.maxHealth = desiredMaxHealthDelta

    local adjustedMaxHealth, adjustedMaxError = readGasValue(gas, "maxHealth")
    if adjustedMaxHealth == nil then error(adjustedMaxError) end
    setGasValue(state, "health", adjustedMaxHealth * healthRatio)

    retargetDerivedGasStat(
        state,
        "attack",
        "baseAttack",
        attackMultiplier,
        "baseAttack"
    )
    retargetDerivedGasStat(
        state,
        "defence",
        "baseDefence",
        defenceMultiplier,
        "baseDefence"
    )
end

local function captureMutationState(state)
    local object = state.object
    local mesh = object.Mesh
    if not isValid(mesh) then error("live skeletal mesh is unavailable") end
    local snapshot = {
        mesh = mesh,
        gasValues = gasValues(state.baseline.gas),
        gasApplied = {
            maxHealth = state.baseline.gas.applied.maxHealth,
            baseAttack = state.baseline.gas.applied.baseAttack,
            baseDefence = state.baseline.gas.applied.baseDefence,
        },
        applied = state.applied,
        colorParameter = state.colorParameter,
        appliedColor = copyColor(state.appliedColor),
    }
    snapshot.meshScale = vector(mesh.RelativeScale3D)
    if snapshot.meshScale == nil then
        error("live skeletal mesh RelativeScale3D is invalid")
    end
    snapshot.MaxHelth = object.MaxHelth
    snapshot.AttackPower = object.AttackPower
    snapshot.DefencePower = object.DefencePower
    snapshot.ExperiencePoint = object.ExperiencePoint
    snapshot.MovingSpeed = object.MovingSpeed
    for key, value in pairs({
        MaxHelth = snapshot.MaxHelth,
        AttackPower = snapshot.AttackPower,
        DefencePower = snapshot.DefencePower,
        ExperiencePoint = snapshot.ExperiencePoint,
        MovingSpeed = snapshot.MovingSpeed,
    }) do
        if not finiteNumber(value) then error("live " .. key .. " is not numeric") end
    end
    return snapshot
end

local function rollbackMutation(state, previous)
    local object = state.object
    local ok, rollbackError = pcall(function()
        setGasValue(state, "maxHealth", previous.gasValues.maxHealth)
        setGasValue(state, "health", previous.gasValues.health)
        setGasValue(state, "baseAttack", previous.gasValues.baseAttack)
        setGasValue(state, "baseDefence", previous.gasValues.baseDefence)
        if not isValid(previous.mesh) then
            error("rollback skeletal mesh is unavailable")
        end
        previous.mesh:SetRelativeScale3D(previous.meshScale)
        object.MaxHelth = previous.MaxHelth
        object.AttackPower = previous.AttackPower
        object.DefencePower = previous.DefencePower
        object.ExperiencePoint = previous.ExperiencePoint
        object.MovingSpeed = previous.MovingSpeed
        object:SetMovingSpeed(previous.MovingSpeed)
        if state.colorParameter ~= nil then
            object:ResetMaterialColorParameter(FName(state.colorParameter))
        end
        if previous.colorParameter ~= nil then
            object:SetMaterialColorParameter(
                FName(previous.colorParameter),
                previous.appliedColor
            )
        end
    end)
    if not ok then
        log("ROLLBACK ERROR | " .. state.key .. " | " .. tostring(rollbackError))
        return false
    end
    local gas = state.baseline.gas
    gas.applied.maxHealth = previous.gasApplied.maxHealth
    gas.applied.baseAttack = previous.gasApplied.baseAttack
    gas.applied.baseDefence = previous.gasApplied.baseDefence
    state.applied = previous.applied
    state.colorParameter = previous.colorParameter
    state.appliedColor = copyColor(previous.appliedColor)
    return true
end

local function restoreState(state)
    if not state.applied then return true end
    if not isValid(state.object) then return false end
    local operational, lifecycleError = enemyOperational(state.object)
    if not operational then
        if lifecycleError ~= "enemy is dead" then
            log("RESTORE ERROR | " .. state.key .. " | " .. lifecycleError)
            return false
        end
        -- Pooled/dead enemies are authoritatively rebuilt by EnemyReused.
        -- Their inactive GAS state has MaxHealth=0 and must not be written.
        state.applied = false
        state.colorParameter = nil
        state.appliedColor = nil
        return true
    end
    local previous
    local okSnapshot, snapshotError = pcall(function()
        previous = captureMutationState(state)
    end)
    if not okSnapshot then
        log("RESTORE ERROR | " .. state.key .. " | " .. tostring(snapshotError))
        return false
    end
    local base = state.baseline
    local ok, restoreError = pcall(function()
        retargetGas(state, 1.0, 1.0, 1.0)
        if not isValid(base.mesh) then
            error("baseline skeletal mesh is unavailable")
        end
        base.mesh:SetRelativeScale3D(base.meshScale)
        state.object.MaxHelth = base.MaxHelth
        state.object.AttackPower = base.AttackPower
        state.object.DefencePower = base.DefencePower
        state.object.ExperiencePoint = base.ExperiencePoint
        state.object.MovingSpeed = base.MovingSpeed
        state.object:SetMovingSpeed(base.MovingSpeed)
        if state.colorParameter ~= nil then
            state.object:ResetMaterialColorParameter(FName(state.colorParameter))
        end
    end)
    if not ok then
        rollbackMutation(state, previous)
        log("RESTORE ERROR | " .. tostring(state.key) .. " | " .. tostring(restoreError))
        return false
    end
    state.applied = false
    state.colorParameter = nil
    state.appliedColor = nil
    return true
end

local function mutationIsIdentity()
    return CONFIG.SCALE_MIN == 1.0
        and CONFIG.SCALE_MAX == 1.0
        and CONFIG.COLOR_MODE == "off"
        and CONFIG.HEALTH_MULTIPLIER == 1.0
        and CONFIG.ATTACK_MULTIPLIER == 1.0
        and CONFIG.DEFENCE_MULTIPLIER == 1.0
        and CONFIG.MOVE_SPEED_MULTIPLIER == 1.0
        and CONFIG.XP_MULTIPLIER == 1.0
end

local function applyMutation(state)
    if not isValid(state.object) then return false end
    local operational, lifecycleError = enemyOperational(state.object)
    if not operational then
        if lifecycleError ~= "enemy is dead"
            and lifecycleError ~= "enemy is not initialized" then
            log("MUTATION ERROR | " .. state.key .. " | " .. lifecycleError)
        end
        return false
    end
    if mutationIsIdentity() then return restoreState(state) end
    if state.baseline.isBoss and not CONFIG.INCLUDE_BOSSES then
        restoreState(state)
        return true
    end

    if CONFIG.COLOR_MODE ~= "off" then
        local apiReady, apiError = resolveMaterialApi()
        if not apiReady then
            log("MUTATION ERROR | " .. state.key .. " | " .. apiError)
            return false
        end
        local okInterface, implemented = pcall(function()
            return materialLibrary:DoesImplementInterface(state.object, materialInterface)
        end)
        if not okInterface or implemented ~= true then
            log("MUTATION ERROR | " .. state.key
                .. " | enemy does not implement the material parameter interface")
            return false
        end
    end

    local previous
    local okSnapshot, snapshotError = pcall(function()
        previous = captureMutationState(state)
    end)
    if not okSnapshot then
        log("MUTATION ERROR | " .. state.key .. " | " .. tostring(snapshotError))
        return false
    end

    if state.scaleRoll == nil then state.scaleRoll = math.random() end
    local scaleFactor = CONFIG.SCALE_MIN
        + (CONFIG.SCALE_MAX - CONFIG.SCALE_MIN) * state.scaleRoll
    local base = state.baseline
    local newScale = {
        X = base.meshScale.X * scaleFactor,
        Y = base.meshScale.Y * scaleFactor,
        Z = base.meshScale.Z * scaleFactor,
    }
    local movingSpeed = base.MovingSpeed * CONFIG.MOVE_SPEED_MULTIPLIER
    local actualGas

    local ok, mutationError = pcall(function()
        retargetGas(
            state,
            CONFIG.HEALTH_MULTIPLIER,
            CONFIG.ATTACK_MULTIPLIER,
            CONFIG.DEFENCE_MULTIPLIER
        )
        if not isValid(base.mesh) then
            error("baseline skeletal mesh is unavailable")
        end
        base.mesh:SetRelativeScale3D(newScale)
        state.object.MaxHelth = roundedProduct(base.MaxHelth, CONFIG.HEALTH_MULTIPLIER)
        state.object.AttackPower = roundedProduct(base.AttackPower, CONFIG.ATTACK_MULTIPLIER)
        state.object.DefencePower = roundedProduct(base.DefencePower, CONFIG.DEFENCE_MULTIPLIER)
        state.object.ExperiencePoint =
            roundedProduct(base.ExperiencePoint, CONFIG.XP_MULTIPLIER)
        state.object.MovingSpeed = movingSpeed
        state.object:SetMovingSpeed(movingSpeed)
        if state.colorParameter ~= nil then
            state.object:ResetMaterialColorParameter(FName(state.colorParameter))
            state.colorParameter = nil
            state.appliedColor = nil
        end
        if CONFIG.COLOR_MODE ~= "off" then
            local selectedColor = copyColor(colorFor(state))
            state.colorParameter = CONFIG.COLOR_PARAMETER_NAME
            state.appliedColor = selectedColor
            state.object:SetMaterialColorParameter(
                FName(state.colorParameter),
                selectedColor
            )
        end
        actualGas = gasValues(base.gas)
    end)
    if not ok then
        rollbackMutation(state, previous)
        log("MUTATION ERROR | " .. state.key .. " | " .. tostring(mutationError))
        return false
    end

    state.applied = true
    dbg(string.format(
        "MUTATED | %s | scale=%.2fx gas_hp=%.1f/%.1f gas_atk=%.1f gas_def=%.1f speed=%.2fx xp=%.2fx",
        state.key,
        scaleFactor,
        actualGas.health,
        actualGas.maxHealth,
        actualGas.attack,
        actualGas.defence,
        CONFIG.MOVE_SPEED_MULTIPLIER,
        CONFIG.XP_MULTIPLIER
    ))
    return true
end

local function destroyOwned(state, reason)
    if isValid(state.object) then
        local ok, destroyError = pcall(function() state.object:K2_DestroyActor() end)
        if not ok then
            log("DESTROY ERROR | " .. state.key .. " | " .. tostring(destroyError))
            return false
        end
    end
    states[state.key] = nil
    dbg("EXTRA REMOVED | " .. state.key .. " | " .. reason)
    return true
end

-- A pending request is a ticket, not an actor: ServerDebugEnemySpawn has not
-- reported anything back yet, so there is usually nothing to destroy. Only a
-- request reconstructed from an already-owned enemy carries an object.
local function destroyPending(request, reason)
    local label = request.actorKey or (request.classKey or "unclaimed ticket")
    if isValid(request.object) then
        local ok, destroyError = pcall(function() request.object:K2_DestroyActor() end)
        if not ok then
            log("DESTROY ERROR | pending " .. label ..
                " | " .. tostring(destroyError))
            return false
        end
    end
    dbg("PENDING EXTRA REMOVED | " .. label .. " | " .. reason)
    return true
end

local function removeOrigin(originKey, destroyActors)
    origins[originKey] = nil
    for index = #spawnQueue, 1, -1 do
        if spawnQueue[index].originKey == originKey then table.remove(spawnQueue, index) end
    end
    for index = #pendingSpawns, 1, -1 do
        if pendingSpawns[index].originKey == originKey then
            local request = table.remove(pendingSpawns, index)
            destroyPending(request, "origin removed")
        end
    end
    if destroyActors then
        local owned = {}
        for _, state in pairs(states) do
            if state.owned and state.originKey == originKey then owned[#owned + 1] = state end
        end
        for _, state in ipairs(owned) do destroyOwned(state, "origin removed") end
    end
end

local function activeExtraCount()
    local count = #spawnQueue + #pendingSpawns
    for _, state in pairs(states) do
        if state.owned and isValid(state.object) then count = count + 1 end
    end
    return count
end

local function enforceGlobalCap()
    while activeExtraCount() > CONFIG.MAX_ACTIVE_EXTRAS and #spawnQueue > 0 do
        local removed = table.remove(spawnQueue)
        dbg(string.format(
            "SPAWN CAP | removed queued origin=%s slot=%d",
            removed.originKey,
            removed.slot
        ))
    end

    while activeExtraCount() > CONFIG.MAX_ACTIVE_EXTRAS
        and #pendingSpawns > 0 do
        local request = table.remove(pendingSpawns)
        destroyPending(request, "global cap reduced")
    end

    if activeExtraCount() <= CONFIG.MAX_ACTIVE_EXTRAS then return end
    local owned = {}
    for _, state in pairs(states) do
        if state.owned and isValid(state.object) then owned[#owned + 1] = state end
    end
    table.sort(owned, function(a, b)
        if a.slot == b.slot then return a.key > b.key end
        return a.slot > b.slot
    end)
    for _, state in ipairs(owned) do
        if activeExtraCount() <= CONFIG.MAX_ACTIVE_EXTRAS then break end
        destroyOwned(state, "global cap reduced")
    end
end

-- With RANDOMIZE_EXTRA_SPECIES on, one draw landing on an entry that has since
-- become ineligible is not the same thing as having no species to spawn. The
-- draw is retried across the catalog before giving up, because the caller treats
-- a nil result as "nothing can be spawned here" and permanently consumes the
-- slot — an unlucky single draw used to silently cost an extra and report the
-- catalog as empty.
local function classEntryIsSpawnable(entry)
    return entry ~= nil
        and entry.spawnEligible == true
        and protectedBossClasses[entry.classKey] ~= true
        and isValid(entry.classObject)
end

local function selectSpawnClass(origin)
    if protectedBossClasses[origin.classKey] == true then return nil, nil end
    if not CONFIG.RANDOMIZE_EXTRA_SPECIES then
        if origin.spawnEligible ~= true then return nil, nil end
        return origin.classObject, origin.classKey
    end

    local count = #classOrder
    if count == 0 then return nil, nil end
    -- Start at a random position and walk the catalog once, so the pick stays
    -- uniform-ish without ever scanning it more than a single time.
    local start = math.random(1, count)
    for step = 0, count - 1 do
        local entry = classCatalog[classOrder[((start + step - 1) % count) + 1]]
        if classEntryIsSpawnable(entry) then
            return entry.classObject, entry.classKey
        end
    end
    return nil, nil
end

local function planarDistanceSquared(a, b)
    local dx = a.X - b.X
    local dy = a.Y - b.Y
    return dx * dx + dy * dy
end

local function minimumSpawnSeparation()
    return math.min(
        NAV_MIN_SEPARATION_CM,
        math.max(50.0, CONFIG.SPAWN_RADIUS * 0.35)
    )
end

local function spawnPositionIsSeparated(position)
    local requiredSeparation = minimumSpawnSeparation()
    local requiredSquared = requiredSeparation * requiredSeparation

    for _, origin in pairs(origins) do
        if origin.location ~= nil
            and planarDistanceSquared(position, origin.location) < requiredSquared then
            return false
        end
    end
    for _, request in ipairs(pendingSpawns) do
        if request.position ~= nil
            and planarDistanceSquared(position, request.position) < requiredSquared then
            return false
        end
    end
    for _, state in pairs(states) do
        if state.owned and state.spawnPosition ~= nil
            and planarDistanceSquared(position, state.spawnPosition) < requiredSquared then
            return false
        end
    end
    return true
end

--========================================================--
--                  SPAWN POSITIONING                     --
--========================================================--
-- Positioning allocates no UObject. That is the whole point of this section.
--
-- It used to validate candidates with FindPathToLocationSynchronously, which
-- returns a UNavigationPath — a NewObject outered to the NavigationSystemV1, one
-- per call, up to NAV_MAX_ATTEMPTS per requested extra and thousands per
-- mission. On this World Partition map there is almost always a package in async
-- loading, and every UObject created on the game thread while that is true is
-- born with EInternalObjectFlags::Async, which is part of GarbageCollectionKeepFlags:
-- it is never collected, not even after being marked PendingKill. Those paths are
-- outered to the world, so the old world could not be collected either, and the
-- engine's world-leak check is fatal in a cooked build:
--
--   LowLevelFatalError ReferenceChainSearch.cpp:1948
--   Fatal world leaks detected ... (PendingKill) (async) NavigationPath
--     -> Outer = NavigationSystemV1 -> Outer = World
--
-- It fired on mission end and fast travel, with the log showing
-- "owned references released=0" — the leak was never the spawned actors.
--
-- K2_GetRandomReachablePointInRadius returns a bool and writes the point into an
-- out parameter. It gives the same guarantee the old pathIsComplete checked for
-- (a point on the navmesh, reachable from the origin, not a partial path) in one
-- call, and allocates nothing.
--
-- NOTE ON THE SIGNATURE: it takes a WorldContextObject FIRST. The header is
--   bool K2_GetRandomReachablePointInRadius(UObject* WorldContextObject,
--       const FVector& Origin, FVector& RandomLocation, float Radius,
--       ANavigationData* NavData, TSubclassOf<UNavigationQueryFilter> FilterClass)
-- Six parameters, not five. Calling a native function with the wrong arity is a
-- hard crash that pcall cannot catch.

-- How UE4SS hands back the RandomLocation out parameter is decided once, on the
-- first call, and logged. Guessing between "extra return value" and "the table
-- you passed in was mutated" is exactly the kind of assumption the house rules
-- say to verify against a visible result rather than build logic on.
local navOutParamMode = nil

local function sampleReachablePoint(worldContext, origin, radius)
    local scratch = { X = 0.0, Y = 0.0, Z = 0.0 }

    if navOutParamMode == nil then
        log("NAV PROBE | calling K2_GetRandomReachablePointInRadius for the "
            .. "first time to learn its out-parameter shape")
    end

    local callOk, reachable, returnedLocation = pcall(function()
        return navigationSystem:K2_GetRandomReachablePointInRadius(
            worldContext,
            origin,
            scratch,
            radius,
            nil,
            nil
        )
    end)
    if not callOk then
        return nil, "K2_GetRandomReachablePointInRadius failed: "
            .. tostring(reachable)
    end

    local function usable(candidate)
        return type(candidate) == "table"
            and type(candidate.X) == "number"
            and type(candidate.Y) == "number"
            and type(candidate.Z) == "number"
            and (candidate.X ~= 0.0 or candidate.Y ~= 0.0 or candidate.Z ~= 0.0)
    end

    local located = nil
    if usable(returnedLocation) then
        located = returnedLocation
        if navOutParamMode == nil then
            navOutParamMode = "return"
            log("NAV PROBE | out parameter arrives as an extra return value")
        end
    elseif usable(scratch) then
        located = scratch
        if navOutParamMode == nil then
            navOutParamMode = "mutated"
            log("NAV PROBE | out parameter arrives by mutating the passed table")
        end
    elseif navOutParamMode == nil then
        navOutParamMode = "unknown"
        log("NAV PROBE | no usable point came back; reachable="
            .. tostring(reachable)
            .. " returned=" .. type(returnedLocation))
    end

    if reachable ~= true then return nil, "no reachable point in radius" end
    if located == nil then return nil, "reachable point was not readable" end
    -- Lifted off the navmesh surface: a character capsule created exactly on the
    -- ground fails its collision check and no actor appears.
    return {
        X = located.X,
        Y = located.Y,
        Z = located.Z + SPAWN_Z_OFFSET_CM,
    }, nil
end

local function resolveNavigableSpawnPosition(request, worldContext)
    local buildOk, building = pcall(function()
        return navigationSystem:IsNavigationBeingBuiltOrLocked(worldContext)
    end)
    if not buildOk then
        return nil, "IsNavigationBeingBuiltOrLocked failed: " ..
            tostring(building), false
    end
    if building == true then
        return nil, "NavMesh is still being built or locked", true
    end

    -- Same per-pass budget as before, so a request that cannot be placed yet
    -- costs the tick no more than it used to and is retried rather than dropped.
    local firstAttempt = request.navAttempts + 1
    local finalAttempt = math.min(
        request.navAttempts + NAV_ATTEMPTS_PER_PASS,
        NAV_MAX_ATTEMPTS
    )
    local lastFailure = "navigation rejected every sample"
    for attempt = firstAttempt, finalAttempt do
        request.navAttempts = attempt
        local position, sampleError = sampleReachablePoint(
            worldContext,
            request.originLocation,
            CONFIG.SPAWN_RADIUS
        )
        if position == nil then
            lastFailure = sampleError
        else
            -- The engine already bounds the sample by Radius; this is a cheap
            -- guard, and spawnPositionIsSeparated is what still enforces the
            -- minimum distance from origins, tickets and owned extras.
            local maxRadius = CONFIG.SPAWN_RADIUS + 25.0
            if planarDistanceSquared(position, request.originLocation)
                <= maxRadius * maxRadius
                and spawnPositionIsSeparated(position) then
                return position, nil, false
            end
            lastFailure = string.format(
                "sample violated radius or %.0f cm separation",
                minimumSpawnSeparation()
            )
        end
    end
    if request.navAttempts < NAV_MAX_ATTEMPTS then
        return nil, lastFailure .. string.format(
            " after %d/%d attempts",
            request.navAttempts,
            NAV_MAX_ATTEMPTS
        ), true
    end
    return nil, lastFailure .. " after " .. NAV_MAX_ATTEMPTS ..
        " attempts", false
end

local function queueExtra(origin, slot)
    if spawningProvenInert then return false end
    if origin.spawnEligible ~= true then
        worldFault = "boss-protection invariant rejected spawn origin " ..
            tostring(origin.key)
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return false
    end
    if protectedBossClasses[origin.classKey] == true then
        worldFault = "boss-protection invariant rejected class " ..
            tostring(origin.classKey)
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return false
    end
    if activeExtraCount() >= CONFIG.MAX_ACTIVE_EXTRAS then
        dbg("SPAWN CAP | slot " .. slot .. " for " .. origin.key .. " was not issued")
        return false
    end

    local classObject, classKey = selectSpawnClass(origin)
    if not isValid(classObject) then
        origin.issued = slot
        if CONFIG.RANDOMIZE_EXTRA_SPECIES then
            log("SPAWN ERROR | no spawnable species in a catalog of "
                .. tostring(#classOrder)
                .. " | every entry is boss-protected, ineligible or unloaded")
        else
            log("SPAWN ERROR | origin species is not spawnable: "
                .. tostring(origin.classKey))
        end
        return true
    end
    spawnQueue[#spawnQueue + 1] = {
        generation = generation,
        originKey = origin.key,
        slot = slot,
        classObject = classObject,
        classKey = classKey,
        level = origin.level,
        originLocation = {
            X = origin.location.X,
            Y = origin.location.Y,
            Z = origin.location.Z,
        },
        navAttempts = 0,
        spawnEligible = true,
    }
    origin.issued = slot
    return true
end

local function reconcileOrigin(origin)
    local desired = CONFIG.SPAWN_MULTIPLIER - 1
    if origin.issued > desired then
        for index = #spawnQueue, 1, -1 do
            local request = spawnQueue[index]
            if request.originKey == origin.key and request.slot > desired then
                table.remove(spawnQueue, index)
            end
        end
        for index = #pendingSpawns, 1, -1 do
            local request = pendingSpawns[index]
            if request.originKey == origin.key and request.slot > desired then
                table.remove(pendingSpawns, index)
                destroyPending(request, "multiplier reduced")
            end
        end
        local removals = {}
        for _, state in pairs(states) do
            if state.owned and state.originKey == origin.key and state.slot > desired then
                removals[#removals + 1] = state
            end
        end
        for _, state in ipairs(removals) do destroyOwned(state, "multiplier reduced") end
        origin.issued = desired
    end
    for slot = origin.issued + 1, desired do
        if not queueExtra(origin, slot) then break end
    end
end

local function addClass(classObject, classKey)
    if protectedBossClasses[classKey] == true then return end
    if classCatalog[classKey] ~= nil then return end
    classCatalog[classKey] = {
        classObject = classObject,
        classKey = classKey,
        spawnEligible = true,
    }
    classOrder[#classOrder + 1] = classKey
    dbg("CLASS DISCOVERED | " .. classKey)
end

local function protectBossClass(classKey)
    if protectedBossClasses[classKey] == true then return end
    protectedBossClasses[classKey] = true
    classCatalog[classKey] = nil
    for index = #classOrder, 1, -1 do
        if classOrder[index] == classKey then table.remove(classOrder, index) end
    end

    local protectedOriginKeys = {}
    for originKey, origin in pairs(origins) do
        if origin.classKey == classKey then
            protectedOriginKeys[originKey] = true
            origins[originKey] = nil
        end
    end

    for index = #spawnQueue, 1, -1 do
        local request = spawnQueue[index]
        if request.classKey == classKey
            or protectedOriginKeys[request.originKey] == true then
            table.remove(spawnQueue, index)
        end
    end

    local unsafeActors = 0
    for _, request in ipairs(pendingSpawns) do
        if request.classKey == classKey
            or protectedOriginKeys[request.originKey] == true then
            unsafeActors = unsafeActors + 1
        end
    end
    for _, state in pairs(states) do
        if state.owned
            and (state.classKey == classKey
                or protectedOriginKeys[state.originKey] == true) then
            unsafeActors = unsafeActors + 1
        end
    end

    if unsafeActors > 0 then
        spawnQueue = {}
        worldFault = string.format(
            "boss class %s was identified after %d owned actor(s) had been issued; mission restart required",
            classKey,
            unsafeActors
        )
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return
    end

    log("MISSION BOSS PROTECTED | removed from spawn system: " .. classKey)
end

-- BeginDeferredActorSpawnFromClass hands back the actor it created, so a
-- request owns an exact object and is claimed by identity. No proximity
-- guessing, which is what made the very first version of this mod attribute
-- pre-existing enemies to itself.
local function takePendingSpawn(actorKey)
    for index, request in ipairs(pendingSpawns) do
        if request.generation == generation and request.actorKey == actorKey then
            table.remove(pendingSpawns, index)
            unmatchedSpawnStreak = 0
            return request
        end
    end
    return nil
end

local function registerEnemy(enemy, reused, queued)
    if not isValid(enemy) then return end
    local key = objectKey(enemy)
    if key == nil or key:find("Default__", 1, true) ~= nil then return end
    local operational, lifecycleError = enemyOperational(enemy)
    if not operational then
        if lifecycleError ~= "enemy is dead"
            and lifecycleError ~= "enemy is not initialized" then
            log("ENEMY ERROR | " .. key .. " | " .. lifecycleError)
        end
        return
    end

    local request = takePendingSpawn(key)
    local previous = states[key]
    if previous ~= nil and not reused then return end
    if previous ~= nil then
        if previous.owned then
            if request == nil then
                request = {
                    generation = generation,
                    originKey = previous.originKey,
                    slot = previous.slot,
                    classKey = previous.classKey,
                    actorKey = previous.key,
                    object = previous.object,
                }
            end
            states[key] = nil
        else
            removeOrigin(key, true)
            states[key] = nil
        end
    end

    local classObject, classKey, classError = classData(enemy)
    if classObject == nil then
        log("ENEMY ERROR | " .. key .. " | " .. classError)
        return
    end
    local location, locationError = actorLocation(enemy)
    if location == nil then
        log("ENEMY ERROR | " .. key .. " | " .. locationError)
        return
    end
    if request ~= nil and request.classKey ~= classKey then
        destroyPending(request, "spawned class did not match the requested class")
        log("SPAWN ERROR | created class " .. classKey ..
            " does not match requested class " .. request.classKey)
        return
    end
    local baseline, snapshotError = snapshotEnemy(enemy)
    if baseline == nil then
        if request == nil and queued ~= nil and (snapshotError == "required skeletal mesh is unavailable" or snapshotError == "required enemy fields are unreadable") then
            local retryCount = (queued.retryCount or 0) + 1
            if retryCount <= 5 then
                queued.retryCount = retryCount
                objectQueue[#objectQueue + 1] = queued
                return
            end
        end
        log("ENEMY ERROR | " .. key .. " | " .. snapshotError)
        if request ~= nil then
            destroyPending(request, "required enemy state was unavailable")
        end
        return
    end
    if baseline.isBoss then
        protectBossClass(classKey)
        if request ~= nil then
            spawnQueue = {}
            worldFault = "owned spawn initialized as protected boss " ..
                key .. "; mission restart required"
            log("WORLD ERROR | " .. worldFault .. " | director paused")
            return
        end
    end

    if request ~= nil and activeExtraCount() >= CONFIG.MAX_ACTIVE_EXTRAS then
        destroyPending(request, "completed above the current cap")
        return
    end
    local state = {
        key = key,
        object = enemy,
        classObject = classObject,
        classKey = classKey,
        baseline = baseline,
        owned = request ~= nil,
        originKey = request and request.originKey or nil,
        slot = request and request.slot or nil,
        spawnPosition = request and request.position or nil,
        applied = false,
    }
    states[key] = state

    -- An extra this mod created has to be told to start. A naturally placed
    -- enemy arrived through the game's own spawn path and is already running.
    if state.owned then
        activateSpawnedEnemy(enemy, key, state.spawnPosition)
    end

    -- INCLUDE_BOSSES controls mutation only. Boss classes and boss actors are
    -- never admitted to either spawning structure, so a quest boss cannot be
    -- duplicated by same-species multiplication or by randomisation.
    if not state.owned
        and not baseline.isBoss
        and protectedBossClasses[classKey] ~= true then
        addClass(classObject, classKey)
        local okLevel, level = pcall(function() return enemy:GetEnemyLevel() end)
        if not okLevel or not finiteNumber(level) then
            log("ENEMY ERROR | " .. key .. " | GetEnemyLevel failed")
        else
            origins[key] = {
                key = key,
                classObject = classObject,
                classKey = classKey,
                level = math.max(1, math.floor(level)),
                location = location,
                issued = 0,
                spawnEligible = true,
            }
        end
    elseif not state.owned then
        dbg("BOSS PROTECTED | excluded from spawn catalog: " .. key)
    end

    if configHealthy and CONFIG.ENABLED then applyMutation(state) end
    local origin = origins[key]
    if origin ~= nil and configHealthy and CONFIG.ENABLED and not discoveryBatch then
        reconcileOrigin(origin)
    end
end

local function cleanupInvalidStates()
    local invalidNatural = {}
    for key, state in pairs(states) do
        if not isValid(state.object) then
            states[key] = nil
            if not state.owned then invalidNatural[#invalidNatural + 1] = key end
        end
    end
    for _, key in ipairs(invalidNatural) do removeOrigin(key, true) end
end

local function expirePendingSpawns()
    for index = #pendingSpawns, 1, -1 do
        local request = pendingSpawns[index]
        if request.generation ~= generation or elapsedMs >= request.expiresAtMs then
            table.remove(pendingSpawns, index)
            if request.generation == generation then
                unmatchedSpawnStreak = unmatchedSpawnStreak + 1
                if not spawningProvenInert then
                    dbg(string.format(
                        "SPAWN UNMATCHED | origin=%s slot=%d class=%s | streak=%d",
                        request.originKey,
                        request.slot,
                        request.classKey,
                        unmatchedSpawnStreak
                    ))
                end
                destroyPending(request, "initialization timeout")
                if not spawningProvenInert
                    and unmatchedSpawnStreak >= UNMATCHED_SPAWN_GIVE_UP then
                    -- Actors were created and none of them ever came back
                    -- through discovery. Stop asking rather than repeating the
                    -- same failure every poll forever; mutation of the enemies
                    -- that already exist is unaffected and keeps running. One
                    -- successful claim clears the streak and re-enables this.
                    spawningProvenInert = true
                    spawnQueue = {}
                    log(string.format(
                        "SPAWN DISABLED | %d consecutive created actors never "
                            .. "finished initialization | multiplication is off, "
                            .. "mutation of existing enemies continues",
                        unmatchedSpawnStreak
                    ))
                end
            end
        end
    end
end

local function pauseForSpawnContractFailure(reason)
    disableWorld("spawn contract failure")
    worldFault = reason
    log("WORLD ERROR | " .. worldFault .. " | director paused")
end

-- A deferred spawn produces the pawn and nothing else.
--
-- Possession is not the gap: AutoPossessAI is 3 (PlacedInWorldOrSpawned) on
-- these Blueprints, so the engine attaches an AIC_* controller by itself and
-- SpawnDefaultController was measured to be a no-op — the controller is already
-- there before and after. The enemy still stands inert, because having a
-- controller is not the same as having started.
--
-- What the game's own path does and GameplayStatics does not is the rest of
-- FRODSpawnActorOption: IsStartBehaviorTree and the initial state. On
-- ARODEnemyCharacter those are StartAI(DetectFlag) and StartBehaviorTree(), and
-- they are called here, after the enemy reports itself initialized rather than
-- straight after creation — an enemy whose assets are still resolving has
-- nothing for a behaviour tree to run yet.
local activationReported = false

activateSpawnedEnemy = function(enemy, key, spawnPosition)
    if not isValid(enemy) then return end

    -- InitialStateLoc, which this path never supplies: ProwlFirstPosition is the
    -- anchor the idle/patrol logic works around, and on an actor created outside
    -- the game's own spawn call it stays at the origin, so the enemy's notion of
    -- where it belongs was (0,0,0) on the far side of the map.
    if spawnPosition ~= nil then
        pcall(function()
            enemy.ProwlFirstPosition = spawnPosition
            enemy.ProwlGoalPosition = spawnPosition
            enemy.ProwlGoalPositionFlag = false
        end)
    end

    local controller = nil
    pcall(function() controller = enemy.Controller end)

    -- Two StartAI functions exist and they are not the same thing.
    --
    -- ARODEnemyCharacter:StartAI(DetectFlag) is the one that was being called,
    -- and it is enough to get the enemy idling and patrolling. But the extras
    -- never noticed the player — invisible until hit — because perception lives
    -- on the controller side: ARODAIControllerBase:StartAI(ProcessedPawn) is
    -- what binds the possessed pawn into the perception system, and
    -- ApplyBindFunction wires its delegates. The engine auto-possesses the pawn
    -- but nothing calls those, since the game's own path reaches them through
    -- RODSpawnActor.
    --
    -- The controller is set up first, then the character, then the tree: binding
    -- perception after the tree is already running is what leaves an enemy
    -- walking its idle loop with nothing feeding it targets.
    local boundController, controllerError = true, nil
    if isValid(controller) then
        boundController, controllerError = pcall(function()
            controller:StartAI(enemy)
            controller:ApplyBindFunction()
        end)
    end

    -- StartAI's argument is inverted from what its name suggests.
    --
    -- It was being called as StartAI(true), reading "DetectFlag = yes, please
    -- detect". Clearing DisableDetectFlag beforehand and reading it back
    -- afterwards showed the write not surviving: the flag was false going in and
    -- true coming out, with nothing between the two but this call. So the
    -- parameter is the option struct's IsNodetect, not its opposite — passing
    -- true is what was making every extra blind.
    local startedAI, aiError = pcall(function() enemy:StartAI(false) end)
    local startedTree, treeResult = pcall(function()
        return enemy:StartBehaviorTree()
    end)

    -- Cleared last, after everything that is known to write it. Belt and braces:
    -- the readback in the log is what says whether it stuck this time.
    local clearedDetect = pcall(function()
        enemy.DisableDetectFlag = false
    end)

    if not activationReported then
        activationReported = true
        local detectStart, disableDetect, prowlAnchor = nil, nil, nil
        pcall(function() detectStart = enemy.DetectStartFlagN end)
        pcall(function() disableDetect = enemy.DisableDetectFlag end)
        pcall(function() prowlAnchor = vector(enemy.ProwlFirstPosition) end)
        log(string.format(
            "SPAWN ACTIVATION | detect cleared=%s DisableDetectFlag=%s "
                .. "DetectStartFlagN=%s | prowl anchor=%s",
            tostring(clearedDetect),
            tostring(disableDetect),
            tostring(detectStart),
            prowlAnchor
                and string.format("%.0f %.0f %.0f",
                    prowlAnchor.X, prowlAnchor.Y, prowlAnchor.Z)
                or "unreadable"
        ))
        log(string.format(
            "SPAWN ACTIVATION | controller=%s | controller:StartAI ok=%s%s | "
                .. "enemy:StartAI ok=%s%s | StartBehaviorTree ok=%s returned=%s",
            isValid(controller) and objectKey(controller) or "none",
            tostring(boundController),
            boundController and "" or (" error=" .. tostring(controllerError)),
            tostring(startedAI),
            startedAI and "" or (" error=" .. tostring(aiError)),
            tostring(startedTree),
            tostring(treeResult)
        ))
    elseif not startedAI or not startedTree then
        dbg("SPAWN ACTIVATION | " .. tostring(key) .. " | StartAI ok="
            .. tostring(startedAI) .. " StartBehaviorTree ok="
            .. tostring(startedTree))
    end
end

-- Actors are not created while World Partition is still streaming.
--
-- Two crashes were seen with heavy spawning, both null dereferences on
-- task-graph worker threads (Foreground Worker #1 reading 0x8, Background
-- Worker #3 reading 0xa4) in two different work items. Neither could be
-- symbolicated: the available symbol map covers only exec* UFunction thunks and
-- the frames land megabytes from the nearest one, so the actual cause is NOT
-- established.
--
-- What is established is that a UObject created on the game thread while a
-- package is async loading is born with EInternalObjectFlags::Async, and that
-- parallel systems pick up newly created enemies immediately. Creating actors in
-- the middle of cell streaming is the one thing this mod does that fits both
-- crashes, so it stops doing it. This is a mitigation, not a diagnosed fix.
--
-- The gate fails open: if the subsystem cannot be resolved, spawning continues
-- and says so once, rather than silently disabling the feature forever.
local function streamingIsSettled()
    if not isValid(worldPartitionSubsystem) then
        worldPartitionSubsystem = nil
        local ok, subsystem = pcall(FindFirstOf, "WorldPartitionSubsystem")
        if not ok or not isValid(subsystem) then
            if not streamingGateReported then
                streamingGateReported = true
                log("SPAWN GATE | WorldPartitionSubsystem is unavailable; "
                    .. "spawning without a streaming gate")
            end
            return true
        end
        worldPartitionSubsystem = subsystem
    end

    local ok, completed = pcall(function()
        return worldPartitionSubsystem:IsAllStreamingCompleted()
    end)
    if not ok then
        if not streamingGateReported then
            streamingGateReported = true
            log("SPAWN GATE | IsAllStreamingCompleted failed: "
                .. tostring(completed) .. "; spawning without a streaming gate")
        end
        return true
    end
    return completed == true
end

local function processSpawnRequest()
    local request = table.remove(spawnQueue, 1)
    if request == nil or request.generation ~= generation then return end
    if not streamingIsSettled() then
        -- Put it back untouched: this is not a failed attempt, so it must not
        -- consume the navigation budget or age the request.
        table.insert(spawnQueue, 1, request)
        dbg("SPAWN DEFERRED | world partition is still streaming")
        return
    end
    if request.spawnEligible ~= true then
        worldFault = "boss-protection invariant rejected queued class " ..
            tostring(request.classKey)
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return
    end
    if protectedBossClasses[request.classKey] == true then
        worldFault = "boss-protection invariant rejected queued boss class " ..
            tostring(request.classKey)
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return
    end
    if not isValid(request.classObject) then
        log("SPAWN ERROR | requested UClass is no longer valid: " .. request.classKey)
        return
    end
    local originState = states[request.originKey]
    if originState == nil or originState.owned or not isValid(originState.object) then
        log("SPAWN ERROR | natural origin is unavailable: " .. request.originKey)
        return
    end
    local apiReady, apiError = resolveSpawnApi()
    if not apiReady then
        pauseForSpawnContractFailure(
            "canonical spawn API is unavailable: " .. firstErrorLine(apiError)
        )
        return
    end

    local spawnClass, classResolveError =
        resolveExactObject(request.classKey)
    if spawnClass == nil then
        pauseForSpawnContractFailure(
            "spawn class resolution failed: " ..
                firstErrorLine(classResolveError)
        )
        return
    end
    local owner, ownerResolveError =
        resolveExactObject(request.originKey)
    if owner == nil then
        pauseForSpawnContractFailure(
            "spawn owner resolution failed: " ..
                firstErrorLine(ownerResolveError)
        )
        return
    end
    -- The origin is still resolved because the navigation query below needs a
    -- world context actor. It is no longer passed to the spawn call itself.
    local contractObjectsOk, contractObjectsError = pcall(function()
        local actorClass = StaticFindObject("/Script/Engine.Actor")
        if not isValid(actorClass) then
            error("canonical Actor class is unavailable")
        end
        if spawnClass:IsAnyClass() ~= true then
            error("resolved Class is not a UClass")
        end
        if owner:IsA(actorClass) ~= true then
            error("resolved spawn origin is not an Actor")
        end
    end)
    if not contractObjectsOk then
        pauseForSpawnContractFailure(
            "spawn object contract failed: " ..
                firstErrorLine(contractObjectsError)
        )
        return
    end
    local position, navigationError, navigationRetryable =
        resolveNavigableSpawnPosition(request, owner)
    if position == nil then
        if navigationRetryable then
            spawnQueue[#spawnQueue + 1] = request
            dbg(string.format(
                "SPAWN NAV RETRY | origin=%s slot=%d class=%s | %s",
                request.originKey,
                request.slot,
                request.classKey,
                tostring(navigationError)
            ))
            return
        end
        log(string.format(
            "SPAWN ERROR | no navigable position origin=%s slot=%d class=%s | %s",
            request.originKey,
            request.slot,
            request.classKey,
            tostring(navigationError)
        ))
        return
    end
    request.position = position

    -- The transform is a plain Lua table and marshals fine: this exact shape is
    -- what the working version passed. FTransform was never the problem in the
    -- RODSpawnActor attempts.
    local transform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = request.position,
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local spawned = nil
    local insertedPending = false
    local okSpawn, spawnError = pcall(function()
        spawned = gameplayStatics:BeginDeferredActorSpawnFromClass(
            owner,
            spawnClass,
            transform,
            SPAWN_COLLISION_ALWAYS,
            nil,
            SPAWN_SCALE_MULTIPLY_ROOT
        )
        if not isValid(spawned) then
            error("BeginDeferredActorSpawnFromClass returned no actor")
        end
        -- Registered as pending before FinishSpawningActor, so a failure in the
        -- second half still has an owner to clean up.
        request.actorKey = objectKey(spawned)
        if request.actorKey == nil then
            error("created actor has no canonical object key")
        end
        request.object = spawned
        request.expiresAtMs = elapsedMs + SPAWN_INITIALIZE_MS
        pendingSpawns[#pendingSpawns + 1] = request
        insertedPending = true

        local finished = gameplayStatics:FinishSpawningActor(
            spawned,
            transform,
            SPAWN_SCALE_MULTIPLY_ROOT
        )
        if not isValid(finished) then
            error("FinishSpawningActor returned no actor")
        end
        if objectKey(finished) ~= request.actorKey then
            error("FinishSpawningActor returned a different actor")
        end
        request.object = finished
        finished:SetEnemyLevel(request.level, false)
    end)
    if not okSpawn then
        if insertedPending then
            for index = #pendingSpawns, 1, -1 do
                if pendingSpawns[index] == request then
                    table.remove(pendingSpawns, index)
                    break
                end
            end
        end
        if isValid(spawned) then
            pcall(function() spawned:K2_DestroyActor() end)
        end
        log("SPAWN ERROR | canonical actor creation failed: " ..
            summarizeSpawnCallError(spawnError))
        return
    end
    dbg(string.format(
        "SPAWN CREATED | origin=%s slot=%d class=%s actor=%s",
        request.originKey,
        request.slot,
        request.classKey,
        request.actorKey
    ))
end

local function requestWorldScan()
    local ok, enemies = pcall(FindAllOf, "RODEnemyCharacter")
    if not ok then
        worldFault = "FindAllOf(RODEnemyCharacter) failed: " .. tostring(enemies)
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return false
    end
    discoveryBatch = true
    discoveryReadyAtMs = elapsedMs + DISCOVERY_STABILIZE_MS
    if enemies ~= nil then
        for _, enemy in pairs(enemies) do
            objectQueue[#objectQueue + 1] = { object = enemy, reused = false }
        end
    end
    dbg("WORLD SCAN | queued " .. tostring(#objectQueue) .. " enemy object(s)")
    return true
end

disableWorld = function(reason)
    spawnQueue = {}
    for index = #pendingSpawns, 1, -1 do
        local request = table.remove(pendingSpawns, index)
        destroyPending(request, reason)
    end
    local owned = {}
    for _, state in pairs(states) do
        if state.owned then
            owned[#owned + 1] = state
        else
            restoreState(state)
        end
    end
    for _, state in ipairs(owned) do destroyOwned(state, reason) end
    for _, origin in pairs(origins) do origin.issued = 0 end
end

-- The outgoing world is about to be destroyed. Calling K2_DestroyActor here
-- races the game's asynchronous enemy teardown and can leave worker tasks with
-- a dangling actor. Count the owned references for diagnostics and let
-- beginTravel release every Lua reference; the world remains the authoritative
-- owner of actor destruction.
releaseWorldForTravel = function(reason)
    local released = 0
    spawnQueue = {}
    released = released + #pendingSpawns
    for _, state in pairs(states) do
        if state.owned then released = released + 1 end
    end
    dbg(string.format(
        "TRAVEL RELEASE | %s | owned references=%d",
        reason,
        released
    ))
    return released, 0
end

local function applyNewSettings(settings, digest)
    local previous = CONFIG
    local wasEnabled = configHealthy and CONFIG ~= nil and CONFIG.ENABLED
    local spawnShapeChanged = previous ~= nil
        and (previous.RANDOMIZE_EXTRA_SPECIES ~= settings.RANDOMIZE_EXTRA_SPECIES
            or previous.SPAWN_RADIUS ~= settings.SPAWN_RADIUS)
    local eligibilityChanged = previous ~= nil
        and previous.INCLUDE_BOSSES ~= settings.INCLUDE_BOSSES
    CONFIG = settings
    configDigest = digest
    configHealthy = true
    log(string.format(
        "CONFIG APPLIED | enabled=%s spawn=%dx cap=%d random=%s bossMutation=%s bossSpawn=false scale=%.2f-%.2f color=%s",
        tostring(CONFIG.ENABLED),
        CONFIG.SPAWN_MULTIPLIER,
        CONFIG.MAX_ACTIVE_EXTRAS,
        tostring(CONFIG.RANDOMIZE_EXTRA_SPECIES),
        tostring(CONFIG.INCLUDE_BOSSES),
        CONFIG.SCALE_MIN,
        CONFIG.SCALE_MAX,
        CONFIG.COLOR_MODE
    ))

    if worldPaused then return end
    cleanupInvalidStates()
    if eligibilityChanged then
        disableWorld("boss eligibility changed")
        states = {}
        origins = {}
        classCatalog = {}
        classOrder = {}
        objectQueue = {}
        discoveryBatch = false
        if CONFIG.ENABLED then rescanRequested = true end
    end
    if not CONFIG.ENABLED then
        disableWorld("director disabled")
        return
    end
    if eligibilityChanged then return end
    if spawnShapeChanged then disableWorld("spawn layout changed") end
    if not wasEnabled then rescanRequested = true end
    for _, state in pairs(states) do applyMutation(state) end
    for _, origin in pairs(origins) do reconcileOrigin(origin) end
    enforceGlobalCap()
end

local function checkSettings(force)
    if not force and elapsedMs - lastSettingsCheckMs < SETTINGS_POLL_MS then return end
    lastSettingsCheckMs = elapsedMs

    local settings, digest, settingsError, transactionInProgress = loadSettings()
    if transactionInProgress then return end
    if digest == configDigest and configHealthy then return end
    if settings == nil then
        local failureDigest = "ERROR:" .. tostring(settingsError)
        if configDigest ~= failureDigest then
            configDigest = failureDigest
            log("CONFIG ERROR | " .. tostring(settingsError) .. " | director disabled")
        end
        if configHealthy then disableWorld("configuration rejected") end
        configHealthy = false
        return
    end
    applyNewSettings(settings, digest)
end

-- Distance recycling.
--
-- Origins here are actors placed in the persistent level, so they never become
-- invalid and cleanupInvalidStates never fires for them. Without this, extras
-- created in one place stay alive forever: MAX_ACTIVE_EXTRAS stays saturated by
-- enemies the player has long left behind, and no new area ever gets any.
--
-- It also bounds how many owned actors are alive when a mission ends, which is
-- when the engine's fatal world-leak check runs. That check has already been
-- seen firing on a spawned enemy's AI controller.
-- FindFirstOf walks the global object array. Doing that twice a tick was enough
-- to be felt as stutter, so the hero is resolved once and kept until it stops
-- being valid, which is also when travel invalidates it.
local function resolveHeroObject()
    if not isValid(cachedHero) then
        cachedHero = nil
        local ok, hero = pcall(FindFirstOf, "RODWorldHeroCharacter")
        if not ok or not isValid(hero) then return nil end
        cachedHero = hero
    end
    return cachedHero
end

local function resolveHeroLocation()
    local hero = resolveHeroObject()
    if not isValid(hero) then return nil end
    return actorLocation(hero)
end

local function recycleDistantExtras()
    local heroLocation, heroError = resolveHeroLocation()
    if heroLocation == nil then
        dbg("RECYCLE | hero location unavailable: " .. tostring(heroError))
        return
    end

    local limitSquared = CONFIG.DESPAWN_RADIUS * CONFIG.DESPAWN_RADIUS
    local distant = {}
    for _, state in pairs(states) do
        if state.owned then
            local location = isValid(state.object) and actorLocation(state.object)
                or state.spawnPosition
            if location ~= nil
                and planarDistanceSquared(location, heroLocation) > limitSquared then
                distant[#distant + 1] = state
            end
        end
    end

    for _, state in ipairs(distant) do
        local originKey = state.originKey
        if destroyOwned(state, "player left the area") then
            -- The slot is handed back so the same origin can re-issue it if the
            -- player returns, instead of the origin being permanently spent.
            local origin = originKey ~= nil and origins[originKey] or nil
            if origin ~= nil and origin.issued > 0 then
                origin.issued = origin.issued - 1
            end
        end
    end
    if #distant > 0 then
        dbg(string.format("RECYCLE | released %d extra(s) beyond %.0f cm",
            #distant, CONFIG.DESPAWN_RADIUS))
    end
    return #distant > 0
end

-- Origins are only reconciled when their natural enemy is rediscovered, and a
-- persistent-level enemy is discovered once per world. After recycling frees
-- slots, the origins near the player have to be revisited or nothing refills.
local function reconcileNearbyOrigins()
    local heroLocation = resolveHeroLocation()
    if heroLocation == nil then return end

    local limitSquared = CONFIG.DESPAWN_RADIUS * CONFIG.DESPAWN_RADIUS
    for _, origin in pairs(origins) do
        if origin.location ~= nil
            and planarDistanceSquared(origin.location, heroLocation) <= limitSquared then
            reconcileOrigin(origin)
        end
    end
end

local function tick(stepMs)
    elapsedMs = elapsedMs + stepMs
    checkSettings(CONFIG == nil)

    if worldPaused then
        local hero = resolveHeroObject()
        local controller = resolveLocalController()
        local heroReady = isValid(hero)
        local clockPassed = (resumeAtMs ~= nil and elapsedMs >= resumeAtMs)

        if heroReady and controller ~= nil then
            readinessStabilitySamples = readinessStabilitySamples + 1
        else
            readinessStabilitySamples = 0
        end

        if clockPassed or readinessStabilitySamples >= STABILITY_SAMPLES_REQUIRED then
            readinessStabilitySamples = 0
            worldPaused = false
            resumeAtMs = nil
            rescanRequested = true
            log("WORLD READY | enemy director resumed via readiness stability")
        else
            return
        end
    end
    if worldFault ~= nil then return end
    if not configHealthy or not CONFIG.ENABLED then
        expirePendingSpawns()
        objectQueue = {}
        return
    end

    cleanupInvalidStates()
    expirePendingSpawns()
    if not discoveryBatch then
        -- reconcileNearbyOrigins is O(origins x states); running it every tick
        -- alongside recycling was the other half of the stutter. It only has
        -- anything to do after a slot is freed, so it runs then, or on a slow
        -- cadence to pick up an origin that came into range on its own.
        local freed = recycleDistantExtras()
        if freed or elapsedMs >= nextOriginSweepMs then
            nextOriginSweepMs = elapsedMs + ORIGIN_SWEEP_MS
            reconcileNearbyOrigins()
        end
    end
    if rescanRequested then
        rescanRequested = false
        if not requestWorldScan() then return end
    end

    local discoveryStartTime = os.clock()
    local MAX_DISCOVERY_SEC = 0.002
    for _ = 1, MAX_DISCOVERY_PER_TICK do
        local queued = table.remove(objectQueue, 1)
        if queued == nil then break end
        registerEnemy(queued.object, queued.reused, queued)
        if os.clock() - discoveryStartTime > MAX_DISCOVERY_SEC then break end
    end
    if discoveryBatch
        and #objectQueue == 0
        and discoveryReadyAtMs ~= nil
        and elapsedMs >= discoveryReadyAtMs then
        discoveryBatch = false
        discoveryReadyAtMs = nil
        for _, origin in pairs(origins) do reconcileOrigin(origin) end
        enforceGlobalCap()
        dbg("WORLD SCAN | discovery batch completed")
    end
    if discoveryBatch then return end
    if #spawnQueue > 0 then processSpawnRequest() end
end

local tickQueued = false
local function poll()
    local delay = CONFIG.POLL_MS
    if not tickQueued then
        tickQueued = true
        local scheduledStepMs = delay
        ExecuteInGameThread(function()
            tickQueued = false
            local handler = debug.traceback
            local ok, tickError = xpcall(function() tick(scheduledStepMs) end, handler)
            if not ok then
                worldFault = tostring(tickError)
                log("WORLD ERROR | " .. worldFault .. " | director paused")
            end
        end)
    end
    ExecuteWithDelay(delay, poll)
end

local function requireHook(path, callback, postCallback)
    local ok, hookError = pcall(function()
        if postCallback ~= nil then
            RegisterHook(path, callback, postCallback)
        else
            RegisterHook(path, callback)
        end
    end)
    if not ok then error("[" .. MOD_NAME .. "] HOOK ERROR | " .. path .. " | " .. tostring(hookError)) end
end

local function queueLifecycleEnemy(object, reused)
    if worldPaused and resumeAtMs == nil then return end
    if CONFIG ~= nil and (not configHealthy or not CONFIG.ENABLED) then return end
    if worldFault ~= nil then return end
    objectQueue[#objectQueue + 1] = { object = object, reused = reused }
    if discoveryBatch then
        discoveryReadyAtMs = elapsedMs + DISCOVERY_STABILIZE_MS
    end
end

requireHook(
    "/Script/ROD.RODEnemyCharacter:OnFinishedInitialize",
    function() end,
    function(context)
        queueLifecycleEnemy(context:get(), false)
    end
)

requireHook(
    "/Script/ROD.RODEnemyCharacter:EnemyReused",
    function() end,
    function(context)
        queueLifecycleEnemy(context:get(), true)
    end
)

for _, travelHook in ipairs({
    { "/Script/Engine.PlayerController:ClientTravelInternal", "ClientTravelInternal" },
    { "/Script/Engine.PlayerController:ClientPrepareMapChange", "ClientPrepareMapChange" },
    { "/Script/ROD.RODGameState:StartQuestEnd", "StartQuestEnd" },
    { "/Script/ROD.RODGameState:QuestEnd", "QuestEnd" },
    { "/Script/ROD.RODGameState:ShowQuestResult", "GameState.ShowQuestResult" },
    { "/Script/ROD.RODPlayerState:ServerDecideTown", "ServerDecideTown" },
    { "/Script/ROD.RODPlayerState:ServerShowQuestResult", "ServerShowQuestResult" },
}) do
    local hookPath = travelHook[1]
    local hookLabel = travelHook[2]
    requireHook(hookPath, function() beginTravel(hookLabel) end)
end

requireHook(
    "/Script/ROD.RODPlayerState:ServerDecideFastTravel",
    function()
        beginSameWorldSettle("ServerDecideFastTravel(same-world)")
    end
)

requireHook(
    "/Script/ROD.RODPlayerState:ServerNotifyQuestTeleportOut",
    beginQuestTeleportSettle
)

requireHook("/Script/Engine.PlayerController:ClientRestart", beginRestartSettle)

--========================================================--
--                   SPAWN CALL MATRIX                    --
--========================================================--
-- `worldenemy spawntest` tries several argument shapes against RODSpawnActor in
-- one pass and reports which property each one dies on.
--
-- This exists because the failure only reproduces in game and every hypothesis
-- so far cost a full restart to test exactly one variable. The property named in
-- each rejection is the signal: comparing which parameter each shape stops at
-- says how many stack slots the ones before it consumed, which is the thing that
-- cannot be read back on this build any other way.
--
-- A shape that gets through spawns a real enemy. That is the intended success
-- condition, and the extra enemy is left as an ordinary one the director does
-- not own.
local function spawnTestSubject()
    local state = FindFirstOf("RODGameState")
    if not isValid(state) then return nil, nil, nil, "RODGameState is unavailable" end

    local enemy = FindFirstOf("RODEnemyCharacter")
    if not isValid(enemy) then
        return nil, nil, nil, "no RODEnemyCharacter is loaded to spawn beside"
    end

    local classOk, enemyClass = pcall(function() return enemy:GetClass() end)
    if not classOk or not isValid(enemyClass) then
        return nil, nil, nil, "enemy class is unreadable"
    end

    local library = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    if not isValid(library) then
        return nil, nil, nil, "KismetMathLibrary is unavailable"
    end

    local transformOk, transform = pcall(function()
        local origin = enemy:K2_GetActorLocation()
        return library:MakeTransform(
            { X = origin.X + 200.0, Y = origin.Y + 200.0, Z = origin.Z },
            { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
            { X = 1.0, Y = 1.0, Z = 1.0 }
        )
    end)
    if not transformOk or transform == nil then
        return nil, nil, nil, "MakeTransform failed: " .. tostring(transform)
    end

    return state, enemyClass, { enemy = enemy, transform = transform }, nil
end

local function fullSpawnOption(location)
    return {
        ActorTags = {},
        FlowGameplayTags = {},
        DefaultSpawnOn = SPAWN_ON_SERVER,
        ItemLotKey = "None",
        Items = {},
        IsDropItems = false,
        HeroNumber = 0,
        IsPermanentableItem = false,
        ReplaceNameID = 0,
        Level = 1,
        InitialState = INITIAL_STATE_PROWL,
        InitialStateLoc = location,
        IsNodetect = false,
        IsStartBehaviorTree = true,
        IsBossWave = false,
        IsDangerousTreasureChests = false,
        IsForcePlaySpawnFX = false,
    }
end

local function runSpawnTest()
    local state, enemyClass, subject, subjectError = spawnTestSubject()
    if state == nil then
        log("SPAWN TEST | cannot run: " .. tostring(subjectError))
        return
    end

    local enemy = subject.enemy
    local transform = subject.transform
    local location = nil
    pcall(function() location = enemy:K2_GetActorLocation() end)

    log("SPAWN TEST | subject class=" .. tostring(objectKey(enemyClass))
        .. " owner=" .. tostring(objectKey(enemy)))

    local controller = resolveLocalController()
    local spawnPoint = nil
    pcall(function()
        local origin = enemy:K2_GetActorLocation()
        spawnPoint = {
            X = origin.X + 200.0,
            Y = origin.Y + 200.0,
            Z = origin.Z,
        }
    end)

    -- Each shape varies exactly one thing from the one above it.
    local shapes = {
        {
            -- The path the director uses. Its native symbol exists, it returns
            -- without error, and nothing appears; this confirms that against a
            -- deliberate, visible attempt right next to the player.
            name = "ServerDebugEnemySpawn(class, level, position)",
            call = function()
                if not isValid(controller) then
                    error("RODInGamePlayerController is unavailable")
                end
                if spawnPoint == nil then error("spawn point unreadable") end
                return controller:ServerDebugEnemySpawn(enemyClass, 1, spawnPoint)
            end,
        },
        {
            name = "full option, instigator=owner",
            call = function()
                return state:RODSpawnActor(enemyClass, transform,
                    fullSpawnOption(location), enemy, enemy,
                    SPAWN_COLLISION_ADJUST_OR_REJECT)
            end,
        },
        {
            name = "empty option, instigator=owner",
            call = function()
                return state:RODSpawnActor(enemyClass, transform, {}, enemy,
                    enemy, SPAWN_COLLISION_ADJUST_OR_REJECT)
            end,
        },
        {
            name = "nil option, instigator=owner",
            call = function()
                return state:RODSpawnActor(enemyClass, transform, nil, enemy,
                    enemy, SPAWN_COLLISION_ADJUST_OR_REJECT)
            end,
        },
        {
            name = "four arguments only",
            call = function()
                return state:RODSpawnActor(enemyClass, transform,
                    fullSpawnOption(location), enemy)
            end,
        },
        {
            name = "two arguments only",
            call = function()
                return state:RODSpawnActor(enemyClass, transform)
            end,
        },
    }

    for index, shape in ipairs(shapes) do
        -- Logged before the call: a native marshaling fault can take the process
        -- down past pcall, and then this line names the shape that did it.
        log(string.format("SPAWN TEST | %d/%d trying: %s",
            index, #shapes, shape.name))
        local ok, resultOrError = pcall(shape.call)
        if ok then
            local spawnOn = "unreadable"
            pcall(function() spawnOn = tostring(resultOrError.SpawnOn) end)
            log(string.format("SPAWN TEST | %d PASSED: %s | SpawnOn=%s",
                index, shape.name, spawnOn))
        else
            log(string.format("SPAWN TEST | %d failed: %s | %s",
                index, shape.name, summarizeSpawnCallError(resultOrError)))
        end
    end
    log("SPAWN TEST | matrix complete")
end

RegisterConsoleCommandGlobalHandler(
    "enemy_director_spawntest",
    function()
        -- Replies are not attempted here: the console writer is only valid for
        -- this synchronous call, and the matrix runs on the game thread.
        ExecuteInGameThread(function()
            local ok, err = pcall(runSpawnTest)
            if not ok then log("SPAWN TEST | aborted: " .. tostring(err)) end
        end)
        return true
    end
)

RegisterConsoleCommandGlobalHandler(
    "enemy_director_status",
    function()
        ExecuteInGameThread(function()
            local natural, owned = 0, 0
            for _, state in pairs(states) do
                if state.owned then owned = owned + 1 else natural = natural + 1 end
            end
            log(string.format(
                "STATUS | healthy=%s enabled=%s paused=%s fault=%s natural=%d extras=%d queued=%d pending=%d classes=%d spawning=%s",
                tostring(configHealthy),
                tostring(CONFIG ~= nil and CONFIG.ENABLED),
                tostring(worldPaused),
                tostring(worldFault),
                natural,
                owned,
                #spawnQueue,
                #pendingSpawns,
                #classOrder,
                spawningProvenInert and "INERT (multiplication off)" or "on"
            ))
        end)
        return true
    end
)

math.randomseed(os.time())
checkSettings(true)
if not configHealthy or CONFIG == nil then
    error("[" .. MOD_NAME .. "] CONFIG ERROR | initial canonical configuration rejected")
end
poll()
log("READY | waiting for the playable world; console: enemy_director_status"
    .. " | enemy_director_spawntest")
