-- FieldEquipmentMenu v1.14.5
-- Add a native-styled Equipment entry to Echoes of Aincrad's start menu.

local MOD_NAME = "FieldEquipmentMenu"
local MOD_VERSION = "v1.14.5"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu.WBP_Console_MainMenu_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"
local EQUIPMENT_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/ChestMenu/WBP_Console_ChestMenu_Equipment.WBP_Console_ChestMenu_Equipment_C"
local EQUIPMENT_ICON_ASSET =
    "/Game/ROD/Widget/Common/IconImage/ItemCategoryIconImage/T_ItemCategoryIcon_Unknown"
local EQUIPMENT_ICON_TEXTURE = EQUIPMENT_ICON_ASSET .. ".T_ItemCategoryIcon_Unknown"

local MAX_NATIVE_MENU_ITEMS = 7
local ACCEPT_BUTTON = 1
local BACK_BUTTON = 2
local DPAD_UP = 13
local DPAD_DOWN = 14
local LSTICK_UP = 17
local LSTICK_DOWN = 18
local injectedMenus = {}
local equipmentContexts = {}
local mainMenuFocusIndexes = {}
local pendingFocusRedirects = {}
local activeEquipmentContext = nil
local transitionBusy = false
local menuCloseBusy = false
local equipmentSubmenuOpen = false
local mainMenuSubmenuActive = false
local submenuTransitionSerial = 0
local pendingDualPanel = nil
local creatingStatOverlay = false
local activeStatOverlay = nil
local activeStatOverlayDonor = nil
local equipmentReturnBusy = false
local equipmentIconTexture = nil
local nativeBackRecoveryBusy = false

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2
local HIT_TEST_INVISIBLE = 3

local setEquipmentEntryVisibility
local setNativeMenuPanelsVisibility
local suppressInactiveTrailingNativeRows
local restoreEquipmentEntryPresentation
local activateDualPanel
local beginEquipmentReturnToMain

local SCRIPT_DIR = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[\\/])") or "./"
end)()

local CONFIG = { ENABLED = true, DEBUG_LOGS = true }

local function log(message)
    if not CONFIG.DEBUG_LOGS then return end
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function applyExternalConfig(external)
    if type(external) ~= "table" then return end
    if external.ENABLED ~= nil then CONFIG.ENABLED = external.ENABLED ~= false end
    if external.DEBUG_LOGS ~= nil then CONFIG.DEBUG_LOGS = external.DEBUG_LOGS ~= false end
end

do
    local ok, external = pcall(function() return dofile(SCRIPT_DIR .. "config.lua") end)
    if ok then applyExternalConfig(external) end
end

local function unwrap(parameter)
    if parameter == nil then return nil end
    local ok, value = pcall(function() return parameter:get() end)
    if ok then return value end
    return parameter
end

