-- FieldEquipPro v1.0
-- Add a native-styled Equipment entry to Echoes of Aincrad's start menu.
--
-- Selecting that entry opens the Equipment screen alone, with the character
-- revealed and the camera moved into the equip close-up, rather than beside a
-- copy of the start menu's stat panel. See OPENING EQUIPMENT below for what was
-- measured on this build.

local MOD_NAME = "FieldEquipPro"
local MOD_VERSION = "v1.0"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"
local EQUIPMENT_WIDGET_CLASS =
    "/Game/ROD/Widget/Console/ChestMenu/WBP_Console_ChestMenu_Equipment.WBP_Console_ChestMenu_Equipment_C"
local EQUIPMENT_ICON_ASSET =
    "/Game/ROD/Widget/Common/IconImage/ItemCategoryIconImage/T_ItemCategoryIcon_OneHandedSword"
local EQUIPMENT_ICON_TEXTURE = EQUIPMENT_ICON_ASSET .. ".T_ItemCategoryIcon_OneHandedSword"

-- EMenuKind::ChestEquipMenu. Stamped on the widget so the menu manager files it
-- as the chest equipment screen rather than as an anonymous debug menu.
local MENU_KIND_CHEST_EQUIP = 33
-- EActorMenuWidgetKind::ChestMenu, for the DebugOpen3DMenu probe only.
local ACTOR_MENU_KIND_CHEST = 4

-- The widget reaches the screen over a few frames; the close animation runs for
-- roughly a second before the manager settles.
local EQUIPMENT_MOUNT_CHECK_MS = 600
local EQUIPMENT_CLOSE_SETTLE_MS = 900
-- Applied after the rail is rebuilt, late enough that every other mod has had
-- its own construction notification and appended its row.
local EQUIPMENT_REFOCUS_DELAY_MS = 600

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
-- Set only once the native Equipment screen is confirmed on screen. The menu
-- manager fires EndMenu for the start menu it closes on the way there, and that
-- must not be mistaken for the player leaving Equipment.
local equipmentSessionArmed = false
local equipmentSessionWidgetKey = nil
local resumePlayableCameraPending = false
local mainMenuSubmenuActive = false
local submenuTransitionSerial = 0
local pendingEquipmentFocus = false
local equipmentReturnBusy = false
local equipmentIconTexture = nil
local nativeBackRecoveryBusy = false
local pendingMenuInjections = {}
local menuInjectionTimerScheduled = false
local scheduleMenuInjection

local MENU_INJECTION_DELAY_SEC = 0.10

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2

local setEquipmentEntryVisibility
local setNativeMenuPanelsVisibility
local suppressInactiveTrailingNativeRows
local restoreEquipmentEntryPresentation
local focusEquipment
local rearmEquipmentEntry
local isCanonicalMainMenuCandidate
local activeEquipmentContextIsAttached
local beginEquipmentReturnToMain
-- Assigned below, next to iconInsideWrapper. Used by the stale-row prune, which
-- is written earlier in this file but only ever runs at injection time.
local railRowLabel

-- The row's visible name, and the only thing that marks a rail row as this
-- mod's. It is written into the icon and read back when pruning, so the two must
-- stay the same string -- hence one constant rather than a literal at each site.
local EQUIPMENT_ROW_LABEL = "Equipment"

local SCRIPT_DIR = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local directory = source:match("^(.*[\\/])")
    if directory == nil then
        error("canonical FieldEquipPro Scripts directory is unavailable")
    end
    return directory
end)()

local CONFIG = {
    ENABLED = true,
    DEBUG_LOGS = true,
    SHOW_CHARACTER = true,
    CAMERA_HEIGHT = 50.0,
}

-- Bounds are the ones the Mods menu offers. Anything outside them is a typo in
-- config.lua, not a preference, so it fails loudly rather than being clamped.
local CONFIG_KEYS = {
    ENABLED = { type = "boolean" },
    DEBUG_LOGS = { type = "boolean" },
    SHOW_CHARACTER = { type = "boolean" },
    CAMERA_HEIGHT = { type = "number", min = -100.0, max = 200.0 },
}

local function log(message)
    if not CONFIG.DEBUG_LOGS then return end
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function applyExternalConfig(external)
    if type(external) ~= "table" then error("settings must be a table") end
    for key in pairs(external) do
        if CONFIG_KEYS[key] == nil then
            error("unknown setting: " .. tostring(key))
        end
    end
    for key, rule in pairs(CONFIG_KEYS) do
        local value = external[key]
        if type(value) ~= rule.type then
            error(key .. " must be " .. rule.type)
        end
        if rule.type == "number" then
            if value ~= value or value == math.huge or value == -math.huge then
                error(key .. " must be finite")
            end
            if value < rule.min or value > rule.max then
                error(string.format("%s must be between %.1f and %.1f",
                    key, rule.min, rule.max))
            end
        end
    end
    for key in pairs(CONFIG_KEYS) do
        CONFIG[key] = external[key]
    end
end

local MOD_MENU_BRIDGE = (function()
    local path = SCRIPT_DIR .. "standalone/ModMenuBridge.lua"
    local ok, bridge = pcall(function() return dofile(path) end)
    if not ok then
        error("canonical ModMenuBridge load failed: " .. tostring(bridge))
    end
    if type(bridge) ~= "table" then
        error("canonical ModMenuBridge did not return a table")
    end
    return bridge
end)()

