-- FastTravelMod v0.15.3
--
-- TWO MAPS, ONE OF THEM WRONG
--
-- The game has two map screens and they are not interchangeable:
--
--   WBP_Map_C            : URODMapMenuWidgetBase    -- the reference map, headed
--                          "Mapa / Detalhes da Area de Missao". Opened by the
--                          GA_AvatarMenu_Map_C first-person-camera ability.
--   WBP_Map_FastTravel_C : URODFastTravelMenuWidget -- the destination picker,
--                          the screen a terminal opens. EMenuKind::FastTravelMenu
--                          = 66, and it carries OnDetailMapTermialIconClickDelegate.
--
-- The fast travel screen is the default and the one that works. It is the game's
-- own fast travel UI and confirming a checkpoint on it is measured end to end.
-- It states its own scope in its banner -- "Escolha para qual Area Segura ou
-- Terminal de Teletransporte voce vai" -- so map pins are drawn on it for
-- orientation and cannot be confirmed.
--
-- The reference map's cursor does stop on every icon, because that screen exists
-- for placing markers, so in principle a pin could be confirmed there. v0.9.0
-- made it the default for that reason and that was a mistake: it trades a
-- working fast travel screen for an unproven confirm interception on a screen
-- that is not the game's fast travel UI. It is opt-in via MAP_TARGET now.
--
-- FAST TRAVEL ANYWHERE
--
-- F9 uses the field map cursor itself; placing a pin is not required. The
-- player's world position, the player/cursor render translations, the live
-- FieldMapDistancePerPixel and RODInGameUIManager::ConvertMapLocation form the
-- complete cursor-to-world transform.
--
-- A temporary WorldPartitionStreamingSourceComponent loads the destination
-- without moving the hero. The move is fail-closed until nine WorldStatic
-- traces support the real hero capsule footprint in two consecutive probes.
-- Navmesh is deliberately not part of this player-collision contract.
--
-- Natively the second is opened by GA_AvatarMenu_AccessTerminal_C, which needs a
-- real terminal actor as its Target. This mod instead constructs the widget and
-- hands it to the menu manager, so no terminal is impersonated.
--
-- ARODPlayerState::OpenMenu(66) looked like the one-call answer and is not: the
-- menu kind resolved correctly (MENU WIDGET MAP confirmed EMenuKind 66 ->
-- WBP_Map_FastTravel_C) and the call returned without constructing anything.
-- The open now uses the Create + DebugOpenMenu + OpenMenu sequence that
-- FieldEquipmentMod already relies on for its Equipment screen.
--
-- WHO PERFORMS THE TELEPORT
--
-- The screen decides the destination natively and announces it through
-- ARODPlayerState::ServerDecideFastTravel(ID). Away from a terminal the player
-- state sits at EFastTravelStatus::Disable, so the server does nothing with that
-- decision and the screen hangs waiting. This mod therefore takes the ID the
-- game chose, resolves it against ARODGameState::RODAccessibleGimmicks, and
-- moves the hero itself. At a real terminal the native transaction is live and
-- is left untouched.
--
-- The move does not go through ARODAvatarCharacter::ServerDebugTeleportGimmick,
-- which this mod used to document as its teleport and which moves nothing. See
-- the note above performTeleport.
--
-- WHERE IT WORKS
--
-- Floor maps only. On the town map the screen decides ID=None: the town world's
-- RODAccessibleGimmicks holds that world's own gimmicks, not the floor's
-- terminals, so there is nothing there to travel to.
--
-- Rather than let that be discovered by failing, the Start Menu row is not
-- injected at all when the current world holds no travel destination. The test
-- is "how many accessible gimmicks carry an ID", which is the real question and
-- hardcodes no map name, and it runs per Start Menu construction so walking
-- between town and a floor needs no transition tracking.
--
-- Adds a native-styled Fast Travel row to Echoes of Aincrad's Start Menu and
-- opens the game's fast travel map. Confirming a terminal teleports the hero.
--
-- Runtime contract: SDK/template 1.0.3
--   EMenuKind::FastTravelMenu = 66
--   UWidgetBlueprintLibrary::Create
--   URODWidgetBPFunctionLibrary::DebugOpenMenu / OpenMenu / EndMenu
--   URODWidgetData::MenuWidgetMap
--   ARODPlayerState::ServerDecideFastTravel(ID)
--   ARODGameState::RODAccessibleGimmicks
--   ARODAccessibleGimmickBase::ID / WarpOutTransforms / AccessTransforms
--   ARODGameState::MapPins (FRODMapPin::Kind / Pos / Timestamp)
--   URODInGameUIManager::ConvertMapLocation
--   URODFieldMapItemWidget::FieldMapDistancePerPixel / ImageAngle
--   URODMapItemWidgetBase::PlayerIconWidget / CursorWidget / MapImageSize
--   UWidget::RenderTransform
--   UWorldPartitionStreamingSourceComponent
--   UROD_BlueprintFunctionLibrary::GetZLineTraceLoc
--   ExecuteInGameThreadWithDelay / LoopInGameThreadWithDelay
--   CancelDelayedAction
--   URODWidgetBPFunctionLibrary::SetCurrentMenuInputActionEnable
--   AActor::K2_TeleportTo(FVector, FRotator)
--   WBP_Map_FastTravel_C
--
--   MAP_TARGET = "map" only:
--   EMenuKind::MapMenu = 31
--   ARODInGamePlayerController::EndMainMenu(true) / EndMapMenu(AllClose)
--   ARODAvatarCharacter::ActivateFPCameraMenuAbility(EventTag, MenuKey, Target)
--   UGA_AvatarMenu_FirstPersonCamera_C::LevelSequenceMap / CurrentMenuKey
--   URODMapMenuWidgetBase::UpdateIcon(...)
--   WBP_Map_C
--
-- HOW THE MAP IS OPENED, AND WHY IT USED TO FAIL
--
-- GA_AvatarMenu_Map_C is not a standalone ability: it derives from
-- GA_AvatarMenu_FirstPersonCamera_C, which activates from an event and then
-- looks its opening cutscene up in LevelSequenceMap, a TMap<FName, LevelSequence>
-- indexed by CurrentMenuKey. That key is what decides whether the avatar ever
-- raises the menu, and it is the only thing that eventually calls
-- ARODInGamePlayerController::DisplayMapMenu, which is what actually constructs
-- WBP_Map_C.
--
-- Calling TryActivateAbilityWithPayloadFromClass with a blank FGameplayEventData
-- activated the ability -- the call returned true -- and then the ability sat
-- there with no menu key, no level sequence and no display step, so no widget was
-- ever built. The measured symptom was exactly that: "map gameplay ability
-- activated" followed by "WBP_Map_C was not constructed".
--
-- ARODAvatarCharacter::ActivateFPCameraMenuAbility(EventTag, MenuKey, Target) is
-- the game's own entry point for this ability family and takes the menu key as a
-- real argument. The hook on it below records what the game passes for every
-- first-person-camera menu it opens (the Start Menu opens through the same
-- function), so the key this mod sends is measured rather than assumed.
--
-- No terminal impersonation, FastTravelStatus write or direct actor-location
-- mutation exists here. If the exact selected icon or its native map position
-- is unavailable, the operation stops and reports the error.

local MOD_NAME = "FastTravelMod"
local MOD_VERSION = "v0.15.3"
local SUPPORTED_SDK = "Echoes of Aincrad 1.0.3"

-- This UE4SS build exposes owned, cancellable game-thread delayed actions.
-- The older ExecuteWithDelay -> ExecuteInGameThread double-hop stores two Lua
-- registry references per step and produced the measured fatal
-- "Registry::get_function_ref | Ref was not function" abort. There is no
-- legacy scheduler path.
if type(ExecuteInGameThreadWithDelay) ~= "function"
    or type(LoopInGameThreadWithDelay) ~= "function"
    or type(CancelDelayedAction) ~= "function" then
    error("[" .. MOD_NAME ..
        "] owned game-thread delayed-action contract is unavailable")
end

-- Folded into one table: this file sits at Lua's limit of 200 locals in the
-- main chunk, and thirty individual constants is thirty slots.
local K = {
    MAIN_MENU_ICON_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_MenuIcon.WBP_Console_MainMenu_MenuIcon_C",
    MAIN_MENU_LIST_CLASS =
    "/Game/ROD/Widget/Console/MainMenu/WBP_Console_MainMenu_List.WBP_Console_MainMenu_List_C",
    MAIN_MENU_CLASS_FRAGMENT = "WBP_Console_MainMenu_C",
    MAIN_MENU_LIST_FRAGMENT = "WBP_Console_MainMenu_List_C",
    MENU_ICON_FRAGMENT = "WBP_Console_MainMenu_MenuIcon_C",
-- Two different screens, and only one of them is the fast travel one.
--   WBP_Map_C            : URODMapMenuWidgetBase    -- the reference map,
--                          titled "Mapa / Detalhes da Area de Missao"
--   WBP_Map_FastTravel_C : URODFastTravelMenuWidget -- the destination picker,
--                          the screen a terminal opens
    MAP_MENU_WIDGET_FRAGMENT = "WBP_Map_C",
    FAST_TRAVEL_WIDGET_FRAGMENT = "WBP_Map_FastTravel_C",
-- Read back from URODWidgetData::MenuWidgetMap for EMenuKind::FastTravelMenu on
-- this build, so this path is confirmed rather than assumed.
    FAST_TRAVEL_WIDGET_CLASS =
    "/Game/ROD/Widget/Cockpit/Minimap/WBP_Map_FastTravel.WBP_Map_FastTravel_C",
    MAIN_MENU_ABILITY_CLASS = "GA_AvatarMenu_Main_C",
    MAP_MENU_ABILITY_CLASS = "GA_AvatarMenu_Map_C",

-- EMenuKind::FastTravelMenu is what the row opens. The reference map is
-- EMenuKind::MapMenu = 31 but is opened through its gameplay ability, not by
-- kind, so only this one is needed.
    MENU_KIND_FAST_TRAVEL_MENU = 66,

    FAST_TRAVEL_STATUS_DISABLE = 0,
    FAST_TRAVEL_STATUS_CANCEL = 1,
    FAST_TRAVEL_STATUS_DECIDE = 2,
    FAST_TRAVEL_STATUS_ENABLE = 3,
    ACCESSIBLE_STATUS_NONE = 0,

    MAX_NATIVE_MENU_ITEMS = 7,
    -- The Start Menu's list builds asynchronously, and this row is borrowed from
    -- a donor list that has to be finished before its slot geometry can be read.
    -- 600ms is the field-tested floor for a first pass over a freshly opened
    -- menu; 200-300ms crashed reproducibly, and worst when a second mod was
    -- taking a donor of its own at the same time -- which is exactly this rail,
    -- where ModMenu borrows one too. See mod_template techniques/
    -- quest-manifest-and-menus.md ("Timing") and ui-widget-techniques.md
    -- ("Do not race construction"). A crash here is a native access violation:
    -- no pcall sees it, the log just stops.
    MENU_INJECTION_DELAY_MS = 600,
    MENU_TRANSITION_POLL_MS = 50,
    MENU_TRANSITION_TIMEOUT_MS = 3000,
    OPEN_VERIFICATION_DELAY_MS = 3000,
    TELEPORT_FINALIZE_DELAY_MS = 900,
    MENU_END_ALL_CLOSE = 2,

    ACCEPT_BUTTON = 1,
    BACK_BUTTON = 2,
    SINGLE_CLICK = 1,
    DPAD_UP = 13,
    DPAD_DOWN = 14,
    LSTICK_UP = 17,
    LSTICK_DOWN = 18,

-- Filled from the pin half of ELIGIBLE_MAP_ICON_KINDS below.
    MAP_PIN_ICON_KINDS = {},

    ELIGIBLE_MAP_ICON_KINDS = {
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
    },

    VISIBLE = 0,
    COLLAPSED = 1,
    HIDDEN = 2,
}

-- Kinds 24 and above are the pin half: HeroPin1..3, PillarPin1..5,
-- InstantPin1..3. Below that are the checkpoints the screen already accepts.
for kind in pairs(K.ELIGIBLE_MAP_ICON_KINDS) do
    if kind >= 24 then K.MAP_PIN_ICON_KINDS[kind] = true end
