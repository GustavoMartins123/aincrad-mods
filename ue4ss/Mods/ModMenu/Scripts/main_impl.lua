-- ModMenu v1.5.6
-- Adds a native-styled "Mods" entry to Echoes of Aincrad's start menu, opening a
-- panel that enables/disables the other mods and retunes their values in-game.
--
-- The rail injection follows the technique proven by FieldEquipmentMenu: the
-- native list's TArrays cannot be grown safely from UE4SS Lua, so the row is a
-- MenuIcon clone parked in a donor wrapper appended to the same VerticalBox, and
-- only the navigation boundaries around it are bridged.
--
-- Changes are persisted to the target mod's Scripts/runtime.lua and picked up by
-- ModMenuBridge, which that mod loads itself. ModMenu never reaches into another
-- mod's Lua state, because UE4SS gives each mod its own.

local MOD_NAME = "ModMenu"
local MOD_VERSION = "v1.5.6"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu.WBP_Console_MainMenu_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"

local MAX_NATIVE_MENU_ITEMS = 7
local MENU_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C"

-- Confirmed against the native switch in FieldEquipmentMenu.
local ACCEPT_BUTTON = 1
local BACK_BUTTON = 2
local DPAD_UP = 13
local DPAD_DOWN = 14
local DPAD_LEFT = 15
local DPAD_RIGHT = 16
local LSTICK_UP = 17
local LSTICK_DOWN = 18
-- Codes 15 and 16 were observed directly in UE4SS.log from the controller's
-- horizontal D-pad. Analog horizontal codes remain deliberately unregistered
-- until they are observed rather than inferred.

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2

local SCRIPT_DIR = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local directory = source:match("^(.*[\\/])")
    if directory == nil then
        error("canonical ModMenu Scripts directory is unavailable")
    end
    return directory
end)()

local CONFIG = {
    ENABLED = true,
    DEBUG_LOGS = false,
    -- A letter drawn over the row instead of borrowed art. This is the only icon
    -- path: invalid configuration aborts the row injection explicitly.
    ICON_LETTER = "M",
    -- Calibrated against the native 64x64 rail icon.
    ICON_LETTER_OFFSET = { X = 36.0, Y = 26.0 },
    ICON_TINT = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
}
local logButtons = false

local injectedMenus = {}
local activeContext = nil
local menuCloseBusy = false
local pendingMenuInjections = {}
local menuInjectionTimerScheduled = false
local scheduleMenuInjection

