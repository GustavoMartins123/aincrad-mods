-- ModMenu v1.5.15
-- Adds a native-styled "Mods" entry to Echoes of Aincrad's start menu, opening a
-- panel that enables/disables the other mods and retunes their values in-game.
--
-- The native list's TArrays cannot be grown safely from UE4SS Lua, so the row is a
-- MenuIcon clone parked in a donor wrapper appended to the same VerticalBox, and
-- only the navigation boundaries around it are bridged.
--
-- Changes are persisted to the target mod's Scripts/runtime.lua and picked up by
-- ModMenuBridge, which that mod loads itself. ModMenu never reaches into another
-- mod's Lua state, because UE4SS gives each mod its own.

local MOD_NAME = "ModMenu"
local MOD_VERSION = "v1.5.15"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu.WBP_Console_MainMenu_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"

local MAX_NATIVE_MENU_ITEMS = 7
local MENU_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C"

-- EInputButtonKindInWidget, taken from the game's own reflection dump
-- (mod_template Data/headers/ROD_enums.hpp) rather than inferred from observed
-- presses. Watching the log tells you a code arrived; it does not tell you
-- which member it is, and 15/16 were written here the wrong way round on that
-- basis -- 15 is Right and 16 is Left, so Left raised a value and Right
-- lowered it.
local ACCEPT_BUTTON = 1
local BACK_BUTTON = 2
local DPAD_UP = 13
local DPAD_DOWN = 14
local DPAD_RIGHT = 15
local DPAD_LEFT = 16
local LSTICK_UP = 17
local LSTICK_DOWN = 18
local LSTICK_RIGHT = 19
local LSTICK_LEFT = 20
local RSTICK_UP = 21
local RSTICK_DOWN = 22
local RSTICK_RIGHT = 23
local RSTICK_LEFT = 24

-- One direction reaches this mod on three different devices, and the enum
-- gives each device its own code. Every navigation decision below is taken
-- from this map instead of from a hand-written pair of codes, so a direction
-- cannot be handled on the D-pad and fall through to the native menu on a
-- stick. Registering only the codes that had been seen in a log is what left
-- both analog horizontals and the whole right stick unclaimed.
local DIRECTION = {}
for _, entry in ipairs({
    { DPAD_UP, "up" }, { LSTICK_UP, "up" }, { RSTICK_UP, "up" },
    { DPAD_DOWN, "down" }, { LSTICK_DOWN, "down" }, { RSTICK_DOWN, "down" },
    { DPAD_LEFT, "left" }, { LSTICK_LEFT, "left" }, { RSTICK_LEFT, "left" },
    { DPAD_RIGHT, "right" }, { LSTICK_RIGHT, "right" }, { RSTICK_RIGHT, "right" },
}) do
    DIRECTION[entry[1]] = entry[2]
end

local function directionOf(button)
    if type(button) ~= "number" then return nil end
    return DIRECTION[button]
end

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2
local HIT_TEST_INVISIBLE = 3

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
-- Exact physical row identity for keyboard boundary handling. CurrentIndex is
-- not authoritative once an injected row owns focus, because custom indexes are
-- deliberately never written into the native list.
local railFocusKeys = {}
local pendingFocusRedirects = {}
-- Focusing an injected UObject raises the native list's FocusEvent again. Those
-- nested events describe the focus operation this router just requested, not a
-- second player input, so they must never be interpreted as another list wrap.
local railFocusMutationDepth = {}
local lastRailError = nil
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

-- RegisterHook parameters are RemoteUnrealParam objects whose storage is valid
-- only during the callback. Input routing is not allowed to keep the wrapper or
-- silently use it as if it were the decoded UObject/value: doing that eventually
-- tries to call the RemoteUnrealParam itself and UE4SS removes the whole hook.
local function hookValue(parameter, label)
    if parameter == nil then
        error(tostring(label) .. " hook parameter is unavailable")
    end
    local ok, value = pcall(function() return parameter:get() end)
    if not ok then
        error(tostring(label) .. " hook parameter decode failed: " .. tostring(value))
    end
    return value
end

local function contains(value, fragment)
    return string.find(tostring(value or ""), fragment, 1, true) ~= nil
end

local function menuContextIsMounted(context)
    if context == nil or not isValid(context.mainMenu)
        or not isValid(context.wrapperPanel) or not isValid(context.wrapperParent) then
        return false
    end

    local menuVisible = false
    local rowVisible = false
    pcall(function() menuVisible = context.mainMenu:IsVisible() == true end)
    pcall(function() rowVisible = context.wrapperPanel:IsVisible() == true end)
    if not menuVisible or not rowVisible then return false end

    local attachedParent = nil
    pcall(function() attachedParent = context.wrapperPanel.Slot.Parent end)
    if not isValid(attachedParent)
        or objectName(attachedParent) ~= objectName(context.wrapperParent) then
        return false
    end

    local component = nil
    pcall(function()
        component = dereferenceWeakObject(context.mainMenu.ParentComponent)
    end)
    if not isValid(component) then return false end

    local mounted = nil
    pcall(function() mounted = component:GetWidget() end)
    return isValid(mounted)
        and objectName(mounted) == objectName(context.mainMenu)
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

-- A marker left set by a crash or a hard exit would tell a mod its settings
-- page is open when no menu exists at all, so clear them at startup. Driven by
-- what each mod's own manifest declares -- this menu names no mod and needs
-- none of them present.
do
    for _, entry in ipairs(registry) do
        if entry.preview == true then
            local cleared, clearError = store.clearPreview(entry.mod)
            if not cleared then
                log(entry.mod .. " preview cleanup failed: " .. tostring(clearError))
            end
        end
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

-- NumContent is the final zero-based authored index, and rows the game has
-- progression-hidden are trimmed off the tail.
local function resolveNativeMenuCount(mainMenu, mainList)
    local finalNativeIndex = nil
    pcall(function() finalNativeIndex = tonumber(mainMenu.NumContent) end)
    if finalNativeIndex == nil or finalNativeIndex % 1 ~= 0
        or finalNativeIndex < 0 or finalNativeIndex >= MAX_NATIVE_MENU_ITEMS then
        return nil, "canonical NumContent is invalid: " .. tostring(finalNativeIndex)
    end

    local count = finalNativeIndex + 1
    for index = 0, count - 1 do
        local item, wrapper = menuItemAndPanel(mainList, index)
        if not isValid(item) or not isValid(wrapper) then
            return nil, "authored menu row " .. tostring(index) .. " is unavailable"
        end
    end

    while count > 1 do
        local _, wrapper = menuItemAndPanel(mainList, count - 1)
        local _, previousWrapper = menuItemAndPanel(mainList, count - 2)
        local visibility = nil
        local previousVisibility = nil
        pcall(function() visibility = wrapper:GetVisibility() end)
        pcall(function() previousVisibility = previousWrapper:GetVisibility() end)
        if visibility == nil or previousVisibility == nil then
            return nil, "authored row visibility is unavailable"
        end
        if visibility ~= COLLAPSED and visibility ~= HIDDEN then break end
        if previousVisibility == COLLAPSED or previousVisibility == HIDDEN then break end
        count = count - 1
    end
    return count, nil
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
local function countForeignInjectedRows(parent, mainList)
    local authored = {}
    -- The full authored range, not just the active rows. Progression hides the
    -- final entry (Logout) without removing its wrapper, so stopping at
    -- nativeCount leaves that wrapper unaccounted for and it gets miscounted as
    -- another mod's row — which pushes the Mods entry one index too far and makes
    -- it unreachable, because the navigation boundary then looks for a row that
    -- is not the last visible one.
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local _, wrapper = menuItemAndPanel(mainList, index)
        if not isValid(wrapper) then
            return nil, "authored wrapper " .. tostring(index) .. " is unavailable"
        end
        authored[objectName(wrapper)] = true
    end

    local childCount = nil
    pcall(function() childCount = parent:GetChildrenCount() end)
    if type(childCount) ~= "number" then
        return nil, "rail child count is unavailable"
    end

    local foreign = 0
    for index = 0, childCount - 1 do
        local child = nil
        pcall(function() child = parent:GetChildAt(index) end)
        if not isValid(child) then
            return nil, "rail child " .. tostring(index) .. " is unavailable"
        end
        if not authored[objectName(child)] and iconInsideWrapper(child) ~= nil then
            local visibility = nil
            pcall(function() visibility = child:GetVisibility() end)
            if visibility == nil then
                return nil, "rail row visibility is unavailable"
            end
            if visibility ~= COLLAPSED and visibility ~= HIDDEN then
                foreign = foreign + 1
            end
        end
    end
    return foreign, nil
