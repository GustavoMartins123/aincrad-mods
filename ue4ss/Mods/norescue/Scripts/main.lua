-- norescue — real falls in EoA: no edge-rescue nudge, no fall-death teleport.
--
-- Two levers, both the game's own data (mechanism fully mapped in
-- research/fall-death-mechanic.md, verified in-game 2026-07-13):
--  1. ARODAvatarCharacter::SetEnablePreventFalling(false) — turns off the
--     predictive edge-rescue (URODGA_PreventFalling steering you off ledges).
--  2. URODGameConfig.DeathLandingHeight (shipped 780) -> huge — landings are
--     bucketed into ELandingLevel tiers by height; the Death tier applies the
--     FallDeath tag and runs the DeathTeleport (collapse + warp to a
--     breadcrumb). Unreachable tier = falls just land. Middle/High are left
--     alone so hard-landing animations still play.
--
-- Fall-only by design: water drowning (MiddleWaterDepth/DeepWaterDepth) and
-- pit/out-of-bounds teleports use separate thresholds and fade-event types —
-- this mod never touches them.
--
-- Perf: no per-tick polling. ClientRestart invalidates map-owned references;
-- a 5s safety net does ONE cached-object validity check and ONE
-- cached float read per tick — object-table scans (FindFirstOf/FindAllOf)
-- happen only when a cache is invalid (spawn, zone load, config rebuild).
--
-- Dead ends — documented so they aren't retried: AbortDeathTeleportAnimation
-- executes but cannot stop the relocation (and hooks on the DeathTeleport
-- dispatch fire for Drown/pit types too); tuning the PreventFalling GA's
-- FindFloorHeight/AllowableHeight applies but the classifier never reads it.
print("[norescue] loading…")

local DEFAULTS = {
    ENABLED = true,
    SAFETY_NET_MS = 5000,
    DEATH_LANDING_HEIGHT = 1000000000.0,
    DEBUG_LOGS = false,
}

local function scriptDir()
    local s = (debug.getinfo(1, "S") or {}).source or ""
    if s:sub(1, 1) == "@" then s = s:sub(2) end
    local directory = s:match("^(.*[\\/])")
    if directory == nil then
        error("canonical norescue Scripts directory is unavailable")
    end
    return directory
end
local SCRIPT_DIR = scriptDir()
local CONFIG = {}
for k, v in pairs(DEFAULTS) do CONFIG[k] = v end

local function applyExternalConfig(c)
    if type(c) ~= "table" then error("settings must be a table") end
    for key in pairs(c) do
        if DEFAULTS[key] == nil then error("unknown setting: " .. tostring(key)) end
    end
    if type(c.ENABLED) ~= "boolean" then error("ENABLED must be boolean") end
    if type(c.SAFETY_NET_MS) ~= "number"
        or c.SAFETY_NET_MS < 500 or c.SAFETY_NET_MS > 60000 then
        error("SAFETY_NET_MS must be between 500 and 60000")
    end
    if type(c.DEATH_LANDING_HEIGHT) ~= "number"
        or c.DEATH_LANDING_HEIGHT < 1000
        or c.DEATH_LANDING_HEIGHT > 1000000000000 then
        error("DEATH_LANDING_HEIGHT must be between 1000 and 1000000000000")
    end
    if type(c.DEBUG_LOGS) ~= "boolean" then error("DEBUG_LOGS must be boolean") end

    CONFIG.ENABLED = c.ENABLED
    CONFIG.SAFETY_NET_MS = c.SAFETY_NET_MS
    CONFIG.DEATH_LANDING_HEIGHT = c.DEATH_LANDING_HEIGHT
    CONFIG.DEBUG_LOGS = c.DEBUG_LOGS
end

local MOD_MENU_BRIDGE = (function()
    local path = SCRIPT_DIR .. "../../shared/ModMenuBridge.lua"
    local ok, bridge = pcall(function() return dofile(path) end)
    if not ok then error("canonical ModMenuBridge load failed: " .. tostring(bridge)) end
    if type(bridge) ~= "table" then
        error("canonical ModMenuBridge did not return a table")
    end
    return bridge
end)()