-- The Start Menu's list builds asynchronously and this row borrows a donor
-- list's slot geometry, so the pass must not start before the native build has
-- settled. 600ms is the field-tested floor for a first pass; 200-300ms crashed
-- reproducibly, and worst when a second mod was taking a donor of its own at the
-- same time -- which is exactly this rail, where FastTravelMod borrows one too
-- on any floor with travel destinations. See mod_template techniques/
-- quest-manifest-and-menus.md ("Timing") and ui-widget-techniques.md ("Do not
-- race construction").
--
-- Deliberately 150ms behind FastTravelMod's 600ms rather than equal to it. Both
-- mods take a donor of their own, and letting them land together brought back
-- the load-order race in the rail ordering. Going last is what this row wants
-- anyway -- refreshRailPosition would move it to the end regardless -- and it
-- makes FastTravelMod deterministically the first injected row, so ownership of
-- the boundary with the native rows stops depending on scheduler luck.
local MENU_INJECTION_DELAY_SEC = 0.75

-- Assigned further down, called the first time a Mods row is actually injected.
-- Nothing this mod hooks is useful before a start menu exists, so the input
-- hooks stay unregistered until then and the mod is inert during loading.
local ensureInputHooks

-- Direction input does not reach this mod's button hooks: the native list moves
-- its own focus internally and only reports the result through FocusEvent. These
-- track that reported focus so the list's wrap off the last row can be turned
-- into "enter the Mods row" instead.
local listFocusIndexes = {}
local pendingFocusRedirects = {}
-- Reported once per panel session rather than once per frame.
local warnedFocusWhilePanelOpen = false

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function dbg(message)
    if not CONFIG.DEBUG_LOGS then return end
    log(message)
end

local function isValid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function dereferenceWeakObject(pointer)
    if isValid(pointer) then return pointer end
    if pointer == nil then return nil end
    local ok, object = pcall(function() return pointer:Get() end)
    if ok and isValid(object) then return object end
    return nil
end

local function objectName(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    if ok and name then return tostring(name) end
    return tostring(object)
end

local function unwrap(parameter)
    if parameter == nil then return nil end
    local ok, value = pcall(function() return parameter:get() end)
    if ok then return value end
    return parameter
end

local function contains(value, fragment)
    return string.find(tostring(value or ""), fragment, 1, true) ~= nil
end

--========================================================--
--                      DEPENDENCIES                      --
--========================================================--

local function loadLocalModule(name)
    local ok, result = pcall(function() return dofile(SCRIPT_DIR .. name .. ".lua") end)
    if ok and type(result) == "table" then return result end
    log("could not load " .. name .. ".lua: " .. tostring(result))
    return nil
end

local function loadModMenuBridge()
    local path = SCRIPT_DIR .. "standalone/ModMenuBridge.lua"
    local ok, result = pcall(function() return dofile(path) end)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then
        return nil, "canonical bridge did not return a table"
    end
    return result, nil
end

-- Printed before anything can fail, so an empty console proves the mod was never
-- loaded at all rather than loaded and aborted.
print(string.format("[%s] main.lua entered | script dir: %s\n", MOD_NAME, SCRIPT_DIR))

local bridge, bridgeError = loadModMenuBridge()
local registry = loadLocalModule("registry")
local store = loadLocalModule("store")
local panel = loadLocalModule("panel")

if bridge == nil or registry == nil or store == nil or panel == nil then
    log(string.format("startup aborted | bridge=%s registry=%s store=%s panel=%s",
        tostring(bridge ~= nil), tostring(registry ~= nil),
        tostring(store ~= nil), tostring(panel ~= nil)))
    if bridge == nil then log("bridge error: " .. tostring(bridgeError)) end
    return
end

store.init(SCRIPT_DIR, bridge)

do
    local cleared, clearError = store.clearPreview("GaugeNumbers")
    if not cleared then
        log("GaugeNumbers preview cleanup failed: " .. tostring(clearError))
    end
end

do
    local ok, external = pcall(function() return dofile(SCRIPT_DIR .. "config.lua") end)
    if not ok then error("config.lua load failed: " .. tostring(external)) end
    if type(external) ~= "table" then error("config.lua must return a table") end
    local known = {
        ENABLED = true,
        DEBUG_LOGS = true,
        ICON_LETTER = true,
        ICON_LETTER_OFFSET = true,
        ICON_TINT = true,
    }
    for key in pairs(external) do
        if not known[key] then error("unknown setting: " .. tostring(key)) end
    end
    if type(external.ENABLED) ~= "boolean" then error("ENABLED must be boolean") end
    if type(external.DEBUG_LOGS) ~= "boolean" then
        error("DEBUG_LOGS must be boolean")
    end
    if type(external.ICON_LETTER) ~= "string"
        or external.ICON_LETTER == "" or #external.ICON_LETTER > 3 then
        error("ICON_LETTER must be a non-empty string of at most 3 bytes")
    end
    if type(external.ICON_LETTER_OFFSET) ~= "table" then
        error("ICON_LETTER_OFFSET must be a table")
    end
    for _, axis in ipairs({ "X", "Y" }) do
        if type(external.ICON_LETTER_OFFSET[axis]) ~= "number" then
            error("ICON_LETTER_OFFSET." .. axis .. " must be numeric")
        end
    end
    if type(external.ICON_TINT) ~= "table" then
        error("ICON_TINT must be a table")
    end
    for _, channel in ipairs({ "R", "G", "B", "A" }) do
        local value = external.ICON_TINT[channel]
        if type(value) ~= "number" or value < 0 or value > 1 then
            error("ICON_TINT." .. channel .. " must be between 0 and 1")
        end
    end
    CONFIG.ENABLED = external.ENABLED
    CONFIG.DEBUG_LOGS = external.DEBUG_LOGS
    CONFIG.ICON_LETTER = external.ICON_LETTER
    CONFIG.ICON_LETTER_OFFSET = external.ICON_LETTER_OFFSET
    CONFIG.ICON_TINT = external.ICON_TINT
end

--========================================================--
--                      UI CONTEXT                        --
--========================================================--

local function resolveLocalController()
    local controller = FindFirstOf("RODInGamePlayerController")
    if isValid(controller) then return controller end
    return nil
end

local function resolveUmgLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function resolveTextLibrary()
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
end

local function resolveRodLibrary()
    return StaticFindObject("/Script/ROD.Default__RODWidgetBPFunctionLibrary")
end

panel.init({
    registry = registry,
    store = store,
    log = function(message) log("panel: " .. tostring(message)) end,
    resolveController = resolveLocalController,
    resolveUmgLibrary = resolveUmgLibrary,
})

--========================================================--
--                    RAIL INJECTION                      --
--========================================================--

local function menuItemAndPanel(mainList, index)
    local item = nil
    local wrapper = nil
    pcall(function()
        item = mainList["Item_" .. tostring(index)]
        wrapper = item.Slot.Parent
    end)
    return item, wrapper
end

-- Mirrors FieldEquipmentMenu: NumContent is the final zero-based authored index,
-- and rows the game has progression-hidden are trimmed off the tail.
local function resolveNativeMenuCount(mainMenu, mainList)
    local finalNativeIndex = nil
    pcall(function() finalNativeIndex = tonumber(mainMenu.NumContent) end)
    local count = finalNativeIndex ~= nil and finalNativeIndex + 1 or nil
    if count == nil or count < 1 or count > MAX_NATIVE_MENU_ITEMS then
        count = 0
        for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
            local item = menuItemAndPanel(mainList, index)
            if isValid(item) then count = index + 1 end
        end
    end

    while count > 1 do
        local _, wrapper = menuItemAndPanel(mainList, count - 1)
        local _, previousWrapper = menuItemAndPanel(mainList, count - 2)
        local visibility = nil
        local previousVisibility = nil
        pcall(function() visibility = wrapper:GetVisibility() end)
        pcall(function() previousVisibility = previousWrapper:GetVisibility() end)
        if visibility ~= COLLAPSED and visibility ~= HIDDEN then break end
        if previousVisibility == COLLAPSED or previousVisibility == HIDDEN then break end
        count = count - 1
    end
    return count
end

local function iconInsideWrapper(wrapper)
    if not isValid(wrapper) then return nil end
    local count = nil
    pcall(function() count = wrapper:GetChildrenCount() end)
    if type(count) ~= "number" then return nil end
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = wrapper:GetChildAt(index) end)
        if isValid(child) and contains(objectName(child), MENU_ICON_FRAGMENT) then
            return child
        end
    end
    return nil
end

-- Counts the rows other mods have already appended to this rail, so the Mods
-- entry lands underneath them with a matching item index.
local function countForeignInjectedRows(parent, mainList, nativeCount)
    local authored = {}
    -- The full authored range, not just the active rows. Progression hides the
    -- final entry (Logout) without removing its wrapper, so stopping at
    -- nativeCount leaves that wrapper unaccounted for and it gets miscounted as
    -- another mod's row — which pushes the Mods entry one index too far and makes
    -- it unreachable, because the navigation boundary then looks for a row that
    -- is not the last visible one.
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local _, wrapper = menuItemAndPanel(mainList, index)
        if isValid(wrapper) then authored[objectName(wrapper)] = true end
    end

    local childCount = nil
    pcall(function() childCount = parent:GetChildrenCount() end)
    if type(childCount) ~= "number" then return 0 end

    local foreign = 0
    for index = 0, childCount - 1 do
        local child = nil
        pcall(function() child = parent:GetChildAt(index) end)
        if isValid(child) and not authored[objectName(child)]
            and iconInsideWrapper(child) ~= nil then
            foreign = foreign + 1
        end
    end
    return foreign
end

-- True when another mod's injected row sits above this one on the rail.
--
-- The boundary with the native rows belongs to whichever injected row is
-- physically first, and that has to be re-read from the live tree on every
-- press. foreignRows only says how many other injected rows exist, not where
-- they are, so gating on it made this mod stand down whenever any other row was
-- present at all -- while FastTravelMod had recorded at injection time that it
-- was not the first injected row and had stood down too. On a floor, where both
-- mods inject, that left nobody carrying focus off the last native row and
-- neither custom row could be reached. In town the pair never met, because with
-- no travel destination FastTravelMod injects nothing.
local function hasInjectedRowAbove(context)
    if context == nil then return false end
    local parent = context.wrapperParent
    if not isValid(parent) or not isValid(context.wrapperPanel) then return false end

    local childCount = nil
    pcall(function() childCount = parent:GetChildrenCount() end)
    if type(childCount) ~= "number" then return false end

    local authored = {}
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local _, wrapper = menuItemAndPanel(context.mainList, index)
        if isValid(wrapper) then authored[objectName(wrapper)] = true end
    end

    local ownKey = objectName(context.wrapperPanel)
    for index = 0, childCount - 1 do
        local child = nil
        pcall(function() child = parent:GetChildAt(index) end)
        if isValid(child) then
            local key = objectName(child)
            -- Reaching our own row first means everything above it is native.
            if key == ownKey then return false end
            if not authored[key] and iconInsideWrapper(child) ~= nil then
                return true
            end
        end
    end
    return false
end

-- Draws a letter over the row instead of relying on a texture. The donor wrapper
-- is the CanvasPanel already proven to accept the Mods icon and a TextBlock.
-- Avoid passing FAnchors from Lua: invalid native struct marshaling aborts the
-- whole UE4SS process before pcall can report an error.
local function applyIconLetter(context)
    local letter = CONFIG.ICON_LETTER
    if type(letter) ~= "string" or letter == "" then return false end
    if context == nil or not isValid(context.wrapperPanel) or not isValid(context.icon)
        or not isValid(context.icon.IconImage) then
        return false
    end

    local class = StaticFindObject("/Script/UMG.TextBlock")
    if not isValid(class) then
        log("cannot draw the icon letter: TextBlock class unavailable")
        return false
    end

    local label = nil
    pcall(function() label = StaticConstructObject(class, context.icon) end)
    if not isValid(label) then
        log("cannot draw the icon letter: TextBlock construction failed")
        return false
    end

    pcall(function() label:SetText(FText(letter)) end)
    -- Borrow the row's own label styling so the letter matches the menu's font.
    pcall(function() label:SetFont(context.icon.MenuName.Font) end)
    pcall(function()
        label:SetColorAndOpacity({ SpecifiedColor = CONFIG.ICON_TINT, ColorUseRule = 0 })
    end)

    local slot = nil
    pcall(function() slot = context.wrapperPanel:AddChildToCanvas(label) end)
    if not isValid(slot) then
        log("cannot draw the icon letter: native row wrapper rejected it")
        return false
    end

    local offset = CONFIG.ICON_LETTER_OFFSET
    local positioned, positionError = pcall(function()
        slot:SetAutoSize(true)
        slot:SetPosition({ X = offset.X, Y = offset.Y })
        slot:SetZOrder(30)
        label:SetVisibility(VISIBLE)
        label:SetRenderOpacity(1.0)
        context.icon.IconImage:SetVisibility(HIDDEN)
    end)
    if not positioned then
        pcall(function() label:RemoveFromParent() end)
        log("cannot position the icon letter: " .. tostring(positionError))
        return false
    end

    context.letterWidget = label
    log("row icon replaced with calibrated letter " .. letter)
    return true
end

local function enforceIconLetter(context)
    if context == nil or not isValid(context.icon)
        or not isValid(context.icon.IconImage)
        or not isValid(context.letterWidget) then
        log("centred Mods icon presentation is invalid")
        return false
    end
    local ok, err = pcall(function()
        context.icon.IconImage:SetVisibility(HIDDEN)
        context.letterWidget:SetVisibility(VISIBLE)
        context.letterWidget:SetRenderOpacity(1.0)
    end)
    if not ok then log("could not enforce centred Mods icon: " .. tostring(err)) end
    return ok
end

-- Keeps the Mods row last on the rail and its item index honest.
--
-- The index used to be computed once at injection and then trusted forever,
-- which breaks the moment another mod appends its own row afterwards: Mods stops
-- being the final entry and its cached index points at someone else's row. Mods
-- is a menu about the other mods, so it belongs at the bottom no matter what
-- order anything loaded in. This re-reads the live tree, moves the row back to
-- the end if something slipped in below it, and recomputes the index from what
-- is actually there.
local function refreshRailPosition(context)
    if context == nil then return end
    local parent = context.wrapperParent
    local wrapper = context.wrapperPanel
    if not isValid(parent) or not isValid(wrapper) then return end

    local count = nil
    pcall(function() count = parent:GetChildrenCount() end)
    if type(count) ~= "number" or count <= 0 then return end

    local wrapperKey = objectName(wrapper)
    local ownPosition, lastRowPosition = nil, nil
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = parent:GetChildAt(index) end)
        if isValid(child) and iconInsideWrapper(child) ~= nil then
            lastRowPosition = index
            if objectName(child) == wrapperKey then ownPosition = index end
        end
    end
    if ownPosition == nil then return end

    if lastRowPosition ~= ownPosition then
        -- Something was appended below. Detach and re-append to reclaim the end.
        local moved = pcall(function()
            wrapper:RemoveFromParent()
            parent:AddChildToVerticalBox(wrapper)
        end)
        if moved then
            pcall(function() wrapper:SetVisibility(VISIBLE) end)
            pcall(function() wrapper:ForceLayoutPrepass() end)
            log("another mod appended a row below Mods; moved Mods back to the end")
        end
    end

    -- countForeignInjectedRows counts every injected row including this one, so
    -- the others are one fewer.
    local injected = countForeignInjectedRows(parent, context.mainList, context.nativeCount)
    local others = math.max(0, injected - 1)
    local index = context.nativeCount + others
    if index ~= context.modsIndex or others ~= context.foreignRows then
        context.modsIndex = index
        context.foreignRows = others
        pcall(function() context.icon:SetItemIndex(index) end)
        dbg(string.format("rail position refreshed: index %d (%d native, %d other injected)",
            index, context.nativeCount, others))
    end