local function isValidObject(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function dereferenceWeakObject(pointer)
    if isValidObject(pointer) then return pointer end
    if pointer == nil then return nil end
    local ok, object = pcall(function() return pointer:Get() end)
    if ok and isValidObject(object) then return object end
    return nil
end

local function objectName(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    if ok and name then return tostring(name) end
    return tostring(object)
end

local function findWidgetComponentFor(targetWidget)
    if not isValidObject(targetWidget) then return nil end
    local component = dereferenceWeakObject(targetWidget.ParentComponent)
    if isValidObject(component) then return component end

    local targetName = objectName(targetWidget)
    local ok, components = pcall(function() return FindAllOf("RODWidgetComponent") end)
    if not ok or components == nil then return nil end
    for _, candidate in ipairs(components) do
        if isValidObject(candidate) then
            local rootWidget = nil
            pcall(function() rootWidget = candidate:GetWidget() end)
            if objectName(rootWidget) == targetName then
                return candidate
            end
        end
    end
    return nil
end

local EQUIPMENT_CLASS_FRAGMENT = "WBP_Console_ChestMenu_Equipment_C"

local function contains(value, fragment)
    return string.find(tostring(value or ""), fragment, 1, true) ~= nil
end

local function componentDetails(component)
    local rootWidget = nil
    local userWidget = nil
    local owner = nil
    pcall(function() rootWidget = component:GetWidget() end)
    pcall(function() userWidget = component:GetUserWidgetObject() end)
    pcall(function() owner = component:GetOwner() end)
    return rootWidget, userWidget, owner
end

-- DebugOpenMenu may mount a different live widget instance than the object
-- passed to it. Resolve the authored Equipment mount by class identity first,
-- and return the widget that the component is actually rendering.
local function findLiveEquipmentMount(targetWidget, emitTrace)
    local direct = findWidgetComponentFor(targetWidget)
    if isValidObject(direct) then
        local rootWidget, userWidget, owner = componentDetails(direct)
        local liveWidget = isValidObject(rootWidget) and rootWidget or userWidget
        return direct, liveWidget, owner
    end

    local liveWidgets = {}
    if isValidObject(targetWidget) then
        table.insert(liveWidgets, targetWidget)
    end
    local widgetOk, widgets = pcall(function()
        return FindAllOf(EQUIPMENT_CLASS_FRAGMENT)
    end)
    if widgetOk and widgets ~= nil then
        for _, candidate in ipairs(widgets) do
            if isValidObject(candidate) then
                table.insert(liveWidgets, candidate)
                local component = dereferenceWeakObject(candidate.ParentComponent)
                if isValidObject(component) then
                    local rootWidget, userWidget, owner = componentDetails(component)
                    local mountedWidget = isValidObject(rootWidget) and rootWidget
                        or (isValidObject(userWidget) and userWidget or candidate)
                    return component, mountedWidget, owner
                end
            end
        end
    end

    local seen = {}
    local traceCount = 0
    for _, className in ipairs({ "RODWidgetComponent", "WidgetComponent" }) do
        local componentsOk, components = pcall(function() return FindAllOf(className) end)
        if componentsOk and components ~= nil then
            for _, component in ipairs(components) do
                if isValidObject(component) then
                    local componentName = objectName(component)
                    if not seen[componentName] then
                        seen[componentName] = true
                        local rootWidget, userWidget, owner = componentDetails(component)
                        local rootName = objectName(rootWidget)
                        local userName = objectName(userWidget)
                        local ownerName = objectName(owner)
                        if contains(rootName, EQUIPMENT_CLASS_FRAGMENT)
                            or contains(userName, EQUIPMENT_CLASS_FRAGMENT) then
                            local mountedWidget = isValidObject(rootWidget) and rootWidget or userWidget
                            return component, mountedWidget, owner
                        end

                        if emitTrace and traceCount < 30
                            and (contains(componentName, "Menu")
                                or contains(rootName, "Menu")
                                or contains(userName, "Menu")
                                or contains(ownerName, "Menu")
                                or contains(componentName, "Chest")
                                or contains(rootName, "Chest")
                                or contains(userName, "Chest")
                                or contains(ownerName, "Chest")) then
                            traceCount = traceCount + 1
                            log("COMPONENT TRACE component=" .. componentName
                                .. " root=" .. rootName
                                .. " user=" .. userName
                                .. " owner=" .. ownerName)
                        end
                    end
                end
            end
        elseif emitTrace then
            log("COMPONENT TRACE FindAllOf(" .. className .. ") failed")
        end
    end

    if emitTrace then
        log("EQUIPMENT TRACE requested=" .. objectName(targetWidget)
            .. " live-widget-count=" .. tostring(#liveWidgets))
        for index, candidate in ipairs(liveWidgets) do
            if index > 12 then break end
            local parentComponent = dereferenceWeakObject(candidate.ParentComponent)
            local parentActor = dereferenceWeakObject(candidate.ParentActor)
            log("EQUIPMENT TRACE widget=" .. objectName(candidate)
                .. " parent-component=" .. objectName(parentComponent)
                .. " parent-actor=" .. objectName(parentActor))
        end
    end
    return nil, nil, nil
end

local function safeValue(callback)
    local ok, value = pcall(callback)
    if ok then return tostring(value) end
    return "error"
end

local function resolveLocalController()
    local controller = FindFirstOf("RODInGamePlayerController")
    if isValidObject(controller) then return controller end
    return nil
end

local function resolveLibraries()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"),
        StaticFindObject("/Script/ROD.Default__RODWidgetBPFunctionLibrary"),
        StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
end

local function applyEquipmentIconTexture(icon)
    if not isValidObject(icon) or not isValidObject(icon.IconImage) then return false end

    local texture = equipmentIconTexture
    if not isValidObject(texture) then
        pcall(function() texture = StaticFindObject(EQUIPMENT_ICON_TEXTURE) end)
    end
    if not isValidObject(texture) then
        pcall(function()
            texture = StaticFindObject(EQUIPMENT_ICON_ASSET .. ".0")
        end)
    end
    if not isValidObject(texture) then
        -- This category texture is not guaranteed to be resident when the
        -- start menu is first constructed, so load its package on demand.
        pcall(function() texture = LoadAsset(EQUIPMENT_ICON_ASSET) end)
    end
    if not isValidObject(texture) then
        pcall(function() texture = LoadAsset(EQUIPMENT_ICON_TEXTURE) end)
    end
    if not isValidObject(texture) then return false end
    equipmentIconTexture = texture

    local applied = pcall(function()
        -- Preserve the authored 64x64 icon size while replacing only its art.
        icon.IconImage:SetBrushFromTexture(texture, false)
    end)
    return applied
end

local function menuItemAndPanel(mainList, index)
    local item = nil
    local panel = nil
    pcall(function()
        item = mainList["Item_" .. tostring(index)]
        panel = item.Slot.Parent
    end)
    return item, panel
end

local function resolveNativeMenuCount(mainMenu, mainList)
    local finalNativeIndex = nil
    pcall(function() finalNativeIndex = tonumber(mainMenu.NumContent) end)
    -- Despite its name, NumContent is the final zero-based authored index:
    -- 6 means seven rows (0..6), while 5 means six rows after Logout is gone.
    local count = finalNativeIndex ~= nil and finalNativeIndex + 1 or nil
    if count == nil or count < 1 or count > MAX_NATIVE_MENU_ITEMS then
        count = 0
        for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
            local item = menuItemAndPanel(mainList, index)
            if isValidObject(item) then count = index + 1 end
        end
    end

    -- Some builds retain Logout in NumContent but collapse its authored panel
    -- once the opening restriction is gone. Trim only collapsed/hidden rows at
    -- the tail; transient animation states such as HitTestInvisible stay active.
    while count > 1 do
        local _, panel = menuItemAndPanel(mainList, count - 1)
        local _, previousPanel = menuItemAndPanel(mainList, count - 2)
        local visibility = nil
        local previousVisibility = nil
        pcall(function() visibility = panel:GetVisibility() end)
        pcall(function() previousVisibility = previousPanel:GetVisibility() end)
        if visibility ~= COLLAPSED and visibility ~= HIDDEN then break end
        -- If both rows are collapsed, the whole rail is probably still inside
        -- its opening animation; do not mistake that transient state for a
        -- progression-based removal of the final row.
        if previousVisibility == COLLAPSED or previousVisibility == HIDDEN then break end
        count = count - 1
    end
    return count
end

local function attachEquipmentIconWithNativeWrapper(umgLibrary, controller, iconParent, icon)
    local listClass = StaticFindObject(MAIN_MENU_LIST_CLASS)
    if not isValidObject(listClass) then
        error("native main-menu list class is unavailable")
    end

    local donorList = umgLibrary:Create(controller, listClass, controller)
    if not isValidObject(donorList) then
        error("native wrapper donor creation returned null")
    end

    local donorItem = donorList.Item_6
    local donorItemSlot = isValidObject(donorItem) and donorItem.Slot or nil
    local donorPanel = isValidObject(donorItemSlot) and donorItemSlot.Parent or nil
    if not isValidObject(donorItem) or not isValidObject(donorItemSlot)
        or not isValidObject(donorPanel) then
        error("native Logout wrapper hierarchy is unavailable")
    end

    local donorLayout = donorItemSlot.LayoutData
    -- Physically remove the donor icon. Collapsing or repurposing it is not
    -- sufficient because its original list keeps repainting the icon brush.
    donorItem:RemoveFromParent()
    donorPanel:RemoveFromParent()
    iconParent:AddChildToVerticalBox(donorPanel)
    local iconSlot = donorPanel:AddChildToCanvas(icon)
    if not isValidObject(iconSlot) then
        error("native wrapper rejected the Equipment icon")
    end
    iconSlot:SetLayout(donorLayout)
    iconSlot:SetAutoSize(true)
    iconSlot:SetZOrder(20)
    icon:SetVisibility(VISIBLE)
    donorPanel:SetVisibility(VISIBLE)
    pcall(function() donorPanel:ForceLayoutPrepass() end)
    return donorList, donorPanel
end

local function openEquipmentWidget(ignoreActiveMenu)
    local controller = resolveLocalController()
    if not isValidObject(controller) then
        log("cannot open equipment: local controller is not ready")
        transitionBusy = false
        return false
    end

    local umgLibrary, rodLibrary = resolveLibraries()
    if not isValidObject(umgLibrary) or not isValidObject(rodLibrary) then
        log("cannot open equipment: widget libraries are unavailable")
        transitionBusy = false
        return false
    end

    if not ignoreActiveMenu then
        local activeOk, menuActive = pcall(function()
            return rodLibrary:IsActiveMenuWidget(controller)
        end)
        if activeOk and menuActive then
            transitionBusy = false
            return false
        end
    end

    local widgetClass = StaticFindObject(EQUIPMENT_WIDGET_CLASS)
    if not isValidObject(widgetClass) then
        log("cannot open equipment: widget class is not loaded")
        transitionBusy = false
        return false
    end

    local widget = nil
    local created, createError = pcall(function()
        widget = umgLibrary:Create(controller, widgetClass, controller)
    end)
    if not created or not isValidObject(widget) then
        log("equipment widget creation failed: " .. tostring(createError))
        transitionBusy = false
        return false
    end

    local handle = nil
    local registered, registerError = pcall(function()
        handle = rodLibrary:DebugOpenMenu(controller, widget)
    end)
    if not registered or handle == nil then
        log("equipment menu registration failed: " .. tostring(registerError))
        transitionBusy = false
        return false
    end

    local opened, openError = pcall(function()
        rodLibrary:OpenMenu(controller, handle)
    end)
    transitionBusy = false
    if opened then
        log("opened equipment and weapons")
        return true
    end

    log("equipment menu opening failed: " .. tostring(openError))
    return false
end

local function selectInjectedEquipment()
    if transitionBusy then return end
    transitionBusy = true

    ExecuteInGameThread(function()
        local context = activeEquipmentContext
        local controller = resolveLocalController()
        local umgLibrary, rodLibrary = resolveLibraries()
        if context == nil or not isValidObject(context.mainMenu)
            or not isValidObject(context.mainList)
            or not isValidObject(controller)
            or not isValidObject(umgLibrary)
            or not isValidObject(rodLibrary) then
            log("cannot open Equipment submenu: UI context is unavailable")
            transitionBusy = false
            return
        end

        -- DebugOpenMenu constructs and opens this particular chest widget
        -- asynchronously. Once it exists, move it from the top-level menu layer
        -- into the start menu's authored SubMenu canvas.
        equipmentSubmenuOpen = true
        mainMenuSubmenuActive = true
        submenuTransitionSerial = submenuTransitionSerial + 1
        pendingFocusRedirects[context.listKey] = nil
        pcall(function() context.mainList.CurrentIndex = 0 end)
        setNativeMenuPanelsVisibility(context, COLLAPSED)
        setEquipmentEntryVisibility(context, VISIBLE)
        restoreEquipmentEntryPresentation(context)

        local widgetClass = StaticFindObject(EQUIPMENT_WIDGET_CLASS)
        local widget = nil
        local equipmentHandle = nil
        local registered, registerError = pcall(function()
            if not isValidObject(widgetClass) then
                error("Equipment widget class is not loaded")
            end
            widget = umgLibrary:Create(controller, widgetClass, controller)
            if not isValidObject(widget) then
                error("Equipment widget creation returned null")
            end

            widget.ParentMenu = context.mainMenu
            widget.MenuKind = 33
            equipmentHandle = rodLibrary:DebugOpenMenu(controller, widget)
            if equipmentHandle == nil then
                error("DebugOpenMenu returned no Equipment handle")
            end
        end)
        if not registered then
            equipmentSubmenuOpen = false
            mainMenuSubmenuActive = false
            setNativeMenuPanelsVisibility(context, VISIBLE)
            setEquipmentEntryVisibility(context, VISIBLE)
            transitionBusy = false
            log("native Equipment widget registration failed: " .. tostring(registerError))
            return
        end

        do
            log("Equipment opened; waiting for the old start-menu close animation")
            ExecuteWithDelay(1600, function()
                activateDualPanel(context, {
                    widget = widget,
                    controller = controller,
                })
            end)
            return
        end

        pcall(function() context.mainMenu:SetSelectAnimation() end)
        log("Equipment opened; waiting to attach it to the start-menu canvas")
        ExecuteWithDelay(125, function()
            ExecuteInGameThread(function()
                local subMenu = nil
                local slot = nil
                local menuComponent = nil
                local menuActor = nil
                local attached, attachError = pcall(function()
                    if not isValidObject(widget) or not isValidObject(context.mainMenu) then
                        error("Equipment or start-menu widget expired")
                    end
                    subMenu = context.mainMenu.SubMenu
                    if not isValidObject(subMenu) then
                        error("start-menu SubMenu canvas is unavailable")
                    end

                    menuComponent = dereferenceWeakObject(widget.ParentComponent)
                    if not isValidObject(menuComponent) then
                        menuComponent = dereferenceWeakObject(context.mainMenu.ParentComponent)
                    end
                    if not isValidObject(menuComponent) then
                        menuActor = dereferenceWeakObject(widget.ParentActor)
                            or dereferenceWeakObject(context.mainMenu.ParentActor)
                        if isValidObject(menuActor) then
                            pcall(function()
                                menuActor.WidgetComponents:ForEach(function(_, componentParameter)
                                    local component = unwrap(componentParameter)
                                    if not isValidObject(component) then return false end
                                    local currentWidget = nil
                                    pcall(function() currentWidget = component:GetWidget() end)
                                    if objectName(currentWidget) == objectName(widget) then
                                        menuComponent = component
                                        return true
                                    end
                                    if not isValidObject(menuComponent) then
                                        menuComponent = component
                                    end
                                    return false
                                end)
                            end)
                        end
                    end
                    if not isValidObject(menuComponent) then
                        error("world-space menu component is unavailable")
                    end

                    widget:RemoveFromParent()
                    slot = subMenu:AddChildToCanvas(widget)
                    if not isValidObject(slot) then
                        error("SubMenu canvas rejected Equipment")
                    end
                    local drawSize = menuComponent:GetDrawSize()
                    local zero = widget:GetDesiredSize()
                    zero.X = 0.0
                    zero.Y = 0.0
                    slot:SetAutoSize(false)
                    slot:SetPosition(zero)
                    slot:SetAlignment(zero)
                    slot:SetSize(drawSize)
                    slot:SetZOrder(10)
                    menuComponent:SetWidget(context.mainMenu)
                    if not isValidObject(menuActor) then
                        pcall(function() menuActor = menuComponent:GetOwner() end)
                    end
                    if isValidObject(menuActor) then
                        menuActor:SetActorHiddenInGame(false)
                    end
                    menuComponent:SetActive(true, true)
                    menuComponent:SetComponentTickEnabled(true)
                    menuComponent:SetHiddenInGame(false, true)
                    menuComponent:SetVisibility(true, true)
                    menuComponent:SetTickWhenOffscreen(true)
                    context.mainMenu:SetVisibility(VISIBLE)
                    widget:SetVisibility(VISIBLE)
                    pcall(function() context.mainMenu:SetInteraction(false) end)
                    pcall(function() widget:SetInteraction(true) end)
                    menuComponent:RequestRenderUpdate()
                    menuComponent:RequestRedraw()
                end)
                transitionBusy = false
                if not attached then
                    equipmentSubmenuOpen = false
                    mainMenuSubmenuActive = false
                    setNativeMenuPanelsVisibility(context, VISIBLE)
                    setEquipmentEntryVisibility(context, VISIBLE)
                    pcall(function() context.mainMenu:SetVisibility(VISIBLE) end)
                    pcall(function() context.mainMenu:SetBackAnimation() end)
                    log("Equipment canvas attachment failed: " .. tostring(attachError))
                    return
                end

                setNativeMenuPanelsVisibility(context, COLLAPSED)
                setEquipmentEntryVisibility(context, VISIBLE)
                restoreEquipmentEntryPresentation(context)
                log("attached Equipment under the restored start-menu component: "
                    .. objectName(menuComponent))
                ExecuteWithDelay(500, function()
                    ExecuteInGameThread(function()
                        if not isValidObject(menuComponent) then
                            log("RENDER TRACE component expired")
                            return
                        end

                        local function renderTrace(stage)
                            local rootWidget = nil
                            pcall(function() rootWidget = menuComponent:GetWidget() end)
                            log("RENDER " .. stage
                                .. " main[visibility=" .. safeValue(function() return context.mainMenu:GetVisibility() end)
                                .. " visible=" .. safeValue(function() return context.mainMenu:IsVisible() end)
                                .. " rendered=" .. safeValue(function() return context.mainMenu:IsRendered() end)
                                .. " opacity=" .. safeValue(function() return context.mainMenu:GetRenderOpacity() end) .. "]"
                                .. " equip[visibility=" .. safeValue(function() return widget:GetVisibility() end)
                                .. " visible=" .. safeValue(function() return widget:IsVisible() end)
                                .. " rendered=" .. safeValue(function() return widget:IsRendered() end)
                                .. " opacity=" .. safeValue(function() return widget:GetRenderOpacity() end) .. "]"
                                .. " component[root=" .. objectName(rootWidget)
                                .. " visible=" .. safeValue(function() return menuComponent:IsVisible() end)
                                .. " widgetVisible=" .. safeValue(function() return menuComponent:IsWidgetVisible() end)
                                .. " active=" .. safeValue(function() return menuComponent:IsActive() end) .. "]")
                        end

                        renderTrace("before-late-restore")
                        local restored, restoreError = pcall(function()
                            menuComponent:SetWidget(context.mainMenu)
                            if isValidObject(menuActor) then
                                menuActor:SetActorHiddenInGame(false)
                            end
                            menuComponent:SetActive(true, true)
                            menuComponent:SetComponentTickEnabled(true)
                            menuComponent:SetHiddenInGame(false, true)
                            menuComponent:SetVisibility(true, true)
                            menuComponent:SetTickWhenOffscreen(true)
                            context.mainMenu:SetVisibility(VISIBLE)
                            context.mainMenu:SetRenderOpacity(1.0)
                            subMenu:SetVisibility(VISIBLE)
                            subMenu:SetRenderOpacity(1.0)
                            widget:SetVisibility(VISIBLE)
                            widget:SetRenderOpacity(1.0)
                            widget:ProcessForcedCameraValues(widget.OpenForcedCameraSettings)
                            widget:OnStartOpenMenuAnimation()
                            context.mainMenu:SetSelectAnimation()
                            setNativeMenuPanelsVisibility(context, COLLAPSED)
                            setEquipmentEntryVisibility(context, VISIBLE)
                            restoreEquipmentEntryPresentation(context)
                            context.mainMenu:SetInteraction(false)
                            widget:SetInteraction(true)
                            widget:SetFocus()
                            widget:SetKeyboardFocus()
                            widget:SetUserFocus(controller)
                            context.mainMenu:ForceLayoutPrepass()
                            menuComponent:RequestRenderUpdate()
                            menuComponent:RequestRedraw()
                        end)
                        log("restored Equipment forced camera; success=" .. tostring(restored)
                            .. " enabled=" .. safeValue(function() return widget.IsOpenCameraEnable end)
                            .. " error=" .. tostring(restoreError))
                        renderTrace("after-late-restore")
                    end)
                end)
            end)
        end)
    end)
end

activateDualPanel = function(context, pending)
    ExecuteInGameThread(function()
        if context == nil or pending == nil or not isValidObject(context.mainMenu)
            or not isValidObject(pending.widget) then
            transitionBusy = false
            equipmentSubmenuOpen = false
            mainMenuSubmenuActive = false
            log("stat-panel reactivation failed: the menu context expired")
            return
        end

        local mainComponent = findWidgetComponentFor(context.mainMenu)
        local mainActor = nil
        if isValidObject(mainComponent) then
            pcall(function() mainActor = mainComponent:GetOwner() end)
        end

        local overlay = nil
        local overlayIcon = nil
        local overlayWrapperDonor = nil
        local overlayWrapperPanel = nil
        local overlayList = nil
        local overlayNativePanels = {}
        local equipmentLabelText = nil
        local activated, activateError = pcall(function()
            if not isValidObject(mainComponent) then
                error("existing start-menu component is unavailable")
            end

            local umgLibrary, _, textLibrary = resolveLibraries()
            local overlayClass = StaticFindObject(MAIN_MENU_WIDGET_CLASS)
            local iconClass = StaticFindObject(MAIN_MENU_ICON_CLASS)
            if not isValidObject(umgLibrary) or not isValidObject(textLibrary)
                or not isValidObject(overlayClass) or not isValidObject(iconClass) then
                error("fresh main-menu overlay class or UMG library is unavailable")
            end
            equipmentLabelText = textLibrary:Conv_StringToText("Equipment")

            -- The original main widget owns a delayed close animation. Create
            -- a display-only clone so the menu manager cannot collapse it after
            -- Equipment has opened.
            creatingStatOverlay = true
            overlay = umgLibrary:Create(pending.controller, overlayClass, pending.controller)
            creatingStatOverlay = false
            if not isValidObject(overlay) then
                error("fresh main-menu overlay creation returned null")
            end

            mainComponent:SetVisibility(false, true)
            context.mainMenu:RemoveFromParent()
            pcall(function() overlay:InitializeMenuWidget() end)
            pcall(function() overlay:OpenedMenu() end)
            overlay:AddToViewport(0)
            -- This clone is display-only. Its full-screen root otherwise sits
            -- above the native Equipment widget and swallows mouse hit tests.
            overlay:SetVisibility(HIT_TEST_INVISIBLE)
            overlay:SetRenderOpacity(1.0)

            local heroDetail = overlay.HeroDetail
            local heroSlot = isValidObject(heroDetail) and heroDetail.Slot or nil
            if not isValidObject(heroSlot) then
                error("fresh overlay HeroDetail slot is unavailable")
            end
            local heroNudge = heroSlot.Nudge
            heroNudge.X = -560.0
            heroNudge.Y = 0.0
            heroSlot:SetNudge(heroNudge)

            overlayList = overlay.MainMenu_List
            local lastItem = overlayList.Item_6
            local lastPanel = lastItem.Slot.Parent
            local iconParent = lastPanel.Slot.Parent
            if not isValidObject(overlayList) or not isValidObject(lastItem)
                or not isValidObject(lastPanel) or not isValidObject(iconParent) then
                error("fresh overlay menu-list hierarchy is unavailable")
            end
            overlayIcon = umgLibrary:Create(pending.controller, iconClass, pending.controller)
            if not isValidObject(overlayIcon) then
                error("fresh overlay Equipment icon creation returned null")
            end
            overlayWrapperDonor, overlayWrapperPanel =
                attachEquipmentIconWithNativeWrapper(
                    umgLibrary, pending.controller, iconParent, overlayIcon)
            overlayIcon:SetItemIndex(context.equipmentIndex)
            overlayIcon:SetOwnerInputWidget(overlayList)
            overlayIcon:SetInactive(false)
            overlayIcon:SetBlank(false)
            overlayIcon:SetInputEnable(false)
            overlayIcon:BP_SetInputInteractionEnable(false)
            overlayIcon:SetMenuName(equipmentLabelText)
            for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
                local panel = nil
                pcall(function()
                    panel = overlayList["Item_" .. tostring(index)].Slot.Parent
                end)
                if isValidObject(panel) then
                    panel:SetVisibility(COLLAPSED)
                    table.insert(overlayNativePanels, panel)
                end
            end
            overlayList:SetVisibility(VISIBLE)
            pcall(function() overlay:SetSelectAnimation() end)
            -- Select (not Select_Full) is the authored one-icon submenu state:
            -- it leaves MenuIcon opaque and fades the cyan SelectMenu arrow in.
            overlayIcon:SetSelectAnimation()
            if not applyEquipmentIconTexture(overlayIcon) then
                error("dedicated Equipment icon texture is unavailable")
            end
            pcall(function() overlay:SetInteraction(false) end)
            pending.widget:SetVisibility(VISIBLE)
            pending.widget:SetRenderOpacity(1.0)
            pending.widget:SetInteraction(true)

            pending.widget:SetFocus()
            pending.widget:SetKeyboardFocus()
            pending.widget:SetUserFocus(pending.controller)
            overlay:ForceLayoutPrepass()
        end)
        creatingStatOverlay = false
        transitionBusy = false
        if not activated then
            equipmentSubmenuOpen = false
            mainMenuSubmenuActive = false
            setNativeMenuPanelsVisibility(context, VISIBLE)
            setEquipmentEntryVisibility(context, VISIBLE)
            log("stat-panel reactivation beside Equipment failed: " .. tostring(activateError))
            return
        end

        equipmentSubmenuOpen = true
        mainMenuSubmenuActive = true
        activeStatOverlay = overlay
        activeStatOverlayDonor = overlayWrapperDonor
        log("mounted fresh stat overlay and Equipment icon: overlay="
            .. objectName(overlay) .. " widget=" .. objectName(pending.widget))
        ExecuteWithDelay(650, function()
            ExecuteInGameThread(function()
                if not equipmentSubmenuOpen or activeEquipmentContext ~= context
                    or not isValidObject(overlay)
                    or not isValidObject(pending.widget) then
                    return
                end
                local guarded, guardError = pcall(function()
                    local inViewport = false
                    pcall(function() inViewport = overlay:IsInViewport() end)
                    if not inViewport then
                        overlay:AddToViewport(0)
                    end
                    overlay:SetVisibility(HIT_TEST_INVISIBLE)
                    overlay:SetRenderOpacity(1.0)
                    pcall(function() overlay.MainMenu_List:SetVisibility(VISIBLE) end)
                    for _, panel in ipairs(overlayNativePanels) do
                        if isValidObject(panel) then panel:SetVisibility(COLLAPSED) end
                    end
                    if isValidObject(overlayIcon) then
                        if isValidObject(overlayWrapperPanel) then
                            overlayWrapperPanel:SetVisibility(VISIBLE)
                        end
                        overlayIcon:SetVisibility(VISIBLE)
                        overlayIcon:SetRenderOpacity(1.0)
                        overlayIcon:SetMenuName(equipmentLabelText)
                        overlayIcon.MenuName:SetText(equipmentLabelText)
                        if not applyEquipmentIconTexture(overlayIcon) then
                            error("Equipment icon texture guard failed")
                        end
                    end
                    pending.widget:SetVisibility(VISIBLE)
                    pending.widget:SetRenderOpacity(1.0)
                    pending.widget:SetInteraction(true)
                end)
                log("fresh stat-overlay guard applied; success=" .. tostring(guarded)
                    .. " error=" .. tostring(guardError))
            end)
        end)
        ExecuteWithDelay(1300, function()
            ExecuteInGameThread(function()
                if not equipmentSubmenuOpen or activeEquipmentContext ~= context
                    or not isValidObject(overlayIcon) then
                    return
                end
                pcall(function()
                    if isValidObject(overlayWrapperPanel) then
                        overlayWrapperPanel:SetVisibility(VISIBLE)
                    end
                    overlayIcon:SetVisibility(VISIBLE)
                    overlayIcon:SetRenderOpacity(1.0)
                    overlayIcon:SetMenuName(equipmentLabelText)
                    overlayIcon.MenuName:SetText(equipmentLabelText)
                    applyEquipmentIconTexture(overlayIcon)
                end)
            end)
        end)
    end)
end

local function injectEquipmentEntry(mainMenu)
    if not CONFIG.ENABLED then return end
    if not isValidObject(mainMenu) then return end
    local menuKey = objectName(mainMenu)
    if injectedMenus[menuKey] ~= nil then return end

    local controller = resolveLocalController()
    local umgLibrary, _, textLibrary = resolveLibraries()
    if not isValidObject(controller) or not isValidObject(umgLibrary)
        or not isValidObject(textLibrary) then
        log("cannot inject Equipment entry: UI context is unavailable")
        return
    end

    local mainList = nil
    local firstItem = nil
    local firstItemPanel = nil
    local lastItem = nil
    local parent = nil
    pcall(function()
        mainList = mainMenu.MainMenu_List
        firstItem, firstItemPanel = menuItemAndPanel(mainList, 0)
        -- Each native item is wrapped by its own CanvasPanel. That panel, not
        -- the item itself, is the direct child of the MenuIcon VerticalBox.
        parent = firstItemPanel.Slot.Parent
    end)
    if not isValidObject(mainList) or not isValidObject(firstItem)
        or not isValidObject(firstItemPanel) or not isValidObject(parent) then
        log("cannot inject Equipment entry: main-menu list hierarchy is unavailable")
        return
    end

    local nativeCount = resolveNativeMenuCount(mainMenu, mainList)
    local equipmentIndex = nativeCount
    lastItem = menuItemAndPanel(mainList, nativeCount - 1)
    if not isValidObject(lastItem) then
        log("cannot inject Equipment entry: final active native item is unavailable")
        return
    end

    local authoredWrapperCount = 0
    local parentKey = objectName(parent)
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local _, panel = menuItemAndPanel(mainList, index)
        local panelParent = nil
        pcall(function() panelParent = panel.Slot.Parent end)
        if isValidObject(panel) and isValidObject(panelParent)
            and objectName(panelParent) == parentKey then
            authoredWrapperCount = authoredWrapperCount + 1
        end
    end
    if authoredWrapperCount < nativeCount then
        -- Never prune an uncertain hierarchy. At worst a hot reload keeps one
        -- stale row until the menu is recreated; native authored rows are safe.
        pcall(function() authoredWrapperCount = parent:GetChildrenCount() end)
    end

    -- Restart All Mods resets Lua tables but can leave the already-mutated UMG
    -- tree alive. Remove children beyond the attached authored wrappers before
    -- appending this build's single row; Logout may exist but be collapsed.
    local removedLegacyRows = 0
    pcall(function()
        local childCount = parent:GetChildrenCount()
        while childCount > authoredWrapperCount do
            local legacyRow = parent:GetChildAt(childCount - 1)
            if not isValidObject(legacyRow) then break end
            legacyRow:RemoveFromParent()
            removedLegacyRows = removedLegacyRows + 1
            local nextCount = parent:GetChildrenCount()
            if nextCount >= childCount then break end
            childCount = nextCount
        end
    end)
    if removedLegacyRows > 0 then
        log("removed " .. tostring(removedLegacyRows)
            .. " stale Equipment rail row(s) from an older hot reload")
    end

    local equipmentIcon = nil
    local equipmentWrapperDonor = nil
    local equipmentWrapperPanel = nil

    local iconClass = StaticFindObject(MAIN_MENU_ICON_CLASS)
    if not isValidObject(iconClass) then
        log("cannot inject Equipment entry: native icon class is not loaded")
        return
    end

    local configured, configureError = pcall(function()
        equipmentIcon = umgLibrary:Create(controller, iconClass, controller)
        if not isValidObject(equipmentIcon) then
            error("Equipment icon creation returned null")
        end
        equipmentWrapperDonor, equipmentWrapperPanel =
            attachEquipmentIconWithNativeWrapper(
                umgLibrary, controller, parent, equipmentIcon)
        equipmentIcon:SetItemIndex(equipmentIndex)
        equipmentIcon:SetOwnerInputWidget(mainList)
        equipmentIcon:SetInactive(false)
        equipmentIcon:SetBlank(false)
        equipmentIcon:SetInputEnable(true)
        equipmentIcon:BP_SetInputInteractionEnable(true)
        equipmentIcon:SetDefaultAnimation()
        if not applyEquipmentIconTexture(equipmentIcon) then
            error("dedicated Equipment icon texture is unavailable")
        end
        local equipmentText = textLibrary:Conv_StringToText("Equipment")
        equipmentIcon:SetMenuName(equipmentText)
        equipmentIcon.MenuName:SetText(equipmentText)
    end)
    if not configured then
        log("Equipment entry configuration failed: " .. tostring(configureError))
        return
    end

    local context = {
        mainMenu = mainMenu,
        mainMenuKey = menuKey,
        mainList = mainList,
        listKey = objectName(mainList),
        firstItem = firstItem,
        lastItem = lastItem,
        nativeCount = nativeCount,
        equipmentIndex = equipmentIndex,
        equipmentIcon = equipmentIcon,
        equipmentWrapperDonor = equipmentWrapperDonor,
        equipmentWrapperPanel = equipmentWrapperPanel,
        equipmentWrapperParent = parent,
        equipmentWrapperAttached = true,
        nativePanels = {},
        inactiveTrailingNativeRows = {},
    }
    for index = 0, nativeCount - 1 do
        local item = nil
        local panel = nil
        pcall(function()
            item = mainList["Item_" .. tostring(index)]
            panel = item.Slot.Parent
        end)
        if isValidObject(panel) then
            table.insert(context.nativePanels, panel)
        end
    end
    for index = nativeCount, MAX_NATIVE_MENU_ITEMS - 1 do
        local item, panel = menuItemAndPanel(mainList, index)
        if isValidObject(item) or isValidObject(panel) then
            local row = { item = item, panel = panel, widgets = {} }
            -- The final authored row's frame/connector are independent named
            -- animation targets. Keep every layer suppressed after Logout is
            -- progression-hidden, not only its Item_6 widget.
            for _, prefix in ipairs({
                "MenuIcon", "Scanline", "ScanlineImage", "Around_Menu"
            }) do
                local widget = nil
                pcall(function() widget = mainList[prefix .. tostring(index + 1)] end)
                if isValidObject(widget) then table.insert(row.widgets, widget) end
            end
            table.insert(context.inactiveTrailingNativeRows, row)
        end
    end
    suppressInactiveTrailingNativeRows(context)
    equipmentContexts[objectName(equipmentIcon)] = context
    activeEquipmentContext = context
    menuCloseBusy = false
    injectedMenus[menuKey] = equipmentIcon
    log("added Equipment entry at dynamic index " .. tostring(equipmentIndex)
        .. " after " .. tostring(nativeCount) .. " active native row(s)")

    -- The native start-menu open animation can repaint its final authored item.
    -- Reapply only the Equipment brush once that authored animation settles.
    local function guardInitialEquipmentIcon()
        ExecuteInGameThread(function()
            if activeEquipmentContext ~= context or mainMenuSubmenuActive
                or not isValidObject(context.equipmentIcon) then
                return
            end
            pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
            suppressInactiveTrailingNativeRows(context)
        end)
    end
    ExecuteWithDelay(250, guardInitialEquipmentIcon)
    ExecuteWithDelay(850, guardInitialEquipmentIcon)
    if pendingDualPanel ~= nil then
        local pending = pendingDualPanel
        pendingDualPanel = nil
        ExecuteWithDelay(100, function()
            activateDualPanel(context, pending)
        end)
    end
end

local function consumeButton(buttonParameter)
    pcall(function() buttonParameter:set(0) end)
end

local function focusMenuIcon(context, icon, index)
    if context == nil or not isValidObject(icon) then return end
    mainMenuFocusIndexes[context.listKey] = index
    -- CurrentIndex addresses only the active authored rows. Equipment itself
    -- begins at nativeCount, even if a hidden compiled Item_6 still exists.
    if type(index) == "number" and index >= 0 and index < context.nativeCount then
        pcall(function() context.mainList.CurrentIndex = index end)
    end
    pcall(function() icon["Set Current Animation"](icon) end)
    if index == context.equipmentIndex then
        pcall(function() applyEquipmentIconTexture(icon) end)
    end
    pcall(function() icon:BP_SetInputWidgetFocus() end)
    pcall(function() icon:SetFocus() end)
    pcall(function() icon:SetKeyboardFocus() end)
    local controller = resolveLocalController()
    if isValidObject(controller) then
        pcall(function() icon:SetUserFocus(controller) end)
    end
end

--========================================================--
--                 SHARED RAIL COEXISTENCE                --
--========================================================--
-- Another mod can extend the same rail by appending its own wrapper panel to
-- the VerticalBox this mod injects into (ModMenu's "Mods" row does exactly
-- that). Equipment therefore cannot assume it is the final row: it has to
-- discover what sits below it and hand focus over instead of wrapping to the
-- top. With no other mod present every path below collapses to the original
-- behavior.
local RAIL_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C"

local function iconInsideWrapper(panel)
    if not isValidObject(panel) then return nil end
    local count = nil
    pcall(function() count = panel:GetChildrenCount() end)
    if type(count) ~= "number" then return nil end
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = panel:GetChildAt(index) end)
        if isValidObject(child) and contains(objectName(child), RAIL_ICON_FRAGMENT) then
            return child
        end
    end
    return nil
end

-- The injected rows sitting after Equipment, in visual order.
local function railRowsBelowEquipment(context)
    local rows = {}
    if context == nil then return rows end
    local parent = context.equipmentWrapperParent
    local wrapper = context.equipmentWrapperPanel
    if not isValidObject(parent) or not isValidObject(wrapper) then return rows end

    local count = nil
    pcall(function() count = parent:GetChildrenCount() end)
    if type(count) ~= "number" then return rows end

    local wrapperKey = objectName(wrapper)
    local passedEquipment = false
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = parent:GetChildAt(index) end)
        if isValidObject(child) then
            if objectName(child) == wrapperKey then
                passedEquipment = true
            elseif passedEquipment then
                local icon = iconInsideWrapper(child)
                if icon ~= nil then rows[#rows + 1] = { panel = child, icon = icon } end
            end
        end
    end
    return rows
end

-- True when the widget belongs to another mod's row, which means this mod must
-- leave its focus alone rather than treating it as a stale native row.
local function isForeignRailIcon(context, widget)
    if context == nil or not isValidObject(widget) then return false end
    if isValidObject(context.equipmentIcon)
        and objectName(widget) == objectName(context.equipmentIcon) then
        return false
    end
    local widgetKey = objectName(widget)
    for _, row in ipairs(railRowsBelowEquipment(context)) do
        if objectName(row.icon) == widgetKey then return true end
    end
    return false
end

local function focusRailRow(context, row, index)
    if context == nil or row == nil or not isValidObject(row.icon) then return false end

    -- Every authored row has to be reset, not just Equipment. Handing focus to a
    -- row that lives outside the native animation array leaves whichever native
    -- row was selected still lit, so two entries appear selected at once.
    for nativeIndex = 0, context.nativeCount - 1 do
        pcall(function()
            context.mainList["Item_" .. tostring(nativeIndex)]:SetDefaultAnimation()
        end)
    end

    -- Equipment sits outside that array too, so nothing else will clear its
    -- selection art either.
    pcall(function() context.equipmentIcon:SetDefaultAnimation() end)
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
    focusMenuIcon(context, row.icon, index)
    return true
end

local function focusEquipment(context)
    if context == nil or not isValidObject(context.equipmentIcon) then return end
    -- Equipment is outside the native animation array. Selecting it
    -- therefore cannot make the list deselect its current authored row. Reset
    -- all active rows so mouse selection works from any source, not only the two
    -- controller wrap boundaries (Pouch and the current final native row).
    for index = 0, context.nativeCount - 1 do
        pcall(function()
            context.mainList["Item_" .. tostring(index)]:SetDefaultAnimation()
        end)
    end
    focusMenuIcon(context, context.equipmentIcon, context.equipmentIndex)
    local _, _, textLibrary = resolveLibraries()
    if isValidObject(textLibrary) then
        pcall(function()
            local equipmentText = textLibrary:Conv_StringToText("Equipment")
            context.equipmentIcon:SetMenuName(equipmentText)
            context.equipmentIcon.MenuName:SetText(equipmentText)
        end)
    end
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
end

local function leaveEquipment(context, destination, destinationIndex)
    if context == nil then return end
    pcall(function() context.equipmentIcon:SetDefaultAnimation() end)
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
    focusMenuIcon(context, destination, destinationIndex)
end

local function clearEquipmentSelectionVisual(context)
    if context == nil or not isValidObject(context.equipmentIcon) then return end
    pcall(function() context.equipmentIcon:SetDefaultAnimation() end)
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
end

-- Down from the last native row always enters Equipment, because Equipment is
-- the first injected row. Up from the first native row has to enter whatever is
-- visually last on the rail, which is Equipment only while no other mod has
-- appended a row below it.
local function focusRailBoundary(context, goingUp)
    if context == nil then return end
    if goingUp then
        local rows = railRowsBelowEquipment(context)
        local last = rows[#rows]
        if last ~= nil
            and focusRailRow(context, last, context.equipmentIndex + #rows) then
            return
        end
    end
    focusEquipment(context)
end

local function equipmentContextFor(widget)
    if not isValidObject(widget) then return nil end
    return equipmentContexts[objectName(widget)]
end

setEquipmentEntryVisibility = function(context, visibility)
    if context == nil or not isValidObject(context.equipmentIcon) then return end
    local wrapper = context.equipmentWrapperPanel
    if visibility == VISIBLE and not context.equipmentWrapperAttached
        and isValidObject(wrapper)
        and isValidObject(context.equipmentWrapperParent) then
            local wrapperSlot = nil
            local attached = pcall(function()
                wrapperSlot = context.equipmentWrapperParent:AddChildToVerticalBox(wrapper)
            end)
            context.equipmentWrapperAttached = attached and isValidObject(wrapperSlot)
    end

    -- MenuIcon7 is an authored three-layer row: Scanline7 supplies the
    -- connector, Around_Menu7 supplies the square frame, and the injected icon
    -- supplies the circle/art. The native submenu animation addresses those
    -- children independently, so control every layer rather than only their
    -- CanvasPanel parent. Render opacity is a second guard against an animation
    -- rewriting visibility later in the same transition.
    local widgets = { wrapper, context.equipmentIcon }
    local donor = context.equipmentWrapperDonor
    if isValidObject(donor) then
        local function includeDonorWidget(name)
            local widget = nil
            pcall(function() widget = donor[name] end)
            if isValidObject(widget) then table.insert(widgets, widget) end
        end
        includeDonorWidget("MenuIcon7")
        includeDonorWidget("Scanline7")
        includeDonorWidget("ScanlineImage7")
        includeDonorWidget("Around_Menu7")
    end
    local opacity = visibility == VISIBLE and 1.0 or 0.0
    for _, widget in ipairs(widgets) do
        if isValidObject(widget) then
            pcall(function() widget:SetVisibility(visibility) end)
            pcall(function() widget:SetRenderOpacity(opacity) end)
        end
    end
    if visibility == VISIBLE and isValidObject(wrapper) then
        pcall(function() wrapper:ForceLayoutPrepass() end)
    end
end

suppressInactiveTrailingNativeRows = function(context)
    if context == nil then return end
    for _, row in ipairs(context.inactiveTrailingNativeRows or {}) do
        local widgets = { row.panel, row.item }
        for _, widget in ipairs(row.widgets or {}) do
            table.insert(widgets, widget)
        end
        for _, widget in ipairs(widgets) do
            if isValidObject(widget) then
                pcall(function() widget:SetVisibility(COLLAPSED) end)
                pcall(function() widget:SetRenderOpacity(0.0) end)
            end
        end
    end
end

setNativeMenuPanelsVisibility = function(context, visibility)
    if context == nil then return end
    local opacity = visibility == VISIBLE and 1.0 or 0.0
    for _, panel in ipairs(context.nativePanels or {}) do
        if isValidObject(panel) then
            pcall(function() panel:SetVisibility(visibility) end)
            pcall(function() panel:SetRenderOpacity(opacity) end)
        end
    end
    -- NumContent remains stale after the beta-only Logout row disappears.
    -- Never let native open/Back animations repaint that inactive authored row.
    suppressInactiveTrailingNativeRows(context)
end

restoreEquipmentEntryPresentation = function(context)
    if context == nil or not isValidObject(context.equipmentIcon) then return end
    pcall(function() context.equipmentIcon["Set Current Animation"](context.equipmentIcon) end)
    local _, _, textLibrary = resolveLibraries()
    if isValidObject(textLibrary) then
        pcall(function()
            local equipmentText = textLibrary:Conv_StringToText("Equipment")
            context.equipmentIcon:SetMenuName(equipmentText)
            context.equipmentIcon.MenuName:SetText(equipmentText)
        end)
    end
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
end

local function rearmEquipmentEntry(context, emitLog)
    if context == nil or not isValidObject(context.mainMenu)
        or not isValidObject(context.mainList)
        or not isValidObject(context.equipmentIcon) then
        return false
    end

    local rearmed, rearmError = pcall(function()
        local icon = context.equipmentIcon
        icon:SetItemIndex(context.equipmentIndex)
        icon:SetOwnerInputWidget(context.mainList)
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        setEquipmentEntryVisibility(context, VISIBLE)
        suppressInactiveTrailingNativeRows(context)
        if not context.equipmentWrapperAttached then
            error("Equipment wrapper could not be reattached")
        end
        context.mainMenu:SetInteraction(true)
        if not applyEquipmentIconTexture(icon) then
            error("dedicated Equipment icon texture is unavailable")
        end
    end)
    if not rearmed then
        if emitLog then
            log("could not rearm Equipment navigation: " .. tostring(rearmError))
        end
        return false
    end

    local currentIndex = 0
    pcall(function() currentIndex = context.mainList.CurrentIndex end)
    restoreEquipmentEntryPresentation(context)
    if currentIndex ~= context.equipmentIndex then
        -- Rearming input must not visually select Equipment. Native submenus
        -- return focus to their own icon (Pouch, Skills, etc.).
        pcall(function() context.equipmentIcon:SetDefaultAnimation() end)
    end
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
    suppressInactiveTrailingNativeRows(context)
    activeEquipmentContext = context
    equipmentContexts[objectName(context.equipmentIcon)] = context
    pendingFocusRedirects[context.listKey] = nil
    mainMenuFocusIndexes[context.listKey] = currentIndex
    if emitLog then
        log("rearmed Equipment navigation after native submenu return; current="
            .. tostring(currentIndex))
    end
    return true
end

local function suppressNonSelectedNativeRows(context, selectedIndex)
    if context == nil then return end
    for arrayIndex, panel in ipairs(context.nativePanels or {}) do
        local nativeIndex = arrayIndex - 1
        if nativeIndex ~= selectedIndex and isValidObject(panel) then
            pcall(function() panel:SetVisibility(COLLAPSED) end)
            pcall(function() panel:SetRenderOpacity(0.0) end)
        end
    end
    suppressInactiveTrailingNativeRows(context)
end

local function prepareMainMenuRailForSubmenu(mainMenu, selectedIndex)
    local context = activeEquipmentContext
    if context == nil or context.mainMenuKey ~= objectName(mainMenu) then return end

    if selectedIndex == nil then
        selectedIndex = context.activeNativeSubmenuIndex
    end
    if selectedIndex == nil then
        pcall(function() selectedIndex = context.mainList.CurrentIndex end)
    end
    if selectedIndex == nil or selectedIndex < 0
        or selectedIndex >= context.equipmentIndex then
        selectedIndex = 0
    end
    context.activeNativeSubmenuIndex = selectedIndex

    if mainMenuSubmenuActive and not equipmentSubmenuOpen then
        setEquipmentEntryVisibility(context, COLLAPSED)
        suppressNonSelectedNativeRows(context, selectedIndex)
        return
    end

    mainMenuSubmenuActive = true
    pendingFocusRedirects[context.listKey] = nil
    submenuTransitionSerial = submenuTransitionSerial + 1
    local serial = submenuTransitionSerial
    -- Native submenus animate their own selected icon into the rail. Keep the
    -- injected Equipment entry out of that layout until Back completes.
    equipmentSubmenuOpen = false
    setEquipmentEntryVisibility(context, COLLAPSED)
    suppressNonSelectedNativeRows(context, selectedIndex)


    -- Native item widgets and the list animation both repaint the rail. Keep
    -- suppressing the injected row for the entire submenu lifetime rather than
    -- assuming the transition has finished after a fixed delay.
    local function suppressInjectedRow()
        ExecuteInGameThread(function()
            if not mainMenuSubmenuActive
                or submenuTransitionSerial ~= serial then
                return
            end
            setEquipmentEntryVisibility(context, COLLAPSED)
            suppressNonSelectedNativeRows(context, selectedIndex)
            ExecuteWithDelay(100, suppressInjectedRow)
        end)
    end
    ExecuteWithDelay(25, suppressInjectedRow)
    log("native submenu rail suppression armed; selected="
        .. tostring(selectedIndex))
end

local function beginMainMenuReturn(mainMenu)
    local context = activeEquipmentContext
    if context == nil or context.mainMenuKey ~= objectName(mainMenu) then return nil end

    local returningFromEquipment = equipmentSubmenuOpen
    submenuTransitionSerial = submenuTransitionSerial + 1
    local serial = submenuTransitionSerial

    -- Restore the authored panels before the native EndSubMenu function starts
    -- its Back animation. The custom icon returns after that animation, avoiding
    -- a one-frame overlap with the collapsed rail.
    setNativeMenuPanelsVisibility(context, VISIBLE)
    setEquipmentEntryVisibility(context, COLLAPSED)
    return {
        context = context,
        returningFromEquipment = returningFromEquipment,
        serial = serial,
    }
end

local function finishMainMenuReturn(returnState)
    if returnState == nil then return end
    ExecuteWithDelay(250, function()
        ExecuteInGameThread(function()
            if submenuTransitionSerial ~= returnState.serial then return end
            local context = returnState.context
            if context == nil or not isValidObject(context.mainMenu) then return end

            equipmentSubmenuOpen = false
            mainMenuSubmenuActive = false
            context.activeNativeSubmenuIndex = nil
            rearmEquipmentEntry(context, true)
            if returnState.returningFromEquipment then
                focusEquipment(context)
            end

            -- Native return animations can perform one final owner/input reset
            -- after EndSubMenu completes. Reapply the bridge once that settles.
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function()
                    if not mainMenuSubmenuActive and activeEquipmentContext == context then
                        rearmEquipmentEntry(context, false)
                    end
                end)
            end)
        end)
    end)
end

local function recoverEquipmentAfterNativeBack(context)
    if context == nil or nativeBackRecoveryBusy then return end
    nativeBackRecoveryBusy = true
    log("observed native submenu Back; Equipment recovery armed")

    local function recover(emitLog)
        if equipmentSubmenuOpen or activeEquipmentContext ~= context
            or not isValidObject(context.mainMenu) then
            return
        end
        mainMenuSubmenuActive = false
        context.activeNativeSubmenuIndex = nil
        pendingFocusRedirects[context.listKey] = nil
        setNativeMenuPanelsVisibility(context, VISIBLE)
        rearmEquipmentEntry(context, emitLog)
    end

    ExecuteWithDelay(700, function()
        ExecuteInGameThread(function() recover(true) end)
    end)
    ExecuteWithDelay(1400, function()
        ExecuteInGameThread(function()
            recover(false)
            nativeBackRecoveryBusy = false
        end)
    end)
end

local function closeMainMenuFromEquipment()
    if menuCloseBusy then return end
    menuCloseBusy = true

    ExecuteInGameThread(function()
        local controller = resolveLocalController()
        local _, rodLibrary = resolveLibraries()
        if not isValidObject(controller) or not isValidObject(rodLibrary) then
            log("cannot close start menu: UI context is unavailable")
            menuCloseBusy = false
            return
        end

        local ended, endError = pcall(function()
            rodLibrary:EndMenu(controller)
        end)
        if not ended then
            log("could not close start menu: " .. tostring(endError))
            menuCloseBusy = false
        end
    end)
end

local function handleBridgedButton(widgetParameter, buttonParameter)
    local widget = unwrap(widgetParameter)
    local button = unwrap(buttonParameter)
    if not isValidObject(widget) then return end

    -- Arm suppression at the native item itself. This precedes the main-menu
    -- OpenSelectMenu call and covers controller paths that do not consistently
    -- reach that higher-level hook before the authored animation starts.
    if button == ACCEPT_BUTTON and activeEquipmentContext ~= nil
        and not mainMenuSubmenuActive then
        local nativeIndex = nil
        pcall(function() nativeIndex = widget:GetItemIndex() end)
        if nativeIndex ~= nil and nativeIndex >= 0
            and nativeIndex < activeEquipmentContext.equipmentIndex
            and string.find(objectName(widget),
                "WBP_Console_MainMenu_List_C", 1, true) then
            prepareMainMenuRailForSubmenu(
                activeEquipmentContext.mainMenu, nativeIndex)
        end
    end

    if equipmentSubmenuOpen and button == BACK_BUTTON then
        local widgetName = objectName(widget)
        if string.find(widgetName,
            "WBP_Console_ChestMenu_Equipment_EquipmentSetting_C", 1, true) then
            log("captured root Equipment Back input from " .. widgetName)
            beginEquipmentReturnToMain()
        else
            log("leaving nested Equipment picker through native Back: " .. widgetName)
        end
        -- Do not consume Back. The native Equipment widget still needs to run
        -- its own authored transition in both the root and nested cases.
        return
    end

    if mainMenuSubmenuActive and button == BACK_BUTTON then
        recoverEquipmentAfterNativeBack(activeEquipmentContext)
        -- Do not consume this input: the native submenu must still perform its
        -- own authored Back transition before we restore the injected entry.
        return
    end

    local context = equipmentContextFor(widget)
    if context ~= nil then
        if button == ACCEPT_BUTTON then
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, selectInjectedEquipment)
        elseif button == BACK_BUTTON then
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, closeMainMenuFromEquipment)
        elseif button == DPAD_UP or button == LSTICK_UP then
            consumeButton(buttonParameter)
            leaveEquipment(context, context.lastItem, context.equipmentIndex - 1)
        elseif button == DPAD_DOWN or button == LSTICK_DOWN then
            consumeButton(buttonParameter)
            -- Only wrap to the top once nothing else is below Equipment.
            local rowsBelow = railRowsBelowEquipment(context)
            if rowsBelow[1] == nil
                or not focusRailRow(context, rowsBelow[1], context.equipmentIndex + 1) then
                leaveEquipment(context, context.firstItem, 0)
            end
        end
        return
    end

    local down = button == DPAD_DOWN or button == LSTICK_DOWN
    local up = button == DPAD_UP or button == LSTICK_UP
    if not down and not up then return end
    local index = nil
    pcall(function() index = widget:GetItemIndex() end)
    local widgetName = objectName(widget)
    if activeEquipmentContext ~= nil
        and ((down and index == activeEquipmentContext.equipmentIndex - 1)
            or (up and index == 0))
        and string.find(widgetName, "WBP_Console_MainMenu_List_C", 1, true) then
        consumeButton(buttonParameter)
        focusRailBoundary(activeEquipmentContext, up)
    end
end

local function restoreNativeStartMenuAfterEquipment()
    local controller = resolveLocalController()
    if not isValidObject(controller) then
        equipmentReturnBusy = false
        log("cannot restore start menu after Equipment: controller is unavailable")
        return
    end

    local reopened, reopenError = pcall(function()
        controller:DebugOpenMainMenu()
    end)
    if not reopened then
        equipmentReturnBusy = false
        log("could not reopen native start menu after Equipment: " .. tostring(reopenError))
        return
    end

    ExecuteWithDelay(300, function()
        ExecuteInGameThread(function()
            local context = activeEquipmentContext
            if context == nil or not isValidObject(context.mainMenu) then
                equipmentReturnBusy = false
                log("native start-menu context was unavailable after Equipment closed")
                return
            end

            local component = findWidgetComponentFor(context.mainMenu)
            local actor = nil
            if isValidObject(component) then
                pcall(function() actor = component:GetOwner() end)
            end
            local restored, restoreError = pcall(function()
                if not isValidObject(component) then
                    error("native start-menu component is unavailable")
                end
                component:SetWidget(context.mainMenu)
                if isValidObject(actor) then actor:SetActorHiddenInGame(false) end
                component:SetActive(true, true)
                component:SetComponentTickEnabled(true)
                component:SetHiddenInGame(false, true)
                component:SetVisibility(true, true)
                component:SetTickWhenOffscreen(true)
                context.mainMenu:SetVisibility(VISIBLE)
                context.mainMenu:SetRenderOpacity(1.0)
                context.mainMenu:SetInteraction(true)
                setNativeMenuPanelsVisibility(context, VISIBLE)
                if not rearmEquipmentEntry(context, false) then
                    error("Equipment navigation could not be restored")
                end
                focusEquipment(context)
                component:RequestRenderUpdate()
                component:RequestRedraw()
            end)
            equipmentReturnBusy = false
            if restored then
                log("restored original interactive start menu after Equipment")
            else
                log("original start-menu restoration failed: " .. tostring(restoreError))
            end
        end)
    end)
end

beginEquipmentReturnToMain = function()
    if equipmentReturnBusy or not equipmentSubmenuOpen then return end
    equipmentReturnBusy = true
    equipmentSubmenuOpen = false
    mainMenuSubmenuActive = false
    if isValidObject(activeStatOverlay) then
        pcall(function() activeStatOverlay:RemoveFromParent() end)
    end
    activeStatOverlay = nil
    activeStatOverlayDonor = nil
    log("removed display-only stat overlay; waiting to restore native start menu")
    ExecuteWithDelay(900, function()
        ExecuteInGameThread(restoreNativeStartMenuAfterEquipment)
    end)
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

safeHook("/Script/ROD.RODWidgetBPFunctionLibrary:EndMenu",
    function()
        beginEquipmentReturnToMain()
    end)

safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OpenSelectMenu",
    function(self)
        prepareMainMenuRailForSubmenu(unwrap(self))
    end)

