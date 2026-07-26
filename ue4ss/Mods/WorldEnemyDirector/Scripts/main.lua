local MOD_NAME = "WorldEnemyDirector"
local MOD_VERSION = "1.4.3"

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

local STARTUP_SETTLE_MS = 8000
local RESTART_SETTLE_MS = 5000
local QUEST_TELEPORT_SETTLE_MS = 8000
local DISCOVERY_STABILIZE_MS = 2000
local SETTINGS_POLL_MS = 1000
local SPAWN_INITIALIZE_MS = 8000
local NAV_ATTEMPTS_PER_PASS = 4
local NAV_MAX_ATTEMPTS = 36
local NAV_MIN_SEPARATION_CM = 150.0
local NAV_GOLDEN_ANGLE_RADIANS = 2.399963229728653
local MAX_DISCOVERY_PER_TICK = 8
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

local function loadSettings()
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
    local digest = configContents .. "\0" .. (runtimeContents or "")
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
local rodGameState = nil
local navigationSystem = nil
local disableWorld
local releaseWorldForTravel
local gcScheduled = false

local function scheduleReferenceCollection()
    if gcScheduled then return end
    gcScheduled = true
    ExecuteWithDelay(1, function()
        gcScheduled = false
        collectgarbage("collect")
    end)
end

local function clearWorldReferences()
    states = {}
    origins = {}
    classCatalog = {}
    classOrder = {}
    protectedBossClasses = {}
    objectQueue = {}
    spawnQueue = {}
    pendingSpawns = {}
    discoveryBatch = false
    discoveryReadyAtMs = nil
    worldFault = nil
    rodGameState = nil
    navigationSystem = nil
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

local function resolveSpawnApi()
    if not isValid(rodGameState) then
        rodGameState = nil
        local stateOk, state = pcall(FindFirstOf, "RODGameState")
        if not stateOk then
            return false, "FindFirstOf(RODGameState) failed: " .. tostring(state)
        end
        if not isValid(state) then
            return false, "current RODGameState is unavailable"
        end
        rodGameState = state
    end

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

local function snapshotGas(enemy)
    local okSystem, abilitySystem = pcall(function() return enemy.AbilitySystem end)
    if not okSystem or not isValid(abilitySystem) then
        return nil, "required enemy AbilitySystem is unavailable"
    end

    local reflected = {}
    local okAttributes, attributesError =
        pcall(function() abilitySystem:GetAllAttributes(reflected) end)
    if not okAttributes then
        return nil, "GetAllAttributes failed: " .. tostring(attributesError)
    end

    local wanted = {}
    for key, name in pairs(GAS_ATTRIBUTE_NAMES) do wanted[name] = key end
    local attributes = {}
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
    local ok, mesh, meshScale, maxHealth, attack, defence, experience,
        movingSpeed, goldenGateBoss, enemyRole =
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
                enemy.EnemyRole
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
    local gas, gasError = snapshotGas(enemy)
    if gas == nil then return nil, gasError end
    local isBoss = goldenGateBoss or enemyRole == ENEMY_ROLE_BOSS
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

local function destroyPending(request, reason)
    if isValid(request.object) then
        local ok, destroyError = pcall(function() request.object:K2_DestroyActor() end)
        if not ok then
            log("DESTROY ERROR | pending " .. request.actorKey ..
                " | " .. tostring(destroyError))
            return false
        end
    end
    dbg("PENDING EXTRA REMOVED | " .. request.actorKey .. " | " .. reason)
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