end

-- The native list owns the only wrapper geometry that lays a row out correctly,
-- so a throwaway list is created purely to donate its final row's CanvasPanel.
local function attachIconWithNativeWrapper(umgLibrary, controller, parent, icon)
    local listClass = StaticFindObject(MAIN_MENU_LIST_CLASS)
    if not isValid(listClass) then error("native main-menu list class is unavailable") end

    local donorList = umgLibrary:Create(controller, listClass, controller)
    if not isValid(donorList) then error("wrapper donor creation returned null") end

    local donorItem = donorList.Item_6
    local donorItemSlot = isValid(donorItem) and donorItem.Slot or nil
    local donorPanel = isValid(donorItemSlot) and donorItemSlot.Parent or nil
    if not isValid(donorItem) or not isValid(donorItemSlot) or not isValid(donorPanel) then
        error("native wrapper hierarchy is unavailable")
    end

    local layout = nil
    local layoutOk, layoutError = pcall(function()
        local position = donorItemSlot:GetPosition()
        local size = donorItemSlot:GetSize()
        local anchors = donorItemSlot:GetAnchors()
        local alignment = donorItemSlot:GetAlignment()
        layout = {
            position = { X = tonumber(position.X), Y = tonumber(position.Y) },
            size = { X = tonumber(size.X), Y = tonumber(size.Y) },
            minimum = {
                X = tonumber(anchors.Minimum.X),
                Y = tonumber(anchors.Minimum.Y),
            },
            maximum = {
                X = tonumber(anchors.Maximum.X),
                Y = tonumber(anchors.Maximum.Y),
            },
            alignment = {
                X = tonumber(alignment.X),
                Y = tonumber(alignment.Y),
            },
        }
    end)
    if not layoutOk or layout == nil
        or layout.position.X == nil or layout.position.Y == nil
        or layout.size.X == nil or layout.size.Y == nil
        or layout.minimum.X == nil or layout.minimum.Y == nil
        or layout.maximum.X == nil or layout.maximum.Y == nil
        or layout.alignment.X == nil or layout.alignment.Y == nil then
        error("native wrapper layout snapshot failed: " ..
            tostring(layoutError))
    end
    -- The donor icon must be physically removed: collapsing it is not enough
    -- because its original list keeps repainting the icon brush.
    donorItem:RemoveFromParent()
    donorPanel:RemoveFromParent()
    parent:AddChildToVerticalBox(donorPanel)

    local iconSlot = donorPanel:AddChildToCanvas(icon)
    if not isValid(iconSlot) then error("native wrapper rejected the Mods icon") end
    iconSlot:SetMinimum(layout.minimum)
    iconSlot:SetMaximum(layout.maximum)
    iconSlot:SetPosition(layout.position)
    iconSlot:SetSize(layout.size)
    iconSlot:SetAlignment(layout.alignment)
    iconSlot:SetAutoSize(true)
    iconSlot:SetZOrder(20)
    icon:SetVisibility(VISIBLE)
    donorPanel:SetVisibility(VISIBLE)
    pcall(function() donorPanel:ForceLayoutPrepass() end)
    return donorList, donorPanel
