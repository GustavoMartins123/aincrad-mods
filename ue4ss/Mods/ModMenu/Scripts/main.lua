-- ModMenu v1.0
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
local MOD_VERSION = "v1.0"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu.WBP_Console_MainMenu_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"
local MENU_ICON_ASSET =
    "/Game/ROD/Widget/Common/IconImage/ItemCategoryIconImage/T_ItemCategoryIcon_Unknown"
local MENU_ICON_TEXTURE = MENU_ICON_ASSET .. ".T_ItemCategoryIcon_Unknown"

local MAX_NATIVE_MENU_ITEMS = 7
local MENU_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C"

-- Confirmed against the native switch in FieldEquipmentMenu.
local ACCEPT_BUTTON = 1
local BACK_BUTTON = 2
local DPAD_UP = 13
local DPAD_DOWN = 14
local LSTICK_UP = 17
local LSTICK_DOWN = 18
-- Inferred from the pattern above; the game's own code only ever needed the
-- vertical ones, so these have not been observed directly. `modmenu buttons`
-- logs every code the panel receives so they can be corrected from one session.
local DPAD_LEFT = 15
local DPAD_RIGHT = 16
local LSTICK_LEFT = 19
local LSTICK_RIGHT = 20

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2

local SCRIPT_DIR = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[\\/])") or "./"
end)()

local CONFIG = { ENABLED = true, DEBUG_LOGS = false }
local logButtons = false

local injectedMenus = {}
local activeContext = nil
local menuIconTexture = nil

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
    local required, bridge = pcall(require, "ModMenuBridge")
    if required and type(bridge) == "table" then return bridge end
    for _, path in ipairs({
        SCRIPT_DIR .. "../../shared/ModMenuBridge.lua",
        "Mods/shared/ModMenuBridge.lua",
        "Mods\\shared\\ModMenuBridge.lua",
    }) do
        local ok, result = pcall(function() return dofile(path) end)
        if ok and type(result) == "table" then return result end
    end
    return nil
end

-- Printed before anything can fail, so an empty console proves the mod was never
-- loaded at all rather than loaded and aborted.
print(string.format("[%s] main.lua entered | script dir: %s\n", MOD_NAME, SCRIPT_DIR))

local bridge = loadModMenuBridge()
local registry = loadLocalModule("registry")
local store = loadLocalModule("store")
local panel = loadLocalModule("panel")

if bridge == nil or registry == nil or store == nil or panel == nil then
    log(string.format("startup aborted | bridge=%s registry=%s store=%s panel=%s",
        tostring(bridge ~= nil), tostring(registry ~= nil),
        tostring(store ~= nil), tostring(panel ~= nil)))
    return
end

store.init(SCRIPT_DIR, bridge)

do
    local ok, external = pcall(function() return dofile(SCRIPT_DIR .. "config.lua") end)
    if ok and type(external) == "table" then
        if external.ENABLED ~= nil then CONFIG.ENABLED = external.ENABLED ~= false end
        if external.DEBUG_LOGS ~= nil then CONFIG.DEBUG_LOGS = external.DEBUG_LOGS == true end
    end
end

--========================================================--
--                      UI CONTEXT                        --
--========================================================--

local function resolveLocalController()
    for _, className in ipairs({ "RODInGamePlayerController", "PlayerController" }) do
        local controller = FindFirstOf(className)
        if isValid(controller) then return controller end
    end
    return nil
end

local function resolveUmgLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function resolveTextLibrary()
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
end

panel.init({
    registry = registry,
    store = store,
    log = function(message) log("panel: " .. tostring(message)) end,
    resolveController = resolveLocalController,
    resolveUmgLibrary = resolveUmgLibrary,
    hostClassPath = MAIN_MENU_WIDGET_CLASS,
    styleClassPath = MAIN_MENU_ICON_CLASS,
})

--========================================================--
--                    RAIL INJECTION                      --
--========================================================--

local function applyMenuIconTexture(icon)
    if not isValid(icon) or not isValid(icon.IconImage) then return false end

    local texture = menuIconTexture
    if not isValid(texture) then
        for _, path in ipairs({ MENU_ICON_TEXTURE, MENU_ICON_ASSET .. ".0" }) do
            pcall(function() texture = StaticFindObject(path) end)
            if isValid(texture) then break end
        end
    end
    if not isValid(texture) then
        -- The category texture is not guaranteed to be resident when the start
        -- menu is first constructed, so load its package on demand.
        pcall(function() texture = LoadAsset(MENU_ICON_ASSET) end)
    end
    if not isValid(texture) then return false end
    menuIconTexture = texture

    return pcall(function() icon.IconImage:SetBrushFromTexture(texture, false) end)