end

-- Builds the navigable rail from the live widget tree. Authored and injected
-- rows are identified by UObject identity; ItemIndex is presentation metadata
-- only and never decides which row exists or which row is adjacent. A hidden
-- authored row (normally Item_6/Logout) is excluded directly by its wrapper's
-- visibility, including when another mod has assigned indexes beyond it.
--
-- This walk happens only on input/focus/reconciliation events. The rail has at
-- most a handful of children, so coexistence has no per-frame cost.
local function collectRailRows(context)
    if context == nil or not isValid(context.mainList)
        or not isValid(context.wrapperParent) or not isValid(context.wrapperPanel) then
        return nil, "rail context is unavailable"
    end

    local authored = {}
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local item, wrapper = menuItemAndPanel(context.mainList, index)
        if not isValid(item) or not isValid(wrapper) then
            return nil, "authored row " .. tostring(index) .. " is unavailable"
        end
        authored[objectName(wrapper)] = {
            icon = item,
            nativeIndex = index,
        }
    end

    local childCount = nil
    pcall(function() childCount = context.wrapperParent:GetChildrenCount() end)
    if type(childCount) ~= "number" then
        return nil, "rail child count is unavailable"
    end

    local rows = {}
    local iconKeys = {}
    local ownSeen = false
    local ownWrapperKey = objectName(context.wrapperPanel)
    local injectedStarted = false
    for position = 0, childCount - 1 do
        local wrapper = nil
        pcall(function() wrapper = context.wrapperParent:GetChildAt(position) end)
        if not isValid(wrapper) then
            return nil, "rail child " .. tostring(position) .. " is unavailable"
        end

        local visibility = nil
        pcall(function() visibility = wrapper:GetVisibility() end)
        if visibility == nil then
            return nil, "rail row " .. tostring(position) .. " has no visibility"
        end

        local authoredRow = authored[objectName(wrapper)]
        local icon = authoredRow and authoredRow.icon or iconInsideWrapper(wrapper)
        if isValid(icon) and visibility ~= COLLAPSED and visibility ~= HIDDEN then
            local injected = authoredRow == nil
            if not injected and injectedStarted then
                return nil, "an authored row appears below an injected row"
            end
            if injected then injectedStarted = true end

            local iconKey = objectName(icon)
            if iconKeys[iconKey] then
                return nil, "duplicate rail icon identity: " .. tostring(iconKey)
            end
            iconKeys[iconKey] = true
            local row = {
                wrapper = wrapper,
                icon = icon,
                iconKey = iconKey,
                injected = injected,
                nativeIndex = authoredRow and authoredRow.nativeIndex or nil,
            }
            rows[#rows + 1] = row
            if objectName(wrapper) == ownWrapperKey then ownSeen = true end
        end
    end

    if not ownSeen then return nil, "Mods wrapper is not a visible rail row" end
    if #rows == 0 or rows[1].injected then
        return nil, "rail has no visible authored row"
    end
    return rows, nil
end

local function reportRailError(message)
    message = tostring(message)
    if lastRailError == message then return end
    lastRailError = message
    log("rail navigation unavailable: " .. message)
end

local function railRowForKey(rows, widgetKey)
    if type(rows) ~= "table" or type(widgetKey) ~= "string" then return nil, nil end
    for index, row in ipairs(rows) do
        if row.iconKey == widgetKey then return row, index end
    end
    return nil, nil
end

local function railBoundaries(rows)
    local firstNative, lastNative = nil, nil
    local firstInjected, lastInjected = nil, nil
    for _, row in ipairs(rows or {}) do
        if row.injected then
            firstInjected = firstInjected or row
            lastInjected = row
        else
            firstNative = firstNative or row
            lastNative = row
        end
    end
    return firstNative, lastNative, firstInjected, lastInjected
end

-- Returns an authored index only for the exact UObject stored in Item_0..Item_6.
-- If that object is absent from collectRailRows, its wrapper is hidden/collapsed
-- and it must be skipped instead of becoming an invisible navigation target.
local function authoredIndexForKey(context, widgetKey)
    if context == nil or type(widgetKey) ~= "string" then return nil end
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local item = menuItemAndPanel(context.mainList, index)
        if isValid(item) and objectName(item) == widgetKey then return index end
    end
    return nil
end

-- Native submenus temporarily collapse every authored wrapper except the row
-- being opened. In that state the rail is presentation-only: Settings can be
-- both the first and last visible native row, so adjacency and wrap detection
-- have no valid meaning. Item_6 is outside nativeCount and intentionally does
-- not affect this check.
local function nativeRailIsFullyPresented(context)
    if context == nil or not isValid(context.mainList)
        or type(context.nativeCount) ~= "number" then
        return nil, "native rail context is unavailable"
    end

    local visible = 0
    for index = 0, context.nativeCount - 1 do
        local item, wrapper = menuItemAndPanel(context.mainList, index)
        if not isValid(item) or not isValid(wrapper) then
            return nil, "native row " .. tostring(index) .. " is unavailable"
        end
        local visibility = nil
        local read, readError = pcall(function()
            visibility = wrapper:GetVisibility()
        end)
        if not read or type(visibility) ~= "number" then
            return nil, "native row " .. tostring(index) ..
                " visibility is unreadable: " .. tostring(readError)
        end
        if visibility ~= COLLAPSED and visibility ~= HIDDEN then
            visible = visible + 1
        end
    end
    return visible == context.nativeCount, nil
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
        -- The letter is decoration above the real URODInputWidgetBase. Visible
        -- widgets participate in Slate hit testing, so the Z-order 30 TextBlock
        -- was swallowing hover/LMB before either the icon or its owner list saw
        -- the pointer. Keep it rendered while letting input reach the icon.
        label:SetVisibility(HIT_TEST_INVISIBLE)
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
        context.letterWidget:SetVisibility(HIT_TEST_INVISIBLE)
        context.letterWidget:SetRenderOpacity(1.0)
    end)
    if not ok then log("could not enforce centred Mods icon: " .. tostring(err)) end
    return ok
end