end

local function injectModsEntry(mainMenu)
    if not CONFIG.ENABLED then
        log("injection skipped: disabled in config.lua")
        return
    end
    if not isValid(mainMenu) then
        log("injection skipped: the start menu went away before injection ran")
        return
    end
    local menuKey = objectName(mainMenu)
    if injectedMenus[menuKey] ~= nil then
        dbg("already injected into " .. menuKey)
        return
    end

    -- The real start menu is owned by the game's world-space menu component.
    -- Anything of this class without such an owner is a display-only copy — a
    -- mod's overlay, or a widget left over from a discarded world. Injecting
    -- into one replaces activeContext and strands the actual Mods row.
    --
    -- This guard used to be gated on an `inViewport` that was never assigned in
    -- this function, so it was always nil and the guard never fired; the copies
    -- were rejected one layer up, in isCanonicalMainMenuCandidate, which is why
    -- that went unnoticed.
    local parentComponent = nil
    local parentActor = nil
    pcall(function()
        parentComponent = dereferenceWeakObject(mainMenu.ParentComponent)
        parentActor = dereferenceWeakObject(mainMenu.ParentActor)
    end)
    if not isValid(parentComponent) and not isValid(parentActor) then
        injectedMenus[menuKey] = false
        log("ignored display-only main-menu overlay: " .. menuKey)
        return
    end

    log("injecting into " .. menuKey)

    local controller = resolveLocalController()
    local umgLibrary = resolveUmgLibrary()
    local textLibrary = resolveTextLibrary()
    if not isValid(controller) or not isValid(umgLibrary) or not isValid(textLibrary) then
        log("cannot inject Mods entry: UI context is unavailable")
        return
    end

    local mainList = nil
    local firstItem = nil
    local firstWrapper = nil
    local parent = nil
    pcall(function()
        mainList = mainMenu.MainMenu_List
        firstItem, firstWrapper = menuItemAndPanel(mainList, 0)
        parent = firstWrapper.Slot.Parent
    end)
    if not isValid(mainList) or not isValid(firstItem) or not isValid(parent) then
        log("cannot inject Mods entry: main-menu list hierarchy is unavailable")
        return
    end

    local nativeCount = resolveNativeMenuCount(mainMenu, mainList)
    local lastItem = menuItemAndPanel(mainList, nativeCount - 1)
    if not isValid(lastItem) then
        log("cannot inject Mods entry: final active native item is unavailable")
        return
    end

    local foreignRows = countForeignInjectedRows(parent, mainList, nativeCount)
    local modsIndex = nativeCount + foreignRows

    local iconClass = StaticFindObject(MAIN_MENU_ICON_CLASS)
    if not isValid(iconClass) then
        log("cannot inject Mods entry: native icon class is not loaded")
        return
    end

    local icon = nil
    local wrapperDonor = nil
    local wrapperPanel = nil
    local configured, configureError = pcall(function()
        icon = umgLibrary:Create(controller, iconClass, controller)
        if not isValid(icon) then error("Mods icon creation returned null") end

        wrapperDonor, wrapperPanel =
            attachIconWithNativeWrapper(umgLibrary, controller, parent, icon)

        icon:SetItemIndex(modsIndex)
        icon:SetOwnerInputWidget(mainList)
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        icon:SetDefaultAnimation()

        icon:SetMenuName(textLibrary:Conv_StringToText("Mods"))
        icon.MenuName:SetText(textLibrary:Conv_StringToText("Mods"))
    end)
    if not configured then
        log("Mods entry configuration failed: " .. tostring(configureError))
        return
    end

    activeContext = {
        mainMenu = mainMenu,
        mainMenuKey = menuKey,
        mainList = mainList,
        listKey = objectName(mainList),
        firstItem = firstItem,
        lastItem = lastItem,
        nativeCount = nativeCount,
        foreignRows = foreignRows,
        modsIndex = modsIndex,
        icon = icon,
        iconKey = objectName(icon),
        wrapperDonor = wrapperDonor,
        wrapperPanel = wrapperPanel,
        wrapperParent = parent,
    }
    menuCloseBusy = false
    if not applyIconLetter(activeContext) then
        pcall(function() wrapperPanel:RemoveFromParent() end)
        injectedMenus[menuKey] = false
        activeContext = nil
        log("Mods entry injection aborted: centred icon construction failed")
        return
    end

    -- Store only primitive state here. Keeping every historical widget in this
    -- table pins menu/world objects across checkpoint teardown.
    injectedMenus = { [menuKey] = true }
    listFocusIndexes = {}
    pendingFocusRedirects = {}
    -- Seed the focus tracker with wherever the list already is. Without this the
    -- first wrap after opening the menu has no previous index to compare against
    -- and cannot be recognised, so the first attempt to reach Mods silently
    -- falls through to the native wrap.
    local startingIndex = nil
    pcall(function() startingIndex = tonumber(mainList.CurrentIndex) end)
    listFocusIndexes[objectName(mainList)] = startingIndex
    log(string.format("added Mods entry at index %d (%d native rows, %d row(s) from other mods, list at %s)",
        modsIndex, nativeCount, foreignRows, tostring(startingIndex)))

    -- Only now is there anything for the input hooks to act on.
    if ensureInputHooks ~= nil then pcall(ensureInputHooks) end
    -- Another mod may have injected between the count above and the attach.
    pcall(refreshRailPosition, activeContext)

end

--========================================================--
--                        FOCUS                           --
--========================================================--

local function resetNativeSelection(context)
    if context == nil or not isValid(context.mainList) then return end

    local function resetItem(item)
        if not isValid(item) then return end
        pcall(function()
            item:StopAllAnimations()
            item:SetDefaultAnimation()
        end)
    end

    for index = 0, context.nativeCount - 1 do
        local item = nil
        pcall(function() item = context.mainList["Item_" .. tostring(index)] end)
        resetItem(item)
    end

    -- The authored blueprint also caches those icons in MenuIconArray. Reset
    -- that owner list so its current animation cannot repaint a native row
    -- after the live list item was cleared.
    pcall(function()
        context.mainMenu.MenuIconArray:ForEach(function(_, element)
            resetItem(unwrap(element))
        end)
    end)

    for index = 0, context.nativeCount - 1 do
        pcall(function()
            local item = context.mainList["Item_" .. tostring(index)]
            if isValid(item) then item:SetDefaultAnimation() end
        end)
    end