local pendingMainMenuReturns = {}
safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:EndSubMenu",
    function(self)
        local mainMenu = unwrap(self)
        pendingMainMenuReturns[objectName(mainMenu)] = beginMainMenuReturn(mainMenu)
    end,
    function(self)
        local mainMenu = unwrap(self)
        local key = objectName(mainMenu)
        local returnState = pendingMainMenuReturns[key]
        pendingMainMenuReturns[key] = nil
        finishMainMenuReturn(returnState)
    end)

-- The concrete Blueprint class is not loaded when UE4SS installs mods, so a
-- RegisterHook against one of its Blueprint events fails. Watch the native base
-- instead, then filter for the real start-menu instance as it is constructed.
local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject("/Script/ROD.RODConsoleMainMenuWidgetBase", function(object)
        if creatingStatOverlay then return end
        local mainMenu = unwrap(object)
        if not string.find(objectName(mainMenu), "WBP_Console_MainMenu_C", 1, true) then
            return
        end

        ExecuteWithDelay(100, function()
            ExecuteInGameThread(function()
                injectEquipmentEntry(mainMenu)
            end)
        end)
    end)
end)
if not notifyOk then
    log("main-menu object notification unavailable: " .. tostring(notifyError))
end

safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OnButtonDownMenuItemDelegate",
    function(_, widgetParameter, buttonParameter)
        local widget = unwrap(widgetParameter)
        local button = unwrap(buttonParameter)
        local index = nil
        if isValidObject(widget) then
            pcall(function() index = widget:GetItemIndex() end)
        end

        local context = activeEquipmentContext
        if context ~= nil and not mainMenuSubmenuActive and index ~= nil then
            local down = button == DPAD_DOWN or button == LSTICK_DOWN
            local up = button == DPAD_UP or button == LSTICK_UP
            if (down and index == context.equipmentIndex - 1)
                or (up and index == 0) then
                -- This delegate is the reliable boundary path in the six-row
                -- post-beta list; the native list still owns a hidden index 6.
                consumeButton(buttonParameter)
                focusRailBoundary(context, up)
                return
            end
        end

        if context ~= nil
            and index == context.equipmentIndex
            and button == ACCEPT_BUTTON then
            -- Consume this custom index so the native switch never sees it.
            pcall(function() buttonParameter:set(0) end)
            ExecuteWithDelay(0, selectInjectedEquipment)
        end
    end)

