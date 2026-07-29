print("[SpeedMod] Loading TERRAIN RUNNER v7.20 - STATE MACHINE READINESS & HOT-PATH OPTIMIZATION...")
print("[SpeedMod] Startup lifecycle hooks arm immediately; readiness state machine activates upon world stability.")
print("[SpeedMod] Quest/map travel uses dynamic readiness stability guard; ClientRestart uses tick-safe quarantine.")

--========================================================--
--     TERRAIN RUNNER v7.20 - MOD STACK COMPATIBILITY   --
--========================================================--
-- Goals:
--   * Dynamic state-machine readiness based on consecutive world & hero stability.
--   * Cache Hero and MovementComponent references per world generation.
--   * Fast-path baseline identity checks to avoid per-tick C++ reflection.
--   * Preserve transition safety during map changes, teleports, and sleep transitions.
--   * Preserve sprint-entry detection and grade-aligned swept offsets.
--   * Preserve external config loading, fail-closed semantics, and console commands.
--========================================================--

-- Polling intervals. Only one game-thread callback may be outstanding at a time.
local ACTIVE_TICK_MS = 16
local IDLE_TICK_MS = 25
local LOADING_POLL_MS = 250

-- Transition safety & Readiness thresholds.
local POST_TRANSITION_GRACE_MS = 1250
local TELEPORT_GRACE_MS = 750
local TELEPORT_DISTANCE_THRESHOLD = 3000.0

-- Readiness stability: requires N consecutive stable samples of hero & movement before activating.
local STABILITY_SAMPLES_REQUIRED = 3

-- State transition pause durations.
local QUEST_QUIET_SEC = 4.0
local SLEEP_QUIET_SEC = 10.0
local SLEEP_DEBOUNCE_SEC = 10.0
local RESTART_SETTLE_SEC = 2.0
local TRAVEL_TIMEOUT_MS = 30000
local MAX_RESTART_QUARANTINE_SEC = 5.0

--========================================================--
--                  EXTERNAL CONFIG LOADER                --
--========================================================--
-- Players only need to edit config.lua beside this main.lua.
-- This exact file is the canonical configuration source. Invalid or missing
-- settings disable the mod explicitly instead of selecting substitute values.
local BASE_SPEED_CONFIG = {
    ENABLED = true,
    START_SPEED = 1.40,
    MAX_SPEED = 3.20,
    SECONDS_TO_MAX_SPEED = 1.80,
    JUMP_HEIGHT_MULTIPLIER = 1.00,
    DISABLE_IN_COMBAT = true,
}

local CONFIG = {
    ENABLED = BASE_SPEED_CONFIG.ENABLED,
    START_SPEED = BASE_SPEED_CONFIG.START_SPEED,
    MAX_SPEED = BASE_SPEED_CONFIG.MAX_SPEED,
    SECONDS_TO_MAX_SPEED = BASE_SPEED_CONFIG.SECONDS_TO_MAX_SPEED,
    JUMP_HEIGHT_MULTIPLIER = BASE_SPEED_CONFIG.JUMP_HEIGHT_MULTIPLIER,
    DISABLE_IN_COMBAT = BASE_SPEED_CONFIG.DISABLE_IN_COMBAT,
}

local SAFE_MIN_START = 1.00
local SAFE_MAX_START = 2.50
local SAFE_MIN_MAX = 1.00
local SAFE_MAX_MAX = 20.00
local SAFE_MIN_RAMP_SECONDS = 0.25
local SAFE_MAX_RAMP_SECONDS = 10.00
local SAFE_MIN_JUMP_HEIGHT = 0.25
local SAFE_MAX_JUMP_HEIGHT = 15.00

local function getScriptDirectory()
    if debug == nil or type(debug.getinfo) ~= "function" then
        return nil
    end

    local ok, info = pcall(function()
        return debug.getinfo(1, "S")
    end)

    if not ok or type(info) ~= "table" or type(info.source) ~= "string" then
        return nil
    end

    local source = info.source
    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end

    return string.match(source, "^(.*[\\/])")
end

local function applyExternalConfig(external)
    if type(external) ~= "table" then
        return false, "config.lua must return a table"
    end

    if type(external.ENABLED) ~= "boolean" then
        return false, "ENABLED must be boolean"
    end
    if type(external.DISABLE_IN_COMBAT) ~= "boolean" then
        return false, "DISABLE_IN_COMBAT must be boolean"
    end

    local function boundedNumber(key, minimum, maximum)
        local value = external[key]
        if type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge then
            return nil, key .. " must be a finite number"
        end
        if value < minimum or value > maximum then
            return nil, string.format(
                "%s must be between %.2f and %.2f",
                key,
                minimum,
                maximum
            )
        end
        return value, nil
    end

    local startSpeed, startError =
        boundedNumber("START_SPEED", SAFE_MIN_START, SAFE_MAX_START)
    if startSpeed == nil then return false, startError end

    local maxSpeed, maxError =
        boundedNumber("MAX_SPEED", SAFE_MIN_MAX, SAFE_MAX_MAX)
    if maxSpeed == nil then return false, maxError end
    if maxSpeed < startSpeed then
        return false, "MAX_SPEED must be greater than or equal to START_SPEED"
    end

    local rampSeconds, rampError = boundedNumber(
        "SECONDS_TO_MAX_SPEED",
        SAFE_MIN_RAMP_SECONDS,
        SAFE_MAX_RAMP_SECONDS
    )
    if rampSeconds == nil then return false, rampError end

    local jumpHeight, jumpError = boundedNumber(
        "JUMP_HEIGHT_MULTIPLIER",
        SAFE_MIN_JUMP_HEIGHT,
        SAFE_MAX_JUMP_HEIGHT
    )
    if jumpHeight == nil then return false, jumpError end

    -- Commit only after every field is valid, so a broken live edit cannot
    -- partially mutate movement state.
    CONFIG.ENABLED = external.ENABLED
    CONFIG.START_SPEED = startSpeed
    CONFIG.MAX_SPEED = maxSpeed
    CONFIG.SECONDS_TO_MAX_SPEED = rampSeconds
    CONFIG.JUMP_HEIGHT_MULTIPLIER = jumpHeight
    CONFIG.DISABLE_IN_COMBAT = external.DISABLE_IN_COMBAT
    return true
end

local SCRIPT_DIRECTORY = nil
local MOD_MENU_BRIDGE = nil

local function loadExternalConfig()
    SCRIPT_DIRECTORY = getScriptDirectory()
    if type(SCRIPT_DIRECTORY) ~= "string" or SCRIPT_DIRECTORY == "" then
        CONFIG.ENABLED = false
        return false, "canonical script directory is unavailable"
    end

    local bridgePath = SCRIPT_DIRECTORY .. "../../shared/ModMenuBridge.lua"
    local loaded, bridge = pcall(function() return dofile(bridgePath) end)
    if not loaded then
        CONFIG.ENABLED = false
        return false, "canonical ModMenuBridge load failed: " .. tostring(bridge)
    end
    if type(bridge) ~= "table" then
        CONFIG.ENABLED = false
        return false, "canonical ModMenuBridge did not return a table"
    end
    MOD_MENU_BRIDGE = bridge

    local external, _, info =
        MOD_MENU_BRIDGE.readSettings("SpeedMod", SCRIPT_DIRECTORY)
    if external == nil then
        CONFIG.ENABLED = false
        return false, tostring(info and info.error or "canonical settings unavailable")
    end

    local applied, configError = applyExternalConfig(external)
    if not applied then
        CONFIG.ENABLED = false
        return false, tostring(configError)
    end

    print("[SpeedMod] SETTINGS | canonical config.lua + runtime.lua loaded")
    return true, nil
end

-- Derived internal values. Do not edit these.
local INITIAL_EXTRA_MULTIPLIER = 0.40
local ACCELERATION_MULTIPLIER_PER_SECOND = 1.00
local MAX_EXTRA_MULTIPLIER = 2.20

