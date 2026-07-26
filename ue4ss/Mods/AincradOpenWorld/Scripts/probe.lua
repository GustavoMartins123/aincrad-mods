-- AincradOpenWorld — FEASIBILITY PROBE.
-- Finding so far: a floor's field is a World Partition map (e.g. PL_WL01_WP) that already streams the
-- whole floor around the player; a quest just drops RODQuestBarrier actors to fence you into the
-- objective. So "free-roam Floor 1" ~= be in the WP field + remove the barriers, and WP streams the rest.
--
-- Console (game console must be enabled):
--   ow recon      -- dump world/quest/WLM state (also auto-logs ~2s after each map load)
--   ow barriers   -- list each RODQuestBarrier (location + collision/visibility)
--   ow drop       -- disable barriers (collision off + hidden) so you can try to walk past
--   ow restore    -- re-enable barriers
-- All read/actor-property writes only — no native quest calls. Guarded against transition teardown.
print("[OpenWorld] probe loading...")

local DIR = (function()
    local s = debug.getinfo(1, "S").source
    if s:sub(1, 1) == "@" then s = s:sub(2) end
    return s:match("^(.*[\\/])") or "./"
end)()

local function log(m) print("[OpenWorld] " .. m) end
local function isValid(o) if o == nil then return false end local ok,v = pcall(function() return o:IsValid() end) return ok and v == true end
local function classOf(o) local n="?" pcall(function() n=o:GetClass():GetFName():ToString() end) return n end
local function fullName(o) local n="?" pcall(function() n=o:GetFullName() end) return n end
local function allOf(className)
    local out = {}
    local ok, arr = pcall(function() return FindAllOf(className) end)
    if ok and arr then for _, o in ipairs(arr) do if isValid(o) then out[#out+1] = o end end end
    return out
end
local function firstOf(className) local o pcall(function() o = FindFirstOf(className) end) if isValid(o) then return o end return nil end
local function vec(o)
    local x,y,z = "?","?","?"
    pcall(function() local v = o:K2_GetActorLocation(); x=math.floor(v.X); y=math.floor(v.Y); z=math.floor(v.Z) end)
    return string.format("(%s, %s, %s)", tostring(x), tostring(y), tostring(z))
end

local mapLeaving = false
local mapClean   -- forward decl (defined below; called from mapPlace)
pcall(function() RegisterLoadMapPreHook(function() mapLeaving = true end) end)

-- Out-of-bounds neuter. The demo OOB is the GA_AvatarOutOfQuestArea ability: on leaving the quest area
-- it activates and, after WaitTime_OutOfQuestArea seconds, punishes you. Set that wait huge so it never
-- fires; also hook activation to re-patch new instances. (Technique credit: Yui_NoDemoBounds reference.)
local OOB_FN   = "/Game/ROD/GameplayAbilities/Avatar/Action/GA_AvatarOutOfQuestArea.GA_AvatarOutOfQuestArea_C:K2_ActivateAbility"
local OOB_HUGE = 999999.0
local oobOn, oobHooked = false, false

local function patchOOB(ability, src)
    if not isValid(ability) then return end
    local before; pcall(function() before = ability.WaitTime_OutOfQuestArea end)
    pcall(function() ability.WaitTime_OutOfQuestArea = OOB_HUGE end)
    log(string.format("oob: WaitTime %s -> %s (%s)", tostring(before), tostring(OOB_HUGE), src))
end

local function hookOOB()
    if oobHooked then return end
    local ok = pcall(function()
        RegisterHook(OOB_FN, function(ctx)
            if not oobOn then return end
            local a; if pcall(function() a = ctx:get() end) then patchOOB(a, "activate") end
        end)
    end)
    if ok then oobHooked = true; log("oob: activation hook registered")
    else log("oob: hook not available yet (enter a quest first, then re-run)") end
end

local function scanOOB()
    local n = 0
    pcall(function()
        ForEachUObject(function(o)
            local nm; pcall(function() nm = o:GetFullName() end)
            if type(nm) == "string" and nm:find("GA_AvatarOutOfQuestArea", 1, true) and nm:find("_C_", 1, true) then
                patchOOB(o, "scan"); n = n + 1
            end
        end)
    end)
    log("oob: scan patched " .. n .. " live instance(s)")
end

local function recon()
    if mapLeaving then return end
    log("================= RECON =================")
    local pc = firstOf("RODWorldPlayerController") or firstOf("RODInGamePlayerController") or firstOf("PlayerController")
    log("PlayerController: " .. (pc and classOf(pc) or "NOT FOUND"))
    local gs = firstOf("RODWorldGameState") or firstOf("RODGameState")
    log("GameState: " .. (gs and classOf(gs) or "NOT FOUND"))
    if pc then local wn="?" pcall(function() wn = pc:GetWorld():GetFName():ToString() end) log("World: " .. wn) end
    for _, obj in ipairs({ gs, pc }) do
        if obj then local fi if pcall(function() fi = obj:GetFloorIndex() end) and fi ~= nil then
            log("GetFloorIndex() -> " .. tostring(fi) .. " (on " .. classOf(obj) .. ")"); break end end
    end
    log("WLM roots: " .. #allOf("RODWLMRoot") .. " | barriers: " .. #allOf("RODQuestBarrier") ..
        " | terminals: " .. #allOf("RODQuestTerminalBase") .. " | initPopAreas: " .. #allOf("RODInitPopAreaVolume") ..
        " | popAreas: " .. #allOf("RODPopAreaVolume") .. " | enemies: " .. #allOf("RODEnemyCharacter"))
    log("=========================================")
end

-- Reveal the whole floor on the map: ARODInGamePlayerController:DebugMapPieceMaskOpen(true) opens every
-- map piece's mask (the quest normally only reveals its section).
local function revealMap()
    local pc = firstOf("RODWorldPlayerController") or firstOf("RODInGamePlayerController")
    if not pc then log("map: no player controller"); return end
    local ok = pcall(function() pc:DebugMapPieceMaskOpen(true) end)
    log(ok and "map: opened all piece masks (full floor should show)" or "map: DebugMapPieceMaskOpen failed")
end

-- Try to enumerate a UE4SS TMap several ways; returns count, sampleKeys, method. -1 = unreadable.
local function tmapInfo(tm)
    local keys = {}
    local function addk(k)
        if #keys < 10 then
            local s
            pcall(function() s = k:get():ToString() end)          -- RemoteUnrealParam unwrap
            if type(s) ~= "string" then pcall(function() s = k:ToString() end) end
            if type(s) ~= "string" then s = tostring(k) end
            keys[#keys + 1] = s
        end
    end
    -- 1) ForEach (UE4SS TMap)
    local c = 0
    if pcall(function() tm:ForEach(function(k, v) c = c + 1; addk(k) end) end) and c >= 0 then
        return c, keys, "ForEach"
    end
    -- 2) pairs (if wrapped as a Lua table)
    c = 0; keys = {}
    local ok = pcall(function() for k, _ in pairs(tm) do c = c + 1; addk(k) end end)
    if ok and c > 0 then return c, keys, "pairs" end
    -- 3) Num()
    local n
    if pcall(function() n = tm:Num() end) and type(n) == "number" then return n, keys, "Num" end
    return -1, keys, "unreadable"