-- Re-establishes the complete native input contract of the injected row.
-- Restoring SetInputEnable alone is insufficient after the modal SubMenu canvas
-- has been opened and collapsed again: the row may still have a stale owner or
-- the main menu may no longer be accepting pointer interaction, leaving
-- GetIsMouseHover permanently false even though controller focus still works.
local function rearmModsEntry(context)
    if context == nil or not isValid(context.mainMenu)
        or not isValid(context.mainList) or not isValid(context.icon)
        or not isValid(context.wrapperPanel) then
        return false, "Mods row input context is unavailable"
    end
    if not menuContextIsMounted(context) then
        return false, "Mods row is not mounted in the live start menu"
    end

    local rearmed, rearmError = xpcall(function()
        local icon = context.icon
        icon:SetItemIndex(context.modsIndex)
        icon:SetOwnerInputWidget(context.mainList)
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        icon:SetVisibility(VISIBLE)
        icon:SetRenderOpacity(1.0)
        context.wrapperPanel:SetVisibility(VISIBLE)
        context.wrapperPanel:SetRenderOpacity(1.0)
        context.mainMenu:SetInteraction(true)

        local inputEnabled = icon:IsInputEnable()
        local interactionEnabled = icon:IsInputInteractionEnable()
        if inputEnabled ~= true or interactionEnabled ~= true then
            error(string.format(
                "input verification failed (input=%s, interaction=%s)",
                tostring(inputEnabled), tostring(interactionEnabled)))
        end
        if not enforceIconLetter(context) then
            error("centred Mods icon could not be restored")
        end
    end, debug.traceback)
    if not rearmed then
        return false, "Mods row rearm failed: " .. tostring(rearmError)
    end
    return true, nil
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
    local fullyPresented, presentationError = nativeRailIsFullyPresented(context)
    if fullyPresented == nil then
        reportRailError(presentationError)
        return false
    end
    if not fullyPresented then return false end

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
        --
        -- The two halves are checked separately and the result is verified. As
        -- one pcall, a detach that succeeded followed by an append that failed
        -- reported "did not move" while having already taken the row out of the
        -- tree -- the Mods entry would simply be gone, with nothing saying so.
        -- Anything that makes the append fail happens exactly when the menu is
        -- being torn down, which is also when this runs on a delayed pass.
        local detached = pcall(function() wrapper:RemoveFromParent() end)
        if detached then
            pcall(function() parent:AddChildToVerticalBox(wrapper) end)

            local reattached = nil
            pcall(function() reattached = wrapper.Slot.Parent end)
            if isValid(reattached) then
                pcall(function() wrapper:SetVisibility(VISIBLE) end)
                pcall(function() wrapper:ForceLayoutPrepass() end)
                log("another mod appended a row below Mods; moved Mods back to the end")
            else
                -- Detached and could not be put back. Say so loudly: the row is
                -- off the rail until the menu is rebuilt, and silence here is
                -- what made that look like the mod removing itself.
                log("the Mods row was detached but could not be re-attached; " ..
                    "it will return when the start menu is reopened")
            end
        end
    end

    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return
    end
    lastRailError = nil

    local ownRowPosition = nil
    local injected = 0
    for position, row in ipairs(rows) do
        if row.injected then injected = injected + 1 end
        if row.iconKey == context.iconKey then ownRowPosition = position end
    end
    if ownRowPosition == nil then
        reportRailError("Mods icon is absent from the visible rail")
        return
    end

    local others = injected - 1
    local index = ownRowPosition - 1
    if index ~= context.modsIndex or others ~= context.foreignRows then
        context.modsIndex = index
        context.foreignRows = others
        pcall(function() context.icon:SetItemIndex(index) end)
        dbg(string.format("rail position refreshed: index %d (%d native, %d other injected)",
            index, context.nativeCount, others))
    end
    return true
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
    pcall(function()
        parentComponent = dereferenceWeakObject(mainMenu.ParentComponent)
    end)
    local mountedMenu = nil
    if isValid(parentComponent) then
        pcall(function() mountedMenu = parentComponent:GetWidget() end)
    end
    if not isValid(mountedMenu)
        or objectName(mountedMenu) ~= objectName(mainMenu) then
        injectedMenus[menuKey] = false
        log("ignored unmounted/display-only main-menu overlay: " .. menuKey)
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

    local nativeCount, nativeCountError = resolveNativeMenuCount(mainMenu, mainList)
    if nativeCount == nil then
        log("cannot inject Mods entry: " .. tostring(nativeCountError))
        return
    end
    local lastItem = menuItemAndPanel(mainList, nativeCount - 1)
    if not isValid(lastItem) then
        log("cannot inject Mods entry: final active native item is unavailable")
        return
    end

    local foreignRows, foreignRowsError = countForeignInjectedRows(parent, mainList)
    if foreignRows == nil then
        log("cannot inject Mods entry: " .. tostring(foreignRowsError))
        return
    end
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
    railFocusKeys = {}
    pendingFocusRedirects = {}
    railFocusMutationDepth = {}
    -- Seed the focus tracker with wherever the list already is. Without this the
    -- first wrap after opening the menu has no previous index to compare against
    -- and cannot be recognised, so the first attempt to reach Mods silently
    -- falls through to the native wrap.
    local startingIndex = nil
    pcall(function() startingIndex = tonumber(mainList.CurrentIndex) end)
    local listKey = objectName(mainList)
    listFocusIndexes[listKey] = startingIndex
    if type(startingIndex) == "number"
        and startingIndex >= 0 and startingIndex < nativeCount then
        local startingItem = nil
        pcall(function()
            startingItem = mainList["Item_" .. tostring(startingIndex)]
        end)
        if isValid(startingItem) then
            railFocusKeys[listKey] = objectName(startingItem)
        end
    end
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

    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
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

    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        pcall(function()
            local item = context.mainList["Item_" .. tostring(index)]
            if isValid(item) then item:SetDefaultAnimation() end
        end)
    end
end

local function focusIcon(context, icon, index)
    if context == nil or not isValid(icon) then return end
    -- CurrentIndex is the cursor into the currently active authored rows, not
    -- every compiled Item_0..Item_6 slot. Only a row proved to be authored may
    -- update it; injected ItemIndex values are never native cursor positions.
    if type(index) == "number" and index >= 0 and index < context.nativeCount then
        if context.listKey ~= nil then listFocusIndexes[context.listKey] = index end
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

local focusRailRow

local function focusMods(context)
    if context == nil or not isValid(context.icon) then return false end
    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return false
    end
    local row = railRowForKey(rows, context.iconKey)
    if row == nil then
        reportRailError("Mods icon is not a visible rail row")
        return false
    end
    return focusRailRow(context, row)
end

local function clearModsSelection(context)
    if context == nil or not isValid(context.icon) then return end
    pcall(function() context.icon:SetDefaultAnimation() end)
    enforceIconLetter(context)
end