local function selectSpawnClass(origin)
    if protectedBossClasses[origin.classKey] == true then return nil, nil end
    if not CONFIG.RANDOMIZE_EXTRA_SPECIES then
        if origin.spawnEligible ~= true then return nil, nil end
        return origin.classObject, origin.classKey
    end
    if #classOrder == 0 then return nil, nil end
    local entry = classCatalog[classOrder[math.random(1, #classOrder)]]
    if entry == nil
        or entry.spawnEligible ~= true
        or protectedBossClasses[entry.classKey] == true
        or not isValid(entry.classObject) then
        return nil, nil
    end
    return entry.classObject, entry.classKey
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

local function pathIsComplete(path)
    local stateOk, pathValid, pathPartial, pathLength = pcall(function()
        return path:IsValid(), path:IsPartial(), tonumber(path:GetPathLength())
    end)
    if not stateOk then
        return false, "UNavigationPath state is unreadable: " ..
            tostring(pathValid)
    end
    if pathValid ~= true then return false, "UNavigationPath is invalid" end
    if pathPartial == true then return false, "UNavigationPath is partial" end
    if not finiteNumber(pathLength) or pathLength <= 0.0 then
        return false, "UNavigationPath has no positive path length"
    end
    return true, nil
end

local function pathCandidate(request, attempt)
    local separation = minimumSpawnSeparation()
    local usableRadius = CONFIG.SPAWN_RADIUS - separation
    if usableRadius < 0.0 then
        error("SPAWN_RADIUS is smaller than the required separation")
    end
    local fraction = (attempt - 0.5) / NAV_MAX_ATTEMPTS
    local radius = separation + math.sqrt(fraction) * usableRadius
    local angle = request.navSeed
        + attempt * NAV_GOLDEN_ANGLE_RADIANS
    return {
        X = request.originLocation.X + math.cos(angle) * radius,
        Y = request.originLocation.Y + math.sin(angle) * radius,
        Z = request.originLocation.Z,
    }
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

    local firstAttempt = request.navAttempts + 1
    local finalAttempt = math.min(
        request.navAttempts + NAV_ATTEMPTS_PER_PASS,
        NAV_MAX_ATTEMPTS
    )
    local lastFailure = "navigation rejected every candidate"
    for attempt = firstAttempt, finalAttempt do
        request.navAttempts = attempt
        local candidate = pathCandidate(request, attempt)
        local queryOk, path = pcall(function()
            return navigationSystem:FindPathToLocationSynchronously(
                worldContext,
                request.originLocation,
                candidate,
                worldContext,
                nil
            )
        end)
        if not queryOk then
            return nil, "FindPathToLocationSynchronously failed: " ..
                tostring(path), false
        end
        if isValid(path) then
            local complete, pathError = pathIsComplete(path)
            if complete then
                local position = candidate
                local maxRadius = CONFIG.SPAWN_RADIUS + 25.0
                if planarDistanceSquared(position, request.originLocation)
                    <= maxRadius * maxRadius
                    and spawnPositionIsSeparated(position) then
                    return position, nil, false
                end
                lastFailure = string.format(
                    "path endpoint violated radius or %.0f cm separation",
                    minimumSpawnSeparation()
                )
            else
                lastFailure = pathError
            end
        else
            lastFailure = "FindPathToLocationSynchronously returned no path"
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
        log("SPAWN ERROR | loaded enemy class catalog is empty")
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
        navSeed = math.random() * math.pi * 2.0,
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

    log("BOSS CLASS PROTECTED | removed from spawn system: " .. classKey)
end

local function takePendingSpawn(actorKey)
    for index, request in ipairs(pendingSpawns) do
        if request.generation == generation and request.actorKey == actorKey then
            table.remove(pendingSpawns, index)
            return request
        end
    end
    return nil
end

local function registerEnemy(enemy, reused)
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
                log(string.format(
                    "SPAWN ERROR | created enemy did not finish initialization origin=%s slot=%d class=%s",
                    request.originKey,
                    request.slot,
                    request.classKey
                ))
                destroyPending(request, "initialization timeout")
            end
        end
    end
end

local function processSpawnRequest()
    local request = table.remove(spawnQueue, 1)
    if request == nil or request.generation ~= generation then return end
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
        log("SPAWN ERROR | " .. apiError)
        return
    end

    local position, navigationError, navigationRetryable =
        resolveNavigableSpawnPosition(request, originState.object)
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

    local transform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = request.position,
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local option = {
        ActorTags = {},
        FlowGameplayTags = {},
        DefaultSpawnOn = SPAWN_ON_SERVER,
        ItemLotKey = FName("None"),
        Items = {},
        IsDropItems = false,
        HeroNumber = 0,
        IsPermanentableItem = false,
        ReplaceNameID = 0,
        Level = request.level,
        InitialState = INITIAL_STATE_PROWL,
        InitialStateLoc = request.position,
        IsNodetect = false,
        IsStartBehaviorTree = true,
        IsBossWave = false,
        IsDangerousTreasureChests = false,
        IsForcePlaySpawnFX = false,
    }
    local spawned = nil
    local insertedPending = false
    local okSpawn, spawnError = pcall(function()
        local result = rodGameState:RODSpawnActor(
            request.classObject,
            transform,
            option,
            originState.object,
            originState.object,
            SPAWN_COLLISION_ADJUST_OR_REJECT
        )
        if result == nil then error("RODSpawnActor returned no result") end
        local resultSpawnOn = tonumber(result.SpawnOn)
        if resultSpawnOn ~= SPAWN_ON_SERVER then
            error("RODSpawnActor returned non-server SpawnOn=" ..
                tostring(resultSpawnOn))
        end
        local weakActor = result.ServerSpawnActor
        if weakActor == nil then
            error("RODSpawnActor result has no ServerSpawnActor")
        end
        spawned = weakActor:Get()
        if not isValid(spawned) then
            error("RODSpawnActor returned no valid server actor")
        end
        request.actorKey = objectKey(spawned)
        if request.actorKey == nil then error("created actor has no canonical object key") end
        request.object = spawned
        request.expiresAtMs = elapsedMs + SPAWN_INITIALIZE_MS
        pendingSpawns[#pendingSpawns + 1] = request
        insertedPending = true
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
        log("SPAWN ERROR | RODSpawnActor failed: " .. tostring(spawnError))
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
    if digest == configDigest and configHealthy then return end
    applyNewSettings(settings, digest)
end

local function tick(stepMs)
    elapsedMs = elapsedMs + stepMs
    checkSettings(CONFIG == nil)

    if worldPaused then
        if resumeAtMs ~= nil and elapsedMs >= resumeAtMs then
            worldPaused = false
            resumeAtMs = nil
            rescanRequested = true
            log("WORLD READY | enemy director resumed")
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
    if rescanRequested then
        rescanRequested = false
        if not requestWorldScan() then return end
    end

    for _ = 1, MAX_DISCOVERY_PER_TICK do
        local queued = table.remove(objectQueue, 1)
        if queued == nil then break end
        registerEnemy(queued.object, queued.reused)
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

RegisterConsoleCommandGlobalHandler(
    "enemy_director_status",
    function()
        ExecuteInGameThread(function()
            local natural, owned = 0, 0
            for _, state in pairs(states) do
                if state.owned then owned = owned + 1 else natural = natural + 1 end
            end
            log(string.format(
                "STATUS | healthy=%s enabled=%s paused=%s fault=%s natural=%d extras=%d queued=%d pending=%d classes=%d",
                tostring(configHealthy),
                tostring(CONFIG ~= nil and CONFIG.ENABLED),
                tostring(worldPaused),
                tostring(worldFault),
                natural,
                owned,
                #spawnQueue,
                #pendingSpawns,
                #classOrder
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
log("READY | waiting for the playable world; console: enemy_director_status")
