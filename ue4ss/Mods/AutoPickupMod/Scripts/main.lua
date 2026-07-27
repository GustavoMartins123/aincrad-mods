-- AutoPickupMod v1.4.1

local MOD_NAME = "AutoPickupMod"
local MOD_VERSION = "v1.4.1"

local GAME_CONFIG_PATHS = {
    "/Game/ROD/DataAssets/GameConfig.Default__GameConfig_C",
}

local CONFIG = {
    PICKUP_RANGE         = 1000,
    ICON_DISPLAY_RANGE   = 1500,
    ENABLED              = true,
    SHOW_PICKUP_UI       = true,
}

-- 훅/상태전환/픽업만 로그 (poll 핫패스 제외). 콘솔: autopickup debug
local DEBUG_HOOKS = false

local function dbg(stage, msg)
    if not DEBUG_HOOKS then return end
    if msg ~= nil then
        print(string.format("[DEBUG] [%s] %s\n", stage, tostring(msg)))
    else
        print(string.format("[DEBUG] [%s]\n", stage))
    end
end

local iconPatchEnabled  = true
local expandOperatable  = true

local pickupInterval    = 0.3

local SETTINGS_SCHEMA = {
    ENABLED = { kind = "boolean" },
    PICKUP_RANGE = { kind = "number", minimum = 100, maximum = 5000 },
    ICON_DISPLAY_RANGE = { kind = "number", minimum = 100, maximum = 5000 },
    SHOW_PICKUP_UI = { kind = "boolean" },
    PICKUP_INTERVAL = { kind = "number", minimum = 0.05, maximum = 2.0 },
    ICON_RANGE_PATCH = { kind = "boolean" },
    EXPAND_OPERATABLE = { kind = "boolean" },
    DEBUG_HOOKS = { kind = "boolean" },
}

local function validatedSettings(external)
    if type(external) ~= "table" then error("settings must be a table") end
    for key in pairs(external) do
        if SETTINGS_SCHEMA[key] == nil then
            error("unknown setting: " .. tostring(key))
        end
    end
    local result = {}
    for key, rule in pairs(SETTINGS_SCHEMA) do
        local value = external[key]
        if rule.kind == "boolean" then
            if type(value) ~= "boolean" then error(key .. " must be boolean") end
        else
            if type(value) ~= "number"
                or value ~= value
                or value == math.huge
                or value == -math.huge
                or value < rule.minimum
                or value > rule.maximum then
                error(string.format(
                    "%s must be between %s and %s",
                    key,
                    tostring(rule.minimum),
                    tostring(rule.maximum)
                ))
            end
        end
        result[key] = value
    end
    return result
end

local function applyExternalConfig(external)
    local settings = validatedSettings(external)
    CONFIG.ENABLED = settings.ENABLED
    CONFIG.SHOW_PICKUP_UI = settings.SHOW_PICKUP_UI
    iconPatchEnabled = settings.ICON_RANGE_PATCH
    expandOperatable = settings.EXPAND_OPERATABLE
    DEBUG_HOOKS = settings.DEBUG_HOOKS
    CONFIG.PICKUP_RANGE = settings.PICKUP_RANGE
    CONFIG.ICON_DISPLAY_RANGE = settings.ICON_DISPLAY_RANGE
    pickupInterval = settings.PICKUP_INTERVAL
end

local SCRIPT_DIRECTORY = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local directory = source:match("^(.*[\\/])")
    if directory == nil then
        error("canonical AutoPickupMod Scripts directory is unavailable")
    end
    return directory
end)()

local MOD_MENU_BRIDGE = (function()
    local path = SCRIPT_DIRECTORY .. "../../shared/ModMenuBridge.lua"
    local ok, bridge = pcall(function() return dofile(path) end)
    if not ok then error("canonical ModMenuBridge load failed: " .. tostring(bridge)) end
    if type(bridge) ~= "table" then
        error("canonical ModMenuBridge did not return a table")
    end
    return bridge
end)()

