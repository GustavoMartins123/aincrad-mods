local MOD_NAME = "ExperienceNotifications"
local MOD_VERSION = "1.0.0"
local DEATH_REWARD_WINDOW_MS = 1500

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
local nextDeathToken = 0
local deathWindows = {}
local lastDisplayError = nil

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function dbg(message)
    if CONFIG ~= nil and CONFIG.DEBUG_LOGS then log(message) end
end

local function isValid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
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

local function removeDeathToken(token)
    for index = #deathWindows, 1, -1 do
        if deathWindows[index].token == token then
            table.remove(deathWindows, index)
            return
        end
    end
end

local function queueEnemyDeath(enemyParameter)
    if CONFIG == nil or not CONFIG.ENABLED then return end
    local enemy = readHookValue(enemyParameter, "Enemy")
    if not isValid(enemy) then
        error("NotifyEnemyConfirmedDeath supplied an invalid enemy")
    end

    local okData, enemyKey, expectedExperience = pcall(function()
        return enemy:GetFullName(), tonumber(enemy.ExperiencePoint)
    end)
    if not okData or type(enemyKey) ~= "string" or enemyKey == ""
        or not finiteNumber(expectedExperience) then
        error("confirmed-death enemy reward data is unreadable")
    end

    nextDeathToken = nextDeathToken + 1
    local token = nextDeathToken
    deathWindows[#deathWindows + 1] = {
        token = token,
        enemyKey = enemyKey,
        expectedExperience = expectedExperience,
    }
    ExecuteWithDelay(DEATH_REWARD_WINDOW_MS, function()
        removeDeathToken(token)
    end)
end

local function resolveNotificationUi()
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
    return messageLog, widgetLibrary, nil
end

local function displayExperience(amount)
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
        messageWidget.InformationText:SetText(
            FText(string.format("EXP +%d", amount))
        )
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

local function consumeHeroExperience(context, experienceParameter)
    if CONFIG == nil or not CONFIG.ENABLED or #deathWindows == 0 then return end
    local playerState = readHookValue(context, "PlayerState")
    if not isValid(playerState) then
        error("CalcHeroLevelUp supplied an invalid PlayerState")
    end
    local okHost, isHost = pcall(function() return playerState:IsHost() end)
    if not okHost then error("RODPlayerState:IsHost failed: " .. tostring(isHost)) end
    if isHost ~= true then return end

    local amount = tonumber(readHookValue(experienceParameter, "AddExp"))
    if not finiteNumber(amount) or amount <= 0 then
        error("CalcHeroLevelUp AddExp must be a positive finite number")
    end
    amount = math.floor(amount + 0.5)
    local death = table.remove(deathWindows, 1)
    dbg(string.format(
        "REWARD | enemy=%s expected=%.0f actual=%d",
        death.enemyKey,
        death.expectedExperience,
        amount
    ))

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
            end
        end)
    end)
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
    "/Script/ROD.RODGameState:NotifyEnemyConfirmedDeath",
    function(_, enemyParameter)
        local ok, hookError = xpcall(
            function() queueEnemyDeath(enemyParameter) end,
            debug.traceback
        )
        if not ok then log("DEATH HOOK ERROR | " .. tostring(hookError)) end
    end
)

requireHook(
    "/Script/ROD.RODPlayerState:CalcHeroLevelUp",
    function(context, experienceParameter)
        local ok, hookError = xpcall(
            function() consumeHeroExperience(context, experienceParameter) end,
            debug.traceback
        )
        if not ok then log("REWARD HOOK ERROR | " .. tostring(hookError)) end
    end
)

for _, path in ipairs({
    "/Script/Engine.PlayerController:ClientTravelInternal",
    "/Script/ROD.RODGameState:StartQuestEnd",
    "/Script/ROD.RODGameState:QuestEnd",
}) do
    requireHook(path, function() deathWindows = {} end)
end

do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = readSettings,
        apply = function()
            if not CONFIG.ENABLED then deathWindows = {} end
            log("settings reloaded in-game")
        end,
        fail = function(reason)
            CONFIG.ENABLED = false
            deathWindows = {}
            log("CONFIG ERROR | " .. tostring(reason) .. " | notifications disabled")
        end,
        log = log,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

log("READY | native EXP labels follow confirmed enemy rewards")
