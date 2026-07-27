-- FastTravelMod v0.3.7
--
-- Adds a native-styled Fast Travel row to Echoes of Aincrad's Start Menu and
-- opens the game's ordinary WBP_Map screen in teleport mode. Confirming an
-- eligible selected icon teleports through the hero's native server RPC.
--
-- Runtime contract: SDK/template 1.0.3
--   EMenuKind::MapMenu = 31
--   ARODInGamePlayerController::EndMainMenu(true)
--   UGameplayAbility::GetAbilitySystemComponentFromActorInfo()
--   UGameplayAbility::AbilityTriggers
--   URODAbilitySystemComponent::TryActivateAbilityWithPayloadFromClass(...)
--   ARODInGamePlayerController::EndMapMenu(AllClose)
--   URODMapMenuWidgetBase::UpdateIcon(...)
--   ARODAvatarCharacter::ServerDebugTeleportGimmick(FVector)
--   WBP_Map_C
--
-- No terminal impersonation, FastTravelStatus write or direct actor-location
-- mutation exists here. If the exact selected icon or its native map position
-- is unavailable, the operation stops and reports the error.

local MOD_NAME = "FastTravelMod"
local MOD_VERSION = "v0.3.7"
local SUPPORTED_SDK = "Echoes of Aincrad 1.0.3"

local MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C"
local MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C"
local MAIN_MENU_CLASS_FRAGMENT = "WBP_Console_MainMenu_C"
local MAIN_MENU_LIST_FRAGMENT = "WBP_Console_MainMenu_List_C"
local MENU_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C"
local MAP_WIDGET_FRAGMENT = "WBP_Map_C"
local MAIN_MENU_ABILITY_CLASS = "GA_AvatarMenu_Main_C"
local MAP_MENU_ABILITY_CLASS = "GA_AvatarMenu_Map_C"

local FAST_TRAVEL_STATUS_DISABLE = 0
local FAST_TRAVEL_STATUS_CANCEL = 1
local FAST_TRAVEL_STATUS_DECIDE = 2
local FAST_TRAVEL_STATUS_ENABLE = 3
local ACCESSIBLE_STATUS_NONE = 0

local MAX_NATIVE_MENU_ITEMS = 7
local MENU_INJECTION_DELAY_MS = 250
local MENU_TRANSITION_POLL_MS = 50
local MENU_TRANSITION_TIMEOUT_MS = 3000
local OPEN_VERIFICATION_DELAY_MS = 2500
local TELEPORT_FINALIZE_DELAY_MS = 900
local MENU_END_ALL_CLOSE = 2

local ACCEPT_BUTTON = 1
local BACK_BUTTON = 2
local SINGLE_CLICK = 1
local DPAD_UP = 13
local DPAD_DOWN = 14
local LSTICK_UP = 17
local LSTICK_DOWN = 18

local ELIGIBLE_MAP_ICON_KINDS = {
    [11] = "AccessGimmick",
    [12] = "AccessGimmick_Restart",
    [14] = "TeleportGate",
    [15] = "TeleportGate_Restart",
    [16] = "SafeArea",
    [17] = "SafeAreaRestart",
    [24] = "HeroPin1",
    [25] = "HeroPin2",
    [26] = "HeroPin3",
    [27] = "PillarPin1",
    [28] = "PillarPin2",
    [29] = "PillarPin3",
    [30] = "PillarPin4",
    [31] = "PillarPin5",
    [32] = "InstantPin1",
    [33] = "InstantPin2",
    [34] = "InstantPin3",
}

local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2

local SCRIPT_DIR = (function()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local directory = source:match("^(.*[\\/])")
    if directory == nil then
        error("canonical FastTravelMod Scripts directory is unavailable")
    end
    return directory
end)()

local CONFIG = {
    ENABLED = true,
    DEBUG_LOGS = false,
}

local runtimeHealthy = true
local activeContext = nil
local injectedMenuKey = nil
local pendingInjectionKeys = {}
local listFocusIndexes = {}
local pendingFocusRedirects = {}
local inputLocked = false
local openBusy = false
local openSerial = 0
local teleportMapWidgetKey = nil
local menuCloseBusy = false
local teleportMapModeActive = false
local mapTeleportBusy = false
local mapIconDestinations = {}
local pendingMapAbility = nil
local lastNativeFastTravelStatus = nil
local lastNativeAccessibleStatus = nil
local lastNativeAccessingTerminal = nil
local lastNativeAccessibleGimmickId = nil

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

log("main.lua entered | script dir: " .. SCRIPT_DIR)

local function dbg(message)
    if CONFIG.DEBUG_LOGS then log(message) end
end

local function isValid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function objectName(object)
    if not isValid(object) then return nil end
    local ok, name = pcall(function() return object:GetFullName() end)
    if not ok or name == nil then return nil end
    return tostring(name)
end

local function nameContains(object, fragment)
    local name = objectName(object)
    return name ~= nil
        and string.find(name, fragment, 1, true) ~= nil
end

local function hookValue(parameter)
    if parameter == nil then
        error("hook parameter is unavailable")
    end
    local ok, value = pcall(function() return parameter:get() end)
    if not ok then
        error("hook parameter decode failed: " .. tostring(value))
    end
    return value
end

local function exactFNameString(value, label)
    if value == nil then
        error(tostring(label) .. " is unavailable")
    end
    local ok, text = pcall(function()
        return value:ToString()
    end)
    if not ok or type(text) ~= "string" or text == "" then
        error(tostring(label) .. " FName decode failed: " ..
            tostring(text))
    end
    return text
end

local function weakObject(pointer)
    if pointer == nil then return nil end
    local ok, object = pcall(function() return pointer:Get() end)
    if not ok then return nil end
    if isValid(object) then return object end
    return nil
end

local function applySettings(settings)
    if type(settings) ~= "table" then
        error("settings must be a table")
    end
    local known = {
        ENABLED = true,
        DEBUG_LOGS = true,
    }
    for key in pairs(settings) do
        if known[key] ~= true then
            error("unknown setting: " .. tostring(key))
        end
    end
    for key in pairs(known) do
        if type(settings[key]) ~= "boolean" then
            error(key .. " must be boolean")
        end
    end
    CONFIG.ENABLED = settings.ENABLED
    CONFIG.DEBUG_LOGS = settings.DEBUG_LOGS
    runtimeHealthy = true
end