end

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
    MAP_MENU_KEY = "",
    MAP_TARGET = "fasttravel",
    FORCE_CLOSE_KEY = "F8",
    CURSOR_TRAVEL_KEY = "F9",
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
local teleportMapWidget = nil
local menuCloseBusy = false
local teleportMapModeActive = false
local mapTeleportBusy = false
local cursorTravelBusy = false
local mapIconDestinations = {}
-- UpdateIcon fires once per icon and a floor map carries well over a hundred of
-- them, all reporting the same map widget. Resolving that widget's full object
-- path for every one of them is the same answer bought a hundred times, so it is
-- remembered here. owner pins the memo to the destination table it was measured
-- against: every reset of that table replaces it, which invalidates this on its
-- own without any of the eleven reset sites having to know about it.
local updateIconMemo = { owner = nil, widget = nil, accepted = false }
local pendingMapAbility = nil
local pendingMapContract = nil
local lastNativeFastTravelStatus = nil
local lastNativeAccessibleStatus = nil
local lastNativeAccessingTerminal = nil
local lastNativeAccessibleGimmickId = nil

-- Everything the game itself has passed to ActivateFPCameraMenuAbility this
-- session: event tag name -> menu key. Written only by the hook, so a key taken
-- from here is a measured value and never a guess.
local observedMenuKeys = {}
local observedMenuKeyOrder = {}
local mapSequenceKeyCache = nil
local lastMapMenuKey = nil
local lastMapMenuKeySource = nil

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