-- A missed detector sample must persist this long before sprint ends.
local SPRINT_DROPOUT_GRACE_MS = 700

-- A stale sprint cap can survive briefly after the player releases sprint.
-- Confirm native jog velocity before ending the boost immediately.
local JOG_RELEASE_RATIO = 1.06
local JOG_RELEASE_CONFIRM_MS = 180

-- Native sprint detection uses the authoritative MaxWalkSpeed transition.
local SPRINT_CAP_ENTER_RATIO = 1.06
local SPRINT_CAP_HOLD_RATIO = 1.015
local MIN_MOVING_SPEED = 75.0
local OFFSET_RETRY_SECONDS = 2.0

-- Prevent a dash, launch, or bad velocity sample from becoming the held
-- reference speed. This cap is relative to the learned native jog cap.
local MAX_REFERENCE_TO_JOG_RATIO = 2.00

-- Terrain following. The grade sample is calculated from the character's
-- native movement between the previous injected offset and this tick. This
-- avoids confusing our own added horizontal distance with the slope.
local MIN_NATIVE_TERRAIN_SAMPLE = 0.20
local MAX_NATIVE_SAMPLE_Z = 90.0
local MAX_UPHILL_GRADE = 1.20
local MAX_DOWNHILL_GRADE = 1.35
local TERRAIN_GRADE_BLEND = 0.55
local TERRAIN_GRADE_DECAY = 0.82
local TERRAIN_GRADE_DEADZONE = 0.018
local MAX_UPWARD_OFFSET_PER_TICK = 16.0
local MAX_DOWNWARD_OFFSET_PER_TICK = 18.0
local MIN_INPUT_ACCELERATION = 10.0

-- Console spam can create hitching. Leave false for normal use.
local DEBUG_LOGS = false

local cachedHero = nil
local cachedMovement = nil
local jumpMovement = nil
local jumpMovementKey = nil
local nativeJumpZVelocity = nil
local jumpWriteSupported = nil
local movementReadyReported = false
local movementErrorReported = false
local movementBaselineKey = nil
local movementBaselineErrorReported = false
local movementCapErrorReported = false
local jumpReadySignature = nil
local jumpIdentityErrorReported = false
local jumpBaselineErrorReported = false
local heroWaitingReported = false
local disabledStateReported = false
local boostReadyReported = false
local nativeJogCap = nil
local clockErrorReported = false
local stabilitySamples = 0

local extraMultiplier = 0.0
local wasSprinting = false
local sprintDropoutMs = 0
local stableSprintSpeed = nil
local lastDirectionX = nil
local lastDirectionY = nil
local lastDirectionZ = 0.0
local terrainGrade = 0.0
local jogReleaseMs = 0
local combatLockActive = false
local combatStateSupported = nil
local combatEnterMs = 0
local combatExitMs = 0
local combatLockReason = nil

local mapLeaving = false
local quietUntil = 0.0
local sleepDebounceUntil = 0.0
local lifecycleGeneration = 1
local tickQueued = false
local startupCompatReady = false
local restartPending = false
local restartReleaseClock = 0.0
local restartCompatToken = 0
local nextPollMs = IDLE_TICK_MS
local postTransitionGraceMs = POST_TRANSITION_GRACE_MS
local teleportGraceMs = 0

local travelTimeoutId = 0

local lastLocationX = nil
local lastLocationY = nil
local lastLocationZ = nil
local lastPostOffsetX = nil
local lastPostOffsetY = nil
local lastPostOffsetZ = nil
local lastJustTeleportedFlag = false
local offsetSupported = nil
local offsetRetryClock = 0.0
local offsetFailureReported = false
local lastClockSeconds = nil

local elapsedMs = 0
local lastStatusLogMs = 0

local offsetDelta = { X = 0.0, Y = 0.0, Z = 0.0 }

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    elseif value > maximum then
        return maximum
    end
    return value
end

local function applySpeedConfig()
    local startMultiplier = CONFIG.START_SPEED
    local maxMultiplier = CONFIG.MAX_SPEED
    local rampSeconds = CONFIG.SECONDS_TO_MAX_SPEED

    INITIAL_EXTRA_MULTIPLIER = math.max(0.0, startMultiplier - 1.0)
    MAX_EXTRA_MULTIPLIER = math.max(
        INITIAL_EXTRA_MULTIPLIER,
        maxMultiplier - 1.0
    )

    local extraRange = MAX_EXTRA_MULTIPLIER -
        INITIAL_EXTRA_MULTIPLIER
    if extraRange <= 0.0001 then
        ACCELERATION_MULTIPLIER_PER_SECOND = 0.0
    else
        ACCELERATION_MULTIPLIER_PER_SECOND =
            extraRange / rampSeconds
    end
end

local function speedConfigSummary()
    return string.format(
        "enabled=%s | start=%.2fx | max=%.2fx | ramp=%.2fs | jumpHeight=%.2fx | combatLock=%s",
        CONFIG.ENABLED and "true" or "false",
        CONFIG.START_SPEED,
        CONFIG.MAX_SPEED,
        CONFIG.SECONDS_TO_MAX_SPEED,
        CONFIG.JUMP_HEIGHT_MULTIPLIER,
        CONFIG.DISABLE_IN_COMBAT and "true" or "false"
    )
end

local configLoaded, configLoadError = loadExternalConfig()
if not configLoaded then
    error("[SpeedMod] CONFIG ERROR | " .. tostring(configLoadError))
end
applySpeedConfig()
print("[SpeedMod] CONFIG | " .. speedConfigSummary())

local function log(message)
    if DEBUG_LOGS then
        print("[SpeedMod] " .. tostring(message))
    end
end

local function warn(message)
    print("[SpeedMod] " .. tostring(message))
end

-- Object references are cleared by resetState().
-- Do NOT force a full Lua GC from travel/sleep hooks; multiple UE events can
-- fire in the same transition and synchronous GC there can collide with
-- Unreal object teardown. Let UE4SS/Lua collect naturally.
local function dropLuaRefs()
    -- intentionally empty
end

local function isValidObj(obj)
    if obj == nil then
        return false
    end

    -- When a name resolves to a UFunction instead of a property, UE4SS hands
    -- back a bound function rather than an object. Calling ':IsValid()' on that
    -- is a hard Lua error ("attempt to index a function value"), so reject
    -- anything that is not object-like before touching it.
    local kind = type(obj)
    if kind ~= "userdata" and kind ~= "table" then
        return false
    end

    local ok, valid = pcall(function()
        return obj:IsValid()
    end)

    return ok and valid == true
end

local readNumber

local function resolveMovementComponent(hero)
    if isValidObj(cachedMovement) then
        return cachedMovement, nil
    end

    local resolved, component = pcall(function()
        return hero:GetMovementComponent()
    end)
    if resolved and isValidObj(component) then
        cachedMovement = component
        return component, nil
    end
    cachedMovement = nil
    if not resolved then return nil, tostring(component) end
    return nil, "GetMovementComponent returned an invalid component"
end

local function resolveCanonicalMovementBaseline(hero, movement)
    local resolved, identityOrError, baseline = pcall(function()
        local movementIdentity = movement:GetFullName()
        if type(movementIdentity) ~= "string" or movementIdentity == "" then
            error("live CharacterMovement identity is unavailable")
        end

        local heroClass = hero:GetClass()
        if not isValidObj(heroClass) then
            error("hero class is unavailable")
        end

        local heroCDO = heroClass:GetCDO()
        if not isValidObj(heroCDO) then
            error("hero class default object is unavailable")
        end

        local defaultMovement = heroCDO.CharacterMovement
        if not isValidObj(defaultMovement) then
            error("hero CDO CharacterMovement is unavailable")
        end

        local liveClass = movement:GetClass()
        local defaultClass = defaultMovement:GetClass()
        if not isValidObj(liveClass) or not isValidObj(defaultClass) then
            error("movement component class identity is unavailable")
        end

        local liveClassName = liveClass:GetFullName()
        local defaultClassName = defaultClass:GetFullName()
        if type(liveClassName) ~= "string"
            or type(defaultClassName) ~= "string"
            or liveClassName ~= defaultClassName then
            error("live movement class does not match the hero CDO")
        end

        local maxWalkSpeed = readNumber(defaultMovement, "MaxWalkSpeed")
        if maxWalkSpeed == nil or maxWalkSpeed <= 0.0 then
            error("hero CDO MaxWalkSpeed is unavailable")
        end

        return movementIdentity, maxWalkSpeed
    end)

    if not resolved then
        return nil, nil, tostring(identityOrError)
    end
    return identityOrError, baseline, nil