-- The native list's TArrays cannot be grown safely from UE4SS Lua. Bridge only
-- the boundary around the custom item and let the list handle its active rows.
safeHook("/Script/ROD.RODInputWidgetBase:OnInputButtonDown",
    function(_, widgetParameter, buttonParameter)
        handleBridgedButton(widgetParameter, buttonParameter)
    end)

safeHook("/Script/ROD.RODListWidgetBase:ButtonDownEvent",
    function(_, widgetParameter, buttonParameter)
        handleBridgedButton(widgetParameter, buttonParameter)
    end)

-- Main-menu direction input changes focus internally without passing through
-- ButtonDownEvent. Observe that actual focus change and replace only the
-- native final-item -> first-item wrap with final-item -> Equipment.
safeHook("/Script/ROD.RODListWidgetBase:FocusEvent",
    function(self, widgetParameter)
        local mainList = unwrap(self)
        local widget = unwrap(widgetParameter)
        local listKey = objectName(mainList)
        if mainMenuSubmenuActive then
            pendingFocusRedirects[listKey] = nil
            return
        end
        if not string.find(listKey, "WBP_Console_MainMenu_List_C", 1, true)
            or not isValidObject(widget) then
            return
        end

        local index = nil
        pcall(function() index = widget:GetItemIndex() end)
        if index == nil then return end

        local previousIndex = mainMenuFocusIndexes[listKey]
        mainMenuFocusIndexes[listKey] = index
        local context = activeEquipmentContext
        if context ~= nil and context.listKey ~= listKey then context = nil end
        local isInjectedEquipment = equipmentContextFor(widget) == context
        if context ~= nil and isInjectedEquipment then
            -- Another injected row may own the transition into Equipment, but
            -- Equipment remains the sole owner of its label, texture and
            -- selected animation. Reassert presentation without moving focus
            -- again, which avoids a cross-mod focus loop.
            restoreEquipmentEntryPresentation(context)
        end
        if context ~= nil
            and index >= 0 and index < context.equipmentIndex then
            -- Equipment lives outside the native list's animation
            -- array, so focusing a native row cannot deselect it automatically.
            clearEquipmentSelectionVisual(activeEquipmentContext)
        end
        local lastNativeIndex = context ~= nil and context.equipmentIndex - 1 or -1
        local wrappedDownFromLast =
            previousIndex == lastNativeIndex and index == 0
        local wrappedUpFromPouch =
            previousIndex == 0 and index == lastNativeIndex
        -- After Logout is removed visually, the compiled native list can still
        -- focus its now-hidden old index before wrapping. Treat any native focus
        -- at or beyond the live count as the Equipment boundary too.
        -- A row belonging to another mod also reports an index at or beyond
        -- Equipment's. Claiming it as a stale native row would yank focus back
        -- out of that mod's entry the moment it is selected.
        local enteredHiddenTrailingRow =
            context ~= nil and not isInjectedEquipment
                and index >= context.equipmentIndex
                and not isForeignRailIcon(context, widget)
        if (wrappedDownFromLast or wrappedUpFromPouch or enteredHiddenTrailingRow)
            and context ~= nil then
            -- Wrapping upwards off the first row must land on whatever is last
            -- on the rail; the other two paths always mean Equipment.
            pendingFocusRedirects[listKey] = wrappedUpFromPouch and "last" or "equipment"
        end
    end,
    function(self)
        local mainList = unwrap(self)
        local listKey = objectName(mainList)
        if mainMenuSubmenuActive then
            pendingFocusRedirects[listKey] = nil
            return
        end
        local redirect = pendingFocusRedirects[listKey]
        if redirect == nil then return end
        pendingFocusRedirects[listKey] = nil

        -- Run immediately after the native focus function, within the same
        -- frame, so Pouch never survives long enough to be rendered.
        if activeEquipmentContext ~= nil then
            focusRailBoundary(activeEquipmentContext, redirect == "last")
        end
    end)