end

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
    for index = 0, nativeCount - 1 do
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

    local donorLayout = donorItemSlot.LayoutData
    -- The donor icon must be physically removed: collapsing it is not enough
    -- because its original list keeps repainting the icon brush.
    donorItem:RemoveFromParent()
    donorPanel:RemoveFromParent()
    parent:AddChildToVerticalBox(donorPanel)

    local iconSlot = donorPanel:AddChildToCanvas(icon)
    if not isValid(iconSlot) then error("native wrapper rejected the Mods icon") end
    iconSlot:SetLayout(donorLayout)
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
    if injectedMenus[menuKey] ~= nil then return end
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
        applyMenuIconTexture(icon)

        local text = textLibrary:Conv_StringToText("Mods")
        icon:SetMenuName(text)
        icon.MenuName:SetText(text)
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
    injectedMenus[menuKey] = icon
    log(string.format("added Mods entry at index %d (%d native rows, %d row(s) from other mods)",
        modsIndex, nativeCount, foreignRows))

    -- The native open animation can repaint the final authored row, so reapply
    -- the Mods brush once it settles.
    local function guardIcon()
        ExecuteInGameThread(function()
            if activeContext == nil or activeContext.icon ~= icon then return end
            pcall(function() applyMenuIconTexture(icon) end)
        end)
    end
    ExecuteWithDelay(250, guardIcon)
    ExecuteWithDelay(850, guardIcon)
end

--========================================================--
--                        FOCUS                           --
--========================================================--

local function focusIcon(context, icon, index)
    if context == nil or not isValid(icon) then return end
    pcall(function() context.mainList.CurrentIndex = index end)
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
    for index = 0, context.nativeCount - 1 do
        pcall(function() context.mainList["Item_" .. tostring(index)]:SetDefaultAnimation() end)
    end
    focusIcon(context, context.icon, context.modsIndex)
    pcall(function() applyMenuIconTexture(context.icon) end)
end

local function clearModsSelection(context)
    if context == nil or not isValid(context.icon) then return end
    pcall(function() context.icon:SetDefaultAnimation() end)
    pcall(function() applyMenuIconTexture(context.icon) end)
end

-- Upwards out of the Mods row lands on the row directly above it, which is
-- another mod's injected entry when one is present and the last native row
-- otherwise.
local function focusRowAbove(context)
    clearModsSelection(context)
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

local function isModsIcon(widget)
    if activeContext == nil or not isValid(widget) then return false end
    return objectName(widget) == activeContext.iconKey
end

--========================================================--
--                        PANEL                           --
--========================================================--

local function openPanel()
    if panel.isOpen() then return end
    if not panel.open() then
        log("panel could not be opened; use the 'modmenu' console command instead")
        return
    end
    dbg("panel opened")
end

local function closePanel()
    if not panel.isOpen() then return end
    panel.close()
    if activeContext ~= nil then focusMods(activeContext) end
    dbg("panel closed")
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

    if logButtons then log("panel received button code " .. tostring(button)) end

    withInputLock(function()
        if button == DPAD_UP or button == LSTICK_UP then
            panel.move(-1)
        elseif button == DPAD_DOWN or button == LSTICK_DOWN then
            panel.move(1)
        elseif button == DPAD_LEFT or button == LSTICK_LEFT then
            panel.adjust(-1)
        elseif button == DPAD_RIGHT or button == LSTICK_RIGHT then
            panel.adjust(1)
        elseif button == ACCEPT_BUTTON then
            panel.activate()
        elseif button == BACK_BUTTON then
            closePanel()
        end
    end)

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
            ExecuteWithDelay(0, openPanel)
        elseif button == BACK_BUTTON then
            consumeButton(buttonParameter)
            clearModsSelection(activeContext)
        elseif button == DPAD_UP or button == LSTICK_UP then
            consumeButton(buttonParameter)
            -- Locked for the same reason the panel is: this row's navigation is
            -- reached through several hooks that all fire for one press.
            withInputLock(function() focusRowAbove(activeContext) end)
        elseif button == DPAD_DOWN or button == LSTICK_DOWN then
            consumeButton(buttonParameter)
            withInputLock(function() focusFirstNative(activeContext) end)
        end
        return
    end

    -- Downwards off the last row on the rail wraps into Mods. When another mod
    -- owns the row above, that mod hands focus over itself, so only the plain
    -- no-other-mods case is claimed here.
    local context = activeContext
    if context == nil or context.foreignRows > 0 then return end
    if not contains(objectName(widget), "WBP_Console_MainMenu_List_C") then return end

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

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject("/Script/ROD.RODConsoleMainMenuWidgetBase", function(object)
        local mainMenu = unwrap(object)
        -- Logged unconditionally: if the start menu never reaches this callback,
        -- the problem is the notification, not the injection below it.
        log("start-menu candidate constructed: " .. objectName(mainMenu))
        if not contains(objectName(mainMenu), "WBP_Console_MainMenu_C") then return end

        -- Deliberately later than FieldEquipmentMenu's 100ms: whichever rows
        -- other mods add must already be in the VerticalBox when this one counts
        -- them, so that the Mods entry lands underneath with the right index.
        ExecuteWithDelay(400, function()
            ExecuteInGameThread(function() injectModsEntry(mainMenu) end)
        end)
    end)
