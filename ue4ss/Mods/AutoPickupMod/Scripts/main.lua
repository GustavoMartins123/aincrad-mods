-- AutoPickupMod v1.4

local MOD_NAME = "AutoPickupMod"
local MOD_VERSION = "v1.4"

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
local pendingFastTravel = false
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
local startFastTravelArrivalWatch

local TRAVEL_STUCK_MS = 30000
local travelWatchdogId = 0
local ftWatchId = 0
local travelScanId = 0
local ftEndToken = 0
local ftResumeScheduled = false

local FT_DISABLE = 0
local FT_CANCEL  = 1
local FT_DECIDE  = 2
local FT_ENABLE  = 3

local function clearWorldRefs()
    dbg("clearWorldRefs/enter")
    cachedHero = nil
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

    for _, ms in ipairs({ 300, 2000 }) do
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
    for _, ms in ipairs({ 500, 1500, 3000, 6000, 10000, 15000 }) do
        ExecuteWithDelay(ms, function()
            if mapLeaving then return end
            ExecuteInGameThread(function()
                applyHeroPickupRange(resolveHero())
            end)
        end)
    end
    scheduleIconRangePatch(2000, 4)
    travelScanId = travelScanId + 1
    local sid = travelScanId
    ExecuteWithDelay(8000, function()
        if sid ~= travelScanId or mapLeaving then return end
        ExecuteInGameThread(function()
            if sid ~= travelScanId or mapLeaving then return end
            local hero = resolveHero()
            if not isValidObj(hero) then return end
            if expandOperatable and CONFIG.PICKUP_RANGE > 0 then
                local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
                print(string.format("[%s] post-rest expand: %d items\n", MOD_NAME, n or 0))
            end
        end)
    end)
end

local function schedulePostTravelScan()

    travelScanId = travelScanId + 1
    local sid = travelScanId
    local function runExpand(label)
        if sid ~= travelScanId or mapLeaving then return end
        ExecuteInGameThread(function()
            if sid ~= travelScanId or mapLeaving then return end
            local hero = resolveHero()
            if not isValidObj(hero) then
                return
            end
            applyHeroPickupRange(hero)
            if expandOperatable and CONFIG.PICKUP_RANGE > 0 then
                expandedGimmicks = {}
                expandedCount = 0
                local n = expandGimmicksInRange(hero, getScanRange(getEffectiveRange(hero)))
                print(string.format("[%s] %s: %d gimmicks\n", MOD_NAME, label, n or 0))
            end
        end)
    end
    ExecuteWithDelay(3000, function() runExpand("expand+3s") end)
    ExecuteWithDelay(8000, function() runExpand("expand+8s") end)
end

local function endTravelState()
    dbg("endTravelState/enter", string.format("mapLeaving=%s pendingFT=%s",
        tostring(mapLeaving), tostring(pendingFastTravel)))
    mapLeaving = false
    pendingFastTravel = false
    travelWatchdogId = travelWatchdogId + 1
    ftWatchId = ftWatchId + 1
    ftEndToken = ftEndToken + 1
    ftResumeScheduled = false
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
        print(string.format("[%s] onWorldReady error: %s\n", MOD_NAME, tostring(err)))
        dbg("onWorldReady/error", tostring(err))
    else
        dbg("onWorldReady/done")
    end
end

local function readFastTravelStatus()
    local ps = FindFirstOf("RODPlayerState")
    if not isValidObj(ps) then
        ps = FindFirstOf("PlayerState")
    end
    if not isValidObj(ps) then return nil end
    local ok, st = pcall(function() return ps.FastTravelStatus end)
    if not ok or st == nil then return nil end
    if type(st) == "number" then return st end
    local n = numField(st)
    if n then return n end
    local ok2, s = pcall(function() return tonumber(tostring(st)) end)
    if ok2 then return s end
    return nil
end