safeHook("/Script/ROD.RODInputWidgetBase:ClickEventNotify",
    function(self, widgetParameter, buttonParameter, _)
        local widget = unwrap(widgetParameter)
        local context = equipmentContextFor(widget)
            or equipmentContextFor(unwrap(self))
        if context ~= nil then
            -- Mouse clicks use a different ButtonKind from controller Accept on
            -- some input configurations. ClickEventNotify is already a click-
            -- only path, so the custom row itself is the sufficient filter.
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, selectInjectedEquipment)
            log("Equipment click captured at input widget")
        end
    end)

-- SetOwnerInputWidget routes a row's mouse notification through its owning
-- list before the main-menu delegate. The injected row is intentionally absent
-- from the native arrays, so intercept it at this stage.
safeHook("/Script/ROD.RODListWidgetBase:ClickEvent",
    function(_, widgetParameter, buttonParameter, _)
        local widget = unwrap(widgetParameter)
        if equipmentContextFor(widget) ~= nil then
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, selectInjectedEquipment)
            log("Equipment click captured at owning list")
        end
    end)

-- Mouse selection reaches the main menu through this higher-level delegate on
-- the release click, bypassing the controller ButtonDown path used above.
safeHook("/Script/ROD.RODConsoleMainMenuWidgetBase:OnClickMenuItemDelegate",
    function(_, widgetParameter, buttonParameter)
        local widget = unwrap(widgetParameter)
        local context = equipmentContextFor(widget)
        if context ~= nil then
            -- This delegate is already mouse-click-specific. Its button value
            -- is not guaranteed to use the controller Accept code, so treating
            -- only value 1 as a click silently rejects LMB on some input modes.
            consumeButton(buttonParameter)
            ExecuteWithDelay(0, selectInjectedEquipment)
            log("mouse click requested Equipment")
            return
        end

        if activeEquipmentContext ~= nil and isValidObject(widget) then
            local nativeIndex = nil
            pcall(function() nativeIndex = widget:GetItemIndex() end)
            if nativeIndex ~= nil and nativeIndex >= 0
                and nativeIndex < activeEquipmentContext.equipmentIndex then
                clearEquipmentSelectionVisual(activeEquipmentContext)
                prepareMainMenuRailForSubmenu(
                    activeEquipmentContext.mainMenu, nativeIndex)
            end
        end
    end)