focusRailRow = function(context, row)
    if context == nil or row == nil or not isValid(row.icon) then return false end

    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return false
    end
    lastRailError = nil

    local liveRow = railRowForKey(rows, row.iconKey)
    if liveRow == nil then
        reportRailError("focus target left the visible rail")
        return false
    end
    row = liveRow

    local listKey = context.listKey
    if row.injected then
        -- There is no native cursor index for this target. Clear the predecessor
        -- before any UObject focus call so even an asynchronously reported native
        -- side effect cannot be mistaken for a wrap from the previous boundary.
        listFocusIndexes[listKey] = nil
    end
    railFocusMutationDepth[listKey] = (railFocusMutationDepth[listKey] or 0) + 1
    local focused, focusError = xpcall(function()
        -- No authored animation knows about injected rows. Clear every non-target
        -- injected icon explicitly, and clear the native array before focusing a
        -- custom row so exactly one row is presented as selected.
        for _, candidate in ipairs(rows) do
            if candidate.injected and candidate.iconKey ~= row.iconKey then
                pcall(function() candidate.icon:SetDefaultAnimation() end)
            end
        end

        if row.injected then
            resetNativeSelection(context)
            focusIcon(context, row.icon, nil)
        else
            clearModsSelection(context)
            focusIcon(context, row.icon, row.nativeIndex)
        end
        if row.iconKey == context.iconKey then enforceIconLetter(context) end
    end, debug.traceback)
    local depth = (railFocusMutationDepth[listKey] or 1) - 1
    railFocusMutationDepth[listKey] = depth > 0 and depth or nil
    if not focused then
        reportRailError("focus mutation failed: " .. tostring(focusError))
        return false
    end
    railFocusKeys[listKey] = row.iconKey
    return true
end

local function moveFromRailKey(context, widgetKey, delta)
    if context == nil or type(widgetKey) ~= "string" then return false end
    pcall(refreshRailPosition, context)

    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return false
    end
    local _, current = railRowForKey(rows, widgetKey)
    if current == nil then
        reportRailError("input widget is not a visible rail row")
        return false
    end

    local target = current + delta
    if target < 1 then target = #rows end
    if target > #rows then target = 1 end
    return focusRailRow(context, rows[target])
end

local function isModsIcon(widget)
    if activeContext == nil or not isValid(widget) then return false end
    return objectName(widget) == activeContext.iconKey
end

local function isNavigationFocused(widget)
    if not isValid(widget) then return nil, "focus widget is unavailable" end
    local focused = nil
    local ok, focusError = pcall(function()
        focused = widget:HasAnyUserFocus()
    end)
    if not ok or type(focused) ~= "boolean" then
        return nil, "HasAnyUserFocus is unreadable: " .. tostring(focusError)
    end
    return focused, nil
end

-- World-space menu geometry is not screen geometry on this build: testing the
-- wrapper with IsUnderLocation made clicks on Settings resolve as Mods. The
-- interactive URODInputWidgetBase already owns the authoritative hover state.
local function isMouseHoveringMods(context)
    if context == nil or not isValid(context.icon) then
        return nil, "Mods row is unavailable"
    end
    local hovered = nil
    local hoverOk, hoverError = pcall(function()
        hovered = context.icon:GetIsMouseHover()
    end)
    if not hoverOk or type(hovered) ~= "boolean" then
        return nil, "GetIsMouseHover is unreadable: " .. tostring(hoverError)
    end
    return hovered, nil
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
    -- own copy of this watched widget class: construction observers would treat
    -- the detached copy as a real menu and mutate an uninitialised widget tree.
    panel.attachTo(context.mainMenu, context.icon)

    -- Mouse opening commonly arrives while the native CurrentIndex still owns a
    -- different authored row. Move actual user focus onto Mods before the panel
    -- installs its own modal input surface.
    local focused = focusMods(context)
    local ownsFocus, focusError = isNavigationFocused(context.icon)
    if not focused or ownsFocus ~= true then
        log("cannot open the panel: Mods did not acquire modal focus" ..
            (focusError and (": " .. tostring(focusError)) or ""))
        return
    end

    if not panel.open() then
        local rearmed, rearmError = rearmModsEntry(context)
        log("panel could not be opened; Mods row rearm " ..
            (rearmed and "succeeded" or ("failed: " .. tostring(rearmError))))
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
            local cleaned, cleanupError = pcall(panel.close)
            if not cleaned or panel.isOpen() then
                log("panel cleanup after open error failed: " ..
                    tostring(cleanupError))
                return
            end
            if activeContext ~= nil then
                local rearmed, rearmError = rearmModsEntry(activeContext)
                if not rearmed then
                    log("Mods row rearm after panel error failed: " ..
                        tostring(rearmError))
                end
            end
        end
    end)
end

-- Puts the Mods row back at the bottom of the rail once the panel is out of the
-- way, and keeps doing so for a moment.
--
-- Switching a mod on from the panel is now a live event on this rail: UE4SS
-- RestartMod brings the mod up mid-session and its own acquisition sweep finds
-- the start menu that is already open, so it appends its row while the panel is
-- still covering everything. Every rail mod appends with AddChildToVerticalBox,
-- so the newcomer lands below Mods and the two swap places -- and modsIndex,
-- computed at injection, is then pointing at somebody else's row.
--
-- Two reasons this waits for the panel to close instead of correcting live:
--
--   * refreshRailPosition detaches and re-appends the Mods wrapper, and while
--     the panel is up that wrapper's icon is the one widget still accepting
--     input. Pulling it out of the tree mid-session is how the panel would stop
--     responding -- a worse bug than a row in the wrong order.
--   * nothing on the rail is visible or reachable until the panel is gone, so
--     correcting earlier buys nothing.
--
-- The repeats exist because the newcomer's arrival is not synchronous with
-- anything here: RestartMod only queues, the loader reinstalls the mod on its
-- own event loop, and the mod then waits out its own readiness delay. A single
-- pass at close could run before the row it is meant to notice exists.
-- refreshRailPosition is a walk over
-- a handful of children and does nothing when the order is already right, so
-- repeating it is cheap and idempotent.
--
-- These only make the correction early enough that the player never sees the
-- wrong order. The permanent safety net is the FocusEvent hook, which reconciles
-- on every rail move once the panel is closed, so a newcomer arriving after the
-- last pass here is still put in its place the moment the player navigates.
local RAIL_RECONCILE_DELAYS_MS = { 0, 300, 900, 2000 }

-- `expectNewRows` is true when a mod was just started and is about to append a
-- row. Without one, closing the panel cannot have changed the rail, so a single
-- immediate pass is the whole job.
local function reconcileRailAfterPanel(context, expectNewRows)
    if context == nil then return end

    local schedule = RAIL_RECONCILE_DELAYS_MS
    if not expectNewRows then schedule = { 0 } end

    for _, delay in ipairs(schedule) do
        local function pass()
            -- The context may have been replaced by a new start menu, or the
            -- panel reopened, between scheduling and now.
            if activeContext ~= context or panel.isOpen() then return end

            -- And the player may simply have left the menu. Moving a row around
            -- a widget tree that is being torn down is how the row ends up
            -- detached with nowhere to go back to, and these passes run for two
            -- seconds after the panel closes -- long enough to still be firing
            -- while the menu is on its way out.
            if not menuContextIsMounted(context) then return end

            pcall(refreshRailPosition, context)
        end

        if delay <= 0 then
            pass()
        else
            ExecuteWithDelay(delay, function() onGameThread(pass) end)
        end
    end
end