end

local function focusIcon(context, icon, index)
    if context == nil or not isValid(icon) then return end
    -- Keep the focus tracker aligned with injected rows as well as authored rows.
    -- The native list never receives a custom index, but the previous focus still
    -- needs to know that the live rail is currently on Mods when the next native
    -- FocusEvent arrives.
    if type(index) == "number" and context.listKey ~= nil then
        listFocusIndexes[context.listKey] = index
    end
    -- CurrentIndex is the cursor into the currently active authored rows, not
    -- every compiled Item_0..Item_6 slot. Equipment starts at nativeCount and
    -- Mods follows it, so neither custom index may enter the native cursor.
    if type(index) == "number" and index >= 0 and index < context.nativeCount then
        pcall(function() context.mainList.CurrentIndex = index end)
    end
    pcall(function() icon:SetInactive(false) end)
    pcall(function() icon:SetBlank(false) end)
    pcall(function() icon:SetInputEnable(true) end)
    pcall(function() icon:BP_SetInputInteractionEnable(true) end)
    pcall(function() icon["Set Current Animation"](icon) end)
    pcall(function() icon:BP_SetInputWidgetFocus() end)
    pcall(function() icon:SetFocus() end)
    pcall(function() icon:SetKeyboardFocus() end)
    local controller = resolveLocalController()
    if isValid(controller) then
        pcall(function() icon:SetUserFocus(controller) end)
    end
end

local function focusMods(context)
    if context == nil or not isValid(context.icon) then return end
    -- The Mods row is outside the native animation array, so selecting it cannot
    -- make the list deselect its own current row.
    resetNativeSelection(context)
    focusIcon(context, context.icon, context.modsIndex)
    enforceIconLetter(context)
end

local function clearModsSelection(context)
    if context == nil or not isValid(context.icon) then return end
    pcall(function() context.icon:SetDefaultAnimation() end)
    enforceIconLetter(context)
end

-- Upwards out of the Mods row lands on the row directly above it, which is
-- another mod's injected entry when one is present and the last native row
-- otherwise.
local function focusRowAbove(context)
    if context == nil then return end
    pcall(refreshRailPosition, context)
    clearModsSelection(context)

    -- A custom rail row sits outside the authored animation array. Reset every
    -- native row before handing focus to it so the result is independent of the
    -- direction from which Mods was entered.
    for index = 0, context.nativeCount - 1 do
        pcall(function()
            local item = context.mainList["Item_" .. tostring(index)]
            item:StopAllAnimations()
            item:SetDefaultAnimation()
        end)
    end

    if context.foreignRows > 0 then
        local parent = context.wrapperParent
        local count = nil
        pcall(function() count = parent:GetChildrenCount() end)
        local previousIcon = nil
        for index = 0, (tonumber(count) or 0) - 1 do
            local child = nil
            pcall(function() child = parent:GetChildAt(index) end)
            if isValid(child) then
                if objectName(child) == objectName(context.wrapperPanel) then break end
                local candidate = iconInsideWrapper(child)
                if candidate ~= nil then previousIcon = candidate end
            end
        end
        if isValid(previousIcon) then
            focusIcon(context, previousIcon, context.modsIndex - 1)
            return
        end
    end
    focusIcon(context, context.lastItem, context.nativeCount - 1)
end

local function focusFirstNative(context)
    clearModsSelection(context)
    focusIcon(context, context.firstItem, 0)
end