do
    local external, _, info =
        MOD_MENU_BRIDGE.readSettings("norescue", SCRIPT_DIR)
    if external == nil then
        error("canonical settings load failed: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    applyExternalConfig(external)
end

local function dbg(m) if CONFIG.DEBUG_LOGS then print("[norescue] " .. tostring(m)) end end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

------------------------------------------------------------------- hero switch
local heroCache, switchedHeroKey
local heroWaitingReported = false
local heroReadyReported = false
local heroLookupErrorReported = false
local heroIdentityErrorReported = false
local heroSwitchErrorReported = false

local function resolveHero()
    if valid(heroCache) then return heroCache end
    heroCache = nil

    local found, hero = pcall(FindFirstOf, "RODWorldHeroCharacter")
    if not found then
        return nil, "FindFirstOf(RODWorldHeroCharacter) failed: " .. tostring(hero)
    end
    if not valid(hero) then return nil, nil end

    local hostResolved, isHost = pcall(function() return hero:IsHostHero() end)
    if not hostResolved then
        return nil, "RODWorldHeroCharacter:IsHostHero failed: " .. tostring(isHost)
    end
    if isHost ~= true then return nil, nil end

    heroCache = hero
    return heroCache, nil
end

local function applyHeroSwitch()
    local hero, lookupError = resolveHero()
    if lookupError ~= nil then
        if not heroLookupErrorReported then
            heroLookupErrorReported = true
            print("[norescue] HERO LOOKUP ERROR | " .. tostring(lookupError))
        end
        return false
    end
    heroLookupErrorReported = false

    if not valid(hero) then
        if not heroWaitingReported then
            heroWaitingReported = true
            print("[norescue] WAITING FOR HERO | safety net remains active")
        end
        return false
    end

    if heroWaitingReported or not heroReadyReported then
        print("[norescue] HERO READY | safety net acquired the current hero")
    end
    heroWaitingReported = false
    heroReadyReported = true

    local identityResolved, heroKey = pcall(function() return hero:GetFullName() end)
    if not identityResolved or type(heroKey) ~= "string" or heroKey == "" then
        if not heroIdentityErrorReported then
            heroIdentityErrorReported = true
            print("[norescue] HERO IDENTITY ERROR | canonical object name is unavailable")
        end
        return false
    end
    heroIdentityErrorReported = false

    if switchedHeroKey == heroKey then return true end
    local switched, switchError = pcall(function()
        hero:SetEnablePreventFalling(false)
    end)
    if switched then
        switchedHeroKey = heroKey
        heroSwitchErrorReported = false
        print("[norescue] edge-rescue disabled for the current hero")
        return true
    else
        switchedHeroKey = nil
        if not heroSwitchErrorReported then
            heroSwitchErrorReported = true
            print("[norescue] EDGE RESCUE ERROR | SetEnablePreventFalling failed: "
                .. tostring(switchError))
        end
        return false
    end
end

------------------------------------------------------------------- threshold
local gcCache
-- Captured the first time the threshold is overwritten, so switching the mod off
-- in-game can hand the shipped value (780) back instead of guessing at it.
local originalLandingHeight
local gameConfigWaitingReported = false
local gameConfigReadyReported = false

local function applyThreshold()
    -- cheap path: cached object still valid and still carrying our value
    if valid(gcCache) then
        local readOk, cur = pcall(function()
            return tonumber(gcCache.DeathLandingHeight)
        end)
        if not readOk or cur == nil then
            error("cached RODGameConfig.DeathLandingHeight read failed: " ..
                tostring(cur))
        end
        if cur == CONFIG.DEATH_LANDING_HEIGHT then return true end
    else
        gcCache = nil
    end
    -- repair path: (re)find every config object and set the threshold
    local ok, list = pcall(function() return FindAllOf("RODGameConfig") end)
    if not ok then error("FindAllOf(RODGameConfig) failed: " .. tostring(list)) end
    if list == nil then
        if not gameConfigWaitingReported then
            gameConfigWaitingReported = true
            print("[norescue] WAITING FOR GAME CONFIG | safety net remains active")
        end
        return false
    end
    if type(list) ~= "table" then
        error("FindAllOf(RODGameConfig) returned " .. type(list) ..
            " instead of a table")
    end
    local applied = 0
    for _, gc in ipairs(list) do
        if valid(gc) then
            local readOk, before = pcall(function()
                return tonumber(gc.DeathLandingHeight)
            end)
            if not readOk or before == nil then
                error("RODGameConfig.DeathLandingHeight read failed: " ..
                    tostring(before))
            end
            if originalLandingHeight == nil and before ~= nil
                and before ~= CONFIG.DEATH_LANDING_HEIGHT then
                originalLandingHeight = before
            end
            local writeOk, writeError = pcall(function()
                gc.DeathLandingHeight = CONFIG.DEATH_LANDING_HEIGHT
            end)
            if not writeOk then
                error("RODGameConfig.DeathLandingHeight write failed: " ..
                    tostring(writeError))
            end
            gcCache = gc
            applied = applied + 1
            print(string.format("[norescue] DeathLandingHeight %s -> %.0f",
                tostring(before), CONFIG.DEATH_LANDING_HEIGHT))
        end
    end
    if applied == 0 then
        if not gameConfigWaitingReported then
            gameConfigWaitingReported = true
            print("[norescue] WAITING FOR GAME CONFIG | safety net remains active")
        end
        return false
    end
    if gameConfigWaitingReported or not gameConfigReadyReported then
        print("[norescue] GAME CONFIG READY | fall threshold acquired")
    end
    gameConfigWaitingReported = false
    gameConfigReadyReported = true
    return true
end

-- Both levers are plain writes, so switching the mod off in-game just puts the
-- game's own values back. Anything we never touched is left alone.
local function revertAll()
    local hero, heroError = resolveHero()
    if heroError ~= nil then error(heroError) end
    if valid(hero) then
        local switched, switchError = pcall(function()
            hero:SetEnablePreventFalling(true)
        end)
        if not switched then
            error("SetEnablePreventFalling(true) failed: " .. tostring(switchError))
        end
        switchedHeroKey = nil
    end
    if originalLandingHeight ~= nil then
        local ok, list = pcall(function() return FindAllOf("RODGameConfig") end)
        if not ok then
            error("FindAllOf(RODGameConfig) failed while reverting: " ..
                tostring(list))
        end
        if list ~= nil and type(list) ~= "table" then
            error("FindAllOf(RODGameConfig) returned " .. type(list) ..
                " while reverting")
        end
        if type(list) == "table" then
            for _, gc in ipairs(list) do
                if valid(gc) then
                    local writeOk, writeError = pcall(function()
                        gc.DeathLandingHeight = originalLandingHeight
                    end)
                    if not writeOk then
                        error("DeathLandingHeight revert failed: " ..
                            tostring(writeError))
                    end
                end
            end
        end
        gcCache = nil
    end
end

------------------------------------------------------------------- drivers
-- nil until the first pass, then tracks which direction was last applied so the
-- safety net can drive an in-game toggle both ways without repeating itself.
local modActive

local function applyAll()
    if not CONFIG.ENABLED then
        if modActive ~= true then return end
        local ok, err = xpcall(revertAll, debug and debug.traceback or tostring)
        if not ok then print("[norescue] revert error: " .. tostring(err)) end
        modActive = false
        print("[norescue] switched off in-game; falls are back to vanilla")
        return
    end

    local ok, err = xpcall(function()
        local heroReady = applyHeroSwitch()
        local configReady = applyThreshold()
        if not heroReady or not configReady then return false end
        return true
    end, debug and debug.traceback or tostring)
    if not ok then
        print("[norescue] apply error: " .. tostring(err))
        return
    end
    if err ~= true then return end
    if modActive == false then print("[norescue] switched back on in-game") end
    modActive = true
end

local function safetyNet()
    ExecuteInGameThread(applyAll)
    ExecuteWithDelay(CONFIG.SAFETY_NET_MS, safetyNet)
end

local RETRY_DELAYS_MS = { 100, 250, 500, 1000, 2000 }

local function applyProgressiveRetry(index)
    index = index or 1
    ExecuteInGameThread(function()
        applyAll()
        if modActive ~= true and index <= #RETRY_DELAYS_MS then
            ExecuteWithDelay(RETRY_DELAYS_MS[index], function()
                applyProgressiveRetry(index + 1)
            end)
        end
    end)
end

local function onRespawnPath()
    heroCache, switchedHeroKey, gcCache = nil, nil, nil
    heroWaitingReported = false
    heroReadyReported = false
    heroLookupErrorReported = false
    heroIdentityErrorReported = false
    heroSwitchErrorReported = false
    gameConfigWaitingReported = false
    gameConfigReadyReported = false
    applyProgressiveRetry(1)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", onRespawnPath)

------------------------------------------------------------ runtime settings
-- Lets the in-game Mods menu flip ENABLED or retune the threshold without a
-- restart. applyAll already handles both directions, so the bridge only has to
-- reload the values and poke it.
do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = "norescue",
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = applyExternalConfig,
        apply = applyAll,
        fail = function(reason)
            CONFIG.ENABLED = false
            local ok, revertError = xpcall(revertAll,
                debug and debug.traceback or tostring)
            if not ok then
                error("fail-closed revert failed after " .. tostring(reason) ..
                    ": " .. tostring(revertError))
            end
            modActive = false
        end,
        log = function(message) print("[norescue] " .. tostring(message)) end,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

applyProgressiveRetry(1)
ExecuteWithDelay(CONFIG.SAFETY_NET_MS, safetyNet)
print(string.format("[norescue] loaded | enabled=%s | DeathLandingHeight=%.0f | safety net %dms",
    tostring(CONFIG.ENABLED), CONFIG.DEATH_LANDING_HEIGHT, CONFIG.SAFETY_NET_MS))
