-- AincradOpenWorld — open up each floor: take any quest and the ENTIRE floor comes alive.
--
-- Mechanism (all of it): a quest's setup is driven by the FQuestData manifest on its
-- RODQuestPrimaryDataAsset. We hook the asset's CONSTRUCTION (NotifyOnNewObject fires
-- post-serialization, and again for every fresh copy the engine loads across the transition) and grow
-- two arrays on it:
--   * QuestData.QuestTerminalList     += every region key of the quest's floor
--   * QuestData.OffOutQuestBarrierIDs += every known barrier ID of the floor
-- The game's own init then activates ALL regions natively: detailed map pieces, spawn volumes and
-- enemies, chests, terminals (exploration-gated activation), and — because the quest area becomes the
-- whole floor — no out-of-quest-area punishment and no blocking barriers. No actor patches, no polling.
--
-- HARD RULE (learned the crash way): never call LoadAsset or stack delayed callbacks during a level
-- transition. Construct-time growth needs neither.
print("[OpenWorld] Loading...")

local DIR = (function()
    local s = (debug.getinfo(1, "S") or {}).source or ""
    if s:sub(1, 1) == "@" then s = s:sub(2) end
    local directory = s:match("^(.*[\\/])")
    if directory == nil then
        error("canonical AincradOpenWorld Scripts directory is unavailable")
    end
    return directory
end)()

local CONFIG_KEYS = {
    ENABLED = true,
    EXCLUDE_QUEST_IDS = true,
    FREE_ROAM_QUESTS = true,
    FREE_ROAM_DESCRIPTION = true,
    DEBUG_LOGS = true,
    PROBE_MODE = true,
}

local function validateConfig(config)
    if type(config) ~= "table" then error("settings must be a table") end
    for key in pairs(config) do
        if not CONFIG_KEYS[key] then error("unknown setting: " .. tostring(key)) end
    end
    if type(config.ENABLED) ~= "boolean" then error("ENABLED must be boolean") end
    if type(config.DEBUG_LOGS) ~= "boolean" then error("DEBUG_LOGS must be boolean") end
    if type(config.PROBE_MODE) ~= "boolean" then error("PROBE_MODE must be boolean") end
    if type(config.EXCLUDE_QUEST_IDS) ~= "table" then
        error("EXCLUDE_QUEST_IDS must be a table")
    end
    for index, questId in ipairs(config.EXCLUDE_QUEST_IDS) do
        if type(questId) ~= "number" or questId < 1
            or questId ~= math.floor(questId) then
            error("EXCLUDE_QUEST_IDS[" .. tostring(index) ..
                "] must be a positive integer")
        end
    end
    if type(config.FREE_ROAM_QUESTS) ~= "table" then
        error("FREE_ROAM_QUESTS must be a table")
    end
    for questId, label in pairs(config.FREE_ROAM_QUESTS) do
        if type(questId) ~= "number" or questId < 1
            or questId ~= math.floor(questId) then
            error("FREE_ROAM_QUESTS keys must be positive integer QuestIds")
        end
        if type(label) ~= "string" or label == "" then
            error("FREE_ROAM_QUESTS labels must be non-empty strings")
        end
    end
    if type(config.FREE_ROAM_DESCRIPTION) ~= "string"
        or config.FREE_ROAM_DESCRIPTION == "" then
        error("FREE_ROAM_DESCRIPTION must be a non-empty string")
    end
end

local MOD_MENU_BRIDGE = (function()
    local path = DIR .. "../../shared/ModMenuBridge.lua"
    local ok, bridge = pcall(function() return dofile(path) end)
    if not ok then error("canonical ModMenuBridge load failed: " .. tostring(bridge)) end
    if type(bridge) ~= "table" then
        error("canonical ModMenuBridge did not return a table")
    end
    return bridge
end)()