do
    local settings, _, info = MOD_MENU_BRIDGE.readSettings(MOD_NAME, SCRIPT_DIR)
    if settings == nil then
        error("canonical settings load failed: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    applyExternalConfig(settings)
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

local EQUIPMENT_CLASS_FRAGMENT = "WBP_Console_ChestMenu_Equipment_C"

local function contains(value, fragment)
    return string.find(tostring(value or ""), fragment, 1, true) ~= nil
end

-- The Equipment screen counts as open only when the game has mounted it on a
-- visible widget component, which is what DebugOpen3DMenu's menu actor does.
-- The chest menu actor is pooled, so its component can still be holding the
-- widget from an earlier visit, DebugOpenMenu can put the widget straight in the
-- viewport with no component at all, and a widget the manager has finished with
-- lingers until collection. So this reports which of the three it found rather
-- than judging, and each caller applies its own bar:
--
--   "component"/"viewport" -> presented, this is a screen the player can see
--   "detached"             -> the object exists but is on nothing
--
-- Opening only needs the object to exist; deciding the player is still inside
-- Equipment needs it to be presented, or a leftover would trap them there.
local function findLiveEquipmentWidget()
    local ok, widgets = pcall(function()
        return FindAllOf(EQUIPMENT_CLASS_FRAGMENT)
    end)
    if not ok or widgets == nil then return nil, nil, nil end

    local viewportWidget = nil
    local detachedWidget = nil
    for _, candidate in ipairs(widgets) do
        if isValidObject(candidate) then
            local component = dereferenceWeakObject(candidate.ParentComponent)
            local visible = false
            if isValidObject(component) then
                pcall(function() visible = component:IsVisible() end)
            end
            if visible then
                local owner = nil
                pcall(function() owner = component:GetOwner() end)
                return candidate, "component", owner
            end

            if viewportWidget == nil then
                local inViewport = false
                pcall(function() inViewport = candidate:IsInViewport() end)
                if inViewport then viewportWidget = candidate end
            end
            if detachedWidget == nil then detachedWidget = candidate end
        end
    end
    if viewportWidget ~= nil then return viewportWidget, "viewport", nil end
    if detachedWidget ~= nil then return detachedWidget, "detached", nil end
    return nil, nil, nil
end

-- True only for a widget the player can actually see.
local function equipmentScreenIsPresented()
    local widget, presentation = findLiveEquipmentWidget()
    return isValidObject(widget)
        and (presentation == "component" or presentation == "viewport")
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

local function applyEquipmentIconTexture(icon, mainList)
    if not isValidObject(icon) or not isValidObject(icon.IconImage) then return false end

    -- Item_2 on WBP_Console_MainMenu_List_C is the authentic CHEST (Baú) icon
    if isValidObject(mainList) then
        local donorItem = mainList.Item_2 or mainList.Item_1
        if isValidObject(donorItem) and isValidObject(donorItem.IconImage) then
            local copied = false
            pcall(function()
                if donorItem.IconImage.Brush ~= nil then
                    icon.IconImage:SetBrush(donorItem.IconImage.Brush)
                    copied = true
                end
            end)
            if copied then return true end
        end
    end

    pcall(function()
        if type(icon.SetIconImage) == "function" then
            icon:SetIconImage(2)
        end
    end)
    return true
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

--========================================================--
--                   OPENING EQUIPMENT                    --
--========================================================--
-- Two things have to happen for this screen to look like the one a chest gives
-- you: the Equipment widget has to be on screen, and the camera has to be moved
-- to frame the character.
--
-- The widget half is settled. RODWidgetBPFunctionLibrary's DebugOpenMenu +
-- OpenMenu pair is the only path measured to work on this build: it creates the
-- widget, registers it with the menu manager and puts it up. The controller's
-- own DebugOpen3DMenu(ChestMenu, ChestEquipMenu) reads like the better answer —
-- it would bring the menu actor and its authored open flow with it — but it was
-- tried on this build and returns without doing anything at all: no Lua error,
-- no widget, no visible change. It is present in reflection and inert in the
-- shipping build, so it is not usable from here. `fieldequip probe` re-measures
-- that if a patch ever changes it.
--
-- Showing the character took three things, and each was found by measuring what
-- the previous attempt actually put on screen:
--
--   the hero -- the start menu hides the character, and it does it through the
--              game's keyed hide system, not a plain flag. ARODCharacterBase
--              carries HiddenInGameKeys, a TArray<FName>, and
--              SetAllActorHiddenInGame(bHidden, Key) adds or removes one key.
--              The actor stays hidden while any key remains, so any number of
--              systems can ask for it independently and none of them can undo
--              another request by accident. Calling the menu's own
--              OnMainMenuCharacterHidden(false) did not clear it, which is why
--              the screen came back with the camera in the right place and
--              nobody standing in it. Every key present is removed on the way
--              in and put back on the way out.
--   the view target -- ARODInGamePlayerController:OnMainMenuOpened receives the
--              level-sequence ACameraActor the start menu frames itself with, so
--              the view can belong to something other than the hero. Measured on
--              this build it does not: by the time Equipment is up the view is
--              already back on the hero. The handover stays because it is cheap,
--              it is symmetric, and it says so in the log when it fires.
--   framing  -- RODMenuWidgetBase carries this on the widget itself.
--              IsOpenCameraEnable gates it, OpenForcedCameraSettings holds it,
--              ProcessForcedCameraValues applies it. Every parameter is relative
--              to the player's camera boom (FOV, boom length, socket/target
--              offset, relative rotator), which is why the view target has to be
--              the hero before this runs.
--
-- All three are gated on SHOW_CHARACTER together, because they are one feature.
-- Any one alone leaves the screen worse than not touching the camera at all.
local previousViewTarget = nil
local suppressedHiddenKeys = {}
local originalCameraState = nil

local function describeCameraState(widget)
    local enabled = nil
    pcall(function() enabled = widget.IsOpenCameraEnable end)
    return tostring(enabled)
end

local function resolveHero()
    local hero = FindFirstOf("RODWorldHeroCharacter")
    if isValidObject(hero) then return hero end
    return nil
end