-- The panel is modal. Disable the native list, all authored entries and every
-- foreign injected row. Only the Mods row stays live as the controller input
-- sink; its button is consumed before the outer list can act on it.
local function setNativeMenuInputEnabled(context, enabled)
    if context == nil or not isValid(context.mainMenu) then return end

    local targets = {}
    local targetKeys = {}
    local function addTarget(target)
        if not isValid(target) then return end
        local key = objectName(target)
        if targetKeys[key] then return end
        targetKeys[key] = true
        targets[#targets + 1] = target
    end

    addTarget(context.mainList)
    for index = 0, context.nativeCount - 1 do
        local item = nil
        pcall(function() item = context.mainList["Item_" .. tostring(index)] end)
        addTarget(item)
    end

    local childCount = nil
    pcall(function() childCount = context.wrapperParent:GetChildrenCount() end)
    for index = 0, (tonumber(childCount) or 0) - 1 do
        local wrapper = nil
        pcall(function() wrapper = context.wrapperParent:GetChildAt(index) end)
        local railIcon = iconInsideWrapper(wrapper)
        if isValid(railIcon) and objectName(railIcon) ~= context.iconKey then
            addTarget(railIcon)
        end
    end

    local applied = 0
    for _, target in ipairs(targets) do
        if isValid(target) and isValid(context.mainMenu) then
            local ok = false
            if type(target.SetInputEnable) == "function" then
                if pcall(function() target:SetInputEnable(enabled) end) then ok = true end
            end
            if type(target.BP_SetInputInteractionEnable) == "function" then
                if pcall(function() target:BP_SetInputInteractionEnable(enabled) end) then ok = true end
            end
            if ok then applied = applied + 1 end
        end
    end

    if isValid(context.icon) and isValid(context.mainMenu) then
        if type(context.icon.SetInputEnable) == "function" then
            pcall(function() context.icon:SetInputEnable(true) end)
        end
        if type(context.icon.BP_SetInputInteractionEnable) == "function" then
            pcall(function() context.icon:BP_SetInputInteractionEnable(true) end)
        end
    end

    dbg(string.format("outer menu input %s on %d/%d widget(s); Mods row kept live",
        enabled and "enabled" or "disabled", applied, #targets))
end

local function isModsIcon(widget)
    if activeContext == nil or not isValid(widget) then return false end
    return objectName(widget) == activeContext.iconKey
end

--========================================================--
--                        PANEL                           --
--========================================================--

-- Building the panel constructs UObjects and edits the widget tree, so it has to
-- happen on the game thread. The callers reach here from ExecuteWithDelay, which
-- runs on the async thread — doing engine work from there is the other classic
-- way to earn an access violation.
local function onGameThread(action)
    -- Almost every caller here arrives from a RegisterHook callback, which is
    -- already the game thread. Going through ExecuteInGameThread from there was
    -- worse than pointless: when UE4SS has torn down its shared game-thread hook
    -- the work is queued and never runs, and the pcall still reports success
    -- because queuing itself did not fail. Run directly whenever possible.
    local inGameThread = false
    pcall(function() inGameThread = IsInGameThread() == true end)
    if inGameThread then
        action()
        return
    end

    local scheduled, dispatchError =
        pcall(function() ExecuteInGameThread(action) end)
    if not scheduled then
        log("game-thread dispatch failed: " .. tostring(dispatchError))
    end
end

local function buildPanelNow()
    if panel.isOpen() then return end

    local context = activeContext
    if context == nil or not isValid(context.mainMenu) then
        log("cannot open the panel: the start menu is not on screen")
        return
    end

    -- The panel draws into the menu that is already up. It must never build its
    -- own copy of the main-menu widget: that class is watched for construction
    -- by this mod and by FieldEquipmentMenu, and both would try to inject a rail
    -- row into the uninitialised copy, which crashes the game.
    panel.attachTo(context.mainMenu, context.icon)

    -- Capture the outer rail before constructing the modal panel. The same
    -- physical Accept press continues through native callbacks after this hook;
    -- capturing first prevents it from advancing the menu underneath.
    setNativeMenuInputEnabled(context, false)
    -- A mouse click can open Mods without passing through focusMods. Clear the
    -- last authored selection before the panel is shown, otherwise the native
    -- CurrentIndex animation remains lit beside the custom Mods row.
    resetNativeSelection(context)

    if not panel.open() then
        setNativeMenuInputEnabled(context, true)
        log("panel could not be opened; outer menu input was restored")
        return
    end

    -- Opening the panel can make the authored menu run one last focus pass.
    -- Clear the native cursor after that pass as well as before construction;
    -- otherwise the old CurrentIndex animation can reappear beside Mods.
    resetNativeSelection(context)
    ExecuteWithDelay(100, function()
        onGameThread(function()
            if panel.isOpen() and activeContext == context then
                resetNativeSelection(context)
            end
        end)
    end)

    warnedFocusWhilePanelOpen = false
    dbg("panel opened")
end

local function openPanel()
    onGameThread(function()
        local ok, err = pcall(buildPanelNow)
        if not ok then
            log("panel failed to open: " .. tostring(err))
            pcall(panel.close)
            if activeContext ~= nil then
                pcall(setNativeMenuInputEnabled, activeContext, true)
            end
        end
    end)
end

local function closePanel()
    if not panel.isOpen() then return end
    onGameThread(function()
        pcall(panel.close)
        if activeContext ~= nil then
            setNativeMenuInputEnabled(activeContext, true)
            pcall(focusMods, activeContext)
        end
        dbg("panel closed")
    end)
end

local function closeMainMenuFromMods()
    if menuCloseBusy then return end
    menuCloseBusy = true

    onGameThread(function()
        local controller = resolveLocalController()
        local rodLibrary = resolveRodLibrary()
        if not isValid(controller) or not isValid(rodLibrary) then
            log("cannot close start menu from Mods: UI context is unavailable")
            menuCloseBusy = false
            return
        end

        local ended, endError = pcall(function()
            rodLibrary:EndMenu(controller)
        end)
        if not ended then
            log("could not close start menu from Mods: " .. tostring(endError))
            menuCloseBusy = false
        end
    end)
end

-- One physical press reaches this mod several times over: the button hooks are
-- registered against three different UFunctions that all fire for the same
-- input, and a keyboard arrow additionally arrives through UE4SS's own keybind.
-- Without a lock a single press would step two or three rows at once.
local inputLocked = false

local function withInputLock(action)
    if inputLocked then return false end
    inputLocked = true
    ExecuteWithDelay(60, function() inputLocked = false end)
    action()
    return true
end

-- Returns true when the input was consumed by the panel.
local function routeToPanel(button)
    if not panel.isOpen() then return false end

    if logButtons or CONFIG.DEBUG_LOGS then
        log("panel received button code " .. tostring(button))
    end

    local action = nil
    if button == DPAD_UP or button == LSTICK_UP then
        action = function() panel.move(-1) end
    elseif button == DPAD_DOWN or button == LSTICK_DOWN then
        action = function() panel.move(1) end
    elseif button == DPAD_LEFT then
        action = function() panel.adjust(-1) end
    elseif button == DPAD_RIGHT then
        action = function() panel.adjust(1) end
    elseif button == ACCEPT_BUTTON then
        action = function() panel.activate() end
    elseif button == BACK_BUTTON then
        action = function() closePanel() end
    end

    -- Taking the shared input lock for a button that maps to nothing would
    -- block the keybind carrying the same press from acting on it.
    if action ~= nil then withInputLock(action) end

    -- Every button is swallowed while the panel is up, whether or not the lock
    -- let it through, otherwise the start menu underneath keeps reacting to
    -- input aimed at the panel.
    return true
end

--========================================================--
--                       HOOKS                            --
--========================================================--

local function consumeButton(buttonParameter)
    pcall(function() buttonParameter:set(0) end)
end

local function handleButton(widgetParameter, buttonParameter)
    local widget = unwrap(widgetParameter)
    local button = unwrap(buttonParameter)

    if panel.isOpen() then
        consumeButton(buttonParameter)
        routeToPanel(button)
        return
    end

    if not isValid(widget) then return end

    if isModsIcon(widget) then
        if button == ACCEPT_BUTTON then
            consumeButton(buttonParameter)
            openPanel()
        elseif button == BACK_BUTTON then
            consumeButton(buttonParameter)
            -- Match Equipment's proven close path: leave the native input hook
            -- before EndMenu tears down the widget that originated this event.
            ExecuteWithDelay(0, closeMainMenuFromMods)
        elseif button == DPAD_UP or button == LSTICK_UP then
            consumeButton(buttonParameter)
            -- Mods owns both of its boundaries. Depending on another mod's hook
            -- order here made Up work or fail nondeterministically.
            withInputLock(function() focusRowAbove(activeContext) end)
        elseif button == DPAD_DOWN or button == LSTICK_DOWN then
            consumeButton(buttonParameter)
            withInputLock(function() focusFirstNative(activeContext) end)
        end
        return
    end

    -- Downwards off the last row on the rail wraps into Mods. When another mod
    -- owns the row directly above the native ones, that mod claims this boundary
    -- and hands focus down over itself, so only the case where Mods is the first
    -- injected row is claimed here.
    local context = activeContext
    if context == nil then return end
    if not contains(objectName(widget), "WBP_Console_MainMenu_List_C") then return end
    if hasInjectedRowAbove(context) then return end

    local index = nil
    pcall(function() index = widget:GetItemIndex() end)
    if index == nil then return end

    local down = button == DPAD_DOWN or button == LSTICK_DOWN
    local up = button == DPAD_UP or button == LSTICK_UP
    if (down and index == context.modsIndex - 1) or (up and index == 0) then
        consumeButton(buttonParameter)
        withInputLock(function() focusMods(context) end)
    end
end

local function safeHook(path, callback, postCallback)
    local ok, err = pcall(function()
        if postCallback ~= nil then
            RegisterHook(path, callback, postCallback)
        else
            RegisterHook(path, callback)
        end
    end)
    if not ok then log("hook unavailable: " .. path .. " / " .. tostring(err)) end
end

local function isCanonicalMainMenuCandidate(mainMenu)
    if not isValid(mainMenu)
        or not contains(objectName(mainMenu), "WBP_Console_MainMenu_C") then
        return false
    end

    local inViewport = false
    local parentComponent = nil
    local parentActor = nil
    pcall(function() inViewport = mainMenu:IsInViewport() end)
    pcall(function()
        parentComponent = dereferenceWeakObject(mainMenu.ParentComponent)
        parentActor = dereferenceWeakObject(mainMenu.ParentActor)
    end)

    -- The interactive start menu is canonically owned by the game's world-space
    -- widget component/actor. Field Equipment's display-only copy and detached
    -- objects from a discarded world have neither owner and are rejected.
    return isValid(parentComponent) or isValid(parentActor)
end

local function resolveMainMenuByKey(menuKey)
    local ok, widgets = pcall(function()
        return FindAllOf("WBP_Console_MainMenu_C")
    end)
    if not ok or type(widgets) ~= "table" then
        return nil, "FindAllOf(WBP_Console_MainMenu_C) returned no table"
    end

    for _, widget in ipairs(widgets) do
        if isCanonicalMainMenuCandidate(widget)
            and objectName(widget) == menuKey then
            return widget, nil
        end
    end
    return nil, "exact constructed start-menu object is no longer live"
end

local function queueMenuInjection(menuKey)
    if type(menuKey) ~= "string" or menuKey == ""
        or injectedMenus[menuKey] ~= nil then
        return
    end

    local readyAt = os.clock() + MENU_INJECTION_DELAY_SEC
    local pending = pendingMenuInjections[menuKey]
    if pending == nil or readyAt < pending then
        pendingMenuInjections[menuKey] = readyAt
    end
    scheduleMenuInjection()
end

local function activeMenuContextIsAttached()
    local context = activeContext
    if context == nil
        or not isValid(context.mainMenu)
        or not isValid(context.icon)
        or not isValid(context.wrapperPanel)
        or not isValid(context.wrapperParent) then
        return false
    end

    local attachedParent = nil
    pcall(function() attachedParent = context.wrapperPanel.Slot.Parent end)
    return isValid(attachedParent)
        and objectName(attachedParent) == objectName(context.wrapperParent)
end

local function processMenuInjectionCycle()
    local now = os.clock()

    if activeContext ~= nil and not activeMenuContextIsAttached() then
        local staleKey = activeContext.mainMenuKey
        activeContext = nil
        if staleKey ~= nil then injectedMenus[staleKey] = nil end
        panel.close()
    end

    for menuKey, readyAt in pairs(pendingMenuInjections) do
        if now >= readyAt then
            pendingMenuInjections[menuKey] = nil
            local mainMenu, resolveError = resolveMainMenuByKey(menuKey)
            if mainMenu == nil then
                log("start-menu injection failed closed for " .. menuKey
                    .. ": " .. tostring(resolveError))
            else
                injectModsEntry(mainMenu)
            end
        end
    end
end

scheduleMenuInjection = function()
    if menuInjectionTimerScheduled
        or next(pendingMenuInjections) == nil then
        return
    end

    local now = os.clock()
    local earliest = nil
    for _, readyAt in pairs(pendingMenuInjections) do
        if earliest == nil or readyAt < earliest then earliest = readyAt end
    end
    local delayMs = math.max(
        1,
        math.ceil(math.max(0.0, earliest - now) * 1000)
    )
    menuInjectionTimerScheduled = true
    ExecuteWithDelay(delayMs, function()
        menuInjectionTimerScheduled = false
        ExecuteInGameThread(function()
            local handler = debug and debug.traceback or tostring
            local ok, cycleError =
                xpcall(processMenuInjectionCycle, handler)
            if not ok then
                pendingMenuInjections = {}
                log("menu acquisition cycle failed closed: "
                    .. tostring(cycleError))
                return
            end
            scheduleMenuInjection()
        end)
    end)
end

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject(
        "/Script/ROD.RODConsoleMainMenuWidgetBase",
        function(object)
            local mainMenu = unwrap(object)
            if not contains(
                objectName(mainMenu),
                "WBP_Console_MainMenu_C"
            ) then
                return
            end
            local menuKey = objectName(mainMenu)
            if activeContext ~= nil
                and activeContext.mainMenuKey ~= menuKey then
                -- A new widget tree is authoritative. Drop every reference to
                -- the previous tree synchronously, before its first FocusEvent
                -- can reach the hooks installed by an earlier menu.
                activeContext = nil
                listFocusIndexes = {}
                pendingFocusRedirects = {}
            end
            -- Do not capture the UObject in delayed work. Only its primitive
            -- identity crosses the readiness delay.
            queueMenuInjection(menuKey)
        end
    )
end)
if not notifyOk then
    error("[" .. MOD_NAME .. "] canonical main-menu notification failed: "
        .. tostring(notifyError))
end

-- Construction notification is the only acquisition trigger. A hot reload
-- against an already-existing widget is intentionally fail-closed; reopen the
-- menu or relaunch the game instead of scanning the global object array.

-- Every hook below only has anything to do once a Mods row exists on the rail.
-- Registering them at load time meant this mod had callbacks running on common
-- engine events throughout startup and gameplay for no benefit, which is a large
-- surface to be wrong on. They are installed once, on first injection.
local inputHooksInstalled = false

ensureInputHooks = function()
    if inputHooksInstalled then return end
    inputHooksInstalled = true

    safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OnButtonDownMenuItemDelegate",
        function(_, widgetParameter, buttonParameter)
            handleButton(widgetParameter, buttonParameter)
        end)

    safeHook("/Script/ROD.RODInputWidgetBase:OnInputButtonDown",
        function(_, widgetParameter, buttonParameter)
            handleButton(widgetParameter, buttonParameter)
        end)

    safeHook("/Script/ROD.RODListWidgetBase:ButtonDownEvent",
        function(_, widgetParameter, buttonParameter)
            handleButton(widgetParameter, buttonParameter)
        end)

    -- Pressing down on the last row never reaches the button hooks above: the
    -- native list changes focus on its own and only announces the result here.
    -- So the wrap is caught after the fact — the list is allowed to move to the
    -- first row, and the post-hook immediately moves focus to Mods instead,
    -- within the same frame so the wrong row is never drawn.
    --
    -- This also clears the Mods highlight when any other row takes focus: the
    -- row sits outside the native animation array, so nothing else deselects it.
    safeHook("/Script/ROD.RODListWidgetBase:FocusEvent",
        function(self, widgetParameter)
            local context = activeContext
            local listKey = objectName(unwrap(self))
            if listKey == nil then return end

            -- activeContext belongs to the exact list that received the Mods
            -- row. A newly constructed Start Menu can emit FocusEvent before
            -- the delayed acquisition cycle replaces the previous context.
            -- Touching that previous widget tree is a native use-after-free;
            -- reject the foreign list before dereferencing any stored UObject.
            if context == nil or listKey ~= context.listKey then
                pendingFocusRedirects[listKey] = nil
                return
            end

            -- Cheap: a walk over a handful of children. Catches a mod that
            -- injected its row after this one did.
            if not panel.isOpen() then
                pcall(refreshRailPosition, context)
            end

            -- While the panel is up, watch and report — never correct.
            --
            -- This used to pull focus back to the Mods row, which fed itself:
            -- re-focusing moved the focus, that raised this event again on the
            -- next frame, and the pair looped for as long as the panel stayed
            -- open, logging every frame. A re-entrancy flag did not help,
            -- because the repeat arrives a frame later with the flag already
            -- cleared. Disabling the native widgets' input is the actual fix; if
            -- focus still moves, that fix did not take and saying so once is
            -- worth more than fighting it.
            if panel.isOpen() then
                pendingFocusRedirects[listKey] = nil
                if not warnedFocusWhilePanelOpen then
                    warnedFocusWhilePanelOpen = true
                    log("native focus is still moving with the panel open; " ..
                        "the input disable did not take on this build")
                end
                return
            end
            if not contains(listKey, "WBP_Console_MainMenu_List_C") then return end

            local widget = unwrap(widgetParameter)
            if not isValid(widget) then return end
            if not isModsIcon(widget) then clearModsSelection(context) end

            local index = nil
            pcall(function() index = widget:GetItemIndex() end)
            if index == nil then return end

            local previousIndex = listFocusIndexes[listKey]
            listFocusIndexes[listKey] = index

            -- When another mod owns the row directly above the native ones it
            -- drives this boundary itself, and stealing focus here would fight
            -- it. Asked of the live rail, not of the injection-time count.
            if hasInjectedRowAbove(context) then return end

            local lastNativeIndex = context.modsIndex - 1
            local wrappedDown = previousIndex == lastNativeIndex and index == 0
            local wrappedUp = previousIndex == 0 and index == lastNativeIndex
            if wrappedDown or wrappedUp then
                pendingFocusRedirects[listKey] = true
            end
            dbg(string.format("focus %s -> %s (last native %d)%s",
                tostring(previousIndex), tostring(index), lastNativeIndex,
                (wrappedDown or wrappedUp) and " => redirect to Mods" or ""))
        end,
        function(self)
            local listKey = objectName(unwrap(self))
            if pendingFocusRedirects[listKey] ~= true then return end
            pendingFocusRedirects[listKey] = nil
            if activeContext ~= nil and not panel.isOpen() then
                focusMods(activeContext)
            end
        end)

    safeHook("/Script/ROD.RODListWidgetBase:ClickEvent",
        function(_, widgetParameter, buttonParameter, _)
            if isModsIcon(unwrap(widgetParameter)) then
                consumeButton(buttonParameter)
                openPanel()
            end
        end)

    safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OnClickMenuItemDelegate",
        function(_, widgetParameter, buttonParameter)
            if isModsIcon(unwrap(widgetParameter)) then
                consumeButton(buttonParameter)
                openPanel()
            end
        end)

    -- The start menu closing must take the panel with it, or it would be left
    -- floating over the world. The context reference is deliberately kept until
    -- a new real menu replaces it, rather than cleared here: a close is not
    -- proof the menu is gone for good, and processMenuInjectionCycle already
    -- drops the context the moment the row stops being attached to it.
    safeHook("/Script/ROD.RODWidgetBPFunctionLibrary:EndMenu", function()
        if panel.isOpen() then closePanel() end
        -- If this EndMenu came from the Mods row, retain the close lock until
        -- the next real menu injection. One physical Back press reaches several
        -- hooked functions and must never call EndMenu more than once.
    end)

    log("input hooks installed")