end

local function bindCanonicalMovementBaseline(hero, movement)
    -- Fast path: reuse cached baseline identity if the movement component reference is unchanged across ticks.
    if movementBaselineKey ~= nil and nativeJogCap ~= nil and cachedMovement == movement then
        return true
    end

    local identityOk, currentIdentity = pcall(function()
        return movement:GetFullName()
    end)
    if identityOk
        and type(currentIdentity) == "string"
        and currentIdentity ~= ""
        and movementBaselineKey == currentIdentity
        and nativeJogCap ~= nil then
        return true
    end

    local movementIdentity, baseline, baselineError =
        resolveCanonicalMovementBaseline(hero, movement)
    if movementIdentity == nil or baseline == nil then
        movementBaselineKey = nil
        nativeJogCap = nil
        if not movementBaselineErrorReported then
            movementBaselineErrorReported = true
            warn("MOVEMENT BASELINE ERROR | horizontal boost is fail-closed: "
                .. tostring(baselineError))
        end
        return false
    end

    movementBaselineErrorReported = false
    movementBaselineKey = movementIdentity
    nativeJogCap = baseline
    if not movementReadyReported then
        movementReadyReported = true
        warn(string.format(
            "MOVEMENT READY | canonical CDO jog=%.2f",
            nativeJogCap
        ))
    end
    return true
end

local function acceptHero(hero)
    if not isValidObj(hero) then
        return nil
    end

    local okHost, isHost = pcall(function()
        return hero:IsHostHero()
    end)

    if okHost and isHost == true then
        return hero
    end

    return nil
end

local function tryFindFirstOf(className)
    if type(className) ~= "string" or className == "" then
        return nil
    end

    local okFind, obj = pcall(FindFirstOf, className)

    if not okFind then
        return nil
    end

    return obj
end

local function findHero()
    -- RODWorldHeroCharacter is the canonical playable-world hero class.
    -- Missing heroes are expected while a world is loading; the persistent
    -- poll keeps trying this exact class until it exists.
    return acceptHero(tryFindFirstOf("RODWorldHeroCharacter"))
end

local function resolveHero()
    if isValidObj(cachedHero) then
        return cachedHero
    end

    cachedHero = findHero()

    if isValidObj(cachedHero) then
        heroWaitingReported = false
        log("Hero found")
    else
        cachedMovement = nil
    end

    return cachedHero
end

readNumber = function(object, propertyName)
    if object == nil then return nil end
    local value = object[propertyName]
    if type(value) == "number" then
        return value
    end
    return nil
end

local function readBool(object, propertyName)
    if object == nil then return nil end
    local value = object[propertyName]
    if type(value) == "boolean" then
        return value
    end
    return nil
end

local function clearJumpTracking()
    jumpMovement = nil
    jumpMovementKey = nil
    nativeJumpZVelocity = nil
    jumpWriteSupported = nil
    jumpReadySignature = nil
    jumpIdentityErrorReported = false
    jumpBaselineErrorReported = false
end

local function restoreJumpVelocity()
    if not isValidObj(jumpMovement) or nativeJumpZVelocity == nil then
        clearJumpTracking()
        return true
    end

    local restored, restoreError = pcall(function()
        jumpMovement.JumpZVelocity = nativeJumpZVelocity
    end)
    if not restored then
        warn("JUMP HEIGHT ERROR | could not restore JumpZVelocity: " ..
            tostring(restoreError))
        clearJumpTracking()
        return false
    end

    local restoredVelocity = readNumber(jumpMovement, "JumpZVelocity")
    if restoredVelocity == nil
        or math.abs(restoredVelocity - nativeJumpZVelocity) > 0.01 then
        warn("JUMP HEIGHT ERROR | native JumpZVelocity restore was rejected")
        clearJumpTracking()
        return false
    end

    clearJumpTracking()
    return true
end

-- CharacterMovement.JumpZVelocity is the canonical Unreal vertical launch
-- property. Ballistic apex height is proportional to velocity squared, so the
-- square root converts a requested height multiplier into launch velocity.
local function resolveCanonicalJumpBaseline(hero, movement)
    local resolved, valueOrError = pcall(function()
        local heroClass = hero:GetClass()
        if not isValidObj(heroClass) then
            error("hero class is unavailable")
        end

        local heroCDO = heroClass:GetCDO()
        if not isValidObj(heroCDO) then
            error("hero class default object is unavailable")
        end

        -- ACharacter.CharacterMovement on the concrete hero CDO is the
        -- authoritative Blueprint-configured default subobject. Reading the
        -- live component here would compound our own write after UE4SS's
        -- "Restart All Mods".
        local defaultMovement = heroCDO.CharacterMovement
        if not isValidObj(defaultMovement) then
            error("hero CDO CharacterMovement is unavailable")
        end

        local liveClass = movement:GetClass()
        local defaultClass = defaultMovement:GetClass()
        if not isValidObj(liveClass) or not isValidObj(defaultClass) then
            error("movement component class identity is unavailable")
        end

        local liveClassName = liveClass:GetFullName()
        local defaultClassName = defaultClass:GetFullName()
        if type(liveClassName) ~= "string"
            or type(defaultClassName) ~= "string"
            or liveClassName ~= defaultClassName then
            error("live movement class does not match the hero CDO")
        end

        local nativeVelocity = readNumber(defaultMovement, "JumpZVelocity")
        if nativeVelocity == nil or nativeVelocity <= 0.0 then
            error("hero CDO JumpZVelocity is unavailable")
        end

        return nativeVelocity
    end)

    if not resolved then
        return nil, tostring(valueOrError)
    end
    return valueOrError, nil
end