local MOD_MENU_BRIDGE = (function()
    local path = SCRIPT_DIR .. "../../shared/ModMenuBridge.lua"
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
    local settings, _, info =
        MOD_MENU_BRIDGE.readSettings(MOD_NAME, SCRIPT_DIR)
    if settings == nil then
        error("canonical settings load failed: " ..
            tostring(info and info.error or "unknown settings error"))
    end
    applySettings(settings)
end

local function resolveLocalController()
    local controller = FindFirstOf("RODWorldPlayerController")
    if not isValid(controller) then
        return nil, "exact RODWorldPlayerController is unavailable"
    end
    return controller, nil
end

local function isLocalWorldController(controller)
    if not isValid(controller) then
        error("hook controller is unavailable")
    end
    local expectedClass =
        StaticFindObject("/Script/ROD.RODWorldPlayerController")
    if not isValid(expectedClass) then
        error("RODWorldPlayerController class fingerprint is unavailable")
    end
    local classOk, matches = pcall(function()
        return controller:IsA(expectedClass)
    end)
    if not classOk then
        error("controller class validation failed: " ..
            tostring(matches))
    end
    if matches ~= true then return false end

    local localOk, isLocal = pcall(function()
        return controller:IsLocalController()
    end)
    if not localOk or type(isLocal) ~= "boolean" then
        error("controller locality validation failed: " ..
            tostring(isLocal))
    end
    return isLocal
end

local function resolveLocalPlayerState()
    local controller, controllerError = resolveLocalController()
    if controller == nil then return nil, controllerError end

    local playerState = nil
    local readOk, readError = pcall(function()
        playerState = controller.PlayerState
    end)
    if not readOk or not isValid(playerState) then
        return nil, "local PlayerState is unavailable: " .. tostring(readError)
    end

    local expectedClass =
        StaticFindObject("/Script/ROD.RODWorldPlayerState")
    if not isValid(expectedClass) then
        return nil, "RODWorldPlayerState class fingerprint is unavailable"
    end
    local classOk, matches = pcall(function()
        return playerState:IsA(expectedClass)
    end)
    if not classOk or matches ~= true then
        return nil, "local PlayerState is not RODWorldPlayerState"
    end
    return playerState, nil
end

local function resolveLocalHero()
    local controller, controllerError = resolveLocalController()
    if controller == nil then return nil, controllerError end

    local hero = nil
    local readOk, readError = pcall(function()
        hero = controller.HeroRef
    end)
    if not readOk or not isValid(hero) then
        return nil, "local RODHeroCharacter is unavailable: " ..
            tostring(readError)
    end

    local expectedClass =
        StaticFindObject("/Script/ROD.RODHeroCharacter")
    if not isValid(expectedClass) then
        return nil, "RODHeroCharacter class fingerprint is unavailable"
    end
    local classOk, matches = pcall(function()
        return hero:IsA(expectedClass)
    end)
    if not classOk or matches ~= true then
        return nil, "local hero is not RODHeroCharacter"
    end
    return hero, nil
end

local function findAbilityObjects(className)
    local objects = nil
    local queryOk, queryError = pcall(function()
        objects = FindAllOf(className)
    end)
    if not queryOk or type(objects) ~= "table" then
        error(tostring(className) .. " query failed: " ..
            tostring(queryError))
    end

    local validObjects = {}
    for _, object in ipairs(objects) do
        if isValid(object) then
            validObjects[#validObjects + 1] = object
        end
    end
    if #validObjects == 0 then
        error(tostring(className) .. " has no valid loaded objects")
    end
    return validObjects
end

local function resolveOwnedAbility(className, abilitySystem)
    local abilitySystemName = objectName(abilitySystem)
    if abilitySystemName == nil then
        error("local Ability System identity is unavailable")
    end

    local ownedAbilities = {}
    for _, ability in ipairs(findAbilityObjects(className)) do
        local ownerAbilitySystem = nil
        local ownerOk, ownerError = pcall(function()
            ownerAbilitySystem =
                ability:GetAbilitySystemComponentFromActorInfo()
        end)
        if not ownerOk then
            error(string.format(
                "%s owner query failed for %s: %s",
                tostring(className),
                tostring(objectName(ability)),
                tostring(ownerError)))
        end
        if isValid(ownerAbilitySystem)
            and objectName(ownerAbilitySystem) == abilitySystemName then
            ownedAbilities[#ownedAbilities + 1] = ability
        end
    end

    if #ownedAbilities ~= 1 then
        error(string.format(
            "expected one %s owned by the local Ability System, found %d",
            tostring(className),
            #ownedAbilities))
    end
    return ownedAbilities[1]
end

local function isOwnedAbilityClassActive(className, abilitySystem)
    local ability = resolveOwnedAbility(className, abilitySystem)
    local active = nil
    local queryOk, queryError = pcall(function()
        active = ability:BP_IsActive()
    end)
    if not queryOk or type(active) ~= "boolean" then
        error(string.format(
            "%s BP_IsActive query failed for %s: %s",
            tostring(className),
            tostring(objectName(ability)),
            tostring(queryError)))
    end
    return active
end

local function resolveMapAbilityContract()
    local hero, heroError = resolveLocalHero()
    if hero == nil then return nil, heroError end

    local abilitySystem = nil
    local abilityReadOk, abilityReadError = pcall(function()
        abilitySystem = hero.AbilitySystem
    end)
    if not abilityReadOk or not isValid(abilitySystem) then
        return nil, "local RODAbilitySystemComponent is unavailable: " ..
            tostring(abilityReadError)
    end

    local abilityClass =
        StaticFindObject("/Script/ROD.RODAbilitySystemComponent")
    if not isValid(abilityClass) then
        return nil,
            "RODAbilitySystemComponent class fingerprint is unavailable"
    end
    local classOk, classMatches = pcall(function()
        return abilitySystem:IsA(abilityClass)
    end)
    if not classOk or classMatches ~= true then
        return nil, "hero AbilitySystem is not RODAbilitySystemComponent"
    end

    local mapAbility = nil
    local mapAbilityClass = nil
    local mapAbilityClassName = nil
    local mapAbilityTriggerTag = nil
    local mapAbilityTriggerTagName = nil
    local mapAbilityPayload = nil
    local contractOk, contractError = pcall(function()
        mapAbility = resolveOwnedAbility(
            MAP_MENU_ABILITY_CLASS,
            abilitySystem)
        mapAbilityClass = mapAbility:GetClass()
        if not isValid(mapAbilityClass) then
            error(MAP_MENU_ABILITY_CLASS ..
                " generated class is unavailable")
        end
        mapAbilityClassName = objectName(mapAbilityClass)
        if mapAbilityClassName == nil
            or string.find(
                mapAbilityClassName,
                MAP_MENU_ABILITY_CLASS,
                1,
                true) == nil then
            error("map ability generated class fingerprint mismatch: " ..
                tostring(mapAbilityClassName))
        end

        local tagLibrary = StaticFindObject(
            "/Script/GameplayTags.Default__BlueprintGameplayTagLibrary")
        if not isValid(tagLibrary) then
            error("BlueprintGameplayTagLibrary default object is unavailable")
        end

        local eventTriggers = {}
        local triggers = mapAbility.AbilityTriggers
        if triggers == nil then
            error(MAP_MENU_ABILITY_CLASS ..
                " AbilityTriggers is unavailable")
        end
        local triggersOk, triggersError = pcall(function()
            triggers:ForEach(function(_, element)
                local trigger = element:get()
                if trigger == nil then
                    error("AbilityTriggers element decode failed")
                end
                if tonumber(trigger.TriggerSource) == 0 then
                    eventTriggers[#eventTriggers + 1] =
                        trigger.TriggerTag
                end
            end)
        end)
        if not triggersOk then
            error("AbilityTriggers query failed: " ..
                tostring(triggersError))
        end
        if #eventTriggers ~= 1 then
            error(string.format(
                "%s must expose exactly one GameplayEvent trigger; found %d",
                MAP_MENU_ABILITY_CLASS,
                #eventTriggers))
        end

        mapAbilityTriggerTag = eventTriggers[1]
        if tagLibrary:IsGameplayTagValid(
            mapAbilityTriggerTag) ~= true then
            error(MAP_MENU_ABILITY_CLASS ..
                " GameplayEvent trigger tag is invalid")
        end
        mapAbilityTriggerTagName = exactFNameString(
            mapAbilityTriggerTag.TagName,
            MAP_MENU_ABILITY_CLASS .. " trigger TagName")

        mapAbilityPayload = mapAbility.CurrentEventData
        if mapAbilityPayload == nil then
            error(MAP_MENU_ABILITY_CLASS ..
                " CurrentEventData payload is unavailable")
        end

        local mainMenuActive =
            isOwnedAbilityClassActive(
                MAIN_MENU_ABILITY_CLASS,
                abilitySystem)
        if not mainMenuActive then
            error(MAIN_MENU_ABILITY_CLASS ..
                " has no active ability instance")
        end
    end)
    if not contractOk then
        return nil, "map gameplay ability contract failed: " ..
            tostring(contractError)
    end

    return {
        abilitySystem = abilitySystem,
        mapAbility = mapAbility,
        mapAbilityClass = mapAbilityClass,
        mapAbilityClassName = mapAbilityClassName,
        mapAbilityTriggerTag = mapAbilityTriggerTag,
        mapAbilityTriggerTagName = mapAbilityTriggerTagName,
        mapAbilityPayload = mapAbilityPayload,
    }, nil
end

local function resolveWorldGameState()
    local gameState = FindFirstOf("RODWorldGameState")
    if not isValid(gameState) then
        return nil, "exact RODWorldGameState is unavailable"
    end
    return gameState, nil
end

local FAST_TRAVEL_STATUS_NAMES = {
    [FAST_TRAVEL_STATUS_DISABLE] = "Disable",
    [FAST_TRAVEL_STATUS_CANCEL] = "Cancel",
    [FAST_TRAVEL_STATUS_DECIDE] = "Decide",
    [FAST_TRAVEL_STATUS_ENABLE] = "Enable",
}

local function exactFastTravelStatusName(status)
    local name = FAST_TRAVEL_STATUS_NAMES[status]
    if name == nil then
        error("unknown FastTravelStatus: " .. tostring(status))
    end
    return name
end

local function readNativeTravelState()
    local playerState, playerStateError = resolveLocalPlayerState()
    if playerState == nil then error(playerStateError) end

    local gameState, gameStateError = resolveWorldGameState()
    if gameState == nil then error(gameStateError) end

    local state = {}
    local readOk, readError = pcall(function()
        state.fastTravelStatus = tonumber(playerState.FastTravelStatus)
        state.accessibleStatus = tonumber(playerState.PSAcsGmkStatus)
        state.accessingTerminal = playerState.bAccessingTerminal
        state.currentGimmickId = exactFNameString(
            gameState.CurrentAcsGmkID, "CurrentAcsGmkID")
        state.checkPointId = exactFNameString(
            gameState.CheckPointID, "CheckPointID")
        state.currentGimmick = gameState.CurrentAcsGmk
    end)
    if not readOk then
        error("native Fast Travel state read failed: " ..
            tostring(readError))
    end
    if state.fastTravelStatus == nil then
        error("FastTravelStatus is not numeric")
    end
    exactFastTravelStatusName(state.fastTravelStatus)
    if state.accessibleStatus == nil then
        error("PSAcsGmkStatus is not numeric")
    end
    if type(state.accessingTerminal) ~= "boolean" then
        error("bAccessingTerminal is not boolean")
    end
    if isValid(state.currentGimmick) then
        state.currentGimmickName = objectName(state.currentGimmick)
    else
        -- CurrentAcsGmk is a nullable native pointer. UE4SS exposes its null
        -- value as an invalid RemoteObject rather than Lua nil.
        state.currentGimmickName = "<null>"
    end
    if isValid(state.currentGimmick)
        and state.currentGimmickName == nil then
        error("CurrentAcsGmk name is unavailable")
    end
    return state
end

local function logNativeTravelState(source)
    local state = readNativeTravelState()
    lastNativeFastTravelStatus = state.fastTravelStatus
    lastNativeAccessibleStatus = state.accessibleStatus
    lastNativeAccessingTerminal = state.accessingTerminal
    lastNativeAccessibleGimmickId = state.currentGimmickId
    log(string.format(
        "NATIVE STATE | source=%s | FastTravelStatus=%s(%d) | PSAcsGmkStatus=%d | bAccessingTerminal=%s | CurrentAcsGmkID=%s | CurrentAcsGmk=%s | CheckPointID=%s",
        tostring(source),
        exactFastTravelStatusName(state.fastTravelStatus),
        state.fastTravelStatus,
        state.accessibleStatus,
        tostring(state.accessingTerminal),
        state.currentGimmickId,
        state.currentGimmickName,
        state.checkPointId))
    return state
end

local function restorePlayableCamera(source)
    local hero, heroError = resolveLocalHero()
    if hero == nil then error(heroError) end

    local cameraProcess = nil
    local cameraReadOk, cameraReadError = pcall(function()
        cameraProcess = hero.CameraAdjustComponent
    end)
    if not cameraReadOk or not isValid(cameraProcess) then
        error("RODInGameCameraProcessComponent is unavailable: " ..
            tostring(cameraReadError))
    end

    local resetOk, resetError = pcall(function()
        hero:StopCameraAnimation()
        hero:ResetFov()
        hero:ResetCameraViewPointLocation(true)
        hero:ResetCameraBoomArmLength()
        cameraProcess:ResetMenuRotation()
        cameraProcess:ResetMenuCameraTransform()
        cameraProcess:OnEnablePlayableFollowCamera()
    end)
    if not resetOk then
        error("playable camera reset failed: " .. tostring(resetError))
    end
    log("playable camera restored | source=" .. tostring(source))
end

local function recoverCompletedNativeTravel(source)
    local state = readNativeTravelState()
    local completedButStale =
        state.fastTravelStatus == FAST_TRAVEL_STATUS_DECIDE
        and state.accessibleStatus == ACCESSIBLE_STATUS_NONE
        and state.accessingTerminal == false
        and state.currentGimmickId == "None"
    if not completedButStale then return false end

    local playerState, playerStateError = resolveLocalPlayerState()
    if playerState == nil then error(playerStateError) end
    local cancelled, cancelError = pcall(function()
        playerState:ServerCancelFastTravel()
    end)
    if not cancelled then
        error("ServerCancelFastTravel cleanup failed: " ..
            tostring(cancelError))
    end
    restorePlayableCamera(source)
    log("stale native Fast Travel transaction closed")
    return true
end

local function scheduleNativeTravelState(source, delayMs)
    local scheduled, scheduleError = pcall(function()
        ExecuteWithDelay(delayMs or 0, function()
            ExecuteInGameThread(function()
                local ok, stateError =
                    xpcall(function()
                        logNativeTravelState(source)
                    end, debug.traceback)
                if not ok then
                    log("NATIVE STATE ERROR | source=" ..
                        tostring(source) .. " | " ..
                        tostring(stateError))
                end
            end)
        end)
    end)
    if not scheduled then
        log("NATIVE STATE ERROR | scheduling failed: " ..
            tostring(scheduleError))
    end
end

local function resolveUmgLibrary()
    local library =
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not isValid(library) then
        return nil, "WidgetBlueprintLibrary default object is unavailable"
    end
    return library, nil
end

local function resolveTextLibrary()
    local library =
        StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if not isValid(library) then
        return nil, "KismetTextLibrary default object is unavailable"
    end
    return library, nil
end

local function resolveRodWidgetLibrary()
    local library =
        StaticFindObject("/Script/ROD.Default__RODWidgetBPFunctionLibrary")
    if not isValid(library) then
        return nil, "RODWidgetBPFunctionLibrary default object is unavailable"
    end
    return library, nil
end

local function setContextVisibility(context, visibility)
    if context == nil or not isValid(context.wrapperPanel) then return end
    local ok, visibilityError = pcall(function()
        context.wrapperPanel:SetVisibility(visibility)
    end)
    if not ok then
        runtimeHealthy = false
        log("FAIL-CLOSED | row visibility failed: " ..
            tostring(visibilityError))
    end
end

local function failCurrentMenu(reason)
    local message = tostring(reason)
    runtimeHealthy = false
    CONFIG.ENABLED = false
    openBusy = false
    teleportMapModeActive = false
    mapTeleportBusy = false
    mapIconDestinations = {}
    teleportMapWidgetKey = nil
    openSerial = openSerial + 1
    if activeContext ~= nil then
        activeContext.failed = true
        setContextVisibility(activeContext, COLLAPSED)
    end
    log("FAIL-CLOSED | " .. message)
end

local function menuItemAndPanel(mainList, index)
    local item = nil
    local wrapper = nil
    local ok = pcall(function()
        item = mainList["Item_" .. tostring(index)]
        wrapper = item.Slot.Parent
    end)
    if not ok or not isValid(item) or not isValid(wrapper) then
        return nil, nil
    end
    return item, wrapper
end

local function resolveNativeMenuCount(mainMenu, mainList)
    local finalIndex = nil
    local readOk, readError = pcall(function()
        finalIndex = tonumber(mainMenu.NumContent)
    end)
    if not readOk or finalIndex == nil
        or finalIndex % 1 ~= 0
        or finalIndex < 0
        or finalIndex >= MAX_NATIVE_MENU_ITEMS then
        return nil, "canonical NumContent is invalid: " ..
            tostring(readError or finalIndex)
    end

    local count = finalIndex + 1
    for index = 0, count - 1 do
        local item = menuItemAndPanel(mainList, index)
        if not isValid(item) then
            return nil, "native menu item " .. tostring(index) ..
                " is unavailable"
        end
    end
    return count, nil
end

local function iconInsideWrapper(wrapper)
    if not isValid(wrapper) then return nil end
    local childCount = nil
    local countOk = pcall(function()
        childCount = wrapper:GetChildrenCount()
    end)
    if not countOk or type(childCount) ~= "number" then return nil end

    for index = 0, childCount - 1 do
        local child = nil
        local childOk = pcall(function()
            child = wrapper:GetChildAt(index)
        end)
        if childOk and isValid(child)
            and nameContains(child, MENU_ICON_FRAGMENT) then
            return child
        end
    end
    return nil
end

local function authoredWrapperNames(mainList)
    local authored = {}
    for index = 0, MAX_NATIVE_MENU_ITEMS - 1 do
        local _, wrapper = menuItemAndPanel(mainList, index)
        local name = objectName(wrapper)
        if name ~= nil then authored[name] = true end
    end
    return authored
end

local function countInjectedRows(parent, mainList)
    local authored = authoredWrapperNames(mainList)
    local childCount = nil
    local countOk = pcall(function()
        childCount = parent:GetChildrenCount()
    end)
    if not countOk or type(childCount) ~= "number" then
        return nil, "rail child count is unavailable"
    end

    local count = 0
    for index = 0, childCount - 1 do
        local child = nil
        local childOk = pcall(function()
            child = parent:GetChildAt(index)
        end)
        local name = objectName(child)
        if childOk and name ~= nil and authored[name] ~= true
            and iconInsideWrapper(child) ~= nil then
            count = count + 1
        end
    end
    return count, nil
end

local function attachIconWithNativeWrapper(
    umgLibrary, controller, parent, icon
)
    local listClass = StaticFindObject(MAIN_MENU_LIST_CLASS)
    if not isValid(listClass) then
        error("native main-menu list class is unavailable")
    end

    local donorList = umgLibrary:Create(controller, listClass, controller)
    if not isValid(donorList) then
        error("native wrapper donor creation returned null")
    end

    local donorItem = donorList.Item_6
    local donorItemSlot = isValid(donorItem) and donorItem.Slot or nil
    local donorPanel =
        isValid(donorItemSlot) and donorItemSlot.Parent or nil
    if not isValid(donorItem)
        or not isValid(donorItemSlot)
        or not isValid(donorPanel) then
        error("native wrapper hierarchy is unavailable")
    end

    local donorLayout = donorItemSlot.LayoutData
    donorItem:RemoveFromParent()
    donorPanel:RemoveFromParent()
    parent:AddChildToVerticalBox(donorPanel)

    local iconSlot = donorPanel:AddChildToCanvas(icon)
    if not isValid(iconSlot) then
        error("native wrapper rejected the Fast Travel icon")
    end
    iconSlot:SetLayout(donorLayout)
    iconSlot:SetAutoSize(true)
    iconSlot:SetZOrder(20)
    icon:SetVisibility(VISIBLE)
    donorPanel:SetVisibility(VISIBLE)
    donorPanel:ForceLayoutPrepass()
    return donorList, donorPanel
end

local function applyLetterIcon(context)
    if context == nil
        or not isValid(context.wrapperPanel)
        or not isValid(context.icon)
        or not isValid(context.icon.IconImage)
        or not isValid(context.icon.MenuName) then
        return nil, "Fast Travel row presentation is incomplete"
    end

    local textBlockClass = StaticFindObject("/Script/UMG.TextBlock")
    if not isValid(textBlockClass) then
        return nil, "TextBlock class is unavailable"
    end

    local label = nil
    local built, buildError = pcall(function()
        label = StaticConstructObject(textBlockClass, context.icon)
        if not isValid(label) then
            error("TextBlock construction returned null")
        end
        label:SetText(FText("FT"))
        label:SetFont(context.icon.MenuName.Font)
        label:SetColorAndOpacity({
            SpecifiedColor = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
            ColorUseRule = 0,
        })

        local slot = context.wrapperPanel:AddChildToCanvas(label)
        if not isValid(slot) then
            error("native row wrapper rejected the FT label")
        end
        slot:SetAutoSize(true)
        slot:SetPosition({ X = 28.0, Y = 26.0 })
        slot:SetZOrder(30)
        label:SetVisibility(VISIBLE)
        label:SetRenderOpacity(1.0)
        context.icon.IconImage:SetVisibility(HIDDEN)
    end)
    if not built then
        if isValid(label) then
            pcall(function() label:RemoveFromParent() end)
        end
        return nil, tostring(buildError)
    end
    context.letterWidget = label
    return true, nil
end

local function enforceLetterIcon(context)
    if context == nil
        or not isValid(context.icon)
        or not isValid(context.icon.IconImage)
        or not isValid(context.letterWidget) then
        return nil, "FT letter presentation is no longer valid"
    end
    local ok, presentationError = pcall(function()
        context.icon.IconImage:SetVisibility(HIDDEN)
        context.letterWidget:SetVisibility(VISIBLE)
        context.letterWidget:SetRenderOpacity(1.0)
    end)
    if not ok then return nil, tostring(presentationError) end
    return true, nil
end

local function isCanonicalMainMenu(mainMenu)
    if not isValid(mainMenu)
        or not nameContains(mainMenu, MAIN_MENU_CLASS_FRAGMENT) then
        return false
    end

    local parentComponent = nil
    local parentActor = nil
    pcall(function()
        parentComponent = weakObject(mainMenu.ParentComponent)
        parentActor = weakObject(mainMenu.ParentActor)
    end)
    return isValid(parentComponent) or isValid(parentActor)
end

local function resolveConstructedMainMenu(menuKey)
    local ok, widgets = pcall(function()
        return FindAllOf(MAIN_MENU_CLASS_FRAGMENT)
    end)
    if not ok or type(widgets) ~= "table" then
        return nil, "exact main-menu object query failed"
    end
    for _, widget in ipairs(widgets) do
        if isCanonicalMainMenu(widget)
            and objectName(widget) == menuKey then
            return widget, nil
        end
    end
    return nil, "constructed main-menu object is no longer live"
end

local function injectFastTravelEntry(mainMenu)
    if not CONFIG.ENABLED then
        dbg("row injection skipped because the mod is disabled")
        return
    end
    if not runtimeHealthy then
        log("row injection refused: settings are not healthy")
        return
    end
    if not isCanonicalMainMenu(mainMenu) then
        log("row injection refused: object is not the canonical Start Menu")
        return
    end

    local menuKey = objectName(mainMenu)
    if menuKey == nil then
        log("row injection refused: Start Menu identity is unavailable")
        return
    end
    if injectedMenuKey == menuKey then
        dbg("row already injected into " .. menuKey)
        return
    end

    local controller, controllerError = resolveLocalController()
    local umgLibrary, umgError = resolveUmgLibrary()
    local textLibrary, textError = resolveTextLibrary()
    if controller == nil or umgLibrary == nil or textLibrary == nil then
        log("row injection failed closed: " ..
            tostring(controllerError or umgError or textError))
        return
    end

    local mainList = nil
    local firstItem = nil
    local firstWrapper = nil
    local parent = nil
    local hierarchyOk = pcall(function()
        mainList = mainMenu.MainMenu_List
        firstItem, firstWrapper = menuItemAndPanel(mainList, 0)
        parent = firstWrapper.Slot.Parent
    end)
    if not hierarchyOk
        or not isValid(mainList)
        or not isValid(firstItem)
        or not isValid(parent) then
        log("row injection failed closed: native rail hierarchy is unavailable")
        return
    end

    local nativeCount, countError =
        resolveNativeMenuCount(mainMenu, mainList)
    if nativeCount == nil then
        log("row injection failed closed: " .. tostring(countError))
        return
    end
    local lastItem = menuItemAndPanel(mainList, nativeCount - 1)
    if not isValid(lastItem) then
        log("row injection failed closed: final native item is unavailable")
        return
    end

    local rowsAbove, injectedError =
        countInjectedRows(parent, mainList)
    if rowsAbove == nil then
        log("row injection failed closed: " .. tostring(injectedError))
        return
    end
    local fastTravelIndex = nativeCount + rowsAbove

    local iconClass = StaticFindObject(MAIN_MENU_ICON_CLASS)
    if not isValid(iconClass) then
        log("row injection failed closed: native menu icon class is unavailable")
        return
    end

    local icon = nil
    local wrapperDonor = nil
    local wrapperPanel = nil
    local configured, configureError = xpcall(function()
        icon = umgLibrary:Create(controller, iconClass, controller)
        if not isValid(icon) then
            error("Fast Travel icon creation returned null")
        end

        wrapperDonor, wrapperPanel =
            attachIconWithNativeWrapper(
                umgLibrary, controller, parent, icon)

        icon:SetItemIndex(fastTravelIndex)
        icon:SetOwnerInputWidget(mainList)
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        icon:SetDefaultAnimation()

        local text = textLibrary:Conv_StringToText("Fast Travel")
        icon:SetMenuName(text)
        icon.MenuName:SetText(text)
    end, debug.traceback)
    if not configured then
        if isValid(wrapperPanel) then
            pcall(function() wrapperPanel:RemoveFromParent() end)
        end
        log("row injection failed closed: " .. tostring(configureError))
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
        rowsAbove = rowsAbove,
        fastTravelIndex = fastTravelIndex,
        firstInjected = rowsAbove == 0,
        icon = icon,
        iconKey = objectName(icon),
        wrapperDonor = wrapperDonor,
        wrapperPanel = wrapperPanel,
        wrapperParent = parent,
        failed = false,
    }

    local iconOk, iconError = applyLetterIcon(context)
    if iconOk ~= true then
        pcall(function() wrapperPanel:RemoveFromParent() end)
        log("row injection failed closed: " .. tostring(iconError))
        return
    end

    activeContext = context
    injectedMenuKey = menuKey
    listFocusIndexes = {}
    pendingFocusRedirects = {}
    menuCloseBusy = false

    local startingIndex = nil
    pcall(function()
        startingIndex = tonumber(mainList.CurrentIndex)
    end)
    listFocusIndexes[context.listKey] = startingIndex

    log(string.format(
        "Fast Travel row added at index %d (%d native, %d injected above)",
        fastTravelIndex, nativeCount, rowsAbove))

    ExecuteWithDelay(850, function()
        ExecuteInGameThread(function()
            if activeContext ~= context
                or not isValid(context.wrapperPanel) then
                return
            end
            local enforced, enforceError = enforceLetterIcon(context)
            if enforced ~= true then
                failCurrentMenu(
                    "post-animation icon validation failed: " ..
                    tostring(enforceError))
            end
        end)
    end)
end

local function focusIcon(context, icon, index)
    if context == nil or not isValid(icon) then
        return nil, "focus target is unavailable"
    end
    local focused, focusError = pcall(function()
        if type(index) == "number"
            and index >= 0
            and index < context.nativeCount then
            context.mainList.CurrentIndex = index
        end
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        icon["Set Current Animation"](icon)
        icon:BP_SetInputWidgetFocus()
        icon:SetFocus()
        icon:SetKeyboardFocus()
        local controller, controllerError = resolveLocalController()
        if controller == nil then error(controllerError) end
        icon:SetUserFocus(controller)
    end)
    if not focused then return nil, tostring(focusError) end
    return true, nil
end

local function resetNativeRows(context)
    for index = 0, context.nativeCount - 1 do
        local resetOk, resetError = pcall(function()
            context.mainList["Item_" .. tostring(index)]
                :SetDefaultAnimation()
        end)
        if not resetOk then
            return nil, "native row " .. tostring(index) ..
                " reset failed: " .. tostring(resetError)
        end
    end
    return true, nil
end

local function focusFastTravel(context)
    if context == nil or context.failed then return end
    local resetOk, resetError = resetNativeRows(context)
    if resetOk ~= true then
        failCurrentMenu(resetError)
        return
    end
    local focusOk, focusError =
        focusIcon(context, context.icon, context.fastTravelIndex)
    if focusOk ~= true then
        failCurrentMenu("Fast Travel focus failed: " ..
            tostring(focusError))
        return
    end
    local iconOk, iconError = enforceLetterIcon(context)
    if iconOk ~= true then
        failCurrentMenu("Fast Travel icon focus failed: " ..
            tostring(iconError))
    end
end

local function clearFastTravelSelection(context)
    if context == nil or not isValid(context.icon) then return end
    local ok, clearError = pcall(function()
        context.icon:SetDefaultAnimation()
    end)
    if not ok then
        failCurrentMenu("Fast Travel deselection failed: " ..
            tostring(clearError))
        return
    end
    local iconOk, iconError = enforceLetterIcon(context)
    if iconOk ~= true then
        failCurrentMenu("Fast Travel icon restore failed: " ..
            tostring(iconError))
    end
end

local function railIconsRelativeToOwn(context)
    local parent = context.wrapperParent
    if not isValid(parent) or not isValid(context.wrapperPanel) then
        return nil, nil, "rail wrapper is unavailable"
    end
    local authored = authoredWrapperNames(context.mainList)

    local childCount = nil
    local countOk, countError = pcall(function()
        childCount = parent:GetChildrenCount()
    end)
    if not countOk or type(childCount) ~= "number" then
        return nil, nil, "rail child count failed: " ..
            tostring(countError)
    end

    local before = {}
    local after = {}
    local ownSeen = false
    local ownName = objectName(context.wrapperPanel)
    for index = 0, childCount - 1 do
        local wrapper = nil
        local childOk = pcall(function()
            wrapper = parent:GetChildAt(index)
        end)
        if not childOk or not isValid(wrapper) then
            return nil, nil, "rail child " .. tostring(index) ..
                " is unavailable"
        end
        if objectName(wrapper) == ownName then
            ownSeen = true
        else
            local icon = iconInsideWrapper(wrapper)
            local wrapperName = objectName(wrapper)
            if icon ~= nil and authored[wrapperName] ~= true then
                local target = ownSeen and after or before
                target[#target + 1] = icon
            end
        end
    end
    if not ownSeen then
        return nil, nil, "Fast Travel wrapper is detached"
    end
    return before, after, nil
end

local function focusRowAbove(context)
    clearFastTravelSelection(context)
    local before, _, railError = railIconsRelativeToOwn(context)
    if before == nil then
        failCurrentMenu(railError)
        return
    end
    local target = before[#before]
    local targetIndex = context.fastTravelIndex - 1
    if target == nil then
        target = context.lastItem
        targetIndex = context.nativeCount - 1
    end
    local ok, focusError = focusIcon(context, target, targetIndex)
    if ok ~= true then
        failCurrentMenu("row-above focus failed: " ..
            tostring(focusError))
    end
end

local function focusRowBelow(context)
    clearFastTravelSelection(context)
    local _, after, railError = railIconsRelativeToOwn(context)
    if after == nil then
        failCurrentMenu(railError)
        return
    end
    local target = after[1]
    local targetIndex = context.fastTravelIndex + 1
    if target == nil then
        target = context.firstItem
        targetIndex = 0
    end
    local ok, focusError = focusIcon(context, target, targetIndex)
    if ok ~= true then
        failCurrentMenu("row-below focus failed: " ..
            tostring(focusError))
    end
end

local function focusLastInjected(context)
    local _, after, railError = railIconsRelativeToOwn(context)
    if after == nil then
        failCurrentMenu(railError)
        return
    end
    if after[#after] == nil then
        focusFastTravel(context)
        return
    end
    clearFastTravelSelection(context)
    local targetIndex =
        context.fastTravelIndex + #after
    local ok, focusError =
        focusIcon(context, after[#after], targetIndex)
    if ok ~= true then
        failCurrentMenu("last injected row focus failed: " ..
            tostring(focusError))
    end
end

local function isFastTravelIcon(widget)
    return activeContext ~= nil
        and isValid(widget)
        and objectName(widget) == activeContext.iconKey
end

local function withInputLock(action)
    if inputLocked then return end
    inputLocked = true
    ExecuteWithDelay(60, function() inputLocked = false end)
    action()
end

local function consumeButton(buttonParameter)
    local consumed, consumeError = pcall(function()
        buttonParameter:set(0)
    end)
    if not consumed then
        failCurrentMenu("input consumption failed: " ..
            tostring(consumeError))
        return false
    end
    return true
end

local function isPresentedTeleportMapWidget(widget)
    if not isValid(widget)
        or not nameContains(widget, MAP_WIDGET_FRAGMENT) then
        return false
    end

    local inViewport = false
    pcall(function() inViewport = widget:IsInViewport() == true end)
    if inViewport then return true end

    local component = nil
    pcall(function()
        component = weakObject(widget.ParentComponent)
    end)
    if not isValid(component) then return false end

    local mounted = nil
    local mountedOk = pcall(function()
        mounted = component:GetWidget()
    end)
    return mountedOk
        and isValid(mounted)
        and objectName(mounted) == objectName(widget)
end

local function failPendingOpen(serial, reason)
    if serial ~= nil and serial ~= openSerial then return end
    local abilityToCancel = pendingMapAbility
    pendingMapAbility = nil
    if isValid(abilityToCancel) then
        local active = false
        local activeOk = pcall(function()
            active = abilityToCancel:BP_IsActive() == true
        end)
        if activeOk and active then
            local cancelOk, cancelError = pcall(function()
                abilityToCancel:K2_CancelAbility()
            end)
            if cancelOk then
                log("map ability rollback completed")
            else
                log("MAP ABILITY ROLLBACK ERROR | " ..
                    tostring(cancelError))
            end
        end
    end
    openBusy = false
    teleportMapModeActive = false
    mapTeleportBusy = false
    mapIconDestinations = {}
    teleportMapWidgetKey = nil
    openSerial = openSerial + 1
    log("FAST TRAVEL ERROR | " .. tostring(reason))
end

local function verifyTeleportMapOpen(serial)
    if serial ~= openSerial then return end
    local ok, widgets = pcall(function()
        return FindAllOf(MAP_WIDGET_FRAGMENT)
    end)
    if not ok or type(widgets) ~= "table" then
        failPendingOpen(
            serial,
            "WBP_Map_C was not constructed")
        return
    end

    local presented = {}
    for _, widget in ipairs(widgets) do
        if isPresentedTeleportMapWidget(widget) then
            presented[#presented + 1] = widget
        end
    end
    if #presented ~= 1 then
        failPendingOpen(serial, string.format(
            "expected one presented %s, found %d",
            MAP_WIDGET_FRAGMENT, #presented))
        return
    end
    openBusy = false
    pendingMapAbility = nil
    teleportMapWidgetKey = objectName(presented[1])
    teleportMapModeActive = true
    log("teleport map presented; select an eligible icon and confirm")
end

local function activateTeleportMapAbility(serial, contract)
    if serial ~= openSerial then return end

    local activated = nil
    local activationOk, activationError = pcall(function()
        activated =
            contract.abilitySystem:
                TryActivateAbilityWithPayloadFromClass(
                contract.mapAbilityClass,
                contract.mapAbilityTriggerTag,
                contract.mapAbilityPayload)
    end)
    if not activationOk then
        failPendingOpen(
            serial,
            "map gameplay ability activation failed: " ..
                tostring(activationError))
        return
    end
    if activated ~= true then
        failPendingOpen(
            serial,
            "map gameplay event activation was rejected: " ..
                contract.mapAbilityTriggerTagName)
        return
    end

    pendingMapAbility = contract.mapAbility
    log("map gameplay ability activated | ability=" ..
        tostring(objectName(contract.mapAbility)) ..
        " | class=" .. contract.mapAbilityClassName ..
        " | trigger=" .. contract.mapAbilityTriggerTagName)
    local scheduled, scheduleError = pcall(function()
        ExecuteWithDelay(
            OPEN_VERIFICATION_DELAY_MS,
            function()
                ExecuteInGameThread(function()
                    verifyTeleportMapOpen(serial)
                end)
            end)
    end)
    if not scheduled then
        failPendingOpen(
            serial,
            "map verification scheduling failed: " ..
                tostring(scheduleError))
    end
end

local function waitForMainMenuAbilityEnd(
    serial, contract, elapsedMs
)
    if serial ~= openSerial then return end

    local transitionOk, transitionError = xpcall(function()
        local mainMenuActive =
            isOwnedAbilityClassActive(
                MAIN_MENU_ABILITY_CLASS,
                contract.abilitySystem)
        if not mainMenuActive then
            activateTeleportMapAbility(serial, contract)
            return
        end

        if elapsedMs >= MENU_TRANSITION_TIMEOUT_MS then
            error(MAIN_MENU_ABILITY_CLASS .. " remained active for " ..
                tostring(elapsedMs) .. " ms")
        end

        ExecuteWithDelay(MENU_TRANSITION_POLL_MS, function()
            ExecuteInGameThread(function()
                waitForMainMenuAbilityEnd(
                    serial,
                    contract,
                    elapsedMs + MENU_TRANSITION_POLL_MS)
            end)
        end)
    end, debug.traceback)
    if not transitionOk then
        failPendingOpen(
            serial,
            "menu ability transition failed: " ..
                tostring(transitionError))
    end
end

local function requestFastTravelOpen(source)
    if not CONFIG.ENABLED or not runtimeHealthy then
        log("Fast Travel open refused: mod is disabled")
        return
    end
    if openBusy then
        log("Fast Travel open refused: map opening is already pending")
        return
    end
    if teleportMapModeActive then
        log("Fast Travel open refused: teleport map is already active")
        return
    end

    local controller, controllerError = resolveLocalController()
    if controller == nil then
        log("Fast Travel open failed closed: " ..
            tostring(controllerError))
        return
    end

    openBusy = true
    openSerial = openSerial + 1
    local serial = openSerial
    teleportMapWidgetKey = nil
    mapTeleportBusy = false
    mapIconDestinations = {}
    pendingMapAbility = nil

    local state = nil
    local stateOk, stateError =
        xpcall(function()
            local recovered =
                recoverCompletedNativeTravel("before teleport map")
            state = logNativeTravelState("before teleport map")
            if state.fastTravelStatus == FAST_TRAVEL_STATUS_DECIDE
                and recovered ~= true then
                error("a native Fast Travel transaction is still active")
            end
            if state.accessibleStatus ~= ACCESSIBLE_STATUS_NONE
                or state.accessingTerminal ~= false then
                error(string.format(
                    "terminal interaction is active | PSAcsGmkStatus=%d | bAccessingTerminal=%s",
                    state.accessibleStatus,
                    tostring(state.accessingTerminal)))
            end
        end, debug.traceback)
    if not stateOk then
        failPendingOpen(
            serial,
            "teleport map precondition failed: " .. tostring(stateError))
        return
    end

    local abilityContract, abilityContractError =
        resolveMapAbilityContract()
    if abilityContract == nil then
        failPendingOpen(
            serial,
            "map ability contract unavailable: " ..
                tostring(abilityContractError))
        return
    end

    local alreadyActiveOk, alreadyActiveError = xpcall(function()
        local mapMenuActive =
            isOwnedAbilityClassActive(
                MAP_MENU_ABILITY_CLASS,
                abilityContract.abilitySystem)
        if mapMenuActive then
            error(MAP_MENU_ABILITY_CLASS .. " is already active")
        end
    end, debug.traceback)
    if not alreadyActiveOk then
        failPendingOpen(
            serial,
            "map ability precondition failed: " ..
                tostring(alreadyActiveError))
        return
    end

    teleportMapModeActive = true
    log("closing Start Menu before teleport map | source=" ..
        tostring(source))
    local closed, closeError = pcall(function()
        controller:EndMainMenu(true)
    end)
    if not closed then
        failPendingOpen(
            serial,
            "EndMainMenu(true) failed: " .. tostring(closeError))
        return
    end

    log("waiting for " .. MAIN_MENU_ABILITY_CLASS .. " to end")
    waitForMainMenuAbilityEnd(serial, abilityContract, 0)
end

local function scheduleFastTravelOpen(source)
    local scheduled, scheduleError = pcall(function()
        ExecuteWithDelay(0, function()
            ExecuteInGameThread(function()
                requestFastTravelOpen(source)
            end)
        end)
    end)
    if not scheduled then
        log("teleport map scheduling failed: " ..
            tostring(scheduleError))
    end
end

local function resolveSelectedMapIcon(mapWidget)
    if not isValid(mapWidget)
        or not nameContains(mapWidget, MAP_WIDGET_FRAGMENT) then
        error("exact WBP_Map_C teleport map is unavailable")
    end

    local mapItemWidget = nil
    local iconPointer = nil
    local readOk, readError = pcall(function()
        mapItemWidget = mapWidget.MapItemWidget
        if not isValid(mapItemWidget) then
            error("MapItemWidget is unavailable")
        end
        iconPointer = mapItemWidget.CurrentTargetIconWidget
    end)
    if not readOk then
        error("selected map icon read failed: " ..
            tostring(readError))
    end

    local iconWidget = weakObject(iconPointer)
    if not isValid(iconWidget) then
        error("no map icon is selected; hover or focus a checkpoint/pin")
    end

    local iconClass =
        StaticFindObject("/Script/ROD.RODIconForMapWidgetBase")
    if not isValid(iconClass) then
        error("RODIconForMapWidgetBase class fingerprint is unavailable")
    end
    local classOk, isMapIcon = pcall(function()
        return iconWidget:IsA(iconClass)
    end)
    if not classOk or isMapIcon ~= true then
        error("selected widget is not RODIconForMapWidgetBase")
    end

    local kind = nil
    local canHover = nil
    local kindOk, kindError = pcall(function()
        kind = tonumber(iconWidget:GetMapIconKind())
        canHover = iconWidget:GetCanHoverIcon()
    end)
    if not kindOk or kind == nil
        or type(canHover) ~= "boolean" then
        error("selected map icon metadata failed: " ..
            tostring(kindError))
    end
    if canHover ~= true then
        error("selected map icon is not hoverable")
    end

    local kindName = ELIGIBLE_MAP_ICON_KINDS[kind]
    if kindName == nil then
        error("map icon kind " .. tostring(kind) ..
            " is not an eligible checkpoint/pin destination")
    end
    local iconKey = objectName(iconWidget)
    if iconKey == nil then
        error("selected map icon identity is unavailable")
    end
    local destination = mapIconDestinations[iconKey]
    if destination == nil then
        error("selected map icon has no canonical UpdateIcon destination")
    end
    if destination.kind ~= kind then
        error(string.format(
            "selected map icon kind mismatch: selected=%d cached=%d",
            kind, destination.kind))
    end
    return iconWidget, kind, kindName, destination
end

local function finalizeMapTeleport(source)
    local finalizeOk, finalizeError = xpcall(function()
        restorePlayableCamera(source)
    end, debug.traceback)

    teleportMapModeActive = false
    mapTeleportBusy = false
    mapIconDestinations = {}
    openBusy = false
    teleportMapWidgetKey = nil
    openSerial = openSerial + 1

    if not finalizeOk then
        failCurrentMenu("teleport finalization failed: " ..
            tostring(finalizeError))
        return
    end
    log("map teleport completed and camera returned to gameplay")
end

local function requestSelectedMapTeleport(mapWidget, source)
    if not teleportMapModeActive then
        mapTeleportBusy = false
        log("FAST TRAVEL ERROR | teleport map mode is not active")
        return
    end

    local iconWidget = nil
    local iconKind = nil
    local iconKindName = nil
    local destination = nil
    local selectionOk, selectionError = xpcall(function()
        iconWidget, iconKind, iconKindName, destination =
            resolveSelectedMapIcon(mapWidget)
    end, debug.traceback)
    if not selectionOk then
        mapTeleportBusy = false
        log("FAST TRAVEL ERROR | " .. tostring(selectionError))
        return
    end

    log(string.format(
        "teleporting to selected map icon | kind=%s(%d) | pos=(%.3f, %.3f, %.3f) | widget=%s",
        iconKindName,
        iconKind,
        destination.position.X,
        destination.position.Y,
        destination.position.Z,
        tostring(objectName(iconWidget))))

    local hero, heroError = resolveLocalHero()
    if hero == nil then
        mapTeleportBusy = false
        log("FAST TRAVEL ERROR | " .. tostring(heroError))
        return
    end
    local teleported, teleportError = pcall(function()
        hero:ServerDebugTeleportGimmick(destination.position)
    end)
    if not teleported then
        mapTeleportBusy = false
        log("FAST TRAVEL ERROR | ServerDebugTeleportGimmick failed: " ..
            tostring(teleportError))
        return
    end

    local closed, closeError = pcall(function()
        if isPresentedTeleportMapWidget(mapWidget) then
            local controller, controllerError =
                resolveLocalController()
            if controller == nil then error(controllerError) end
            controller:EndMapMenu(MENU_END_ALL_CLOSE)
        end
    end)
    if not closed then
        mapTeleportBusy = false
        failCurrentMenu("teleport map close failed: " ..
            tostring(closeError))
        return
    end

    local scheduled, scheduleError = pcall(function()
        ExecuteWithDelay(TELEPORT_FINALIZE_DELAY_MS, function()
            ExecuteInGameThread(function()
                finalizeMapTeleport(source)
            end)
        end)
    end)
    if not scheduled then
        mapTeleportBusy = false
        failCurrentMenu("teleport finalization scheduling failed: " ..
            tostring(scheduleError))
    end
end

local function interceptMapTeleport(
    mapParameter, buttonParameter, clickTypeParameter, source
)
    if not teleportMapModeActive then return end

    local mapWidget = hookValue(mapParameter)
    if not isValid(mapWidget)
        or not nameContains(mapWidget, MAP_WIDGET_FRAGMENT) then
        return
    end

    local button = tonumber(hookValue(buttonParameter))
    if button ~= ACCEPT_BUTTON then return end
    if clickTypeParameter ~= nil then
        local clickType = tonumber(hookValue(clickTypeParameter))
        if clickType ~= SINGLE_CLICK then return end
    end

    if not consumeButton(buttonParameter) then return end
    if mapTeleportBusy then return end
    mapTeleportBusy = true

    local scheduled, scheduleError = pcall(function()
        ExecuteWithDelay(0, function()
            ExecuteInGameThread(function()
                requestSelectedMapTeleport(mapWidget, source)
            end)
        end)
    end)
    if not scheduled then
        mapTeleportBusy = false
        failCurrentMenu("selected map teleport scheduling failed: " ..
            tostring(scheduleError))
    end
end

local function cacheMapIconDestination(
    mapParameter,
    kindParameter,
    actorParameter,
    locationParameter,
    iconParameter
)
    if not teleportMapModeActive then return end

    local mapWidget = hookValue(mapParameter)
    if not isValid(mapWidget)
        or not nameContains(mapWidget, MAP_WIDGET_FRAGMENT) then
        return
    end

    local kind = tonumber(hookValue(kindParameter))
    if kind == nil then
        error("UpdateIcon EMapIconKind decode failed")
    end
    if ELIGIBLE_MAP_ICON_KINDS[kind] == nil then return end

    local iconWidget = hookValue(iconParameter)
    local iconKey = objectName(iconWidget)
    if iconKey == nil then
        error("UpdateIcon icon widget identity is unavailable")
    end

    local location = hookValue(locationParameter)
    local x = tonumber(location.X)
    local y = tonumber(location.Y)
    local z = tonumber(location.Z)
    if x == nil or y == nil or z == nil then
        error("UpdateIcon world position decode failed")
    end

    local actor = hookValue(actorParameter)
    mapIconDestinations[iconKey] = {
        kind = kind,
        position = { X = x, Y = y, Z = z },
        actor = isValid(actor) and objectName(actor) or nil,
    }
    dbg(string.format(
        "cached map destination | kind=%s(%d) | pos=(%.3f, %.3f, %.3f) | actor=%s",
        ELIGIBLE_MAP_ICON_KINDS[kind],
        kind,
        x,
        y,
        z,
        tostring(mapIconDestinations[iconKey].actor or "<none>")))
end

local function closeMainMenuFromFastTravel()
    if menuCloseBusy then return end
    menuCloseBusy = true

    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            local controller, controllerError = resolveLocalController()
            local rodLibrary, libraryError = resolveRodWidgetLibrary()
            if controller == nil or rodLibrary == nil then
                menuCloseBusy = false
                failCurrentMenu(controllerError or libraryError)
                return
            end
            local closed, closeError = pcall(function()
                rodLibrary:EndMenu(controller)
            end)
            if not closed then
                menuCloseBusy = false
                failCurrentMenu("Start Menu close failed: " ..
                    tostring(closeError))
            end
        end)
    end)
end

local function handleButton(widgetParameter, buttonParameter)
    local widget = hookValue(widgetParameter)
    local button = hookValue(buttonParameter)
    if not isValid(widget) then return end

    if isFastTravelIcon(widget) then
        if button == ACCEPT_BUTTON then
            if consumeButton(buttonParameter) then
                scheduleFastTravelOpen("Start Menu")
            end
        elseif button == BACK_BUTTON then
            if consumeButton(buttonParameter) then
                closeMainMenuFromFastTravel()
            end
        elseif button == DPAD_UP or button == LSTICK_UP then
            if consumeButton(buttonParameter) then
                withInputLock(function()
                    focusRowAbove(activeContext)
                end)
            end
        elseif button == DPAD_DOWN or button == LSTICK_DOWN then
            if consumeButton(buttonParameter) then
                withInputLock(function()
                    focusRowBelow(activeContext)
                end)
            end
        end
        return
    end

    local context = activeContext
    if context == nil or context.failed
        or context.firstInjected ~= true
        or not nameContains(widget, MAIN_MENU_LIST_FRAGMENT) then
        return
    end

    local index = nil
    pcall(function() index = widget:GetItemIndex() end)
    if type(index) ~= "number" then return end

    local down = button == DPAD_DOWN or button == LSTICK_DOWN
    local up = button == DPAD_UP or button == LSTICK_UP
    if down and index == context.nativeCount - 1 then
        if consumeButton(buttonParameter) then
            withInputLock(function() focusFastTravel(context) end)
        end
    elseif up and index == 0 then
        if consumeButton(buttonParameter) then
            withInputLock(function() focusLastInjected(context) end)
        end
    end
end

local function guardedHookCallback(label, callback)
    return function(...)
        local ok, callbackError =
            xpcall(callback, debug.traceback, ...)
        if not ok then
            failCurrentMenu(label .. " hook failed: " ..
                tostring(callbackError))
        end
    end
end

local function requireHook(path, callback, postCallback)
    local ok, hookError = pcall(function()
        if postCallback ~= nil then
            RegisterHook(path, callback, postCallback)
        else
            RegisterHook(path, callback)
        end
    end)
    if not ok then
        error("[" .. MOD_NAME .. "] required hook unavailable: " ..
            path .. " / " .. tostring(hookError))
    end
end

requireHook(
    "/Script/ROD.RODConsoleMainMenuWidgetBase:OnButtonDownMenuItemDelegate",
    guardedHookCallback("main-menu button", function(
        _, widgetParameter, buttonParameter
    )
        handleButton(widgetParameter, buttonParameter)
    end)
)

requireHook(
    "/Script/ROD.RODInputWidgetBase:OnInputButtonDown",
    guardedHookCallback("input widget button", function(
        _, widgetParameter, buttonParameter
    )
        handleButton(widgetParameter, buttonParameter)
    end)
)

requireHook(
    "/Script/ROD.RODListWidgetBase:ButtonDownEvent",
    guardedHookCallback("list button", function(
        _, widgetParameter, buttonParameter
    )
        handleButton(widgetParameter, buttonParameter)
    end)
)

requireHook(
    "/Script/ROD.RODListWidgetBase:FocusEvent",
    guardedHookCallback("list focus pre", function(
        selfParameter, widgetParameter
    )
        local context = activeContext
        local list = hookValue(selfParameter)
        local listKey = objectName(list)
        if listKey == nil then return end

        if context == nil or context.failed
            or listKey ~= context.listKey then
            pendingFocusRedirects[listKey] = nil
            return
        end

        local widget = hookValue(widgetParameter)
        if not isValid(widget) then return end
        if not isFastTravelIcon(widget) then
            clearFastTravelSelection(context)
        end

        local index = nil
        pcall(function() index = widget:GetItemIndex() end)
        if type(index) ~= "number" then return end

        local previousIndex = listFocusIndexes[listKey]
        listFocusIndexes[listKey] = index
        if context.firstInjected ~= true then return end

        local wrappedDown =
            previousIndex == context.nativeCount - 1 and index == 0
        local wrappedUp =
            previousIndex == 0 and index == context.nativeCount - 1
        if wrappedDown then
            pendingFocusRedirects[listKey] = "down"
        elseif wrappedUp then
            pendingFocusRedirects[listKey] = "up"
        end
    end),
    guardedHookCallback("list focus post", function(selfParameter)
        local list = hookValue(selfParameter)
        local listKey = objectName(list)
        if listKey == nil then return end
        local direction = pendingFocusRedirects[listKey]
        pendingFocusRedirects[listKey] = nil
        if direction == nil
            or activeContext == nil
            or activeContext.failed then
            return
        end
        if direction == "down" then
            focusFastTravel(activeContext)
        elseif direction == "up" then
            focusLastInjected(activeContext)
        end
    end)
)

local function handleClick(widgetParameter, buttonParameter)
    local widget = hookValue(widgetParameter)
    if not isFastTravelIcon(widget) then return end
    if consumeButton(buttonParameter) then
        scheduleFastTravelOpen("Start Menu click")
    end
end

requireHook(
    "/Script/ROD.RODListWidgetBase:ClickEvent",
    guardedHookCallback("list click", function(
        _, widgetParameter, buttonParameter, _
    )
        handleClick(widgetParameter, buttonParameter)
    end)
)

requireHook(
    "/Script/ROD.RODConsoleMainMenuWidgetBase:OnClickMenuItemDelegate",
    guardedHookCallback("main-menu click", function(
        _, widgetParameter, buttonParameter
    )
        handleClick(widgetParameter, buttonParameter)
    end)
)

requireHook(
    "/Script/ROD.RODInGamePlayerController:OpenDirectingMapMenu",
    guardedHookCallback("directing map open", function(selfParameter)
        if not teleportMapModeActive then return end
        local controller = hookValue(selfParameter)
        if not isLocalWorldController(controller) then return end
        log("native OpenDirectingMapMenu entered")
    end)
)

requireHook(
    "/Script/ROD.RODInGamePlayerController:DisplayMapMenu",
    guardedHookCallback("map display", function(
        selfParameter, overlapParameter
    )
        if not teleportMapModeActive then return end
        local controller = hookValue(selfParameter)
        if not isLocalWorldController(controller) then return end
        local overlap = hookValue(overlapParameter)
        if type(overlap) ~= "boolean" then
            error("DisplayMapMenu overlap flag decode failed")
        end
        log("native DisplayMapMenu entered | overlapTerminalIcon=" ..
            tostring(overlap))
    end)
)

requireHook(
    "/Script/ROD.RODMapMenuWidgetBase:UpdateIcon",
    guardedHookCallback("map destination cache", function(
        selfParameter,
        kindParameter,
        actorParameter,
        locationParameter,
        iconParameter
    )
        cacheMapIconDestination(
            selfParameter,
            kindParameter,
            actorParameter,
            locationParameter,
            iconParameter)
    end)
)

requireHook(
    "/Script/ROD.RODMapMenuWidgetBase:MapDecidedEvent",
    guardedHookCallback("map decided", function(
        selfParameter, buttonParameter
    )
        interceptMapTeleport(
            selfParameter,
            buttonParameter,
            nil,
            "MapDecidedEvent")
    end)
)

requireHook(
    "/Script/ROD.RODMapMenuWidgetBase:MapClickEvent",
    guardedHookCallback("map click", function(
        selfParameter,
        _,
        buttonParameter,
        clickTypeParameter
    )
        interceptMapTeleport(
            selfParameter,
            buttonParameter,
            clickTypeParameter,
            "MapClickEvent")
    end)
)

requireHook(
    "/Script/Engine.PlayerController:ClientRestart",
    guardedHookCallback("ClientRestart", function(selfParameter)
        local controller = hookValue(selfParameter)
        if not isLocalWorldController(controller) then return end
        openBusy = false
        teleportMapModeActive = false
        mapTeleportBusy = false
        mapIconDestinations = {}
        openSerial = openSerial + 1
        teleportMapWidgetKey = nil
        dbg("native restart completed; teleport map state cleared")
    end)
)

requireHook(
    "/Script/ROD.RODMenuWidgetBase:ClosedMenu",
    guardedHookCallback("ClosedMenu", function(selfParameter)
        local widget = hookValue(selfParameter)
        if isValid(widget)
            and nameContains(widget, MAP_WIDGET_FRAGMENT) then
            teleportMapWidgetKey = nil
            openBusy = false
            teleportMapModeActive = false
            mapTeleportBusy = false
            mapIconDestinations = {}
            openSerial = openSerial + 1
            dbg("teleport map closed")
        end
    end)
)

local notifyTeleportMapOk, notifyTeleportMapError = pcall(function()
    NotifyOnNewObject(
        "/Script/ROD.RODMapMenuWidgetBase",
        function(widget)
            if isValid(widget)
                and nameContains(widget, MAP_WIDGET_FRAGMENT) then
                teleportMapWidgetKey = objectName(widget)
                dbg("constructed " .. tostring(teleportMapWidgetKey))
            end
        end
    )
end)
if not notifyTeleportMapOk then
    error("[" .. MOD_NAME ..
        "] canonical teleport map widget notification failed: " ..
        tostring(notifyTeleportMapError))
end

local notifyMainMenuOk, notifyMainMenuError = pcall(function()
    NotifyOnNewObject(
        "/Script/ROD.RODConsoleMainMenuWidgetBase",
        function(mainMenu)
            if not isValid(mainMenu)
                or not nameContains(
                    mainMenu, MAIN_MENU_CLASS_FRAGMENT) then
                return
            end
            local menuKey = objectName(mainMenu)
            if menuKey == nil
                or pendingInjectionKeys[menuKey] == true then
                return
            end
            pendingInjectionKeys[menuKey] = true

            ExecuteWithDelay(MENU_INJECTION_DELAY_MS, function()
                pendingInjectionKeys[menuKey] = nil
                ExecuteInGameThread(function()
                    local resolved, resolveError =
                        resolveConstructedMainMenu(menuKey)
                    if resolved == nil then
                        log("Start Menu injection failed closed: " ..
                            tostring(resolveError))
                        return
                    end
                    injectFastTravelEntry(resolved)
                end)
            end)
        end
    )
end)
if not notifyMainMenuOk then
    error("[" .. MOD_NAME ..
        "] canonical Start Menu notification failed: " ..
        tostring(notifyMainMenuError))
end

local function logNameArray(label, values)
    local count = nil
    local countOk, countError = pcall(function()
        count = #values
    end)
    if not countOk or type(count) ~= "number" then
        error(label .. " count failed: " .. tostring(countError))
    end
    log(string.format("%s (%d)", label, count))
    for index = 1, count do
        local value = nil
        local valueOk, valueError = pcall(function()
            value = values[index]
        end)
        if not valueOk then
            error(label .. "[" .. tostring(index) ..
                "] failed: " .. tostring(valueError))
        end
        log(string.format(
            "  [%d] %s",
            index,
            exactFNameString(
                value, label .. "[" .. tostring(index) .. "]")))
    end
end

local function logTerminalCatalog()
    local gameState, gameStateError = resolveWorldGameState()
    if gameState == nil then error(gameStateError) end

    log("TERMINAL CATALOG BEGIN")
    log("  CheckPointID=" ..
        exactFNameString(gameState.CheckPointID, "CheckPointID"))
    logNameArray(
        "CurrentActivatedTerminalIDs",
        gameState.CurrentActivatedTerminalIDs)
    logNameArray(
        "FloorActivatedTerminalIDs",
        gameState.FloorActivatedTerminalIDs)
    logNameArray(
        "AvailableTerminalIDs",
        gameState.AvailableTerminalIDs)
    logNameArray(
        "SavedCheckpointIDs",
        gameState.SavedCheckpointIDs)
    log("TERMINAL CATALOG END")
end

local function logPinCatalog()
    local gameState, gameStateError = resolveWorldGameState()
    if gameState == nil then error(gameStateError) end

    local pins = gameState.MapPins
    local count = #pins
    log(string.format("PIN CATALOG BEGIN (%d)", count))
    for index = 1, count do
        local pin = pins[index]
        if pin == nil then
            error("MapPins[" .. tostring(index) .. "] is unavailable")
        end
        local position = pin.Pos
        local actorName = objectName(pin.Actor)
        log(string.format(
            "  [%d] kind=%s pos=(%.3f, %.3f, %.3f) actor=%s timestamp=%s",
            index,
            tostring(pin.Kind),
            tonumber(position.X),
            tonumber(position.Y),
            tonumber(position.Z),
            tostring(actorName or "<none>"),
            tostring(pin.Timestamp)))
    end
    log("PIN CATALOG END")
end

local commandOk, commandError = pcall(function()
    RegisterConsoleCommandHandler(
        "fasttravel",
        function(_, params, ar)
            local function reply(message)
                ar:Log(tostring(message))
            end
            local subcommand =
                params[1] and string.lower(tostring(params[1]))
                or "status"

            if subcommand == "status" then
                reply(string.format(
                    "%s %s | sdk=%s | enabled=%s | healthy=%s | opening=%s | teleportMode=%s | teleporting=%s | widget=%s | lastNativeFastTravel=%s | lastAccessible=%s | lastAccessingTerminal=%s | lastGimmickId=%s",
                    MOD_NAME,
                    MOD_VERSION,
                    SUPPORTED_SDK,
                    tostring(CONFIG.ENABLED),
                    tostring(runtimeHealthy),
                    tostring(openBusy),
                    tostring(teleportMapModeActive),
                    tostring(mapTeleportBusy),
                    tostring(teleportMapWidgetKey),
                    tostring(lastNativeFastTravelStatus),
                    tostring(lastNativeAccessibleStatus),
                    tostring(lastNativeAccessingTerminal),
                    tostring(lastNativeAccessibleGimmickId)))
                scheduleNativeTravelState("console status", 0)
                reply(
                    "Exact native state snapshot scheduled; see the UE4SS console.")
                return true
            end

            if subcommand == "open" then
                reply(
                    "Teleport map opening scheduled; see the UE4SS console.")
                scheduleFastTravelOpen("console")
                return true
            end

            if subcommand == "terminals" then
                reply(
                    "Terminal catalog scheduled; output goes to the UE4SS console.")
                ExecuteInGameThread(function()
                    local ok, catalogError =
                        xpcall(logTerminalCatalog, debug.traceback)
                    if not ok then
                        log("TERMINAL CATALOG ERROR | " ..
                            tostring(catalogError))
                    end
                end)
                return true
            end

            if subcommand == "pins" then
                reply(
                    "Pin catalog scheduled; output goes to the UE4SS console.")
                ExecuteInGameThread(function()
                    local ok, catalogError =
                        xpcall(logPinCatalog, debug.traceback)
                    if not ok then
                        log("PIN CATALOG ERROR | " ..
                            tostring(catalogError))
                    end
                end)
                return true
            end

            reply(
                "Usage: fasttravel status | open | terminals | pins")
            return true
        end
    )
end)
if not commandOk then
    error("[" .. MOD_NAME ..
        "] console command registration failed: " ..
        tostring(commandError))
end

do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = applySettings,
        apply = function()
            if not CONFIG.ENABLED then
                openBusy = false
                teleportMapModeActive = false
                mapTeleportBusy = false
                mapIconDestinations = {}
                teleportMapWidgetKey = nil
                openSerial = openSerial + 1
            end
            if activeContext ~= nil then
                if CONFIG.ENABLED then
                    setContextVisibility(activeContext, VISIBLE)
                else
                    clearFastTravelSelection(activeContext)
                    local focusOk, focusError =
                        focusIcon(activeContext,
                            activeContext.firstItem, 0)
                    if focusOk ~= true then
                        failCurrentMenu(
                            "disable focus transfer failed: " ..
                            tostring(focusError))
                        return
                    end
                    setContextVisibility(activeContext, COLLAPSED)
                end
            end
        end,
        fail = function(reason)
            runtimeHealthy = false
            CONFIG.ENABLED = false
            openBusy = false
            teleportMapModeActive = false
            mapTeleportBusy = false
            mapIconDestinations = {}
            teleportMapWidgetKey = nil
            openSerial = openSerial + 1
            if activeContext ~= nil then
                setContextVisibility(activeContext, COLLAPSED)
            end
            log("CONFIG ERROR | " .. tostring(reason) ..
                " | mod disabled")
        end,
        log = log,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " ..
            tostring(attachmentError))
    end
end

local startupCleanupOk, startupCleanupError = pcall(function()
    ExecuteWithDelay(500, function()
        ExecuteInGameThread(function()
            local cleanupOk, cleanupError = xpcall(function()
                recoverCompletedNativeTravel("mod startup")
            end, debug.traceback)
            if not cleanupOk then
                dbg("startup native travel cleanup skipped: " ..
                    tostring(cleanupError))
            end
        end)
    end)
end)
if not startupCleanupOk then
    error("[" .. MOD_NAME ..
        "] startup cleanup scheduling failed: " ..
        tostring(startupCleanupError))
end

log(string.format(
    "loaded %s | SDK contract: %s | console: fasttravel status",
    MOD_VERSION, SUPPORTED_SDK))