end

--========================================================--
--                      KEYBOARD                          --
--========================================================--

-- Controller input reaches the panel through the button hooks above. Keyboard
-- arrows do not always travel that path, so they are bound directly and gated on
-- the panel being open.
local function bindPanelKey(key, action)
    local ok, err = pcall(function()
        RegisterKeyBind(key, function()
            if not panel.isOpen() then return end
            -- Shares the lock with the button hooks: the same keypress often
            -- arrives through both paths.
            ExecuteInGameThread(function() withInputLock(action) end)
        end)
    end)
    if not ok then log("keybind unavailable: " .. tostring(err)) end
end

-- Reading Key.X directly would throw outside a pcall if the enum is missing on
-- some UE4SS build, taking the whole mod down with it before the console command
-- is ever registered.
local function keyCode(name)
    local ok, code = pcall(function() return Key[name] end)
    if ok and type(code) == "number" then return code end
    log("key enum unavailable: " .. name)
    return nil
end

for _, binding in ipairs({
    { "UP_ARROW", function() panel.move(-1) end },
    { "DOWN_ARROW", function() panel.move(1) end },
    { "LEFT_ARROW", function() panel.adjust(-1) end },
    { "RIGHT_ARROW", function() panel.adjust(1) end },
    { "RETURN", function() panel.activate() end },
    { "ESCAPE", function() closePanel() end },
}) do
    local code = keyCode(binding[1])
    if code ~= nil then bindPanelKey(code, binding[2]) end