-- The native list registers mouse delegates for its authored rows only.
-- UE4SS's key hook still receives LMB while the world-space menu owns input, so
-- use the injected widget's live hover/geometry as its hit-test.
local function isMouseOverInjectedEquipment(context)
    if context == nil or not isValidObject(context.equipmentIcon) then
        return false, "no-icon"
    end

    local hovered = false
    pcall(function() hovered = context.equipmentIcon:GetIsMouseHover() end)
    if hovered then return true, "hover" end

    local slateLibrary = StaticFindObject(
        "/Script/UMG.Default__SlateBlueprintLibrary")
    if not isValidObject(slateLibrary) then return false, "no-slate" end

    local geometry = nil
    local mousePosition = nil
    local under = false
    local checked = pcall(function()
        geometry = context.equipmentIcon:GetCachedGeometry()
        mousePosition = context.equipmentIcon:GetScreenMousePosition()
        under = slateLibrary:IsUnderLocation(geometry, mousePosition)
    end)
    return checked and under == true, checked and "geometry" or "geometry-error"
end

local mouseBindOk, mouseBindError = pcall(function()
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        if transitionBusy or equipmentSubmenuOpen or mainMenuSubmenuActive then
            return
        end
        local context = activeEquipmentContext
        if context == nil or not isValidObject(context.mainMenu)
            or not isValidObject(context.equipmentIcon) then
            return
        end

        local hit, method = isMouseOverInjectedEquipment(context)
        if not hit then return end
        if mainMenuFocusIndexes[context.listKey] ~= context.equipmentIndex then
            -- Match the authored mouse behavior: the first click selects and
            -- reveals the row label; a second click confirms the selection.
            focusEquipment(context)
            log("LMB selected Equipment through " .. tostring(method))
            return
        end
        log("LMB confirmed Equipment through " .. tostring(method))
        ExecuteWithDelay(0, selectInjectedEquipment)
    end)
