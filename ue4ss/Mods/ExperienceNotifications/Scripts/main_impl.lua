local MOD_NAME = "ExperienceNotifications"
local MOD_VERSION = "1.2.0"

print(string.format("[%s] Loading v%s\n", MOD_NAME, MOD_VERSION))

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if type(info) ~= "table" or type(info.source) ~= "string" then
        error("[" .. MOD_NAME .. "] CONFIG ERROR | script source is unavailable")
    end
    local source = info.source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local directory = source:match("^(.*[\\/])")
    if type(directory) ~= "string" or directory == "" then
        error("[" .. MOD_NAME ..
            "] CONFIG ERROR | canonical Scripts directory is unavailable")
    end
    return directory
end

local SCRIPT_DIR = scriptDir()
local CONFIG = nil
local lastDisplayError = nil
local acquisitionReadyReported = false
local displayReadyReported = false

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        cachedMessageLog = nil
        cachedWidgetLibrary = nil
    end)
end)

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function dbg(message)
    if CONFIG ~= nil and CONFIG.DEBUG_LOGS then log(message) end
end

local function isValid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return false end
    local ok, valid = pcall(function()
        if type(object.get_address) == "function" then
            local addr = object:get_address()
            if addr == nil or addr == 0 then return false end
        elseif type(object.GetAddress) == "function" then
            local addr = object:GetAddress()
            if addr == nil or addr == 0 then return false end
        end
        if type(object.IsValid) == "function" then
            return object:IsValid()
        elseif type(object.is_valid) == "function" then
            return object:is_valid()
        end
        return true
    end)
    return ok and valid == true
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function readSettings(settings)
    if type(settings) ~= "table" then error("settings must be a table") end
    for key, _ in pairs(settings) do
        if key ~= "ENABLED" and key ~= "DEBUG_LOGS" then
            error("unknown setting: " .. tostring(key))
        end
    end
    if type(settings.ENABLED) ~= "boolean" then
        error("ENABLED must be boolean")
    end
    if type(settings.DEBUG_LOGS) ~= "boolean" then
        error("DEBUG_LOGS must be boolean")
    end
    CONFIG = {
        ENABLED = settings.ENABLED,
        DEBUG_LOGS = settings.DEBUG_LOGS,
    }
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
    readSettings(settings)
end

local function readHookValue(parameter, name)
    if parameter == nil then error(name .. " hook parameter is unavailable") end
    local ok, value = pcall(function() return parameter:get() end)
    if not ok then error(name .. " hook parameter read failed: " .. tostring(value)) end
    return value
end

local displayExperience

local function queueDisplay(amount)
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            local okDisplay, displayError =
                xpcall(function() displayExperience(amount) end, debug.traceback)
            if not okDisplay then
                local text = tostring(displayError)
                if text ~= lastDisplayError then
                    lastDisplayError = text
                    log("DISPLAY ERROR | " .. text)
                end
            elseif not displayReadyReported then
                displayReadyReported = true
                log("DISPLAY READY | native EXP notification displayed")
            end
        end)
    end)
end

local function queueEnemyAcquisition(sourceParameter, acquisitionParameter)
    if CONFIG == nil or not CONFIG.ENABLED then return end
    local source
    local okRead, readErr = pcall(function()
        source = readHookValue(sourceParameter, "Source")
    end)
    if not okRead or not isValid(source) then
        return
    end

    local okEnemy, isEnemy = pcall(function()
        return source:IsA("/Script/ROD.RODEnemyCharacter")
    end)
    if not okEnemy then
        error("Source class validation failed: " .. tostring(isEnemy))
    end
    if isEnemy ~= true then return end

    local acquisition = readHookValue(acquisitionParameter, "AcquisitionData")
    if acquisition == nil then
        error("ApplyAcquisition supplied no AcquisitionData")
    end
    local okExperience, amount = pcall(function()
        return tonumber(acquisition.ExperiencePoint)
    end)
    if not okExperience or not finiteNumber(amount) then
        error("AcquisitionData.ExperiencePoint is not a finite number")
    end
    if amount <= 0 then return end
    amount = math.floor(amount + 0.5)

    if not acquisitionReadyReported then
        acquisitionReadyReported = true
        log("ACQUISITION READY | enemy EXP transaction detected")
    end
    dbg("ENEMY EXP | +" .. amount)
    queueDisplay(amount)