end

--========================================================--
--                   CONSOLE COMMAND                      --
--========================================================--
-- Read-only diagnostics only. State changes have one canonical path: the panel.

local function runCommand(params, reply)
    local sub = params[1] and string.lower(tostring(params[1])) or "list"

    if sub == "list" or sub == "show" then
        for _, entry in ipairs(registry) do
            local marker = entry.apply == "restart" and "  (restart)"
                or (entry.apply == "menu" and "  (reopen menu)" or "")
            -- Same truth the panel shows: whether UE4SS will load the mod.
            local read, loaded = pcall(store.isModEnabled, entry.mod)
            local enabled = read and (loaded and "ON" or "OFF") or "--"
            reply(string.format("%-18s %-3s%s", entry.mod, enabled, marker))

            -- A mod with no settings contract is one line and no more.
            if entry.configured then
                local ok, failure = pcall(function()
                    local effective = store.readEffective(entry.mod)
                    for _, setting in ipairs(entry.settings or {}) do
                        if setting.key ~= "ENABLED" then
                            local value = store.valueOf(effective, setting)
                            reply(string.format("    %-22s %s",
                                setting.key, tostring(value)))
                        end
                    end
                end)
                if not ok then
                    reply("    settings unavailable: " .. tostring(failure))
                end
            end
        end
        reply("Diagnostics: modmenu probe | buttons")
        return
    end

    if sub == "buttons" then
        logButtons = not logButtons
        reply("panel button code logging " .. (logButtons and "ON" or "OFF"))
        return
    end

    if sub == "probe" then
        ExecuteInGameThread(function() panel.probe(function(line) log(line) end) end)
        reply("probe written to the UE4SS log")
        return
    end

    reply("Unknown diagnostic. Use: modmenu list | probe | buttons")
end

local commandOk, commandError = pcall(function()
    RegisterConsoleCommandHandler("modmenu", function(_full, params, ar)
        local function reply(message)
            local delivered = pcall(function() ar:Log(message) end)
            if not delivered then print("[" .. MOD_NAME .. "] " .. tostring(message) .. "\n") end
        end
        local ok, err = pcall(runCommand, params or {}, reply)
        if not ok then reply("command error: " .. tostring(err)) end
        return true
    end)
end)

if not commandOk then
    log("console command unavailable: " .. tostring(commandError))
end

log(string.format("loaded %s | %d mods registered | console: modmenu list",
    MOD_VERSION, #registry))