local function applyJumpHeight(hero, movement)
    if not isValidObj(hero) or not isValidObj(movement) then return false end

    -- Fast path: reuse cached jump state if target configuration and component reference are unchanged.
    if jumpMovement == movement and jumpWriteSupported == true and jumpReadySignature ~= nil then
        local currentSignature = string.format("%s|%.6f", jumpMovementKey or "", CONFIG.JUMP_HEIGHT_MULTIPLIER)
        if jumpReadySignature == currentSignature then
            return true
        end
    end

    local identityOk, movementIdentity = pcall(function()
        return movement:GetFullName()
    end)
    if not identityOk or type(movementIdentity) ~= "string"
        or movementIdentity == "" then
        if not jumpIdentityErrorReported then
            jumpIdentityErrorReported = true
            warn("JUMP HEIGHT ERROR | canonical CharacterMovement identity is unavailable")
        end
        return false
    end
    jumpIdentityErrorReported = false

    if jumpMovementKey ~= movementIdentity then
        if not restoreJumpVelocity() then return false end
        jumpMovement = movement
        jumpMovementKey = movementIdentity
        local baseline, baselineError =
            resolveCanonicalJumpBaseline(hero, movement)
        nativeJumpZVelocity = baseline
        jumpWriteSupported = nil

        if nativeJumpZVelocity == nil or nativeJumpZVelocity <= 0.0 then
            jumpWriteSupported = false
            if not jumpBaselineErrorReported then
                jumpBaselineErrorReported = true
                warn("JUMP HEIGHT ERROR | canonical CDO baseline unavailable: " ..
                    tostring(baselineError))
            end
            return false
        end
        jumpBaselineErrorReported = false
    else
        -- UE4SS may expose a new Lua wrapper for the same Unreal object on each
        -- call. Refresh the wrapper but retain the native baseline and log state.
        jumpMovement = movement
    end

    if jumpWriteSupported == false then return false end

    local targetVelocity =
        nativeJumpZVelocity * math.sqrt(CONFIG.JUMP_HEIGHT_MULTIPLIER)
    local readySignature = string.format(
        "%s|%.6f",
        movementIdentity,
        CONFIG.JUMP_HEIGHT_MULTIPLIER
    )

    local function reportReady()
        if jumpReadySignature == readySignature then return end
        jumpReadySignature = readySignature
        warn(string.format(
            "JUMP READY | native=%.2f | applied=%.2f | height=%.2fx",
            nativeJumpZVelocity,
            targetVelocity,
            CONFIG.JUMP_HEIGHT_MULTIPLIER
        ))
    end

    local currentVelocity = readNumber(movement, "JumpZVelocity")
    if currentVelocity ~= nil
        and math.abs(currentVelocity - targetVelocity) <= 0.01 then
        jumpWriteSupported = true
        reportReady()
        return true
    end

    local written, writeError = pcall(function()
        movement.JumpZVelocity = targetVelocity
    end)
    if not written then
        jumpWriteSupported = false
        warn("JUMP HEIGHT ERROR | could not write JumpZVelocity: " ..
            tostring(writeError))
        return false
    end

    local verifiedVelocity = readNumber(movement, "JumpZVelocity")
    if verifiedVelocity == nil
        or math.abs(verifiedVelocity - targetVelocity) > 0.01 then
        jumpWriteSupported = false
        warn("JUMP HEIGHT ERROR | JumpZVelocity write was rejected")
        return false
    end

    jumpWriteSupported = true
    reportReady()
    return true
end

local function applyLiveJumpSetting()
    if not CONFIG.ENABLED then
        restoreJumpVelocity()
        return
    end

    local hero = resolveHero()
    if not isValidObj(hero) then
        if not heroWaitingReported then
            heroWaitingReported = true
            warn("WAITING FOR HERO | movement poll remains active")
        end
        return
    end
    heroWaitingReported = false

    local movement, movementError = resolveMovementComponent(hero)
    if not isValidObj(movement) then
        if not movementErrorReported then
            movementErrorReported = true
            warn("WAITING FOR MOVEMENT | " .. tostring(movementError) ..
                " | poll remains active")
        end
        return
    end
    movementErrorReported = false

    applyJumpHeight(hero, movement)
end

-- Combat lock evaluates active lock-on target or recent melee engagement
-- rather than passive aggro proximity to avoid rapid oscillation.
local COMBAT_ATTACK_TARGET_DISTANCE = 1800.0
local COMBAT_ENTER_CONFIRM_MS = 200
local COMBAT_EXIT_CONFIRM_MS = 1000

local function isLiveTarget(actor)
    if not isValidObj(actor) then
        return false
    end

    local okDead, dead = pcall(function()
        return actor:IsDead()
    end)

    return not (okDead and dead)
end

local function tryLiveTarget(getter)
    local ok, actor = pcall(getter)
    if not ok or not isLiveTarget(actor) then
        return nil
    end
    return actor
end

local function getCombatEngagementSignal(hero)
    if not CONFIG.DISABLE_IN_COMBAT then
        return false, "disabled"
    end

    local ok, inCombat = pcall(function()
        return hero:IsCombat()
    end)

    if not ok or type(inCombat) ~= "boolean" then
        if combatStateSupported ~= false then
            warn("IsCombat was unavailable; combat lockout disabled for this session.")
        end
        combatStateSupported = false
        return false, "unavailable"
    end

    combatStateSupported = true

    if not inCombat then
        return false, "not in combat"
    end

    -- Lock-on is deliberate engagement and should stop traversal boost quickly.
    local lockOn = tryLiveTarget(function()
        return hero:GetCurrentLockOnTarget()
    end)
    if lockOn then
        return true, "lock-on"
    end

    -- Fighting without lock-on becomes a combat lock after the player has
    -- actually attacked something nearby. Merely being noticed/chased does
    -- not disable traversal speed.
    local lastAttack = tryLiveTarget(function()
        return hero:GetLastAttackEnemy()
    end)
    if lastAttack then
        local okDist, distance = pcall(function()
            return hero:GetActorDist(lastAttack)
        end)

        if okDist and type(distance) == "number" and
           distance <= COMBAT_ATTACK_TARGET_DISTANCE then
            return true, "recent attack"
        end
    end

    return false, "aggro only"
end

local function axisNumber(value)
    if type(value) ~= "number" then return nil end
    if value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end
    return value
end

local function getHorizontalVelocity(movement)
    local ok, x, y = pcall(function()
        local velocity = movement.Velocity
        if velocity == nil then return nil, nil end
        return axisNumber(velocity.X), axisNumber(velocity.Y)
    end)

    if not ok or x == nil or y == nil then
        return 0.0, 0.0, 0.0
    end

    local speed = math.sqrt((x * x) + (y * y))
    return x, y, speed
end

local function getHorizontalAcceleration(movement)
    local ok, x, y = pcall(function()
        local acceleration = movement.Acceleration
        if acceleration == nil then return nil, nil end
        return axisNumber(acceleration.X), axisNumber(acceleration.Y)
    end)

    if not ok or x == nil or y == nil then
        return 0.0, 0.0, 0.0
    end

    local magnitude = math.sqrt((x * x) + (y * y))
    return x, y, magnitude
end

local function getActorLocation(hero)
    local ok, location = pcall(function()
        return hero:K2_GetActorLocation()
    end)

    if not ok or location == nil then
        return nil, nil, nil
    end

    local x = axisNumber(location.X)
    local y = axisNumber(location.Y)
    local z = axisNumber(location.Z)
    if x == nil or y == nil or z == nil then
        return nil, nil, nil
    end
    return x, y, z
end

-- ExecuteWithDelay does not guarantee an exact interval. os.clock is the
-- canonical timer for movement integration. Missing or implausible samples
-- skip that injection tick instead of substituting a synthetic delta.
local function getMeasuredDeltaSeconds()
    local okClock, now = pcall(os.clock)
    if not okClock or type(now) ~= "number" then
        if not clockErrorReported then
            clockErrorReported = true
            warn("CLOCK ERROR | os.clock unavailable; movement injection paused")
        end
        lastClockSeconds = nil
        return nil
    end
    clockErrorReported = false

    if lastClockSeconds == nil then
        lastClockSeconds = now
        return nil
    end

    local measured = now - lastClockSeconds
    lastClockSeconds = now
    if measured < 0.005 or measured > 0.050 then
        return nil
    end
    return measured
end

local function clearAcceleration()
    extraMultiplier = 0.0
    wasSprinting = false
    sprintDropoutMs = 0
    stableSprintSpeed = nil
    lastDirectionX = nil
    lastDirectionY = nil
    lastDirectionZ = 0.0
    terrainGrade = 0.0
    jogReleaseMs = 0
    nextPollMs = IDLE_TICK_MS
end