end

local cachedMessageLog = nil
local cachedWidgetLibrary = nil

local function resolveNotificationUi()
    if isValid(cachedMessageLog) and isValid(cachedWidgetLibrary) then
        return cachedMessageLog, cachedWidgetLibrary, nil
    end
    cachedMessageLog = nil
    cachedWidgetLibrary = nil

    local ok, messageLog, widgetLibrary = pcall(function()
        return FindFirstOf("RODInfoMessageLogWidget"),
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end)
    if not ok then
        return nil, nil, "native notification UI lookup failed: " ..
            tostring(messageLog)
    end
    if not isValid(messageLog) then
        return nil, nil, "active RODInfoMessageLogWidget is unavailable"
    end
    if not isValid(widgetLibrary) then
        return nil, nil, "canonical WidgetBlueprintLibrary is unavailable"
    end
    cachedMessageLog = messageLog
    cachedWidgetLibrary = widgetLibrary
    return cachedMessageLog, cachedWidgetLibrary, nil
end

displayExperience = function(amount)
    local messageLog, widgetLibrary, resolveError = resolveNotificationUi()
    if messageLog == nil then error(resolveError) end

    local messageWidget = nil
    local addedToPanel = false
    local ok, displayError = pcall(function()
        local panel = messageLog.Information
        local widgetClass = messageLog.EventMessageWidgetClass
        local owningPlayer = messageLog:GetOwningPlayer()
        if not isValid(panel) then
            error("Information vertical panel is unavailable")
        end
        if not isValid(widgetClass) then
            error("EventMessageWidgetClass is unavailable")
        end
        if not isValid(owningPlayer) then
            error("notification owning player is unavailable")
        end

        messageWidget = widgetLibrary:Create(
            messageLog,
            widgetClass,
            owningPlayer
        )
        if not isValid(messageWidget) then
            error("WidgetBlueprintLibrary.Create returned no event message widget")
        end
        if not isValid(messageWidget.InformationText) then
            error("event message InformationText is unavailable")
        end
        local expectedText = string.format("EXP +%d", amount)
        messageWidget.InformationText:SetText(FText(expectedText))
        local actualText = messageWidget.InformationText:GetText():ToString()
        if actualText ~= expectedText then
            error(string.format(
                "native InformationText verification failed: expected=%q actual=%q",
                expectedText,
                tostring(actualText)
            ))
        end
        local slot = panel:AddChild(messageWidget)
        if not isValid(slot) then
            error("native Information panel rejected the EXP widget")
        end
        addedToPanel = true
        messageWidget:SetVisibility(0)
        messageLog:SetVisibleStackMessage()
        messageLog:SetMessageTimer(messageWidget)
    end)

    if not ok then
        if addedToPanel and isValid(messageWidget) then
            pcall(function() messageWidget:RemoveFromParent() end)
        end
        error(displayError)
    end
    lastDisplayError = nil
    dbg("DISPLAYED | EXP +" .. amount)
end

local function requireHook(path, preCallback, postCallback)
    local ok, hookError = pcall(function()
        if postCallback ~= nil then
            RegisterHook(path, preCallback, postCallback)
        else
            RegisterHook(path, preCallback)
        end
    end)
    if not ok then
        error("[" .. MOD_NAME .. "] HOOK ERROR | " .. path .. " | " ..
            tostring(hookError))
    end
end

requireHook(
    "/Script/ROD.RODGameState:ApplyAcquisition",
    function(_, sourceParameter, acquisitionParameter)
        ExecuteInGameThread(function()
            local ok, hookError = xpcall(
                function()
                    queueEnemyAcquisition(sourceParameter, acquisitionParameter)
                end,
                debug.traceback
            )
            if not ok then
                log("ACQUISITION HOOK ERROR | " .. tostring(hookError))
            end
        end)
    end
)

do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = readSettings,
        apply = function()
            log("settings reloaded in-game")
        end,
        fail = function(reason)
            CONFIG.ENABLED = false
            log("CONFIG ERROR | " .. tostring(reason) .. " | notifications disabled")
        end,
        log = log,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

log("READY | native EXP labels follow enemy acquisition transactions")