startFastTravelArrivalWatch = function()
    dbg("startFastTravelArrivalWatch/enter")
    ftWatchId = ftWatchId + 1
    local wid = ftWatchId
    local sawActive = false
    local ticks = 0

    local function tick()
        if wid ~= ftWatchId or not mapLeaving or not pendingFastTravel then
            dbg("startFastTravelArrivalWatch/abort", string.format(
                "widOk=%s mapLeaving=%s pendingFT=%s",
                tostring(wid == ftWatchId), tostring(mapLeaving), tostring(pendingFastTravel)))
            return
        end
        ticks = ticks + 1

        local st = readFastTravelStatus()
        if st == FT_DECIDE or st == FT_ENABLE then
            if not sawActive then
                dbg("startFastTravelArrivalWatch/sawActive", tostring(st))
            end
            sawActive = true
        elseif sawActive and (st == FT_DISABLE or st == FT_CANCEL) then
            print(string.format("[%s] FastTravelStatus settled (%s) — resume\n", MOD_NAME, tostring(st)))
            dbg("startFastTravelArrivalWatch/settled", tostring(st))
            onWorldReady("FastTravelStatus", 1.0)
            return
        end

        if ticks < 60 then
            ExecuteWithDelay(500, tick)
        else
            dbg("startFastTravelArrivalWatch/timeout", string.format("ticks=%d lastSt=%s", ticks, tostring(st)))
        end
    end

    ExecuteWithDelay(500, tick)
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
                if expandOperatable and CONFIG.PICKUP_RANGE > 0 then
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