local function resetState()
    cachedHero = nil
    cachedMovement = nil
    stabilitySamples = 0
    -- World teardown owns the old movement component. Discard its reference;
    -- writing into a component being destroyed is unsafe.
    clearJumpTracking()
    movementReadyReported = false
    movementErrorReported = false
    movementBaselineKey = nil
    movementBaselineErrorReported = false
    movementCapErrorReported = false
    heroWaitingReported = false
    boostReadyReported = false
    nativeJogCap = nil
    clockErrorReported = false

    extraMultiplier = 0.0
    wasSprinting = false
    sprintDropoutMs = 0
    stableSprintSpeed = nil
    lastDirectionX = nil
    lastDirectionY = nil
    lastDirectionZ = 0.0
    terrainGrade = 0.0
    jogReleaseMs = 0
    combatLockActive = false
    combatStateSupported = nil
    combatEnterMs = 0
    combatExitMs = 0
    combatLockReason = nil

    teleportGraceMs = 0
    lastLocationX = nil
    lastLocationY = nil
    lastLocationZ = nil
    lastPostOffsetX = nil
    lastPostOffsetY = nil
    lastPostOffsetZ = nil
    lastJustTeleportedFlag = false
    offsetSupported = nil
    offsetRetryClock = 0.0
    offsetFailureReported = false
    lastClockSeconds = nil

    elapsedMs = 0
    lastStatusLogMs = 0
    nextPollMs = IDLE_TICK_MS
end

local function invalidateMovementSession()
    lifecycleGeneration = lifecycleGeneration + 1
    resetState()
    dropLuaRefs()
end

local function beginQuietOnly(reason, quietSec)
    quietSec = quietSec or QUEST_QUIET_SEC
    invalidateMovementSession()
    quietUntil = math.max(quietUntil, os.clock() + quietSec)
    print(
        "[SpeedMod] QUIET " .. string.format("%.0fs", quietSec) ..
        " | " .. tostring(reason)
    )
end

local function beginSleepQuiet(reason)
    local now = os.clock()

    -- A single sleep action can emit StartSleepDirection,
    -- ServerSleepDirection, ClientStartSleepFade, and StartSleepFade within
    -- milliseconds of each other. Treat them as one transition.
    if now < sleepDebounceUntil then
        quietUntil = math.max(quietUntil, sleepDebounceUntil)
        print("[SpeedMod] SLEEP DUPLICATE IGNORED | " .. tostring(reason))
        return
    end

    sleepDebounceUntil = now + SLEEP_DEBOUNCE_SEC
    invalidateMovementSession()
    quietUntil = math.max(quietUntil, sleepDebounceUntil)

    print(
        "[SpeedMod] SLEEP PAUSE " ..
        string.format("%.0fs", SLEEP_DEBOUNCE_SEC) ..
        " | " .. tostring(reason) ..
        " | duplicate sleep hooks ignored"
    )
end

local function endTravelState()
    mapLeaving = false
    travelTimeoutId = travelTimeoutId + 1
end

local function onWorldReady(reason, quietSec)
    local wasLeaving = mapLeaving
    endTravelState()
    invalidateMovementSession()

    quietSec = quietSec or RESTART_SETTLE_SEC
    quietUntil = math.max(quietUntil, os.clock() + quietSec)
    postTransitionGraceMs = POST_TRANSITION_GRACE_MS

    if wasLeaving then
        print(
            "[SpeedMod] TRAVEL END | " .. tostring(reason) ..
            " | settle " .. string.format("%.1fs", quietSec)
        )
    else
        print(
            "[SpeedMod] WORLD RESET | " .. tostring(reason) ..
            " | settle " .. string.format("%.1fs", quietSec)
        )
    end
end

local function beginTravel(reason)
    if mapLeaving then
        return
    end

    mapLeaving = true
    quietUntil = 0.0
    invalidateMovementSession()

    print("[SpeedMod] TRAVEL BEGIN | " .. tostring(reason))

    travelTimeoutId = travelTimeoutId + 1
    local timeoutId = travelTimeoutId
    ExecuteWithDelay(TRAVEL_TIMEOUT_MS, function()
        if not mapLeaving or timeoutId ~= travelTimeoutId then
            return
        end
        -- This used to warn and stop, leaving mapLeaving set: the tick returned
        -- early on it forever and movement never came back for the rest of the
        -- session. ClientRestart is shared by several mods, and UE4SS does
        -- remove a hook when any of them throws --
        -- "[Lua::Registry::get_function_ref] Ref was not function ... removing
        -- hook!" was observed immediately before this timeout fired. A lost
        -- callback must not be able to disable movement permanently.
        --
        -- Recovery is the same readiness-stability path ClientRestart would have
        -- taken, so nothing new is invented: the tick resumes once the hero and
        -- movement component read valid, or once the quarantine clock passes.
        warn("TRAVEL ERROR | ClientRestart was not received after " ..
            tostring(TRAVEL_TIMEOUT_MS) ..
            "ms; recovering through readiness stability")
        restartCompatToken = restartCompatToken + 1
        restartPending = true
        restartReleaseClock = math.max(
            restartReleaseClock,
            os.clock() + MAX_RESTART_QUARANTINE_SEC
        )
    end)
end

local function detectNativeSprint(currentCap, horizontalSpeed)
    if horizontalSpeed < MIN_MOVING_SPEED then
        return false, "not moving"
    end

    if nativeJogCap == nil or currentCap == nil then
        return false, "movement cap unavailable"
    end

    local ratio = wasSprinting and
        SPRINT_CAP_HOLD_RATIO or SPRINT_CAP_ENTER_RATIO

    if currentCap > (nativeJogCap * ratio) then
        return true, wasSprinting and
            "movement-cap hold" or "movement cap"
    end

    return false, "jog"
end

local function teleportDetected(movement, x, y, z)
    local flagged = readBool(movement, "bJustTeleported") == true

    if lastLocationX ~= nil then
        local dx = x - lastLocationX
        local dy = y - lastLocationY
        local dz = z - lastLocationZ
        local distanceSquared = (dx * dx) + (dy * dy) + (dz * dz)
        local thresholdSquared =
            TELEPORT_DISTANCE_THRESHOLD * TELEPORT_DISTANCE_THRESHOLD

        if distanceSquared > thresholdSquared then
            lastJustTeleportedFlag = flagged
            return true, "large location jump"
        end
    end

    -- CharacterMovement also sets this during normal floor correction,
    -- depenetration, and step-up. Treating it as travel caused the old
    -- 750 ms terrain hitches, so it is informational only.
    lastJustTeleportedFlag = flagged
    return false, nil
end

local function addSweptOffset(hero, deltaX, deltaY, deltaZ)
    local now = os.clock()
    if offsetSupported == false and now < offsetRetryClock then
        return false
    end

    deltaZ = deltaZ or 0.0

    if math.abs(deltaX) < 0.0001 and
       math.abs(deltaY) < 0.0001 and
       math.abs(deltaZ) < 0.0001 then
        return true
    end

    offsetDelta.X = deltaX
    offsetDelta.Y = deltaY
    offsetDelta.Z = deltaZ

    local ok = pcall(function()
        -- Never retain FHitResult output references across frames or worlds.
        local ignoredHitResult = {}
        hero:K2_AddActorWorldOffset(
            offsetDelta,
            true,
            ignoredHitResult,
            false
        )
    end)

    if ok then
        if offsetSupported == false then
            warn("OFFSET READY | canonical swept movement recovered")
        end
        offsetSupported = true
        offsetRetryClock = 0.0
        offsetFailureReported = false
        return true
    end

    offsetSupported = false
    offsetRetryClock = now + OFFSET_RETRY_SECONDS
    if not offsetFailureReported then
        offsetFailureReported = true
        warn(string.format(
            "OFFSET ERROR | K2_AddActorWorldOffset failed; injection paused, canonical retry in %.0fs",
            OFFSET_RETRY_SECONDS
        ))
    end
    return false
end

local function clampReferenceSpeed(speed)
    if speed == nil or speed <= 0 then
        return nil
    end

    if nativeJogCap and nativeJogCap > 0 then
        return math.min(
            speed,
            nativeJogCap * MAX_REFERENCE_TO_JOG_RATIO
        )
    end

    return speed
end

local function updateStableSprintSpeed(currentCap, horizontalSpeed)
    local candidate = horizontalSpeed

    if currentCap and currentCap > candidate then
        candidate = currentCap
    end

    candidate = clampReferenceSpeed(candidate)

    if candidate and
       (stableSprintSpeed == nil or candidate > stableSprintSpeed) then
        -- Rise immediately when the native game reports a higher legitimate
        -- sprint speed. Do not fall on one weak velocity sample.
        stableSprintSpeed = candidate
    end

    return stableSprintSpeed or horizontalSpeed