do
    local settings, _, info =
        MOD_MENU_BRIDGE.readSettings("AutoPickupMod", SCRIPT_DIRECTORY)
    if settings == nil then
        error("canonical settings load failed: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    applyExternalConfig(settings)
end

local NOTIFY_PICKUP_CLASSES = {
    "/Game/ROD/Blueprints/Placement/Gimmick/PickUpItem/BP_PickUpItemBase.BP_PickUpItemBase_C",
}

local VA_PICK_ITEM = 1

local PICKUP_CLASS_PATTERNS = {
    "DropItem",
    "PickUpItem",
    "NatureItem",
}

local GIMMICK_FIND_CLASSES = {
    "BP_PickUpItemBase_C",
    "BP_NatureItemBase_C",
}

local pollLoopActive   = false
local mapLeaving       = false
local pickupQuietUntil = 0
local lastPickupAt     = 0
local gimmickCooldown  = {}
local cooldownPruneTick = 0
local expandedCount    = 0
local lastCandidateTick = 0
local expandedGimmicks = {}
local cachedHero       = nil
local heroWaitingReported = false
local heroReadyReported = false
local heroLookupErrorReported = false
local heroRecheckTick  = 0
local initialScanDone  = false
local nearbyExpanded   = {}
local notifyExpandQueue    = {}
local notifyExpandPending  = {}
local notifyExpandScheduled = false
local nearbyPruneTick      = 0
local originalActionFlagDisplayDist = nil
local notifyDbgBucket = { t = 0, n = 0 }
local lastAppliedTakeItemDist = nil
local lastRangeSkipDbg = 0
local lastOutOfRangeDbg = 0
local lastCapsuleFailDbg = 0
local lastCapsuleOkDbg = { t = 0, n = 0 }
local lastIconDbgKey = nil

local operatedBusy         = false
local OPERATED_BUSY_MS     = 150

local applyOperatableRadius
local onWorldReady
local applyHeroPickupRange
local expandGimmicksInRange
local resolveHero
local getScanRange
local getEffectiveRange
local scheduleIconRangePatch
local startPoll
local runInitialExpandScan
local isValidObj
local getHero
local numField
local TRAVEL_TIMEOUT_MS = 30000
local travelTimeoutId = 0
local travelScanId = 0

local cachedGameConfigList = nil

local function clearWorldRefs()
    dbg("clearWorldRefs/enter")
    cachedHero = nil
    cachedGameConfigList = nil
    heroWaitingReported = false
    heroReadyReported = false
    heroLookupErrorReported = false
    expandedGimmicks = {}
    expandedCount = 0
    gimmickCooldown = {}
    nearbyExpanded = {}
    notifyExpandQueue = {}
    notifyExpandPending = {}
    notifyExpandScheduled = false
    operatedBusy = false
    cooldownPruneTick = 0
    lastCandidateTick = 0
    lastAppliedTakeItemDist = nil
    lastIconDbgKey = nil
    dbg("clearWorldRefs/done")
end

local function scheduleRangeRefresh()
    for _, ms in ipairs({ 300, 1500 }) do
        ExecuteWithDelay(ms, function()
            if mapLeaving then return end
            ExecuteInGameThread(function()
                applyHeroPickupRange(resolveHero())
            end)
        end)
    end
    scheduleIconRangePatch(1500, 2)
end

local function schedulePostRestRangeRefresh()
    expandedGimmicks = {}
    expandedCount = 0
    ExecuteWithDelay(500, function()
        if mapLeaving then return end
        ExecuteInGameThread(function()
            applyHeroPickupRange(resolveHero())
            local hero = resolveHero()
            if isValidObj(hero) and expandOperatable then
                local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
                dbg("schedulePostRestRangeRefresh", string.format("post-rest expand: %d items", n or 0))
            end
        end)
    end)
    scheduleIconRangePatch(1500, 2)
end

local function schedulePostTravelScan()
    travelScanId = travelScanId + 1
    local sid = travelScanId
    ExecuteWithDelay(500, function()
        if sid ~= travelScanId or mapLeaving then return end
        ExecuteInGameThread(function()
            if sid ~= travelScanId or mapLeaving then return end
            local hero = resolveHero()
            if not isValidObj(hero) then return end
            applyHeroPickupRange(hero)
            if expandOperatable then
                expandedGimmicks = {}
                expandedCount = 0
                local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
                dbg("schedulePostTravelScan", string.format("post-travel initial expand: %d gimmicks", n or 0))
            end
        end)
    end)
end

local function endTravelState()
    dbg("endTravelState/enter", string.format("mapLeaving=%s",
        tostring(mapLeaving)))
    mapLeaving = false
    travelTimeoutId = travelTimeoutId + 1
    dbg("endTravelState/done")
end

onWorldReady = function(reason, quietSec)
    dbg("onWorldReady/enter", string.format("reason=%s quietSec=%s mapLeaving=%s",
        tostring(reason or "?"), tostring(quietSec), tostring(mapLeaving)))
    local wasLeaving = mapLeaving
    endTravelState()
    if wasLeaving then
        print(string.format("[%s] travel end (%s) — pickup resumed\n", MOD_NAME, tostring(reason or "?")))
        dbg("onWorldReady/travelEnded", tostring(reason or "?"))
    end

    quietSec = quietSec or 1.5
    pickupQuietUntil = os.clock() + quietSec
    clearWorldRefs()
    initialScanDone = false
    lastPickupAt = 0
    nearbyPruneTick = 0
    heroRecheckTick = 0

    local ok, err = xpcall(function()
        dbg("onWorldReady/setup")
        if not pollLoopActive then startPoll() end
        scheduleRangeRefresh()
        schedulePostTravelScan()
        ExecuteInGameThread(function()
            dbg("onWorldReady/applyRange")
            local hero = resolveHero()
            dbg("onWorldReady/heroValid", tostring(isValidObj(hero)))
            applyHeroPickupRange(hero)
        end)
    end, debug and debug.traceback or tostring)
    if not ok then
        CONFIG.ENABLED = false
        print(string.format("[%s] onWorldReady error: %s\n", MOD_NAME, tostring(err)))
        dbg("onWorldReady/error", tostring(err))
    else
        dbg("onWorldReady/done")
    end
end

local function beginQuietOnly(reason, quietSec)
    dbg("beginQuietOnly/enter", string.format("reason=%s quietSec=%s",
        tostring(reason or "?"), tostring(quietSec)))

    travelScanId = travelScanId + 1
    local sid = travelScanId
    clearWorldRefs()
    initialScanDone = false
    quietSec = quietSec or 4.0
    pickupQuietUntil = os.clock() + quietSec
    pcall(collectgarbage, "collect")
    print(string.format("[%s] quiet %.0fs (%s) — refs cleared, pickup stays on\n",
        MOD_NAME, quietSec, tostring(reason or "?")))
    dbg("beginQuietOnly/done", string.format("quietUntil=%.2f", pickupQuietUntil))

    local afterMs = math.floor(quietSec * 1000) + 400
    ExecuteWithDelay(afterMs, function()
        if sid ~= travelScanId or mapLeaving then return end
        scheduleRangeRefresh()
        ExecuteInGameThread(function()
            if sid ~= travelScanId or mapLeaving then return end
            applyHeroPickupRange(resolveHero())
        end)
        ExecuteWithDelay(2500, function()
            if sid ~= travelScanId or mapLeaving then return end
            ExecuteInGameThread(function()
                if sid ~= travelScanId or mapLeaving then return end
                local hero = resolveHero()
                if not isValidObj(hero) then return end
                if expandOperatable then
                    local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
                    print(string.format("[%s] post-quiet expand: %d items\n", MOD_NAME, n or 0))
                end
            end)
        end)
    end)
end

local function onSleepBegin(reason)
    dbg("onSleepBegin/enter", tostring(reason))
    beginQuietOnly(tostring(reason), 6.0)
    schedulePostRestRangeRefresh()
    dbg("onSleepBegin/done")
end

local function beginTravel(reason)
    dbg("beginTravel/enter", string.format("reason=%s mapLeaving=%s",
        tostring(reason or "?"), tostring(mapLeaving)))
    if mapLeaving then
        dbg("beginTravel/alreadyLeaving")
        return
    end
    mapLeaving = true
    travelScanId = travelScanId + 1
    clearWorldRefs()
    initialScanDone = false
    print(string.format("[%s] travel begin (%s) — pickup paused\n", MOD_NAME, tostring(reason or "?")))
    dbg("beginTravel/paused")

    travelTimeoutId = travelTimeoutId + 1
    local timeoutId = travelTimeoutId
    ExecuteWithDelay(TRAVEL_TIMEOUT_MS, function()
        if not mapLeaving or timeoutId ~= travelTimeoutId then return end
        print(string.format(
            "[%s] TRAVEL ERROR | ClientRestart was not received after %dms; pickup remains paused\n",
            MOD_NAME,
            TRAVEL_TIMEOUT_MS
        ))
    end)
    dbg("beginTravel/done")
end

local function releaseOperatedBusy()
    operatedBusy = false
end

local function beginOperatedBusy()
    operatedBusy = true

    ExecuteWithDelay(OPERATED_BUSY_MS, releaseOperatedBusy)
end

isValidObj = function(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function classNameOf(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and type(name) == "string" and name or nil
end

local function isNatureItem(actor)
    local name = classNameOf(actor)
    return name ~= nil and string.find(name, "NatureItem", 1, true) ~= nil
end

local function isPickupGimmick(actor)
    if not isValidObj(actor) then return false end
    local name = classNameOf(actor)
    if not name then return false end
    for _, pat in ipairs(PICKUP_CLASS_PATTERNS) do
        if string.find(name, pat, 1, true) then return true end
    end
    return false
end

local function gimmickKey(gimmick)
    local ok, key = pcall(function() return gimmick:GetFullName() end)
    if ok and type(key) == "string" and #key > 0 then return key end
    local s = tostring(gimmick)
    if type(s) == "string" and #s > 0 then return s end
    local okA, addr = pcall(function() return gimmick:GetAddress() end)
    if okA and addr then return tostring(addr) end
    return "dead_" .. tostring(math.floor(os.clock() * 1000) % 999999)
end

local function itemCount(items)
    if items == nil then return 0 end
    local ok, n = pcall(function() return items:Num() end)
    if ok and type(n) == "number" then return n end
    if type(items) == "table" then return #items end
    return 1
end

local function gimmickHasItems(gimmick)
    local ok, items = pcall(function() return gimmick:GetItems() end)
    if not ok or items == nil then return true end
    return itemCount(items) > 0
end

local function getDistance(hero, gimmick)
    local ok, dist = pcall(function() return hero:GetActorDist(gimmick) end)
    if ok and dist and dist >= 0 then return dist end
    return nil
end

getHero = function()
    local found, hero = pcall(FindFirstOf, "RODWorldHeroCharacter")
    if not found then
        return nil, "FindFirstOf(RODWorldHeroCharacter) failed: " .. tostring(hero)
    end
    if not isValidObj(hero) then
        return nil, nil
    end

    local hostResolved, isHost = pcall(function() return hero:IsHostHero() end)
    if not hostResolved then
        return nil, "RODWorldHeroCharacter:IsHostHero failed: " .. tostring(isHost)
    end
    if isHost ~= true then
        return nil, nil
    end
    return hero, nil
end

resolveHero = function()
    if isValidObj(cachedHero) then return cachedHero end
    local hero, lookupError = getHero()
    cachedHero = hero

    if lookupError ~= nil then
        if not heroLookupErrorReported then
            heroLookupErrorReported = true
            print(string.format("[%s] HERO LOOKUP ERROR | %s\n",
                MOD_NAME, tostring(lookupError)))
        end
        return nil
    end
    heroLookupErrorReported = false

    if not isValidObj(cachedHero) then
        if not heroWaitingReported then
            heroWaitingReported = true
            print(string.format(
                "[%s] WAITING FOR HERO | pickup poll remains active\n",
                MOD_NAME
            ))
        end
        return nil
    end

    if heroWaitingReported or not heroReadyReported then
        print(string.format(
            "[%s] HERO READY | pickup poll active\n",
            MOD_NAME
        ))
    end
    heroWaitingReported = false
    heroReadyReported = true
    return cachedHero
end

numField = function(v)
    if type(v) == "number" then return v end
    if v and v.get then
        local ok, n = pcall(function() return v:get() end)
        if ok and type(n) == "number" then return n end
    end
    return tonumber(tostring(v))
end

getEffectiveRange = function(hero)
    return CONFIG.PICKUP_RANGE
end

local function getCapsuleRadius(hero)
    return getEffectiveRange(hero) * 1.05
end

local function readTakeItemDistance(hero)
    if not isValidObj(hero) then return nil end
    local ok, dist = pcall(function() return hero.TakeItemDistance end)
    if not ok then return nil end
    return numField(dist)
end

applyHeroPickupRange = function(hero)
    if not isValidObj(hero) then
        if DEBUG_HOOKS then
            local now = os.clock()
            if now - lastRangeSkipDbg >= 2.0 then
                lastRangeSkipDbg = now
                dbg("applyHeroPickupRange/invalidHero")
            end
        end
        return
    end

    local target = CONFIG.PICKUP_RANGE
    local before = readTakeItemDistance(hero)

    local writeOk = pcall(function()
        hero.TakeItemDistance = target
    end)
    local after = readTakeItemDistance(hero)

    if not DEBUG_HOOKS then return end

    local appliedOk = writeOk and after and math.abs(after - target) < 1.0
    local needLog = (not appliedOk)
        or (before == nil)
        or (before and math.abs(before - target) >= 1.0)
        or (lastAppliedTakeItemDist == nil)
        or (after and lastAppliedTakeItemDist and math.abs(after - lastAppliedTakeItemDist) >= 1.0)

    if needLog then
        dbg("applyHeroPickupRange/write", string.format(
            "target=%.0f before=%s writeOk=%s after=%s applied=%s",
            target,
            before ~= nil and string.format("%.0f", before) or "nil",
            tostring(writeOk),
            after ~= nil and string.format("%.0f", after) or "nil",
            tostring(appliedOk)
        ))
        if not appliedOk then
            dbg("applyHeroPickupRange/mismatch", "TakeItemDistance did not stick — range apply failed")
        end
    end
    lastAppliedTakeItemDist = after
end

local function formatRangeLabel(hero)
    return string.format(
        "%.0f (~%.1fm)",
        CONFIG.PICKUP_RANGE,
        CONFIG.PICKUP_RANGE / 100
    )
end

local function formatIconDisplayLabel()
    local cm = CONFIG.ICON_DISPLAY_RANGE
    return string.format("%.0f (~%.1fm)", cm, cm / 100)
end

local function getIconDisplayTarget()
    return CONFIG.ICON_DISPLAY_RANGE
end

local function readConfigField(gc, fieldName)
    local v = nil
    local ok = pcall(function() v = gc[fieldName] end)
    if not ok then return nil end
    return numField(v)
end

local function writeConfigField(gc, fieldName, value)
    return pcall(function() gc[fieldName] = value end)
end

local function configObjectKey(gc)
    if not isValidObj(gc) then return nil end
    local ok, name = pcall(function() return gc:GetFullName() end)
    if ok and name and name ~= "" then return name end
    return tostring(gc)
end

local function collectGameConfigCandidates()
    if cachedGameConfigList ~= nil and #cachedGameConfigList > 0 then
        local validList = {}
        for _, gc in ipairs(cachedGameConfigList) do
            if isValidObj(gc) then
                validList[#validList + 1] = gc
            end
        end
        if #validList > 0 then
            cachedGameConfigList = validList
            return validList
        end
    end

    local list = {}
    local seen = {}

    local function add(gc)
        if not isValidObj(gc) then return end
        local key = configObjectKey(gc)
        if not key or seen[key] then return end
        seen[key] = true
        list[#list + 1] = gc
    end

    for _, path in ipairs(GAME_CONFIG_PATHS) do
        local ok, obj = pcall(function() return StaticFindObject(path) end)
        if ok then add(obj) end
    end

    for _, clsName in ipairs({ "RODGameInstance", "GameInstance" }) do
        local gi = FindFirstOf(clsName)
        if isValidObj(gi) then
            pcall(function() add(gi.GameConfig) end)
        end
    end

    local nativeCls = StaticFindObject("/Script/ROD.RODGameConfig")
    if isValidObj(nativeCls) then
        pcall(function() add(nativeCls:GetGameConfig()) end)
    end

    for _, clsName in ipairs({ "GameConfig_C", "RODGameConfig" }) do
        add(FindFirstOf(clsName))
    end

    cachedGameConfigList = list
    return list
end

local function applyIconDisplayRange()
    local candidates = collectGameConfigCandidates()
    if #candidates == 0 then
        if lastIconDbgKey ~= "none" then
            lastIconDbgKey = "none"
            dbg("applyIconDisplayRange/noCandidates")
        end
        return false
    end

    local target = getIconDisplayTarget()
    local verified = 0
    local firstBefore, firstAfter = nil, nil

    for _, gc in ipairs(candidates) do
        local before = readConfigField(gc, "ActionFlagDisplayDist")
        if originalActionFlagDisplayDist == nil and before and before > 0 then
            originalActionFlagDisplayDist = before
        end
        if firstBefore == nil then firstBefore = before end

        local writeVal = target
        if not iconPatchEnabled then
            writeVal = originalActionFlagDisplayDist or before
        end
        if writeVal and writeVal > 0 and writeConfigField(gc, "ActionFlagDisplayDist", writeVal) then
            local after = readConfigField(gc, "ActionFlagDisplayDist")
            if firstAfter == nil then firstAfter = after end
            if after and math.abs(after - writeVal) < 1.0 then
                verified = verified + 1
            end
        end
    end

    local ok = verified > 0
    local dbgKey = string.format("%s|%s|%d|%s",
        tostring(target), tostring(iconPatchEnabled), verified, tostring(ok))
    if dbgKey ~= lastIconDbgKey then
        lastIconDbgKey = dbgKey
        dbg("applyIconDisplayRange/done", string.format(
            "candidates=%d target=%s enabled=%s verified=%d before=%s after=%s ok=%s",
            #candidates,
            target ~= nil and string.format("%.0f", target) or "nil",
            tostring(iconPatchEnabled),
            verified,
            firstBefore ~= nil and string.format("%.0f", firstBefore) or "nil",
            firstAfter ~= nil and string.format("%.0f", firstAfter) or "nil",
            tostring(ok)
        ))
    end
    return ok
end

scheduleIconRangePatch = function(delayMs, retries)
    delayMs = delayMs or 500
    retries = retries or 1
    for i = 0, retries - 1 do
        ExecuteWithDelay(delayMs + i * 1200, function()
            ExecuteInGameThread(applyIconDisplayRange)
        end)
    end
end

local function getPlayerController(hero)
    local ok, pc = pcall(function() return hero:GetPlayerController() end)
    if ok and isValidObj(pc) then return pc end
    return nil
end

getScanRange = function(maxRange)
    return maxRange * 1.05
end

local function getCandidateGimmick(hero)
    if not isValidObj(hero) then return nil end

    local okVA, target = pcall(function() return hero:GetVATargetGimmick() end)

    if not okVA or not isValidObj(target)
        or not isPickupGimmick(target) then return nil end
    return target
end

local function isOnCooldown(key)
    if key == nil then return false end
    local t = gimmickCooldown[key]
    return t ~= nil and os.clock() < t
end

local function markCooldown(key, seconds)
    if key == nil then return end
    gimmickCooldown[key] = os.clock() + (seconds or 3.0)
end

local function getOperatableCapsule(gimmick)
    local ok, cap = pcall(function() return gimmick.OperatableArea end)
    if ok and isValidObj(cap) then return cap end
    return nil
end

applyOperatableRadius = function(gimmick, hero)
    if not expandOperatable then return false end
    local key = gimmickKey(gimmick)
    if expandedGimmicks[key] then return true end

    if expandedCount > 800 then
        expandedGimmicks = {}
        expandedCount = 0
        dbg("applyOperatableRadius/cacheReset", "expandedCount>800")
    end
    local cap = getOperatableCapsule(gimmick)
    if not cap then
        if DEBUG_HOOKS then
            local now = os.clock()
            if now - lastCapsuleFailDbg >= 2.0 then
                lastCapsuleFailDbg = now
                dbg("applyOperatableRadius/noCapsule", key)
            end
        end
        return false
    end
    local r = getCapsuleRadius(hero)
    local ok = pcall(function() cap:SetCapsuleRadius(r, false) end)
    if ok then
        expandedGimmicks[key] = true
        expandedCount = expandedCount + 1
        if DEBUG_HOOKS then
            local now = os.clock()
            if now - lastCapsuleOkDbg.t >= 1.0 then
                lastCapsuleOkDbg.t = now
                lastCapsuleOkDbg.n = 0
            end
            if lastCapsuleOkDbg.n < 3 then
                lastCapsuleOkDbg.n = lastCapsuleOkDbg.n + 1
                dbg("applyOperatableRadius/ok", string.format("r=%.0f count=%d key=%s", r, expandedCount, tostring(key)))
            end
        end
    else
        dbg("applyOperatableRadius/setFail", string.format("r=%.0f key=%s", r, tostring(key)))
    end
    return ok
end

local function removeFromNearbyExpandedByKey(key)
    if not key then return end
    for i = #nearbyExpanded, 1, -1 do
        local g = nearbyExpanded[i]
        if not isValidObj(g) then
            table.remove(nearbyExpanded, i)
        elseif gimmickKey(g) == key then
            table.remove(nearbyExpanded, i)
        end
    end
end

local function trackExpandedGimmick(gimmick)
    local key = gimmickKey(gimmick)
    for _, g in ipairs(nearbyExpanded) do
        if gimmickKey(g) == key then return false end
    end
    nearbyExpanded[#nearbyExpanded + 1] = gimmick
    if #nearbyExpanded > 64 then
        table.remove(nearbyExpanded, 1)
    end
    return true
end

local function pruneNearbyExpanded(hero, full)
    local kept = {}
    local scanRange = full and getScanRange(getEffectiveRange(hero)) or nil

    for _, gimmick in ipairs(nearbyExpanded) do
        if isValidObj(gimmick) then
            if full then
                local dist = getDistance(hero, gimmick)
                if dist and dist <= scanRange then
                    kept[#kept + 1] = gimmick
                end
            else
                kept[#kept + 1] = gimmick
            end
        end
    end
    nearbyExpanded = kept

    if not full or #nearbyExpanded <= 1 then return end

    if #nearbyExpanded > 64 then
        table.sort(nearbyExpanded, function(a, b)
            local da = getDistance(hero, a) or 999999
            local db = getDistance(hero, b) or 999999
            return da < db
        end)
        while #nearbyExpanded > 64 do
            table.remove(nearbyExpanded)
        end
    end
end

expandGimmicksInRange = function(hero, scanRange)
    local expanded = 0
    for _, className in ipairs(GIMMICK_FIND_CLASSES) do
        local found = FindAllOf(className)
        if found then
            for _, gimmick in ipairs(found) do
                if isValidObj(gimmick) and isPickupGimmick(gimmick) then
                    local dist = getDistance(hero, gimmick)
                    if dist and dist <= scanRange then
                        if applyOperatableRadius(gimmick, hero) then
                            expanded = expanded + 1
                            trackExpandedGimmick(gimmick)
                        end
                    end
                end
            end
        end
    end
    return expanded
end

local processNotifyExpandQueue

local function enqueueNotifyExpand(gimmick)
    if gimmick == nil then return end

    local key = nil
    pcall(function()
        if not isValidObj(gimmick) then return end
        key = gimmickKey(gimmick)
    end)
    if not key then return end
    if expandedGimmicks[key] or notifyExpandPending[key] then return end

    notifyExpandPending[key] = true
    notifyExpandQueue[#notifyExpandQueue + 1] = gimmick

    if not notifyExpandScheduled then
        notifyExpandScheduled = true
        ExecuteWithDelay(200, function()
            if processNotifyExpandQueue then processNotifyExpandQueue() end
        end)
    end
end

processNotifyExpandQueue = function()
    notifyExpandScheduled = false
    if mapLeaving then
        notifyExpandQueue = {}
        notifyExpandPending = {}
        return
    end

    if operatedBusy then
        if #notifyExpandQueue > 0 then
            notifyExpandScheduled = true
            ExecuteWithDelay(50, function()
                if processNotifyExpandQueue then processNotifyExpandQueue() end
            end)
        end
        return
    end

    local batch = {}
    while #batch < 4 and #notifyExpandQueue > 0 do
        batch[#batch + 1] = table.remove(notifyExpandQueue, 1)
    end
    if #batch == 0 then return end

    ExecuteInGameThread(function()
        if operatedBusy then
            for _, gimmick in ipairs(batch) do
                notifyExpandQueue[#notifyExpandQueue + 1] = gimmick
            end
            if #notifyExpandQueue > 0 and not notifyExpandScheduled then
                notifyExpandScheduled = true
                ExecuteWithDelay(50, function()
                    if processNotifyExpandQueue then processNotifyExpandQueue() end
                end)
            end
            return
        end

        local hero = resolveHero()
        for _, gimmick in ipairs(batch) do
            pcall(function()
                if not isValidObj(gimmick) or not isPickupGimmick(gimmick) then return end
                local key = gimmickKey(gimmick)
                notifyExpandPending[key] = nil
                applyOperatableRadius(gimmick, hero)
                trackExpandedGimmick(gimmick)
            end)
        end
    end)

    if #notifyExpandQueue > 0 then
        notifyExpandScheduled = true
        ExecuteWithDelay(50, function()
            if processNotifyExpandQueue then processNotifyExpandQueue() end
        end)
    end
end

local function onNewPickupGimmick(gimmick)
    if mapLeaving then return end
    if not expandOperatable then return end
    -- 스폰 폭주 시 로그 과다 방지 (초당 3회)
    if DEBUG_HOOKS then
        local now = os.clock()
        if now - notifyDbgBucket.t >= 1.0 then
            notifyDbgBucket.t = now
            notifyDbgBucket.n = 0
        end
        if notifyDbgBucket.n < 3 then
            notifyDbgBucket.n = notifyDbgBucket.n + 1
            local key = nil
            pcall(function()
                if isValidObj(gimmick) then key = gimmickKey(gimmick) end
            end)
            dbg("NotifyOnNewObject/enqueue", key or "invalid")
        end
    end
    enqueueNotifyExpand(gimmick)
end

runInitialExpandScan = function()
    if initialScanDone then return end
    if not expandOperatable then return end

    initialScanDone = true
    local attempts = 0
    local function tryScan()
        if mapLeaving then
            initialScanDone = false
            return
        end
        attempts = attempts + 1
        ExecuteInGameThread(function()
            if mapLeaving then
                initialScanDone = false
                return
            end
            local hero = resolveHero()
            if not isValidObj(hero) then
                if attempts < 8 then
                    ExecuteWithDelay(800, tryScan)
                else
                    initialScanDone = false
                end
                return
            end
            local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
            print(string.format("[%s] expand scan: %d gimmicks (attempt %d)\n", MOD_NAME, n or 0, attempts))
            if (not n or n == 0) and attempts < 6 then
                ExecuteWithDelay(1000, tryScan)
            end
        end)
    end
    ExecuteWithDelay(800, tryScan)
end

local function unwrapField(v)
    if v == nil then return nil end
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then return v end
    if v.get then
        local ok, inner = pcall(function() return v:get() end)
        if ok and inner ~= nil then return inner end
    end
    return v
end

local function toNumber(v)
    v = unwrapField(v)
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    return tonumber(tostring(v))
end

local function foreachPossessItem(items, fn)
    if items == nil then return end
    local ok, n = pcall(function() return items:Num() end)
    if ok and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local okI, item = pcall(function() return items:Get(i) end)
            if okI and item then fn(item, i) end
        end
        return
    end
    if type(items) == "table" then
        for i, item in ipairs(items) do fn(item, i - 1) end
    end
end

local function snapshotGimmickItems(gimmick)
    local snaps = {}
    local ok, items = pcall(function() return gimmick:GetItems() end)
    if not ok or items == nil then return snaps end
    foreachPossessItem(items, function(item)
        local cat, id, num
        pcall(function() cat = toNumber(item.Category) end)
        pcall(function() id  = toNumber(item.ItemId) end)
        pcall(function() num = toNumber(item.Num) end)
        if cat and id then
            snaps[#snaps + 1] = { category = cat, itemId = id, num = num or 1 }
        end
    end)
    return snaps
end

local function showPickupUI(pc, snaps)
    if not CONFIG.SHOW_PICKUP_UI or not isValidObj(pc) then return end
    if not snaps or #snaps == 0 then return end
    for _, it in ipairs(snaps) do
        local cat = tonumber(it.category)
        local id  = tonumber(it.itemId)
        local num = tonumber(it.num) or 1
        if cat and id then
            pcall(function()
                pc:DebugDrawGrowthItemAcquisition(false, cat, id, num)
            end)
        end
    end
end

local function clearGimmickState(key)
    if not key then return end
    if expandedGimmicks[key] then
        expandedGimmicks[key] = nil
        if expandedCount > 0 then expandedCount = expandedCount - 1 end
    end
    notifyExpandPending[key] = nil
    removeFromNearbyExpandedByKey(key)
    for i = #notifyExpandQueue, 1, -1 do
        local g = notifyExpandQueue[i]
        if gimmickKey(g) == key then
            table.remove(notifyExpandQueue, i)
        end
    end
end

local function tryGimmickPickup(gimmick, hero, pc, itemSnaps)
    dbg("tryGimmickPickup/enter")
    if not isValidObj(gimmick) or not isValidObj(hero) then
        dbg("tryGimmickPickup/invalid", string.format("gimmick=%s hero=%s",
            tostring(isValidObj(gimmick)), tostring(isValidObj(hero))))
        return nil
    end

    applyOperatableRadius(gimmick, hero)
    if not isValidObj(gimmick) then
        dbg("tryGimmickPickup/gimmickDeadAfterExpand")
        return nil
    end

    dbg("tryGimmickPickup/beforeOperated", string.format("snaps=%d", itemSnaps and #itemSnaps or 0))
    local ok = pcall(function() gimmick:Operated(hero, VA_PICK_ITEM) end)
    dbg("tryGimmickPickup/afterOperated", tostring(ok))
    if ok then
        showPickupUI(pc, itemSnaps)
        return true
    end
    return nil
end

local function pickupGimmick(gimmick, hero, dist, key)
    dbg("pickupGimmick/enter", string.format("dist=%s key=%s", tostring(dist), tostring(key)))
    if mapLeaving or operatedBusy then
        dbg("pickupGimmick/busyOrLeaving", string.format("mapLeaving=%s operatedBusy=%s",
            tostring(mapLeaving), tostring(operatedBusy)))
        return false
    end
    if not isValidObj(gimmick) or not isValidObj(hero) then
        dbg("pickupGimmick/invalid")
        return false
    end

    local itemSnaps = snapshotGimmickItems(gimmick)
    local pc        = getPlayerController(hero)

    markCooldown(key, 0.4)
    clearGimmickState(key)

    beginOperatedBusy()
    local ok, result = pcall(function()
        return tryGimmickPickup(gimmick, hero, pc, itemSnaps)
    end)
    releaseOperatedBusy()

    local success = ok and result == true
    dbg("pickupGimmick/done", string.format("ok=%s result=%s success=%s",
        tostring(ok), tostring(result), tostring(success)))
    return success
end

local function canPickPromptGimmick(gimmick, hero)
    if not isPickupGimmick(gimmick) then return false end

    local key = gimmickKey(gimmick)
    if isOnCooldown(key) then return false end

    local okDeny, deny = pcall(function() return gimmick.bIsAccessDeny end)
    if okDeny and deny then return false end

    if not isNatureItem(gimmick) and not gimmickHasItems(gimmick) then return false end

    local dist = getDistance(hero, gimmick)
    if not dist then return false end

    return true, dist, key
end

local function tryPickupIfReady(hero, gimmick, now)
    if not isValidObj(gimmick) then return false end

    local pickable, dist, key = canPickPromptGimmick(gimmick, hero)
    if not pickable then return false end

    applyOperatableRadius(gimmick, hero)
    local maxR = getEffectiveRange(hero)
    local takeDist = readTakeItemDistance(hero)
    if not dist or dist > maxR then
        if DEBUG_HOOKS then
            local t = os.clock()
            if t - lastOutOfRangeDbg >= 1.0 then
                lastOutOfRangeDbg = t
                dbg("tryPickupIfReady/outOfRange", string.format(
                    "dist=%s maxR=%.0f TakeItemDistance=%s cfg=%.0f",
                    dist ~= nil and string.format("%.1f", dist) or "nil",
                    maxR,
                    takeDist ~= nil and string.format("%.0f", takeDist) or "nil",
                    CONFIG.PICKUP_RANGE
                ))
            end
        end
        return false
    end

    dbg("tryPickupIfReady/inRange", string.format(
        "dist=%.1f maxR=%.0f TakeItemDistance=%s",
        dist, maxR,
        takeDist ~= nil and string.format("%.0f", takeDist) or "nil"
    ))
    pcall(function() pickupGimmick(gimmick, hero, dist, key) end)
    lastPickupAt = now
    return true
end

local function tryPickupNearbyFirst(hero, now)
    nearbyPruneTick = nearbyPruneTick + 1
    pruneNearbyExpanded(hero, nearbyPruneTick >= 5)
    if nearbyPruneTick >= 5 then nearbyPruneTick = 0 end

    local maxChecks = 10
    local maxR = getEffectiveRange(hero)
    local candidates = {}

    for _, gimmick in ipairs(nearbyExpanded) do
        if isValidObj(gimmick) and isPickupGimmick(gimmick) then
            local dist = getDistance(hero, gimmick)
            if dist and dist <= maxR then
                candidates[#candidates + 1] = { gimmick = gimmick, dist = dist }
            end
        end
    end

    table.sort(candidates, function(a, b) return a.dist < b.dist end)

    local checks = 0
    for _, entry in ipairs(candidates) do
        if checks >= maxChecks then break end
        checks = checks + 1
        if tryPickupIfReady(hero, entry.gimmick, now) then return true end
    end
    return false
end

local function pruneCooldownTable()
    local now = os.clock()
    for k, t in pairs(gimmickCooldown) do
        if now >= t then
            gimmickCooldown[k] = nil
        end
    end
end

local function pollTick()
    if mapLeaving or operatedBusy then return end
    if os.clock() < pickupQuietUntil then return end

    heroRecheckTick = heroRecheckTick + 1
    if heroRecheckTick >= 25 then
        heroRecheckTick = 0
        if not isValidObj(cachedHero) then cachedHero = getHero() end
    end

    cooldownPruneTick = cooldownPruneTick + 1
    if cooldownPruneTick >= 100 then
        cooldownPruneTick = 0
        pruneCooldownTable()
    end

    local hero = resolveHero()
    if not isValidObj(hero) then return end

    applyHeroPickupRange(hero)

    local okDead, dead = pcall(function() return hero:IsDead() end)
    if okDead and dead then return end

    local now = os.clock()
    if now - lastPickupAt < pickupInterval then return end

    if tryPickupNearbyFirst(hero, now) then
        lastCandidateTick = now
        return
    end

    local candidate = getCandidateGimmick(hero)
    if tryPickupIfReady(hero, candidate, now) then
        lastCandidateTick = now
    end
end

local function poll()
    if CONFIG.ENABLED then
        ExecuteInGameThread(function()
            local handler = function(e) return tostring(e) end
            if debug and type(debug.traceback) == "function" then
                handler = debug.traceback
            end
            local ok, err = xpcall(pollTick, handler)
            if not ok then
                print(string.format("[%s] pollTick error: %s\n", MOD_NAME, tostring(err)))
            end
        end)
    end

    local idleSec = os.clock() - lastCandidateTick
    local nextMs = (lastCandidateTick > 0 and idleSec > 3.0) and 250 or 100
    ExecuteWithDelay(nextMs, poll)
end

local function resetPollState()
    lastPickupAt        = 0
    gimmickCooldown     = {}
    expandedGimmicks    = {}
    expandedCount       = 0
    cachedHero          = nil
    heroWaitingReported = false
    heroReadyReported   = false
    heroLookupErrorReported = false
    heroRecheckTick     = 0
    initialScanDone     = false
    nearbyExpanded      = {}
    notifyExpandQueue   = {}
    notifyExpandPending = {}
    notifyExpandScheduled = false
    nearbyPruneTick     = 0
    operatedBusy        = false
    cooldownPruneTick   = 0
    lastCandidateTick   = 0
end

startPoll = function()
    if pollLoopActive then return end
    pollLoopActive = true
    resetPollState()

    ExecuteWithDelay(500, poll)
end

local function requireLifecycleHook(path, fn, label)
    if type(path) ~= "string" or path == ""
        or type(fn) ~= "function"
        or type(label) ~= "string" or label == "" then
        CONFIG.ENABLED = false
        error("[" .. MOD_NAME .. "] HOOK ERROR | invalid canonical hook registration")
    end
    dbg("requireLifecycleHook/try", label)
    local ok, err = pcall(function()
        RegisterHook(path, fn)
    end)
    if not ok then
        CONFIG.ENABLED = false
        error(string.format("[%s] HOOK ERROR | %s: %s",
            MOD_NAME, label, tostring(err)))
    end
    print(string.format("[%s] hooked %s\n", MOD_NAME, label))
    dbg("requireLifecycleHook/ok", label)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    dbg("Hook/ClientRestart/enter", string.format("mapLeaving=%s", tostring(mapLeaving)))
    if mapLeaving then
        onWorldReady("ClientRestart", 3.0)
        return
    end

    travelScanId = travelScanId + 1
    clearWorldRefs()
    initialScanDone = false
    lastPickupAt = 0
    pickupQuietUntil = os.clock() + 5.0
    print(string.format("[%s] ClientRestart (no prior travel) — quiet 5s + delayed settle\n", MOD_NAME))
    dbg("Hook/ClientRestart/orphanQuiet")

    local sid = travelScanId
    ExecuteWithDelay(5000, function()
        if sid ~= travelScanId or mapLeaving then
            dbg("Hook/ClientRestart/settleAbort")
            return
        end
        if not pollLoopActive then startPoll() end
        scheduleRangeRefresh()
        schedulePostTravelScan()
        ExecuteInGameThread(function()
            if sid ~= travelScanId or mapLeaving then return end
            dbg("Hook/ClientRestart/settleApplyRange")
            applyHeroPickupRange(resolveHero())
        end)
        print(string.format("[%s] orphan-restart settle done\n", MOD_NAME))
        dbg("Hook/ClientRestart/settleDone")
    end)
end)

requireLifecycleHook("/Script/Engine.PlayerController:ClientTravelInternal", function()
    dbg("Hook/ClientTravelInternal")
    beginTravel("ClientTravelInternal")
end, "ClientTravelInternal")

requireLifecycleHook("/Script/Engine.PlayerController:ClientTravel", function()
    dbg("Hook/ClientTravel")
    beginTravel("ClientTravel")
end, "ClientTravel")

requireLifecycleHook("/Script/Engine.PlayerController:ClientPrepareMapChange", function()
    dbg("Hook/ClientPrepareMapChange")
    beginTravel("ClientPrepareMapChange")
end, "ClientPrepareMapChange")

requireLifecycleHook("/Script/ROD.RODPlayerState:ServerDecideTown", function()
    dbg("Hook/ServerDecideTown")
    beginTravel("ServerDecideTown")
end, "ServerDecideTown")

requireLifecycleHook("/Script/ROD.RODPlayerState:ServerDecideFastTravel", function()
    dbg("Hook/ServerDecideFastTravel(same-world)")
    beginQuietOnly("ServerDecideFastTravel(same-world)", 6.0)
end, "ServerDecideFastTravel(same-world)")

requireLifecycleHook("/Script/ROD.RODPlayerState:ServerNotifyQuestTeleportOut", function()
    dbg("Hook/ServerNotifyQuestTeleportOut")
    beginQuietOnly("ServerNotifyQuestTeleportOut", 4.0)
end, "ServerNotifyQuestTeleportOut")

requireLifecycleHook("/Script/ROD.RODPlayerState:ServerShowQuestResult", function()
    dbg("Hook/ServerShowQuestResult")
    beginTravel("ServerShowQuestResult")
end, "ServerShowQuestResult")

requireLifecycleHook("/Script/ROD.RODHeroCharacter:ServerSleepDirection", function()
    dbg("Hook/ServerSleepDirection")
    onSleepBegin("ServerSleepDirection")
end, "ServerSleepDirection")

requireLifecycleHook("/Script/ROD.RODGameState:StartSleepDirection", function()
    dbg("Hook/StartSleepDirection")
    onSleepBegin("StartSleepDirection")
end, "StartSleepDirection")

requireLifecycleHook("/Script/ROD.RODInGamePlayerController:ClientStartSleepFade", function()
    dbg("Hook/ClientStartSleepFade")
    onSleepBegin("ClientStartSleepFade")
end, "ClientStartSleepFade")

requireLifecycleHook("/Script/ROD.RODInGamePlayerController:StartSleepFade", function()
    dbg("Hook/StartSleepFade")
    onSleepBegin("StartSleepFade")
end, "StartSleepFade")

local TOWN_WARP_MENU_KIND = 60
local townWarpMenuOpen = false

local function onTownWarpMenuOpen()
    dbg("onTownWarpMenuOpen/enter", string.format("mapLeaving=%s alreadyOpen=%s",
        tostring(mapLeaving), tostring(townWarpMenuOpen)))
    if mapLeaving then return end
    if townWarpMenuOpen then return end
    townWarpMenuOpen = true

    pickupQuietUntil = os.clock() + 120
    print(string.format("[%s] TownWarp menu opened — pickup quiet (draining network buffer)\n", MOD_NAME))
    dbg("onTownWarpMenuOpen/done")
end

local function onTownWarpMenuClose()
    dbg("onTownWarpMenuClose/enter", string.format("open=%s mapLeaving=%s",
        tostring(townWarpMenuOpen), tostring(mapLeaving)))
    if not townWarpMenuOpen then return end
    townWarpMenuOpen = false
    if mapLeaving then return end
    pickupQuietUntil = 0
    print(string.format("[%s] TownWarp menu closed (cancelled) — pickup resumed\n", MOD_NAME))
    dbg("onTownWarpMenuClose/done")
end

local function readEnumParam(params, idx)
    if not params then return nil end
    local p = params[idx]
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok and type(v) == "number" then return v end
    return nil
end

requireLifecycleHook("/Script/ROD.RODPlayerState:ClientPassiveUIOpen", function(self, params)
    local kind = readEnumParam(params, 1)
    if kind == TOWN_WARP_MENU_KIND then
        dbg("Hook/ClientPassiveUIOpen", string.format("kind=%s", tostring(kind)))
        onTownWarpMenuOpen()
    end
end, "ClientPassiveUIOpen")

requireLifecycleHook("/Script/ROD.RODPlayerState:ClientPassiveUIClose", function()
    if townWarpMenuOpen then
        dbg("Hook/ClientPassiveUIClose")
    end
    onTownWarpMenuClose()
end, "ClientPassiveUIClose")

requireLifecycleHook("/Script/ROD.RODPlayerState:OpenMenu", function(self, params)
    local kind = readEnumParam(params, 1)
    if kind == TOWN_WARP_MENU_KIND then
        dbg("Hook/OpenMenu/TownWarp", string.format("kind=%s", tostring(kind)))
        onTownWarpMenuOpen()
    end
end, "OpenMenu(TownWarp)")

ExecuteInGameThread(function()
    startPoll()
    scheduleIconRangePatch(1500, 3)
end)

local function consoleReply(ar, msg)
    if ar and type(ar) == "userdata" then
        pcall(function() ar:Log(tostring(msg)) end)
    end
end

local function runAutopickupCommand(params, ar)
    local sub = params[1]
    if sub ~= nil and sub ~= "show" and sub ~= "status" then
        consoleReply(ar,
            "Read-only command. Change persistent settings through config.lua or ModMenu.")
        return
    end

    consoleReply(ar, string.format(
        "%s %s | %s | pickup=%s | icon_dist=%s | interval=%.2fs | icon_patch=%s | expand=%s | notify=%s | debug=%s",
        MOD_NAME, MOD_VERSION,
        CONFIG.ENABLED and "ON" or "OFF",
        formatRangeLabel(getHero()),
        formatIconDisplayLabel(),
        pickupInterval,
        iconPatchEnabled and "ON" or "OFF",
        expandOperatable and "ON" or "OFF",
        CONFIG.SHOW_PICKUP_UI and "ON" or "OFF",
        DEBUG_HOOKS and "ON" or "OFF"
    ))
end

RegisterConsoleCommandHandler("autopickup", function(_full, params, ar)
    pcall(runAutopickupCommand, params, ar)
    return true
end)

-- Runtime settings. This mod keeps a few tunables outside CONFIG as plain
-- locals, so the settings file uses stable public names and this loader maps
-- them onto whatever each one is actually stored in.
do
    -- Every cache keyed off the old radius has to be dropped so the new value
    -- applies to already discovered items.
    local function activateExternalConfig()
        expandedGimmicks = {}
        nearbyExpanded = {}
        lastAppliedTakeItemDist = nil
        lastIconDbgKey = nil
        scheduleIconRangePatch(100)
        pcall(function() applyHeroPickupRange(resolveHero()) end)
    end

    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
            modName = "AutoPickupMod",
            scriptDir = SCRIPT_DIRECTORY,
            pollMs = 750,
            load = applyExternalConfig,
            apply = activateExternalConfig,
            fail = function(message)
                CONFIG.ENABLED = false
                expandedGimmicks = {}
                nearbyExpanded = {}
                cachedHero = nil
                print("[AutoPickupMod] FAIL-CLOSED | " ..
                    tostring(message) .. "\n")
            end,
            log = function(message) print("[AutoPickupMod] " .. tostring(message) .. "\n") end,
    })
    if attachment == nil then
        CONFIG.ENABLED = false
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

for _, classPath in ipairs(NOTIFY_PICKUP_CLASSES) do
    pcall(function()
        NotifyOnNewObject(classPath, onNewPickupGimmick)
    end)
end

print(string.format(
    "[%s] %s loaded | pickup=%s | icon_dist=%s | interval=%.2fs | icon_patch=%s | expand=3s+8s | debug=%s\n",
    MOD_NAME, MOD_VERSION,
    formatRangeLabel(getHero()),
    formatIconDisplayLabel(),
    pickupInterval,
    iconPatchEnabled and "ON" or "OFF",
    DEBUG_HOOKS and "ON" or "OFF"
))
dbg("main/loaded", MOD_VERSION)