-- The player must always be able to get out. The panel owns and removes its
-- input shield; it never changes input state on the underlying rail.
local function closePanel()
    if not panel.isOpen() then return end
    onGameThread(function()
        local railContext = activeContext
        local closed, closeError = pcall(panel.close)
        if not closed then
            log("panel close failed: " .. tostring(closeError))
            return
        end
        if panel.isOpen() then
            log("panel still reports itself open after close")
            return
        end

        -- Restoring SubMenu visibility can invalidate pointer state on the one
        -- injected widget this mod owns. Re-establish only that widget's native
        -- contract; no authored or third-party row participates.
        if railContext ~= nil and activeContext == railContext then
            local rearmed, rearmError = rearmModsEntry(railContext)
            if not rearmed then
                log("Mods row rearm after panel close failed: " ..
                    tostring(rearmError))
                return
            end
        end

        -- The panel and its shield are both down. Start whatever was switched
        -- on during this session only after the normal menu is exposed again.
        local started = 0
        local flushed, startedOrError = pcall(function()
            return panel.flushPendingStarts()
        end)
        if flushed then
            started = tonumber(startedOrError) or 0
        else
            log("could not start the mods switched on here: " ..
                tostring(startedOrError))
        end

        if railContext ~= nil and activeContext == railContext then
            -- Reconcile the rail before handing focus back, so the live physical
            -- order is authoritative when focusMods resolves its exact row.
            reconcileRailAfterPanel(railContext, started > 0)
            pcall(focusMods, railContext)
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

local function takeInputLock()
    if inputLocked then return false end
    inputLocked = true
    ExecuteWithDelay(60, function() inputLocked = false end)
    return true
end

-- Returns true when the input was consumed by the panel.
local function routeToPanel(button)
    if not panel.isOpen() then return false end

    if logButtons or CONFIG.DEBUG_LOGS then
        log("panel received button code " .. tostring(button))
    end

    -- Back is deliberately outside the input lock. The lock exists to stop one
    -- physical press from stepping the cursor two or three rows because the
    -- same press arrives on three hooks; closing is idempotent (closePanel
    -- returns immediately once the panel is shut), so repeating it costs
    -- nothing. Inside the lock, a Back that landed within another press's 60ms
    -- window was swallowed by the consume below and dropped without acting,
    -- which turns "the way out" into something that works most of the time.
    -- The way out is the one action that must never be rate-limited.
    if button == BACK_BUTTON then
        closePanel()
        return true
    end

    local direction = directionOf(button)
    if direction == "up" then
        if takeInputLock() then panel.move(-1) end
    elseif direction == "down" then
        if takeInputLock() then panel.move(1) end
    elseif direction == "left" then
        if takeInputLock() then panel.adjust(-1) end
    elseif direction == "right" then
        if takeInputLock() then panel.adjust(1) end
    elseif button == ACCEPT_BUTTON then
        if takeInputLock() then panel.activate() end
    end

    local routed = direction ~= nil or button == ACCEPT_BUTTON
    if routed then
        if activeContext ~= nil then
            pcall(resetNativeSelection, activeContext)
        end
    end

    -- Every button is swallowed while the panel is up, whether or not the lock
    -- let it through, otherwise the start menu underneath keeps reacting to
    -- input aimed at the panel.
    return true
end

--========================================================--
--                       HOOKS                            --
--========================================================--

local function consumeButton(buttonParameter)
    if buttonParameter == nil then error("button hook parameter is unavailable") end
    local ok, consumeError = pcall(function() buttonParameter:set(0) end)
    if not ok then
        error("button hook parameter could not be consumed: " .. tostring(consumeError))
    end
    return true
end

local function handleButton(widgetParameter, buttonParameter)
    local widget = hookValue(widgetParameter, "input widget")
    local button = tonumber(hookValue(buttonParameter, "input button"))
    if button == nil then error("input button did not decode to a number") end

    if panel.isOpen() then
        consumeButton(buttonParameter)
        routeToPanel(button)
        return
    end

    if not isValid(widget) then return end

    local context = activeContext
    if context == nil then return end
    local widgetName = objectName(widget)
    local widgetKey = widgetName
    if widgetKey ~= context.iconKey and not contains(widgetName, MENU_ICON_FRAGMENT) then
        return
    end

    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return
    end
    lastRailError = nil
    local direction = directionOf(button)
    local row = railRowForKey(rows, widgetKey)
    if row == nil then
        local hiddenIndex = authoredIndexForKey(context, widgetKey)
        if hiddenIndex == nil then return end

        -- An authored UObject that is absent from `rows` is not navigable. This
        -- is normally the progression-hidden Logout Item_6. Consume its input
        -- before the invisible row can act, then recover to a visible physical
        -- neighbour without consulting its stale ItemIndex.
        if direction == "up" or direction == "down" or button == ACCEPT_BUTTON then
            consumeButton(buttonParameter)
            if takeInputLock() then
                local firstNative, lastNative, firstInjected, lastInjected =
                    railBoundaries(rows)
                local target = nil
                if direction == "up" then
                    target = lastNative
                elseif direction == "down" then
                    target = firstInjected
                else
                    local previous = listFocusIndexes[context.listKey]
                    target = firstNative ~= nil
                        and previous == firstNative.nativeIndex
                        and lastInjected or firstInjected
                end
                if target == nil then
                    reportRailError("hidden authored row has no visible neighbour")
                else
                    dbg("ignored hidden authored row " .. tostring(hiddenIndex) ..
                        " and restored visible rail focus")
                    focusRailRow(context, target)
                end
            end
        elseif direction ~= nil then
            consumeButton(buttonParameter)
        end
        return
    end

    if row.iconKey == context.iconKey then
        if button == ACCEPT_BUTTON then
            consumeButton(buttonParameter)
            -- Keyboard Enter can reach both this hook and the direct keybind.
            -- Taking the shared lock here prevents the same physical press from
            -- opening the panel and immediately activating its first row.
            if takeInputLock() then openPanel() end
        elseif button == BACK_BUTTON then
            consumeButton(buttonParameter)
            -- Match Equipment's proven close path: leave the native input hook
            -- before EndMenu tears down the widget that originated this event.
            ExecuteWithDelay(0, closeMainMenuFromMods)
        elseif direction == "up" then
            consumeButton(buttonParameter)
            -- Physical adjacency is owned here, independent of another mod's
            -- hook order or its cached custom index.
            if takeInputLock() then moveFromRailKey(context, row.iconKey, -1) end
        elseif direction == "down" then
            consumeButton(buttonParameter)
            if takeInputLock() then moveFromRailKey(context, row.iconKey, 1) end
        elseif direction ~= nil then
            -- Left and right mean nothing on the rail, but the Mods row is not
            -- part of the authored list, so letting them through hands the
            -- native list a press aimed at a row it does not own. Swallowed
            -- without acting: every direction leaves this row the same way.
            consumeButton(buttonParameter)
        end
        return
    end

    -- ModMenu owns only directional hand-offs between physical rail rows. It
    -- never consumes Accept/Back on another mod's icon, so that row retains its
    -- own action while no longer needing special knowledge of its neighbours.
    if row.injected and (direction == "up" or direction == "down") then
        consumeButton(buttonParameter)
        local delta = direction == "up" and -1 or 1
        if takeInputLock() then moveFromRailKey(context, row.iconKey, delta) end
        return
    end

    local firstNative, lastNative = railBoundaries(rows)
    if (direction == "down" and row == lastNative)
        or (direction == "up" and row == firstNative) then
        consumeButton(buttonParameter)
        local delta = direction == "up" and -1 or 1
        if takeInputLock() then moveFromRailKey(context, row.iconKey, delta) end
    end
end

local function handleButtonFailClosed(source, widgetParameter, buttonParameter)
    local ok, inputError = xpcall(
        handleButton, debug.traceback, widgetParameter, buttonParameter)
    if ok then return end

    -- The press that failed must not fall through to the authored list: that is
    -- how a routing error selects the invisible Item_6. Keep the hook installed,
    -- swallow this one press and emit the exact Lua line for the next test.
    local consumed, consumeError = pcall(consumeButton, buttonParameter)
    log(string.format(
        "%s input failed closed (button consumed=%s): %s%s",
        tostring(source), tostring(consumed), tostring(inputError),
        consumed and "" or (" / consume failed: " .. tostring(consumeError))))
end

-- UE4SS removes a ProcessEvent hook permanently when its Lua callback throws.
-- Every callback is retained strongly and contains its own error so one bad
-- event cannot silently delete controller, keyboard or mouse navigation.
local retainedHookCallbacks = {}

local function guardedHookCallback(path, phase, callback)
    local guarded = function(...)
        local ok, callbackError = xpcall(callback, debug.traceback, ...)
        if not ok then
            log(string.format("%s %s hook failed closed: %s",
                tostring(path), tostring(phase), tostring(callbackError)))
        end
    end
    retainedHookCallbacks[#retainedHookCallbacks + 1] = guarded
    return guarded
end

local function safeHook(path, callback, postCallback)
    local guardedPre = guardedHookCallback(path, "pre", callback)
    local guardedPost = postCallback ~= nil
        and guardedHookCallback(path, "post", postCallback) or nil
    local ok, err = pcall(function()
        if guardedPost ~= nil then
            RegisterHook(path, guardedPre, guardedPost)
        else
            RegisterHook(path, guardedPre)
        end
    end)
    if not ok then log("hook unavailable: " .. path .. " / " .. tostring(err)) end
end

local function isCanonicalMainMenuCandidate(mainMenu)
    if not isValid(mainMenu)
        or not contains(objectName(mainMenu), "WBP_Console_MainMenu_C") then
        return false
    end

    local parentComponent = nil
    pcall(function()
        parentComponent = dereferenceWeakObject(mainMenu.ParentComponent)
    end)

    -- The interactive start menu is canonically owned by the game's world-space
    -- widget component. Display-only copies and detached objects from a
    -- discarded world have no such owner and are rejected.
    return isValid(parentComponent)
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

    if type(pendingMenuInjections) ~= "table" then
        error("menu injection state is invalid")
    end
    local readyAt = os.clock() + MENU_INJECTION_DELAY_SEC
    local pending = pendingMenuInjections[menuKey]
    if pending == nil or readyAt < pending then
        pendingMenuInjections[menuKey] = readyAt
    end
    scheduleMenuInjection()
end

local function requirePendingMenuInjections()
    if type(pendingMenuInjections) ~= "table" then
        error("menu injection state is invalid")
    end
    return pendingMenuInjections
end

local function hasPendingMenuInjections()
    for _ in pairs(requirePendingMenuInjections()) do return true end
    return false
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
    local pendingInjections = requirePendingMenuInjections()

    if activeContext ~= nil and not activeMenuContextIsAttached() then
        local staleKey = activeContext.mainMenuKey
        activeContext = nil
        if staleKey ~= nil then injectedMenus[staleKey] = nil end
        panel.close()
    end

    for menuKey, readyAt in pairs(pendingInjections) do
        if now >= readyAt then
            pendingInjections[menuKey] = nil
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
    if menuInjectionTimerScheduled then return end
    if not hasPendingMenuInjections() then return end

    local now = os.clock()
    local earliest = nil
    for _, readyAt in pairs(requirePendingMenuInjections()) do
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
                railFocusKeys = {}
                pendingFocusRedirects = {}
                railFocusMutationDepth = {}
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

-- Construction notification cannot fire for a menu that was already built
-- before this mod started, and that is a real way for this mod to start: UE4SS
-- RestartMod reinstalls a mod mid-session, and the player switching mods on is
-- doing it from a panel drawn over the very start menu this row belongs in.
-- The notification above then waits for a construction that already happened,
-- the mod loads correctly and injects nothing, and the row only appears once
-- the menu has been closed and reopened.
--
-- So sweep once for a menu that is already up. This is not the "scan the global
-- object array" that used to be avoided here: it is the same FindAllOf that
-- resolveMainMenuByKey already runs on every injection cycle, behind the same
-- isCanonicalMainMenuCandidate filter, feeding the same queue and the same
-- readiness delay. A display-only copy or a widget from a discarded world is
-- rejected here exactly as it is everywhere else, and a menu that arrives
-- normally is deduplicated by injectedMenus.
--
-- Defined here, next to the notification it backstops, but fired at the very
-- end of this file: it can queue an injection, and injectModsEntry calls
-- ensureInputHooks, which is not assigned until further down.
local function acquireExistingMainMenu()
    local ok, widgets = pcall(function()
        return FindAllOf("WBP_Console_MainMenu_C")
    end)
    if not ok or type(widgets) ~= "table" then return end

    for _, widget in ipairs(widgets) do
        if isCanonicalMainMenuCandidate(widget) then
            queueMenuInjection(objectName(widget))
        end
    end
end

-- Going into a start-menu submenu and back out can rebuild or re-gate the rail.
--
-- Entering Equipment (or any other native submenu) and returning does not
-- construct a new start menu -- the same WBP_Console_MainMenu_C object stays
-- alive -- but the game may rebuild the row list underneath it or retain the
-- injected widget with stale owner/input gates. A detached row needs the normal
-- injection path; an attached row needs exactly one rearm after the authored
-- rail is fully presented again.
--
-- Neither outcome is synchronous with the event, so this checks a few readiness
-- points rather than guessing one delay. `activeMenuContextIsAttached` selects
-- the two canonical outcomes: rearm in place, or clear the primitive injection
-- marker and reacquire the current Start Menu.
local RAIL_REACQUIRE_DELAYS_MS = { 250, 700, 1500 }
-- ClosedMenu belongs to RODMenuWidgetBase, so it fires for every menu in the
-- game, and twice in a row for one Equipment exit in the logs. Without this the
-- mod would keep three timers in flight per event, forever, for menus that have
-- nothing to do with this rail.
local railReacquireInFlight = false

local function reacquireRailAfterSubmenu()
    if railReacquireInFlight then return end
    railReacquireInFlight = true

    local passes = #RAIL_REACQUIRE_DELAYS_MS
    local attachedRowRearmed = false
    for _, delay in ipairs(RAIL_REACQUIRE_DELAYS_MS) do
        ExecuteWithDelay(delay, function()
            onGameThread(function()
                passes = passes - 1
                if passes <= 0 then railReacquireInFlight = false end
                if panel.isOpen() then return end

                local context = activeContext
                if context ~= nil then
                    if activeMenuContextIsAttached() then
                        if attachedRowRearmed then return end
                        local fullyPresented, presentationError =
                            nativeRailIsFullyPresented(context)
                        if fullyPresented == nil then
                            reportRailError(presentationError)
                            return
                        end
                        if not fullyPresented then return end
                        if refreshRailPosition(context) ~= true then return end
                        local rearmed, rearmError = rearmModsEntry(context)
                        if not rearmed then
                            reportRailError(rearmError)
                            return
                        end
                        attachedRowRearmed = true
                        dbg("rearmed Mods after native submenu return")
                        return
                    end
                    local staleKey = context.mainMenuKey
                    activeContext = nil
                    if staleKey ~= nil then injectedMenus[staleKey] = nil end
                    log("the Mods row left the rail on a submenu return; re-injecting")
                end

                acquireExistingMainMenu()
            end)
        end)
    end
end

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
            handleButtonFailClosed(
                "main-menu delegate", widgetParameter, buttonParameter)
        end)

    safeHook("/Script/ROD.RODInputWidgetBase:OnInputButtonDown",
        function(_, widgetParameter, buttonParameter)
            handleButtonFailClosed(
                "input-widget", widgetParameter, buttonParameter)
        end)

    safeHook("/Script/ROD.RODListWidgetBase:ButtonDownEvent",
        function(_, widgetParameter, buttonParameter)
            handleButtonFailClosed(
                "list-widget", widgetParameter, buttonParameter)
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
            local listKey = objectName(hookValue(self, "focus list"))
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

            if (railFocusMutationDepth[listKey] or 0) > 0 then
                pendingFocusRedirects[listKey] = nil
                return
            end

            -- Cheap: a walk over a handful of children. Catches a mod that
            -- injected its row after this one did.
            if not panel.isOpen() then
                local fullyPresented, presentationError =
                    nativeRailIsFullyPresented(context)
                if fullyPresented == nil then
                    pendingFocusRedirects[listKey] = nil
                    reportRailError(presentationError)
                    return
                end
                if not fullyPresented then
                    -- A native submenu owns focus while its opening animation
                    -- suppresses the rail. Do not reinterpret its selected row
                    -- as a wrap boundary or rewrite the Mods ItemIndex.
                    pendingFocusRedirects[listKey] = nil
                    listFocusIndexes[listKey] = nil
                    railFocusKeys[listKey] = nil
                    clearModsSelection(context)
                    return
                end
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
                pcall(resetNativeSelection, context)
                if not warnedFocusWhilePanelOpen then
                    warnedFocusWhilePanelOpen = true
                    log("native focus is still moving with the panel open; " ..
                        "the input disable did not take on this build")
                end
                return
            end
            if not contains(listKey, "WBP_Console_MainMenu_List_C") then return end

            local widget = hookValue(widgetParameter, "focused widget")
            if not isValid(widget) then return end
            local widgetKey = objectName(widget)

            local rows, railError = collectRailRows(context)
            if rows == nil then
                pendingFocusRedirects[listKey] = nil
                reportRailError(railError)
                return
            end
            lastRailError = nil

            local row = railRowForKey(rows, widgetKey)
            if row ~= nil and row.injected then
                railFocusKeys[listKey] = row.iconKey
                if row.iconKey ~= context.iconKey then clearModsSelection(context) end
                -- An injected row has no meaningful predecessor in the native
                -- cursor. Clearing it prevents our own focus calls from turning
                -- 5 -> injected -> 0 into a fictitious second wrap.
                listFocusIndexes[listKey] = nil
                pendingFocusRedirects[listKey] = nil
                return
            end
            clearModsSelection(context)
            if row ~= nil then railFocusKeys[listKey] = row.iconKey end

            local index = row and row.nativeIndex or nil
            if index == nil then
                index = authoredIndexForKey(context, widgetKey)
            end
            if index == nil then return end

            local previousIndex = listFocusIndexes[listKey]
            listFocusIndexes[listKey] = index
            local firstNative, lastNative, firstInjected, lastInjected =
                railBoundaries(rows)
            if firstNative == nil or lastNative == nil
                or firstInjected == nil or lastInjected == nil then
                pendingFocusRedirects[listKey] = nil
                reportRailError("rail boundaries are incomplete")
                return
            end

            local redirect = nil
            if previousIndex ~= index
                and previousIndex == lastNative.nativeIndex
                and index == firstNative.nativeIndex then
                redirect = "first"
            elseif previousIndex ~= index
                and previousIndex == firstNative.nativeIndex
                and index == lastNative.nativeIndex then
                redirect = "last"
            elseif row == nil and previousIndex == lastNative.nativeIndex then
                redirect = "first"
            elseif row == nil and previousIndex == firstNative.nativeIndex then
                redirect = "last"
            elseif row == nil then
                -- A hidden authored row is never a valid resting place. With no
                -- native predecessor (for example after a foreign injected row)
                -- choose the first injected row deterministically so the cursor
                -- remains visible instead of preserving an invalid selection.
                redirect = "first"
            end
            pendingFocusRedirects[listKey] = redirect
            dbg(string.format("focus %s -> %s%s",
                tostring(previousIndex), tostring(index),
                redirect and (" => redirect to " .. redirect ..
                    " injected row") or ""))
        end,
        function(self)
            local listKey = objectName(hookValue(self, "focus list post"))
            local redirect = pendingFocusRedirects[listKey]
            if redirect == nil then return end
            pendingFocusRedirects[listKey] = nil
            if activeContext ~= nil and not panel.isOpen() then
                local rows, railError = collectRailRows(activeContext)
                if rows == nil then
                    reportRailError(railError)
                    return
                end
                local _, _, firstInjected, lastInjected = railBoundaries(rows)
                local target = redirect == "first" and firstInjected or lastInjected
                if target == nil then
                    reportRailError("focus redirect has no injected target")
                    return
                end
                focusRailRow(activeContext, target)
            end
        end)

    -- Coming back from a native submenu rebuilds the rail out from under this
    -- row. Both events are hooked because EndSubMenu is the main menu's own
    -- return path while ClosedMenu is what the submenu widget itself reports,
    -- and which one fires depends on how the player left. Re-acquisition is
    -- idempotent -- it does nothing when the row is still attached -- so hooking
    -- both costs a cheap check and covers both exits.
    safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:EndSubMenu", function()
        reacquireRailAfterSubmenu()
    end)
    safeHook("/Script/ROD.RODMenuWidgetBase:ClosedMenu", function()
        reacquireRailAfterSubmenu()
    end)

    -- The start menu closing must take the panel with it, or it would be left
    -- floating over the world. The context reference is deliberately kept until
    -- a new real menu replaces it, rather than cleared here: a close is not
    -- proof the menu is gone for good, and processMenuInjectionCycle already
    -- drops the context the moment the row stops being attached to it.
    safeHook("/Script/ROD.RODWidgetBPFunctionLibrary:EndMenu", function()
        if panel.isOpen() then closePanel() end
        -- Release the close lock here rather than leaving it latched until the
        -- next injection. The lock is only there to stop one physical Back
        -- press -- which reaches several hooked functions -- from calling
        -- EndMenu more than once, and by the time this post-hook runs the menu
        -- is already closing, so it has done its job. Latching it meant that a
        -- start menu reopened without being reconstructed (no NotifyOnNewObject,
        -- so no re-injection, so nothing to clear the flag) had a Mods row that
        -- swallowed Back and did nothing with it for the rest of the session.
        ExecuteWithDelay(250, function() menuCloseBusy = false end)
    end)

    log("input hooks installed")
