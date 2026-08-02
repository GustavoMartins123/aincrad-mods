local MOD_NAME = "WorldEnemyDirector"
local MOD_VERSION = "1.8.1"

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
-- Used by the ClientRestart-after-travel path. Left at 1500 because cross-world
-- travel gets a real
-- ClientRestart and the readiness-stability gate behind it, but it is the
-- shortest settle in the mod guarding the most expensive transition -- if
-- streaming crashes resurface after a map change rather than a fast travel,
-- this is the number to raise.
local RESTART_SETTLE_MS = 1500
-- FastTravelMod now activates and validates the destination cell before moving
-- the hero. Two seconds keeps the director out of the close/arrival lifecycle
-- without adding another five-second wait after the destination is already
-- locally ready.
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
-- Requests allowed to expire unmatched, in a row, before multiplication is
-- declared non-functional for this session.
-- How often origins near the hero are revisited when nothing was freed.
local ORIGIN_SWEEP_MS = 3000
-- Blueprint/AI initialization can change a capsule after the initial spawn
-- check. Re-validate every owned actor after activation so an actor cannot stay
-- in the world after losing its physical Pawn collision.
local COLLISION_AUDIT_MS = 500
-- Distance bands are re-scanned faster than the audit runs because a sprinting
-- player crosses a band edge quickly. The scan is native and reports only
-- changes, so a short interval costs almost nothing when nothing moved bands.
local BAND_SCAN_MS = 250
local OWNED_ADMISSION_SAMPLES_REQUIRED = 3
local OWNED_ADMISSION_TIMEOUT_MS = 4000
local NAV_ATTEMPTS_PER_PASS = 1
local NAV_MAX_ATTEMPTS = 12
local NAV_MIN_SEPARATION_CM = 150.0
local MAX_DISCOVERY_PER_TICK = 2
-- Caps how long the admission-audit loop may spend per 500 ms collision-audit
-- cycle. A spawn burst otherwise runs comparePhysical/controlOperational/
-- nativeRegistryMembership for every not-yet-admitted enemy synchronously in
-- one pass on the game thread. This spreads that cost across additional
-- cycles instead of stalling one frame for the whole burst; a deferred enemy
-- is simply checked on the next 500 ms cycle. Admission itself is unaffected:
-- the 3-sample stability requirement and admissionDeadlineMs are wall-clock
-- based, not cycle-count based, so nothing is skipped, only delayed slightly.
local AUDIT_BUDGET_SEC = 0.003
-- 32 attempts, 250 ms apart: eight seconds of grace for a streaming enemy to
-- finish initialising before it is reported as broken.
local SNAPSHOT_RETRY_LIMIT = 32
local SNAPSHOT_RETRY_BACKOFF_MS = 250
local GAMEPLAY_MOD_ADDITIVE = 0
local SPAWN_COLLISION_ADJUST_OR_REJECT = 3
local SPAWN_SCALE_MULTIPLY_ROOT = 1
local GAS_VALUE_EPSILON = 0.01
local ENEMY_ROLE_NONE = 0
local ENEMY_ROLE_MOB = 1
local ENEMY_ROLE_ELITE = 2
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
    COMMON_HEALTH_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    COMMON_ATTACK_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    COMMON_DEFENCE_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    COMMON_MOVE_SPEED_MULTIPLIER =
        { kind = "number", minimum = 0.25, maximum = 3.0 },
    COMMON_XP_MULTIPLIER =
        { kind = "number", minimum = 0.0, maximum = 10.0 },
    ELITE_HEALTH_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    ELITE_ATTACK_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    ELITE_DEFENCE_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    ELITE_MOVE_SPEED_MULTIPLIER =
        { kind = "number", minimum = 0.25, maximum = 3.0 },
    ELITE_XP_MULTIPLIER =
        { kind = "number", minimum = 0.0, maximum = 10.0 },
    BOSS_HEALTH_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    BOSS_ATTACK_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    BOSS_DEFENCE_MULTIPLIER =
        { kind = "number", minimum = 0.10, maximum = 10.0 },
    BOSS_MOVE_SPEED_MULTIPLIER =
        { kind = "number", minimum = 0.25, maximum = 3.0 },
    BOSS_XP_MULTIPLIER =
        { kind = "number", minimum = 0.0, maximum = 10.0 },
    POLL_MS = { kind = "number", minimum = 100, maximum = 2000, integer = true },
    DESPAWN_RADIUS = { kind = "number", minimum = 1500.0, maximum = 30000.0 },
    COMBAT_RADIUS = { kind = "number", minimum = 1000.0, maximum = 30000.0 },
    LOD_ENABLED = { kind = "boolean" },
    LOD_DORMANT_TICK_S = { kind = "number", minimum = 0.0, maximum = 5.0 },
    LOD_HYSTERESIS_CM = { kind = "number", minimum = 0.0, maximum = 5000.0 },
    SPAWN_IN_EMPTY_AREAS = { kind = "boolean" },
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

-- Death belongs to the game, not to this mod.
--
-- ARODEnemyCharacter owns a whole death sequence: TriggerDeath, the dismember
-- and gauge work, SetCollisonEnableCpp(false, Dead), OnEnemyDeadDelegate,
-- OnEnemyConfirmedDeathDelegate, then EnemyDestroyCheck and the despawn
-- delegate on the game's own schedule. Any owned extra that dies must run all
-- of it exactly like a natural enemy, so it is retired from the contract
-- regime rather than destroyed: the audit stops sampling it and nothing here
-- calls K2_DestroyActor on it again. The corpse leaves `states` when the game
-- finally destroys the actor and cleanupInvalidStates notices.
local function enemyIsDead(enemy)
    if not isValid(enemy) then return nil end
    local ok, dead, healthZero = pcall(function()
        return enemy:IsDead(), enemy:IsHealthZero()
    end)
    if not ok then return nil end
    return dead == true or healthZero == true
end

local function objectKey(object)
    if not isValid(object) then return nil end
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

