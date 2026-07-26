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
-- Perf: no per-tick polling. Event hooks (ClientRestart, LoadMap) do the
-- re-apply; a 5s safety net does ONE cached-object validity check and ONE
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
    DEATH_LANDING_HEIGHT = 1000000000.0, -- 0 = leave the game's threshold alone
    DEBUG_LOGS = false,
}

local function scriptDir()
    local s = (debug.getinfo(1, "S") or {}).source or ""
    if s:sub(1, 1) == "@" then s = s:sub(2) end
    return s:match("^(.*[\\/])") or "./"
end
local CONFIG = {}
for k, v in pairs(DEFAULTS) do CONFIG[k] = v end

-- Unknown keys and type mismatches are dropped rather than trusted. This runs
-- again on every in-game change, so it is also the guard against a bad value
-- arriving from the Mods menu.
local function applyExternalConfig(c)
    if type(c) ~= "table" then return end
    for k, v in pairs(c) do
        if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then CONFIG[k] = v end
    end
end

do
    local ok, c = pcall(function() return dofile(scriptDir() .. "config.lua") end)
    if ok then applyExternalConfig(c) end
end

local function dbg(m) if CONFIG.DEBUG_LOGS then print("[norescue] " .. tostring(m)) end end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

------------------------------------------------------------------- hero switch
local heroCache, switchedHero

local function resolveHero()
    if valid(heroCache) then return heroCache end
    heroCache = nil
    for _, n in ipairs({ "RODWorldHeroCharacter", "RODHeroCharacter", "BP_RODWorldHeroCharacter_C" }) do
        local h = FindFirstOf(n)
        if valid(h) then
            local ok, isHost = pcall(function() return h:IsHostHero() end)
            if not ok or isHost then heroCache = h; return h end
        end
    end
    return nil
end

local function applyHeroSwitch()
    local hero = resolveHero()
    if not valid(hero) then return end
    if switchedHero == hero then return end
    if pcall(function() hero:SetEnablePreventFalling(false) end) then
        switchedHero = hero
        print("[norescue] edge-rescue disabled for the current hero")
    else
        switchedHero = nil
        dbg("SetEnablePreventFalling failed; will retry")
    end
end

------------------------------------------------------------------- threshold
local gcCache
-- Captured the first time the threshold is overwritten, so switching the mod off
-- in-game can hand the shipped value (780) back instead of guessing at it.
local originalLandingHeight

local function applyThreshold()
    if CONFIG.DEATH_LANDING_HEIGHT <= 0 then return end
    -- cheap path: cached object still valid and still carrying our value
    if valid(gcCache) then
        local cur
        pcall(function() cur = tonumber(gcCache.DeathLandingHeight) end)
        if cur == CONFIG.DEATH_LANDING_HEIGHT then return end
    else
        gcCache = nil
    end
    -- repair path: (re)find every config object and set the threshold
    local ok, list = pcall(function() return FindAllOf("RODGameConfig") end)
    if not (ok and type(list) == "table") then return end
    for _, gc in ipairs(list) do
        if valid(gc) then
            local before
            pcall(function() before = tonumber(gc.DeathLandingHeight) end)
            if originalLandingHeight == nil and before ~= nil
                and before ~= CONFIG.DEATH_LANDING_HEIGHT then
                originalLandingHeight = before
            end
            if pcall(function() gc.DeathLandingHeight = CONFIG.DEATH_LANDING_HEIGHT end) then
                gcCache = gc
                print(string.format("[norescue] DeathLandingHeight %s -> %.0f",
                    tostring(before), CONFIG.DEATH_LANDING_HEIGHT))
            end
        end
    end
end

-- Both levers are plain writes, so switching the mod off in-game just puts the
-- game's own values back. Anything we never touched is left alone.
local function revertAll()
    local hero = resolveHero()
    if valid(hero) and pcall(function() hero:SetEnablePreventFalling(true) end) then
        switchedHero = nil
    end
    if originalLandingHeight ~= nil then
        local ok, list = pcall(function() return FindAllOf("RODGameConfig") end)
        if ok and type(list) == "table" then
            for _, gc in ipairs(list) do
                if valid(gc) then
                    pcall(function() gc.DeathLandingHeight = originalLandingHeight end)
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
        applyHeroSwitch()
        applyThreshold()
    end, debug and debug.traceback or tostring)
    if not ok then
        print("[norescue] apply error: " .. tostring(err))
        return
    end
    if modActive == false then print("[norescue] switched back on in-game") end
    modActive = true
end

local function safetyNet()
    ExecuteInGameThread(applyAll)
    ExecuteWithDelay(CONFIG.SAFETY_NET_MS, safetyNet)
end

local function onRespawnPath()
    heroCache, switchedHero = nil, nil
    ExecuteWithDelay(1000, function() ExecuteInGameThread(applyAll) end)
end

pcall(function() RegisterLoadMapPreHook(function() heroCache, switchedHero, gcCache = nil, nil, nil end) end)
pcall(function() RegisterLoadMapPostHook(onRespawnPath) end)
pcall(function() RegisterHook("/Script/Engine.PlayerController:ClientRestart", onRespawnPath) end)

------------------------------------------------------------ runtime settings
-- Lets the in-game Mods menu flip ENABLED or retune the threshold without a
-- restart. applyAll already handles both directions, so the bridge only has to
-- reload the values and poke it.
do
    local function loadModMenuBridge()
        local required, bridge = pcall(require, "ModMenuBridge")
        if required and type(bridge) == "table" then return bridge end
        for _, path in ipairs({
            scriptDir() .. "../../shared/ModMenuBridge.lua",
            "Mods/shared/ModMenuBridge.lua",
            "Mods\\shared\\ModMenuBridge.lua",
        }) do
            local ok, result = pcall(function() return dofile(path) end)
            if ok and type(result) == "table" then return result end
        end
        return nil
    end

    local bridge = loadModMenuBridge()
    if bridge ~= nil then
        bridge.attach({
            modName = "norescue",
            scriptDir = scriptDir(),
            load = applyExternalConfig,
            apply = applyAll,
            log = function(message) print("[norescue] " .. tostring(message)) end,
        })
    else
        print("[norescue] ModMenuBridge unavailable; settings apply on restart only")
    end
end

ExecuteWithDelay(2000, function() ExecuteInGameThread(applyAll) end)
ExecuteWithDelay(CONFIG.SAFETY_NET_MS, safetyNet)
print(string.format("[norescue] loaded | enabled=%s | DeathLandingHeight=%.0f | safety net %dms",
    tostring(CONFIG.ENABLED), CONFIG.DEATH_LANDING_HEIGHT, CONFIG.SAFETY_NET_MS))
