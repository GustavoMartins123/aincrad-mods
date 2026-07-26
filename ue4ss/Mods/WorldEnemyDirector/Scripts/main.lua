local MOD_NAME = "WorldEnemyDirector"
local MOD_VERSION = "1.1.1"

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

local STARTUP_SETTLE_MS = 8000
local RESTART_SETTLE_MS = 5000
local SETTINGS_POLL_MS = 1000
local SPAWN_TICKET_MS = 8000
local SPAWN_MATCH_DISTANCE_CM = 650.0
local SPAWN_Z_OFFSET_CM = 40.0
local MAX_DISCOVERY_PER_TICK = 8
local GAMEPLAY_MOD_ADDITIVE = 0
local GAS_VALUE_EPSILON = 0.01

local GAS_ATTRIBUTE_NAMES = {
    health = "Health",
    maxHealth = "MaxHealth",
    attack = "ATK",
    defence = "Def",
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
    return merged, digest, nil
end

local function isValid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
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

local function squaredDistance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local states = {}
local origins = {}
local classCatalog = {}
local classOrder = {}
local objectQueue = {}
local spawnQueue = {}
local pendingSpawns = {}
local discardSpawns = {}
local discoveryBatch = false
local generation = 1
local worldPaused = true
local resumeAtMs = STARTUP_SETTLE_MS
local rescanRequested = false
local worldFault = nil

local materialLibrary = nil
local materialInterface = nil

local function clearWorldReferences()
    states = {}
    origins = {}
    classCatalog = {}
    classOrder = {}
    objectQueue = {}
    spawnQueue = {}
    pendingSpawns = {}
    discardSpawns = {}
    discoveryBatch = false
    worldFault = nil
end

local function beginTravel(reason)
    generation = generation + 1
    worldPaused = true
    resumeAtMs = nil
    clearWorldReferences()
    log("TRAVEL START | " .. reason .. " | native object access paused")
end

local function beginRestartSettle()
    generation = generation + 1
    worldPaused = true
    resumeAtMs = elapsedMs + RESTART_SETTLE_MS
    clearWorldReferences()
    log("TRAVEL SETTLE | ClientRestart | waiting 5 seconds")
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
        applied = { maxHealth = 0.0, attack = 0.0, defence = 0.0 },
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
    local ok, scale, maxHealth, attack, defence, experience, movingSpeed, isBoss =
        pcall(function()
            return enemy:GetActorScale3D(),
                enemy.MaxHelth,
                enemy.AttackPower,
                enemy.DefencePower,
                enemy.ExperiencePoint,
                enemy.MovingSpeed,
                enemy.GoldenGateBoss
        end)
    if not ok then return nil, "required enemy fields are unreadable" end
    local parsedScale = vector(scale)
    if parsedScale == nil then return nil, "GetActorScale3D returned an invalid vector" end
    for key, value in pairs({
        MaxHelth = maxHealth,
        AttackPower = attack,
        DefencePower = defence,
        ExperiencePoint = experience,
        MovingSpeed = movingSpeed,
    }) do
        if not finiteNumber(value) then return nil, key .. " is not numeric" end
    end
    if type(isBoss) ~= "boolean" then return nil, "GoldenGateBoss is not boolean" end
    local gas, gasError = snapshotGas(enemy)
    if gas == nil then return nil, gasError end
    return {
        scale = parsedScale,
        MaxHelth = maxHealth,
        AttackPower = attack,
        DefencePower = defence,
        ExperiencePoint = experience,
        MovingSpeed = movingSpeed,
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
    local gas = state.baseline.gas
    local current, currentError = readGasValue(gas, key)
    if current == nil then error(currentError) end
    applyGasDelta(state, key, target - current)
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

    local desiredAttackDelta = gas.baseline.attack * (attackMultiplier - 1.0)
    applyGasDelta(state, "attack", desiredAttackDelta - gas.applied.attack)
    gas.applied.attack = desiredAttackDelta

    local desiredDefenceDelta = gas.baseline.defence * (defenceMultiplier - 1.0)
    applyGasDelta(state, "defence", desiredDefenceDelta - gas.applied.defence)
    gas.applied.defence = desiredDefenceDelta
end

local function captureMutationState(state)
    local object = state.object
    local snapshot = {
        gasValues = gasValues(state.baseline.gas),
        gasApplied = {
            maxHealth = state.baseline.gas.applied.maxHealth,
            attack = state.baseline.gas.applied.attack,
            defence = state.baseline.gas.applied.defence,
        },
        applied = state.applied,
        colorParameter = state.colorParameter,
        appliedColor = copyColor(state.appliedColor),
    }
    snapshot.scale = vector(object:GetActorScale3D())
    if snapshot.scale == nil then error("live actor scale is invalid") end
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
        setGasValue(state, "attack", previous.gasValues.attack)
        setGasValue(state, "defence", previous.gasValues.defence)
        object:SetActorScale3D(previous.scale)
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
    gas.applied.attack = previous.gasApplied.attack
    gas.applied.defence = previous.gasApplied.defence
    state.applied = previous.applied
    state.colorParameter = previous.colorParameter
    state.appliedColor = copyColor(previous.appliedColor)
    return true
end

local function restoreState(state)
    if not state.applied then return true end
    if not isValid(state.object) then return false end
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
        state.object:SetActorScale3D(base.scale)
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
        X = base.scale.X * scaleFactor,
        Y = base.scale.Y * scaleFactor,
        Z = base.scale.Z * scaleFactor,
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
        state.object:SetActorScale3D(newScale)
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

local function removeOrigin(originKey, destroyActors)
    origins[originKey] = nil
    for index = #spawnQueue, 1, -1 do
        if spawnQueue[index].originKey == originKey then table.remove(spawnQueue, index) end
    end
    for index = #pendingSpawns, 1, -1 do
        if pendingSpawns[index].originKey == originKey then
            discardSpawns[#discardSpawns + 1] = table.remove(pendingSpawns, index)
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
    if activeExtraCount() > CONFIG.MAX_ACTIVE_EXTRAS then
        log("SPAWN CAP | pending native requests temporarily exceed the new cap")
    end
end

local function selectSpawnClass(origin)
    if not CONFIG.RANDOMIZE_EXTRA_SPECIES then
        return origin.classObject, origin.classKey
    end
    if #classOrder == 0 then return nil, nil end
    local entry = classCatalog[classOrder[math.random(1, #classOrder)]]
    if entry == nil or not isValid(entry.classObject) then return nil, nil end
    return entry.classObject, entry.classKey
end

local function queueExtra(origin, slot)
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
    local angle = math.random() * math.pi * 2.0
    local radius = math.sqrt(math.random()) * CONFIG.SPAWN_RADIUS
    local position = {
        X = origin.location.X + math.cos(angle) * radius,
        Y = origin.location.Y + math.sin(angle) * radius,
        Z = origin.location.Z + SPAWN_Z_OFFSET_CM,
    }
    spawnQueue[#spawnQueue + 1] = {
        generation = generation,
        originKey = origin.key,
        slot = slot,
        classObject = classObject,
        classKey = classKey,
        level = origin.level,
        position = position,
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
            local ticket = pendingSpawns[index]
            if ticket.originKey == origin.key and ticket.slot > desired then
                discardSpawns[#discardSpawns + 1] = table.remove(pendingSpawns, index)
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
    if classCatalog[classKey] ~= nil then return end
    classCatalog[classKey] = { classObject = classObject, classKey = classKey }
    classOrder[#classOrder + 1] = classKey
    dbg("CLASS DISCOVERED | " .. classKey)
end

local function matchTicket(tickets, classKey, location)
    local maximumSquared = SPAWN_MATCH_DISTANCE_CM * SPAWN_MATCH_DISTANCE_CM
    for index, ticket in ipairs(tickets) do
        if ticket.generation == generation
            and ticket.classKey == classKey
            and squaredDistance(ticket.position, location) <= maximumSquared then
            table.remove(tickets, index)
            return ticket
        end
    end
    return nil
end

local function registerEnemy(enemy, reused, discardOnly)
    if not isValid(enemy) then return end
    local key = objectKey(enemy)
    if key == nil or key:find("Default__", 1, true) ~= nil then return end

    local previous = states[key]
    if previous ~= nil and not reused then return end
    if previous ~= nil then
        if previous.owned then
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
    local discardedTicket = matchTicket(discardSpawns, classKey, location)
    if discardedTicket ~= nil then
        local okDestroy, destroyError =
            pcall(function() enemy:K2_DestroyActor() end)
        if not okDestroy then
            log("DESTROY ERROR | retired spawn request | " .. tostring(destroyError))
        else
            dbg("SPAWN RETIRED | destroyed completed request for " .. classKey)
        end
        return
    end
    if discardOnly then return end
    local baseline, snapshotError = snapshotEnemy(enemy)
    if baseline == nil then
        log("ENEMY ERROR | " .. key .. " | " .. snapshotError)
        return
    end

    local ticket = matchTicket(pendingSpawns, classKey, location)
    if ticket ~= nil and activeExtraCount() >= CONFIG.MAX_ACTIVE_EXTRAS then
        local okDestroy, destroyError =
            pcall(function() enemy:K2_DestroyActor() end)
        if not okDestroy then
            log("DESTROY ERROR | unmatched cap overflow | " .. tostring(destroyError))
        else
            dbg("SPAWN CAP | destroyed completed request above the current cap")
        end
        return
    end
    local state = {
        key = key,
        object = enemy,
        classObject = classObject,
        classKey = classKey,
        baseline = baseline,
        owned = ticket ~= nil,
        originKey = ticket and ticket.originKey or nil,
        slot = ticket and ticket.slot or nil,
        applied = false,
    }
    states[key] = state

    if not state.owned and (CONFIG.INCLUDE_BOSSES or not baseline.isBoss) then
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
            }
        end
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

local function expireSpawnTickets()
    for index = #pendingSpawns, 1, -1 do
        local ticket = pendingSpawns[index]
        if ticket.generation ~= generation or elapsedMs >= ticket.expiresAtMs then
            if ticket.generation == generation then
                log(string.format(
                    "SPAWN ERROR | no enemy matched origin=%s slot=%d class=%s",
                    ticket.originKey,
                    ticket.slot,
                    ticket.classKey
                ))
            end
            table.remove(pendingSpawns, index)
        end
    end
    for index = #discardSpawns, 1, -1 do
        local ticket = discardSpawns[index]
        if ticket.generation ~= generation or elapsedMs >= ticket.expiresAtMs then
            if ticket.generation == generation then
                log(string.format(
                    "SPAWN RETIRE ERROR | no enemy matched origin=%s slot=%d class=%s",
                    ticket.originKey,
                    ticket.slot,
                    ticket.classKey
                ))
            end
            table.remove(discardSpawns, index)
        end
    end
end

local function processSpawnRequest()
    local request = table.remove(spawnQueue, 1)
    if request == nil or request.generation ~= generation then return end
    if not isValid(request.classObject) then
        log("SPAWN ERROR | requested UClass is no longer valid: " .. request.classKey)
        return
    end
    local okController, controller = pcall(FindFirstOf, "RODInGamePlayerController")
    if not okController or not isValid(controller) then
        log("SPAWN ERROR | RODInGamePlayerController is unavailable")
        return
    end
    local okSpawn, spawnError = pcall(function()
        controller:ServerDebugEnemySpawn(
            request.classObject,
            request.level,
            request.position
        )
    end)
    if not okSpawn then
        log("SPAWN ERROR | ServerDebugEnemySpawn failed: " .. tostring(spawnError))
        return
    end
    request.expiresAtMs = elapsedMs + SPAWN_TICKET_MS
    pendingSpawns[#pendingSpawns + 1] = request
    dbg(string.format(
        "SPAWN REQUEST | origin=%s slot=%d class=%s",
        request.originKey,
        request.slot,
        request.classKey
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
    if enemies ~= nil then
        for _, enemy in pairs(enemies) do
            objectQueue[#objectQueue + 1] = { object = enemy, reused = false }
        end
    end
    dbg("WORLD SCAN | queued " .. tostring(#objectQueue) .. " enemy object(s)")
    return true
end

local function disableWorld(reason)
    spawnQueue = {}
    for index = #pendingSpawns, 1, -1 do
        discardSpawns[#discardSpawns + 1] = table.remove(pendingSpawns, index)
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
        "CONFIG APPLIED | enabled=%s spawn=%dx cap=%d random=%s scale=%.2f-%.2f color=%s",
        tostring(CONFIG.ENABLED),
        CONFIG.SPAWN_MULTIPLIER,
        CONFIG.MAX_ACTIVE_EXTRAS,
        tostring(CONFIG.RANDOMIZE_EXTRA_SPECIES),
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

    local settings, digest, settingsError = loadSettings()
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
        expireSpawnTickets()
        if #discardSpawns > 0 then
            for _ = 1, MAX_DISCOVERY_PER_TICK do
                local queued = table.remove(objectQueue, 1)
                if queued == nil then break end
                registerEnemy(queued.object, queued.reused, true)
            end
        else
            objectQueue = {}
        end
        return
    end

    cleanupInvalidStates()
    expireSpawnTickets()
    if rescanRequested then
        rescanRequested = false
        if not requestWorldScan() then return end
    end

    for _ = 1, MAX_DISCOVERY_PER_TICK do
        local queued = table.remove(objectQueue, 1)
        if queued == nil then break end
        registerEnemy(queued.object, queued.reused, false)
    end
    if discoveryBatch and #objectQueue == 0 then
        discoveryBatch = false
        for _, origin in pairs(origins) do reconcileOrigin(origin) end
        enforceGlobalCap()
        dbg("WORLD SCAN | discovery batch completed")
    end
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
    if CONFIG ~= nil and (not configHealthy or not CONFIG.ENABLED)
        and #discardSpawns == 0 then return end
    if worldFault ~= nil then return end
    objectQueue[#objectQueue + 1] = { object = object, reused = reused }
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
    { "/Script/ROD.RODPlayerState:ServerDecideTown", "ServerDecideTown" },
    { "/Script/ROD.RODPlayerState:ServerDecideFastTravel", "ServerDecideFastTravel" },
    { "/Script/ROD.RODPlayerState:ServerShowQuestResult", "ServerShowQuestResult" },
}) do
    local hookPath = travelHook[1]
    local hookLabel = travelHook[2]
    requireHook(hookPath, function() beginTravel(hookLabel) end)
end

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
                "STATUS | healthy=%s enabled=%s paused=%s fault=%s natural=%d extras=%d queued=%d pending=%d retiring=%d classes=%d",
                tostring(configHealthy),
                tostring(CONFIG ~= nil and CONFIG.ENABLED),
                tostring(worldPaused),
                tostring(worldFault),
                natural,
                owned,
                #spawnQueue,
                #pendingSpawns,
                #discardSpawns,
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