end

local function updateTerrainGrade(
    movementMode,
    currentX,
    currentY,
    currentZ,
    directionX,
    directionY
)
    local grounded = movementMode == 1 or movementMode == 2

    if grounded and lastPostOffsetX ~= nil then
        local dx = currentX - lastPostOffsetX
        local dy = currentY - lastPostOffsetY
        local dz = currentZ - lastPostOffsetZ
        local horizontal = math.sqrt((dx * dx) + (dy * dy))

        if horizontal >= MIN_NATIVE_TERRAIN_SAMPLE and
           math.abs(dz) <= MAX_NATIVE_SAMPLE_Z then
            local alignmentOk = true

            if directionX ~= nil and directionY ~= nil then
                local nativeX = dx / horizontal
                local nativeY = dy / horizontal
                local alignment =
                    (nativeX * directionX) + (nativeY * directionY)
                alignmentOk = alignment >= 0.15
            end

            if alignmentOk then
                local sample = dz / horizontal
                sample = clamp(
                    sample,
                    -MAX_DOWNHILL_GRADE,
                    MAX_UPHILL_GRADE
                )

                if math.abs(sample) < TERRAIN_GRADE_DEADZONE then
                    sample = 0.0
                end

                terrainGrade =
                    (terrainGrade * (1.0 - TERRAIN_GRADE_BLEND)) +
                    (sample * TERRAIN_GRADE_BLEND)

                return horizontal
            end
        end
    end

    terrainGrade = terrainGrade * TERRAIN_GRADE_DECAY

    if math.abs(terrainGrade) < TERRAIN_GRADE_DEADZONE then
        terrainGrade = 0.0
    end

    return 0.0
end

local function updateThreeDimensionalDirection(baseX, baseY, movementMode)
    local grade = 0.0

    if movementMode == 1 or movementMode == 2 then
        grade = terrainGrade
    end

    local length = math.sqrt(1.0 + (grade * grade))
    lastDirectionX = baseX / length
    lastDirectionY = baseY / length
    lastDirectionZ = grade / length
end

local function rememberPostOffsetLocation(hero)
    local x, y, z = getActorLocation(hero)
    if x == nil then
        return false
    end

    lastPostOffsetX = x
    lastPostOffsetY = y
    lastPostOffsetZ = z
    return true
end