end

--========================================================--
--                      KEYBOARD                          --
--========================================================--

-- Inside the authored range, controller and keyboard directions stay on the
-- native ProcessEvent path. Direct keyboard arrows act only at the two physical
-- boundaries where the authored list can absorb a press without emitting those
-- callbacks. They resolve one exact destination rather than applying a second
-- relative move, so both paths safely converge if the native callback also runs.
local function activeRailContext()
    local context = activeContext
    if not menuContextIsMounted(context) or not isValid(context.icon) then return nil end
    local fullyPresented, presentationError = nativeRailIsFullyPresented(context)
    if fullyPresented == nil then
        reportRailError(presentationError)
        return nil
    end
    if not fullyPresented then return nil end
    return context
end

-- Keyboard arrows can be handled internally by the authored list without
-- reaching any of the ProcessEvent button hooks. At the two physical boundaries
-- only, use the exact focus identity recorded by FocusEvent and our own focus
-- mutations. The target is deterministic, so if a native hook also handles the
-- same press both paths converge on the same row rather than stepping twice.
local function wrapKeyboardRailBoundary(delta)
    if panel.isOpen() then return end
    local context = activeRailContext()
    if context == nil then return end
    if refreshRailPosition(context) ~= true then return end

    local rows, railError = collectRailRows(context)
    if rows == nil then
        reportRailError(railError)
        return
    end
    local focusKey = railFocusKeys[context.listKey]
    if type(focusKey) ~= "string" then
        reportRailError("focused rail identity is unavailable for keyboard wrap")
        return
    end
    local _, position = railRowForKey(rows, focusKey)
    if position == nil then
        reportRailError("focused rail row left the visible rail")
        return
    end

    local target = nil
    if delta < 0 and position == 1 then
        target = rows[#rows]
    elseif delta > 0 and position == #rows then
        target = rows[1]
    end
    if target ~= nil and takeInputLock() then
        if focusRailRow(context, target) then
            dbg(string.format("keyboard boundary wrap: row %d -> row %d",
                position, delta < 0 and #rows or 1))
        end
    end
end

local function activateModsFromKeyboard()
    local context = activeRailContext()
    if context == nil then return end

    local focused, focusError = isNavigationFocused(context.icon)
    if focused == nil then
        reportRailError(focusError)
        return
    end
    if not focused then
        local hovered, hoverError = isMouseHoveringMods(context)
        if hovered == nil then
            reportRailError(hoverError)
            return
        end
        if not hovered then return end
    end

    if takeInputLock() then
        focusMods(context)
        openPanel()
    end
end

local function activateModsFromMouse()
    if panel.isOpen() then
        if not takeInputLock() then return end
        local handled, actionOrError = panel.clickHovered()
        if handled == nil then
            log("panel mouse input failed closed: " .. tostring(actionOrError))
            closePanel()
            return
        end
        if handled and actionOrError == "close" then
            closePanel()
        elseif handled then
            dbg("panel LMB action: " .. tostring(actionOrError))
        end
        return
    end
    local context = activeRailContext()
    if context == nil then return end
    local hovered, hoverError = isMouseHoveringMods(context)
    if hovered == nil then
        reportRailError(hoverError)
        return
    end
    if not hovered then return end

    if takeInputLock() then
        -- A mouse press on the injected icon first runs the authored list's
        -- handler, which restores focus to its native CurrentIndex. Consequently
        -- HasAnyUserFocus() can never survive until a second click. Hover already
        -- identifies the exact Mods UObject, so it is the complete click contract.
        log("LMB opened Mods through native hover")
        openPanel()
    end
end

local function bindPanelKey(key, action, locked, closedAction)
    local ok, err = pcall(function()
        RegisterKeyBind(key, function()
            if not panel.isOpen() then
                if closedAction ~= nil then ExecuteInGameThread(closedAction) end
                return
            end
            -- Shares the lock with the button hooks: the same keypress often
            -- arrives through both paths.
            ExecuteInGameThread(function()
                if locked == false then
                    action()
                elseif takeInputLock() then
                    action()
                end
                if activeContext ~= nil then
                    pcall(resetNativeSelection, activeContext)
                end
            end)
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

-- BACKSPACE joins ESCAPE as a way out. The panel consumes every button while
-- it is up, so if the one bound close key does not arrive on someone's setup
-- there is no other exit -- no mouse path, and Back on the controller is the
-- same code either way. A second keyboard key costs nothing and removes the
-- single point of failure.
for _, binding in ipairs({
    { "UP_ARROW", function() panel.move(-1) end, true,
        function() wrapKeyboardRailBoundary(-1) end },
    { "DOWN_ARROW", function() panel.move(1) end, true,
        function() wrapKeyboardRailBoundary(1) end },
    { "LEFT_ARROW", function() panel.adjust(-1) end, true },
    { "RIGHT_ARROW", function() panel.adjust(1) end, true },
    { "RETURN", function() panel.activate() end, true,
        activateModsFromKeyboard },
    { "ESCAPE", function() closePanel() end, false },
    { "BACKSPACE", function() closePanel() end, false },
}) do
    local code = keyCode(binding[1])
    if code ~= nil then
        bindPanelKey(code, binding[2], binding[3], binding[4])
    end
end

do
    local mouseCode = keyCode("LEFT_MOUSE_BUTTON")
    if mouseCode ~= nil then
        local mouseOk, mouseError = pcall(function()
            RegisterKeyBind(mouseCode, function()
                ExecuteInGameThread(activateModsFromMouse)
            end)
        end)
        if not mouseOk then
            log("left-mouse bridge unavailable: " .. tostring(mouseError))
        end
    end
end

--========================================================--
--                   CONSOLE COMMAND                      --
--========================================================--
-- Read-only diagnostics only. State changes have one canonical path: the panel.

local function probeRail(emit)
    local context = activeContext
    if context == nil then
        emit("rail: no active Mods context")
        return
    end
    emit("rail mounted: " .. tostring(menuContextIsMounted(context)))

    local rows, railError = collectRailRows(context)
    if rows == nil then
        emit("rail unavailable: " .. tostring(railError))
        return
    end

    for position, row in ipairs(rows) do
        local label = nil
        local itemIndex = nil
        local focused = nil
        pcall(function() label = row.icon.MenuName:GetText():ToString() end)
        pcall(function() itemIndex = row.icon:GetItemIndex() end)
        pcall(function() focused = row.icon:HasAnyUserFocus() end)
        emit(string.format(
            "rail[%d] %s label=%s item=%s native=%s focus=%s",
            position - 1,
            row.injected and "injected" or "authored",
            tostring(label),
            tostring(itemIndex),
            tostring(row.nativeIndex),
            tostring(focused)))
    end

    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local item, wrapper = menuItemAndPanel(context.mainList, index)
        if isValid(item) and isValid(wrapper) then
            local visibility = nil
            pcall(function() visibility = wrapper:GetVisibility() end)
            if visibility == COLLAPSED or visibility == HIDDEN then
                emit(string.format(
                    "authored Item_%d excluded by visibility=%s identity=%s",
                    index, tostring(visibility), objectName(item)))
            end
        end
    end
end

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
        ExecuteInGameThread(function()
            local function emit(line) log(line) end
            panel.probe(emit)
            probeRail(emit)
        end)
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

-- Last, so a start menu that is already open when this mod starts is picked up
-- only once everything an injection needs is in place. Reads live UObjects, so
-- it goes to the game thread rather than running on whatever thread the loader
-- started this chunk on.
local sweepOk, sweepError =
    pcall(function() ExecuteInGameThread(acquireExistingMainMenu) end)
if not sweepOk then
    log("could not sweep for an already-open start menu: " .. tostring(sweepError))
end

log(string.format("loaded %s | %d mods registered | console: modmenu list",
    MOD_VERSION, #registry))