end)
if not notifyOk then
    log("main-menu object notification unavailable: " .. tostring(notifyError))
end

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

safeHook("/Script/ROD.RODListWidgetBase:ClickEvent",
    function(_, widgetParameter, buttonParameter, _)
        if isModsIcon(unwrap(widgetParameter)) then
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, openPanel)
        end
    end)

safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OnClickMenuItemDelegate",
    function(_, widgetParameter, buttonParameter)
        if isModsIcon(unwrap(widgetParameter)) then
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, openPanel)
        end
    end)

-- The start menu closing must take the panel with it, or it would be left
-- floating over the world.
safeHook("/Script/ROD.RODWidgetBPFunctionLibrary:EndMenu", function()
    if panel.isOpen() then ExecuteWithDelay(0, closePanel) end
    activeContext = nil
end)

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
-- A complete alternative to the panel: everything the menu can do is reachable
-- from here, which keeps the mod usable if the in-game panel fails to build on a
-- given game build.

local function findEntry(name)
    if name == nil then return nil end
    local wanted = string.lower(tostring(name))
    for _, entry in ipairs(registry) do
        if string.lower(entry.mod) == wanted or string.lower(entry.label) == wanted then
            return entry
        end
    end
    return nil
end

local function findSetting(entry, key)
    if key == nil then return nil end
    local wanted = string.lower(tostring(key))
    for _, setting in ipairs(entry.settings or {}) do
        if string.lower(setting.key) == wanted then return setting end
    end
    return nil
end

local function coerce(setting, raw)
    if setting.type == "bool" then
        local lowered = string.lower(tostring(raw))
        if lowered == "on" or lowered == "true" or lowered == "1" then return true end
        if lowered == "off" or lowered == "false" or lowered == "0" then return false end
        return nil, "expected on/off"
    end
    local number = tonumber(raw)
    if number == nil then return nil, "expected a number" end
    if setting.type == "number" then
        if setting.min ~= nil and number < setting.min then
            return nil, string.format("minimum is %s", tostring(setting.min))
        end
        if setting.max ~= nil and number > setting.max then
            return nil, string.format("maximum is %s", tostring(setting.max))
        end
    end
    return number
end

local function runCommand(params, reply)
    local sub = params[1] and string.lower(tostring(params[1])) or "list"

    if sub == "list" or sub == "show" then
        for _, entry in ipairs(registry) do
            local effective = store.readEffective(entry.mod)
            local marker = entry.apply == "restart" and "  (restart)"
                or (entry.apply == "menu" and "  (reopen menu)" or "")
            local enabled = "?"
            for _, setting in ipairs(entry.settings or {}) do
                if setting.key == "ENABLED" then
                    enabled = store.valueOf(effective, setting) and "ON" or "OFF"
                end
            end
            reply(string.format("%-18s %-3s%s", entry.mod, enabled, marker))
            for _, setting in ipairs(entry.settings or {}) do
                if setting.key ~= "ENABLED" then
                    local value = store.valueOf(effective, setting)
                    reply(string.format("    %-22s %s", setting.key, tostring(value)))
                end
            end
        end
        reply("Commands: modmenu set <mod> <key> <value> | reset <mod> | open | close | buttons | probe")
        return
    end

    if sub == "open" then
        ExecuteInGameThread(openPanel)
        reply("opening panel")
        return
    end

    if sub == "close" then
        ExecuteInGameThread(closePanel)
        reply("closing panel")
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

    if sub == "reset" then
        local entry = findEntry(params[2])
        if entry == nil then
            reply("unknown mod: " .. tostring(params[2]))
            return
        end
        local ok, err = store.resetMod(entry.mod)
        reply(ok and (entry.mod .. " reset to config.lua")
            or ("reset failed: " .. tostring(err)))
        return
    end

    if sub == "set" then
        local entry = findEntry(params[2])
        if entry == nil then
            reply("unknown mod: " .. tostring(params[2]))
            return
        end
        local setting = findSetting(entry, params[3])
        if setting == nil then
            reply("unknown setting: " .. tostring(params[3]))
            return
        end
        local value, err = coerce(setting, params[4])
        if value == nil then
            reply(string.format("%s.%s: %s", entry.mod, setting.key, tostring(err)))
            return
        end
        local ok, writeError = store.setValue(entry.mod, setting.key, value)
        if not ok then
            reply("could not save: " .. tostring(writeError))
            return
        end
        reply(string.format("%s.%s = %s", entry.mod, setting.key, tostring(value)))
        if entry.apply == "restart" then reply("takes effect after a game restart") end
        if entry.apply == "menu" then reply("takes effect next time the menu is opened") end
        return
    end

    reply("Unknown command. Use: modmenu list")
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