local function tick(stepMs)
    -- Readiness State Machine: verify host hero & movement component across N consecutive samples before arming injection.
    if not startupCompatReady then
        local hero = resolveHero()
        local movement = nil
        if isValidObj(hero) then
            movement = resolveMovementComponent(hero)
        end

        if isValidObj(hero) and isValidObj(movement) then
            stabilitySamples = stabilitySamples + 1
            if stabilitySamples >= STABILITY_SAMPLES_REQUIRED then
                startupCompatReady = true
                quietUntil = math.max(quietUntil, os.clock() + 0.5)
                postTransitionGraceMs = POST_TRANSITION_GRACE_MS
                print(string.format(
                    "[SpeedMod] READINESS STABLE | Hero & movement verified across %d samples | Movement armed",
                    STABILITY_SAMPLES_REQUIRED
                ))
            end
        else
            stabilitySamples = 0
        end
        return
    end

    -- Dynamic Restart Quarantine: automatically releases as soon as world stability is re-verified across samples.
    if restartPending then
        local hero = resolveHero()
        local movement = nil
        if isValidObj(hero) then
            movement = resolveMovementComponent(hero)
        end

        local clockPassed = os.clock() >= restartReleaseClock
        local worldStable = isValidObj(hero) and isValidObj(movement)

        if worldStable then
            stabilitySamples = stabilitySamples + 1
        else
            stabilitySamples = 0
        end

        if clockPassed or stabilitySamples >= STABILITY_SAMPLES_REQUIRED then
            restartPending = false
            onWorldReady("ClientRestart(stability-readiness)", 0.0)
            return
        end
        return
    end

    if mapLeaving then
        return
    end

    if not CONFIG.ENABLED then
        if not disabledStateReported then
            disabledStateReported = true
            warn("DISABLED | runtime ENABLED=false; speed and jump are inactive")
        end
        restoreJumpVelocity()
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = IDLE_TICK_MS
        return
    end
    disabledStateReported = false

    if os.clock() < quietUntil then
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = IDLE_TICK_MS
        return
    end

    if postTransitionGraceMs > 0 then
        postTransitionGraceMs = math.max(
            0,
            postTransitionGraceMs - stepMs
        )
        nextPollMs = IDLE_TICK_MS
        lastClockSeconds = nil
        return
    end

    if teleportGraceMs > 0 then
        teleportGraceMs = math.max(0, teleportGraceMs - stepMs)
        clearAcceleration()
        lastClockSeconds = nil
        return
    end

    local hero = resolveHero()
    if not isValidObj(hero) then
        if not heroWaitingReported then
            heroWaitingReported = true
            warn("WAITING FOR HERO | movement poll remains active")
        end
        cachedHero = nil
        cachedMovement = nil
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = LOADING_POLL_MS
        return
    end
    heroWaitingReported = false

    local movement, movementError = resolveMovementComponent(hero)
    if not isValidObj(movement) then
        if not movementErrorReported then
            movementErrorReported = true
            warn("WAITING FOR MOVEMENT | " .. tostring(movementError) ..
                " | poll remains active")
        end
        cachedHero = nil
        cachedMovement = nil
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = LOADING_POLL_MS
        return
    end
    movementErrorReported = false
    -- Jump height is independent of the sprint boost and remains active during
    -- combat lock. It is still restored when the Speed mod itself is disabled.
    applyJumpHeight(hero, movement)

    -- Horizontal sprint detection is bound to the concrete hero CDO, never to
    -- the first live MaxWalkSpeed sample. A checkpoint may resume while Sprint
    -- is already held; learning that live value would misclassify the sprint
    -- cap as the jog baseline and permanently suppress the boost.
    if not bindCanonicalMovementBaseline(hero, movement) then
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = LOADING_POLL_MS
        return
    end

    local combatSignal, combatReason = getCombatEngagementSignal(hero)

    if combatSignal then
        combatExitMs = 0

        if combatLockActive then
            combatLockReason = combatReason
            clearAcceleration()
            lastClockSeconds = nil
            nextPollMs = IDLE_TICK_MS
            return
        end

        combatEnterMs = combatEnterMs + stepMs

        if combatEnterMs >= COMBAT_ENTER_CONFIRM_MS then
            combatLockActive = true
            combatLockReason = combatReason
            combatEnterMs = 0

            clearAcceleration()
            lastClockSeconds = nil
            nextPollMs = IDLE_TICK_MS
            print("[SpeedMod] COMBAT LOCK | boost disabled | " .. tostring(combatReason))
            return
        end
    else
        combatEnterMs = 0

        if combatLockActive then
            combatExitMs = combatExitMs + stepMs

            -- Hold the lock through brief target/combat-state dropouts. This
            -- prevents lock/clear spam when enemies or animation states flicker.
            if combatExitMs < COMBAT_EXIT_CONFIRM_MS then
                clearAcceleration()
                lastClockSeconds = nil
                nextPollMs = IDLE_TICK_MS
                return
            end

            combatLockActive = false
            combatExitMs = 0
            combatLockReason = nil

            -- Require one clean native-movement sample before boost can rebuild.
            clearAcceleration()
            lastClockSeconds = nil
            nextPollMs = IDLE_TICK_MS
            print("[SpeedMod] COMBAT CLEAR | traversal boost available")
            return
        end

        combatExitMs = 0
    end

    -- MOVE_None is generally used while movement is disabled or while the
    -- actor is being repositioned. Never inject movement in that state.
    local movementMode = readNumber(movement, "MovementMode")
    if movementMode == 0 then
        clearAcceleration()
        lastClockSeconds = nil
        return
    end

    local locationX, locationY, locationZ = getActorLocation(hero)
    if locationX == nil then
        cachedHero = nil
        cachedMovement = nil
        clearAcceleration()
        lastClockSeconds = nil
        return
    end

    local didTeleport, teleportReason = teleportDetected(
        movement,
        locationX,
        locationY,
        locationZ
    )

    lastLocationX = locationX
    lastLocationY = locationY
    lastLocationZ = locationZ

    if didTeleport then
        clearAcceleration()
        teleportGraceMs = TELEPORT_GRACE_MS
        lastClockSeconds = nil
        log("Acceleration paused: " .. tostring(teleportReason))
        return
    end

    local velocityX, velocityY, horizontalSpeed =
        getHorizontalVelocity(movement)
    local accelerationX, accelerationY, accelerationMagnitude =
        getHorizontalAcceleration(movement)

    local baseDirectionX = nil
    local baseDirectionY = nil

    if horizontalSpeed >= MIN_MOVING_SPEED then
        baseDirectionX = velocityX / horizontalSpeed
        baseDirectionY = velocityY / horizontalSpeed
    elseif accelerationMagnitude >= MIN_INPUT_ACCELERATION then
        baseDirectionX = accelerationX / accelerationMagnitude
        baseDirectionY = accelerationY / accelerationMagnitude
    elseif lastDirectionX ~= nil and lastDirectionY ~= nil then
        local horizontalLength = math.sqrt(
            (lastDirectionX * lastDirectionX) +
            (lastDirectionY * lastDirectionY)
        )
        if horizontalLength > 0.0001 then
            baseDirectionX = lastDirectionX / horizontalLength
            baseDirectionY = lastDirectionY / horizontalLength
        end
    end

    local nativeTerrainDistance = updateTerrainGrade(
        movementMode,
        locationX,
        locationY,
        locationZ,
        baseDirectionX,
        baseDirectionY
    )

    local measuredDt = getMeasuredDeltaSeconds()
    if measuredDt == nil then
        return
    end
    local measuredStepMs = measuredDt * 1000.0

    local currentCap = readNumber(movement, "MaxWalkSpeed")
    if currentCap == nil or currentCap <= 0.0 then
        if not movementCapErrorReported then
            movementCapErrorReported = true
            warn("MOVEMENT CAP ERROR | live MaxWalkSpeed is unavailable; "
                .. "horizontal boost is fail-closed")
        end
        clearAcceleration()
        lastClockSeconds = nil
        nextPollMs = LOADING_POLL_MS
        return
    end
    movementCapErrorReported = false

    local sprintSignal, detector =
        detectNativeSprint(currentCap, horizontalSpeed)

    local sprinting = sprintSignal
    local hardJogRelease = false
    local jogReference = nativeJogCap

    if wasSprinting and
       jogReference and jogReference > 0 and
       (movementMode == 1 or movementMode == 2) and
       horizontalSpeed >= MIN_MOVING_SPEED and
       horizontalSpeed <= (jogReference * JOG_RELEASE_RATIO) and
       accelerationMagnitude >= MIN_INPUT_ACCELERATION then
        jogReleaseMs = jogReleaseMs + measuredStepMs

        if jogReleaseMs >= JOG_RELEASE_CONFIRM_MS then
            hardJogRelease = true
            sprinting = false
            detector = "native jog release"
        end
    else
        jogReleaseMs = 0
    end

    if hardJogRelease then
        sprintDropoutMs = 0
    elseif sprintSignal then
        sprintDropoutMs = 0
    elseif wasSprinting and
           (horizontalSpeed >= MIN_MOVING_SPEED or
            accelerationMagnitude >= MIN_INPUT_ACCELERATION or
            nativeTerrainDistance >= MIN_NATIVE_TERRAIN_SAMPLE) then
        sprintDropoutMs = sprintDropoutMs + measuredStepMs

        if sprintDropoutMs <= SPRINT_DROPOUT_GRACE_MS then
            sprinting = true
            detector = "dropout grace"
        end
    else
        sprintDropoutMs = 0
    end

    if sprinting then
        nextPollMs = ACTIVE_TICK_MS

        if not wasSprinting then
            -- Do not spend the first second feeling almost stock-speed.
            extraMultiplier = INITIAL_EXTRA_MULTIPLIER
            stableSprintSpeed = nil
            log("Native sprint detected by " .. detector)
            if not boostReadyReported then
                boostReadyReported = true
                warn(string.format(
                    "BOOST READY | detector=%s | start=%.2fx | max=%.2fx",
                    tostring(detector),
                    CONFIG.START_SPEED,
                    CONFIG.MAX_SPEED
                ))
            end
        else
            extraMultiplier = math.min(
                extraMultiplier +
                    (ACCELERATION_MULTIPLIER_PER_SECOND * measuredDt),
                MAX_EXTRA_MULTIPLIER
            )
        end

        if baseDirectionX ~= nil and baseDirectionY ~= nil then
            updateThreeDimensionalDirection(
                baseDirectionX,
                baseDirectionY,
                movementMode
            )
        end

        local referenceSpeed = updateStableSprintSpeed(
            currentCap,
            horizontalSpeed
        )

        local movementEvidence =
            horizontalSpeed >= MIN_MOVING_SPEED or
            accelerationMagnitude >= MIN_INPUT_ACCELERATION or
            nativeTerrainDistance >= MIN_NATIVE_TERRAIN_SAMPLE

        if lastDirectionX ~= nil and
           lastDirectionY ~= nil and
           movementEvidence then
            local extraDistance =
                referenceSpeed * extraMultiplier * measuredDt

            local deltaZ = clamp(
                lastDirectionZ * extraDistance,
                -MAX_DOWNWARD_OFFSET_PER_TICK,
                MAX_UPWARD_OFFSET_PER_TICK
            )

            if not addSweptOffset(
                hero,
                lastDirectionX * extraDistance,
                lastDirectionY * extraDistance,
                deltaZ
            ) then
                clearAcceleration()
                if not rememberPostOffsetLocation(hero) then cachedHero = nil cachedMovement = nil end
                return
            end

            if not rememberPostOffsetLocation(hero) then
                cachedHero = nil
                cachedMovement = nil
                clearAcceleration()
                return
            end
        else
            lastPostOffsetX = locationX
            lastPostOffsetY = locationY
            lastPostOffsetZ = locationZ
        end
    else
        if wasSprinting then
            log("Sprint ended after detector grace; acceleration reset")
        end

        clearAcceleration()
        lastPostOffsetX = locationX
        lastPostOffsetY = locationY
        lastPostOffsetZ = locationZ
    end

    wasSprinting = sprinting

    elapsedMs = elapsedMs + measuredStepMs
    if DEBUG_LOGS and elapsedMs - lastStatusLogMs >= 1000 then
        lastStatusLogMs = elapsedMs
        log(
            "speed=" .. string.format("%.1f", horizontalSpeed) ..
            " cap=" .. tostring(currentCap) ..
            " jogCap=" .. tostring(nativeJogCap) ..
            " sprint=" .. tostring(sprinting) ..
            " detector=" .. detector ..
            " dropoutMs=" .. string.format("%.0f", sprintDropoutMs) ..
            " reference=" ..
                (stableSprintSpeed and
                    string.format("%.1f", stableSprintSpeed) or "nil") ..
            " extra=" .. string.format("%.2f", extraMultiplier) ..
            " dt=" .. string.format("%.3f", measuredDt)
        )
    end
end