end)
if not mouseBindOk then
    log("could not register Equipment LMB bridge: " .. tostring(mouseBindError))
end

local function cleanupOrphanedStatOverlays()
    local ok, widgets = pcall(function() return FindAllOf("WBP_Console_MainMenu_C") end)
    if not ok or widgets == nil then return end
    local removed = 0
    for _, widget in ipairs(widgets) do
        if isValidObject(widget)
            and not isValidObject(dereferenceWeakObject(widget.ParentComponent))
            and not isValidObject(dereferenceWeakObject(widget.ParentActor)) then
            local inViewport = false
            pcall(function() inViewport = widget:IsInViewport() end)
            if inViewport then
                local didRemove = pcall(function() widget:RemoveFromParent() end)
                if didRemove then removed = removed + 1 end
            end
        end
    end
    if removed > 0 then
        log("removed " .. tostring(removed) .. " orphaned stat overlay(s) from an older build")
    end
end

ExecuteWithDelay(100, function()
    ExecuteInGameThread(cleanupOrphanedStatOverlays)
end)

-- Runtime settings. Injection happens as the start menu is constructed, so an
-- ENABLED change lands the next time the menu is opened rather than instantly.
do
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

    local bridge = loadModMenuBridge()
    if bridge ~= nil then
        bridge.attach({
            modName = "FieldEquipmentMod",
            scriptDir = SCRIPT_DIR,
            load = applyExternalConfig,
            log = function(message)
                print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
            end,
        })
    end
end

print(string.format("[%s] loaded %s\n", MOD_NAME, MOD_VERSION))