-- An owned enemy is admitted only if its physical shape matches a naturally
-- initialized enemy of the exact same generated class. Nothing is repaired or
-- copied into the spawned actor: a mismatch is an explicit rejection.
local enemyContracts = {}
do
    -- Every runtime collision channel except the deprecated sentinel. A profile
    -- name is only a preset label: Unreal changes it to "Custom" as soon as one
    -- response is authored directly. The effective response container is the
    -- canonical contract.
    local PHYSICAL_COLLISION_FIELDS = {
        "WorldStatic",
        "WorldDynamic",
        "Pawn",
        "Visibility",
        "Camera",
        "PhysicsBody",
        "Vehicle",
        "Destructible",
    }
    for channel = 1, 6 do
        PHYSICAL_COLLISION_FIELDS[#PHYSICAL_COLLISION_FIELDS + 1] =
            "EngineTraceChannel" .. tostring(channel)
    end
    for channel = 1, 18 do
        PHYSICAL_COLLISION_FIELDS[#PHYSICAL_COLLISION_FIELDS + 1] =
            "GameTraceChannel" .. tostring(channel)
    end
    local SIZE_TOLERANCE_CM = 0.1
    local aiControllerBaseClass = nil

    local function capsuleSnapshot(
        component, label, requirePawnBody, expectedOwnerKey
    )
        if not isValid(component) then
            error(label .. " is unavailable")
        end
        local owner = component:GetOwner()
        if not isValid(owner) or objectKey(owner) ~= expectedOwnerKey then
            error(label .. " is not owned by this enemy")
        end
        local profile = component:GetCollisionProfileName():ToString()
        local enabled = tonumber(component:GetCollisionEnabled())
        local objectType = tonumber(component:GetCollisionObjectType())
        local radius = tonumber(component:GetScaledCapsuleRadius())
        local halfHeight = tonumber(component:GetScaledCapsuleHalfHeight())
        local active = component:IsActive()
        local collisionEnabled = component:K2_IsCollisionEnabled()
        local queryEnabled = component:K2_IsQueryCollisionEnabled()
        local physicsEnabled = component:K2_IsPhysicsCollisionEnabled()
        local generateOverlapEvents = component:GetGenerateOverlapEvents()
        if type(profile) ~= "string" or profile == "" then
            error(label .. " collision profile is unavailable")
        end
        if not finiteNumber(enabled)
            or not finiteNumber(objectType)
            or not finiteNumber(radius)
            or not finiteNumber(halfHeight)
            or radius <= 0.0
            or halfHeight <= 0.0 then
            error(label .. " collision geometry is invalid")
        end
        if type(active) ~= "boolean"
            or type(collisionEnabled) ~= "boolean"
            or type(queryEnabled) ~= "boolean"
            or type(physicsEnabled) ~= "boolean"
            or type(generateOverlapEvents) ~= "boolean" then
            error(label .. " reflected collision state is unreadable")
        end
        local responses = {}
        local responseContainer =
            component.BodyInstance.CollisionResponses.ResponseToChannels
        if responseContainer == nil then
            error(label .. " collision response container is unavailable")
        end
        for _, field in ipairs(PHYSICAL_COLLISION_FIELDS) do
            local response = tonumber(responseContainer[field])
            if response ~= 0 and response ~= 1 and response ~= 2 then
                error(label .. " channel " .. field ..
                    " response is invalid")
            end
            responses[field] = response
        end
        if requirePawnBody then
            if enabled ~= 1 and enabled ~= 3 and enabled ~= 5 then
                error(label .. " has no query collision: " ..
                    tostring(enabled))
            end
            if collisionEnabled ~= true or queryEnabled ~= true then
                error(label .. " query collision is not operational")
            end
            if objectType ~= 2 then
                error(label .. " object type is not Pawn: " ..
                    tostring(objectType))
            end
            if responses.Pawn ~= 2 then
                error(label .. " does not block Pawn: " ..
                    tostring(responses.Pawn))
            end
        end

        -- Collision profiles and responses live in FBodyInstance and remain
        -- readable even when the component has no shape registered in Chaos.
        -- GetClosestPointOnCollision is the reflected operational test: Unreal
        -- returns a negative distance when no collision body is available.
        local bodyAvailable = false
        if collisionEnabled then
            local center = vector(component:K2_GetComponentLocation())
            if center == nil then
                error(label .. " component location is invalid")
            end
            local closestPoint = { X = 0.0, Y = 0.0, Z = 0.0 }
            local bodyDistance = tonumber(component:GetClosestPointOnCollision(
                center,
                closestPoint,
                FName("None")
            ))
            if not finiteNumber(bodyDistance) or bodyDistance < 0.0 then
                error(label .. " has no registered physics collision body")
            end
            bodyAvailable = true
        end
        return {
            profile = profile,
            enabled = enabled,
            objectType = objectType,
            radius = radius,
            halfHeight = halfHeight,
            responses = responses,
            active = active,
            collisionEnabled = collisionEnabled,
            queryEnabled = queryEnabled,
            physicsEnabled = physicsEnabled,
            generateOverlapEvents = generateOverlapEvents,
            bodyAvailable = bodyAvailable,
        }
    end

    -- Every difference is reported rather than the first one found. A rejection
    -- costs a whole play session to observe, and stopping at the first mismatch
    -- hides the rest of them behind it one run at a time.
    local function compareCapsule(actual, expected, label, compareEnabled)
        local differences = {}
        local function note(field, expectedValue, actualValue)
            differences[#differences + 1] = label .. " " .. field ..
                " changed from " .. tostring(expectedValue) .. " to " ..
                tostring(actualValue)
        end
        if compareEnabled and actual.enabled ~= expected.enabled then
            note("collision mode", expected.enabled, actual.enabled)
        end
        if actual.objectType ~= expected.objectType then
            note("object type", expected.objectType, actual.objectType)
        end
        if compareEnabled then
            -- IsActive controls component activation/ticking; it is not a
            -- collision predicate. The query mode, collision responses, and
            -- registered Chaos body below are the physical contract.
            for _, field in ipairs({
                "collisionEnabled",
                "queryEnabled",
                "physicsEnabled",
                "generateOverlapEvents",
                "bodyAvailable",
            }) do
                if actual[field] ~= expected[field] then
                    note(field, expected[field], actual[field])
                end
            end
        end
        if math.abs(actual.radius - expected.radius) > SIZE_TOLERANCE_CM
            or math.abs(actual.halfHeight - expected.halfHeight)
                > SIZE_TOLERANCE_CM then
            differences[#differences + 1] = string.format(
                "%s geometry changed from %.1fx%.1f to %.1fx%.1f",
                label,
                expected.radius,
                expected.halfHeight,
                actual.radius,
                actual.halfHeight)
        end
        -- Channel responses are compared on every capsule, including the extra
        -- per-body-part hitboxes.
        --
        -- These were briefly excluded on the theory that the game re-profiles
        -- them at runtime and the mismatch was harmless. It is not harmless.
        -- The extras are what the player's attack traces hit, and one of the
        -- observed differences was an extra dropping a trace channel from
        -- Overlap to Ignore -- an enemy that is physically there but that
        -- attacks pass through. Excluding the comparison did not fix those
        -- enemies, it only stopped reporting them, and the director then kept
        -- producing more of them.
        for _, field in ipairs(PHYSICAL_COLLISION_FIELDS) do
            if actual.responses[field] ~= expected.responses[field] then
                note("channel " .. field .. " response",
                    expected.responses[field],
                    actual.responses[field])
            end
        end
        if #differences == 0 then return true, nil end
        return nil, table.concat(differences, "; ")
    end

    function enemyContracts.capturePhysical(enemy)
        if not isValid(enemy) then
            return nil, "enemy object is invalid"
        end
        local contract = nil
        local ok, captureError = pcall(function()
            local enemyKey = objectKey(enemy)
            if enemyKey == nil then
                error("enemy identity is unavailable")
            end
            if enemy:GetActorEnableCollision() ~= true then
                error("actor collision is disabled")
            end
            if enemy.bCanBeDamaged ~= true then
                error("actor damage reception is disabled")
            end

            local root = enemy.RootComponent
            local capsule = enemy.CapsuleComponent
            local multi = enemy.MultiCapsuleComponent
            local movement = enemy.EnemyMovementComponent
            local characterMovement = enemy.CharacterMovement
            if not isValid(root) or not isValid(capsule) then
                error("root capsule hierarchy is unavailable")
            end
            if objectKey(root) ~= objectKey(capsule) then
                error("CapsuleComponent is not the actor root")
            end
            if not isValid(multi) then
                error("MultiCapsuleComponent is unavailable")
            end
            if not isValid(movement)
                or objectKey(movement) ~= objectKey(characterMovement) then
                error("EnemyMovementComponent is not CharacterMovement")
            end
            if movement:IsActive() ~= true then
                error("EnemyMovementComponent is inactive")
            end
            if objectKey(movement.UpdatedComponent) ~= objectKey(capsule) then
                error("EnemyMovementComponent is not bound to the root capsule")
            end

            local multiIsRoot = objectKey(multi) == objectKey(capsule)
            local extras = multi.ExtraCapsuleComponents
            if extras == nil then
                error("ExtraCapsuleComponents is unavailable")
            end
            local extraContracts = {}
            for index = 1, #extras do
                extraContracts[index] = capsuleSnapshot(
                    extras[index],
                    "ExtraCapsuleComponents[" .. tostring(index) .. "]",
                    false,
                    enemyKey)
            end
            contract = {
                root = capsuleSnapshot(
                    capsule, "CapsuleComponent", true, enemyKey),
                multiIsRoot = multiIsRoot,
                multi = multiIsRoot and nil or capsuleSnapshot(
                    multi, "MultiCapsuleComponent", false, enemyKey),
                weldChildren = multi.bWeldChildColliders,
                extras = extraContracts,
            }
            if type(contract.weldChildren) ~= "boolean" then
                error("bWeldChildColliders is not boolean")
            end
        end)
        if not ok then return nil, tostring(captureError) end
        return contract, nil
    end

    function enemyContracts.comparePhysical(enemy, expected)
        if type(expected) ~= "table" then
            return nil, "same-class natural collision contract is unavailable"
        end
        local actual, captureError = enemyContracts.capturePhysical(enemy)
        if actual == nil then return nil, captureError end
        if actual.multiIsRoot ~= expected.multiIsRoot then
            return nil, "MultiCapsuleComponent/root identity changed"
        end
        if actual.weldChildren ~= expected.weldChildren then
            return nil, "bWeldChildColliders changed"
        end
        local rootMatches, rootError =
            compareCapsule(actual.root, expected.root, "CapsuleComponent", true)
        if rootMatches ~= true then return nil, rootError end
        if not actual.multiIsRoot then
            local multiMatches, multiError = compareCapsule(
                actual.multi,
                expected.multi,
                "MultiCapsuleComponent",
                false)
            if multiMatches ~= true then return nil, multiError end
        end
        if #actual.extras ~= #expected.extras then
            return nil, string.format(
                "ExtraCapsuleComponents count changed from %d to %d",
                #expected.extras,
                #actual.extras)
        end
        for index = 1, #actual.extras do
            local matches, compareError = compareCapsule(
                actual.extras[index],
                expected.extras[index],
                "ExtraCapsuleComponents[" .. tostring(index) .. "]",
                false)
            if matches ~= true then return nil, compareError end
        end
        local registeredBodies = actual.root.bodyAvailable and 1 or 0
        if not actual.multiIsRoot and actual.multi.bodyAvailable then
            registeredBodies = registeredBodies + 1
        end
        for _, extra in ipairs(actual.extras) do
            if extra.bodyAvailable then
                registeredBodies = registeredBodies + 1
            end
        end
        return true, string.format(
            "profile=%s referenceProfile=%s body=%.1fx%.1f "
                .. "extras=%d chaosBodies=%d",
            actual.root.profile,
            expected.root.profile,
            actual.root.radius,
            actual.root.halfHeight,
            #actual.extras,
            registeredBodies)
    end

    function enemyContracts.controlOperational(enemy)
        local operational, lifecycleError = enemyOperational(enemy)
        if not operational then return nil, lifecycleError end
        local detail = nil
        local ok, controlError = pcall(function()
            if enemy.bAbilitiesInitialized ~= true then
                error("enemy abilities are not initialized")
            end
            if enemy.DisableDetectFlag ~= false then
                error("enemy detection is disabled")
            end
            local controller = enemy:GetController()
            if not isValid(controller) then
                error("AI controller is unavailable")
            end
            if not isValid(aiControllerBaseClass) then
                aiControllerBaseClass =
                    StaticFindObject("/Script/ROD.RODAIControllerBase")
            end
            if not isValid(aiControllerBaseClass)
                or controller:IsA(aiControllerBaseClass) ~= true then
                error("controller is not RODAIControllerBase")
            end
            local pawn = controller:K2_GetPawn()
            if not isValid(pawn)
                or objectKey(pawn) ~= objectKey(enemy) then
                error("controller does not possess this enemy")
            end
            local brain = controller.BrainComponent
            if not isValid(brain) then
                error("controller BrainComponent is unavailable")
            end
            if brain:IsRunning() ~= true then
                error("behavior tree is not running")
            end
            if brain:IsPaused() == true then
                error("behavior tree is paused")
            end
            if not isValid(controller.PathFollowingComponent) then
                error("PathFollowingComponent is unavailable")
            end
            if not isValid(controller:GetAIPerceptionComponent()) then
                error("PerceptionComponent is unavailable")
            end
            if not isValid(controller.Blackboard) then
                error("Blackboard is unavailable")
            end
            detail = objectKey(controller)
        end)
        if not ok then return nil, tostring(controlError) end
        return true, detail
    end
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
local quarantinedActorKeys = {}
local discoveryBatch = false
local discoveryReadyAtMs = nil
local generation = 1
local worldPaused = true
local resumeAtMs = STARTUP_SETTLE_MS
local rescanRequested = false
local worldFault = nil
-- A world fault used to be permanent: one rejected spawn stopped multiplication
-- for the rest of the session, and the only way back was a world transition.
-- A single bad actor is not evidence that the next one is bad, so a fault now
-- stops the work, waits, and lets the director try again. Repeated faults back
-- off so a genuinely broken world reports itself instead of looping.
local WORLD_FAULT_RETRY_MS = 15000
local WORLD_FAULT_RETRY_CEILING_MS = 120000
local worldFaultRetryMs = WORLD_FAULT_RETRY_MS
local worldFaultResumeAtMs = nil
local awaitingTravelRestart = false

local function recordWorldFault(reason)
    spawnQueue = {}
    pendingSpawns = {}
    worldFault = reason
    worldFaultResumeAtMs = elapsedMs + worldFaultRetryMs
    log(string.format(
        "WORLD ERROR | %s | spawning paused, retrying in %ds",
        tostring(reason),
        math.floor(worldFaultRetryMs / 1000)))
end

local materialLibrary = nil
local materialInterface = nil
local navigationSystem = nil
local gameplayStatics = nil
local worldPartitionSubsystem = nil
local cachedHero = nil
local nativeContractReported = false
local nextOriginSweepMs = 0
local nextCollisionAuditMs = 0
local nextBandScanMs = 0
local bandScanFaultReported = false
local SPAWN_PACING_MS = 350
local lastSpawnMs = 0
local AMBIENT_CHECK_INTERVAL_MS = 4000
local AMBIENT_EMPTY_RADIUS_CM = 3500.0
local AMBIENT_SPAWN_MIN_DIST_CM = 1800.0
local AMBIENT_SPAWN_MAX_DIST_CM = 3200.0
local nextAmbientCheckMs = 0
local ambientCounter = 0
local NATIVE_SANITIZE_DELAY_MS = 2000
local nativeSanitizeRequested = false
local nativeSanitizeDueMs = 0
local nativeSanitizeReason = nil
local disableWorld
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
    quarantinedActorKeys = {}
    discoveryBatch = false
    discoveryReadyAtMs = nil
    worldFault = nil
    worldFaultResumeAtMs = nil
    worldFaultRetryMs = WORLD_FAULT_RETRY_MS
    navigationSystem = nil
    gameplayStatics = nil
    worldPartitionSubsystem = nil
    nativeContractReported = false
    cachedHero = nil
    nextOriginSweepMs = 0
    nextCollisionAuditMs = 0
    -- Band state lives on the states table, which is being dropped with the
    -- world; the native side re-classifies every surviving identity from
    -- scratch on the next scan.
    nextBandScanMs = 0
    lastSpawnMs = 0
    nextAmbientCheckMs = 0
    ambientCounter = 0
    nativeSanitizeRequested = false
    nativeSanitizeDueMs = 0
    nativeSanitizeReason = nil
end

local function requestNativeSanitize(reason)
    nativeSanitizeRequested = true
    nativeSanitizeDueMs = elapsedMs + NATIVE_SANITIZE_DELAY_MS
    nativeSanitizeReason = tostring(reason)
end

local function sanitizeNativeOwnedActors(reason)
    if type(WEDNativeReleaseOwnedWorld) ~= "function" then
        return 0, 0, 0,
            "WorldEnemyDirector native Async sanitizer is not loaded"
    end

    local callOk, released, detail, resolvedActors, clearedObjects, trackedActors =
        pcall(WEDNativeReleaseOwnedWorld)
    local resultValid = callOk
        and released == true
        and finiteNumber(resolvedActors) and resolvedActors >= 0
        and finiteNumber(clearedObjects) and clearedObjects >= 0
        and finiteNumber(trackedActors) and trackedActors >= 0
    if not resultValid then
        local failure = callOk and tostring(detail) or firstErrorLine(released)
        return 0, 0, 0,
            "native owned-actor sanitation failed: " .. failure
    end

    resolvedActors = math.floor(resolvedActors)
    clearedObjects = math.floor(clearedObjects)
    trackedActors = math.floor(trackedActors)
    nativeSanitizeRequested = false
    nativeSanitizeDueMs = 0
    nativeSanitizeReason = nil
    local sanitizeReport = string.format(
        "NATIVE ASYNC SANITIZE | %s | tracked=%d resolved=%d async-cleared=%d | %s",
        tostring(reason),
        trackedActors,
        resolvedActors,
        clearedObjects,
        tostring(detail)
    )
    if clearedObjects > 0 then log(sanitizeReport) else dbg(sanitizeReport) end
    return resolvedActors, clearedObjects, trackedActors, nil
end

local function beginTravel(reason)
    if awaitingTravelRestart and worldPaused and resumeAtMs == nil then
        -- Quest-end/travel emits more than one boundary callback. The first
        -- callback starts the quarantine, while later callbacks can still
        -- create Async-owned GameplayEffects during the native teardown.
        -- Keep the single poll chain armed for the latest callback instead of
        -- returning with only the pre-transition pass having run.
        requestNativeSanitize("continued transition: " .. tostring(reason))
        return
    end
    local nativeResolved, nativeCleared, nativeTracked, nativeError =
        sanitizeNativeOwnedActors(reason)
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
    -- Unreal may create the actor's GameplayEffect graph after the pre-hook
    -- pass, while the outgoing world is being torn down. The native bridge
    -- retains the weak identities, so this delayed pass can clear Async from
    -- that late-created graph without retaining Lua references to the world.
    requestNativeSanitize("post-transition: " .. tostring(reason))
    if nativeError ~= nil then releaseFailures = releaseFailures + 1 end
    if releaseFailures > 0 then
        log(string.format(
            "TRAVEL CLEANUP ERROR | %s | released=%d failed=%d | %s",
            reason,
            released,
            releaseFailures,
            tostring(nativeError or "Lua reference release failed")
        ))
    end
    log(string.format(
        "TRAVEL START | %s | Lua references released=%d | native tracked=%d resolved=%d async-cleared=%d",
        reason,
        released,
        nativeTracked,
        nativeResolved,
        nativeCleared
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
        requestNativeSanitize("post-ClientRestart after travel")
        log(string.format(
            "TRAVEL SETTLE | ClientRestart after travel | waiting %g seconds",
            RESTART_SETTLE_MS / 1000
        ))
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
    requestNativeSanitize("post-ClientRestart without travel")
end

local function beginSameWorldSettle(reason)
    if awaitingTravelRestart and worldPaused and resumeAtMs == nil then
        requestNativeSanitize("continued same-world transition: " .. tostring(reason))
        return
    end
    local nativeResolved, nativeCleared, nativeTracked, nativeError =
        sanitizeNativeOwnedActors(reason)
    worldPaused = true
    local requestedResumeAtMs = elapsedMs + QUEST_TELEPORT_SETTLE_MS
    if resumeAtMs == nil or resumeAtMs < requestedResumeAtMs then
        resumeAtMs = requestedResumeAtMs
    end
    requestNativeSanitize("post-same-world transition: " .. tostring(reason))
    if nativeError ~= nil then
        log("WORLD QUARANTINE ERROR | " .. tostring(reason) .. " | " ..
            tostring(nativeError))
    end
    log(string.format(
        "WORLD QUARANTINE | %s | native tracked=%d resolved=%d async-cleared=%d | retained same-world state and waiting %d seconds",
        tostring(reason),
        nativeTracked,
        nativeResolved,
        nativeCleared,
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

-- The local host controller is resolved fresh because it is replaced on travel.
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
    end

    if type(WEDNativeIdentifyOwnedEnemy) ~= "function"
        or type(WEDNativeTrackOwnedEnemy) ~= "function"
        or type(WEDNativeRegisterEnemy) ~= "function"
        or type(WEDNativeReleaseOwnedWorld) ~= "function" then
        return false,
            "WorldEnemyDirector native spawn and world teardown contract is not loaded"
    end

    if not nativeContractReported then
        nativeContractReported = true
        log("SPAWN CONTRACT | direct spawn, native registry injection and world teardown are available")
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
    local classObj, className = classData(enemy)
    local ok, mesh, meshScale, maxHealth, attack, defence, experience,
        movingSpeed, enemyRole =
        pcall(function()
            local enemyMesh = enemy.Mesh
            return enemyMesh,
                enemyMesh.RelativeScale3D,
                enemy.MaxHelth,
                enemy.AttackPower,
                enemy.DefencePower,
                enemy.ExperiencePoint,
                enemy.MovingSpeed,
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
    if not finiteNumber(enemyRole)
        or enemyRole % 1 ~= 0
        or enemyRole < ENEMY_ROLE_NONE
        or enemyRole > ENEMY_ROLE_BOSS then
        return nil, "EnemyRole is outside the reflected EEnemyRole contract"
    end
    local gas, gasError = snapshotGas(enemy, className)
    if gas == nil then return nil, gasError end

    -- SDK 1.0.3 defines the categories directly. Encounter flags and cinematic
    -- sequences are not used as substitute classification data.
    local tier = "common"
    if enemyRole == ENEMY_ROLE_ELITE then
        tier = "elite"
    elseif enemyRole == ENEMY_ROLE_BOSS then
        tier = "boss"
    elseif enemyRole ~= ENEMY_ROLE_NONE
        and enemyRole ~= ENEMY_ROLE_MOB then
        return nil, "EnemyRole has no canonical mutation category"
    end
    return {
        mesh = mesh,
        meshScale = parsedMeshScale,
        MaxHelth = maxHealth,
        AttackPower = attack,
        DefencePower = defence,
        ExperiencePoint = experience,
        MovingSpeed = movingSpeed,
        enemyRole = enemyRole,
        tier = tier,
        isBoss = tier == "boss",
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

local function mutationProfile(baseline)
    local prefix = nil
    if baseline.tier == "common" then
        prefix = "COMMON_"
    elseif baseline.tier == "elite" then
        prefix = "ELITE_"
    elseif baseline.tier == "boss" then
        prefix = "BOSS_"
    else
        return nil, "enemy has no canonical mutation tier"
    end
    return {
        health = CONFIG[prefix .. "HEALTH_MULTIPLIER"],
        attack = CONFIG[prefix .. "ATTACK_MULTIPLIER"],
        defence = CONFIG[prefix .. "DEFENCE_MULTIPLIER"],
        moveSpeed = CONFIG[prefix .. "MOVE_SPEED_MULTIPLIER"],
        xp = CONFIG[prefix .. "XP_MULTIPLIER"],
    }, nil
end

local function mutationIsIdentity(profile)
    return CONFIG.SCALE_MIN == 1.0
        and CONFIG.SCALE_MAX == 1.0
        and CONFIG.COLOR_MODE == "off"
        and profile.health == 1.0
        and profile.attack == 1.0
        and profile.defence == 1.0
        and profile.moveSpeed == 1.0
        and profile.xp == 1.0
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
    if state.owned and state.admitted ~= true then return false end
    local profile, profileError = mutationProfile(state.baseline)
    if profile == nil then
        log("MUTATION ERROR | " .. state.key .. " | " .. profileError)
        return false
    end
    if mutationIsIdentity(profile) then return restoreState(state) end
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
    local movingSpeed = base.MovingSpeed * profile.moveSpeed
    local actualGas

    local ok, mutationError = pcall(function()
        retargetGas(
            state,
            profile.health,
            profile.attack,
            profile.defence
        )
        if not isValid(base.mesh) then
            error("baseline skeletal mesh is unavailable")
        end
        base.mesh:SetRelativeScale3D(newScale)
        state.object.MaxHelth = roundedProduct(base.MaxHelth, profile.health)
        state.object.AttackPower = roundedProduct(base.AttackPower, profile.attack)
        state.object.DefencePower = roundedProduct(base.DefencePower, profile.defence)
        state.object.ExperiencePoint =
            roundedProduct(base.ExperiencePoint, profile.xp)
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
    if state.owned then
        requestNativeSanitize("owned mutation: " .. tostring(state.key))
    end
    dbg(string.format(
        "MUTATED | %s | tier=%s scale=%.2fx gas_hp=%.1f/%.1f gas_atk=%.1f gas_def=%.1f speed=%.2fx xp=%.2fx",
        state.key,
        state.baseline.tier,
        scaleFactor,
        actualGas.health,
        actualGas.maxHealth,
        actualGas.attack,
        actualGas.defence,
        profile.moveSpeed,
        profile.xp
    ))
    return true
end

-- Once direct creation has issued an actor, only the game may end its lifecycle.
-- Forcing EnemyReturnToPool from the director raced the render/physics threads,
-- deleted valid enemies, and produced a dangling RHI resource. Origin removal
-- therefore cancels only requests that have not created an actor yet.
local function removeOrigin(originKey)
    origins[originKey] = nil
    for index = #spawnQueue, 1, -1 do
        if spawnQueue[index].originKey == originKey then table.remove(spawnQueue, index) end
    end
end

local function activeExtraCount()
    local count = #spawnQueue
    for _, request in ipairs(pendingSpawns) do
        if request.quarantined ~= true then count = count + 1 end
    end
    for _, state in pairs(states) do
        -- A corpse waiting for the game to despawn it is no longer a live
        -- extra, so it does not hold a slot under the cap.
        if state.owned and isValid(state.object)
            and not state.retired and state.quarantined ~= true then
            count = count + 1
        end
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

    local active = activeExtraCount()
    if active > CONFIG.MAX_ACTIVE_EXTRAS then
        log(string.format(
            "SPAWN CAP | %d already-issued extra(s) retained above cap=%d; no new actors will be created",
            active,
            CONFIG.MAX_ACTIVE_EXTRAS
        ))
    end
end

local function activePendingSpawnCount()
    local count = 0
    for _, request in ipairs(pendingSpawns) do
        if request.quarantined ~= true then count = count + 1 end
    end
    return count
end

local function runRequestedNativeSanitize()
    if not nativeSanitizeRequested
        or elapsedMs < nativeSanitizeDueMs
        or activePendingSpawnCount() > 0
        or #spawnQueue > 0 then
        return true
    end
    local reason = nativeSanitizeReason or "owned spawn batch"
    local _, _, _, sanitizeError = sanitizeNativeOwnedActors(reason)
    if sanitizeError == nil then return true end
    nativeSanitizeRequested = false
    worldFault = sanitizeError
    log("WORLD ERROR | " .. worldFault .. " | director paused")
    return false
end

-- Spawn selection operates only on the currently valid catalog.
local function classEntryIsSpawnable(entry)
    return entry ~= nil
        and entry.spawnEligible == true
        and type(entry.physicalContract) == "table"
        and protectedBossClasses[entry.classKey] ~= true
        and isValid(entry.classObject)
end

local function selectSpawnClass(origin)
    if protectedBossClasses[origin.classKey] == true then
        return nil, nil, nil
    end
    if not CONFIG.RANDOMIZE_EXTRA_SPECIES then
        if origin.spawnEligible ~= true then return nil, nil, nil end
        return origin.classObject, origin.classKey, origin.physicalContract
    end

    -- Randomisation makes one selection from the currently valid domain.
    local eligible = {}
    for _, classKey in ipairs(classOrder) do
        local entry = classCatalog[classKey]
        if classEntryIsSpawnable(entry) then
            eligible[#eligible + 1] = entry
        end
    end
    if #eligible == 0 then return nil, nil, nil end
    local entry = eligible[math.random(1, #eligible)]
    return entry.classObject, entry.classKey, entry.physicalContract
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
    if origin.quarantined == true then return false end
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
    local heroLocation = resolveHeroLocation()
    if heroLocation == nil then return false end
    local activeRadiusSquared = CONFIG.DESPAWN_RADIUS * CONFIG.DESPAWN_RADIUS
    if planarDistanceSquared(origin.location, heroLocation)
        > activeRadiusSquared then
        return false
    end
    if activeExtraCount() >= CONFIG.MAX_ACTIVE_EXTRAS then
        dbg("SPAWN CAP | slot " .. slot .. " for " .. origin.key .. " was not issued")
        return false
    end

    local classObject, classKey, physicalContract = selectSpawnClass(origin)
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
        physicalContract = physicalContract,
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
    if origin.completed == true or origin.quarantined == true then
        return
    end
    local desired = CONFIG.SPAWN_MULTIPLIER - 1
    if origin.issued > desired then
        for index = #spawnQueue, 1, -1 do
            local request = spawnQueue[index]
            if request.originKey == origin.key and request.slot > desired then
                table.remove(spawnQueue, index)
            end
        end
        dbg(string.format(
            "SPAWN LAYOUT | origin=%s retains %d already-issued slot(s) after multiplier target changed to %d",
            origin.key,
            origin.issued,
            desired
        ))
    end
    if origin.issued >= desired then
        origin.completed = true
        return
    end
    -- Reserve at most one slot per origin per sweep. Reserving every slot at
    -- discovery let the first room consume the global cap with queued work
    -- before later-room origins were even seen.
    queueExtra(origin, origin.issued + 1)
    origin.completed = origin.issued >= desired
end

local function addClass(classObject, classKey, physicalContract)
    if protectedBossClasses[classKey] == true then return end
    if classCatalog[classKey] ~= nil then return end
    if type(physicalContract) ~= "table" then
        error("same-class natural collision contract is unavailable")
    end
    classCatalog[classKey] = {
        classObject = classObject,
        classKey = classKey,
        physicalContract = physicalContract,
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

-- Native registration returns a weak identity. The lifecycle callback is
-- claimed by the exact resolved address, never by class or proximity.
local function takePendingSpawn(enemy, actorKey)
    local addressOk, actorAddress = pcall(function() return enemy:GetAddress() end)
    if not addressOk or type(actorAddress) ~= "number" then return nil end
    for index, request in ipairs(pendingSpawns) do
        if request.generation == generation
            and request.actorAddress == actorAddress then
            table.remove(pendingSpawns, index)
            request.actorKey = actorKey
            request.object = enemy
            return request
        end
    end
    return nil
end

-- Snapshot failures that mean "not ready yet" rather than "broken". An enemy
-- streaming in during a world transition is visible before its mesh, its fields
-- and its GAS attribute set have finished initialising. Fast travel made this
-- common rather than rare: a whole cell's worth of enemies arrives at once, and
-- the log filled with "required GAS attribute is absent: MaxHealth" for enemies
-- that were perfectly fine a second later.
local TRANSIENT_SNAPSHOT_PREFIXES = {
    "required skeletal mesh is unavailable",
    "required enemy fields are unreadable",
    "required enemy AbilitySystem is unavailable",
    "required GAS attribute is absent",
    "GetAllAttributes failed",
}

local function snapshotErrorIsTransient(message)
    if type(message) ~= "string" then return false end
    for _, prefix in ipairs(TRANSIENT_SNAPSHOT_PREFIXES) do
        if message:find(prefix, 1, true) == 1 then return true end
    end
    return false
end

-- A spawned enemy is a gameplay enemy only after the game's own GameState has
-- accepted it. Physical collision and a running behaviour tree are not enough:
-- player targeting, the minimap and partner targeting consume these registries.
local function nativeRegistryMembership(enemy, key)
    if not isValid(enemy) then
        return false, false, "enemy object is invalid"
    end

    local ok, inEnemies, inGroup, enemiesCount, groupCount = pcall(function()
        local gameState = FindFirstOf("RODGameState")
        if not isValid(gameState) then error("RODGameState is unavailable") end

        local function contains(array)
            if array == nil then error("native registry array is unavailable") end
            for index = 1, #array do
                local entry = array[index]
                if isValid(entry) and objectKey(entry) == key then return true end
            end
            return false
        end

        local group = gameState.ManagerEnemyGroup
        if not isValid(group) then
            error("ManagerEnemyGroup is unavailable")
        end
        local enemies = gameState.RODEnemies
        local grouped = group.EnemyList
        return contains(enemies), contains(grouped), #enemies, #grouped
    end)
    if not ok then return false, false, firstErrorLine(inEnemies) end
    return inEnemies == true, inGroup == true, string.format(
        "RODEnemies=%s/%d EnemyList=%s/%d",
        tostring(inEnemies), enemiesCount, tostring(inGroup), groupCount)
end

local function registerEnemy(enemy, reused, queued)
    if not isValid(enemy) then return end

    -- Re-queued items carry a wall-clock gate. Without it the retry budget is
    -- spent within a few frames, which is far too fast for an ability system to
    -- finish coming up.
    if queued ~= nil and queued.retryAtMs ~= nil
        and elapsedMs < queued.retryAtMs then
        objectQueue[#objectQueue + 1] = queued
        return
    end

    local key = objectKey(enemy)
    if key == nil or key:find("Default__", 1, true) ~= nil then return end
    if quarantinedActorKeys[key] == true then
        return
    end
    local operational, lifecycleError = enemyOperational(enemy)
    if not operational then
        if lifecycleError ~= "enemy is dead"
            and lifecycleError ~= "enemy is not initialized" then
            log("ENEMY ERROR | " .. key .. " | " .. lifecycleError)
        end
        return
    end

    local request = (queued and queued.request) or takePendingSpawn(enemy, key)
    -- Ownership comes from the native weak-identity registry, which is the
    -- same record the spawn path wrote. Nothing is stored on the actor.
    local ownedOrphan = false
    local identifyOk, identified, identifyDetail, ownedFlag = pcall(function()
        return WEDNativeIdentifyOwnedEnemy(enemy:GetAddress())
    end)
    local ownedTag = nil
    if identifyOk and identified == true and (ownedFlag == 0 or ownedFlag == 1) then
        ownedTag = ownedFlag == 1
    end
    if ownedTag == nil then
        -- An unreadable identity is only a problem for an actor this mod just
        -- issued. For anything else it simply means "not ours", which is the
        -- safe reading, and the enemy is left entirely to the game.
        if request ~= nil then
            recordWorldFault(
                "issued actor has no readable native identity: " .. key ..
                " | " .. (identifyOk and tostring(identifyDetail)
                    or firstErrorLine(identified)))
        else
            dbg("ENEMY IDENTITY UNREADABLE | " .. key .. " | treated as not owned")
        end
        return
    end
    if request ~= nil and ownedTag ~= true then
        recordWorldFault("issued actor lost its native weak identity: " .. key)
        return
    end
    if request == nil and ownedTag == true then
        ownedOrphan = true
        dbg("ORPHAN EXTRA ADOPTED | " .. key ..
            " | ownership survived reference quarantine")
    end
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
                    physicalContract = previous.expectedPhysical,
                    actorKey = previous.key,
                    object = previous.object,
                }
            end
            states[key] = nil
        else
            removeOrigin(key)
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
        spawnQueue = {}
        pendingSpawns = {}
        worldFault = "created class " .. classKey ..
            " does not match requested class " .. request.classKey
        log("WORLD ERROR | " .. worldFault .. " | director paused")
        return
    end
    local baseline, snapshotError = snapshotEnemy(enemy)
    if baseline == nil then
        if queued ~= nil and snapshotErrorIsTransient(snapshotError) then
            local retryCount = (queued.retryCount or 0) + 1
            if retryCount <= SNAPSHOT_RETRY_LIMIT then
                queued.retryCount = retryCount
                queued.retryAtMs = elapsedMs + SNAPSHOT_RETRY_BACKOFF_MS
                queued.request = request
                objectQueue[#objectQueue + 1] = queued
                return
            end
            log("ENEMY ERROR | " .. key .. " | " .. snapshotError ..
                " | still absent after " .. SNAPSHOT_RETRY_LIMIT ..
                " retries over " ..
                (SNAPSHOT_RETRY_LIMIT * SNAPSHOT_RETRY_BACKOFF_MS) .. " ms")
            if request ~= nil then
                spawnQueue = {}
                pendingSpawns = {}
                worldFault = "issued actor never exposed its required enemy state: " .. key
                log("WORLD ERROR | " .. worldFault .. " | director paused")
            end
            return
        end
        log("ENEMY ERROR | " .. key .. " | " .. snapshotError)
        if request ~= nil then
            spawnQueue = {}
            pendingSpawns = {}
            worldFault = "issued actor rejected its required enemy state: " .. key
            log("WORLD ERROR | " .. worldFault .. " | director paused")
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

    local state = {
        key = key,
        object = enemy,
        classObject = classObject,
        classKey = classKey,
        baseline = baseline,
        owned = request ~= nil or ownedOrphan,
        originKey = request and request.originKey or nil,
        slot = request and request.slot or nil,
        spawnPosition = request and request.position or nil,
        expectedPhysical = request and request.physicalContract or nil,
        weakIndex = request and request.weakIndex or nil,
        weakSerial = request and request.weakSerial or nil,
        admitted = request == nil,
        retired = false,
        admissionStableSamples = 0,
        admissionDeadlineMs =
            request and (elapsedMs + OWNED_ADMISSION_TIMEOUT_MS) or nil,
        applied = false,
    }
    states[key] = state

    -- Direct extras bypass the game's finite EnemySpawnPool. Their own
    -- initialization event is the canonical point for starting their authored
    -- controller and behavior tree.
    if state.owned then
        if activateSpawnedEnemy(enemy, key, state.spawnPosition) ~= true then
            -- One actor that could not be activated is quarantined and left to
            -- the game, exactly like one that fails admission. It is never
            -- destroyed, never mutated, and does not hold a slot under the cap.
            -- Stopping the whole director for it meant a single bad actor
            -- ended multiplication for the session.
            state.quarantined = true
            if type(key) == "string" then quarantinedActorKeys[key] = true end
            log("SPAWN ACTIVATION QUARANTINED | " .. tostring(key) ..
                " | extra left to the game; director continues")
            return
        end
    end

    -- INCLUDE_BOSSES controls mutation only. Boss classes and boss actors are
    -- never admitted to either spawning structure, so a quest boss cannot be
    -- duplicated by same-species multiplication or by randomisation.
    if not state.owned
        and not baseline.isBoss
        and protectedBossClasses[classKey] ~= true then
        local physicalContract, physicalError =
            enemyContracts.capturePhysical(enemy)
        if physicalContract == nil then
            log("CLASS REJECTED | " .. classKey ..
                " | natural collision contract failed: " ..
                tostring(physicalError))
            return
        end
        addClass(classObject, classKey, physicalContract)
        local okLevel, level = pcall(function() return enemy:GetEnemyLevel() end)
        if not okLevel or not finiteNumber(level) then
            log("ENEMY ERROR | " .. key .. " | GetEnemyLevel failed")
        else
            origins[key] = {
                key = key,
                classObject = classObject,
                classKey = classKey,
                physicalContract = physicalContract,
                level = math.max(1, math.floor(level)),
                location = location,
                issued = 0,
                completed = false,
                spawnEligible = true,
            }
        end
    elseif not state.owned then
        dbg("BOSS PROTECTED | excluded from spawn catalog: " .. key)
    end

    if configHealthy and CONFIG.ENABLED
        and (not state.owned or state.admitted) then
        applyMutation(state)
    end
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
        elseif not state.owned and origins[key] ~= nil
            and enemyIsDead(state.object) == true then
            invalidNatural[#invalidNatural + 1] = key
        end
    end
    for _, key in ipairs(invalidNatural) do removeOrigin(key) end
end

local function expirePendingSpawns()
    for index = #pendingSpawns, 1, -1 do
        local request = pendingSpawns[index]
        if request.generation ~= generation or elapsedMs >= request.expiresAtMs then
            table.remove(pendingSpawns, index)
            if request.generation == generation then
                request.quarantined = true
                if type(request.actorKey) == "string" then
                    quarantinedActorKeys[request.actorKey] = true
                end
                local origin = origins[request.originKey]
                if origin ~= nil then
                    origin.quarantined = true
                    origin.completed = true
                end
                for queueIndex = #spawnQueue, 1, -1 do
                    if spawnQueue[queueIndex].originKey == request.originKey then
                        table.remove(spawnQueue, queueIndex)
                    end
                end
                requestNativeSanitize(
                    "lifecycle quarantine: " ..
                        tostring(request.actorKey or request.actorAddress))
                log(string.format(
                    "SPAWN LIFECYCLE QUARANTINED | %s | origin=%s | actor retained unmutated; only this origin was stopped",
                    tostring(request.actorKey or request.actorAddress),
                    tostring(request.originKey)))
            end
        end
    end
end

local function pauseForSpawnContractFailure(reason)
    disableWorld("spawn contract failure")
    worldFault = reason
    log("WORLD ERROR | " .. worldFault .. " | director paused")
end

activateSpawnedEnemy = function(enemy, key, spawnPosition)
    if not isValid(enemy) then return false end
    local state = states[key]
    if state == nil or type(state.expectedPhysical) ~= "table" then
        log("SPAWN ACTIVATION ERROR | " .. tostring(key) ..
            " | same-class natural collision contract is unavailable")
        return false
    end

    -- Hand collision setup back to the game before the enemy starts acting.
    --
    -- A deferred GameplayStatics spawn produces the components but never runs
    -- the enemy's own collision setup, which is why extras could arrive with
    -- their per-body-part hitboxes on the wrong channels -- physically present
    -- but with attacks passing through them. SetCollisonEnableCpp is the
    -- game's own entry point for exactly this, so the authored responses come
    -- from the game rather than being reconstructed here.
    --
    -- Best-effort on purpose: the admission contract is still the gate that
    -- decides whether the extra is acceptable, so a failure here is reported
    -- and left for that contract to catch rather than failing activation.
    local collisionOk, collisionError = pcall(function()
        enemy:SetCollisonEnableCpp(true, false)
    end)
    if not collisionOk then
        dbg("SPAWN COLLISION SETUP | " .. tostring(key) .. " | " ..
            firstErrorLine(collisionError))
    end

    local controller = nil
    local treeResult = nil
    local activated, activationError = pcall(function()
        if spawnPosition == nil then
            error("canonical spawn position is unavailable")
        end
        controller = enemy:GetController()
        if not isValid(controller) then error("AI controller is unavailable") end
        local pawn = controller:K2_GetPawn()
        if not isValid(pawn) or objectKey(pawn) ~= objectKey(enemy) then
            error("AI controller does not possess the spawned enemy")
        end

        enemy.ProwlFirstPosition = spawnPosition
        enemy.ProwlGoalPosition = spawnPosition
        enemy.ProwlGoalPositionFlag = false
        controller:StartAI(enemy)
        controller:ApplyBindFunction()
        enemy:StartAI(false)
        treeResult = enemy:StartBehaviorTree()
    end)
    if not activated then
        log("SPAWN ACTIVATION ERROR | " .. tostring(key) .. " | " ..
            firstErrorLine(activationError))
        return false
    end

    dbg(string.format(
        "SPAWN ACTIVATION | enemy=%s controller=%s tree=%s",
        tostring(key),
        tostring(objectKey(controller)),
        tostring(treeResult)
    ))
    return true
end

-- A deferred spawn produces the pawn and nothing else.
--
-- Possession is not the gap: AutoPossessAI is 3 (PlacedInWorldOrSpawned) on
-- these Blueprints, so the engine attaches an AIC_* controller by itself and
-- SpawnDefaultController was measured to be a no-op — the controller is already
-- there before and after. The enemy still stands inert, because having a
-- controller is not the same as having started.
--
-- The deferred spawn does not start the enemy's authored behavior. On
-- ARODEnemyCharacter that requires StartAI and StartBehaviorTree, and they are
-- called here after the enemy reports itself initialized rather than
-- straight after creation — an enemy whose assets are still resolving has
-- nothing for a behaviour tree to run yet.
-- Both contracts are reported when both fail. The physical one used to win and
-- the control one stayed invisible until the physical side was fixed, which
-- costs a session per hidden failure.
local function describeContractFailure(
    physical, physicalDetail, controlled, controlDetail
)
    local parts = {}
    if physical ~= true then
        parts[#parts + 1] = "physical contract: " .. tostring(physicalDetail)
    end
    if controlled ~= true then
        parts[#parts + 1] = "control contract: " .. tostring(controlDetail)
    end
    if #parts == 0 then return "contract state is unavailable" end
    return table.concat(parts, " | ")
end

local registryProbeReported = false

-- Read-only, once per session, on the first admitted extra.
--
-- ARODGameState carries the lists the game's own AI reads: RODEnemies, and
-- ManagerEnemyGroup.EnemyList, which URODAIEnemyGroup uses to hand out attack
-- slots (PartnerAttackEnemyTimesLimit, VisitorAttackEnemyTimesLimit,
-- EnemyTargetingDatas). An actor created through UGameplayStatics is a
-- well-formed enemy, but nothing adds it to those lists. The native bridge
-- registers the exact direct actor in both arrays before admission. If an
-- admitted extra is absent from them while natural enemies are present, that
-- is why a partner never engages it, and no collision channel or AI flag on
-- the actor itself can change that.
local function reportRegistryMembership(state)
    if registryProbeReported then return end
    registryProbeReported = true

    local function describeList(array, ownedKey)
        if array == nil then return "unavailable" end
        local size = #array
        local found = false
        for index = 1, size do
            local entry = array[index]
            if isValid(entry) and objectKey(entry) == ownedKey then
                found = true
                break
            end
        end
        return string.format("contains=%s entries=%d", tostring(found), size)
    end

    local ok, report = pcall(function()
        local gameState = FindFirstOf("RODGameState")
        if not isValid(gameState) then
            return "RODGameState is unavailable"
        end
        local group = gameState.ManagerEnemyGroup
        return "RODEnemies " ..
            describeList(gameState.RODEnemies, state.key) ..
            " | ManagerEnemyGroup.EnemyList " ..
            (isValid(group)
                and describeList(group.EnemyList, state.key)
                or "unavailable")
    end)
    log("SPAWN REGISTRY | " .. tostring(state.key) .. " | " ..
        (ok and tostring(report)
            or ("probe failed: " .. firstErrorLine(report))))
end

-- Candidates remain unmutated until their physical, AI, and registry contracts
-- pass three consecutive samples. Once admitted, the game's dynamic combat
-- state is authoritative and is not reinterpreted as a spawn-contract failure.
local function auditOwnedEnemyCollision()
    if elapsedMs < nextCollisionAuditMs then return end
    nextCollisionAuditMs = elapsedMs + COLLISION_AUDIT_MS

    -- The dead are retired before anything is compared. A killed extra fails
    -- both contracts by definition — the game turns its collision off and stops
    -- its behaviour tree as part of dying — and reading that as a contract loss
    -- is what made a killed extra pop out of existence on the next audit
    -- instead of falling, dropping loot and fading on the game's own schedule.
    for _, state in pairs(states) do
        if state.owned and not state.retired and isValid(state.object)
            and enemyIsDead(state.object) == true then
            state.retired = true
            dbg("EXTRA RETIRED | " .. tostring(state.key) ..
                " | killed; the game owns its death and despawn")
        end
    end

    local rejected = nil
    local auditStartTime = os.clock()
    for _, state in pairs(states) do
        if state.owned and isValid(state.object) and not state.retired
            and state.quarantined ~= true and state.admitted ~= true then
            local physical, physicalDetail =
                enemyContracts.comparePhysical(
                    state.object,
                    state.expectedPhysical)
            local controlled, controlDetail =
                enemyContracts.controlOperational(state.object)
            local inEnemies, inGroup, registryDetail =
                nativeRegistryMembership(state.object, state.key)
            local registered = inEnemies == true and inGroup == true
            if physical == true and controlled == true and registered then
                if state.admitted ~= true then
                    state.admissionStableSamples =
                        state.admissionStableSamples + 1
                    if state.admissionStableSamples
                        >= OWNED_ADMISSION_SAMPLES_REQUIRED then
                        state.admitted = true
                        -- A spawn that reached admission proves the pipeline
                        -- works, so the retry delay goes back to its floor.
                        worldFaultRetryMs = WORLD_FAULT_RETRY_MS
                        log("SPAWN ADMITTED | " .. tostring(state.key) ..
                            " | " .. tostring(physicalDetail) ..
                            " | controller=" .. tostring(controlDetail) ..
                            " | registry=" .. tostring(registryDetail))
                        reportRegistryMembership(state)
                        if configHealthy and CONFIG.ENABLED then
                            applyMutation(state)
                        end
                    end
                end
            elseif elapsedMs >= state.admissionDeadlineMs then
                local rejectionReason = describeContractFailure(
                    physical, physicalDetail, controlled, controlDetail)
                if not registered then
                    rejectionReason = rejectionReason ..
                        " | native registry: " .. tostring(registryDetail)
                end
                rejected = {
                    state = state,
                    reason = rejectionReason,
                }
            else
                state.admissionStableSamples = 0
                state.lastAdmissionError = describeContractFailure(
                    physical, physicalDetail, controlled, controlDetail)
                if not registered then
                    state.lastAdmissionError = state.lastAdmissionError ..
                        " | native registry: " .. tostring(registryDetail)
                end
            end
            if os.clock() - auditStartTime > AUDIT_BUDGET_SEC then break end
        end
    end

    -- One extra failing its contract says something about that extra, not about
    -- the world. It is quarantined and left entirely to the game -- never
    -- mutated, never destroyed -- and the director carries on with the rest.
    -- This used to stop multiplication for the whole session.
    if rejected ~= nil then
        local state = rejected.state
        state.quarantined = true
        state.admitted = false
        if type(state.key) == "string" then
            quarantinedActorKeys[state.key] = true
        end
        log("SPAWN ADMISSION REJECTED | " .. tostring(state.key) .. " | " ..
            tostring(rejected.reason) ..
            " | extra quarantined and left to the game; director continues")
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
local function streamingIsSettled()
    if not isValid(worldPartitionSubsystem) then
        worldPartitionSubsystem = nil
        local ok, subsystem = pcall(FindFirstOf, "WorldPartitionSubsystem")
        if not ok or not isValid(subsystem) then
            return nil, "WorldPartitionSubsystem is unavailable"
        end
        worldPartitionSubsystem = subsystem
    end

    local ok, completed = pcall(function()
        return worldPartitionSubsystem:IsAllStreamingCompleted()
    end)
    if not ok then
        return nil, "IsAllStreamingCompleted failed: " ..
            tostring(completed)
    end
    return completed == true, nil
end

local function processSpawnRequest()
    if elapsedMs < lastSpawnMs + SPAWN_PACING_MS then return end
    local request = table.remove(spawnQueue, 1)
    if request == nil or request.generation ~= generation then return end
    lastSpawnMs = elapsedMs
    local streamingSettled, streamingError = streamingIsSettled()
    if streamingSettled == nil then
        pauseForSpawnContractFailure(
            "world partition spawn gate failed: " ..
                tostring(streamingError))
        return
    end
    if not streamingSettled then
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

    local isAmbient = request.isAmbient == true
    local owner = nil
    if isAmbient then
        owner = resolveHeroObject()
        if not isValid(owner) then return end
    else
        local originState = states[request.originKey]
        if originState == nil or originState.owned or not isValid(originState.object) then
            log("SPAWN ERROR | natural origin is unavailable: " .. request.originKey)
            return
        end
        local ownerObj, ownerResolveError = resolveExactObject(request.originKey)
        if ownerObj == nil then
            pauseForSpawnContractFailure(
                "spawn owner resolution failed: " ..
                    firstErrorLine(ownerResolveError)
            )
            return
        end
        owner = ownerObj
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

    local transform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = request.position,
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local spawned = nil
    local insertedPending = false
    local spawnOk, spawnError = pcall(function()
        spawned = gameplayStatics:BeginDeferredActorSpawnFromClass(
            owner,
            spawnClass,
            transform,
            SPAWN_COLLISION_ADJUST_OR_REJECT,
            nil,
            SPAWN_SCALE_MULTIPLY_ROOT
        )
        if not isValid(spawned) then
            error("BeginDeferredActorSpawnFromClass returned no actor")
        end

        request.actorKey = objectKey(spawned)
        if request.actorKey == nil then
            error("created actor has no canonical object key")
        end
        request.actorAddress = spawned:GetAddress()
        if not finiteNumber(request.actorAddress) or request.actorAddress <= 0 then
            error("created actor has no canonical address")
        end

        local trackCallOk, tracked, trackDetail,
            trackedAddress, trackedWeakIndex, trackedWeakSerial =
            pcall(WEDNativeTrackOwnedEnemy, request.actorAddress)
        local trackedIdentityValid = trackCallOk
            and tracked == true
            and trackedAddress == request.actorAddress
            and finiteNumber(trackedWeakIndex) and trackedWeakIndex >= 0
            and finiteNumber(trackedWeakSerial) and trackedWeakSerial > 0
        if not trackedIdentityValid then
            error("native ownership tracking rejected the issued actor: " ..
                (trackCallOk and tostring(trackDetail)
                    or firstErrorLine(tracked)))
        end
        request.weakIndex = math.floor(trackedWeakIndex)
        request.weakSerial = math.floor(trackedWeakSerial)
        requestNativeSanitize(
            "issued actor batch: " .. tostring(request.actorKey))
        request.object = spawned
        request.expiresAtMs = elapsedMs + SPAWN_INITIALIZE_MS
        pendingSpawns[#pendingSpawns + 1] = request
        insertedPending = true

        -- Ownership is recorded natively, by weak identity, before the actor is
        -- finished. It used to be written onto the actor as an FName in its
        -- Tags array, but appending to a native TArray from Lua corrupts the
        -- array instead of appending to it, so the tag never read back and
        -- every spawn failed its own ownership check.
        local finished = gameplayStatics:FinishSpawningActor(
            spawned,
            transform,
            SPAWN_SCALE_MULTIPLY_ROOT
        )
        if not isValid(finished) then
            error("FinishSpawningActor returned no actor")
        end
        if objectKey(finished) ~= request.actorKey
            or finished:GetAddress() ~= request.actorAddress then
            error("FinishSpawningActor returned a different actor")
        end
        request.object = finished
        finished:SetEnemyLevel(request.level, false)

        local gameState = FindFirstOf("RODGameState")
        if not isValid(gameState) then
            error("RODGameState is unavailable for native registration")
        end
        local callOk, registered, detail, actorAddress, weakIndex, weakSerial =
            pcall(
                WEDNativeRegisterEnemy,
                gameState:GetAddress(),
                request.actorAddress
            )
        local identityValid = callOk
            and registered == true
            and actorAddress == request.actorAddress
            and weakIndex == request.weakIndex
            and weakSerial == request.weakSerial
        if not identityValid then
            error("native registry injection rejected the issued actor: " ..
                (callOk and tostring(detail) or firstErrorLine(registered)))
        end
    end)
    if not spawnOk then
        for index = #pendingSpawns, 1, -1 do
            if pendingSpawns[index] == request then
                table.remove(pendingSpawns, index)
                break
            end
        end
        pauseForSpawnContractFailure(
            "direct spawn contract failed: " .. summarizeSpawnCallError(spawnError) ..
            (isValid(spawned) and " | issued actor retained" or ""))
        return
    end
    dbg(string.format(
        "SPAWN CREATED DIRECT | origin=%s slot=%d class=%s address=%s weak=%d:%d",
        request.originKey,
        request.slot,
        request.classKey,
        tostring(request.actorAddress),
        request.weakIndex,
        request.weakSerial
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
    local issued = #pendingSpawns
    pendingSpawns = {}
    for _, state in pairs(states) do
        restoreState(state)
    end
    dbg(string.format(
        "DIRECTOR DISABLED | %s | retained %d already-issued actor request(s); game owns every live lifecycle",
        tostring(reason),
        issued
    ))
end

-- The outgoing world is about to be destroyed. Calling K2_DestroyActor here
-- races the game's asynchronous enemy teardown and can leave worker tasks with
-- a dangling actor. Native teardown has already removed the Async GC roots from
-- the exact issued actor graphs; this stage only counts the Lua references that
-- beginTravel is about to release. The world remains the authoritative owner of
-- actor destruction.
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
        "CONFIG APPLIED | enabled=%s spawn=%dx cap=%d random=%s "
            .. "bossMutation=%s bossSpawn=false scale=%.2f-%.2f color=%s "
            .. "| common H/A/D/S/XP=%.1f/%.1f/%.1f/%.2f/%.1f "
            .. "| elite=%.1f/%.1f/%.1f/%.2f/%.1f "
            .. "| boss=%.1f/%.1f/%.1f/%.2f/%.1f",
        tostring(CONFIG.ENABLED),
        CONFIG.SPAWN_MULTIPLIER,
        CONFIG.MAX_ACTIVE_EXTRAS,
        tostring(CONFIG.RANDOMIZE_EXTRA_SPECIES),
        tostring(CONFIG.INCLUDE_BOSSES),
        CONFIG.SCALE_MIN,
        CONFIG.SCALE_MAX,
        CONFIG.COLOR_MODE,
        CONFIG.COMMON_HEALTH_MULTIPLIER,
        CONFIG.COMMON_ATTACK_MULTIPLIER,
        CONFIG.COMMON_DEFENCE_MULTIPLIER,
        CONFIG.COMMON_MOVE_SPEED_MULTIPLIER,
        CONFIG.COMMON_XP_MULTIPLIER,
        CONFIG.ELITE_HEALTH_MULTIPLIER,
        CONFIG.ELITE_ATTACK_MULTIPLIER,
        CONFIG.ELITE_DEFENCE_MULTIPLIER,
        CONFIG.ELITE_MOVE_SPEED_MULTIPLIER,
        CONFIG.ELITE_XP_MULTIPLIER,
        CONFIG.BOSS_HEALTH_MULTIPLIER,
        CONFIG.BOSS_ATTACK_MULTIPLIER,
        CONFIG.BOSS_DEFENCE_MULTIPLIER,
        CONFIG.BOSS_MOVE_SPEED_MULTIPLIER,
        CONFIG.BOSS_XP_MULTIPLIER
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

-- Persistent origins that were outside the configured radius remain pending.
-- The sweep may issue them after the player approaches, but it never revokes a
-- live actor: death, despawn, pooling, and world teardown belong to the game.
local function reconcileNearbyOrigins()
    local heroLocation = resolveHeroLocation()
    if heroLocation == nil then return end

    local limitSquared = CONFIG.DESPAWN_RADIUS * CONFIG.DESPAWN_RADIUS
    local resetSlots = {}
    for index = #spawnQueue, 1, -1 do
        local request = spawnQueue[index]
        local origin = origins[request.originKey]
        local outOfRange = origin == nil or origin.location == nil
            or planarDistanceSquared(origin.location, heroLocation) > limitSquared
        if outOfRange then
            table.remove(spawnQueue, index)
            if origin ~= nil then
                if origin.isAmbient then
                    origins[request.originKey] = nil
                else
                    local current = resetSlots[request.originKey]
                    if current == nil or request.slot < current then
                        resetSlots[request.originKey] = request.slot
                    end
                end
            end
        end
    end
    for originKey, firstRemovedSlot in pairs(resetSlots) do
        local origin = origins[originKey]
        if origin ~= nil and origin.quarantined ~= true then
            origin.issued = math.min(origin.issued, firstRemovedSlot - 1)
            origin.completed = false
            dbg(string.format(
                "SPAWN QUEUE RELEASED | origin=%s reset to issued=%d after leaving active radius",
                originKey,
                origin.issued))
        end
    end

    for _, origin in pairs(origins) do
        -- reconcileOrigin's own first act is to return on a completed origin,
        -- so testing it here first keeps the sweep from measuring a distance
        -- for every origin in the world only to discard the answer. At a large
        -- despawn radius that is most of them.
        if origin.completed ~= true
            and origin.location ~= nil
            and planarDistanceSquared(origin.location, heroLocation) <= limitSquared then
            reconcileOrigin(origin)
        end
    end
end

-- Distance banding.
--
-- An enemy that is far away still costs an AI controller, a running behaviour
-- tree, perception, movement and a full ability system. Unreal's visual culling
-- removes none of that, so a multiplied population keeps paying for every extra
-- it has ever created no matter where the player is. This puts distant extras
-- to sleep and wakes them when the player returns.
--
-- The scan itself is native: reading a position through reflection costs one
-- Lua boundary crossing per enemy, and the native side reads it directly and
-- reports only the extras whose band actually changed. In steady state there
-- are no transitions and this costs a single call.
--
-- Everything here is best-effort by design. Banding is an optimisation, not a
-- correctness contract, so a failure downgrades that one enemy to full
-- simulation and is never allowed to set worldFault: a performance feature must
-- not be able to stop enemy multiplication.
local enemyLod = {}
do
local ZONE_ACTIVE = 1
local ZONE_DORMANT = 2

-- There is no release tier yet: everything past the combat radius is simply
-- asleep, and the scan's outer edge has nothing to separate. Passing an edge
-- no actor can reach keeps the band ordered for the native contract without
-- borrowing DESPAWN_RADIUS, which means something else entirely -- it gates
-- which spawns are issued. Coupling the two would let a saved menu value for
-- one silently change the other.
local BAND_NO_RELEASE_CM = 1.0e9

local function lodAvailable()
    return CONFIG ~= nil
        and CONFIG.LOD_ENABLED
        and type(WEDNativeScanOwnedEnemies) == "function"
        and type(WEDNativeNextZoneTransition) == "function"
end

-- An extra is only ever put to sleep when every one of these says it is safe.
-- Each unreadable answer counts as "not safe": the enemy stays fully simulated.
local function extraMaySleep(state)
    if state.admitted ~= true or state.retired then return false end
    local enemy = state.object
    if not isValid(enemy) then return false end
    if enemyIsDead(enemy) ~= false then return false end

    local targetOk, target = pcall(function() return enemy.TargetHeroCharacter end)
    if not targetOk or isValid(target) then return false end

    local renderedOk, rendered = pcall(function()
        return enemy:WasRecentlyRendered(0.5)
    end)
    if not renderedOk or rendered ~= false then return false end

    return true
end

local function enemyBrainComponent(enemy)
    local ok, brain = pcall(function()
        local controller = enemy:GetController()
        if not isValid(controller) then return nil end
        return controller.BrainComponent
    end)
    if not ok or not isValid(brain) then return nil end
    return brain
end

-- The movement component is slowed rather than switched off. A disabled
-- movement tick can leave a character parked in whatever mid-air state it was
-- in, and the saving from the interval is nearly the same.
local function applyTickInterval(state, interval)
    local enemy = state.object
    if state.lodOriginalTickInterval == nil then
        local ok, original = pcall(function() return enemy:GetActorTickInterval() end)
        state.lodOriginalTickInterval = (ok and finiteNumber(original)) and original or 0.0
    end
    pcall(function() enemy:SetActorTickInterval(interval) end)
    pcall(function()
        local movement = enemy.EnemyMovementComponent
        if isValid(movement) then movement:SetComponentTickInterval(interval) end
    end)
end

local function sleepExtra(state)
    local brain = enemyBrainComponent(state.object)
    if brain == nil then return false, "behaviour tree is unreachable" end
    local stopped = pcall(function()
        brain:StopLogic("WorldEnemyDirector distance band")
    end)
    if not stopped then return false, "StopLogic was rejected" end
    applyTickInterval(state, CONFIG.LOD_DORMANT_TICK_S)
    state.lodZone = ZONE_DORMANT
    return true, nil
end

local function wakeExtra(state)
    local restored = true
    local brain = enemyBrainComponent(state.object)
    if brain ~= nil then
        restored = pcall(function() brain:RestartLogic() end)
    else
        restored = false
    end
    applyTickInterval(state, state.lodOriginalTickInterval or 0.0)
    state.lodZone = ZONE_ACTIVE
    if not restored then return false, "RestartLogic was rejected" end
    return true, nil
end

-- A woken enemy whose behaviour tree refused to restart would stand inert and
-- read as a broken extra, so that single failure is reported loudly even though
-- it never pauses the director.
local function applyZoneTransition(state, newZone)
    -- Anything past the sleep band is also asleep. The furthest band exists so
    -- that releasing the actor entirely can be added later; until then the
    -- correct treatment for "even further away" is emphatically not to wake it.
    if newZone ~= ZONE_ACTIVE then
        if state.lodZone == ZONE_DORMANT then return end
        if not extraMaySleep(state) then return end
        local ok, reason = sleepExtra(state)
        if ok then
            dbg("LOD SLEEP | " .. tostring(state.key))
        else
            state.lodUnavailable = true
            dbg("LOD SKIPPED | " .. tostring(state.key) .. " | " .. tostring(reason))
        end
        return
    end

    if state.lodZone ~= ZONE_DORMANT then
        state.lodZone = ZONE_ACTIVE
        return
    end
    local ok, reason = wakeExtra(state)
    if ok then
        dbg("LOD WAKE | " .. tostring(state.key))
    else
        state.lodUnavailable = true
        log("LOD WAKE FAILED | " .. tostring(state.key) .. " | " ..
            tostring(reason) .. " | extra may stand inert until it is re-engaged")
    end
end

function enemyLod.update()
    if not lodAvailable() then return end
    if worldPaused or worldFault ~= nil then return end
    if elapsedMs < nextBandScanMs then return end
    nextBandScanMs = elapsedMs + BAND_SCAN_MS

    local heroLocation = resolveHeroLocation()
    if heroLocation == nil then return end

    local scanOk, scanned, detail, transitionCount = pcall(
        WEDNativeScanOwnedEnemies,
        heroLocation.X,
        heroLocation.Y,
        CONFIG.COMBAT_RADIUS,
        BAND_NO_RELEASE_CM,
        CONFIG.LOD_HYSTERESIS_CM)
    if not scanOk or scanned ~= true then
        if not bandScanFaultReported then
            bandScanFaultReported = true
            log("LOD UNAVAILABLE | native band scan failed: " ..
                (scanOk and tostring(detail) or firstErrorLine(scanned)) ..
                " | extras stay fully simulated")
        end
        return
    end
    if not finiteNumber(transitionCount) or transitionCount <= 0 then return end

    -- Only built when something actually changed band, which is the whole
    -- reason the native side reports transitions instead of positions.
    local byAddress = {}
    for _, state in pairs(states) do
        if state.owned and isValid(state.object) then
            local ok, address = pcall(function() return state.object:GetAddress() end)
            if ok and address ~= nil then byAddress[address] = state end
        end
    end

    for _ = 1, transitionCount do
        local ok, popped, _, address, newZone = pcall(WEDNativeNextZoneTransition)
        if not ok or popped ~= true or not finiteNumber(address) or address == 0 then
            break
        end
        local state = byAddress[address]
        if state ~= nil then applyZoneTransition(state, newZone) end
    end
end
end

local function checkAmbientEmptyAreaSpawns()
    if CONFIG == nil or not CONFIG.ENABLED or not CONFIG.SPAWN_IN_EMPTY_AREAS then return end
    if worldPaused or worldFault ~= nil then return end
    if elapsedMs < nextAmbientCheckMs then return end
    nextAmbientCheckMs = elapsedMs + AMBIENT_CHECK_INTERVAL_MS

    if #classOrder == 0 then return end
    if activeExtraCount() >= CONFIG.MAX_ACTIVE_EXTRAS then return end

    local hero = resolveHeroObject()
    if not isValid(hero) then return end
    local heroPos, posError = actorLocation(hero)
    if heroPos == nil then return end

    -- Only "is there at least one enemy nearby" is ever consulted below, so
    -- this stops at the first match instead of pricing a full reflected
    -- location read against every tracked state on every 4-second check. The
    -- common case (a populated area) now resolves in a handful of reads
    -- instead of the whole roster; only a genuinely empty area still pays
    -- for the full scan, which is the case that needs an accurate answer.
    local nearbyEnemies = 0
    local emptyRadSq = AMBIENT_EMPTY_RADIUS_CM * AMBIENT_EMPTY_RADIUS_CM
    for _, state in pairs(states) do
        if isValid(state.object) then
            local enemyPos = actorLocation(state.object)
            if enemyPos ~= nil and planarDistanceSquared(heroPos, enemyPos) <= emptyRadSq then
                nearbyEnemies = 1
                break
            end
        end
    end

    if nearbyEnemies > 0 then return end

    -- The catalog is filtered through the same predicate every other spawn
    -- path uses. Drawing straight out of classOrder only checked that the
    -- class object was valid, so this path could issue a class whose natural
    -- collision contract was never captured -- which then failed activation
    -- with "same-class natural collision contract is unavailable" -- and could
    -- equally have spawned a boss-protected class that every other path
    -- refuses.
    local eligible = {}
    for _, classKey in ipairs(classOrder) do
        local entry = classCatalog[classKey]
        if classEntryIsSpawnable(entry) then eligible[#eligible + 1] = entry end
    end
    if #eligible == 0 then return end
    local classInfo = eligible[math.random(1, #eligible)]
    local chosenClassKey = classInfo.classKey

    local angle = math.random() * math.pi * 2.0
    local dist = AMBIENT_SPAWN_MIN_DIST_CM + math.random() * (AMBIENT_SPAWN_MAX_DIST_CM - AMBIENT_SPAWN_MIN_DIST_CM)
    local rawTarget = {
        X = heroPos.X + math.cos(angle) * dist,
        Y = heroPos.Y + math.sin(angle) * dist,
        Z = heroPos.Z,
    }

    local navPoint = sampleReachablePoint(hero, rawTarget, 600.0)
    if navPoint == nil then return end

    ambientCounter = ambientCounter + 1
    local ambientKey = "ambient_origin_" .. tostring(ambientCounter)

    local heroLevel = 1
    pcall(function()
        local lvl = hero:GetEnemyLevel()
        if finiteNumber(lvl) then heroLevel = math.max(1, math.floor(lvl)) end
    end)

    origins[ambientKey] = {
        key = ambientKey,
        classObject = classInfo.classObject,
        classKey = chosenClassKey,
        physicalContract = classInfo.physicalContract,
        level = heroLevel,
        location = navPoint,
        issued = 1,
        completed = true,
        spawnEligible = true,
        isAmbient = true,
    }

    local request = {
        generation = generation,
        originKey = ambientKey,
        slot = 1,
        classKey = chosenClassKey,
        classObject = classInfo.classObject,
        physicalContract = classInfo.physicalContract,
        level = heroLevel,
        originLocation = navPoint,
        navAttempts = 0,
        spawnEligible = true,
        isAmbient = true,
    }

    spawnQueue[#spawnQueue + 1] = request
    dbg(string.format("AMBIENT SPAWN | empty area detected | queued %s at %.0f, %.0f", chosenClassKey, navPoint.X, navPoint.Y))
end

local function tick(stepMs)
    elapsedMs = elapsedMs + stepMs
    checkSettings(CONFIG == nil)
    if not runRequestedNativeSanitize() then return end

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

        if heroReady and clockPassed and readinessStabilitySamples >= STABILITY_SAMPLES_REQUIRED then
            worldPaused = false
            resumeAtMs = nil
            rescanRequested = true
            log("WORLD READY | enemy director resumed via readiness stability")
        else
            return
        end
    end
    -- Recovery is handled here rather than at each fault site so that every
    -- way of raising a fault, including the ones that only assign worldFault
    -- directly, becomes recoverable.
    if worldFault ~= nil then
        if worldFaultResumeAtMs == nil then
            worldFaultResumeAtMs = elapsedMs + worldFaultRetryMs
        elseif elapsedMs >= worldFaultResumeAtMs then
            log("WORLD RETRY | resuming after: " .. tostring(worldFault))
            worldFault = nil
            worldFaultResumeAtMs = nil
            -- Back off, so a world that faults every attempt stops flooding
            -- the log while a one-off recovers at full speed once it succeeds.
            worldFaultRetryMs = math.min(
                worldFaultRetryMs * 2, WORLD_FAULT_RETRY_CEILING_MS)
            rescanRequested = true
        end
        if worldFault ~= nil then return end
    end
    if not configHealthy or not CONFIG.ENABLED then
        expirePendingSpawns()
        objectQueue = {}
        return
    end

    cleanupInvalidStates()
    expirePendingSpawns()
    auditOwnedEnemyCollision()
    if worldFault ~= nil then return end
    enemyLod.update()
    if not discoveryBatch then
        if elapsedMs >= nextOriginSweepMs then
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
    checkAmbientEmptyAreaSpawns()
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
    if not isValid(object) then return end
    objectQueue[#objectQueue + 1] = { object = object, reused = reused }
    if discoveryBatch then
        discoveryReadyAtMs = elapsedMs + DISCOVERY_STABILIZE_MS
    end
end

requireHook(
    "/Script/ROD.RODEnemyCharacter:OnFinishedInitialize",
    function() end,
    function(context)
        if worldPaused and resumeAtMs == nil then return end
        local eventGeneration = generation
        pcall(function()
            local obj = context:get()
            if isValid(obj) then
                ExecuteInGameThread(function()
                    if eventGeneration ~= generation then return end
                    if isValid(obj) then
                        queueLifecycleEnemy(obj, false)
                    end
                end)
            end
        end)
    end
)

requireHook(
    "/Script/ROD.RODEnemyCharacter:EnemyReused",
    function() end,
    function(context)
        if worldPaused and resumeAtMs == nil then return end
        local eventGeneration = generation
        pcall(function()
            local obj = context:get()
            if isValid(obj) then
                ExecuteInGameThread(function()
                    if eventGeneration ~= generation then return end
                    if isValid(obj) then
                        queueLifecycleEnemy(obj, true)
                    end
                end)
            end
        end)
    end
)

for _, travelHook in ipairs({
    { "/Script/Engine.PlayerController:ClientTravelInternal", "ClientTravelInternal" },
    { "/Script/Engine.PlayerController:ClientPrepareMapChange", "ClientPrepareMapChange" },
    { "/Script/ROD.RODGameState:StartQuestEnd", "StartQuestEnd" },
    { "/Script/ROD.RODGameState:QuestEnd", "QuestEnd" },
    { "/Script/ROD.RODGameState:ShowQuestResult", "GameState.ShowQuestResult" },
    { "/Script/ROD.RODHeroCharacter:ServerRequestQuestEnd", "Hero.ServerRequestQuestEnd" },
    { "/Script/ROD.RODHeroCharacter:MulticastQuestEnd", "Hero.MulticastQuestEnd" },
    { "/Script/ROD.RODPlayerState:ServerDecideTown", "ServerDecideTown" },
    { "/Script/ROD.RODPlayerState:ServerShowQuestResult", "ServerShowQuestResult" },
}) do
    local hookPath = travelHook[1]
    local hookLabel = travelHook[2]
    requireHook(
        hookPath,
        function() beginTravel(hookLabel) end,
        function() requestNativeSanitize("post-boundary: " .. hookLabel) end
    )
end

requireHook(
    "/Script/ROD.RODPlayerState:ServerDecideFastTravel",
    function()
        beginSameWorldSettle("ServerDecideFastTravel(same-world)")
    end,
    function() requestNativeSanitize("post-boundary: ServerDecideFastTravel") end
)

requireHook(
    "/Script/ROD.RODPlayerState:ServerDecideStartTerminal",
    function()
        beginTravel("ServerDecideStartTerminal")
    end,
    function() requestNativeSanitize("post-boundary: ServerDecideStartTerminal") end
)

-- Mod-performed same-world travel does not enter ServerDecideFastTravel.
-- K2_TeleportTo is the actual engine move used by FastTravelMod, so a large
-- move of the local hero is the canonical boundary at which every retained
-- enemy/world reference must be released. Small corrective teleports stay
-- below the threshold and do not interrupt the director.
requireHook(
    "/Script/Engine.Actor:K2_TeleportTo",
    function(actorParameter, destinationParameter)
        local ok, hookError = pcall(function()
            local actor = actorParameter:get()
            local hero = resolveHeroObject()
            if not isValid(actor) or not isValid(hero)
                or objectKey(actor) ~= objectKey(hero) then
                return
            end

            local current, currentError = actorLocation(hero)
            if current == nil then error(currentError) end
            local destination = vector(destinationParameter:get())
            if destination == nil then
                error("K2_TeleportTo destination is invalid")
            end
            local dx = destination.X - current.X
            local dy = destination.Y - current.Y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance >= 3000.0 then
                beginSameWorldSettle(string.format(
                    "local hero K2_TeleportTo %.0f cm",
                    distance))
            end
        end)
        if not ok then
            log("WORLD QUARANTINE ERROR | K2_TeleportTo hook | " ..
                tostring(hookError))
        end
    end
)

requireHook(
    "/Script/ROD.RODHeroCharacter:MulticastRestSafeArea",
    function()
        beginTravel("MulticastRestSafeArea (Checkpoint Rest)")
    end,
    function() requestNativeSanitize("post-boundary: MulticastRestSafeArea") end
)

requireHook(
    "/Script/ROD.RODPlayerState:ServerNotifyQuestTeleportOut",
    beginQuestTeleportSettle,
    function() requestNativeSanitize("post-boundary: ServerNotifyQuestTeleportOut") end
)

requireHook(
    "/Script/Engine.PlayerController:ClientRestart",
    beginRestartSettle,
    function() requestNativeSanitize("post-boundary: ClientRestart") end
)

RegisterConsoleCommandGlobalHandler(
    "enemy_director_status",
    function()
        ExecuteInGameThread(function()
            local natural, owned, admissionPending, nativeRegistered = 0, 0, 0, 0
            local common, elite, boss = 0, 0, 0
            for _, state in pairs(states) do
                if state.owned then
                    owned = owned + 1
                    if state.admitted ~= true then
                        admissionPending = admissionPending + 1
                    end
                    local inEnemies, inGroup =
                        nativeRegistryMembership(state.object, state.key)
                    if inEnemies and inGroup then
                        nativeRegistered = nativeRegistered + 1
                    end
                else
                    natural = natural + 1
                end
                if state.baseline.tier == "common" then
                    common = common + 1
                elseif state.baseline.tier == "elite" then
                    elite = elite + 1
                elseif state.baseline.tier == "boss" then
                    boss = boss + 1
                end
            end
            log(string.format(
                "STATUS | healthy=%s enabled=%s paused=%s fault=%s "
                    .. "natural=%d extras=%d nativeRegistered=%d "
                    .. "admissionPending=%d "
                    .. "tiers=%d/%d/%d(common/elite/boss) "
                    .. "queued=%d pending=%d classes=%d spawning=%s",
                tostring(configHealthy),
                tostring(CONFIG ~= nil and CONFIG.ENABLED),
                tostring(worldPaused),
                tostring(worldFault),
                natural,
                owned,
                nativeRegistered,
                admissionPending,
                common,
                elite,
                boss,
                #spawnQueue,
                #pendingSpawns,
                #classOrder,
                "native"
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