local function poll()
    local delayMs = LOADING_POLL_MS

    if not restartPending and not mapLeaving then
        delayMs = nextPollMs
    end

    -- Back-pressure: never stack callbacks while the game thread is busy.
    -- During restart quarantine we still queue the lightweight tick so it can
    -- release the quarantine after the clock deadline; movement remains blocked.
    if not tickQueued then
        tickQueued = true

        local queuedGeneration = lifecycleGeneration
        local queuedStepMs = delayMs

        ExecuteInGameThread(function()
            tickQueued = false

            if (mapLeaving and not restartPending) or
               queuedGeneration ~= lifecycleGeneration then
                return
            end

            local handler = debug and debug.traceback or tostring
            local ok, err = xpcall(function()
                tick(queuedStepMs)
            end, handler)

            if not ok then
                warn("Tick error:")
                print(tostring(err))
                cachedHero = nil
                cachedMovement = nil
                clearAcceleration()
                lastClockSeconds = nil
            end
        end)
    end

    ExecuteWithDelay(delayMs, poll)
end

local function requireLifecycleHook(functionPath, callback, label)
    if type(functionPath) ~= "string" or functionPath == ""
        or type(callback) ~= "function"
        or type(label) ~= "string" or label == "" then
        CONFIG.ENABLED = false
        error("[SpeedMod] HOOK ERROR | invalid canonical hook registration")
    end
    local ok, err = pcall(function()
        RegisterHook(functionPath, callback)
    end)

    if not ok then
        CONFIG.ENABLED = false
        error("[SpeedMod] HOOK ERROR | " .. label .. ": " .. tostring(err))
    end
    print("[SpeedMod] HOOKED | " .. label)
end

local function registerLifecycleHooks()
-- True world-travel events: stop all injected movement until a reliable
-- world-ready signal arrives.
requireLifecycleHook(
    "/Script/Engine.PlayerController:ClientTravelInternal",
    function()
        beginTravel("ClientTravelInternal")
    end,
    "ClientTravelInternal"
)

requireLifecycleHook(
    "/Script/Engine.PlayerController:ClientTravel",
    function()
        beginTravel("ClientTravel")
    end,
    "ClientTravel"
)

requireLifecycleHook(
    "/Script/Engine.PlayerController:ClientPrepareMapChange",
    function()
        beginTravel("ClientPrepareMapChange")
    end,
    "ClientPrepareMapChange"
)

requireLifecycleHook(
    "/Script/ROD.RODPlayerState:ServerDecideTown",
    function()
        beginTravel("ServerDecideTown")
    end,
    "ServerDecideTown"
)

requireLifecycleHook(
    "/Script/ROD.RODPlayerState:ServerDecideFastTravel",
    function()
        -- Checkpoint fast travel repositions the existing world and does not
        -- necessarily emit ClientRestart. Treating it as world replacement
        -- left mapLeaving latched forever and disabled only the horizontal
        -- injector while the previously written jump value appeared healthy.
        beginQuietOnly(
            "ServerDecideFastTravel(same-world)",
            QUEST_QUIET_SEC
        )
    end,
    "ServerDecideFastTravel(same-world)"
)

requireLifecycleHook(
    "/Script/ROD.RODPlayerState:ServerShowQuestResult",
    function()
        beginTravel("ServerShowQuestResult")
    end,
    "ServerShowQuestResult"
)

-- Quest teleport-out is a VFX/transition cue in the proven companion mods.
-- Pause briefly and clear references, but do not enter an indefinite
-- map-leaving state unless a real travel hook also fires.
requireLifecycleHook(
    "/Script/ROD.RODPlayerState:ServerNotifyQuestTeleportOut",
    function()
        beginQuietOnly(
            "ServerNotifyQuestTeleportOut",
            QUEST_QUIET_SEC
        )
    end,
    "ServerNotifyQuestTeleportOut"
)

-- Sleep/rest can emit several overlapping callbacks for one transition.
-- Debounce them so only the first callback clears movement state.
for _, sleepHook in ipairs({
    {
        "/Script/ROD.RODHeroCharacter:ServerSleepDirection",
        "ServerSleepDirection"
    },
    {
        "/Script/ROD.RODGameState:StartSleepDirection",
        "StartSleepDirection"
    },
    {
        "/Script/ROD.RODInGamePlayerController:ClientStartSleepFade",
        "ClientStartSleepFade"
    },
    {
        "/Script/ROD.RODInGamePlayerController:StartSleepFade",
        "StartSleepFade"
    }
}) do
    local hookPath = sleepHook[1]
    local hookLabel = sleepHook[2]

    requireLifecycleHook(
        hookPath,
        function()
            beginSleepQuiet(hookLabel)
        end,
        hookLabel
    )
end

-- ClientRestart can be shared by several mods and also fires during quest-start
-- world replacement. Keep this hook intentionally minimal: no object access, no
-- state reset, and no ExecuteWithDelay callback. The normal tick loop performs
-- the reset after a quarantine window, safely away from the native callback chain.
requireLifecycleHook(
    "/Script/Engine.PlayerController:ClientRestart",
    function()
        restartCompatToken = restartCompatToken + 1
        restartPending = true
        restartReleaseClock = math.max(
            restartReleaseClock,
            os.clock() + MAX_RESTART_QUARANTINE_SEC
        )
    end,
    "ClientRestart(quarantine)"
)

end

-- Lifecycle Registration:
-- Arm lifecycle hooks immediately upon loading so map transitions and player state events are captured.
registerLifecycleHooks()
startupCompatReady = false
print(
    "[SpeedMod] COMPAT READY | lifecycle hooks armed immediately | " ..
    "waiting for hero stability (3 samples)"
)

local function consoleReply(ar, message)
    local text = "[SpeedMod] " .. tostring(message)
    print(text)

    if ar and type(ar) == "userdata" then
        pcall(function()
            ar:Log(text)
        end)
    end
end

local function resetLiveAcceleration()
    clearAcceleration()
    lastClockSeconds = nil
end

--========================================================--
--                RUNTIME SETTINGS BRIDGE                 --
--========================================================--
-- Lets the in-game Mods menu change these values without a restart. The bridge
-- hands over the merged config.lua + runtime.lua table. The same strict
-- validator is used for startup and live changes.
do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
            modName = "SpeedMod",
            scriptDir = SCRIPT_DIRECTORY,
            pollMs = 750,
            load = function(external)
                local applied, configError = applyExternalConfig(external)
                if not applied then
                    CONFIG.ENABLED = false
                    error(configError)
                end
            end,
            apply = function()
                applySpeedConfig()
                -- A live ramp built from the old multipliers would otherwise keep
                -- pushing the player at the previous speed until sprint ends.
                resetLiveAcceleration()
                warn("LIVE CONFIG | " .. speedConfigSummary())
                applyLiveJumpSetting()
            end,
            fail = function(message)
                CONFIG.ENABLED = false
                restoreJumpVelocity()
                clearAcceleration()
                warn("FAIL-CLOSED | " .. tostring(message))
            end,
            log = function(message) print("[SpeedMod] " .. tostring(message) .. "\n") end,
    })
    if attachment == nil then
        CONFIG.ENABLED = false
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

local function runSpeedModCommand(params, ar)
    local subcommand = params and params[1] or nil

    if subcommand ~= nil then
        subcommand = string.lower(tostring(subcommand))
    end

    if subcommand == nil or subcommand == "show" or subcommand == "status" then
        consoleReply(ar, "CONFIG | " .. speedConfigSummary())
        return
    end

    consoleReply(ar, "Read-only command. Use: speedmod show")
end

local commandOk, commandError = pcall(function()
    RegisterConsoleCommandHandler("speedmod", function(_fullCommand, params, ar)
        local handler = debug and debug.traceback or tostring
        local ok, err = xpcall(function()
            runSpeedModCommand(params or {}, ar)
        end, handler)

        if not ok then
            consoleReply(ar, "command error: " .. tostring(err))
        end
        return true
    end)
end)

if commandOk then
    print("[SpeedMod] Console command ready: speedmod show")
else
    warn("Console command unavailable: " .. tostring(commandError))
end

ExecuteWithDelay(100, poll)