-- Which of the two map screens this widget is, or nil. "WBP_Map_C" is not a
-- substring of "WBP_Map_FastTravel_C", so these never answer for each other.
local function mapScreenFragment(widget)
    if not isValid(widget) then return nil end
    if nameContains(widget, K.FAST_TRAVEL_WIDGET_FRAGMENT) then
        return K.FAST_TRAVEL_WIDGET_FRAGMENT
    end
    if nameContains(widget, K.MAP_MENU_WIDGET_FRAGMENT) then
        return K.MAP_MENU_WIDGET_FRAGMENT
    end
    return nil
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
    local booleanKeys = {
        ENABLED = true,
        DEBUG_LOGS = true,
    }
    -- MAP_MENU_KEY is deliberately absent from the ModMenu registry: it is a
    -- free-text FName escape hatch for the case where the menu key cannot be
    -- learned from the game, and the in-game menu has no text field.
    local stringKeys = {
        MAP_MENU_KEY = true,
        MAP_TARGET = true,
        FORCE_CLOSE_KEY = true,
        CURSOR_TRAVEL_KEY = true,
    }
    for key in pairs(settings) do
        if booleanKeys[key] ~= true and stringKeys[key] ~= true then
            error("unknown setting: " .. tostring(key))
        end
    end
    for key in pairs(booleanKeys) do
        if type(settings[key]) ~= "boolean" then
            error(key .. " must be boolean")
        end
    end
    for key in pairs(stringKeys) do
        if settings[key] ~= nil and type(settings[key]) ~= "string" then
            error(key .. " must be a string")
        end
    end
    local mapTarget = settings.MAP_TARGET or "fasttravel"
    if mapTarget ~= "fasttravel" and mapTarget ~= "map" then
        error("MAP_TARGET must be \"fasttravel\" or \"map\"")
    end

    CONFIG.ENABLED = settings.ENABLED
    CONFIG.DEBUG_LOGS = settings.DEBUG_LOGS
    CONFIG.MAP_MENU_KEY = settings.MAP_MENU_KEY or ""
    CONFIG.MAP_TARGET = mapTarget
    -- Keys are read once at load; the bindings are registered there and are not
    -- re-registered on a live settings change.
    if settings.FORCE_CLOSE_KEY ~= nil then
        CONFIG.FORCE_CLOSE_KEY = settings.FORCE_CLOSE_KEY
    end
    if settings.CURSOR_TRAVEL_KEY ~= nil then
        CONFIG.CURSOR_TRAVEL_KEY = settings.CURSOR_TRAVEL_KEY
    end
    runtimeHealthy = true
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
    local contractOk, contractError = pcall(function()
        mapAbility = resolveOwnedAbility(
            K.MAP_MENU_ABILITY_CLASS,
            abilitySystem)
        mapAbilityClass = mapAbility:GetClass()
        if not isValid(mapAbilityClass) then
            error(K.MAP_MENU_ABILITY_CLASS ..
                " generated class is unavailable")
        end
        mapAbilityClassName = objectName(mapAbilityClass)
        if mapAbilityClassName == nil
            or string.find(
                mapAbilityClassName,
                K.MAP_MENU_ABILITY_CLASS,
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
            error(K.MAP_MENU_ABILITY_CLASS ..
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
                K.MAP_MENU_ABILITY_CLASS,
                #eventTriggers))
        end

        mapAbilityTriggerTag = eventTriggers[1]
        if tagLibrary:IsGameplayTagValid(
            mapAbilityTriggerTag) ~= true then
            error(K.MAP_MENU_ABILITY_CLASS ..
                " GameplayEvent trigger tag is invalid")
        end
        mapAbilityTriggerTagName = exactFNameString(
            mapAbilityTriggerTag.TagName,
            K.MAP_MENU_ABILITY_CLASS .. " trigger TagName")

        local mainMenuActive =
            isOwnedAbilityClassActive(
                K.MAIN_MENU_ABILITY_CLASS,
                abilitySystem)
        if not mainMenuActive then
            error(K.MAIN_MENU_ABILITY_CLASS ..
                " has no active ability instance")
        end
    end)
    if not contractOk then
        return nil, "map gameplay ability contract failed: " ..
            tostring(contractError)
    end

    return {
        hero = hero,
        abilitySystem = abilitySystem,
        mapAbility = mapAbility,
        mapAbilityClass = mapAbilityClass,
        mapAbilityClassName = mapAbilityClassName,
        mapAbilityTriggerTag = mapAbilityTriggerTag,
        mapAbilityTriggerTagName = mapAbilityTriggerTagName,
    }, nil
end

-- The legal menu keys for this ability, read straight out of its own
-- LevelSequenceMap. A key that is not in here has no opening sequence, and the
-- ability that used to be activated with a blank payload had exactly that.
local function mapSequenceKeys(mapAbility)
    if mapSequenceKeyCache ~= nil then return mapSequenceKeyCache end

    local keys = {}
    local readOk, readError = pcall(function()
        local sequences = mapAbility.LevelSequenceMap
        if sequences == nil then
            error("LevelSequenceMap is unavailable")
        end
        sequences:ForEach(function(key)
            keys[#keys + 1] =
                exactFNameString(key:get(), "LevelSequenceMap key")
        end)
    end)
    if not readOk then
        log("MAP SEQUENCE KEYS | unreadable: " .. tostring(readError))
        mapSequenceKeyCache = {}
        return mapSequenceKeyCache
    end

    mapSequenceKeyCache = keys
    log(string.format(
        "MAP SEQUENCE KEYS | %s LevelSequenceMap holds %d key(s): %s",
        K.MAP_MENU_ABILITY_CLASS,
        #keys,
        #keys == 0 and "<none>" or table.concat(keys, ", ")))
    return mapSequenceKeyCache
end

-- Sources are tried strongest first. "Observed" means the game itself passed
-- that key to ActivateFPCameraMenuAbility while this session was running.
local function resolveMapMenuKey(contract)
    local keys = mapSequenceKeys(contract.mapAbility)
    local legal = {}
    for _, key in ipairs(keys) do legal[key] = true end

    if CONFIG.MAP_MENU_KEY ~= "" then
        return CONFIG.MAP_MENU_KEY, "config MAP_MENU_KEY"
    end

    local observedForMap = observedMenuKeys[contract.mapAbilityTriggerTagName]
    if observedForMap ~= nil then
        return observedForMap, "observed native map activation"
    end

    -- The key names the avatar's opening pose, not the menu, so the Start Menu
    -- and the map share a vocabulary. Only accept a borrowed key if the map
    -- ability actually declares a sequence for it.
    for index = #observedMenuKeyOrder, 1, -1 do
        local tagName = observedMenuKeyOrder[index]
        local candidate = observedMenuKeys[tagName]
        if candidate ~= nil and legal[candidate] == true then
            return candidate, "observed " .. tagName .. " key, shared"
        end
    end

    if #keys == 1 then
        return keys[1], "sole LevelSequenceMap key"
    end
    for _, key in ipairs(keys) do
        if string.find(string.lower(key), "map", 1, true) ~= nil then
            return key, "LevelSequenceMap key naming the map"
        end
    end
    if #keys > 0 then
        return keys[1], "first of " .. #keys .. " LevelSequenceMap keys"
    end
    return nil, "no key source"
end

local function resolveWorldGameState()
    local gameState = FindFirstOf("RODWorldGameState")
    if not isValid(gameState) then
        return nil, "exact RODWorldGameState is unavailable"
    end
    return gameState, nil
end

-- "Is there anywhere to travel from this world?"
--
-- On a floor the game state carries that floor's terminals. In town it carries
-- the town's own couple of gimmicks, the screen decides ID=None, and opening it
-- there can only fail -- measured, twice. Counting terminals that actually hold
-- an ID is the semantic question and hardcodes no map name, so it keeps working
-- on floors this build has not shipped yet.
local function isTownWorld(gameState)
    local hero = resolveLocalHero()
    if isValid(hero) then
        local isTown = false
        local ok = pcall(function()
            if hero:IsTown() == true or hero.bIsTown == true then
                isTown = true
            end
        end)
        if ok and isTown then return true end
    end

    if isValid(gameState) then
        local isTown = false
        local ok = pcall(function()
            if gameState.bIsTown == true or gameState.bTownActive == true then
                isTown = true
            end
        end)
        if ok and isTown then return true end
    end

    return false
end

local function fastTravelAvailability()
    local gameState, gameStateError = resolveWorldGameState()
    if gameState == nil then return nil, tostring(gameStateError) end

    if isTownWorld(gameState) then
        return { travelable = 0, total = 0, sample = {}, isTown = true }, nil
    end

    local gimmicks = nil
    local listOk, listError = pcall(function()
        gimmicks = gameState.RODAccessibleGimmicks
    end)
    if not listOk or gimmicks == nil then
        return nil, "RODAccessibleGimmicks is unavailable: " ..
            tostring(listError)
    end

    local total = 0
    pcall(function() total = #gimmicks end)

    local travelable = 0
    local sample = {}
    for index = 1, total do
        local gimmick = nil
        pcall(function() gimmick = gimmicks[index] end)
        if isValid(gimmick) then
            local id = nil
            pcall(function()
                id = exactFNameString(gimmick.ID, "accessible gimmick ID")
            end)
            if id ~= nil and id ~= "None" then
                travelable = travelable + 1
                if #sample < 6 then sample[#sample + 1] = id end
            end
        end
    end
    return { travelable = travelable, total = total, sample = sample }, nil
end

local FAST_TRAVEL_STATUS_NAMES = {
    [K.FAST_TRAVEL_STATUS_DISABLE] = "Disable",
    [K.FAST_TRAVEL_STATUS_CANCEL] = "Cancel",
    [K.FAST_TRAVEL_STATUS_DECIDE] = "Decide",
    [K.FAST_TRAVEL_STATUS_ENABLE] = "Enable",
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
        state.fastTravelStatus == K.FAST_TRAVEL_STATUS_DECIDE
        and state.accessibleStatus == K.ACCESSIBLE_STATUS_NONE
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
        ExecuteInGameThreadWithDelay(delayMs or 0, function()
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
    cursorTravelBusy = false
    mapIconDestinations = {}
    teleportMapWidgetKey = nil
    teleportMapWidget = nil
    openSerial = openSerial + 1
    if activeContext ~= nil then
        activeContext.failed = true
        setContextVisibility(activeContext, K.COLLAPSED)
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
        or finalIndex >= K.MAX_NATIVE_MENU_ITEMS then
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

    -- NumContent is the last AUTHORED index, not the last ACTIVE one. Progression
    -- and quest state hide rows off the tail -- Logout is the usual one -- by
    -- collapsing the wrapper, leaving the item itself alive and countable. Trust
    -- it as-is and this row lands one index past the end: the handoff waits for
    -- focus to reach a row the player can never select, the list wraps straight
    -- from the real last row back to the first, and neither custom row can be
    -- reached. On the floor where this was caught the count was 7 authored but 6
    -- active, and ModMenu -- which already trimmed -- disagreed by exactly one.
    -- Stop at the first still-visible row so a collapsed row in the MIDDLE is
    -- left counted, which is what the native cursor does with it.
    while count > 1 do
        local _, wrapper = menuItemAndPanel(mainList, count - 1)
        local _, previousWrapper = menuItemAndPanel(mainList, count - 2)
        local visibility = nil
        local previousVisibility = nil
        pcall(function() visibility = wrapper:GetVisibility() end)
        pcall(function() previousVisibility = previousWrapper:GetVisibility() end)
        if visibility ~= K.COLLAPSED and visibility ~= K.HIDDEN then break end
        if previousVisibility == K.COLLAPSED
            or previousVisibility == K.HIDDEN then
            break
        end
        count = count - 1
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
            and nameContains(child, K.MENU_ICON_FRAGMENT) then
            return child
        end
    end
    return nil
end

local function authoredWrapperNames(mainList)
    local authored = {}
    for index = 0, K.MAX_NATIVE_MENU_ITEMS - 1 do
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
    local listClass = StaticFindObject(K.MAIN_MENU_LIST_CLASS)
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

    -- LayoutData is a remote FAnchorData view. It becomes invalid when the
    -- donor slot is detached, so retain only plain Lua numbers across reparent.
    dbg("wrapper stage | snapshotting donor layout scalars")
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
    dbg("wrapper stage | reparenting donor panel")
    donorItem:RemoveFromParent()
    donorPanel:RemoveFromParent()
    parent:AddChildToVerticalBox(donorPanel)

    dbg("wrapper stage | slotting icon")
    local iconSlot = donorPanel:AddChildToCanvas(icon)
    if not isValid(iconSlot) then
        error("native wrapper rejected the Fast Travel icon")
    end
    dbg("wrapper stage | applying donor layout scalars")
    iconSlot:SetMinimum(layout.minimum)
    iconSlot:SetMaximum(layout.maximum)
    iconSlot:SetPosition(layout.position)
    iconSlot:SetSize(layout.size)
    iconSlot:SetAlignment(layout.alignment)
    iconSlot:SetAutoSize(true)
    iconSlot:SetZOrder(20)
    icon:SetVisibility(K.VISIBLE)
    donorPanel:SetVisibility(K.VISIBLE)
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
        label:SetVisibility(K.VISIBLE)
        label:SetRenderOpacity(1.0)
        context.icon.IconImage:SetVisibility(K.HIDDEN)
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
        context.icon.IconImage:SetVisibility(K.HIDDEN)
        context.letterWidget:SetVisibility(K.VISIBLE)
        context.letterWidget:SetRenderOpacity(1.0)
    end)
    if not ok then return nil, tostring(presentationError) end
    return true, nil
end

local function isCanonicalMainMenu(mainMenu)
    if not isValid(mainMenu)
        or not nameContains(mainMenu, K.MAIN_MENU_CLASS_FRAGMENT) then
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
        return FindAllOf(K.MAIN_MENU_CLASS_FRAGMENT)
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
    -- Evaluated per Start Menu construction, so walking from town to a floor and
    -- back is picked up without any transition tracking.
    local availability, availabilityError = fastTravelAvailability()
    if availability == nil then
        log("row injection refused: " .. tostring(availabilityError))
        return
    end
    log(string.format(
        "FAST TRAVEL AVAILABILITY | %d destination(s) of %d gimmick(s)%s",
        availability.travelable,
        availability.total,
        #availability.sample == 0 and ""
            or (" | " .. table.concat(availability.sample, ", "))))
    if availability.travelable == 0 then
        log("Fast Travel row omitted: this world has no travel destination." ..
            " That is the town map; use a floor map.")
        return
    end

    if injectedMenuKey == menuKey then
        dbg("row already injected into " .. menuKey)
        return
    end

    dbg("row injection stage | resolving libraries")
    local controller, controllerError = resolveLocalController()
    local umgLibrary, umgError = resolveUmgLibrary()
    local textLibrary, textError = resolveTextLibrary()
    if controller == nil or umgLibrary == nil or textLibrary == nil then
        log("row injection failed closed: " ..
            tostring(controllerError or umgError or textError))
        return
    end

    dbg("row injection stage | walking rail hierarchy")
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

    dbg("row injection stage | counting native rows")
    local nativeCount, countError =
        resolveNativeMenuCount(mainMenu, mainList)
    if nativeCount == nil then
        log("row injection failed closed: " .. tostring(countError))
        return
    end
    dbg("row injection stage | native rows = " .. tostring(nativeCount))
    local lastItem = menuItemAndPanel(mainList, nativeCount - 1)
    if not isValid(lastItem) then
        log("row injection failed closed: final native item is unavailable")
        return
    end

    dbg("row injection stage | counting injected rows")
    local rowsAbove, injectedError =
        countInjectedRows(parent, mainList)
    if rowsAbove == nil then
        log("row injection failed closed: " .. tostring(injectedError))
        return
    end
    local fastTravelIndex = nativeCount + rowsAbove

    dbg("row injection stage | resolving icon class")
    local iconClass = StaticFindObject(K.MAIN_MENU_ICON_CLASS)
    if not isValid(iconClass) then
        log("row injection failed closed: native menu icon class is unavailable")
        return
    end

    local icon = nil
    local wrapperDonor = nil
    local wrapperPanel = nil
    -- Everything below here is native widget construction and reparenting. A bad
    -- pointer in any of it takes the process down with an access violation,
    -- which is a hardware exception: the xpcall cannot see it and the log simply
    -- stops. These markers are what tells the stages apart afterwards, so turn
    -- DEBUG_LOGS on in config.lua before reproducing a crash on menu open.
    dbg("row injection stage | creating icon")
    local configured, configureError = xpcall(function()
        icon = umgLibrary:Create(controller, iconClass, controller)
        if not isValid(icon) then
            error("Fast Travel icon creation returned null")
        end

        dbg("row injection stage | borrowing native wrapper")
        wrapperDonor, wrapperPanel =
            attachIconWithNativeWrapper(
                umgLibrary, controller, parent, icon)

        dbg("row injection stage | configuring icon")
        icon:SetItemIndex(fastTravelIndex)
        icon:SetOwnerInputWidget(mainList)
        icon:SetInactive(false)
        icon:SetBlank(false)
        icon:SetInputEnable(true)
        icon:BP_SetInputInteractionEnable(true)
        icon:SetDefaultAnimation()

        icon:SetMenuName(textLibrary:Conv_StringToText("Fast Travel"))
        icon.MenuName:SetText(
            textLibrary:Conv_StringToText("Fast Travel"))
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
            local item = context.mainList["Item_" .. tostring(index)]
            item:StopAllAnimations()
            item:SetDefaultAnimation()
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

-- Whether this row is the one that borders the native rows, asked of the live
-- rail on every press.
--
-- The boundary belongs to whichever injected row is physically first, and that
-- cannot be settled at injection time: on a floor both this mod and ModMenu
-- inject, in whatever order the two independent notification cycles happen to
-- land. The answer used to be frozen into context.firstInjected, so when ModMenu
-- injected first this row recorded "not first" permanently -- and ModMenu then
-- moved itself back to the end of the rail, which left this row bordering the
-- native ones with its claim already surrendered. Both mods stood down, nothing
-- carried focus off the last native row, and neither custom row could be
-- reached. In town the pair never met: with no travel destination this row is
-- not injected at all, which is why the rail behaved there.
local function ownsNativeBoundary(context)
    if context == nil then return false end
    local before = railIconsRelativeToOwn(context)
    -- The walk only fails while the rail is being torn down. Fall back to the
    -- injection-time answer rather than failing the menu from an input hook.
    if before == nil then return context.firstInjected == true end
    return #before == 0
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
    ExecuteInGameThreadWithDelay(60, function() inputLocked = false end)
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
    if mapScreenFragment(widget) == nil then
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

-- Read back what the ability did with the key we sent it. CurrentMenuKey is set
-- by the native activation path, so an empty one says the key never landed and a
-- populated one moves the investigation past this mod.
local function logMapAbilityState(label)
    local contract = pendingMapContract
    if contract == nil or not isValid(contract.mapAbility) then
        log(string.format(
            "MAP ABILITY STATE | %s | ability reference is gone", label))
        return
    end

    local active = "unreadable"
    pcall(function()
        active = tostring(contract.mapAbility:BP_IsActive())
    end)

    local currentKey = "unreadable"
    pcall(function()
        currentKey = exactFNameString(
            contract.mapAbility.CurrentMenuKey, "CurrentMenuKey")
    end)

    log(string.format(
        "MAP ABILITY STATE | %s | active=%s | CurrentMenuKey=%s | sent=%s (%s)",
        label,
        active,
        currentKey,
        tostring(lastMapMenuKey),
        tostring(lastMapMenuKeySource)))
end

local function failPendingOpen(serial, reason)
    if serial ~= nil and serial ~= openSerial then return end
    local abilityToCancel = pendingMapAbility
    pendingMapAbility = nil
    pendingMapContract = nil
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
    cursorTravelBusy = false
    mapIconDestinations = {}
    teleportMapWidgetKey = nil
    teleportMapWidget = nil
    openSerial = openSerial + 1
    log("FAST TRAVEL ERROR | " .. tostring(reason))
end

--========================================================--
--                     MAP PIN TRAVEL                     --
--========================================================--
-- Pins are read from the game state, never from the screen. Measured with the
-- cursor over the only placed pin:
--
--   MapPins[1]  EMapPinKind=7  timestamp=33.5873  pos=(21400.3, 291328.2, 0.0)
--   PinIcon[8]  kind=27        timestamp=33.5873  visible=true  canHover=false
--
-- The timestamp join works, but every widget on that screen -- the cursor
-- included -- reports position 0,0 through both the canvas slot and the cached
-- geometry, and the icons report canHover=false. Nothing on screen can say which
-- pin is being pointed at, so the pin is identified rather than aimed at.
--
-- HOW THE GAME ITSELF DOES HOVER
--
-- Not by geometry. URODInputWidgetBase -- the base of every interactive widget,
-- which URODIconForMapWidgetBase inherits through URODMenuItemWidgetBase --
-- carries the hover state itself:
--
--   bool GetIsMouseHover();              execGetIsMouseHover
--   void SetInputEnable(bool bEnable);   execSetInputEnable
--   bool IsInputEnable();                execIsInputEnable
--   void OnEnterHover();  void OnLeaveHover();
--
-- So the question "is the cursor on this pin" is asked of the pin, not computed
-- from coordinates. Every previous attempt here tried to compute it -- canvas
-- slots, cached geometry, absolute positions, nearest-wins -- and all of it read
-- 0,0 because that is not where this information lives.
--
-- SetInputEnable is one half. Hit testing is the other: an icon that is drawn
-- HitTestInvisible so it does not intercept the mouse over the map can never
-- report hover, whatever its input flags say. Both are raised.
-- URODMapMenuWidgetBase declares MapItemWidget. URODFastTravelMenuWidget does
-- not: it builds one from FieldClass into MapWidgetCanvas, so for that screen
-- the canvas children are where it lives.
-- F9 is not tied to a pin. The field map's own distance-per-pixel and the
-- RODInGameUIManager world-to-map transform turn the live cursor translation
-- into an exact world XY. Before the hero moves, a temporary World Partition
-- streaming source loads that XY. Teleport is allowed only after the game's
-- WorldStatic trace supports the complete capsule footprint twice in a row.
-- There is no approach hop, alternate destination, or guessed Z.

local function resolveMapItemWidget(mapWidget)
    if not isValid(mapWidget) then return nil, "no map screen" end

    local direct = nil
    pcall(function() direct = mapWidget.MapItemWidget end)
    if isValid(direct) then return direct, nil end

    local itemClass = StaticFindObject("/Script/ROD.RODMapItemWidgetBase")
    if not isValid(itemClass) then
        return nil, "RODMapItemWidgetBase class fingerprint is unavailable"
    end

    local canvas = nil
    pcall(function() canvas = mapWidget.MapWidgetCanvas end)
    if not isValid(canvas) then
        return nil, "MapWidgetCanvas is unavailable"
    end

    local found = nil
    pcall(function()
        local count = canvas:GetChildrenCount()
        for index = 0, count - 1 do
            local child = canvas:GetChildAt(index)
            if isValid(child) and child:IsA(itemClass) then
                found = child
                break
            end
        end
    end)
    if isValid(found) then return found, nil end
    return nil, "no RODMapItemWidgetBase under MapWidgetCanvas"
end

-- WHERE THE POSITIONS ACTUALLY ARE
--
-- The canvas slot read 0,0 for every widget including the cursor, and so did
-- GetCachedGeometry. Both were the wrong place to look: an icon that moves
-- across a map is positioned by render translation, not by its slot.
-- UWidget::RenderTransform is a plain property, so this is a field read with no
-- UFunction call behind it.

local function widgetTranslation(widget)
    if not isValid(widget) then return nil end
    local at = nil
    pcall(function()
        local translation = widget.RenderTransform.Translation
        at = { X = tonumber(translation.X), Y = tonumber(translation.Y) }
    end)
    if at == nil or at.X == nil or at.Y == nil then return nil end
    return at
end

local function verifyTeleportMapOpen(serial)
    if serial ~= openSerial then return end

    -- Both screens are scanned, not just the wanted one, so a run that opens
    -- the reference map by mistake says so instead of reporting nothing at all.
    local presented = {}
    local constructed = 0
    for _, fragment in ipairs({
        K.FAST_TRAVEL_WIDGET_FRAGMENT, K.MAP_MENU_WIDGET_FRAGMENT
    }) do
        local ok, widgets = pcall(function()
            return FindAllOf(fragment)
        end)
        if ok and type(widgets) == "table" then
            for _, widget in ipairs(widgets) do
                constructed = constructed + 1
                if isPresentedTeleportMapWidget(widget) then
                    presented[#presented + 1] = widget
                end
            end
        end
    end

    if #presented ~= 1 then
        logMapAbilityState("map screen not presented")
        failPendingOpen(serial, string.format(
            "expected one presented map screen, found %d presented of %d " ..
                "constructed (%s / %s)",
            #presented,
            constructed,
            K.FAST_TRAVEL_WIDGET_FRAGMENT,
            K.MAP_MENU_WIDGET_FRAGMENT))
        return
    end

    local fragment = mapScreenFragment(presented[1])
    local wanted = CONFIG.MAP_TARGET == "map"
        and K.MAP_MENU_WIDGET_FRAGMENT
        or K.FAST_TRAVEL_WIDGET_FRAGMENT
    if fragment ~= wanted then
        log(string.format(
            "MAP SCREEN MISMATCH | opened %s, wanted %s",
            tostring(fragment),
            wanted))
    end

    openBusy = false
    pendingMapAbility = nil
    pendingMapContract = nil
    teleportMapWidget = presented[1]
    teleportMapWidgetKey = objectName(presented[1])
    teleportMapModeActive = true
    log(string.format(
        "map screen presented | %s | confirm a native destination or press %s at the cursor",
        tostring(fragment),
        tostring(CONFIG.CURSOR_TRAVEL_KEY)))
end

local function activateTeleportMapAbility(serial, contract)
    if serial ~= openSerial then return end

    if not isValid(contract.hero) then
        failPendingOpen(serial, "local hero is unavailable at activation")
        return
    end

    local menuKey, menuKeySource = resolveMapMenuKey(contract)
    lastMapMenuKey = menuKey
    lastMapMenuKeySource = menuKeySource
    if menuKey == nil then
        failPendingOpen(
            serial,
            "no menu key is available for " .. K.MAP_MENU_ABILITY_CLASS ..
                "; set MAP_MENU_KEY in config.lua or open the map once " ..
                "natively so the key can be observed")
        return
    end

    -- Step-logged before the native call, because an access violation inside it
    -- would take the process down with no Lua error to catch.
    log(string.format(
        "MAP OPEN | ActivateFPCameraMenuAbility | tag=%s | menuKey=%s (%s)",
        contract.mapAbilityTriggerTagName,
        menuKey,
        menuKeySource))

    pendingMapAbility = contract.mapAbility
    pendingMapContract = contract

    local activationOk, activationError = pcall(function()
        contract.hero:ActivateFPCameraMenuAbility(
            contract.mapAbilityTriggerTag,
            FName(menuKey),
            nil)
    end)
    if not activationOk then
        failPendingOpen(
            serial,
            "ActivateFPCameraMenuAbility failed: " ..
                tostring(activationError))
        return
    end

    log("map gameplay ability requested | ability=" ..
        tostring(objectName(contract.mapAbility)) ..
        " | class=" .. contract.mapAbilityClassName ..
        " | trigger=" .. contract.mapAbilityTriggerTagName)
    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(
            K.OPEN_VERIFICATION_DELAY_MS,
            function()
                verifyTeleportMapOpen(serial)
            end)
    end)
    if not scheduled then
        failPendingOpen(
            serial,
            "map verification scheduling failed: " ..
                tostring(scheduleError))
    end
end

-- URODWidgetData::MenuWidgetMap is the table the menu system itself uses to turn
-- an EMenuKind into a widget class. Reading it back is the difference between
-- "66 should be the fast travel map" and knowing it on this build.
local function reportMenuWidgetClass(menuKind)
    local reported = "<unresolved>"
    local ok, readError = pcall(function()
        local widgetData = FindFirstOf("RODWidgetData")
        if not isValid(widgetData) then
            error("no loaded RODWidgetData")
        end
        local menuWidgetMap = widgetData.MenuWidgetMap
        if menuWidgetMap == nil then
            error("MenuWidgetMap is unavailable")
        end
        menuWidgetMap:ForEach(function(key, value)
            if tonumber(key:get()) == menuKind then
                local widgetClass = value:get()
                if isValid(widgetClass) then
                    reported = tostring(objectName(widgetClass))
                end
            end
        end)
    end)
    if not ok then
        log(string.format(
            "MENU WIDGET MAP | EMenuKind %d unreadable: %s",
            menuKind, tostring(readError)))
        return nil
    end
    log(string.format(
        "MENU WIDGET MAP | EMenuKind %d -> %s", menuKind, reported))
    return reported
end

-- The fast travel screen is a plain menu, not a first-person-camera ability:
-- natively a terminal opens it through GA_AvatarMenu_AccessTerminal_C, which
-- needs a real terminal actor as its Target.
--
-- ARODPlayerState::OpenMenu(66) was tried first and does nothing observable:
-- the log showed the kind resolving correctly and then "found 0 presented of 0
-- constructed". It is not the local UI entry point.
--
-- What is measured to work on this build is the pair FieldEquipmentMod uses for
-- its Equipment screen: construct the widget with UWidgetBlueprintLibrary::Create,
-- stamp ParentMenu and MenuKind on it before the menu manager ever sees it, then
-- hand it to RODWidgetBPFunctionLibrary's DebugOpenMenu + OpenMenu. ParentMenu is
-- also what makes Back return to the Start Menu, so the Start Menu is left open
-- instead of being torn down first.
local function openFastTravelMenu(serial)
    if serial ~= openSerial then return end

    local availability, availabilityError = fastTravelAvailability()
    if availability == nil or availability.travelable == 0 then
        failPendingOpen(
            serial,
            "Fast Travel is not available in the town map"
        )
        log("Fast Travel open refused: current world has no travel terminals (Town Map).")
        return
    end

    local controller, controllerError = resolveLocalController()
    if controller == nil then
        failPendingOpen(serial, tostring(controllerError))
        return
    end
    local umgLibrary, umgError = resolveUmgLibrary()
    if umgLibrary == nil then
        failPendingOpen(serial, tostring(umgError))
        return
    end
    local rodLibrary, rodError = resolveRodWidgetLibrary()
    if rodLibrary == nil then
        failPendingOpen(serial, tostring(rodError))
        return
    end

    reportMenuWidgetClass(K.MENU_KIND_FAST_TRAVEL_MENU)

    local widgetClass = StaticFindObject(K.FAST_TRAVEL_WIDGET_CLASS)
    if not isValid(widgetClass) then
        failPendingOpen(
            serial,
            K.FAST_TRAVEL_WIDGET_CLASS .. " is not loaded")
        return
    end

    local parentMenu = nil
    if activeContext ~= nil and isValid(activeContext.mainMenu) then
        parentMenu = activeContext.mainMenu
    end

    -- Step-logged before the native calls: an access violation inside them takes
    -- the process down with no Lua error left to catch.
    log(string.format(
        "MAP OPEN | Create + DebugOpenMenu + OpenMenu | kind=%d | parent=%s",
        K.MENU_KIND_FAST_TRAVEL_MENU,
        tostring(objectName(parentMenu))))

    local widget = nil
    local openedOk, openError = pcall(function()
        widget = umgLibrary:Create(controller, widgetClass, controller)
        if not isValid(widget) then
            error("fast travel widget creation returned null")
        end
        if parentMenu ~= nil then
            widget.ParentMenu = parentMenu
        end
        widget.MenuKind = K.MENU_KIND_FAST_TRAVEL_MENU

        -- Settled by measurement: Create already leaves PlayerControllerRef and
        -- UIManagerRef populated here. v0.6.0 wrote them on the theory that they
        -- were null and were the cause of the <MISSING STRING TABLE ENTRY>
        -- labels. UE4SS rejected both writes outright --
        -- "[push_weakobjectproperty] Operation::Set is not supported" -- and the
        -- read-back still showed the correct UI manager and controller. The
        -- theory is dead, so the writes are gone. The read-back is kept as a
        -- debug line so a real regression in these refs stays visible.
        local controllerRefName = "<unset>"
        local uiManagerRefName = "<unset>"
        pcall(function()
            controllerRefName =
                tostring(objectName(weakObject(widget.PlayerControllerRef)))
        end)
        pcall(function()
            uiManagerRefName =
                tostring(objectName(weakObject(widget.UIManagerRef)))
        end)
        dbg(string.format(
            "WIDGET REFS | PlayerControllerRef=%s | UIManagerRef=%s",
            controllerRefName,
            uiManagerRefName))

        local handle = rodLibrary:DebugOpenMenu(controller, widget)
        if handle == nil then
            error("DebugOpenMenu returned no fast travel handle")
        end
        rodLibrary:OpenMenu(controller, handle)
    end)
    if not openedOk then
        failPendingOpen(
            serial,
            "fast travel menu open failed: " .. tostring(openError))
        return
    end

    log("fast travel widget constructed | " .. tostring(objectName(widget)))

    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(
            K.OPEN_VERIFICATION_DELAY_MS,
            function()
                if serial == openSerial and openBusy then
                    failPendingOpen(
                        serial,
                        "EndOpenAnimEvent did not present the fast travel "
                            .. "screen within " ..
                            tostring(K.OPEN_VERIFICATION_DELAY_MS) ..
                            " ms")
                end
            end)
    end)
    if not scheduled then
        failPendingOpen(
            serial,
            "map verification scheduling failed: " ..
                tostring(scheduleError))
    end
end

-- Only reached with MAP_TARGET = "map". The fast travel path never closes the
-- Start Menu, so it never waits on the Start Menu's ability.
local function waitForMainMenuAbilityEnd(
    serial, contract, elapsedMs
)
    if serial ~= openSerial then return end

    local transitionOk, transitionError = xpcall(function()
        local mainMenuActive =
            isOwnedAbilityClassActive(
                K.MAIN_MENU_ABILITY_CLASS,
                contract.abilitySystem)
        if not mainMenuActive then
            activateTeleportMapAbility(serial, contract)
            return
        end

        if elapsedMs >= K.MENU_TRANSITION_TIMEOUT_MS then
            error(K.MAIN_MENU_ABILITY_CLASS .. " remained active for " ..
                tostring(elapsedMs) .. " ms")
        end

        ExecuteInGameThreadWithDelay(K.MENU_TRANSITION_POLL_MS, function()
            waitForMainMenuAbilityEnd(
                serial,
                contract,
                elapsedMs + K.MENU_TRANSITION_POLL_MS)
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
        -- Alt+Enter, and anything else that rebuilds the viewport, can leave the
        -- screen up but unfocused: the icons keep tracking the mouse and nothing
        -- closes it. The flag then blocks every later open, which is the "estado
        -- todo errado" part. If the screen it refers to is gone or no longer
        -- presented, the flag is stale -- clear it and carry on rather than
        -- refusing for the rest of the session.
        if isValid(teleportMapWidget)
            and isPresentedTeleportMapWidget(teleportMapWidget) then
            log("Fast Travel open refused: teleport map is already active")
            return
        end
        log("stale teleport map state cleared: the screen it referred to is " ..
            "no longer presented")
        teleportMapModeActive = false
        teleportMapWidget = nil
        teleportMapWidgetKey = nil
        mapTeleportBusy = false
        mapIconDestinations = {}
        openSerial = openSerial + 1
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
    teleportMapWidget = nil
    mapTeleportBusy = false
    mapIconDestinations = {}
    pendingMapAbility = nil
    pendingMapContract = nil

    local state = nil
    local stateOk, stateError =
        xpcall(function()
            local recovered =
                recoverCompletedNativeTravel("before teleport map")
            state = logNativeTravelState("before teleport map")
            if state.fastTravelStatus == K.FAST_TRAVEL_STATUS_DECIDE
                and recovered ~= true then
                error("a native Fast Travel transaction is still active")
            end
            if state.accessibleStatus ~= K.ACCESSIBLE_STATUS_NONE
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

    -- The fast travel screen opens as a submenu of the Start Menu, the way
    -- Equipment does. Nothing is torn down, so there is no ability to wait on.
    if CONFIG.MAP_TARGET ~= "map" then
        teleportMapModeActive = true
        log("opening fast travel map as a Start Menu submenu | source=" ..
            tostring(source))
        openFastTravelMenu(serial)
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
                K.MAP_MENU_ABILITY_CLASS,
                abilityContract.abilitySystem)
        if mapMenuActive then
            error(K.MAP_MENU_ABILITY_CLASS .. " is already active")
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

    log("waiting for " .. K.MAIN_MENU_ABILITY_CLASS .. " to end")
    waitForMainMenuAbilityEnd(serial, abilityContract, 0)
end

local function scheduleFastTravelOpen(source)
    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(0, function()
            requestFastTravelOpen(source)
        end)
    end)
    if not scheduled then
        log("teleport map scheduling failed: " ..
            tostring(scheduleError))
    end
end

local function resolveSelectedMapIcon(mapWidget)
    if not isValid(mapWidget)
        or not nameContains(mapWidget, K.MAP_MENU_WIDGET_FRAGMENT) then
        error("exact " .. K.MAP_MENU_WIDGET_FRAGMENT ..
            " reference map is unavailable")
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

    local kindName = K.ELIGIBLE_MAP_ICON_KINDS[kind]
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

-- TWO CANDIDATE TELEPORTS WERE TRIED IN THE GAME; ONE WORKS.
--
-- ARODAvatarCharacter::ServerDebugTeleportGimmick was this mod's documented
-- teleport and moves nothing. ARODGameState carries both a DebugTeleportPos
-- field and its own ServerDebugTeleportGimmick, so the avatar call looks like it
-- parks a position for a later gimmick warp rather than performing one.
--
-- ARODInGamePlayerController::ServerDebugTeleport(FVector) also moves nothing.
-- Measured directly: "ServerDebugTeleport called=true" and then, half a second
-- later, the hero still 23703 cm from the target.
--
-- AActor::K2_TeleportTo is the engine's own and lands the hero on the target,
-- read back at 0 cm. It is what this uses. The other two are recorded here so
-- they are not tried again.
--
-- The arrival is still read back from the world rather than assumed, because a
-- teleport into unstreamed World Partition cells is a real possibility and a
-- silent failure is what cost this mod two sessions.
local TELEPORT_VERIFY_DELAY_MS = 500
local TELEPORT_ARRIVAL_TOLERANCE = 200.0

local function heroLocation()
    local hero, heroError = resolveLocalHero()
    if hero == nil then return nil, tostring(heroError) end
    local position = nil
    local ok, readError = pcall(function()
        local location = hero:K2_GetActorLocation()
        position = {
            X = tonumber(location.X),
            Y = tonumber(location.Y),
            Z = tonumber(location.Z),
        }
    end)
    if not ok or position == nil or position.X == nil then
        return nil, "hero location unreadable: " .. tostring(readError)
    end
    return position, nil
end

local function spatialDistance(a, b)
    if a == nil or b == nil then return nil end
    local dx = a.X - b.X
    local dy = a.Y - b.Y
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function performTeleport(position, label, onArrived)
    local hero, heroError = resolveLocalHero()
    if hero == nil then
        log("FAST TRAVEL ERROR | " .. tostring(heroError))
        return false
    end

    local before = heroLocation()
    local callOk, acceptedOrError = pcall(function()
        return hero:K2_TeleportTo(position, hero:K2_GetActorRotation())
    end)
    if not callOk then
        log("FAST TRAVEL ERROR | K2_TeleportTo failed: " ..
            tostring(acceptedOrError))
        return false
    end
    if acceptedOrError ~= true then
        log(string.format(
            "TELEPORT | %s | K2_TeleportTo REJECTED target=(%.1f, %.1f, %.1f)",
            label, position.X, position.Y, position.Z))
        return false
    end

    log(string.format(
        "TELEPORT | %s | K2_TeleportTo | from=(%s) | target=(%.1f, %.1f, %.1f)",
        label,
        before == nil and "?" or string.format(
            "%.1f, %.1f, %.1f", before.X, before.Y, before.Z),
        position.X, position.Y, position.Z))

    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(TELEPORT_VERIFY_DELAY_MS, function()
            local after = heroLocation()
            local distance = spatialDistance(after, position)
            if distance == nil then
                log("TELEPORT | " .. label ..
                    " | arrival unverifiable; hero location unreadable")
                return
            end
            if distance <= TELEPORT_ARRIVAL_TOLERANCE then
                log(string.format(
                    "TELEPORT | %s | arrived | %.0f cm from target",
                    label, distance))
                if type(onArrived) == "function" then
                    local callbackOk, callbackError = pcall(onArrived)
                    if not callbackOk then
                        log("FAST TRAVEL ERROR | arrival callback failed: " ..
                            tostring(callbackError))
                    end
                end
            else
                log(string.format(
                    "TELEPORT | %s | DID NOT ARRIVE | %.0f cm from target",
                    label, distance))
            end
        end)
    end)
    if not scheduled then
        log("FAST TRAVEL ERROR | teleport verification scheduling failed: " ..
            tostring(scheduleError))
        return false
    end
    return true
end

local function performMapCoordinateTeleport(
    destination, label, onArrived, onFinished
)
    local finished = false
    local function finish(success, reason)
        if finished then return end
        finished = true
        if success ~= true and reason ~= nil then
            log("CURSOR TRAVEL ERROR | " .. tostring(reason))
        end
        if type(onFinished) == "function" then
            local callbackOk, callbackError =
                pcall(onFinished, success == true, reason)
            if not callbackOk then
                log("CURSOR TRAVEL ERROR | completion callback failed: " ..
                    tostring(callbackError))
            end
        end
    end

    if type(destination) ~= "table"
        or type(destination.X) ~= "number"
        or type(destination.Y) ~= "number"
        or destination.X ~= destination.X
        or destination.Y ~= destination.Y then
        finish(false, "world cursor coordinates are invalid")
        return false
    end

    local hero, heroError = resolveLocalHero()
    if hero == nil then
        finish(false, heroError)
        return false
    end
    local origin, originError = heroLocation()
    if origin == nil then
        finish(false, originError)
        return false
    end

    local capsule = nil
    local halfHeight = nil
    local radius = nil
    local capsuleOk, capsuleError = pcall(function()
        capsule = hero.CapsuleComponent
        if not isValid(capsule) then
            error("hero capsule is unavailable")
        end
        halfHeight = tonumber(capsule:GetScaledCapsuleHalfHeight())
        radius = tonumber(capsule:GetScaledCapsuleRadius())
    end)
    if not capsuleOk or halfHeight == nil or halfHeight ~= halfHeight
        or halfHeight <= 0.0 or halfHeight > 1000.0
        or radius == nil or radius ~= radius
        or radius <= 0.0 or radius > halfHeight then
        finish(false, "hero capsule contract failed: " ..
            tostring(capsuleError or
                string.format("radius=%s halfHeight=%s",
                    tostring(radius), tostring(halfHeight))))
        return false
    end

    local gameplayStatics =
        StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local sourceActorClass =
        StaticFindObject("/Script/Engine.TargetPoint")
    local sourceComponentClass =
        StaticFindObject(
            "/Script/Engine.WorldPartitionStreamingSourceComponent")
    if not isValid(gameplayStatics)
        or not isValid(sourceActorClass)
        or not isValid(sourceComponentClass) then
        finish(false,
            "World Partition streaming-source contract is unavailable")
        return false
    end

    local sourceTransform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = {
            X = destination.X,
            Y = destination.Y,
            Z = origin.Z,
        },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local identityTransform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local sourceActor = nil
    local sourceComponent = nil
    local cleaned = false
    local pollHandle = nil
    local watchdogHandle = nil
    local function cancelOwnedAction(handle)
        if handle == nil then return end
        local cancelled, cancelError = pcall(function()
            return CancelDelayedAction(handle)
        end)
        if not cancelled then
            log("CURSOR TRAVEL ERROR | delayed-action cancellation failed: " ..
                tostring(cancelError))
        end
    end
    local function stopPolling()
        local handle = pollHandle
        pollHandle = nil
        cancelOwnedAction(handle)
    end
    local function stopWatchdog()
        local handle = watchdogHandle
        watchdogHandle = nil
        cancelOwnedAction(handle)
    end
    local function cleanupSource()
        if cleaned then return end
        cleaned = true
        if isValid(sourceComponent) then
            pcall(function()
                sourceComponent:DisableStreamingSource()
            end)
        end
        if isValid(sourceActor) then
            pcall(function() sourceActor:K2_DestroyActor() end)
        end
    end
    local function abort(reason)
        stopPolling()
        stopWatchdog()
        cleanupSource()
        finish(false, reason)
    end

    local sourceOk, sourceError = pcall(function()
        sourceActor = gameplayStatics:BeginDeferredActorSpawnFromClass(
            hero,
            sourceActorClass,
            sourceTransform,
            1,
            hero,
            1)
        if not isValid(sourceActor) then
            error("temporary TargetPoint creation returned null")
        end
        local completedActor = gameplayStatics:FinishSpawningActor(
            sourceActor,
            sourceTransform,
            1)
        if not isValid(completedActor)
            or objectName(completedActor) ~= objectName(sourceActor) then
            error("temporary TargetPoint completion failed")
        end
        sourceActor = completedActor
        sourceActor:SetActorHiddenInGame(true)
        sourceActor:SetActorEnableCollision(false)

        sourceComponent = sourceActor:AddComponentByClass(
            sourceComponentClass,
            false,
            identityTransform,
            false)
        if not isValid(sourceComponent) then
            error("WorldPartitionStreamingSourceComponent creation returned null")
        end
        sourceComponent:DisableStreamingSource()
        sourceComponent.TargetBehavior = 0
        sourceComponent.Priority = 0
        sourceComponent.TargetState = 1
        sourceComponent:EnableStreamingSource()
        if sourceComponent:IsStreamingSourceEnabled() ~= true then
            error("World Partition streaming source did not enable")
        end
    end)
    if not sourceOk then
        abort("streaming source creation failed: " .. tostring(sourceError))
        return false
    end

    log(string.format(
        "CURSOR PRELOAD | worldXY=(%.1f, %.1f) | source=%s | player not moved",
        destination.X,
        destination.Y,
        tostring(objectName(sourceActor))))

    local transactionSerial = openSerial
    local pollCount = 0
    local stableReadyCount = 0
    local lastReadyTarget = nil
    local lastProbeError = "destination cell has not activated yet"

    -- Navmesh is an AI pathfinding product, not the authoritative geometry
    -- beneath the player. Some valid solid surfaces never expose navmesh, while
    -- a streamed navmesh does not prove that the complete player capsule is
    -- supported. The canonical landing contract is therefore physical:
    --
    --   * WorldStatic must answer beneath the centre and eight samples spanning
    --     the real scaled capsule footprint;
    --   * all samples must stay on one locally coherent surface;
    --   * two consecutive probes must agree;
    --   * K2_TeleportTo must finally accept the capsule without encroachment.
    --
    -- A missing sample is an edge, void, water-only area, or unloaded collision
    -- cell. There is no substitute destination and the player never moves.
    local function probeDestination()
        local floorLibrary = StaticFindObject(
            "/Script/ROD.Default__ROD_BlueprintFunctionLibrary")
        if not isValid(floorLibrary) then
            return nil, "WorldStatic floor-validation contract is unavailable"
        end

        local footprintRadius = radius * 0.70
        local diagonal = footprintRadius * 0.70710678118655
        local samples = {
            { X = 0.0, Y = 0.0 },
            { X = footprintRadius, Y = 0.0 },
            { X = -footprintRadius, Y = 0.0 },
            { X = 0.0, Y = footprintRadius },
            { X = 0.0, Y = -footprintRadius },
            { X = diagonal, Y = diagonal },
            { X = diagonal, Y = -diagonal },
            { X = -diagonal, Y = diagonal },
            { X = -diagonal, Y = -diagonal },
        }
        local floorMinZ = nil
        local floorMaxZ = nil
        for index, offset in ipairs(samples) do
            local sampleX = destination.X + offset.X
            local sampleY = destination.Y + offset.Y
            local tracedFloor = { X = 0.0, Y = 0.0, Z = 0.0 }
            local floorOk, floorFound = pcall(function()
                return floorLibrary:GetZLineTraceLoc(
                    tracedFloor,
                    hero,
                    {
                        X = sampleX,
                        Y = sampleY,
                        Z = origin.Z + 50000.0,
                    },
                    100000.0,
                    0)
            end)
            local floorX = tonumber(tracedFloor.X)
            local floorY = tonumber(tracedFloor.Y)
            local floorZ = tonumber(tracedFloor.Z)
            if not floorOk or floorFound ~= true
                or floorX == nil or floorY == nil or floorZ == nil
                or floorX ~= floorX or floorY ~= floorY or floorZ ~= floorZ then
                return nil, string.format(
                    "WorldStatic does not support capsule sample %d/9",
                    index)
            end
            local horizontalError = math.sqrt(
                (floorX - sampleX) * (floorX - sampleX)
                    + (floorY - sampleY) * (floorY - sampleY))
            if horizontalError > 25.0 then
                return nil, string.format(
                    "WorldStatic sample %d moved %.0f cm from its trace",
                    index, horizontalError)
            end
            floorMinZ = floorMinZ == nil
                and floorZ or math.min(floorMinZ, floorZ)
            floorMaxZ = floorMaxZ == nil
                and floorZ or math.max(floorMaxZ, floorZ)
        end

        local floorSpread = floorMaxZ - floorMinZ
        local maximumSpread = math.max(40.0, radius * 1.5)
        if floorSpread > maximumSpread then
            return nil, string.format(
                "WorldStatic varies %.0f cm beneath the %.0f cm capsule radius",
                floorSpread, radius)
        end

        return {
            position = {
                X = destination.X,
                Y = destination.Y,
                Z = floorMaxZ + halfHeight + 5.0,
            },
            floorMinZ = floorMinZ,
            floorMaxZ = floorMaxZ,
            floorSpread = floorSpread,
            sampleCount = #samples,
        }, nil
    end

    local function teleportValidatedTarget(validated)
        stopPolling()
        local target = validated.position
        log(string.format(
            "CURSOR SAFE | WorldStatic footprint=%d/9 | floorZ=%.1f..%.1f "
                .. "| spread=%.1f | capsule r=%.1f hh=%.1f | targetZ=%.1f",
            validated.sampleCount,
            validated.floorMinZ,
            validated.floorMaxZ,
            validated.floorSpread,
            radius,
            halfHeight,
            target.Z))

        local arrived = false
        local moveStarted = performTeleport(target, label, function()
            arrived = true
            stopWatchdog()
            if type(onArrived) == "function" then
                local callbackOk, callbackError = pcall(onArrived)
                if not callbackOk then
                    log("CURSOR TRAVEL ERROR | arrival callback failed: " ..
                        tostring(callbackError))
                end
            end
            finish(true, nil)
            ExecuteInGameThreadWithDelay(750, cleanupSource)
        end)
        if not moveStarted then
            abort("K2_TeleportTo rejected the validated destination")
            return
        end

        local watchdogOk, watchdogError = pcall(function()
            watchdogHandle = ExecuteInGameThreadWithDelay(2500, function()
                watchdogHandle = nil
                if arrived or finished then return end
                abort("arrival verification did not confirm the destination")
            end)
            if type(watchdogHandle) ~= "number" then
                error("arrival watchdog returned no action handle")
            end
        end)
        if not watchdogOk then
            abort("arrival watchdog scheduling failed: " ..
                tostring(watchdogError))
        end
    end

    local scheduleOk, handleOrError = pcall(function()
        return LoopInGameThreadWithDelay(100, function()
            local stepOk, stepError = xpcall(function()
                if finished then
                    stopPolling()
                    return
                end
                if transactionSerial ~= openSerial
                    or not teleportMapModeActive then
                    abort("map closed while destination was loading")
                    return
                end
                if not isValid(sourceActor)
                    or not isValid(sourceComponent) then
                    abort("streaming source became invalid")
                    return
                end

                pollCount = pollCount + 1
                local validated, probeError = probeDestination()
                if validated ~= nil then
                    local target = validated.position
                    local stable = lastReadyTarget ~= nil
                        and math.abs(target.X - lastReadyTarget.X) <= 25.0
                        and math.abs(target.Y - lastReadyTarget.Y) <= 25.0
                        and math.abs(target.Z - lastReadyTarget.Z) <= 25.0
                    if stable then
                        stableReadyCount = stableReadyCount + 1
                    else
                        stableReadyCount = 1
                    end
                    lastReadyTarget = {
                        X = target.X,
                        Y = target.Y,
                        Z = target.Z,
                    }
                    lastProbeError = nil
                else
                    stableReadyCount = 0
                    lastReadyTarget = nil
                    lastProbeError = tostring(probeError)
                end
                if stableReadyCount >= 2 then
                    log(string.format(
                        "CURSOR PRELOAD | destination collision ready after %d ms",
                        pollCount * 100))
                    teleportValidatedTarget(validated)
                    return
                end
                if pollCount >= 100 then
                    abort("destination did not expose a stable "
                        .. "WorldStatic capsule footprint within "
                        .. "10000 ms | "
                        .. tostring(lastProbeError))
                end
            end, debug.traceback)
            if not stepOk then
                abort("streaming callback failed: " ..
                    tostring(stepError))
            end
        end)
    end)
    if not scheduleOk or type(handleOrError) ~= "number" then
        abort("streaming loop scheduling failed: " ..
            tostring(handleOrError))
        return false
    end
    pollHandle = handleOrError
    return true
end
local function finalizeMapTeleport(source)
    local finalizeOk, finalizeError = xpcall(function()
        restorePlayableCamera(source)
    end, debug.traceback)

    teleportMapModeActive = false
    mapTeleportBusy = false
    cursorTravelBusy = false
    mapIconDestinations = {}
    openBusy = false
    teleportMapWidgetKey = nil
    teleportMapWidget = nil
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

    if not performTeleport(
        destination.position,
        string.format("%s icon", tostring(iconKindName))
    ) then
        mapTeleportBusy = false
        return
    end

    local closed, closeError = pcall(function()
        if isPresentedTeleportMapWidget(mapWidget) then
            local controller, controllerError =
                resolveLocalController()
            if controller == nil then error(controllerError) end
            controller:EndMapMenu(K.MENU_END_ALL_CLOSE)
        end
    end)
    if not closed then
        mapTeleportBusy = false
        failCurrentMenu("teleport map close failed: " ..
            tostring(closeError))
        return
    end

    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(K.TELEPORT_FINALIZE_DELAY_MS, function()
            finalizeMapTeleport(source)
        end)
    end)
    if not scheduled then
        mapTeleportBusy = false
        failCurrentMenu("teleport finalization scheduling failed: " ..
            tostring(scheduleError))
    end
end

--========================================================--
--        NATIVE DECISION, MOD-PERFORMED TELEPORT         --
--========================================================--
-- Confirming a destination on WBP_Map_FastTravel_C calls
-- ARODPlayerState::ServerDecideFastTravel(ID) and then waits for the server to
-- move the hero. Away from a terminal the player state sits at
-- EFastTravelStatus::Disable, so the server does nothing and the screen hangs
-- with its cursor still live. That is exactly what was measured: three
-- ServerDecideFastTravel calls about 200 ms apart for one confirm, no travel,
-- and a stuck screen.
--
-- The decided ID is the useful part, and it is better than anything the old
-- WBP_Map_C path had: ARODGameState keeps every ARODAccessibleGimmickBase in
-- RODAccessibleGimmicks, each carrying its own ID and the transforms the game
-- warps players to. The destination therefore comes from the terminal actor
-- rather than from a screen-space icon position.
--
-- At a real terminal the native transaction works and must be left alone, so
-- this runs only while the mod's own screen is open and only when the player
-- state says the native path will not fire.

local nativeDecisionBusy = false
local NATIVE_DECISION_COOLDOWN_MS = 1500

local function usableTranslation(source)
    local position = nil
    local ok = pcall(function()
        position = {
            X = tonumber(source.X),
            Y = tonumber(source.Y),
            Z = tonumber(source.Z),
        }
    end)
    if not ok or position == nil
        or position.X == nil or position.Y == nil or position.Z == nil then
        return nil
    end
    -- A terminal at the world origin is a default-constructed transform, not a
    -- place worth dropping the hero into.
    if position.X == 0.0 and position.Y == 0.0 and position.Z == 0.0 then
        return nil
    end
    return position
end

local function terminalDestination(gimmick)
    local position = nil
    local source = nil

    pcall(function()
        local warpOut = gimmick.WarpOutTransforms
        if warpOut == nil then return end
        warpOut:ForEach(function(key, value)
            if position ~= nil then return end
            local transform = value:get()
            if transform == nil then return end
            local candidate = usableTranslation(transform.Translation)
            if candidate ~= nil then
                position = candidate
                local keyName = "?"
                pcall(function()
                    keyName = exactFNameString(key:get(), "WarpOutTransforms key")
                end)
                source = "WarpOutTransforms[" .. keyName .. "]"
            end
        end)
    end)

    if position == nil then
        pcall(function()
            local access = gimmick.AccessTransforms
            if access == nil or #access < 1 then return end
            local candidate = usableTranslation(access[1].Translation)
            if candidate ~= nil then
                position = candidate
                source = "AccessTransforms[1]"
            end
        end)
    end

    if position == nil then
        pcall(function()
            local candidate = usableTranslation(gimmick:K2_GetActorLocation())
            if candidate ~= nil then
                position = candidate
                source = "actor location"
            end
        end)
    end

    if position == nil then return nil end
    return { position = position, source = source, gimmick = gimmick }
end

local function resolveTerminalDestination(idName)
    local gameState, gameStateError = resolveWorldGameState()
    if gameState == nil then return nil, tostring(gameStateError) end

    local gimmicks = nil
    local listOk, listError = pcall(function()
        gimmicks = gameState.RODAccessibleGimmicks
    end)
    if not listOk or gimmicks == nil then
        return nil, "RODAccessibleGimmicks is unavailable: " ..
            tostring(listError)
    end

    local count = 0
    pcall(function() count = #gimmicks end)
    if count == 0 then
        return nil, "RODAccessibleGimmicks is empty"
    end

    for index = 1, count do
        local gimmick = nil
        pcall(function() gimmick = gimmicks[index] end)
        if isValid(gimmick) then
            local gimmickId = nil
            pcall(function()
                gimmickId =
                    exactFNameString(gimmick.ID, "accessible gimmick ID")
            end)
            if gimmickId == idName then
                local destination = terminalDestination(gimmick)
                if destination == nil then
                    return nil, "terminal " .. idName ..
                        " exposes no usable destination transform"
                end
                return destination, nil
            end
        end
    end
    return nil, string.format(
        "no accessible gimmick among %d carries ID %s", count, idName)
end

-- The screen is waiting on a transaction that will never land, so it has to be
-- dismissed here or it keeps the cursor and swallows input.
local function dismissFastTravelScreen()
    local dismissed, dismissError = pcall(function()
        local rodLibrary, libraryError = resolveRodWidgetLibrary()
        if rodLibrary == nil then error(libraryError) end
        local controller, controllerError = resolveLocalController()
        if controller == nil then error(controllerError) end
        rodLibrary:EndMenu(controller)
        controller:EndMainMenu(true)
    end)
    if not dismissed then
        log("FAST TRAVEL ERROR | menu dismissal failed: " ..
            tostring(dismissError))
    end

    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(K.TELEPORT_FINALIZE_DELAY_MS, function()
            finalizeMapTeleport("fast travel map")
        end)
    end)
    if not scheduled then
        log("FAST TRAVEL ERROR | teleport finalization scheduling failed: " ..
            tostring(scheduleError))
    end
end

-- Everything the mod believes about the screen, reset. Separated from
-- dismissFastTravelScreen because the escape hatch has to work when the screen
-- is already unreachable and dismissing it may not take.
local function forceCloseMapScreen(source)
    log("forced map dismissal | source=" .. tostring(source))
    pcall(dismissFastTravelScreen)
    pcall(function()
        local rodLibrary = resolveRodWidgetLibrary()
        local controller = resolveLocalController()
        if rodLibrary ~= nil and controller ~= nil then
            -- The screen survives with its input dead, so hand input back to
            -- whatever menu remains rather than leaving the player with none.
            rodLibrary:SetCurrentMenuInputActionEnable(controller, true)
        end
    end)
    teleportMapModeActive = false
    teleportMapWidget = nil
    teleportMapWidgetKey = nil
    mapTeleportBusy = false
    cursorTravelBusy = false
    openBusy = false
    mapIconDestinations = {}
    openSerial = openSerial + 1
end

-- A confirmed pin reaches ServerDecideFastTravel with ID=None, because a pin has
-- no terminal ID to decide on. The focused widget is what says which pin it was.
-- URODIconForMapWidgetBase and FRODMapPin both carry a Timestamp, which is the
-- only field the two sides share, so that is the join.
-- Absolute (screen) position of a widget's top-left. Absolute rather than slot
-- position because the cursor and the icons need not share a canvas, and slot
-- coordinates are only comparable within one.
local function handleNativeFastTravelDecision(idName)
    local state = nil
    local stateOk, stateError = pcall(function()
        state = readNativeTravelState()
    end)
    if not stateOk then
        log("FAST TRAVEL ERROR | native state unreadable at decision: " ..
            tostring(stateError))
        return
    end
    if state.fastTravelStatus == K.FAST_TRAVEL_STATUS_ENABLE
        or state.accessingTerminal == true then
        log("native Fast Travel is live; leaving the decision to the game" ..
            " | ID=" .. idName)
        return
    end

    local destination, destinationError = resolveTerminalDestination(idName)
    if destination == nil then
        log("FAST TRAVEL ERROR | " .. tostring(destinationError))
        return
    end

    log(string.format(
        "MOD TELEPORT | ID=%s | from=%s | pos=(%.1f, %.1f, %.1f) | actor=%s",
        idName,
        tostring(destination.source),
        destination.position.X,
        destination.position.Y,
        destination.position.Z,
        tostring(objectName(destination.gimmick))))

    if performTeleport(destination.position, "terminal " .. idName) then
        dismissFastTravelScreen()
    end
end

local function interceptMapTeleport(
    mapParameter, buttonParameter, clickTypeParameter, source
)
    if not teleportMapModeActive then return end

    local mapWidget = hookValue(mapParameter)
    if not isValid(mapWidget)
        or not nameContains(mapWidget, K.MAP_MENU_WIDGET_FRAGMENT) then
        return
    end

    local button = tonumber(hookValue(buttonParameter))
    if button ~= K.ACCEPT_BUTTON then return end
    if clickTypeParameter ~= nil then
        local clickType = tonumber(hookValue(clickTypeParameter))
        if clickType ~= K.SINGLE_CLICK then return end
    end

    if not consumeButton(buttonParameter) then return end
    if mapTeleportBusy then return end
    mapTeleportBusy = true

    local scheduled, scheduleError = pcall(function()
        ExecuteInGameThreadWithDelay(0, function()
            requestSelectedMapTeleport(mapWidget, source)
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
    if not isValid(mapWidget) then return end

    local accepted
    if updateIconMemo.owner == mapIconDestinations
        and updateIconMemo.widget == mapWidget then
        accepted = updateIconMemo.accepted
    else
        accepted = nameContains(mapWidget, K.MAP_MENU_WIDGET_FRAGMENT)
        updateIconMemo.owner = mapIconDestinations
        updateIconMemo.widget = mapWidget
        updateIconMemo.accepted = accepted
    end
    if not accepted then return end

    local kind = tonumber(hookValue(kindParameter))
    if kind == nil then
        error("UpdateIcon EMapIconKind decode failed")
    end
    if K.ELIGIBLE_MAP_ICON_KINDS[kind] == nil then return end

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
        K.ELIGIBLE_MAP_ICON_KINDS[kind],
        kind,
        x,
        y,
        z,
        tostring(mapIconDestinations[iconKey].actor or "<none>")))
end

local function closeMainMenuFromFastTravel()
    if menuCloseBusy then return end
    menuCloseBusy = true

    ExecuteInGameThreadWithDelay(0, function()
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
end

local function handleButton(widgetParameter, buttonParameter)
    local widget = hookValue(widgetParameter)
    local button = hookValue(buttonParameter)
    if not isValid(widget) then return end

    if isFastTravelIcon(widget) then
        if button == K.ACCEPT_BUTTON then
            if consumeButton(buttonParameter) then
                scheduleFastTravelOpen("Start Menu")
            end
        elseif button == K.BACK_BUTTON then
            if consumeButton(buttonParameter) then
                closeMainMenuFromFastTravel()
            end
        elseif button == K.DPAD_UP or button == K.LSTICK_UP then
            if consumeButton(buttonParameter) then
                withInputLock(function()
                    focusRowAbove(activeContext)
                end)
            end
        elseif button == K.DPAD_DOWN or button == K.LSTICK_DOWN then
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
        or not nameContains(widget, K.MAIN_MENU_LIST_FRAGMENT) then
        return
    end
    if not ownsNativeBoundary(context) then return end

    local index = nil
    pcall(function() index = widget:GetItemIndex() end)
    if type(index) ~= "number" then return end

    local down = button == K.DPAD_DOWN or button == K.LSTICK_DOWN
    local up = button == K.DPAD_UP or button == K.LSTICK_UP
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

-- For observation only. These hooks exist to describe the native fast travel
-- flow in the log; losing one costs a diagnostic, not the feature, so it must
-- never take the mod down the way requireHook does.
local function optionalHook(path, callback)
    local ok, hookError = pcall(function()
        RegisterHook(path, function(...)
            pcall(callback, ...)
        end)
    end)
    if not ok then
        log("OBSERVATION HOOK UNAVAILABLE | " .. path ..
            " | " .. tostring(hookError))
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
        if not ownsNativeBoundary(context) then return end

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

-- Observation only. Every first-person-camera menu the game opens -- the Start
-- Menu included -- comes through here, so one Start Menu open is enough to learn
-- the exact argument shape this mod has to reproduce. It never fails the mod:
-- a decode problem here must not cost the user their Fast Travel row.
requireHook(
    "/Script/ROD.RODAvatarCharacter:ActivateFPCameraMenuAbility",
    function(selfParameter, tagParameter, keyParameter, targetParameter)
        pcall(function()
            local avatar = hookValue(selfParameter)
            if not isValid(avatar) then return end

            local tagName = "<unreadable>"
            pcall(function()
                tagName = exactFNameString(
                    hookValue(tagParameter).TagName, "EventTag TagName")
            end)

            local menuKey = "<unreadable>"
            pcall(function()
                menuKey = exactFNameString(
                    hookValue(keyParameter), "MenuKey")
            end)

            local targetName = "<null>"
            pcall(function()
                local target = hookValue(targetParameter)
                if isValid(target) then
                    targetName = tostring(objectName(target))
                end
            end)

            local known = observedMenuKeys[tagName]
            observedMenuKeys[tagName] = menuKey
            if known == nil then
                observedMenuKeyOrder[#observedMenuKeyOrder + 1] = tagName
            end
            if known ~= menuKey then
                log(string.format(
                    "NATIVE FP MENU | tag=%s | menuKey=%s | target=%s | avatar=%s",
                    tagName,
                    menuKey,
                    targetName,
                    tostring(objectName(avatar))))
            else
                dbg(string.format(
                    "native FP menu repeat | tag=%s | menuKey=%s", tagName, menuKey))
            end
        end)
    end
)

-- The fast travel screen's own input path. Nothing here consumes or redirects
-- anything: the open question is whether URODFastTravelMenuWidget already
-- performs the teleport by itself once a terminal icon is confirmed, and these
-- three lines plus ServerDecideFastTravel answer it from one session.
optionalHook(
    "/Script/ROD.RODFastTravelMenuWidget:OnDetailMapTermialIconClickDelegate",
    function(selfParameter, widgetParameter, buttonParameter, typeParameter)
        local clicked = hookValue(widgetParameter)
        log(string.format(
            "FT MAP | terminal icon click | icon=%s | button=%s | type=%s",
            tostring(objectName(clicked)),
            tostring(tonumber(hookValue(buttonParameter))),
            tostring(tonumber(hookValue(typeParameter)))))
        scheduleNativeTravelState("fast travel icon click", 250)
    end
)

-- Logged rather than dbg'd on purpose. WBP_Map_FastTravel_C is a terminal
-- picker: only terminal icons reach OnDetailMapTermialIconClickDelegate, which
-- is why pins on it cannot be confirmed. This generic click is the one place a
-- pin click could still surface, so what it delivers needs to be visible.
optionalHook(
    "/Script/ROD.RODFastTravelMenuWidget:OnInputClickEvent",
    function(selfParameter, widgetParameter, buttonParameter, typeParameter)
        log(string.format(
            "FT MAP | input click | widget=%s | button=%s | type=%s",
            tostring(objectName(hookValue(widgetParameter))),
            tostring(tonumber(hookValue(buttonParameter))),
            tostring(tonumber(hookValue(typeParameter)))))
    end
)

requireHook(
    "/Script/ROD.RODFastTravelMenuWidget:EndOpenAnimEvent",
    guardedHookCallback("fast-travel open animation", function(selfParameter)
        log("FT MAP | open animation finished | widget=" ..
            tostring(objectName(hookValue(selfParameter))))
        if openBusy then
            verifyTeleportMapOpen(openSerial)
        end
    end)
)

optionalHook(
    "/Script/ROD.RODPlayerState:ServerDecideFastTravel",
    function(selfParameter, idParameter)
        local id = nil
        pcall(function()
            id = exactFNameString(
                hookValue(idParameter), "ServerDecideFastTravel ID")
        end)
        log("FT MAP | native ServerDecideFastTravel | ID=" ..
            tostring(id))

        if id == nil then return end
        -- Only the mod's own screen is taken over; a real terminal keeps its
        -- native transaction.
        if not teleportMapModeActive then return end
        if id == "None" then
            log("FT MAP | no native terminal destination; " ..
                tostring(CONFIG.CURSOR_TRAVEL_KEY) ..
                " teleports to the map cursor")
            return
        end
        -- One confirm produces three of these about 200 ms apart. The gate is
        -- set here, synchronously, so the second and third never queue work.
        if nativeDecisionBusy then return end
        nativeDecisionBusy = true
        ExecuteInGameThreadWithDelay(NATIVE_DECISION_COOLDOWN_MS, function()
            nativeDecisionBusy = false
        end)

        ExecuteInGameThreadWithDelay(0, function()
            local ok, handlerError =
                xpcall(handleNativeFastTravelDecision, debug.traceback, id)
            if not ok then
                log("FAST TRAVEL ERROR | decision handling failed: " ..
                    tostring(handlerError))
            end
        end)
    end
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
        cursorTravelBusy = false
        mapIconDestinations = {}
        openSerial = openSerial + 1
        teleportMapWidgetKey = nil
        teleportMapWidget = nil
        pendingMapAbility = nil
        pendingMapContract = nil
        dbg("native restart completed; teleport map state cleared")
    end)
)

requireHook(
    "/Script/ROD.RODMenuWidgetBase:ClosedMenu",
    guardedHookCallback("ClosedMenu", function(selfParameter)
        local widget = hookValue(selfParameter)
        if mapScreenFragment(widget) ~= nil then
            teleportMapWidgetKey = nil
            teleportMapWidget = nil
            openBusy = false
            teleportMapModeActive = false
            mapTeleportBusy = false
            cursorTravelBusy = false
            mapIconDestinations = {}
            openSerial = openSerial + 1
            pendingMapAbility = nil
            pendingMapContract = nil
            dbg("teleport map closed")
        end
    end)
)

for _, notification in ipairs({
    { class = "/Script/ROD.RODMapMenuWidgetBase",
      label = "reference map" },
    { class = "/Script/ROD.RODFastTravelMenuWidget",
      label = "fast travel map" },
}) do
    local notifyOk, notifyError = pcall(function()
        NotifyOnNewObject(notification.class, function(widget)
            local fragment = mapScreenFragment(widget)
            if fragment ~= nil then
                teleportMapWidgetKey = objectName(widget)
                log("MAP SCREEN CONSTRUCTED | " .. notification.label ..
                    " | " .. tostring(teleportMapWidgetKey))
            end
        end)
    end)
    if not notifyOk then
        error("[" .. MOD_NAME ..
            "] canonical " .. notification.label ..
            " widget notification failed: " .. tostring(notifyError))
    end
end

local notifyMainMenuOk, notifyMainMenuError = pcall(function()
    NotifyOnNewObject(
        "/Script/ROD.RODConsoleMainMenuWidgetBase",
        function(mainMenu)
            if not isValid(mainMenu)
                or not nameContains(
                    mainMenu, K.MAIN_MENU_CLASS_FRAGMENT) then
                return
            end
            local menuKey = objectName(mainMenu)
            if menuKey == nil
                or pendingInjectionKeys[menuKey] == true then
                return
            end
            pendingInjectionKeys[menuKey] = true

            ExecuteInGameThreadWithDelay(K.MENU_INJECTION_DELAY_MS, function()
                pendingInjectionKeys[menuKey] = nil
                local resolved, resolveError =
                    resolveConstructedMainMenu(menuKey)
                if resolved == nil then
                    log("Start Menu injection failed closed: " ..
                        tostring(resolveError))
                    return
                end
                injectFastTravelEntry(resolved)
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
                    "%s %s | sdk=%s | target=%s | enabled=%s | healthy=%s | opening=%s | teleportMode=%s | teleporting=%s | widget=%s | lastNativeFastTravel=%s | lastAccessible=%s | lastAccessingTerminal=%s | lastGimmickId=%s",
                    MOD_NAME,
                    MOD_VERSION,
                    SUPPORTED_SDK,
                    tostring(CONFIG.MAP_TARGET),
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

            -- WBP_Map_FastTravel_C only confirms terminals, so a pin cannot be
            -- selected on it. FRODMapPin carries both the map Pos and its actual
            -- MapPin world actor, so the destination is available without
            -- inventing a terrain height.
            -- The escape hatch for a screen left unfocused by a viewport change.
            if subcommand == "close" then
                reply("Force-closing the map screen; see the UE4SS console.")
                ExecuteInGameThread(function()
                    local ok, closeError =
                        xpcall(forceCloseMapScreen, debug.traceback, "console")
                    if not ok then
                        log("FORCED CLOSE ERROR | " .. tostring(closeError))
                    end
                end)
                return true
            end

            if subcommand == "pin" then
                local index = tonumber(params[2])
                if index == nil or index < 1 then
                    reply("Usage: fasttravel pin <index from 'fasttravel pins'>")
                    return true
                end
                reply("Pin travel scheduled; see the UE4SS console.")
                ExecuteInGameThread(function()
                    local ok, pinError = xpcall(function()
                        local gameState, gameStateError = resolveWorldGameState()
                        if gameState == nil then error(gameStateError) end
                        local pins = gameState.MapPins
                        local count = #pins
                        if index > count then
                            error(string.format(
                                "pin %d does not exist; the map holds %d",
                                index, count))
                        end
                        local pin = pins[index]
                        if pin == nil then
                            error("MapPins[" .. index .. "] is unavailable")
                        end
                        local position = pin.Pos
                        local entry = {
                            index = index,
                            raw = {
                                X = tonumber(position.X),
                                Y = tonumber(position.Y),
                                Z = tonumber(position.Z),
                            },
                        }
                        if not performMapCoordinateTeleport(
                            entry.raw,
                            "map pin " .. tostring(index),
                            nil,
                            nil) then
                            error("pin teleport transaction was rejected")
                        end
                    end, debug.traceback)
                    if not ok then
                        log("PIN TRAVEL ERROR | " .. tostring(pinError))
                    end
                end)
                return true
            end

            if subcommand == "menukeys" then
                reply(
                    "Menu key report scheduled; output goes to the UE4SS console.")
                ExecuteInGameThread(function()
                    local reportOk, reportError = xpcall(function()
                        log("MENU KEY REPORT | configured=" ..
                            (CONFIG.MAP_MENU_KEY == ""
                                and "<auto>" or CONFIG.MAP_MENU_KEY) ..
                            " | lastSent=" .. tostring(lastMapMenuKey) ..
                            " (" .. tostring(lastMapMenuKeySource) .. ")")
                        if #observedMenuKeyOrder == 0 then
                            log("MENU KEY REPORT | nothing observed yet; " ..
                                "open the Start Menu once")
                        end
                        for _, tagName in ipairs(observedMenuKeyOrder) do
                            log(string.format(
                                "MENU KEY REPORT | observed %s -> %s",
                                tagName,
                                tostring(observedMenuKeys[tagName])))
                        end
                        local contract, contractError =
                            resolveMapAbilityContract()
                        if contract == nil then
                            log("MENU KEY REPORT | LevelSequenceMap " ..
                                "unavailable: " .. tostring(contractError) ..
                                " (open the Start Menu first)")
                            return
                        end
                        mapSequenceKeyCache = nil
                        mapSequenceKeys(contract.mapAbility)
                    end, debug.traceback)
                    if not reportOk then
                        log("MENU KEY REPORT ERROR | " ..
                            tostring(reportError))
                    end
                end)
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
                "Usage: fasttravel status | open | close | pins | " ..
                "pin <index> | terminals | menukeys")
            return true
        end
    )
end)
if not commandOk then
    error("[" .. MOD_NAME ..
        "] console command registration failed: " ..
        tostring(commandError))
end

--========================================================--
--                  STUCK-SCREEN ESCAPE                   --
--========================================================--
-- A viewport change -- Alt+Enter reproduces it -- leaves the screen up with its
-- cursor live and its input dead: Cancelar does nothing, Confirmar stays greyed,
-- and nothing in the game closes it. Recovering through the Start Menu is
-- impossible because the Start Menu cannot be reached from there.
--
-- So the way out must not go through the game's input at all. A UE4SS keybind is
-- processed outside it, which is the whole reason this exists rather than a
-- console command alone.

-- Reading Key.X directly would throw outside a pcall if the enum is missing on
-- some UE4SS build, taking the mod down before anything else registers.
local function keyCode(name)
    local ok, code = pcall(function() return Key[name] end)
    if ok and type(code) == "number" then return code end
    return nil
end

local function bindKey(name, label, action)
    if name == nil or name == "" then return end
    local code = keyCode(name)
    if code == nil then
        log("keybind unavailable: Key." .. tostring(name) .. " does not exist")
        return
    end
    local ok, bindError = pcall(function()
        RegisterKeyBind(code, function()
            ExecuteInGameThread(function()
                local ran, actionError = xpcall(action, debug.traceback)
                if not ran then
                    log(label .. " keybind failed: " .. tostring(actionError))
                end
            end)
        end)
    end)
    if not ok then
        log("keybind registration failed for " .. tostring(name) .. ": " ..
            tostring(bindError))
    else
        log("keybind ready | " .. tostring(name) .. " = " .. label)
    end
end

bindKey(CONFIG.FORCE_CLOSE_KEY, "force close map", function()
    forceCloseMapScreen("keybind")
end)

-- F9 is the canonical "Anywhere" action. The cursor and the player icon share
-- the field map's render coordinate system. RODInGameUIManager supplies the
-- game's world-to-map rotation, and FieldMapDistancePerPixel supplies its live
-- zoom. Inverting that measured transform yields the world XY below the cursor
-- without requiring a pin or choosing a nearby terminal.
bindKey(CONFIG.CURSOR_TRAVEL_KEY, "travel to map cursor", function()
    if cursorTravelBusy then return end

    if not teleportMapModeActive or not isValid(teleportMapWidget) then
        return
    end

    local item, itemError = resolveMapItemWidget(teleportMapWidget)
    if item == nil then
        log("CURSOR TRAVEL ERROR | " .. tostring(itemError))
        return
    end

    local heroPosition, heroError = heroLocation()
    if heroPosition == nil then
        log("CURSOR TRAVEL ERROR | " .. tostring(heroError))
        return
    end

    local playerIcon = nil
    local cursorWidget = nil
    local distancePerPixel = nil
    local imageAngle = nil
    local mapImageSize = nil
    local uiManager = nil
    local contractOk, contractError = pcall(function()
        playerIcon = item.PlayerIconWidget
        cursorWidget = item.CursorWidget
        distancePerPixel = tonumber(item.FieldMapDistancePerPixel)
        imageAngle = tonumber(item.ImageAngle)
        mapImageSize = tonumber(item.MapImageSize)
        uiManager = weakObject(teleportMapWidget.UIManagerRef)
    end)
    if not contractOk
        or not isValid(playerIcon)
        or not isValid(cursorWidget)
        or not isValid(uiManager)
        or distancePerPixel == nil
        or distancePerPixel ~= distancePerPixel
        or distancePerPixel <= 0.0
        or imageAngle == nil
        or imageAngle ~= imageAngle
        or mapImageSize == nil
        or mapImageSize <= 0.0 then
        log("CURSOR TRAVEL ERROR | field-map transform is unavailable: " ..
            tostring(contractError))
        return
    end

    local playerAt = widgetTranslation(playerIcon)
    local cursorAt = widgetTranslation(cursorWidget)
    if playerAt == nil or cursorAt == nil then
        log("CURSOR TRAVEL ERROR | player/cursor render translation is unreadable")
        return
    end

    -- ConvertMapLocation is used at neutral scale so it contributes only the
    -- game's axis swap and rotation. The widget's measured cm-per-pixel then
    -- supplies the current scale. Inverting the resulting 2x2 matrix converts
    -- the player-to-cursor screen delta back to a world delta.
    local convertedOrigin = nil
    local convertedX = nil
    local convertedY = nil
    local conversionOk, conversionError = pcall(function()
        local zero = { X = 0.0, Y = 0.0, Z = 0.0 }
        convertedOrigin = uiManager:ConvertMapLocation(
            zero, zero, imageAngle, 1.0)
        convertedX = uiManager:ConvertMapLocation(
            { X = 1.0, Y = 0.0, Z = 0.0 },
            zero,
            imageAngle,
            1.0)
        convertedY = uiManager:ConvertMapLocation(
            { X = 0.0, Y = 1.0, Z = 0.0 },
            zero,
            imageAngle,
            1.0)
    end)
    if not conversionOk
        or convertedOrigin == nil
        or convertedX == nil
        or convertedY == nil then
        log("CURSOR TRAVEL ERROR | native map conversion failed: " ..
            tostring(conversionError))
        return
    end

    local originX = tonumber(convertedOrigin.X)
    local originY = tonumber(convertedOrigin.Y)
    local basisXX = tonumber(convertedX.X)
    local basisXY = tonumber(convertedX.Y)
    local basisYX = tonumber(convertedY.X)
    local basisYY = tonumber(convertedY.Y)
    if originX == nil or originY == nil
        or basisXX == nil or basisXY == nil
        or basisYX == nil or basisYY == nil then
        log("CURSOR TRAVEL ERROR | native map conversion is non-numeric")
        return
    end
    local m11 = (basisXX - originX) / distancePerPixel
    local m21 = (basisXY - originY) / distancePerPixel
    local m12 = (basisYX - originX) / distancePerPixel
    local m22 = (basisYY - originY) / distancePerPixel
    local determinant = m11 * m22 - m12 * m21
    if determinant ~= determinant or math.abs(determinant) < 0.000000001 then
        log("CURSOR TRAVEL ERROR | native map transform is singular")
        return
    end

    local screenDeltaX = playerAt.X - cursorAt.X
    local screenDeltaY = playerAt.Y - cursorAt.Y
    local playerMinusCursorX =
        (screenDeltaX * m22 - m12 * screenDeltaY) / determinant
    local playerMinusCursorY =
        (m11 * screenDeltaY - screenDeltaX * m21) / determinant
    local destination = {
        X = heroPosition.X - playerMinusCursorX,
        Y = heroPosition.Y - playerMinusCursorY,
    }
    local worldDx = destination.X - heroPosition.X
    local worldDy = destination.Y - heroPosition.Y
    local worldDistance = math.sqrt(worldDx * worldDx + worldDy * worldDy)
    local mapWorldDiameter = mapImageSize * distancePerPixel
    if destination.X ~= destination.X
        or destination.Y ~= destination.Y
        or worldDistance > mapWorldDiameter * 1.5 then
        log(string.format(
            "CURSOR TRAVEL ERROR | converted cursor is outside the field map | distance=%.0f limit=%.0f",
            worldDistance,
            mapWorldDiameter * 1.5))
        return
    end

    log(string.format(
        "CURSOR TRAVEL | cursor=(%.1f, %.1f) | playerIcon=(%.1f, %.1f) | worldXY=(%.1f, %.1f) | cmPerPixel=%.3f | angle=%.3f",
        cursorAt.X,
        cursorAt.Y,
        playerAt.X,
        playerAt.Y,
        destination.X,
        destination.Y,
        distancePerPixel,
        imageAngle))

    cursorTravelBusy = true
    local cursorTransactionSerial = openSerial
    local started = performMapCoordinateTeleport(
        destination,
        "map cursor",
        function()
            dismissFastTravelScreen()
        end,
        function(success)
            -- A successful operation stays latched until the map's own close
            -- lifecycle resets it. This prevents the physical F9 press that
            -- initiated the teleport from repeating into a second destination
            -- during the close animation.
            if success == true then return end
            ExecuteInGameThreadWithDelay(500, function()
                if openSerial == cursorTransactionSerial then
                    cursorTravelBusy = false
                end
            end)
        end)
    if not started then
        dbg("cursor travel request rejected before asynchronous loading")
    end
end)

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
                cursorTravelBusy = false
                mapIconDestinations = {}
                teleportMapWidgetKey = nil
                teleportMapWidget = nil
                openSerial = openSerial + 1
            end
            if activeContext ~= nil then
                if CONFIG.ENABLED then
                    setContextVisibility(activeContext, K.VISIBLE)
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
                    setContextVisibility(activeContext, K.COLLAPSED)
                end
            end
        end,
        fail = function(reason)
            runtimeHealthy = false
            CONFIG.ENABLED = false
            openBusy = false
            teleportMapModeActive = false
            mapTeleportBusy = false
            cursorTravelBusy = false
            mapIconDestinations = {}
            teleportMapWidgetKey = nil
            teleportMapWidget = nil
            openSerial = openSerial + 1
            if activeContext ~= nil then
                setContextVisibility(activeContext, K.COLLAPSED)
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
    ExecuteInGameThreadWithDelay(500, function()
        local cleanupOk, cleanupError = xpcall(function()
            recoverCompletedNativeTravel("mod startup")
        end, debug.traceback)
        if not cleanupOk then
            dbg("startup native travel cleanup skipped: " ..
                tostring(cleanupError))
        end
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