-- Returns the keys as plain strings. The FName objects inside the array must not
-- outlive the array being mutated, and strings are what the log wants anyway.
local function readHiddenKeys(hero)
    local keys = {}
    if not isValidObject(hero) then return keys end
    pcall(function()
        hero.HiddenInGameKeys:ForEach(function(_, element)
            local key = unwrap(element)
            local name = nil
            pcall(function() name = key:ToString() end)
            if type(name) == "string" and name ~= "" then
                keys[#keys + 1] = name
            end
        end)
    end)
    return keys
end

local function describeKeys(keys)
    if #keys == 0 then return "none" end
    return table.concat(keys, ", ")
end

-- Nothing here is allowed to leave the player invisible, so failures are logged
-- rather than swallowed.
local function revealHero(hero)
    suppressedHiddenKeys = readHiddenKeys(hero)
    log("hero hide keys on entry: " .. describeKeys(suppressedHiddenKeys))
    for _, key in ipairs(suppressedHiddenKeys) do
        local cleared, clearError = pcall(function()
            hero:SetAllActorHiddenInGame(false, FName(key))
        end)
        if not cleared then
            log("could not clear hero hide key " .. key .. ": " .. tostring(clearError))
        end
    end

    local remaining = readHiddenKeys(hero)
    local hidden = nil
    pcall(function() hidden = hero:IsHidden() end)
    log("hero after reveal: hidden=" .. tostring(hidden)
        .. " remaining keys=" .. describeKeys(remaining))
end

local function restoreHeroHide(hero)
    for _, key in ipairs(suppressedHiddenKeys) do
        pcall(function() hero:SetAllActorHiddenInGame(true, FName(key)) end)
    end
    if #suppressedHiddenKeys > 0 then
        log("restored hero hide keys: " .. describeKeys(suppressedHiddenKeys))
    end
    suppressedHiddenKeys = {}
end

-- CAMERA_HEIGHT raises the boom's origin, which lowers the character in frame
-- and shows more above them. Moving CameraRoot (USceneComponent) adjusts the
-- base transform of the camera rig directly without being overwritten by native ticks.
local function captureOriginalCameraState(hero)
    if not isValidObject(hero) then
        return false, "hero is unavailable"
    end

    local rootLocation = nil
    local rootRotation = nil
    local targetOffset = nil
    local socketOffset = nil
    local targetArmLength = nil
    local boomRotation = nil

    pcall(function()
        local root = hero.CameraRoot
        if isValidObject(root) then
            local relLoc = root.RelativeLocation
            rootLocation = { X = relLoc.X, Y = relLoc.Y, Z = relLoc.Z }
            local rotation = root.RelativeRotation
            rootRotation = {
                Pitch = rotation.Pitch,
                Yaw = rotation.Yaw,
                Roll = rotation.Roll,
            }
        end
    end)

    pcall(function()
        local boom = hero.CameraBoom
        if isValidObject(boom) then
            local target = boom.TargetOffset
            targetOffset = { X = target.X, Y = target.Y, Z = target.Z }
            local socket = boom.SocketOffset
            socketOffset = { X = socket.X, Y = socket.Y, Z = socket.Z }
            targetArmLength = boom.TargetArmLength
            local rotation = boom.RelativeRotation
            boomRotation = {
                Pitch = rotation.Pitch,
                Yaw = rotation.Yaw,
                Roll = rotation.Roll,
            }
        end
    end)

    if rootLocation == nil or rootRotation == nil
        or targetOffset == nil or socketOffset == nil
        or targetArmLength == nil or boomRotation == nil then
        originalCameraState = nil
        return false, "camera components are unavailable"
    end

    originalCameraState = {
        rootLocation = rootLocation,
        rootRotation = rootRotation,
        targetOffset = targetOffset,
        socketOffset = socketOffset,
        targetArmLength = targetArmLength,
        boomRotation = boomRotation,
    }
    return true, nil
end

local function raiseEquipmentCamera(hero)
    if not isValidObject(hero) then return end

    pcall(function()
        local root = hero.CameraRoot
        if isValidObject(root) then
            local relLoc = root.RelativeLocation
            relLoc.Z = relLoc.Z + CONFIG.CAMERA_HEIGHT
            root.RelativeLocation = relLoc
        end
    end)

    pcall(function()
        local boom = hero.CameraBoom
        if isValidObject(boom) then
            local target = boom.TargetOffset
            local socket = boom.SocketOffset
            target.Z = target.Z + CONFIG.CAMERA_HEIGHT
            socket.Z = socket.Z + CONFIG.CAMERA_HEIGHT
            boom.TargetOffset = target
            boom.SocketOffset = socket
        end
    end)
end

local function restoreEquipmentCamera(hero)
    local state = originalCameraState
    if isValidObject(hero) and state ~= nil then
        local stopped, stopError = pcall(function()
            hero:StopCameraAnimation()
        end)
        if not stopped then
            log("could not stop the Equipment camera animation: "
                .. tostring(stopError))
        end
        pcall(function()
            local root = hero.CameraRoot
            if isValidObject(root) then
                local relLoc = root.RelativeLocation
                relLoc.X = state.rootLocation.X
                relLoc.Y = state.rootLocation.Y
                relLoc.Z = state.rootLocation.Z
                root.RelativeLocation = relLoc
                local rotation = root.RelativeRotation
                rotation.Pitch = state.rootRotation.Pitch
                rotation.Yaw = state.rootRotation.Yaw
                rotation.Roll = state.rootRotation.Roll
                root.RelativeRotation = rotation
            end
        end)
        pcall(function()
            local boom = hero.CameraBoom
            if isValidObject(boom) then
                boom.TargetArmLength = state.targetArmLength
                local rotation = boom.RelativeRotation
                rotation.Pitch = state.boomRotation.Pitch
                rotation.Yaw = state.boomRotation.Yaw
                rotation.Roll = state.boomRotation.Roll
                boom.RelativeRotation = rotation
                local target = boom.TargetOffset
                target.X = state.targetOffset.X
                target.Y = state.targetOffset.Y
                target.Z = state.targetOffset.Z
                boom.TargetOffset = target
                local socket = boom.SocketOffset
                socket.X = state.socketOffset.X
                socket.Y = state.socketOffset.Y
                socket.Z = state.socketOffset.Z
                boom.SocketOffset = socket
            end
        end)
        local updated, updateError = pcall(function()
            local boom = hero.CameraBoom
            if isValidObject(boom) then
                boom:BP_UpdateDesiredArmLocation(0.016)
            end
        end)
        if not updated then
            log("could not refresh the restored camera transform: "
                .. tostring(updateError))
        end
    end
    originalCameraState = nil
end

local function resumePlayableCamera(hero)
    if not isValidObject(hero) then return end

    local cameraProcess = nil
    local readOk, readError = pcall(function()
        cameraProcess = hero.CameraAdjustComponent
    end)
    if not readOk or not isValidObject(cameraProcess) then
        log("could not resume playable camera follow: " .. tostring(readError))
        return
    end

    local resumed, resumeError = pcall(function()
        hero:StopCameraAnimation()
        cameraProcess:EnableCameraFollow()
        cameraProcess:OnEnablePlayableFollowCamera()
    end)
    if not resumed then
        log("could not resume playable camera follow: "
            .. tostring(resumeError))
        return
    end

    pcall(function()
        local boom = hero.CameraBoom
        if isValidObject(boom) then
            boom:BP_UpdateDesiredArmLocation(0.016)
        end
    end)
    log("playable camera follow resumed")
end

local function takeViewTarget(controller, hero)
    local current = nil
    pcall(function() current = controller:GetViewTarget() end)
    if isValidObject(current) and objectName(current) == objectName(hero) then
        log("view target is already the hero; leaving it alone")
        return
    end

    -- Remembered so the menu's own camera can be handed back on the way out.
    previousViewTarget = isValidObject(current) and current or nil
    local taken, takeError = pcall(function()
        -- 0 is EViewTargetBlendFunction::VTBlend_Linear.
        controller:SetViewTargetWithBlend(hero, 0.25, 0, 0.0, false)
    end)
    log("view target: was " .. objectName(current)
        .. ", handed to the hero; success=" .. tostring(taken)
        .. (taken and "" or (" error=" .. tostring(takeError))))
end

local function showCharacterForEquipment(widget)
    if not CONFIG.SHOW_CHARACTER then return end
    if not isValidObject(widget) then return end

    local controller = resolveLocalController()
    local hero = resolveHero()
    if not isValidObject(controller) or not isValidObject(hero) then
        log("cannot show the character for Equipment: "
            .. "controller=" .. objectName(controller)
            .. " hero=" .. objectName(hero))
        return
    end

    log("showing the character for Equipment (SHOW_CHARACTER is on)")
    takeViewTarget(controller, hero)
    revealHero(hero)

    log("applying the Equipment forced camera")
    pcall(function()
        widget:ProcessForcedCameraValues(widget.OpenForcedCameraSettings)
    end)

    raiseEquipmentCamera(hero)
end

-- Called on the way back. The start menu draws its own character panel and wants
-- the hero hidden behind its own camera, but only while it is actually up:
-- putting the hide keys back with no menu on screen would leave the player
-- invisible in the field, and stranding the view on the menu's camera would
-- leave them looking at scenery they cannot move.
local function restoreMenuCharacterState(startMenuIsUp)
    if not CONFIG.SHOW_CHARACTER then return end

    local controller = resolveLocalController()
    local hero = resolveHero()
    if isValidObject(controller) then
        local target = startMenuIsUp and previousViewTarget or hero
        if not isValidObject(target) then target = hero end
        if isValidObject(target) then
            local restored = pcall(function()
                controller:SetViewTargetWithBlend(target, 0.0, 0, 0.0, false)
            end)
            log("view target returned to " .. objectName(target)
                .. "; success=" .. tostring(restored))
        end
    end
    previousViewTarget = nil

    if not isValidObject(hero) then
        suppressedHiddenKeys = {}
        originalCameraState = nil
        return
    end
    restoreEquipmentCamera(hero)
    if startMenuIsUp then
        resumePlayableCameraPending = true
        restoreHeroHide(hero)
    else
        -- No menu to hide behind. Drop what was recorded rather than reapplying
        -- it; being visible is the only safe end state out here.
        suppressedHiddenKeys = {}
        resumePlayableCamera(hero)
    end
end

local function verifyEquipmentMounted()
    if not equipmentSubmenuOpen or equipmentSessionArmed then return end

    local widget, presentation, owner = findLiveEquipmentWidget()
    if isValidObject(widget) then
        equipmentSessionArmed = true
        equipmentSessionWidgetKey = objectName(widget)
        log("Equipment screen is live via " .. tostring(presentation)
            .. ": widget=" .. objectName(widget)
            .. " actor=" .. objectName(owner)
            .. " openCamera=" .. describeCameraState(widget))
        showCharacterForEquipment(widget)
        return
    end

    log("Equipment screen never appeared; resetting state")
    equipmentSessionArmed = false
    equipmentSessionWidgetKey = nil
    equipmentSubmenuOpen = false
    mainMenuSubmenuActive = false
    local context = activeEquipmentContext
    if context ~= nil and isValidObject(context.mainMenu) then
        rearmEquipmentEntry(context, true)
        restoreMenuCharacterState(true)
    else
        restoreMenuCharacterState(false)
    end
end

local function selectInjectedEquipment()
    if transitionBusy or equipmentSubmenuOpen then return end
    transitionBusy = true

    ExecuteInGameThread(function()
        local context = activeEquipmentContext
        local controller = resolveLocalController()
        local umgLibrary, rodLibrary = resolveLibraries()
        if context == nil or not isValidObject(context.mainMenu)
            or not isValidObject(context.mainList)
            or not isValidObject(controller)
            or not isValidObject(umgLibrary) or not isValidObject(rodLibrary) then
            log("cannot open Equipment: UI context is unavailable")
            transitionBusy = false
            return
        end

        equipmentSubmenuOpen = true
        equipmentSessionArmed = false
        equipmentSessionWidgetKey = nil
        mainMenuSubmenuActive = true
        submenuTransitionSerial = submenuTransitionSerial + 1
        pendingFocusRedirects[context.listKey] = nil
        restoreEquipmentEntryPresentation(context)

        local opened, openError = pcall(function()
            local widgetClass = StaticFindObject(EQUIPMENT_WIDGET_CLASS)
            if not isValidObject(widgetClass) then
                error("Equipment widget class is not loaded")
            end

            local widget = umgLibrary:Create(controller, widgetClass, controller)
            if not isValidObject(widget) then
                error("Equipment widget creation returned null")
            end

            -- These writes happen before the menu manager sees the widget, so
            -- its open flow reads the values this mod wants rather than the
            -- authored chest defaults. ParentMenu is what lets the manager treat
            -- this as a screen opened from the start menu, and it is why Back
            -- out of Equipment has always worked.
            widget.ParentMenu = context.mainMenu
            widget.MenuKind = MENU_KIND_CHEST_EQUIP
            if CONFIG.SHOW_CHARACTER then
                widget.IsOpenCameraEnable = true
            end

            if CONFIG.SHOW_CHARACTER then
                local hero = resolveHero()
                local captured, captureError = captureOriginalCameraState(hero)
                if not captured then
                    error("could not capture the original camera state: "
                        .. tostring(captureError))
                end
                log("captured original camera state before native Equipment open")
            end

            local handle = rodLibrary:DebugOpenMenu(controller, widget)
            if handle == nil then
                error("DebugOpenMenu returned no Equipment handle")
            end
            rodLibrary:OpenMenu(controller, handle)
        end)
        transitionBusy = false
        if not opened then
            equipmentSubmenuOpen = false
            mainMenuSubmenuActive = false
            log("Equipment menu could not be opened: " .. tostring(openError))
            return
        end

        log("opened Equipment; verifying it reached the screen")
        ExecuteWithDelay(EQUIPMENT_MOUNT_CHECK_MS, function()
            ExecuteInGameThread(verifyEquipmentMounted)
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
    -- tree alive, so a leftover Equipment row from a previous load of this mod
    -- has to go before this one is appended.
    --
    -- Only this mod's rows. This used to delete every child past the authored
    -- wrappers, on position alone, which is only ever correct while this mod is
    -- the sole occupant of the rail below the native rows. It is not: ModMenu
    -- and FastTravelMod append rows of exactly the same shape -- a donor
    -- CanvasPanel holding a MenuIcon -- and this prune ate them. It went unseen
    -- while this mod always injected first, on the construction notification;
    -- being started mid-session through ModMenu's RestartMod puts this code
    -- after their rows exist, and it removed the Mods row that had just started
    -- it. "removed 2 stale Equipment rail row(s)" in UE4SS.log, with one of them
    -- belonging to ModMenu, is what that looked like.
    --
    -- A row is this mod's when it says so, in the label every rail mod writes
    -- into its own icon. A row that cannot be identified is left alone: keeping
    -- a stale row until the menu is recreated is recoverable, deleting another
    -- mod's row is not.
    local removedLegacyRows = 0
    local keptForeignRows = 0
    pcall(function()
        local childCount = parent:GetChildrenCount()
        -- Back to front, so removing one cannot shift the index of the next.
        for index = childCount - 1, authoredWrapperCount, -1 do
            local legacyRow = parent:GetChildAt(index)
            if isValidObject(legacyRow) then
                if railRowLabel(legacyRow) == EQUIPMENT_ROW_LABEL then
                    legacyRow:RemoveFromParent()
                    removedLegacyRows = removedLegacyRows + 1
                else
                    keptForeignRows = keptForeignRows + 1
                end
            end
        end
    end)
    if keptForeignRows > 0 then
        log("left " .. tostring(keptForeignRows)
            .. " rail row(s) belonging to other mods in place")
    end
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
        if not applyEquipmentIconTexture(equipmentIcon, mainList) then
            error("dedicated Equipment icon texture is unavailable")
        end
        local equipmentText = textLibrary:Conv_StringToText(EQUIPMENT_ROW_LABEL)
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
    -- A checkpoint constructs a new menu tree. Retain only the current context;
    -- historical widget references can pin the discarded world.
    equipmentContexts = {
        [objectName(equipmentIcon)] = context,
    }
    activeEquipmentContext = context
    menuCloseBusy = false
    injectedMenus = { [menuKey] = true }
    mainMenuFocusIndexes = {}
    pendingFocusRedirects = {}
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

    -- Returning from Equipment rebuilds this rail from scratch, which is also
    -- how every other mod gets its row back. Put the cursor back on Equipment
    -- once that rebuild has settled, so leaving the screen lands where the
    -- player left off rather than on Pouch.
    if pendingEquipmentFocus then
        pendingEquipmentFocus = false
        ExecuteWithDelay(EQUIPMENT_REFOCUS_DELAY_MS, function()
            ExecuteInGameThread(function()
                if activeEquipmentContext ~= context or mainMenuSubmenuActive then
                    return
                end
                focusEquipment(context)
            end)
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

-- The visible label of a rail row, which is how this mod tells its own injected
-- rows apart from another mod's. Every rail mod writes its own name into the
-- icon's MenuName, so the row carries its owner with it and nothing has to be
-- shared between mods to read it back. Returns nil when the row cannot be
-- identified at all -- callers must treat that as "not mine".
railRowLabel = function(wrapper)
    local icon = iconInsideWrapper(wrapper)
    if not isValidObject(icon) then return nil end
    local label = nil
    pcall(function() label = icon.MenuName:GetText():ToString() end)
    if type(label) == "string" and label ~= "" then return label end
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
            local item = context.mainList["Item_" .. tostring(nativeIndex)]
            item:StopAllAnimations()
            item:SetDefaultAnimation()
        end)
    end

    -- Equipment sits outside that array too, so nothing else will clear its
    -- selection art either.
    pcall(function() context.equipmentIcon:SetDefaultAnimation() end)
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
    focusMenuIcon(context, row.icon, index)
    return true
end

focusEquipment = function(context)
    if context == nil or not isValidObject(context.equipmentIcon) then return end
    -- Equipment is outside the native animation array. Selecting it
    -- therefore cannot make the list deselect its current authored row. Reset
    -- all active rows so mouse selection works from any source, not only the two
    -- controller wrap boundaries (Pouch and the current final native row).
    for index = 0, context.nativeCount - 1 do
        pcall(function()
            local item = context.mainList["Item_" .. tostring(index)]
            item:StopAllAnimations()
            item:SetDefaultAnimation()
        end)
    end
    focusMenuIcon(context, context.equipmentIcon, context.equipmentIndex)
    local _, _, textLibrary = resolveLibraries()
    if isValidObject(textLibrary) then
        pcall(function()
            local equipmentText = textLibrary:Conv_StringToText(EQUIPMENT_ROW_LABEL)
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
            local equipmentText = textLibrary:Conv_StringToText(EQUIPMENT_ROW_LABEL)
            context.equipmentIcon:SetMenuName(equipmentText)
            context.equipmentIcon.MenuName:SetText(equipmentText)
        end)
    end
    pcall(function() applyEquipmentIconTexture(context.equipmentIcon) end)
end

rearmEquipmentEntry = function(context, emitLog)
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

    local returningFromEquipment = equipmentSubmenuOpen or equipmentSessionArmed
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
            equipmentReturnBusy = false
            context.activeNativeSubmenuIndex = nil
            pendingFocusRedirects[context.listKey] = nil
            setNativeMenuPanelsVisibility(context, VISIBLE)
            rearmEquipmentEntry(context, true)
            if returnState.returningFromEquipment then
                equipmentSessionArmed = false
                equipmentSessionWidgetKey = nil
                focusEquipment(context)
                restoreMenuCharacterState(true)
                log("finishMainMenuReturn | Equipment return completed")
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
        local returningFromEquipment = equipmentSessionArmed
        equipmentSessionArmed = false
        equipmentSessionWidgetKey = nil
        mainMenuSubmenuActive = false
        context.activeNativeSubmenuIndex = nil
        pendingFocusRedirects[context.listKey] = nil
        setNativeMenuPanelsVisibility(context, VISIBLE)
        rearmEquipmentEntry(context, emitLog)
        if returningFromEquipment then
            restoreMenuCharacterState(true)
            log("recovered Equipment camera and character state after native Back")
        end
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
            -- Do NOT call beginEquipmentReturnToMain here. The native
            -- EndSubMenu flow handles the full return. Just clear the
            -- armed flag so the mod knows Equipment is closing.
            equipmentSubmenuOpen = false
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

--========================================================--
--                 RETURNING FROM EQUIPMENT               --
--========================================================--
-- Whether the start menu survives an Equipment session is the menu manager's
-- call, not this mod's. Both outcomes are handled, and neither one edits the
-- widget tree of a menu the manager owns:
--
--   * survived  -> rearm this mod's input bridge on the menu that is already
--                  there. Every other mod's row never moved.
--   * torn down -> ask the game to open a new start menu. It constructs a fresh
--                  WBP_Console_MainMenu_C, so this mod and every other rail mod
--                  get their normal construction notification and inject again.
--
-- What is deliberately gone is the third path older builds took: detaching the
-- real start menu, holding the reference across the whole Equipment session and
-- pushing it back into its component afterwards. That resurrected widget looked
-- right to this mod, because this mod rearmed itself explicitly, and was stale
-- to everyone else — no construction notification ever fired for it, so other
-- mods kept pointing at rows on a menu that had been through a teardown.
local function startMenuSurvivedEquipment()
    local context = activeEquipmentContext
    if context == nil or not isValidObject(context.mainMenu) then return false end
    if not isCanonicalMainMenuCandidate(context.mainMenu) then return false end
    if not activeEquipmentContextIsAttached() then return false end

    -- Owning a component is not enough: the component has to still be rendering
    -- this widget, or the menu is on its way out.
    local component = dereferenceWeakObject(context.mainMenu.ParentComponent)
    if not isValidObject(component) then return false end
    local mounted = nil
    pcall(function() mounted = component:GetWidget() end)
    return isValidObject(mounted)
        and objectName(mounted) == objectName(context.mainMenu)
end

-- This catches a close that bypasses the main-menu EndSubMenu path. The normal
-- Equipment widget close is handled by its ClosedMenu hook below; this helper
-- remains for a manager-level close where the widget is already gone.
local function recoverFromEquipmentClose()
    if equipmentScreenIsPresented() then return end
    log("recoverFromEquipmentClose | resetting flags")
    equipmentSubmenuOpen = false
    mainMenuSubmenuActive = false
    equipmentSessionArmed = false
    equipmentSessionWidgetKey = nil
    equipmentReturnBusy = false
    local context = activeEquipmentContext
    if context ~= nil and isValidObject(context.mainMenu) then
        context.activeNativeSubmenuIndex = nil
        pendingFocusRedirects[context.listKey] = nil
        setNativeMenuPanelsVisibility(context, VISIBLE)
        rearmEquipmentEntry(context, true)
        restoreMenuCharacterState(true)
    else
        restoreMenuCharacterState(false)
    end
end

local function completeEquipmentWidgetClose(widgetKey)
    if not equipmentSessionArmed
        or equipmentSessionWidgetKey == nil
        or equipmentSessionWidgetKey ~= widgetKey then
        return
    end

    equipmentSubmenuOpen = false
    mainMenuSubmenuActive = false
    equipmentSessionArmed = false
    equipmentSessionWidgetKey = nil
    equipmentReturnBusy = false
    nativeBackRecoveryBusy = false

    local hero = resolveHero()
    if isValidObject(hero) then
        local returned, returnError = pcall(function()
            hero:ReturnChestCamera()
        end)
        log("ClosedMenu | native ReturnChestCamera success="
            .. tostring(returned)
            .. (returned and "" or (" error=" .. tostring(returnError))))
    end

    local context = activeEquipmentContext
    local startMenuIsUp = startMenuSurvivedEquipment()
    if startMenuIsUp and context ~= nil and isValidObject(context.mainMenu) then
        context.activeNativeSubmenuIndex = nil
        pendingFocusRedirects[context.listKey] = nil
        setNativeMenuPanelsVisibility(context, VISIBLE)
        rearmEquipmentEntry(context, true)
        restoreMenuCharacterState(true)
    else
        restoreMenuCharacterState(false)
    end

    log("ClosedMenu | Equipment camera and character state restored")
end

local function completeEquipmentWidgetClose(widgetKey)
    if not equipmentSessionArmed
        or equipmentSessionWidgetKey == nil
        or equipmentSessionWidgetKey ~= widgetKey then
        return
    end

    equipmentSubmenuOpen = false
    mainMenuSubmenuActive = false
    equipmentSessionArmed = false
    equipmentSessionWidgetKey = nil
    equipmentReturnBusy = false
    nativeBackRecoveryBusy = false

    local hero = resolveHero()
    if isValidObject(hero) then
        local returned, returnError = pcall(function()
            hero:ReturnChestCamera()
        end)
        log("ClosedMenu | native ReturnChestCamera success="
            .. tostring(returned)
            .. (returned and "" or (" error=" .. tostring(returnError))))
    end

    local context = activeEquipmentContext
    local startMenuIsUp = startMenuSurvivedEquipment()
    if startMenuIsUp and context ~= nil and isValidObject(context.mainMenu) then
        context.activeNativeSubmenuIndex = nil
        pendingFocusRedirects[context.listKey] = nil
        setNativeMenuPanelsVisibility(context, VISIBLE)
        rearmEquipmentEntry(context, true)
        restoreMenuCharacterState(true)
    else
        restoreMenuCharacterState(false)
    end

    log("ClosedMenu | Equipment camera and character state restored")
end

-- Kept as a no-op for callers from the old bridge; the native Equipment close
-- event now owns the return transition.
beginEquipmentReturnToMain = function()
    -- The native EndSubMenu flow handles the full return. Nothing to do here.
    log("beginEquipmentReturnToMain called (no-op; EndSubMenu handles return)")
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

isCanonicalMainMenuCandidate = function(mainMenu)
    if not isValidObject(mainMenu)
        or not string.find(
            objectName(mainMenu),
            "WBP_Console_MainMenu_C",
            1,
            true
        ) then
        return false
    end

    local parentComponent = nil
    local parentActor = nil
    pcall(function()
        parentComponent = dereferenceWeakObject(mainMenu.ParentComponent)
        parentActor = dereferenceWeakObject(mainMenu.ParentActor)
    end)

    -- The interactive menu is canonically owned by the world-space widget
    -- component/actor. Widgets from a discarded world, and display-only copies
    -- any mod might build, are not.
    return isValidObject(parentComponent)
        or isValidObject(parentActor)
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
        error("equipment menu injection state is invalid")
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
        error("equipment menu injection state is invalid")
    end
    return pendingMenuInjections
end

local function hasPendingMenuInjections()
    for _ in pairs(requirePendingMenuInjections()) do return true end
    return false
end

activeEquipmentContextIsAttached = function()
    local context = activeEquipmentContext
    if context == nil
        or not isValidObject(context.mainMenu)
        or not isValidObject(context.equipmentIcon)
        or not isValidObject(context.equipmentWrapperPanel)
        or not isValidObject(context.equipmentWrapperParent) then
        return false
    end

    local attachedParent = nil
    pcall(function()
        attachedParent = context.equipmentWrapperPanel.Slot.Parent
    end)
    return isValidObject(attachedParent)
        and objectName(attachedParent)
            == objectName(context.equipmentWrapperParent)
end

local function processMenuInjectionCycle()
    local now = os.clock()
    local pendingInjections = requirePendingMenuInjections()

    if activeEquipmentContext ~= nil
        and not activeEquipmentContextIsAttached() then
        local staleKey = activeEquipmentContext.mainMenuKey
        activeEquipmentContext = nil
        equipmentContexts = {}
        if staleKey ~= nil then injectedMenus[staleKey] = nil end
    end

    for menuKey, readyAt in pairs(pendingInjections) do
        if now >= readyAt then
            pendingInjections[menuKey] = nil
            local mainMenu, resolveError = resolveMainMenuByKey(menuKey)
            if mainMenu == nil then
                log("Equipment injection failed closed for " .. menuKey
                    .. ": " .. tostring(resolveError))
            else
                injectEquipmentEntry(mainMenu)
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

-- EndMenu fires for every menu close (not just Equipment). Keep its delayed
-- check for manager-level teardown; the Equipment widget's ClosedMenu hook is
-- the canonical return event for the normal Back path.
safeHook("/Script/ROD.RODWidgetBPFunctionLibrary:EndMenu",
    function()
        if not equipmentSubmenuOpen then return end
        -- The Equipment widget is being closed. Schedule a deferred recovery
        -- check to catch cases where EndSubMenu does not fire.
        ExecuteWithDelay(1200, function()
            ExecuteInGameThread(function()
                -- Only recover if finishMainMenuReturn has NOT already handled it.
                if equipmentSubmenuOpen or mainMenuSubmenuActive then
                    recoverFromEquipmentClose()
                end
            end)
        end)
    end,
    function()
        if not resumePlayableCameraPending then return end
        ExecuteWithDelay(0, function()
            ExecuteInGameThread(function()
                if startMenuSurvivedEquipment() then return end
                resumePlayableCameraPending = false
                resumePlayableCamera(resolveHero())
            end)
        end)
    end)

safeHook("/Script/ROD.RODMenuWidgetBase:ClosedMenu",
    function(self)
        local widget = unwrap(self)
        local widgetKey = objectName(widget)
        if not contains(widgetKey, EQUIPMENT_CLASS_FRAGMENT)
            or equipmentSessionWidgetKey ~= widgetKey then
            return
        end
        log("observed Equipment ClosedMenu; camera recovery armed")
    end,
    function(self)
        local widget = unwrap(self)
        local widgetKey = objectName(widget)
        if not contains(widgetKey, EQUIPMENT_CLASS_FRAGMENT) then return end
        ExecuteWithDelay(0, function()
            ExecuteInGameThread(function()
                completeEquipmentWidgetClose(widgetKey)
            end)
        end)
    end)

safeHook("/Script/ROD.RODMenuWidgetBase:ClosedMenu",
    function(self)
        local widget = unwrap(self)
        local widgetKey = objectName(widget)
        if not contains(widgetKey, EQUIPMENT_CLASS_FRAGMENT)
            or equipmentSessionWidgetKey ~= widgetKey then
            return
        end
        log("observed Equipment ClosedMenu; camera recovery armed")
    end,
    function(self)
        local widget = unwrap(self)
        local widgetKey = objectName(widget)
        if not contains(widgetKey, EQUIPMENT_CLASS_FRAGMENT) then return end
        ExecuteWithDelay(0, function()
            ExecuteInGameThread(function()
                completeEquipmentWidgetClose(widgetKey)
            end)
        end)
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

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject(
        "/Script/ROD.RODConsoleMainMenuWidgetBase",
        function(object)
            -- This mod no longer constructs a WBP_Console_MainMenu_C of its
            -- own, so every notification here is a real start menu.
            local mainMenu = unwrap(object)
            if not string.find(
                objectName(mainMenu),
                "WBP_Console_MainMenu_C",
                1,
                true
            ) then
                return
            end
            -- Do not capture the UObject in delayed work. Only its primitive
            -- identity crosses the readiness delay.
            queueMenuInjection(objectName(mainMenu))
        end
    )
end)
if not notifyOk then
    error("[" .. MOD_NAME .. "] canonical main-menu notification failed: "
        .. tostring(notifyError))
end

-- Construction notification cannot fire for a menu that was already built
-- before this mod started, and that is now a normal way for this mod to start:
-- ModMenu switches it on mid-session through UE4SS RestartMod, usually from a
-- panel drawn over the very start menu this row belongs in. The notification
-- above then waits for a construction that already happened, the mod loads
-- correctly and injects nothing, and the row only appears once the player has
-- closed and reopened the menu.
--
-- So sweep once, at startup, for a menu that is already up. This is not the
-- "scan the global object array" that used to be avoided here: it is the same
-- FindAllOf that resolveMainMenuByKey already runs on every injection cycle,
-- behind the same isCanonicalMainMenuCandidate filter, feeding the same queue
-- and the same readiness delay. A display-only copy or a widget from a
-- discarded world is rejected here exactly as it is everywhere else, and a
-- menu that arrives normally is deduplicated by injectedMenus.
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

-- Defined here, next to the notification it backstops, but fired at the very
-- end of this file: it can queue an injection, and everything that injection
-- goes on to touch has to exist first.

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
-- Intercept native focus wrap and hidden Item_6 to redirect into Equipment.
safeHook("/Script/ROD.RODListWidgetBase:FocusEvent",
    function(self, widgetParameter)
        local context = activeEquipmentContext
        if context == nil then return end
        -- Auto-recover from stale submenu flag.
        if mainMenuSubmenuActive and not equipmentSubmenuOpen then
            mainMenuSubmenuActive = false
        end
        if mainMenuSubmenuActive then return end

        local mainList = unwrap(self)
        local widget = unwrap(widgetParameter)
        local listKey = objectName(mainList)
        if not string.find(listKey, "WBP_Console_MainMenu_List_C", 1, true)
            or not isValidObject(widget) then
            return
        end
        if context.listKey ~= listKey then return end

        local index = nil
        pcall(function() index = widget:GetItemIndex() end)
        if index == nil then return end

        local previousIndex = mainMenuFocusIndexes[listKey]
        mainMenuFocusIndexes[listKey] = index

        local isInjectedEquipment = equipmentContextFor(widget) ~= nil
        if isInjectedEquipment then
            restoreEquipmentEntryPresentation(context)
        elseif index >= 0 and index < context.equipmentIndex then
            clearEquipmentSelectionVisual(context)
        end

        -- Detect hidden Item_6 by object identity.
        local isHiddenItem6 = false
        pcall(function()
            if isValidObject(context.mainList.Item_6) then
                isHiddenItem6 = (objectName(widget) == objectName(context.mainList.Item_6))
            end
        end)

        -- Detect native wrap boundaries.
        local lastNative = context.equipmentIndex - 1
        local wrappedDown = (previousIndex == lastNative and index == 0)
        local wrappedUp = (previousIndex == 0 and index == lastNative)

        -- Any focus on a hidden native row or stale index beyond our row.
        local hitHiddenRow = isHiddenItem6
            or (not isInjectedEquipment
                and index >= context.equipmentIndex
                and not isForeignRailIcon(context, widget))

        if wrappedDown or wrappedUp or hitHiddenRow then
            -- Determine direction: going up means we redirect to the last
            -- rail row, going down means we redirect to Equipment.
            local goingUp
            if wrappedUp then
                goingUp = true
            elseif wrappedDown then
                goingUp = false
            elseif hitHiddenRow then
                -- Focus landed on hidden Item_6 or beyond. If previous was
                -- at or beyond Equipment (a mod row), user was going UP.
                -- If previous was a valid native row, user was going DOWN
                -- past Settings into the hidden zone.
                if previousIndex == nil or previousIndex >= context.equipmentIndex then
                    goingUp = true
                else
                    goingUp = (previousIndex > index)
                end
            else
                goingUp = false
            end
            pendingFocusRedirects[listKey] = goingUp and "last" or "equipment"
        end
    end,
    function(self)
        local context = activeEquipmentContext
        if context == nil then return end
        local mainList = unwrap(self)
        local listKey = objectName(mainList)
        local redirect = pendingFocusRedirects[listKey]
        if redirect == nil then return end
        pendingFocusRedirects[listKey] = nil
        focusRailBoundary(context, redirect == "last")
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

-- Nothing in this build creates a viewport-only start menu any more. This still
-- runs once at load so that hot-reloading over a session that used the old
-- clone-based Equipment screen does not leave its overlay stuck on screen.
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

--========================================================--
--                      DIAGNOSTICS                       --
--========================================================--
-- Read-only. This exists because the interesting failures on this build are
-- native calls that succeed and do nothing, which no amount of reading headers
-- will tell you apart from calls that work. `fieldequip probe` reports what is
-- actually there; `fieldequip open3d` re-runs the DebugOpen3DMenu experiment on
-- demand so a future patch can be retested without editing the mod.
local function reportState(reply)
    local controller = resolveLocalController()
    reply("controller: " .. objectName(controller))
    reply(string.format("state: enabled=%s showCharacter=%s open=%s armed=%s",
        tostring(CONFIG.ENABLED), tostring(CONFIG.SHOW_CHARACTER),
        tostring(equipmentSubmenuOpen), tostring(equipmentSessionArmed)))

    local context = activeEquipmentContext
    if context == nil then
        reply("rail: no Equipment row is live (open the start menu first)")
    else
        reply("rail: index " .. tostring(context.equipmentIndex)
            .. " after " .. tostring(context.nativeCount) .. " native row(s) on "
            .. objectName(context.mainMenu))
    end

    local widget, presentation, owner = findLiveEquipmentWidget()
    if isValidObject(widget) then
        reply("equipment widget: " .. objectName(widget)
            .. " via " .. tostring(presentation) .. " actor " .. objectName(owner))
        reply("  IsOpenCameraEnable = " .. describeCameraState(widget))
    else
        reply("equipment widget: none on screen")
    end

    local hero = resolveHero()
    if isValidObject(hero) then
        local hidden = nil
        local location = nil
        pcall(function() hidden = hero:IsHidden() end)
        pcall(function() location = hero:K2_GetActorLocation() end)
        reply("hero: " .. objectName(hero) .. " hidden=" .. tostring(hidden))
        if location ~= nil then
            reply(string.format("  location: %.0f %.0f %.0f",
                location.X or 0, location.Y or 0, location.Z or 0))
        end
        -- The actor stays hidden while any of these is present, so this names
        -- exactly which system is still asking for it.
        reply("  hide keys: " .. describeKeys(readHiddenKeys(hero)))
        reply("  suppressed by this mod: " .. describeKeys(suppressedHiddenKeys))
    else
        reply("hero: not resolvable")
    end

    -- The question every camera failure so far came down to: who owns the view?
    local viewTarget = nil
    if isValidObject(controller) then
        pcall(function() viewTarget = controller:GetViewTarget() end)
    end
    local ownedByHero = isValidObject(viewTarget) and isValidObject(hero)
        and objectName(viewTarget) == objectName(hero)
    reply("view target: " .. objectName(viewTarget)
        .. (ownedByHero and "  (the hero)" or "  (NOT the hero)"))

    for _, name in ipairs({
        "DebugOpen3DMenu", "DebugOpenChangeEquipMenu", "DebugOpenMainMenu",
        "OnMainMenuCharacterHidden",
    }) do
        local present = "unavailable"
        if isValidObject(controller) then
            local ok, member = pcall(function() return controller[name] end)
            if ok and member ~= nil then present = "reflected" end
        end
        reply(string.format("  %-26s %s", name, present))
    end
    reply("reflected only means the function exists; on this build "
        .. "DebugOpen3DMenu returns without opening anything.")
end

-- `<MISSING STRING TABLE ENTRY>` on some Equipment labels means the string table
-- those keys live in is not resident. Opening this screen in the field skips
-- whatever normally pulls it in at a chest, and string tables are collectable,
-- so whether it is there varies within a session. This lists what is loaded so
-- the right asset can be named instead of guessed at.
local function reportStringTables(reply)
    local ok, tables = pcall(function() return FindAllOf("StringTable") end)
    if not ok or tables == nil then
        reply("string tables: FindAllOf(StringTable) returned nothing")
        return
    end

    local count = 0
    for _, table_ in ipairs(tables) do
        if isValidObject(table_) then
            count = count + 1
            if count <= 40 then reply("  " .. objectName(table_)) end
        end
    end
    reply("string tables loaded: " .. tostring(count)
        .. (count > 40 and "  (first 40 shown)" or ""))

    local manager = FindFirstOf("RODDataManager")
    if isValidObject(manager) then
        local general = nil
        pcall(function() general = manager.GeneralLocalizeStringTable end)
        reply("RODDataManager.GeneralLocalizeStringTable: " .. objectName(general))
    else
        reply("RODDataManager: not resolvable")
    end
end

local commandOk, commandError = pcall(function()
    RegisterConsoleCommandHandler("fieldequip", function(_full, params, ar)
        local function reply(message)
            local delivered = pcall(function() ar:Log(tostring(message)) end)
            if not delivered then
                print("[" .. MOD_NAME .. "] " .. tostring(message) .. "\n")
            end
        end

        local arguments = params or {}
        local sub = arguments[1] and string.lower(tostring(arguments[1])) or "probe"
        if sub == "probe" then
            local ok, err = pcall(reportState, reply)
            if not ok then reply("probe error: " .. tostring(err)) end
            return true
        end

        if sub == "open3d" then
            -- Replies before deferring: the console's `ar` is only valid for the
            -- duration of this synchronous call.
            reply("running DebugOpen3DMenu(ChestMenu, ChestEquipMenu); "
                .. "watch UE4SS.log for the result")
            ExecuteInGameThread(function()
                local controller = resolveLocalController()
                if not isValidObject(controller) then
                    log("PROBE open3d: controller is unavailable")
                    return
                end
                log("PROBE open3d: calling DebugOpen3DMenu")
                local called, callError = pcall(function()
                    controller:DebugOpen3DMenu(
                        ACTOR_MENU_KIND_CHEST, MENU_KIND_CHEST_EQUIP)
                end)
                log("PROBE open3d: call returned ok=" .. tostring(called)
                    .. " error=" .. tostring(callError))
                ExecuteWithDelay(1000, function()
                    ExecuteInGameThread(function()
                        local widget, presentation = findLiveEquipmentWidget()
                        log("PROBE open3d: equipment widget="
                            .. objectName(widget)
                            .. " via " .. tostring(presentation))
                    end)
                end)
            end)
            return true
        end

        if sub == "strings" then
            local ok, err = pcall(reportStringTables, reply)
            if not ok then reply("string probe error: " .. tostring(err)) end
            return true
        end

        reply("Usage: fieldequip probe | strings | open3d")
        return true
    end)
end)
if not commandOk then
    print(string.format("[%s] console command unavailable: %s\n",
        MOD_NAME, tostring(commandError)))
end

-- Runtime settings. Injection happens as the start menu is constructed, so an
-- ENABLED change lands the next time the menu is opened rather than instantly.
do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = applyExternalConfig,
        apply = function()
            if activeEquipmentContext ~= nil then
                setEquipmentEntryVisibility(activeEquipmentContext,
                    CONFIG.ENABLED and VISIBLE or COLLAPSED)
            end
        end,
        fail = function()
            CONFIG.ENABLED = false
            if activeEquipmentContext ~= nil then
                setEquipmentEntryVisibility(activeEquipmentContext, COLLAPSED)
            end
        end,
        log = function(message)
            print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
        end,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
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

print(string.format("[%s] loaded %s\n", MOD_NAME, MOD_VERSION))