end

local function mapInfo()
    log("--------------- MAP INFO ---------------")
    -- what the current quest declares for the detailed map
    local qm = firstOf("RODQuestManager")
    log("QuestManager: " .. (qm and classOf(qm) or "NOT FOUND"))
    if qm then
        local done = pcall(function()
            local tm = qm.QuestMapPieceData.QuestMapPieceDataDetails
            local n, keys, how = tmapInfo(tm)
            log(string.format("  quest pieces: %d (via %s)  [%s]", n, how, table.concat(keys, ", ")))
        end)
        if not done then log("  QuestMapPieceData: could not access") end
    end
    -- the floor's FULL piece set (source we'd inject from)
    local assets = allOf("RODMapPieceDataAsset")
    log("MapPieceDataAsset instances: " .. #assets)
    for i, a in ipairs(assets) do
        pcall(function()
            local n, keys, how = tmapInfo(a.MapPieceData)
            log(string.format("  [%d] floor pieces: %d (via %s)  [%s]", i, n, how, table.concat(keys, ", ")))
        end)
    end
    log("---------------------------------------")
end

-- Spawn-system recon: what enemy-population machinery exists around the player right now.
-- Run once INSIDE the quest area and once out in a dead zone; compare. Field enemies spawn when the
-- hero enters an ARODFLDCharAreaVolume (groups resolved via CharacterGroupLotTable); quests also use
-- PopAreaVolume/InitPopAreaVolume. If volumes exist out there but stay silent -> gating logic; if they
-- don't exist at all -> their WP cells/data layers aren't loaded for non-quest regions.
local function heroPos()
    local h = firstOf("RODWorldHeroCharacter") or firstOf("RODHeroCharacter")
    if not h then return nil end
    local v
    pcall(function() v = h:K2_GetActorLocation() end)
    return v
end

local function dist(a, b)
    if not a or not b then return -1 end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.floor(math.sqrt(dx*dx + dy*dy + dz*dz) / 100)   -- meters
end

local function popRecon()
    local hp = heroPos()
    log("--------------- POP RECON ---------------")
    log("hero at: " .. (hp and string.format("(%.0f, %.0f, %.0f)", hp.X, hp.Y, hp.Z) or "?"))
    local groups = {
        { "RODFLDCharAreaVolume",           function(o) local n="?" pcall(function() n=o.NameForUnique:ToString() end) return "key="..n end },
        { "RODPopAreaVolume",               function(o) local n="?" pcall(function() n=o.EnemyPopAreaTableKey:ToString() end) return "enemyKey="..n end },
        { "RODInitPopAreaVolume",           function(o) local n=0 pcall(function() n=#o.InitPopAreaTableKeys end) return "keys="..n end },
        { "RODEnemyGeneratedActorController", function() return "" end },
        { "RODEnemyCharacter",              function() return "" end },
    }
    for _, g in ipairs(groups) do
        local cls, describe = g[1], g[2]
        local list = allOf(cls)
        log(cls .. ": " .. #list)
        -- show nearest few with distance
        local rows = {}
        for _, o in ipairs(list) do
            local ol
            pcall(function() ol = o:K2_GetActorLocation() end)
            rows[#rows + 1] = { o = o, d = dist(hp, ol) }
        end
        table.sort(rows, function(a, b) return (a.d >= 0 and a.d or 1e9) < (b.d >= 0 and b.d or 1e9) end)
        for i = 1, math.min(#rows, 5) do
            local r = rows[i]
            local col = "?"
            pcall(function() col = tostring(r.o:GetActorEnableCollision()) end)
            log(string.format("   %.0fm  %s  %s  collision=%s", r.d, classOf(r.o), describe(r.o), col))
        end
    end
    log("-----------------------------------------")
end

-- World Partition data layers: a quest activates only its regions' content layers (spawn volumes, map
-- pieces, gimmicks) while base terrain streams everywhere. UDataLayerManager:
-- SetDataLayerInstanceRuntimeState(inst, state, recursive) is BlueprintCallable (stable UFunction call).
-- EDataLayerRuntimeState: 0=Unloaded 1=Loaded 2=Activated.
local STATE_NAME = { [0]="Unloaded", [1]="Loaded", [2]="Activated" }
local function layerName(inst)
    local n = "?"
    pcall(function() n = inst.DataLayerAsset:GetFName():ToString() end)
    if n == "?" then pcall(function() n = inst:GetDataLayerFullName() end) end
    if n == "?" then n = fullName(inst) end
    return n
end

local function getLayerManager()
    local m = firstOf("DataLayerManager")
    if m then return m end
    return nil
end

local function listLayers()
    local mgr = getLayerManager()
    log("DataLayerManager: " .. (mgr and "found" or "NOT FOUND"))
    local insts = allOf("DataLayerInstanceWithAsset")
    if #insts == 0 then insts = allOf("DataLayerInstance") end
    log("data layer instances: " .. #insts)
    for i, inst in ipairs(insts) do
        local st = -1
        if mgr then pcall(function() st = mgr:GetDataLayerInstanceRuntimeState(inst) end) end
        log(string.format("  [%d] %s  state=%s", i, layerName(inst), STATE_NAME[tonumber(st)] or tostring(st)))
    end
end

local function activateAllLayers()
    local mgr = getLayerManager()
    if not mgr then log("layers: no DataLayerManager"); return end
    local insts = allOf("DataLayerInstanceWithAsset")
    if #insts == 0 then insts = allOf("DataLayerInstance") end
    local changed, failed = 0, 0
    for _, inst in ipairs(insts) do
        local ok, res = pcall(function() return mgr:SetDataLayerInstanceRuntimeState(inst, 2, true) end)
        if ok and res ~= false then changed = changed + 1 else failed = failed + 1 end
    end
    log(string.format("layers: activated %d / %d instances (%d failed). Roam and watch for spawners/enemies/map pieces.",
        changed, changed + failed, failed))
end

-- Terminal-keyed region activation. Regions of a floor are identified by TerminalID (the quest map's
-- FieldPiece keys ARE TerminalIDs). GameState holds CurrentActivatedTerminalIDs / FloorActivated... /
-- AvailableTerminalIDs; PlayerState:ClientActivateTerminal(FName) activates one region — the suspected
-- per-region init trigger (spawns, gimmicks, map piece).
local function arrN(a) local n=0 if not pcall(function() n=#a end) then pcall(function() n=a:Num() end) end return n end
local function arrG(a,i) local e pcall(function() e=a[i] end) return e end
local function fnameStr(v)
    local s
    pcall(function() s = v:get():ToString() end)
    if type(s) ~= "string" then pcall(function() s = v:ToString() end) end
    if type(s) ~= "string" then s = tostring(v) end
    return s
end
local function readNameArray(obj, field)
    local out = {}
    pcall(function()
        local a = obj[field]
        for i = 1, arrN(a) do out[#out+1] = fnameStr(arrG(a, i)) end
    end)
    return out
end

local function dumpTerminals()
    local gs = firstOf("RODWorldGameState") or firstOf("RODGameState")
    if not gs then log("terms: no GameState"); return end
    for _, f in ipairs({ "CurrentActivatedTerminalIDs", "FloorActivatedTerminalIDs", "AvailableTerminalIDs" }) do
        local t = readNameArray(gs, f)
        log(string.format("terms: %s (%d): %s", f, #t, table.concat(t, ", ")))
    end
end

local function activateTerminals(only)
    local ps = firstOf("RODWorldPlayerState") or firstOf("RODPlayerState")
    if not ps then log("activate: no PlayerState"); return end
    local gs = firstOf("RODWorldGameState") or firstOf("RODGameState")
    local targets = {}
    if only then
        targets = { only }
    else
        -- everything the floor offers that isn't already active
        local active = {}
        for _, id in ipairs(readNameArray(gs, "CurrentActivatedTerminalIDs")) do active[id] = true end
        for _, id in ipairs(readNameArray(gs, "AvailableTerminalIDs")) do
            if not active[id] then targets[#targets+1] = id end
        end
    end
    local n = 0
    for _, id in ipairs(targets) do
        local ok = pcall(function() ps:ClientActivateTerminal(FName(id)) end)
        if ok then n = n + 1 end
        log("activate: ClientActivateTerminal(" .. id .. ") " .. (ok and "ok" or "FAILED"))
    end
    log("activate: done (" .. n .. "/" .. #targets .. ")")
end

-- PROBE 1: watch quest selection. ServerDecideQuest (PlayerState RPC, fired by the terminal UI) and
-- DecideQuest (GameState) go through ProcessEvent -> hookable. Logging their params shows where the
-- quest's region set originates. Param READS here are probe-only (this machine), not shipped code.
local function readFNameArrParam(p)
    local out = {}
    pcall(function()
        local a = p:get()
        for i = 1, arrN(a) do out[#out+1] = fnameStr(arrG(a, i)) end
    end)
    return table.concat(out, ", ")
end

pcall(function()
    RegisterHook("/Script/ROD.RODPlayerState:ServerDecideQuest",
        function(ctx, qid, omit, force, tier, dbgFloor, qterm, fterm, amu, fix, seals)
            local function gv(p) local v pcall(function() v = p:get() end) return tostring(v) end
            log("ServerDecideQuest fired: QuestId=" .. gv(qid) .. " Omit=" .. gv(omit) ..
                " Force=" .. gv(force) .. " Tier=" .. gv(tier) .. " DebugFloor=" .. gv(dbgFloor))
            log("  QuestTerminalIDs: [" .. readFNameArrParam(qterm) .. "]")
            log("  FloorTerminalIDs: [" .. readFNameArrParam(fterm) .. "]")
            log("  AmuletIDs: [" .. readFNameArrParam(amu) .. "]  FixBoxIDs: [" .. readFNameArrParam(fix) .. "]")
        end)
    log("decide watch: ServerDecideQuest hooked")
end)
pcall(function()
    RegisterHook("/Script/ROD.RODGameState:DecideQuest", function(ctx, qid, omit, tier, force, dbgFloor)
        local function gv(p) local v pcall(function() v = p:get() end) return tostring(v) end
        log("DecideQuest fired: QuestId=" .. gv(qid) .. " Omit=" .. gv(omit) .. " Tier=" .. gv(tier) ..
            " Force=" .. gv(force) .. " DebugFloor=" .. gv(dbgFloor))
    end)
    log("decide watch: DecideQuest hooked")
end)

-- PROBE 2: try to GROW the detailed quest map. QuestManager.QuestMapPieceData.QuestMapPieceDataDetails
-- is the TMap of pieces the detailed map shows (quest declares ~4 of the floor's 72). Attempt to insert
-- a new key reusing an existing entry's value as donor (wrong texture is fine — this only tests whether
-- UE4SS can grow the TMap at all; count re-check tells the truth).
local function growQuestMap(key)
    key = key or "SA_Plains1_1_02"
    local qm = firstOf("RODQuestManager")
    if not qm then log("mapgrow: no QuestManager"); return end
    local tm
    if not pcall(function() tm = qm.QuestMapPieceData.QuestMapPieceDataDetails end) or tm == nil then
        log("mapgrow: cannot access QuestMapPieceDataDetails"); return
    end
    local count0, donor = 0, nil
    pcall(function() tm:ForEach(function(k, v)
        count0 = count0 + 1
        if donor == nil then
            pcall(function() donor = v:get() end)
            if donor == nil then donor = v end
        end
    end) end)
    if count0 == 0 then log("mapgrow: map empty / unreadable"); return end
    local okIdx = pcall(function() tm[FName(key)] = donor end)
    local okAdd = false
    if not okIdx then okAdd = pcall(function() tm:Add(FName(key), donor) end) end
    local count1 = 0
    pcall(function() tm:ForEach(function() count1 = count1 + 1 end) end)
    log(string.format("mapgrow: key=%s before=%d indexAssign=%s Add=%s after=%d %s",
        key, count0, tostring(okIdx), tostring(okAdd), count1,
        count1 > count0 and "GREW! open the quest-area map and look for the new piece"
                         or "(no growth — TMap insert not supported this way)"))
end

-- Fill the detailed quest map with ALL of the floor's pieces. For each key missing from
-- QuestMapPieceData: Add a donor entry (proven to grow + render), then overwrite its PieceTexture /
-- PieceMask with the key's REAL assets (paths from the offline DA_MapPiece dump; the mask material is
-- what positions a piece on the map canvas, so correct mask = correct placement).
local function loadObj(path)
    local o
    pcall(function() o = StaticFindObject(path) end)
    if isValid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if isValid(o) then return o end
    return nil
end

-- Isolation test: does LoadAsset work at all here? (experimental UE4SS API — test before mapfill)
local function mapLoadTest()
    local path = "/Game/ROD/Widget/MapTexture/FieldMap/WL01_Hills2/T_MapPiece_WL01_Hills2_1_02.T_MapPiece_WL01_Hills2_1_02"
    log("mapload: StaticFindObject first...")
    local o
    pcall(function() o = StaticFindObject(path) end)
    log("mapload: StaticFindObject -> " .. tostring(isValid(o)))
    if not isValid(o) then
        log("mapload: trying LoadAsset (if the game crashes NOW, LoadAsset is the killer)...")
        pcall(function() o = LoadAsset(path) end)
        log("mapload: LoadAsset -> " .. tostring(isValid(o)))
    end
end

-- Fetch a fresh donor value straight from the map (never hold one across Adds: TMap rehash on grow
-- moves storage and dangles any previously fetched value ref -> native crash). Prefer the entry with
-- the MOST texture slots: pieces render one sub-piece per slot (up to 4 variants), and a small donor
-- truncates multi-variant pieces.
local function freshDonor(tm)
    local donor, best = nil, -1
    pcall(function() tm:ForEach(function(k, v)
        local val
        pcall(function() val = v:get() end)
        val = val or v
        local n = -1
        pcall(function() n = arrN(val.QuestMapUsePieceDataDetails) end)
        if n > best then best = n; donor = val end
    end) end)
    return donor, best
end

local function fillQuestMap(retexture)
    local qm = firstOf("RODQuestManager")
    if not qm then log("mapfill: no QuestManager"); return end
    local tm
    if not pcall(function() tm = qm.QuestMapPieceData.QuestMapPieceDataDetails end) or tm == nil then
        log("mapfill: cannot access QuestMapPieceDataDetails"); return
    end
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP or type(pieces) ~= "table" then log("mapfill: wl01_pieces.lua missing/bad"); return end
    -- FName keys are CASE-INSENSITIVE (the quest has WT_Tolbana; the DA has WT_TOLBANA — Add()ing the
    -- latter overwrote the former with donor data). All matching must be case-insensitive.
    local piecesCI = {}
    for key, p in pairs(pieces) do piecesCI[key:lower()] = p end

    local have = {}
    pcall(function() tm:ForEach(function(k) have[fnameStr(k):lower()] = true end) end)
    local missing = {}
    for key in pairs(pieces) do if not have[key:lower()] then missing[#missing+1] = key end end
    table.sort(missing)
    log(string.format("mapfill: existing=%d missing=%d — adding (fresh donor per Add)...",
        (function() local n=0 for _ in pairs(have) do n=n+1 end return n end)(), #missing))

    -- Phase 1: add every missing key, re-fetching the best donor before each single Add.
    local added = 0
    for i, key in ipairs(missing) do
        local donor, slots = freshDonor(tm)
        if donor == nil then log("mapfill: donor fetch failed at #" .. i .. " (" .. key .. "); stopping adds"); break end
        if i == 1 then log("mapfill: donor slots=" .. tostring(slots) .. " (pieces need up to 4)") end
        if pcall(function() tm:Add(FName(key), donor) end) then added = added + 1 end
        if i % 20 == 0 then log("mapfill: progress " .. i .. "/" .. #missing) end
    end
    log("mapfill: phase1 done, added=" .. added)

    -- Phase 2 (only when asked: 'ow mapfill tex'): retexture added entries with their real assets.
    local fixed, texFail = 0, 0
    local trunc, blankFail = 0, 0
    if retexture == "tex" then
        -- also load the floor's MapPiece data asset, in case native code resolves positions from it
        pcall(function()
            local da = LoadAsset("/Game/ROD/DataAssets/WorldAdmin/MapPiece/DA_MapPiece_PL_WL01_WP.DA_MapPiece_PL_WL01_WP")
            log("mapfill: DA_MapPiece loaded=" .. tostring(isValid(da)))
        end)
        log("mapfill: phase2 retexture starting...")
        pcall(function() tm:ForEach(function(k, v)
            local key = fnameStr(k)
            local pieceDef = piecesCI[key:lower()]   -- case-insensitive (FName semantics)
            -- retexture EVERY key we have assets for (originals get their own textures re-applied — a
            -- no-op), so 'mapfill tex' works standalone, not only in the same run as the adds
            if pieceDef then
                local val
                pcall(function() val = v:get() end)
                val = val or v
                local arr
                if pcall(function() arr = val.QuestMapUsePieceDataDetails end) and arr then
                    local n = arrN(arr)
                    if #pieceDef > n then trunc = trunc + 1 end
                    local any = false
                    for i = 1, n do
                        local e = arrG(arr, i)
                        local variant = pieceDef[i]
                        if variant then
                            local tex, mask = loadObj(variant.tex), loadObj(variant.mask)
                            if e and tex and pcall(function() e.PieceTexture = tex end) then any = true end
                            if e and mask then pcall(function() e.PieceMask = mask end) end
                            if not tex or not mask then texFail = texFail + 1 end
                            -- (positions are set at the widget layer by 'ow mapplace' — the quest
                            -- struct's PiecePosition is unreflected and unwritable)
                        elseif e then
                            -- extra donor slot beyond this piece's real variants: BLANK it (a nil
                            -- texture slot renders nothing) instead of duplicating variant 1 — the
                            -- duplicates were the leftover stacked pile on the map.
                            local okNil = pcall(function() e.PieceTexture = nil end)
                            pcall(function() e.PieceMask = nil end)
                            if not okNil then blankFail = blankFail + 1 end
                        end
                    end
                    if any then fixed = fixed + 1 end
                end
            end
        end) end)
        log("mapfill: phase2 done, retextured=" .. fixed .. " assetLoadFails=" .. texFail ..
            " truncatedPieces=" .. trunc .. " blankFails=" .. blankFail ..
            (blankFail > 0 and "  (nil-texture not writable -> duplicates may persist)" or ""))
    end

    local total = 0
    pcall(function() tm:ForEach(function() total = total + 1 end) end)
    log(string.format("mapfill: totalPieces=%d — open the quest-area map", total))
    revealMap()
end

-- Widget-layer placement. URODFieldMapItemWidget.PieceParamMaps (TMap<FName, FPieceImageParam>) is the
-- REFLECTED home of piece placement: { FVector2D position, FVector2D Size, float PerPixel }. The quest
-- struct's position is unreflected, but this is fully read/writable.
local function mapWidgets()
    local ws = allOf("RODFieldMapItemWidget")
    log("mapwidgets: RODFieldMapItemWidget instances = " .. #ws .. (#ws == 0 and "  (open the map screen first?)" or ""))
    for wi, w in ipairs(ws) do
        log("  [" .. wi .. "] " .. fullName(w))
        local shown = 0
        pcall(function()
            w.PieceParamMaps:ForEach(function(k, v)
                shown = shown + 1
                if shown <= 8 then
                    local key = fnameStr(k)
                    local px, py, sx, sy, pp = "?", "?", "?", "?", "?"
                    pcall(function()
                        local val = v:get() or v
                        px = string.format("%.0f", val.position.X); py = string.format("%.0f", val.position.Y)
                        sx = string.format("%.0f", val.Size.X);     sy = string.format("%.0f", val.Size.Y)
                        pp = string.format("%.3f", val.PerPixel)
                    end)
                    log(string.format("     %s pos=(%s,%s) size=(%s,%s) perPixel=%s", key, px, py, sx, sy, pp))
                end
            end)
        end)
        log("     total param entries: " .. shown)
    end
end

-- Write piece placement into every live field-map widget's PieceParamMaps. The widget keys entries by
-- TEXTURE name (e.g. T_MapPiece_WL01_Hornca), one per variant — NOT by TerminalID. Build texName ->
-- {x, y, pp} from the DA dump and update/add accordingly (fresh donor per Add — dangle rule).
local function mapPlace()
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP or type(pieces) ~= "table" then log("mapplace: wl01_pieces.lua missing/bad"); return end
    -- texture basename -> placement
    local byTex = {}
    for _, p in pairs(pieces) do
        for _, variant in ipairs(p) do
            local texName = variant.tex:match("%.([^%.]+)$")
            if texName then byTex[texName:lower()] = { x = variant.x, y = variant.y, pp = p.pp } end
        end
    end
    local wanted = 0; for _ in pairs(byTex) do wanted = wanted + 1 end

    local ws = allOf("RODFieldMapItemWidget")
    if #ws == 0 then log("mapplace: no RODFieldMapItemWidget live (open the map first)"); return end
    for wi, w in ipairs(ws) do
        local tm
        if pcall(function() tm = w.PieceParamMaps end) and tm ~= nil then
            local have, updated = {}, 0
            pcall(function() tm:ForEach(function(k, v)
                local key = fnameStr(k)
                have[key:lower()] = true
                local t = byTex[key:lower()]
                if t then
                    local ok = pcall(function()
                        local val = v:get() or v
                        val.position.X = t.x
                        val.position.Y = t.y
                        if t.pp and t.pp > 0 then val.PerPixel = t.pp end
                    end)
                    if ok then updated = updated + 1 end
                end
            end) end)
            local added = 0
            for texName, _ in pairs(byTex) do
                if not have[texName] then   -- both lowercase
                    local donor
                    pcall(function() tm:ForEach(function(k2, v2)
                        if donor == nil then pcall(function() donor = v2:get() end); if donor == nil then donor = v2 end end
                    end) end)
                    if donor and pcall(function() tm:Add(FName(texName), donor) end) then added = added + 1 end
                end
            end
            local fixedNew = 0
            if added > 0 then
                pcall(function() tm:ForEach(function(k, v)
                    local key = fnameStr(k)
                    local t = byTex[key:lower()]
                    if not have[key:lower()] and t then
                        local ok = pcall(function()
                            local val = v:get() or v
                            val.position.X = t.x
                            val.position.Y = t.y
                            if t.pp and t.pp > 0 then val.PerPixel = t.pp end
                        end)
                        if ok then fixedNew = fixedNew + 1 end
                    end
                end) end)
            end
            log(string.format("mapplace: widget[%d] texKeys=%d updated=%d added=%d fixedNew=%d — close/reopen the map",
                wi, wanted, updated, added, fixedNew))
        end
    end
    mapClean()   -- collapse null-texture (white-box) images left by blanked slots
end

-- Data-side duplicate finder: which texture is referenced by MORE THAN ONE quest-map entry/slot
-- (that's the piece rendered twice), and which keys have no wl01_pieces match (retexture skipped).
local function mapDupes()
    local qm = firstOf("RODQuestManager")
    if not qm then log("mapdupes: no QuestManager"); return end
    local tm
    if not pcall(function() tm = qm.QuestMapPieceData.QuestMapPieceDataDetails end) or tm == nil then
        log("mapdupes: cannot access QuestMapPieceDataDetails"); return
    end
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP then pieces = {} end
    local piecesCI = {}
    for kk, pp in pairs(pieces) do piecesCI[kk:lower()] = pp end
    local texUse = {}   -- texName -> { "key[slot]", ... }
    pcall(function() tm:ForEach(function(k, v)
        local key = fnameStr(k)
        if piecesCI[key:lower()] == nil then log("mapdupes: key with NO piece-table match: " .. key) end
        local val
        pcall(function() val = v:get() end)
        val = val or v
        local arr
        if pcall(function() arr = val.QuestMapUsePieceDataDetails end) and arr then
            for i = 1, arrN(arr) do
                local e = arrG(arr, i)
                local tex
                pcall(function()
                    local t = e.PieceTexture
                    if isValid(t) then tex = t:GetFName():ToString() end
                end)
                if tex then
                    texUse[tex] = texUse[tex] or {}
                    texUse[tex][#texUse[tex] + 1] = key .. "[" .. i .. "]"
                end
            end
        end
    end) end)
    local dupes = 0
    for tex, users in pairs(texUse) do
        if #users > 1 then
            dupes = dupes + 1
            log("mapdupes: " .. tex .. " used by: " .. table.concat(users, ", "))
        end
    end
    log("mapdupes: done (" .. dupes .. " texture(s) multi-referenced)")
end

-- White-box cleanup: UMG renders a null-texture brush as a white rect. Collapse any FieldMap image
-- whose Brush.ResourceObject is invalid. Property reads + SetVisibility on a VALID widget only (no
-- Slot calls — that was the mapimgs crash).
mapClean = function()
    local hidden, scanned = 0, 0
    for _, im in ipairs(allOf("Image")) do
        local fn = fullName(im)
        if fn:find("FieldMap", 1, true) then
            scanned = scanned + 1
            local tex
            pcall(function() tex = im.Brush.ResourceObject end)
            if not isValid(tex) then
                if pcall(function() im:SetVisibility(1) end) then hidden = hidden + 1 end   -- 1 = Collapsed
            end
        end
    end
    log("mapclean: scanned " .. scanned .. " FieldMap images, collapsed " .. hidden .. " null-texture (white) ones")
end

-- Scroll-clamp probe: dump the field widget's pan/zoom knobs; with a value, scale DummyScrollSize
-- (suspected scrollable extent) to test whether panning range grows. Run with the map OPEN.
local function mapScroll(mult)
    local ws = allOf("RODFieldMapItemWidget")
    if #ws == 0 then log("mapscroll: no field-map widget live (open the map first)"); return end
    for wi, w in ipairs(ws) do
        local d, m, cr, rlo, rhi = "?", "?", "?", "?", "?"
        pcall(function() d = tostring(w.DummyScrollSize) end)
        pcall(function() m = tostring(w.MapImageSize) end)
        pcall(function() cr = tostring(w.MapCursorClampRate) end)
        pcall(function() rlo = tostring(w.ReducedScale.Min); rhi = tostring(w.ReducedScale.Max) end)
        log(string.format("mapscroll[%d]: DummyScrollSize=%s MapImageSize=%s CursorClampRate=%s ReducedScale=[%s..%s]",
            wi, d, m, cr, rlo, rhi))
        local f = tonumber(mult)
        if f and f > 0 then
            local okD = pcall(function() w.DummyScrollSize = w.DummyScrollSize * f end)
            local okM = pcall(function() w.MapImageSize = w.MapImageSize * f end)
            local nd, nm = "?", "?"
            pcall(function() nd = tostring(w.DummyScrollSize) end)
            pcall(function() nm = tostring(w.MapImageSize) end)
            log(string.format("mapscroll[%d]: scaled x%s -> DummyScrollSize=%s (ok=%s) MapImageSize=%s (ok=%s) — try panning",
                wi, tostring(f), nd, tostring(okD), nm, tostring(okM)))
        end
    end
end

-- QUEST-MANIFEST PROBE. A quest's setup is driven by its RODQuestPrimaryDataAsset's
-- QuestData.QuestTerminalList (which floor areas to activate -> map pieces, spawn volumes, chests,
-- bounds). Extend that list on the ASSET (in town, BEFORE starting the quest) and the game's own init
-- should activate the whole floor. Targets quest 20036 (QST_Free_20036 -> parent QST_Sub_0036); edit
-- BOTH copies since inheritance resolution is the game's own.
-- Derive the two asset paths from a QuestId: 1xxxx = Main_%04d, 2xxxx = Sub_%04d.
local function questAssetPaths(qid)
    qid = tonumber(qid) or 20036
    local series, num
    if qid >= 20000 then series, num = "Sub", qid - 20000
    else series, num = "Main", qid - 10000 end
    local n4 = string.format("%04d", num)
    return {
        string.format("/Game/ROD/DataAssets/Quests/%s/QST_%s_%s.QST_%s_%s", series, series, n4, series, n4),
        string.format("/Game/ROD/DataAssets/Quests/Free/Free_%s/QST_Free_%d.QST_Free_%d", series, qid, qid),
    }, qid
end

local function readTerminalList(arr)
    local out = {}
    for i = 1, arrN(arr) do out[#out + 1] = fnameStr(arrG(arr, i)) end
    return out
end

local function questProbe(qidArg)
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP or type(pieces) ~= "table" then log("quest: wl01_pieces.lua missing/bad"); return end
    local wanted = {}
    for key in pairs(pieces) do wanted[#wanted + 1] = key end
    table.sort(wanted)

    local QUEST_ASSETS, qid = questAssetPaths(qidArg)
    log("quest: targeting QuestId " .. qid .. " (run this in TOWN, then start THAT quest)")
    for _, path in ipairs(QUEST_ASSETS) do
        local qa = loadObj(path)
        if not isValid(qa) then
            log("quest: NOT loadable: " .. path)
        else
            local arr
            if not pcall(function() arr = qa.QuestData.QuestTerminalList end) or arr == nil then
                log("quest: no QuestData.QuestTerminalList on " .. path)
            else
                local before = readTerminalList(arr)
                local haveCI = {}
                for _, id in ipairs(before) do haveCI[id:lower()] = true end
                local addIdx, addMeth, fails = 0, 0, 0
                for _, key in ipairs(wanted) do
                    if not haveCI[key:lower()] then
                        local n = arrN(arr)
                        -- attempt 1: index-assign one past the end
                        local ok1 = pcall(function() arr[n + 1] = FName(key) end)
                        if ok1 and arrN(arr) > n then
                            addIdx = addIdx + 1
                        else
                            -- attempt 2: TArray:Add / Emplace if exposed
                            local ok2 = pcall(function() arr:Add(FName(key)) end)
                            if not ok2 then ok2 = pcall(function() arr:Emplace(FName(key)) end) end
                            if ok2 and arrN(arr) > n then addMeth = addMeth + 1 else fails = fails + 1 end
                        end
                    end
                end
                local after = arrN(arr)
                log(string.format("quest: %s", path:match("([^/]+)$")))
                log(string.format("  terminals before=%d [%s]", #before, table.concat(before, ", ")))
                log(string.format("  grow: idxAssign=%d addMethod=%d fails=%d -> after=%d %s",
                    addIdx, addMeth, fails, after,
                    after > #before and "GREW — start quest 20036 and observe the floor"
                                     or "(no growth — TArray not growable this way)"))
            end
        end
    end
end

-- Auto quest-manifest re-apply. In-town asset edits show in the quest-select PREVIEW but are LOST on
-- the level transition (assets reload from disk), so vanilla init runs. Re-apply DURING the transition:
-- hooks on the QuestManager's load-completion callbacks + early ClientRestart passes. Also grows the
-- RUNTIME copy (QuestManager.QuestData.QuestTerminalList) in case the asset re-read already happened.
local questAutoId = nil
local questHooksDone = false

local function growTerminalArray(arr, wanted, tag)
    if arr == nil then return -1 end
    local haveCI = {}
    for i = 1, arrN(arr) do haveCI[fnameStr(arrG(arr, i)):lower()] = true end
    local before, grown = arrN(arr), 0
    for _, key in ipairs(wanted) do
        if not haveCI[key:lower()] then
            local n = arrN(arr)
            local ok = pcall(function() arr[n + 1] = FName(key) end)
            if ok and arrN(arr) > n then grown = grown + 1 end
        end
    end
    log(string.format("questauto[%s]: terminals %d -> %d (+%d)", tag, before, arrN(arr), grown))
    return grown
end

-- NOTE: no LoadAsset here. Forcing synchronous asset loads during a level transition caused an engine
-- assert/abort ("Abort signal received"). The construct-time NotifyOnNewObject below catches every fresh
-- asset copy (it fires post-serialization), so transitions never need loading — this only touches the
-- QuestManager's runtime copy via plain property access.
local function questAutoApply(src)
    if not questAutoId then return end
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP or type(pieces) ~= "table" then return end
    local wanted = {}
    for key in pairs(pieces) do wanted[#wanted + 1] = key end
    table.sort(wanted)
    local qm = firstOf("RODQuestManager")
    if qm then
        local arr
        if pcall(function() arr = qm.QuestData.QuestTerminalList end) then
            growTerminalArray(arr, wanted, src .. ":QuestManager")
        end
    end
end

-- Earliest lever: grow the quest asset's QuestTerminalList the moment the asset object is CONSTRUCTED
-- during the transition (before world-load consumers read it). Serialization may overwrite the array
-- right after construction, so re-grow again shortly after, guarded.
local function wantedKeys()
    local okP, pieces = pcall(function() return dofile(DIR .. "wl01_pieces.lua") end)
    if not okP or type(pieces) ~= "table" then return {} end
    local wanted = {}
    for key in pairs(pieces) do wanted[#wanted + 1] = key end
    table.sort(wanted)
    return wanted
end

local function isTargetQuestAsset(obj)
    if not questAutoId then return false end
    local fn = fullName(obj)
    for _, path in ipairs(questAssetPaths(questAutoId)) do
        local base = path:match("([^/%.]+)$")
        if base and fn:find(base, 1, true) then return true end
    end
    return false
end

pcall(function()
    NotifyOnNewObject("/Script/ROD.RODQuestPrimaryDataAsset", function(obj)
        if not questAutoId or not isTargetQuestAsset(obj) then return end
        local wanted = wantedKeys()
        local okB, barrierIds = pcall(function() return dofile(DIR .. "wl01_barriers.lua") end)
        if not okB or type(barrierIds) ~= "table" then barrierIds = {} end
        local function growNow(tag)
            if not isValid(obj) then return end
            local arr
            if pcall(function() arr = obj.QuestData.QuestTerminalList end) then
                growTerminalArray(arr, wanted, tag)
            end
            -- also tell the game to turn OFF every known barrier for this quest (manifest-native)
            local barr
            if pcall(function() barr = obj.QuestData.OffOutQuestBarrierIDs end) and barr ~= nil then
                growTerminalArray(barr, barrierIds, tag .. ":barriers")
            end
        end
        -- construct-only: the notify fires post-serialization (asset already carries its vanilla list)
        -- and re-fires for every fresh copy the engine loads, so no delayed re-grows are needed —
        -- stacked delayed callbacks during streaming contributed to the transition abort.
        growNow("construct")
    end)
end)

-- List-level activation via the game's OWN handler: grow the GameState's activated-terminal arrays and
-- call OnRep_CurrentActivatedTerminalIDs() — the game's own "list changed -> apply activation" routine
-- (same pattern as OnRep_DEF in DefenseStatScaling).
local function activateAllTerminals()
    local gs = firstOf("RODWorldGameState") or firstOf("RODGameState")
    if not gs then log("activateall: no GameState"); return end
    local wanted = wantedKeys()
    for _, field in ipairs({ "CurrentActivatedTerminalIDs", "FloorActivatedTerminalIDs", "AvailableTerminalIDs" }) do
        local arr
        if pcall(function() arr = gs[field] end) and arr ~= nil then
            growTerminalArray(arr, wanted, "gs." .. field)
        else
            log("activateall: cannot access gs." .. field)
        end
    end
    local ok = pcall(function() gs:OnRep_CurrentActivatedTerminalIDs() end)
    log("activateall: OnRep_CurrentActivatedTerminalIDs() " .. (ok and "called ok" or "FAILED") ..
        " — check terminals/map/areas")
end

local function enableQuestAuto(qid)
    questAutoId = tonumber(qid) or 20036
    log("questauto: ON for QuestId " .. questAutoId .. " — re-applies on quest data load + map load")
    if questHooksDone then return end
    questHooksDone = true
    -- QuestManager load-completion callbacks: fire during quest start, ideally before init consumes
    for _, fn in ipairs({
        "/Script/ROD.RODQuestManager:LoadSelectQuestDataCompleted",
        "/Script/ROD.RODQuestManager:LoadingCompleted",
        "/Script/ROD.RODQuestManager:LoadingSoftAssetCompleted",
    }) do
        local ok = pcall(function()
            RegisterHook(fn, function() end, function() questAutoApply(fn:match("([^:]+)$")) end)
        end)
        log("questauto: hook " .. fn:match("([^:]+)$") .. " " .. (ok and "ok" or "FAILED"))
    end
end

local function listBarriers()
    local bs = allOf("RODQuestBarrier")
    log("barriers: " .. #bs)
    for i, b in ipairs(bs) do
        local col, hid = "?", "?"
        pcall(function() col = tostring(b:GetActorEnableCollision()) end)
        pcall(function() hid = tostring(b:IsHidden()) end)
        log(string.format("  [%d] %s @ %s  collision=%s hidden=%s", i, classOf(b), vec(b), col, hid))
    end
end

local function setBarriers(enable)
    local bs = allOf("RODQuestBarrier")
    for _, b in ipairs(bs) do
        pcall(function() b:SetActorEnableCollision(enable) end)
        pcall(function() b:SetActorHiddenInGame(not enable) end)
    end
    log((enable and "restored " or "dropped (collision off + hidden) ") .. #bs .. " barrier(s)" ..
        (enable and "." or ". Try walking past the quest boundary — does the floor stream in?"))
    return #bs
end

-- Auto-activate all data layers EARLY on map load, before the game's init population pass, so its own
-- spawn pass processes the whole floor's InitPopAreaVolumes (mid-session activation is too late — the
-- pass has already run). Toggle with `ow layers auto`. Fires at several early offsets to straddle the
-- unknown init timing.
local autoLayers = false
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    mapLeaving = false
    if autoLayers then
        for _, ms in ipairs({ 50, 400, 1200 }) do
            ExecuteWithDelay(ms, function() ExecuteInGameThread(function()
                if not mapLeaving then pcall(activateAllLayers) end
            end) end)
        end
    end
    if questAutoId then
        for _, ms in ipairs({ 50, 300, 900, 2000 }) do
            ExecuteWithDelay(ms, function() ExecuteInGameThread(function()
                if not mapLeaving then pcall(questAutoApply, "ClientRestart+" .. ms) end
            end) end)
        end
    end
    ExecuteWithDelay(2000, function() ExecuteInGameThread(function() pcall(recon) end) end)
end)

RegisterConsoleCommandHandler("ow", function(_f, params, ar)
    local sub = params[1]
    ExecuteInGameThread(function()
        if sub == "recon" then recon()
        elseif sub == "barriers" then listBarriers()
        elseif sub == "drop" then setBarriers(false)
        elseif sub == "restore" then setBarriers(true)
        elseif sub == "oob" then
            if params[2] == "off" then oobOn = false; log("oob: neuter OFF (existing patches persist until reload)")
            else oobOn = true; hookOOB(); scanOOB(); log("oob: neuter ON") end
        elseif sub == "map" then revealMap()
        elseif sub == "mapinfo" then mapInfo()
        elseif sub == "pop" then popRecon()
        elseif sub == "terms" then dumpTerminals()
        elseif sub == "activate" then activateTerminals(params[2])
        elseif sub == "mapgrow" then growQuestMap(params[2])
        elseif sub == "mapfill" then fillQuestMap(params[2])
        elseif sub == "mapload" then mapLoadTest()
        elseif sub == "mapwidgets" then mapWidgets()
        elseif sub == "mapplace" then mapPlace()
        elseif sub == "mapdupes" then mapDupes()
        elseif sub == "quest" then
            -- accept: ow quest auto [id] | ow quest [id]
            if params[2] == "auto" then enableQuestAuto(params[3]) else questProbe(params[2]) end
        elseif sub == "questauto" or sub == "auto" then enableQuestAuto(params[2])
        elseif sub == "activateall" then activateAllTerminals()
        elseif sub == "mapclean" then mapClean()
        elseif sub == "mapscroll" then mapScroll(params[2])
        elseif sub == "layers" then
            if params[2] == "all" then activateAllLayers()
            elseif params[2] == "auto" then
                autoLayers = not autoLayers
                log("layers: auto-activate on map load = " .. tostring(autoLayers) ..
                    (autoLayers and "  (now re-enter the quest from town)" or ""))
            else listLayers() end
        elseif sub == "free" then   -- one-shot: drop barriers + neuter OOB + reveal full map
            setBarriers(false); oobOn = true; hookOOB(); scanOOB(); revealMap()
            log("free-roam: barriers dropped + OOB neutered + full map revealed")
        else
            log("unrecognized: 'ow " .. tostring(sub) .. " " .. tostring(params[2] or "") .. "'")
            log("usage: ow recon|barriers|drop|restore|oob [off]|map|mapinfo|mapgrow [id]|mapfill [tex]|mapload|mapwidgets|mapplace|mapdupes|mapclean|mapscroll [xN]|quest [id]|questauto [id]|activateall|pop|terms|activate [id]|layers [all|auto]|free")
        end
    end)
    if ar and type(ar) == "userdata" then pcall(function() ar:Log("ow " .. tostring(sub)) end) end
    return true
end)

print("[OpenWorld] probe loaded. In a Floor-1 quest try: ow barriers, then ow drop, then walk out.")