local CONFIG = (function()
    local settings, _, info =
        MOD_MENU_BRIDGE.readSettings("AincradOpenWorld", DIR)
    if settings == nil then
        error("canonical settings load failed: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    validateConfig(settings)
    return settings
end)()

local function log(m) if CONFIG.DEBUG_LOGS then print("[OpenWorld] " .. m) end end
-- step logging (debug only): the last "step:" line before a native crash names the culprit —
-- pcall cannot catch access violations, prints can.
local function step(s) if CONFIG.DEBUG_LOGS then print("[OpenWorld] step: " .. s .. "\n") end end
local function isValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- Per-floor content tables (generated offline from the game's DA_MapPiece assets + all 95 QST
-- manifests; see the repo README). Loaded once, lazily.
local FLOOR_FILES = {
    -- frame = the quest-select PREVIEW camera (UsePieceData): floor bbox center + scale fitted so the
    -- whole floor sits inside the widget (calibrated against vanilla authored framings).
    [1] = { pieces = "wl01_pieces.lua", barriers = "wl01_barriers.lua",
            frame = { x = -8000, y = 100000, scale = 0.00115 } },
    [2] = { pieces = "wl02_pieces.lua", barriers = "wl02_barriers.lua",
            frame = { x = 12000, y = -200, scale = 0.00174 } },
}
local floorData = {}

local function getFloorData(floorNum)
    if floorData[floorNum] ~= nil then return floorData[floorNum] end
    local files = FLOOR_FILES[floorNum]
    if not files then
        log("unsupported floor " .. tostring(floorNum) .. "; quest left unchanged")
        return nil
    end
    local regions, barriers = {}, {}
    local okP, pieces = pcall(function() return dofile(DIR .. files.pieces) end)
    if not okP then error("floor pieces load failed: " .. tostring(pieces)) end
    if type(pieces) ~= "table" then error(files.pieces .. " must return a table") end
    for key in pairs(pieces) do regions[#regions + 1] = key end
    table.sort(regions)
    local okB, barr = pcall(function() return dofile(DIR .. files.barriers) end)
    if not okB then error("floor barriers load failed: " .. tostring(barr)) end
    if type(barr) ~= "table" then error(files.barriers .. " must return a table") end
    barriers = barr
    if #regions == 0 then error(files.pieces .. " contains no regions") end
    floorData[floorNum] = { regions = regions, barriers = barriers, frame = files.frame }
    log("floor " .. floorNum .. " tables loaded: " .. #regions .. " regions, " .. #barriers .. " barriers")
    return floorData[floorNum]
end

-- QuestId from the asset name: QST_Free_<id> carries it directly; parents are QST_Main_%04d (1xxxx)
-- and QST_Sub_%04d (2xxxx).
local function questIdOf(fullname)
    local id = fullname:match("QST_Free_(%d+)")
    if id then return tonumber(id) end
    local n = fullname:match("QST_Main_(%d+)")
    if n then return 10000 + tonumber(n) end
    n = fullname:match("QST_Sub_(%d+)")
    if n then return 20000 + tonumber(n) end
    return nil
end

local excluded = {}
for _, id in ipairs(CONFIG.EXCLUDE_QUEST_IDS) do excluded[id] = true end


-- Grow a TArray<FName> in place with case-insensitive dedupe. Index-assign one past the end
-- (proven growth path for this game's UE4SS build).
local function growNameArray(arr, keys)
    local n = 0
    if not pcall(function() n = #arr end) then pcall(function() n = arr:Num() end) end
    local haveCI = {}
    for i = 1, n do
        local s
        pcall(function() s = arr[i]:ToString() end)
        if type(s) == "string" then haveCI[s:lower()] = true end
    end
    local grown = 0
    for _, key in ipairs(keys) do
        if not haveCI[key:lower()] then
            local cur = 0
            if not pcall(function() cur = #arr end) then pcall(function() cur = arr:Num() end) end
            local ok = pcall(function() arr[cur + 1] = FName(key) end)
            if ok then grown = grown + 1; haveCI[key:lower()] = true end
        end
    end
    return grown
end

local function openWorldify(obj)
    if not CONFIG.ENABLED or not isValid(obj) then return end

    local nameOk, fullname = pcall(function() return obj:GetFullName() end)
    if not nameOk or type(fullname) ~= "string" or fullname == "" then
        error("quest asset canonical name is unavailable: " .. tostring(fullname))
    end
    local qid = questIdOf(fullname)
    if qid == nil then return end
    if excluded[qid] then log("skip (excluded): QuestId " .. qid); return end

    local qd
    if not pcall(function() qd = obj.QuestData end) or qd == nil then return end

    -- leave dungeon-type quests alone (procedural WLM worlds, not floor fields)
    local isDungeon = false
    pcall(function() isDungeon = (qd.bDungeonQuest == true) end)
    if isDungeon then log("skip (dungeon quest): QuestId " .. qid); return end

    -- ERODFloor: Dungeon=0, First=1, Second=2, Third=3. Enum reads back numeric.
    local floorOk, floorNum = pcall(function()
        local f = qd.Floor
        if type(f) ~= "number" then
            error("QuestData.Floor is not numeric")
        end
        return f
    end)
    if not floorOk then
        error("QuestData.Floor read failed for QuestId " .. tostring(qid) ..
            ": " .. tostring(floorNum))
    end
    if floorNum == 0 then log("skip (dungeon floor): QuestId " .. qid); return end

    local data = getFloorData(floorNum)
    if not data then log("skip (no tables for floor " .. floorNum .. "): QuestId " .. qid); return end

    local grewR, grewB = 0, 0
    local arr
    if pcall(function() arr = qd.QuestTerminalList end) and arr ~= nil then
        grewR = growNameArray(arr, data.regions)
    end
    if pcall(function() arr = qd.OffOutQuestBarrierIDs end) and arr ~= nil then
        grewB = growNameArray(arr, data.barriers)
    end
    -- reframe the quest-select preview camera to fit the whole floor (UsePieceData lives on the
    -- PARENT asset; copies without it just skip). Without this the preview draws all pieces at the
    -- quest's authored zoom and spills outside the widget.
    local framed = false
    if data.frame then
        framed = pcall(function()
            local up = obj.UsePieceData
            up.PieceCenterPosition.X = data.frame.x
            up.PieceCenterPosition.Y = data.frame.y
            up.MapScale = data.frame.scale
        end)
    end
    if grewR > 0 or grewB > 0 or framed then
        log(string.format("QuestId %d (floor %d): +%d regions, +%d barrier-offs%s",
            qid, floorNum, grewR, grewB, framed and ", preview reframed" or ""))
    end
end

do
    local registered, registerError = pcall(function()
    NotifyOnNewObject("/Script/ROD.RODQuestPrimaryDataAsset", function(obj)
        local ok, openError = xpcall(function()
            openWorldify(obj)
        end, debug and debug.traceback or tostring)
        if not ok then
            print("[OpenWorld] QUEST ACTIVATION ERROR | " .. tostring(openError))
        end
    end)
    end)
    if not registered then
        error("RODQuestPrimaryDataAsset notification registration failed: " ..
            tostring(registerError))
    end
end

-- Dedicated free-roam entries: rewrite the terminal quest list's display names for designated quests.
-- FQuestMenuData.Name/.Description are plain FStrings on QuestManager.QuestMenuData (already-resolved
-- display strings, not localization keys), so a property write renames the entry. Triggered when the
-- quest-list widget constructs (menu opening); a short re-pass catches data built after construct.
-- (Delays are fine here — this happens in town menus, never during a level transition.)
-- resolve a localization key (e.g. "QuestName_Sub_0036") to the displayed text via the game's own
-- Dedicated free-roam entries — renaming the RIGHT data. Lessons from in-game probing:
--  * QuestMenuData.Name holds a LOCALIZATION KEY (writing it -> lookup miss -> blank name).
--  * Widget SetText loses the stamping race (pooled rows re-stamp from data on every refresh).
--  * The loc resolvers (GetGeneralLocalizeText/GetMenuText) can't be detoured on this build.
-- The durable level: FSelectQuestParam { QuestId, QuestName/QuestDescription as RESOLVED FText } —
-- held by the quest menu window (QuestSelectMenuContentArray) and by each row's bound item object
-- (RODQuestMenuListViewItem.QuestParam, the exact source rows re-stamp from). Write those FTexts and
-- the game stamps OUR text itself. A one-shot row sweep fixes rows already stamped this frame.
local kismetTextCache
local function makeText(str)
    if not isValid(kismetTextCache) then
        pcall(function() kismetTextCache = StaticFindObject("/Script/Engine.Default__KismetTextLibrary") end)
    end
    if not isValid(kismetTextCache) then return nil end
    local t
    pcall(function() t = kismetTextCache:Conv_StringToText(str) end)
    return t
end

local function renameParamStruct(p, newName, originals)
    local id
    if not pcall(function() id = p.QuestId end) or type(id) ~= "number" then return false end
    local wrote = false
    pcall(function()
        step("param " .. id .. " read old name")
        local old = p.QuestName:ToString()
        if old == newName then wrote = true; return end -- already ours
        step("param " .. id .. " makeText")
        local t = makeText(newName)
        if t == nil then return end
        step("param " .. id .. " write name")
        p.QuestName = t
        step("param " .. id .. " read back")
        local back = p.QuestName:ToString()
        wrote = (back == newName)
        if wrote and type(old) == "string" and #old > 0 then originals[old] = newName end
    end)
    if wrote and CONFIG.FREE_ROAM_DESCRIPTION then
        pcall(function()
            step("param " .. id .. " write description")
            local t = makeText(CONFIG.FREE_ROAM_DESCRIPTION)
            if t ~= nil then p.QuestDescription = t end
        end)
    end
    step("param " .. id .. " done")
    return wrote
end

-- Duplicated entries carry a SENTINEL id (900000 + base QuestId) in the row-identity data so the
-- list renders them as their own row (the UI dedupes rows by id). Launch-facing params get rewritten
-- back to the real free-variant id before the player can confirm.
local SENTINEL_BASE = 900000
local function baseQuestId(id)
    if type(id) ~= "number" then return nil end
    if id >= SENTINEL_BASE then return id - SENTINEL_BASE end
    if id >= 500000 then return id - 500000 end
    return id
end
local function nameForQuestId(id)
    local names = CONFIG.FREE_ROAM_QUESTS
    local base = baseQuestId(id)
    if base == nil then return nil end
    return names[id] or names[base]
end
local function isSentinel(id) return type(id) == "number" and id >= SENTINEL_BASE end

-- count array length defensively
local function arrLen(arr)
    local n = 0
    if not pcall(function() n = #arr end) then pcall(function() n = arr:Num() end) end
    return n
end

-- DUPLICATION PROBE: append a copy of the designated quest's entry to the menu arrays so BOTH the
-- vanilla entry and a free-roam-labeled duplicate exist (same QuestId; which one was picked is
-- discriminated at ServerDecideQuest time via the select screen's param name). TArray<struct> growth
-- via one-past-end donor assign — unproven for structs, this probe answers it.
-- menu machinery belongs to TOWN terminals only. Never touch the in-quest QuestManager's arrays:
-- growing a TArray reallocates its buffer while native code may be mid-iteration (crash risk), and
-- there is nothing to designate outside town.
local function inMenuWorld()
    local ok, name = pcall(function()
        local pc = FindFirstOf("PlayerController")
        local n = pc:GetWorld():GetName()
        if type(n) ~= "string" then n = n:ToString() end
        return n
    end)
    if not ok or type(name) ~= "string" then
        print("[OpenWorld] MENU WORLD ERROR | canonical world name is unavailable")
        return false
    end
    if name == "PL_ROD" then return false end          -- boot/title
    if name:find("_WP") then return false end           -- floor fields (PL_WL01_WP, ...)
    if name:find("Darkness") or name:find("WLM") then return false end -- dungeons
    return true
end

local function duplicateMenuEntries(src)
    if next(CONFIG.FREE_ROAM_QUESTS) == nil then return end
    if not inMenuWorld() then return end
    local results = {}
    pcall(function()
        local qm = FindFirstOf("RODQuestManager")
        if not isValid(qm) then return end
        local arr = qm.QuestMenuData
        local n = arrLen(arr)
        if n == 0 then return end
        -- group matches per designated quest; a sentinel copy already present -> skip
        local byLabel, sentinelSeen = {}, {}
        for i = 1, n do
            pcall(function()
                local id = arr[i].ID
                local label = nameForQuestId(id)
                if label then
                    if isSentinel(id) then sentinelSeen[label] = true
                    else byLabel[label] = byLabel[label] or i end
                end
            end)
        end
        for label, donorIdx in pairs(byLabel) do
            if not sentinelSeen[label] then
                local cur = arrLen(arr)
                local ok = pcall(function() arr[cur + 1] = arr[donorIdx] end)
                local after = arrLen(arr)
                if ok and after > cur then
                    local idOk = pcall(function()
                        arr[after].ID = SENTINEL_BASE + baseQuestId(arr[donorIdx].ID)
                    end)
                    results[#results + 1] = string.format("menuData: %d->%d GREW sentinel=%s", cur, after, tostring(idOk))
                else
                    results[#results + 1] = string.format("menuData: %d->%d failed", cur, after)
                end
            else
                results[#results + 1] = "menuData: sentinel exists"
            end
        end
    end)
    if #results > 0 then log("dup[" .. tostring(src) .. "]: " .. table.concat(results, " | ")) end
end

local function renameQuestParams(src)
    local names = CONFIG.FREE_ROAM_QUESTS
    if next(names) == nil then return end
    if not inMenuWorld() then return end
    local nameFor = nameForQuestId

    local originals, wroteMenu, wroteItems = {}, 0, 0
    -- convert a launch-facing param that carries a sentinel id: label it and point it back at the
    -- real free-variant id so confirming it starts the actual quest. Vanilla entries are untouched.
    local function convertParam(p)
        local id
        if not pcall(function() id = p.QuestId end) or not isSentinel(id) then return false end
        local newName = nameFor(id)
        if not newName then return false end
        return renameParamStruct(p, newName, originals)
    end
    step("rename[" .. tostring(src) .. "] begin")
    pcall(function()
        local menus = FindAllOf("WBP_Console_QuestMenu_C")
        step("menus: " .. tostring(menus and #menus or 0))
        for mi, menu in ipairs(menus or {}) do
            if not isValid(menu) then goto nextMenu end
            for _, arrName in ipairs({ "QuestSelectMenuContentArray", "NotCompleteQuestArray", "QuestLogArray" }) do
                pcall(function()
                    local arr = menu[arrName]
                    local n = arrLen(arr)
                    step("menu " .. mi .. " " .. arrName .. " len " .. n)
                    for i = 1, n do
                        step("menu " .. mi .. " " .. arrName .. " [" .. i .. "]")
                        pcall(function()
                            if convertParam(arr[i]) then wroteMenu = wroteMenu + 1 end
                        end)
                    end
                end)
            end
            ::nextMenu::
        end
    end)
    -- each row's bound item object (what rows re-stamp from)
    pcall(function()
        local items = FindAllOf("RODQuestMenuListViewItem")
        step("items: " .. tostring(items and #items or 0))
        for ii, item in ipairs(items or {}) do
            step("item [" .. ii .. "]")
            pcall(function()
                if not isValid(item) then return end
                if convertParam(item.QuestParam) then wroteItems = wroteItems + 1 end
            end)
        end
    end)
    -- one-shot sweep: fix rows stamped with the old name before our writes landed
    local rowsSet = 0
    if next(originals) ~= nil then
        pcall(function()
            local rows = FindAllOf("WBP_Console_ListItem_Quest_C")
            step("rows: " .. tostring(rows and #rows or 0))
            for ri, row in ipairs(rows or {}) do
                step("row [" .. ri .. "]")
                pcall(function()
                    if not isValid(row) then return end
                    local tb = row.QuestName
                    local newName = originals[tb:GetText():ToString()]
                    if newName then
                        local t = makeText(newName)
                        if t ~= nil then tb:SetText(t); rowsSet = rowsSet + 1 end
                    end
                end)
            end
        end)
    end
    step("rename[" .. tostring(src) .. "] end")
    if wroteMenu > 0 or wroteItems > 0 or rowsSet > 0 or CONFIG.DEBUG_LOGS then
        log(string.format("rename[%s]: menuParams=%d itemParams=%d rowsFixed=%d",
            tostring(src), wroteMenu, wroteItems, rowsSet))
    end
end

-- The terminal's INFO PANEL (right side) resolves name/description from the menu-data keys, which the
-- duplicate shares with the original — but its CurrentQuestId carries the SENTINEL when our entry is
-- selected. Sweep after selection changes: sentinel id -> stamp our label/description onto the
-- QuestName/QuestInfo TextBlocks (single stamp per selection; no re-stamp race here).
local function infoPanelSweep(src)
    local names = CONFIG.FREE_ROAM_QUESTS
    if next(names) == nil then return end
    pcall(function()
        local infos = FindAllOf("WBP_Console_QuestMenu_Info_C")
        local seen, stamped = {}, 0
        for _, info in ipairs(infos or {}) do
            pcall(function()
                if not isValid(info) then return end
                local id = info.CurrentQuestId
                seen[#seen + 1] = tostring(id)
                -- the info panel normalizes free-variant ids by subtracting 500000, so our sentinel
                -- (900000+base) arrives as 400000+base
                local sentinelBase = nil
                if isSentinel(id) then sentinelBase = id
                elseif type(id) == "number" and id >= 400000 and id < 500000 then sentinelBase = id + 500000 end
                if sentinelBase then
                    local label = nameForQuestId(sentinelBase)
                    if label then
                        local t = makeText(label)
                        if t ~= nil and isValid(info.QuestName) then info.QuestName:SetText(t) end
                        if CONFIG.FREE_ROAM_DESCRIPTION then
                            local d = makeText(CONFIG.FREE_ROAM_DESCRIPTION)
                            if d ~= nil and isValid(info.QuestInfo) then info.QuestInfo:SetText(d) end
                        end
                        stamped = stamped + 1
                    end
                end
            end)
        end
        log(string.format("info[%s]: widgets=%d ids=[%s] stamped=%d",
            tostring(src), infos and #infos or -1, table.concat(seen, ","), stamped))
    end)
end

local infoHoverHooked = false
local function tryHookInfoHover()
    if infoHoverHooked then return end
    local ok = pcall(function()
        RegisterHook("/Game/ROD/Widget/Console/Quest/WBP_Console_ListItem_Quest.WBP_Console_ListItem_Quest_C:OnEnterHover", function()
            ExecuteWithDelay(150, function() ExecuteInGameThread(function() pcall(infoPanelSweep, "hover") end) end)
        end)
    end)
    if ok then infoHoverHooked = true; log("info panel: hover hook registered") end
end

-- Trigger: the quest menu is PRE-CONSTRUCTED and reused, so Construct-style triggers never fire.
-- Hook the window's own open event (WBP_Console_QuestMenu_C:MenuOpenAnimation), registering AFTER
-- LoadAsset of the widget class, with retries — the class isn't loaded at mod start on a fresh boot.
-- Rename runs shortly after open (list populates during the animation). LoadAsset here runs from
-- town/menu contexts, never mid-transition.
local QUESTMENU_CLASS = "/Game/ROD/Widget/Console/Quest/WBP_Console_QuestMenu.WBP_Console_QuestMenu_C"
local QUESTMENU_OPEN  = QUESTMENU_CLASS .. ":MenuOpenAnimation"
local renameHooked = false

local function tryHookQuestMenu(tries)
    if renameHooked then return end
    pcall(function() LoadAsset(QUESTMENU_CLASS) end)
    local ok = pcall(function()
        RegisterHook(QUESTMENU_OPEN, function()
            -- 600ms, not 300: starting the pass while the list is still building its rows raced
            -- native construction (reproducible crash at the Urbas terminal, where two designated
            -- donors coexist). The list finishes populating well inside the open animation.
            ExecuteWithDelay(600, function() ExecuteInGameThread(function() pcall(duplicateMenuEntries, "menuOpen+600") pcall(renameQuestParams, "menuOpen+600") pcall(infoPanelSweep, "menuOpen+600") end) end)
            ExecuteWithDelay(1200, function() ExecuteInGameThread(function() pcall(renameQuestParams, "menuOpen+1200") end) end)
        end)
    end)
    if ok then
        renameHooked = true
        log("rename: quest-menu open hook registered")
    elseif tries > 0 then
        ExecuteWithDelay(5000, function() ExecuteInGameThread(function() tryHookQuestMenu(tries - 1) end) end)
    else
        log("rename: quest-menu open hook FAILED after retries")
    end
end

-- extra triggers: the sub-quest LIST page's Construct (fires when the terminal's list page builds)
-- and row hover (fires constantly while browsing — keeps renames applied across tab switches and
-- scrolling; idempotent, renamed rows no longer match an original name)
local subListHooked = false
local function tryHookSubList()
    if subListHooked then return end
    local ok = pcall(function()
        RegisterHook("/Game/ROD/Widget/Console/Quest/WBP_Console_Quest_SubQuestList.WBP_Console_Quest_SubQuestList_C:Construct", function()
            -- 600ms, not 200 — same construction race as the menu-open pass (see above)
            ExecuteWithDelay(600, function() ExecuteInGameThread(function() pcall(duplicateMenuEntries, "subList+600") pcall(renameQuestParams, "subList+600") end) end)
        end)
    end)
    if ok then subListHooked = true; log("rename: sub-quest list hook registered") end
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(3000, function() ExecuteInGameThread(function()
        tryHookQuestMenu(3)
        tryHookSubList()
        tryHookInfoHover()
        pcall(duplicateMenuEntries, "settle") pcall(renameQuestParams, "settle")
    end) end)
end)

-- SELECTION DISCRIMINATOR: the duplicate rows carry the sentinel id all the way to
-- ServerDecideQuest — a sentinel id at decide time MEANS the player picked the free-roam entry.
-- Rewrite the scalar QuestId param to the real free-variant id so the quest actually starts (plain
-- int param write; NOT the const-struct-ref mutation class that proved version-fragile).
pcall(function()
    RegisterHook("/Script/ROD.RODPlayerState:ServerDecideQuest", function(ctx, questIdParam)
        pcall(function()
            local id = questIdParam:get()
            if isSentinel(id) then
                local realId = 500000 + baseQuestId(id)
                questIdParam:set(realId)
                log(string.format("decide: FREE ROAM entry picked (%d -> %d)", id, realId))
            end
        end)
    end)
end)

-- Runtime settings. Only partly live by design: the floor is opened by growing
-- arrays on each quest manifest as it is CONSTRUCTED, so flipping ENABLED here
-- affects quests loaded from that point on and cannot retract a floor that is
-- already open. DEBUG_LOGS takes effect immediately. The Mods menu labels this
-- mod as restart-required for exactly this reason.
do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = "AincradOpenWorld",
        scriptDir = DIR,
        pollMs = 750,
        load = function(external)
            validateConfig(external)
            -- CONFIG is captured by every closure in this file, so refresh it
            -- in place rather than rebinding the local.
            for key in pairs(CONFIG) do CONFIG[key] = nil end
            for key, value in pairs(external) do CONFIG[key] = value end
            for key in pairs(excluded) do excluded[key] = nil end
            for _, questId in ipairs(CONFIG.EXCLUDE_QUEST_IDS) do
                excluded[questId] = true
            end
        end,
        fail = function()
            CONFIG.ENABLED = false
            CONFIG.PROBE_MODE = false
            CONFIG.FREE_ROAM_QUESTS = {}
        end,
        log = function(message) print("[OpenWorld] " .. tostring(message)) end,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

if CONFIG.PROBE_MODE then
    pcall(function() dofile(DIR .. "probe.lua") end)
end

print("[OpenWorld] Loaded" .. (CONFIG.ENABLED and "" or " (DISABLED)") ..
    " — take any quest and the whole floor comes alive." ..
    (CONFIG.PROBE_MODE and " [probe active]" or ""))