local function beginTravel(reason, isFastTravel)
    dbg("beginTravel/enter", string.format("reason=%s isFT=%s mapLeaving=%s",
        tostring(reason or "?"), tostring(isFastTravel), tostring(mapLeaving)))
    if mapLeaving then
        if isFastTravel then pendingFastTravel = true end
        dbg("beginTravel/alreadyLeaving", string.format("pendingFT=%s", tostring(pendingFastTravel)))
        return
    end
    mapLeaving = true
    pendingFastTravel = isFastTravel and true or false
    travelScanId = travelScanId + 1
    ftResumeScheduled = false
    clearWorldRefs()
    initialScanDone = false
    print(string.format("[%s] travel begin (%s) — pickup paused\n", MOD_NAME, tostring(reason or "?")))
    dbg("beginTravel/paused", string.format("pendingFT=%s", tostring(pendingFastTravel)))

    if pendingFastTravel then
        startFastTravelArrivalWatch()
    end

    travelWatchdogId = travelWatchdogId + 1
    local wid = travelWatchdogId
    ExecuteWithDelay(TRAVEL_STUCK_MS, function()
        if not mapLeaving or wid ~= travelWatchdogId then return end
        print(string.format("[%s] travel watchdog — force resume after %dms (%s)\n",
            MOD_NAME, TRAVEL_STUCK_MS, tostring(reason or "?")))
        dbg("beginTravel/watchdog", tostring(reason or "?"))
        onWorldReady("watchdog", 1.0)
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
    if CONFIG.PICKUP_RANGE > 0 then return CONFIG.PICKUP_RANGE end
    if isValidObj(hero) then
        local ok, dist = pcall(function() return hero.TakeItemDistance end)
        if ok then
            dist = numField(dist)
            if dist and dist > 0 then return dist end
        end
    end
    return 300.0
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
    if CONFIG.PICKUP_RANGE <= 0 then
        if DEBUG_HOOKS then
            local now = os.clock()
            if now - lastRangeSkipDbg >= 5.0 then
                lastRangeSkipDbg = now
                dbg("applyHeroPickupRange/skip", "CONFIG.PICKUP_RANGE<=0 (game default)")
            end
        end
        return
    end
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
    if CONFIG.PICKUP_RANGE > 0 then
        return string.format("%.0f (~%.1fm)", CONFIG.PICKUP_RANGE, CONFIG.PICKUP_RANGE / 100)
    end
    local r = isValidObj(hero) and getEffectiveRange(hero) or 300.0
    return string.format("game default %.0f (~%.1fm)", r, r / 100)
end

local function formatIconDisplayLabel()
    local cm = CONFIG.ICON_DISPLAY_RANGE
    if not cm or cm <= 0 then
        cm = CONFIG.PICKUP_RANGE
    end
    if cm <= 0 then
        return "game default"
    end
    return string.format("%.0f (~%.1fm)", cm, cm / 100)
end

local function getIconDisplayTarget()
    local base = CONFIG.ICON_DISPLAY_RANGE
    if not base or base <= 0 then
        base = CONFIG.PICKUP_RANGE
    end
    if base <= 0 then return nil end
    return base
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
    local pc
    pcall(function() pc = hero:GetPlayerController() end)
    if isValidObj(pc) then return pc end
    pc = FindFirstOf("RODInGamePlayerController")
    if isValidObj(pc) then return pc end
    return FindFirstOf("PlayerController")
end

getScanRange = function(maxRange)
    return maxRange * 1.05
end

local function getCandidateGimmick(hero)
    if not isValidObj(hero) then return nil end

    local target = nil
    local okVA, vaTarget = pcall(function() return hero:GetVATargetGimmick() end)
    if okVA and isValidObj(vaTarget) then
        target = vaTarget
    else
        local okCur, curTarget = pcall(function() return hero.CurrentTargetGimmick end)
        if okCur and isValidObj(curTarget) then
            target = curTarget
        end
    end

    if not isValidObj(target) or not isPickupGimmick(target) then return nil end
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
    if not expandOperatable or CONFIG.PICKUP_RANGE <= 0 then return end
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
    if not expandOperatable or CONFIG.PICKUP_RANGE <= 0 then return end

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

local function safeRegisterHook(path, fn, label)
    dbg("safeRegisterHook/try", label or path)
    local ok, err = pcall(function()
        RegisterHook(path, fn)
    end)
    if ok then
        print(string.format("[%s] hooked %s\n", MOD_NAME, label or path))
        dbg("safeRegisterHook/ok", label or path)
    else
        print(string.format("[%s] hook failed %s: %s\n", MOD_NAME, label or path, tostring(err)))
        dbg("safeRegisterHook/fail", string.format("%s err=%s", label or path, tostring(err)))
    end
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

safeRegisterHook("/Script/Engine.PlayerController:ClientTravelInternal", function()
    dbg("Hook/ClientTravelInternal")
    beginTravel("ClientTravelInternal", false)
end, "ClientTravelInternal")

safeRegisterHook("/Script/Engine.PlayerController:ClientTravel", function()
    dbg("Hook/ClientTravel")
    beginTravel("ClientTravel", false)
end, "ClientTravel")

safeRegisterHook("/Script/Engine.PlayerController:ClientPrepareMapChange", function()
    dbg("Hook/ClientPrepareMapChange")
    beginTravel("ClientPrepareMapChange", false)
end, "ClientPrepareMapChange")

safeRegisterHook("/Script/ROD.RODPlayerState:ServerDecideTown", function()
    dbg("Hook/ServerDecideTown")
    beginTravel("ServerDecideTown", false)
end, "ServerDecideTown")

safeRegisterHook("/Script/ROD.RODPlayerState:ServerDecideFastTravel", function()
    dbg("Hook/ServerDecideFastTravel")
    beginTravel("ServerDecideFastTravel", true)
end, "ServerDecideFastTravel")

safeRegisterHook("/Script/ROD.RODWorldGameState:CheckFastTravelTeleport", function()
    -- 게임이 FT 중 ~0.1초마다 호출함 → 첫 1회만 +8s 재개 예약 (타이머 폭주 방지)
    if not (mapLeaving and pendingFastTravel) then return end
    if ftResumeScheduled then return end
    ftResumeScheduled = true
    local tok = ftEndToken
    dbg("Hook/CheckFastTravelTeleport/schedule+8s", string.format("tok=%d", tok))
    ExecuteWithDelay(8000, function()
        if tok ~= ftEndToken then return end
        if mapLeaving and pendingFastTravel then
            dbg("Hook/CheckFastTravelTeleport/resume+8s")
            onWorldReady("CheckFastTravelTeleport+8s", 2.0)
        else
            dbg("Hook/CheckFastTravelTeleport/+8sSkip")
        end
    end)
end, "CheckFastTravelTeleport")

safeRegisterHook("/Script/ROD.RODPlayerState:OnRep_FastTravelStatus", function()
    dbg("Hook/OnRep_FastTravelStatus/enter", string.format("mapLeaving=%s pendingFT=%s",
        tostring(mapLeaving), tostring(pendingFastTravel)))
    if not (mapLeaving and pendingFastTravel) then
        dbg("Hook/OnRep_FastTravelStatus/skip")
        return
    end
    ExecuteWithDelay(600, function()
        if not (mapLeaving and pendingFastTravel) then
            dbg("Hook/OnRep_FastTravelStatus/delaySkip")
            return
        end
        local st = readFastTravelStatus()
        dbg("Hook/OnRep_FastTravelStatus/status", tostring(st))
        if st == FT_DISABLE or st == FT_CANCEL then
            onWorldReady("OnRep_FastTravelStatus", 1.0)
        end
    end)
end, "OnRep_FastTravelStatus")

safeRegisterHook("/Script/ROD.RODPlayerState:ServerNotifyQuestTeleportOut", function()
    dbg("Hook/ServerNotifyQuestTeleportOut")
    beginQuietOnly("ServerNotifyQuestTeleportOut", 4.0)
end, "ServerNotifyQuestTeleportOut")

safeRegisterHook("/Script/ROD.RODPlayerState:ServerShowQuestResult", function()
    dbg("Hook/ServerShowQuestResult")
    beginTravel("ServerShowQuestResult", false)
end, "ServerShowQuestResult")

safeRegisterHook("/Script/ROD.RODHeroCharacter:ServerSleepDirection", function()
    dbg("Hook/ServerSleepDirection")
    onSleepBegin("ServerSleepDirection")
end, "ServerSleepDirection")

safeRegisterHook("/Script/ROD.RODGameState:StartSleepDirection", function()
    dbg("Hook/StartSleepDirection")
    onSleepBegin("StartSleepDirection")
end, "StartSleepDirection")

safeRegisterHook("/Script/ROD.RODInGamePlayerController:ClientStartSleepFade", function()
    dbg("Hook/ClientStartSleepFade")
    onSleepBegin("ClientStartSleepFade")
end, "ClientStartSleepFade")

safeRegisterHook("/Script/ROD.RODInGamePlayerController:StartSleepFade", function()
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

local function safeReadEnumParam(params, idx)
    if not params then return nil end
    local p = params[idx]
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok and type(v) == "number" then return v end
    ok, v = pcall(function() return tonumber(tostring(p)) end)
    if ok and v then return v end
    return nil
end

safeRegisterHook("/Script/ROD.RODPlayerState:ClientPassiveUIOpen", function(self, params)
    local kind = safeReadEnumParam(params, 1)
    if kind == TOWN_WARP_MENU_KIND then
        dbg("Hook/ClientPassiveUIOpen", string.format("kind=%s", tostring(kind)))
        onTownWarpMenuOpen()
    end
end, "ClientPassiveUIOpen")

safeRegisterHook("/Script/ROD.RODPlayerState:ClientPassiveUIClose", function()
    if townWarpMenuOpen then
        dbg("Hook/ClientPassiveUIClose")
    end
    onTownWarpMenuClose()
end, "ClientPassiveUIClose")

safeRegisterHook("/Script/ROD.RODPlayerState:OpenMenu", function(self, params)
    local kind = safeReadEnumParam(params, 1)
    if kind == TOWN_WARP_MENU_KIND then
        dbg("Hook/OpenMenu/TownWarp", string.format("kind=%s", tostring(kind)))
        onTownWarpMenuOpen()
    end
end, "OpenMenu(TownWarp)")

pcall(function()
    RegisterLoadMapPreHook(function()
        dbg("Hook/LoadMapPre")
        beginTravel("LoadMapPre", false)
    end)
end)

ExecuteInGameThread(function()
    startPoll()
    scheduleIconRangePatch(1500, 3)
end)

pcall(function()
    RegisterHook("/Script/ROD.RODGameInstance:LoadInGameGameModeCompleted", function()
        dbg("Hook/LoadInGameGameModeCompleted/enter", string.format("mapLeaving=%s", tostring(mapLeaving)))
        if mapLeaving then
            onWorldReady("LoadInGameGameModeCompleted", 2.0)
        else
            scheduleIconRangePatch(300, 2)
            ExecuteWithDelay(500, function()
                if mapLeaving then return end
                ExecuteInGameThread(function()
                    dbg("Hook/LoadInGameGameModeCompleted/applyRange")
                    applyHeroPickupRange(resolveHero())
                end)
            end)
        end
    end)
end)

local function consoleReply(ar, msg)
    if ar and type(ar) == "userdata" then
        pcall(function() ar:Log(tostring(msg)) end)
    end
end

local function runAutopickupCommand(params, ar)
    local sub = params[1]

    local function reply(msg)
        consoleReply(ar, msg)
    end

    if sub == "range" then
        local v = tonumber(params[2])
        if v == nil or v < 0 then
            reply("usage: autopickup range <cm>  (0=game default, current: " .. formatRangeLabel(getHero()) .. ")")
            return
        end
        CONFIG.PICKUP_RANGE = v
        expandedGimmicks = {}
        nearbyExpanded = {}
        lastAppliedTakeItemDist = nil
        lastIconDbgKey = nil
        dbg("console/range", string.format("PICKUP_RANGE=%.0f", v))
        scheduleIconRangePatch(100)
        pcall(function()
            ExecuteInGameThread(function() applyHeroPickupRange(resolveHero()) end)
        end)
        if v == 0 then
            reply("pickup range = game default (TakeItemDistance)")
        else
            reply(string.format("pickup range = %.0f (%.1fm)", v, v / 100))
        end
        return
    end

    if sub == "icondist" then
        local v = tonumber(params[2])
        if v == nil or v < 0 then
            reply("usage: autopickup icondist <cm>  (0=same as pickup, current: " .. formatIconDisplayLabel() .. ")")
            return
        end
        CONFIG.ICON_DISPLAY_RANGE = v
        scheduleIconRangePatch(50)
        if v == 0 then
            reply("icon display = same as pickup (" .. formatIconDisplayLabel() .. ")")
        else
            reply(string.format("icon display = %.0f (%.1fm)", v, v / 100))
        end
        return
    end

    if sub == "icon" then
        local arg = params[2]
        if arg == "on" then
            iconPatchEnabled = true
        elseif arg == "off" then
            iconPatchEnabled = false
        elseif arg == "dist" or arg == "range" then
            local v = tonumber(params[3])
            if v == nil or v < 0 then
                reply("usage: autopickup icon dist <cm>  (0=same as pickup, current: " .. formatIconDisplayLabel() .. ")")
                return
            end
            CONFIG.ICON_DISPLAY_RANGE = v
            scheduleIconRangePatch(50)
            if v == 0 then
                reply("icon display = same as pickup (" .. formatIconDisplayLabel() .. ")")
            else
                reply(string.format("icon display = %.0f (%.1fm)", v, v / 100))
            end
            return
        else
            iconPatchEnabled = not iconPatchEnabled
        end
        scheduleIconRangePatch(50)
        reply("icon range patch " .. (iconPatchEnabled and "ON" or "OFF"))
        return
    end

    if sub == "interval" then
        local v = tonumber(params[2])
        if not v or v < 0 then
            reply("usage: autopickup interval <sec>  (current: " .. pickupInterval .. ")")
            return
        end
        pickupInterval = v
        reply(string.format("pickup interval = %.2fs", v))
        return
    end

    if sub == "expand" then
        expandOperatable = not expandOperatable
        reply("OperatableArea expand " .. (expandOperatable and "ON" or "OFF"))
        return
    end

    if sub == "toggle" then
        CONFIG.ENABLED = not CONFIG.ENABLED
        reply(CONFIG.ENABLED and "ON" or "OFF")
        return
    end

    if sub == "debug" then
        local arg = params[2]
        if arg == "on" then
            DEBUG_HOOKS = true
        elseif arg == "off" then
            DEBUG_HOOKS = false
        else
            DEBUG_HOOKS = not DEBUG_HOOKS
        end
        reply("hook debug " .. (DEBUG_HOOKS and "ON" or "OFF"))
        dbg("console/debugToggle", DEBUG_HOOKS and "ON" or "OFF")
        return
    end

    if sub == "notify" then
        CONFIG.SHOW_PICKUP_UI = not CONFIG.SHOW_PICKUP_UI
        reply("pickup notification UI " .. (CONFIG.SHOW_PICKUP_UI and "ON" or "OFF"))
        return
    end

    reply(string.format(
        "%s %s | %s | pickup=%s | icon_dist=%s | icon_patch=%s | notify=%s | debug=%s\n" ..
        "Commands: range <cm> | icondist <cm> | icon [on|off|dist <cm>] | interval <sec> | expand | toggle | notify | debug [on|off]",
        MOD_NAME, MOD_VERSION,
        CONFIG.ENABLED and "ON" or "OFF",
        formatRangeLabel(getHero()),
        formatIconDisplayLabel(),
        iconPatchEnabled and "ON" or "OFF",
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
    local function readNumber(value, current, minimum)
        local number = tonumber(value)
        if number == nil then return current end
        if minimum ~= nil and number < minimum then return current end
        return number
    end

    local function applyExternalConfig(external)
        if type(external) ~= "table" then return end

        if external.ENABLED ~= nil then CONFIG.ENABLED = external.ENABLED ~= false end
        if external.SHOW_PICKUP_UI ~= nil then
            CONFIG.SHOW_PICKUP_UI = external.SHOW_PICKUP_UI ~= false
        end
        if external.ICON_RANGE_PATCH ~= nil then
            iconPatchEnabled = external.ICON_RANGE_PATCH ~= false
        end
        if external.EXPAND_OPERATABLE ~= nil then
            expandOperatable = external.EXPAND_OPERATABLE ~= false
        end
        if external.DEBUG_HOOKS ~= nil then
            DEBUG_HOOKS = external.DEBUG_HOOKS == true
        end

        CONFIG.PICKUP_RANGE = readNumber(external.PICKUP_RANGE, CONFIG.PICKUP_RANGE, 0)
        CONFIG.ICON_DISPLAY_RANGE =
            readNumber(external.ICON_DISPLAY_RANGE, CONFIG.ICON_DISPLAY_RANGE, 0)
        pickupInterval = readNumber(external.PICKUP_INTERVAL, pickupInterval, 0)
    end

    -- Mirrors the `autopickup range` console path: every cache keyed off the old
    -- radius has to be dropped or the new one only takes effect for items that
    -- happen to be seen for the first time.
    local function activateExternalConfig()
        expandedGimmicks = {}
        nearbyExpanded = {}
        lastAppliedTakeItemDist = nil
        lastIconDbgKey = nil
        scheduleIconRangePatch(100)
        pcall(function() applyHeroPickupRange(resolveHero()) end)
    end

    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local scriptDirectory = source:match("^(.*[\\/])")

    local function loadModMenuBridge()
        local required, bridge = pcall(require, "ModMenuBridge")
        if required and type(bridge) == "table" then return bridge end
        for _, path in ipairs({
            (scriptDirectory or "") .. "../../shared/ModMenuBridge.lua",
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
            modName = "AutoPickupMod",
            scriptDir = scriptDirectory,
            load = applyExternalConfig,
            apply = activateExternalConfig,
            log = function(message) print("[AutoPickupMod] " .. tostring(message) .. "\n") end,
        })
    else
        print("[AutoPickupMod] ModMenuBridge unavailable; settings apply on restart only\n")
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
