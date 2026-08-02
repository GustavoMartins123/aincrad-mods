local MOD_NAME = "GaugeNumbers"
local MOD_VERSION = "1.0.0"

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

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function dbg(message)
    if CONFIG ~= nil and CONFIG.DEBUG_LOGS then log(message) end
end

-- Every failure path here is recoverable and repeats on the next poll, so an
-- unfiltered log line would be written twice a second forever.
local lastReport = {}

local function reportOnce(tag, message)
    local text = tostring(message)
    if lastReport[tag] == text then return end
    lastReport[tag] = text
    log(text)
end

local function clearReport(tag)
    lastReport[tag] = nil
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

local function weakObject(pointer)
    if pointer == nil then return nil end
    local ok, object = pcall(function() return pointer:Get() end)
    if not ok then return nil end
    if isValid(object) then return object end
    return nil
end

local function round(value)
    return math.floor(value + 0.5)
end

--========================================================--
--                       SETTINGS                         --
--========================================================--

local BOOLEAN_KEYS = {
    "ENABLED",
    "SHOW_HP", "SHOW_STAMINA", "SHOW_SP", "ALIGN_READOUTS",
    "SHOW_EXP", "SHOW_EXP_BAR", "SHOW_EXP_TEXT", "SHOW_EXP_LEVEL",
    "DEBUG_LOGS",
}

local NUMBER_KEYS = {
    HP_X           = { min = 0.0, max = 1920.0 },
    HP_Y           = { min = 0.0, max = 1080.0 },
    STAMINA_X      = { min = 0.0, max = 1920.0 },
    STAMINA_Y      = { min = 0.0, max = 1080.0 },
    SP_X           = { min = 0.0, max = 1920.0 },
    SP_Y           = { min = 0.0, max = 1080.0 },
    TEXT_OFFSET_X  = { min = -400.0, max = 400.0 },
    TEXT_OFFSET_Y  = { min = -400.0, max = 400.0 },
    FONT_SIZE      = { min = 6.0, max = 48.0 },
    EXP_OFFSET_X   = { min = -400.0, max = 400.0 },
    EXP_OFFSET_Y   = { min = -400.0, max = 400.0 },
    EXP_BAR_WIDTH  = { min = 0.0, max = 1200.0 },
    EXP_BAR_HEIGHT = { min = 0.0, max = 40.0 },
    REFRESH_MS     = { min = 100.0, max = 5000.0 },
}

local CHOICE_KEYS = {
    VALUE_FORMAT      = { current_max = true, current = true, percent = true },
    READOUT_PLACEMENT = { center = true, right = true },
    READOUT_LAYER     = { inside = true, gauge = true, front = true },
    EXP_STYLE         = { native = true, flat = true },
    EXP_ANCHOR        = { hp = true, stamina = true, sp = true },
    EXP_PLACEMENT     = { above = true, below = true },
}

local function readSettings(settings)
    if type(settings) ~= "table" then error("settings must be a table") end

    local known = {}
    for _, key in ipairs(BOOLEAN_KEYS) do known[key] = true end
    for key, _ in pairs(NUMBER_KEYS) do known[key] = true end
    for key, _ in pairs(CHOICE_KEYS) do known[key] = true end
    for key, _ in pairs(settings) do
        if not known[key] then error("unknown setting: " .. tostring(key)) end
    end

    local parsed = {}
    for _, key in ipairs(BOOLEAN_KEYS) do
        if type(settings[key]) ~= "boolean" then
            error(key .. " must be boolean")
        end
        parsed[key] = settings[key]
    end
    for key, bounds in pairs(NUMBER_KEYS) do
        local value = settings[key]
        if not finiteNumber(value) then
            error(key .. " must be a finite number")
        end
        if value < bounds.min or value > bounds.max then
            error(string.format("%s must be between %g and %g", key,
                bounds.min, bounds.max))
        end
        parsed[key] = value
    end
    for key, allowed in pairs(CHOICE_KEYS) do
        local value = settings[key]
        if type(value) ~= "string" or not allowed[value] then
            error(key .. " has an unsupported value: " .. tostring(value))
        end
        parsed[key] = value
    end

    CONFIG = parsed
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
    readSettings(settings)
end

-- ModMenu publishes this as a short-lived lease only while GaugeNumbers is
-- expanded. It is deliberately separate from runtime.lua: preview state must
-- never become a saved player setting.
local PREVIEW_PATH = SCRIPT_DIR .. "preview.lua"
local PREVIEW_POLL_MS = 250
local previewFingerprint = nil
local previewExpiresAt = 0
local previewValidationError = nil

--========================================================--
--                       CONSTANTS                        --
--========================================================--

-- ESlateVisibility. Everything the mod adds is decoration, so it is mounted
-- HitTestInvisible: it can never swallow a click or become a focus target
-- belonging to the HUD underneath.
local VISIBLE = 0
local HIT_TEST_INVISIBLE = 3
local COLLAPSED = 1
local HIDDEN = 2

local TEXT_BLOCK_CLASS = "/Script/UMG.TextBlock"
local IMAGE_CLASS = "/Script/UMG.Image"
local LAYOUT_LIBRARY = "/Script/UMG.Default__WidgetLayoutLibrary"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"

local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local EXP_FILL_COLOR = { R = 1.0, G = 0.78, B = 0.28, A = 1.0 }
local EXP_BACK_COLOR = { R = 0.02, G = 0.03, B = 0.05, A = 0.55 }

-- unit     the cockpit member holding the whole bar assembly.
-- canvas   the CanvasPanel inside it that owns the bar's coordinate space.
-- gauge    the gauge widget itself.
-- posX/Y   settings naming this bar's point on the cockpit gauge canvas.
local BARS = {
    {
        key = "HP",
        anchor = "hp",
        setting = "SHOW_HP",
        unit = "PlayerUnitGauge_HP",
        canvas = "HPGauge",
        gauge = "HP",
        posX = "HP_X",
        posY = "HP_Y",
    },
    {
        key = "STAMINA",
        anchor = "stamina",
        setting = "SHOW_STAMINA",
        unit = "PlayerUnitGauge_Stamina",
        canvas = "StaminaGauge",
        gauge = "Stamina",
        posX = "STAMINA_X",
        posY = "STAMINA_Y",
    },
    {
        key = "SP",
        anchor = "sp",
        setting = "SHOW_SP",
        unit = "PlayerUnitGauge_Soul",
        canvas = "SoulGauge",
        gauge = "Soul",
        posX = "SP_X",
        posY = "SP_Y",
    },
}

local BAR_BY_KEY = {}
local BAR_BY_ANCHOR = {}
for _, definition in ipairs(BARS) do
    BAR_BY_KEY[definition.key] = definition
    BAR_BY_ANCHOR[definition.anchor] = definition
end

-- WBP_StaminaGauge_Player_C is the donor for the native experience bar because
-- it is the only player gauge with NO blueprint graph at all: no
-- UberGraphFrame, no Construct, no ExecuteUbergraph. Copying the HP or SP
-- gauge would run their construction logic against a widget that has no avatar
-- behind it.
local NATIVE_DONOR = { unit = "PlayerUnitGauge_Stamina", gauge = "Stamina" }

-- Only used when nothing could be measured at all.
local FALLBACK_BAR_WIDTH = 320.0
local FALLBACK_BAR_HEIGHT = 12.0
local PREVIEW_DESIGN_WIDTH = 1920.0
local PREVIEW_DESIGN_HEIGHT = 1080.0

--========================================================--
--                        STATE                           --
--========================================================--

local state = {
    cockpit = nil,
    labels = {},        -- [barKey] = { widget, current, maximum }
    exp = nil,
    fontDonor = nil,
    previewRequested = false,
    previewApplied = false,
    previewSnapshot = nil,
    previewCockpit = nil,
    previewGaugeWasVisible = nil,
    previewCombatUIWasVisible = nil,
    previewUnitGauge = nil,
    previewOriginalParent = nil,
    previewOriginalLayout = nil,
    previewOriginalAutoSize = nil,
    previewOriginalZOrder = nil,
    previewMenuCanvas = nil,
    previewMounted = false,
}

-- Assigned below the widget-lifecycle helpers so releaseWidgets can discard a
-- preview snapshot without reaching into a stale world during teardown.
local restorePreviewVisibility
local restorePreviewMount

-- The menu is a separate viewport layer from the cockpit. Visibility on the
-- UnitGauge itself is therefore not enough: when the menu is open, the cockpit
-- can be perfectly visible and still be drawn underneath the menu's RetainerBox.
-- The live menu owns a full-screen SubMenu canvas, so the preview temporarily
-- mounts only UnitGauge there. Its original parent and CanvasPanelSlot layout
-- are retained and restored when the preview lease ends.
local function resolvePreviewCanvas()
    local ok, menu = pcall(function()
        return FindFirstOf("WBP_Console_MainMenu_C")
    end)
    if not ok or not isValid(menu) then return nil end

    local canvas = nil
    local read = pcall(function() canvas = menu.SubMenu end)
    if not read or not isValid(canvas) then return nil end
    return canvas
end

local function clearPreviewMountState()
    state.previewUnitGauge = nil
    state.previewOriginalParent = nil
    state.previewOriginalLayout = nil
    state.previewOriginalAutoSize = nil
    state.previewOriginalZOrder = nil
    state.previewMenuCanvas = nil
    state.previewMounted = false
end

local function capturePreviewMount(cockpit)
    local unitGauge = cockpit.UnitGauge
    if not isValid(unitGauge) then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | UnitGauge is unavailable for menu mounting")
        return false
    end

    local parent = nil
    local slot = nil
    local readParent = pcall(function()
        slot = unitGauge.Slot
        parent = slot.Parent
    end)
    if not readParent or not isValid(slot) or not isValid(parent) then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | UnitGauge original CanvasPanel parent is unavailable")
        return false
    end

    local layout = nil
    local autoSize = nil
    local zOrder = nil
    local readLayout = pcall(function()
        layout = slot:GetLayout()
        autoSize = slot:GetAutoSize()
        zOrder = slot:GetZOrder()
    end)
    if not readLayout or layout == nil or type(autoSize) ~= "boolean"
        or type(zOrder) ~= "number" then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | UnitGauge CanvasPanelSlot layout is unavailable")
        return false
    end

    local menuCanvas = resolvePreviewCanvas()
    if menuCanvas == nil then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | live menu SubMenu canvas is unavailable")
        return false
    end

    state.previewUnitGauge = unitGauge
    state.previewOriginalParent = parent
    state.previewOriginalLayout = layout
    state.previewOriginalAutoSize = autoSize
    state.previewOriginalZOrder = zOrder
    state.previewMenuCanvas = menuCanvas
    state.previewMounted = false
    clearReport("PREVIEW-MOUNT")
    return true
end

local function restoreOriginalMountAfterFailure(unitGauge)
    local parent = state.previewOriginalParent
    if not isValid(parent) or not isValid(unitGauge) then return false end

    local slot = nil
    local added = pcall(function()
        slot = parent:AddChildToCanvas(unitGauge)
    end)
    if not added or not isValid(slot) then return false end

    local restored = pcall(function()
        slot:SetLayout(state.previewOriginalLayout)
        slot:SetAutoSize(state.previewOriginalAutoSize)
        slot:SetZOrder(state.previewOriginalZOrder)
    end)
    return restored
end

local function mountPreviewUnitGauge()
    if state.previewMounted then return true end

    local unitGauge = state.previewUnitGauge
    local menuCanvas = state.previewMenuCanvas
    if not isValid(unitGauge) or not isValid(menuCanvas) then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview mount objects became invalid")
        return false
    end

    local removed = pcall(function() unitGauge:RemoveFromParent() end)
    if not removed then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | could not detach UnitGauge for menu mounting")
        return false
    end

    local menuSlot = nil
    local added = pcall(function()
        menuSlot = menuCanvas:AddChildToCanvas(unitGauge)
    end)
    if not added or not isValid(menuSlot) then
        restoreOriginalMountAfterFailure(unitGauge)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | menu SubMenu rejected UnitGauge")
        return false
    end

    local configured = pcall(function()
        -- The original slot is relative to the cockpit's own canvas. Reusing
        -- that slot on SubMenu applies the cockpit's parent offset a second
        -- time, which shifts the preview toward the centre of the screen. The
        -- menu uses the game's 1920x1080 design space, so the temporary slot is
        -- explicit and top-left anchored.
        menuSlot:SetAutoSize(false)
        menuSlot:SetMinimum({ X = 0.0, Y = 0.0 })
        menuSlot:SetMaximum({ X = 0.0, Y = 0.0 })
        menuSlot:SetAlignment({ X = 0.0, Y = 0.0 })
        menuSlot:SetPosition({ X = 0.0, Y = 0.0 })
        menuSlot:SetSize({
            X = PREVIEW_DESIGN_WIDTH,
            Y = PREVIEW_DESIGN_HEIGHT,
        })
        menuSlot:SetZOrder(1000)
        unitGauge:SetVisibility(VISIBLE)
        unitGauge:SetRenderOpacity(1.0)
    end)
    if not configured then
        pcall(function() unitGauge:RemoveFromParent() end)
        restoreOriginalMountAfterFailure(unitGauge)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | could not configure the menu UnitGauge slot")
        return false
    end

    state.previewMounted = true
    reportOnce("PREVIEW-MOUNTED",
        string.format(
            "PREVIEW | UnitGauge mounted into menu SubMenu | origin=0,0 | size=%dx%d | z=1000",
            PREVIEW_DESIGN_WIDTH,
            PREVIEW_DESIGN_HEIGHT))
    clearReport("PREVIEW-MOUNT")
    return true
end

restorePreviewMount = function(restore)
    if not state.previewMounted then
        if not restore then clearPreviewMountState() end
        return true
    end

    local unitGauge = state.previewUnitGauge
    local parent = state.previewOriginalParent
    if not restore or not isValid(unitGauge) or not isValid(parent) then
        clearPreviewMountState()
        return false
    end

    local removed = pcall(function() unitGauge:RemoveFromParent() end)
    local originalSlot = nil
    local added = pcall(function()
        originalSlot = parent:AddChildToCanvas(unitGauge)
    end)
    if not removed or not added or not isValid(originalSlot) then
        reportOnce("PREVIEW-RESTORE-MOUNT",
            "PREVIEW ERROR | could not restore UnitGauge to its original parent")
        return false
    end

    local restored = pcall(function()
        originalSlot:SetLayout(state.previewOriginalLayout)
        originalSlot:SetAutoSize(state.previewOriginalAutoSize)
        originalSlot:SetZOrder(state.previewOriginalZOrder)
    end)
    if not restored then
        reportOnce("PREVIEW-RESTORE-MOUNT",
            "PREVIEW ERROR | could not restore UnitGauge original layout")
        return false
    end

    clearReport("PREVIEW-RESTORE-MOUNT")
    clearPreviewMountState()
    return true
end

local function previewTargets(cockpit)
    local targets = {}

    local function add(widget)
        if not isValid(widget) then return end
        for _, existing in ipairs(targets) do
            if existing == widget then return end
        end
        targets[#targets + 1] = widget
    end

    -- UnitGauge is the common front canvas. The remaining entries cover the
    -- assembly and gauge nodes that the game's combat fade toggles at runtime.
    add(cockpit.UnitGauge)
    for _, definition in ipairs(BARS) do
        local unit = cockpit[definition.unit]
        add(unit)
        if isValid(unit) then
            add(unit[definition.canvas])
            add(unit[definition.gauge])
        end
    end
    return targets
end

restorePreviewVisibility = function(restore)
    local snapshot = state.previewSnapshot
    local mountedRestored = true
    if restore and (snapshot ~= nil or state.previewMounted) then
        if isValid(state.previewCockpit)
            and state.previewGaugeWasVisible ~= nil then
            pcall(function()
                if state.previewCombatUIWasVisible ~= nil then
                    state.previewCockpit:SetIsVisibleCombatUIFlag(
                        state.previewCombatUIWasVisible)
                end
                state.previewCockpit:SetUnitGaugeVisibility(
                    state.previewGaugeWasVisible)
            end)
        end
        if snapshot ~= nil then
            for _, entry in ipairs(snapshot) do
                if isValid(entry.widget) then
                    if entry.visibility ~= nil then
                        pcall(function()
                            entry.widget:SetVisibility(entry.visibility)
                        end)
                    end
                    if entry.opacity ~= nil then
                        pcall(function()
                            entry.widget:SetRenderOpacity(entry.opacity)
                        end)
                    end
                end
            end
        end
        mountedRestored = restorePreviewMount(true)
        if not mountedRestored and state.previewMounted then
            reportOnce("PREVIEW-RESTORE-MOUNT",
                "PREVIEW ERROR | original UnitGauge remains detached; retrying")
        elseif mountedRestored then
            clearReport("PREVIEW-RESTORE-MOUNT")
            reportOnce("PREVIEW-RESTORED",
                "PREVIEW | original UnitGauge restored to cockpit")
        end
    end
    if not restore then restorePreviewMount(false) end

    -- Keep the complete snapshot while the live widget is still mounted in
    -- SubMenu. A later lease tick must retry that same restoration; recapturing
    -- at this point would incorrectly record SubMenu as the original parent.
    if restore and not mountedRestored and state.previewMounted then
        return false
    end

    state.previewSnapshot = nil
    state.previewApplied = false
    state.previewCockpit = nil
    state.previewGaugeWasVisible = nil
    state.previewCombatUIWasVisible = nil
    clearReport("PREVIEW-APPLIED")
    return mountedRestored
end

local function capturePreviewVisibility(cockpit)
    local snapshot = {}
    for _, widget in ipairs(previewTargets(cockpit)) do
        local visibility = nil
        local opacity = nil
        local read = pcall(function()
            visibility = widget:GetVisibility()
            opacity = widget:GetRenderOpacity()
        end)
        if read and visibility ~= nil and finiteNumber(opacity) then
            snapshot[#snapshot + 1] = {
                widget = widget,
                visibility = visibility,
                opacity = opacity,
            }
        end
    end

    if #snapshot == 0 then
        reportOnce("PREVIEW-NATIVE-STATE",
            "PREVIEW ERROR | native gauge visibility state is unavailable")
        return false
    end
    state.previewSnapshot = snapshot
    state.previewCockpit = cockpit
    state.previewGaugeWasVisible = nil
    local unitGauge = cockpit.UnitGauge
    if isValid(unitGauge) then
        local visibility = nil
        local read = pcall(function() visibility = unitGauge:GetVisibility() end)
        if read and visibility ~= nil then
            state.previewGaugeWasVisible = visibility == VISIBLE
        end
    end
    if state.previewGaugeWasVisible == nil then
        state.previewSnapshot = nil
        state.previewCockpit = nil
        state.previewGaugeWasVisible = nil
        reportOnce("PREVIEW-NATIVE-STATE",
            "PREVIEW ERROR | UnitGauge visibility state is unavailable")
        return false
    end

    local combatUIWasVisible = nil
    local readCombatUI = pcall(function()
        combatUIWasVisible = cockpit:GetIsVisibleCombatUIFlag()
    end)
    if not readCombatUI or type(combatUIWasVisible) ~= "boolean" then
        state.previewSnapshot = nil
        state.previewCockpit = nil
        state.previewGaugeWasVisible = nil
        clearPreviewMountState()
        reportOnce("PREVIEW-NATIVE-STATE",
            "PREVIEW ERROR | combat UI visibility flag is unavailable")
        return false
    end
    state.previewCombatUIWasVisible = combatUIWasVisible
    if not capturePreviewMount(cockpit) then
        state.previewSnapshot = nil
        state.previewCockpit = nil
        state.previewGaugeWasVisible = nil
        state.previewCombatUIWasVisible = nil
        clearPreviewMountState()
        return false
    end
    state.previewApplied = true
    clearReport("PREVIEW-NATIVE-STATE")
    return true
end

local function applyPreviewVisibility(cockpit)
    if state.previewApplied and state.previewCockpit ~= cockpit then
        restorePreviewVisibility(isValid(state.previewCockpit))
    end
    if not state.previewApplied then
        if not capturePreviewVisibility(cockpit) then return false end
    end

    local called, nativeError = pcall(function()
        -- This is the game's own visibility boundary for the three player
        -- gauges. Calling it keeps the same parent/animation bookkeeping as
        -- combat, instead of fighting individual child widgets every frame.
        cockpit:SetIsVisibleCombatUIFlag(true)
        cockpit:SetUnitGaugeVisibility(true)
        -- The menu can leave the children collapsed even after the native
        -- boundary is opened. Reassert only the captured gauge nodes; their
        -- exact visibility and opacity are restored when the lease ends.
        for _, entry in ipairs(state.previewSnapshot or {}) do
            if isValid(entry.widget) then
                entry.widget:SetVisibility(VISIBLE)
                entry.widget:SetRenderOpacity(1.0)
            end
        end
        if not mountPreviewUnitGauge() then
            error("menu UnitGauge mount failed")
        end
    end)
    if not called then
        reportOnce("PREVIEW-NATIVE",
            "PREVIEW ERROR | SetUnitGaugeVisibility failed: " ..
            tostring(nativeError))
        restorePreviewVisibility(isValid(cockpit))
        return false
    end
    clearReport("PREVIEW-NATIVE")
    local combatUIVisible = "unreadable"
    local unitGaugeVisibility = "unreadable"
    pcall(function()
        combatUIVisible = tostring(cockpit:GetIsVisibleCombatUIFlag())
    end)
    pcall(function()
        unitGaugeVisibility = tostring(cockpit.UnitGauge:GetVisibility())
    end)
    reportOnce("PREVIEW-APPLIED", string.format(
        "PREVIEW | applied | combatUI=%s | UnitGaugeVisibility=%s | widgets=%d",
        combatUIVisible, unitGaugeVisibility,
        #(state.previewSnapshot or {})))
    return true
end

local function readPreviewLease()
    local contents, readError = MOD_MENU_BRIDGE.readFile(PREVIEW_PATH)
    if readError ~= nil then
        return false, "preview state read failed: " .. tostring(readError)
    end
    if contents == nil then
        previewFingerprint = nil
        previewExpiresAt = 0
        previewValidationError = nil
        return false, nil
    end

    if contents ~= previewFingerprint then
        local parsed, parseError = MOD_MENU_BRIDGE.evaluateTable(
            contents, "@" .. PREVIEW_PATH)
        previewFingerprint = contents
        previewExpiresAt = 0
        previewValidationError = nil
        if parsed == nil then
            previewValidationError = "preview state rejected: " .. tostring(parseError)
            return false, previewValidationError
        end
        for key in pairs(parsed) do
            if key ~= "ACTIVE" and key ~= "EXPIRES_AT" then
                previewValidationError =
                    "preview state has unknown key: " .. tostring(key)
                return false, previewValidationError
            end
        end
        if parsed.ACTIVE ~= true then
            previewValidationError = "preview state ACTIVE must be true"
            return false, previewValidationError
        end
        if not finiteNumber(parsed.EXPIRES_AT) then
            previewValidationError =
                "preview state EXPIRES_AT must be finite"
            return false, previewValidationError
        end
        previewExpiresAt = math.floor(parsed.EXPIRES_AT)
    end

    return os.time() <= previewExpiresAt, previewValidationError
end

-- destroy is only ever true on the settings path, where the world is live and
-- the cockpit has just been confirmed valid. Reaching into these widgets after
-- a level change would be a stale dereference, and a stale dereference is an
-- access violation that pcall cannot catch -- there, references are simply
-- dropped and the dead cockpit takes its children with it.
local function releaseWidgets(destroy, reason)
    -- Settings reloads keep the preview lease and its native visibility
    -- snapshot alive, so changing a coordinate does not briefly hide the
    -- original gauges. Every other release path restores them when the object
    -- is still valid, or discards the snapshot without dereferencing stale UE
    -- objects during teardown.
    if reason ~= "settings reloaded" and restorePreviewVisibility ~= nil then
        restorePreviewVisibility(isValid(state.cockpit))
    end
    if destroy then
        local doomed = {}
        -- Appended through a guard, never by index: the experience block
        -- leaves nil in whichever of native/back/fill its style did not build,
        -- and a nil written at #doomed+1 both fails to grow the list and makes
        -- ipairs stop early, silently sparing every widget after it.
        local function condemn(widget)
            if isValid(widget) then doomed[#doomed + 1] = widget end
        end

        for _, entry in pairs(state.labels) do condemn(entry.widget) end
        if state.exp ~= nil then
            condemn(state.exp.native)
            condemn(state.exp.back)
            condemn(state.exp.fill)
            condemn(state.exp.label)
        end
        for _, widget in ipairs(doomed) do
            pcall(function() widget:RemoveFromParent() end)
        end
    end
    state.cockpit = nil
    state.labels = {}
    state.exp = nil
    state.fontDonor = nil
    if reason ~= nil then dbg("widgets released | " .. reason) end
end

--========================================================--
--                    NATIVE RESOLUTION                   --
--========================================================--

local cachedLibraries = {}

local function library(path)
    if isValid(cachedLibraries[path]) then return cachedLibraries[path] end
    cachedLibraries[path] = nil
    local ok, found = pcall(function() return StaticFindObject(path) end)
    if ok and isValid(found) then cachedLibraries[path] = found end
    return cachedLibraries[path]
end

local function objectName(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    if ok and type(name) == "string" then return name end
    return "<unnamed>"
end

local function shortName(object)
    local name = objectName(object)
    return name:match("([^%.%s/]+)$") or name
end

local function findInstance(className)
    local ok, found = pcall(function() return FindFirstOf(className) end)
    if not ok or not isValid(found) then return nil end
    -- FindFirstOf can hand back the class default object, which has no widget
    -- tree and no player behind it.
    if string.find(objectName(found), "Default__", 1, true) ~= nil then
        return nil
    end
    return found
end

-- The cockpit's own lifetime is the mod's lifecycle. Nothing else resets the
-- widget state: as long as this object is valid the widgets inside it are valid
-- too, and when the world tears it down IsValid stops answering and the
-- references are dropped here. That is also what keeps a second ClientRestart
-- inside one world from stacking a duplicate set of widgets.
local function resolveCockpit()
    if isValid(state.cockpit) then return state.cockpit end
    if state.cockpit ~= nil then releaseWidgets(false, "cockpit went invalid") end

    local found = findInstance("WBP_Cockpit_C")
        or findInstance("RODCockpitWidgetBase")
    if found == nil then return nil end

    state.cockpit = found
    dbg("cockpit resolved | " .. objectName(found))
    return found
end

local function resolveHero(cockpit)
    local hero = weakObject(cockpit.HeroCharacterRef)
    if isValid(hero) then return hero end
    return findInstance("RODWorldHeroCharacter")
        or findInstance("RODHeroCharacter")
end

local function resolvePlayerState(cockpit)
    local playerState = weakObject(cockpit.PlayerStateRef)
    if isValid(playerState) then return playerState end
    return findInstance("RODPlayerState")
end

--========================================================--
--                      GEOMETRY                          --
--========================================================--

-- A CanvasPanelSlot is the only slot type carrying a position, and
-- SlotAsCanvasSlot is the sanctioned way to ask for one: reading .Slot directly
-- would hand back whatever slot type the parent happens to use. It returns nil
-- whenever the parent is not a CanvasPanel, which is information in itself.
local function measure(widget)
    local layout = library(LAYOUT_LIBRARY)
    if layout == nil or not isValid(widget) then return nil end
    local slot = nil
    local ok = pcall(function() slot = layout:SlotAsCanvasSlot(widget) end)
    if not ok or not isValid(slot) then return nil end

    local geometry = nil
    local read = pcall(function()
        local position = slot:GetPosition()
        local size = slot:GetSize()
        geometry = {
            x = tonumber(position.X),
            y = tonumber(position.Y),
            width = tonumber(size.X),
            height = tonumber(size.Y),
        }
    end)
    if not read or geometry == nil
        or geometry.x == nil or geometry.y == nil
        or geometry.width == nil or geometry.height == nil then
        return nil
    end
    if geometry.width <= 1.0 then return nil end
    geometry.note = string.format("x=%.0f y=%.0f w=%.0f h=%.0f",
        geometry.x, geometry.y, geometry.width, geometry.height)
    return geometry
end

-- Drawing ON a bar means out-ranking everything already in that canvas, and a
-- fixed ZOrder is a guess about a layout the mod does not own.
--
-- The floor matters as much as the survey: SlotAsCanvasSlot returns nothing
-- for a child whose parent is not a CanvasPanel, and on this build it returns
-- nothing for the gauges. A survey that reads no slot at all reports 0 and
-- would put the readout on layer 10 -- under anything the HUD placed higher.
local MINIMUM_Z_ORDER = 500

local function topZOrder(canvas)
    local layout = library(LAYOUT_LIBRARY)
    local highest = 0
    if layout == nil then return highest end

    local count = nil
    pcall(function() count = canvas:GetChildrenCount() end)
    if type(count) ~= "number" then return highest end

    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = canvas:GetChildAt(index) end)
        if isValid(child) then
            local slot = nil
            pcall(function() slot = layout:SlotAsCanvasSlot(child) end)
            if isValid(slot) then
                local order = nil
                pcall(function() order = tonumber(slot:GetZOrder()) end)
                if finiteNumber(order) and order > highest then
                    highest = order
                end
            end
        end
    end
    return highest
end

-- Every gauge assembly caches its own drawing. A cached subtree keeps
-- repainting what it was cached with, which would freeze anything the mod adds
-- under it on its first value.
local function stopCaching(widget, member)
    pcall(function() widget[member]:SetCanCache(false) end)
end

-- The experience block's surface, and it is deliberately NOT the readouts'.
-- Hanging it off the gauge assembly's own canvas by a normalised edge anchor
-- is the arrangement that landed it correctly above the HUD; the readouts have
-- a different problem (draw order) and chasing it must not move this.
local function experienceSurface(cockpit, definition)
    local unit = cockpit[definition.unit]
    if not isValid(unit) then return nil end
    local canvas = unit[definition.canvas]
    if not isValid(canvas) then return nil end
    stopCaching(unit, "InvalidationBox_root")
    return { canvas = canvas, size = measure(unit[definition.gauge]) }
end

-- WHERE a readout draws, in order of preference, because a readout centred ON
-- its bar has to be painted AFTER the gauge art and no ZOrder can achieve that
-- from a canvas that is painted first. Attaching is the only honest test that
-- a candidate is a usable canvas, so ensureLabel walks this list and keeps the
-- first one that accepts the widget.
--
--   inside  the gauge widget's own root panel -- the innermost surface there
--           is, painted last within the bar.
--   gauge   the assembly canvas the gauge sits in. Painted before the gauge
--           art, so a centred readout lands behind it, but an off-the-end one
--           is clear of the art and shows fine.
--   front   the cockpit's UnitGauge canvas. Painted after every assembly, but
--           it only works if the assemblies report a rectangle in it -- and on
--           this build they all report the origin, which stacks every readout
--           in the corner.
local function readoutCandidates(cockpit, definition)
    local unit = cockpit[definition.unit]
    if not isValid(unit) then return {} end
    stopCaching(unit, "InvalidationBox_root")

    local candidates = {}
    local gauge = unit[definition.gauge]
    -- Everything between the assembly and the gauge art. Any of these is a
    -- plausible place for the HUD to apply its fade.
    local chain = { unit, unit[definition.canvas], gauge }

    if CONFIG.READOUT_LAYER == "inside" and isValid(gauge) then
        local root = nil
        pcall(function() root = gauge.WidgetTree.RootWidget end)
        if isValid(root) then
            candidates[#candidates + 1] =
                { canvas = root, layer = "inside", chain = chain,
                  normalised = true }
        end
    elseif CONFIG.READOUT_LAYER == "front" then
        local front = cockpit.UnitGauge
        if isValid(front) then
            stopCaching(cockpit, "InvalidationBox_61")
            -- No measuring here. Asking this canvas where each assembly sits
            -- returns the origin for all three -- that is what stacked every
            -- readout in the corner. The point comes from settings instead,
            -- in the canvas's own design-space pixels, which the HUD's own
            -- layout is authored in and which do not change with resolution.
            candidates[#candidates + 1] = {
                canvas = front,
                layer = "front",
                chain = chain,
                point = {
                    x = CONFIG[definition.posX],
                    y = CONFIG[definition.posY],
                },
            }
        end
    end

    local assembly = unit[definition.canvas]
    if isValid(assembly) then
        candidates[#candidates + 1] = {
            canvas = assembly,
            layer = "gauge",
            chain = chain,
            rectangle = measure(gauge),
        }
    end
    return candidates
end

--========================================================--
--                  WIDGET CONSTRUCTION                   --
--========================================================--

-- Every widget the mod builds is named with this prefix, which is the only
-- thing that makes a leftover recognisable later. See sweepOrphans.
local WIDGET_PREFIX = "GaugeNumbers_"
local widgetSerial = 0

local function constructWidget(classPath, outer)
    local class = nil
    local ok = pcall(function() class = StaticFindObject(classPath) end)
    if not ok or not isValid(class) then
        return nil, "widget class is unavailable: " .. classPath
    end

    widgetSerial = widgetSerial + 1
    local widget = nil
    local built, buildError = pcall(function()
        widget = StaticConstructObject(class, outer,
            FName(WIDGET_PREFIX .. tostring(widgetSerial)))
    end)
    if not isValid(widget) then
        -- A named construction is preferred but not required; an unnamed
        -- widget still works, it just cannot be swept up later.
        pcall(function() widget = StaticConstructObject(class, outer) end)
    end
    if not isValid(widget) then
        if not built then return nil, tostring(buildError) end
        return nil, "construction returned no widget: " .. classPath
    end
    return widget, nil
end

-- UE4SS restarting the Lua mods builds a fresh Lua state, but the widgets from
-- the previous run belong to the cockpit, not to Lua: they stay in the tree,
-- still parented, with the old run's poll no longer touching them but the new
-- run's widgets stacked on top. That is what put two of every number on screen.
--
-- Nothing in the Lua state can survive to clean that up, so the evidence has to
-- be read off the tree itself -- hence the name prefix. This runs before any
-- construction, so a restart lands on a clean canvas.
local function sweepCanvas(canvas, extraMatch)
    if not isValid(canvas) then return 0 end
    local count = nil
    pcall(function() count = canvas:GetChildrenCount() end)
    if type(count) ~= "number" then return 0 end

    local doomed = {}
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = canvas:GetChildAt(index) end)
        if isValid(child) then
            local name = objectName(child)
            if string.find(name, WIDGET_PREFIX, 1, true) ~= nil
                or (extraMatch ~= nil
                    and string.find(name, extraMatch, 1, true) ~= nil) then
                doomed[#doomed + 1] = child
            end
        end
    end
    for _, child in ipairs(doomed) do
        pcall(function() child:RemoveFromParent() end)
    end
    return #doomed
end

-- Once per cockpit: every surface the mod has ever attached anything to, in
-- any layer setting, because the previous run may have been configured
-- differently from this one.
local sweptCockpit = nil

local function sweepOrphans(cockpit)
    local identity = objectName(cockpit)
    if sweptCockpit == identity then return end
    sweptCockpit = identity

    local removed = sweepCanvas(cockpit.UnitGauge)
    for _, definition in ipairs(BARS) do
        local unit = cockpit[definition.unit]
        if isValid(unit) then
            -- The experience bar is a copy of the stamina gauge. The real one
            -- lives in the stamina assembly, so that class turning up in any
            -- other assembly is a leftover copy -- and it is the one widget
            -- the mod cannot name, because the engine creates it.
            local extra = nil
            if definition.unit ~= NATIVE_DONOR.unit then
                extra = "StaminaGauge_Player"
            end
            removed = removed + sweepCanvas(unit[definition.canvas], extra)

            local gauge = unit[definition.gauge]
            if isValid(gauge) then
                local root = nil
                pcall(function() root = gauge.WidgetTree.RootWidget end)
                removed = removed + sweepCanvas(root)
            end
        end
    end

    if removed > 0 then
        log(string.format(
            "SWEEP | removed %d widget(s) left behind by a previous run",
            removed))
    end
end

local function resolveFontDonor(cockpit)
    if isValid(state.fontDonor) then return state.fontDonor end
    state.fontDonor = nil
    -- The partner name plate is the one text block always mounted in the
    -- cockpit and styled for it. Without a partner it is absent, and the
    -- TextBlock CDO's own font is a perfectly readable fallback.
    local donor = nil
    pcall(function()
        local partner = cockpit.PartnerUnitGauge
        if isValid(partner) and isValid(partner.PlayerName) then
            donor = partner.PlayerName
        end
    end)
    if isValid(donor) then state.fontDonor = donor end
    return state.fontDonor
end

local function styleLabel(label, cockpit)
    local donor = resolveFontDonor(cockpit)
    if donor ~= nil then
        pcall(function() label:SetFont(donor.Font) end)
    end
    pcall(function() label.Font.Size = CONFIG.FONT_SIZE end)
    pcall(function()
        label:SetColorAndOpacity({ SpecifiedColor = WHITE, ColorUseRule = 0 })
    end)
    -- The readouts sit over gauge art and open world alike, so they need their
    -- own contrast.
    pcall(function() label:SetShadowOffset({ X = 1.0, Y = 1.0 }) end)
    pcall(function()
        label:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
    end)
end

-- placement fields:
--   anchor   normalised point on the canvas the widget hangs off
--   align    which point of the widget lands on it
--   position pixel offset from the anchor
--   size     nil for auto-sized text, { X, Y } for a box
local function place(canvas, widget, placement, zOrder)
    local slot = nil
    local ok = pcall(function() slot = canvas:AddChildToCanvas(widget) end)
    if not ok or not isValid(slot) then return nil end
    pcall(function()
        slot:SetAutoSize(placement.size == nil)
        slot:SetMinimum(placement.anchor)
        slot:SetMaximum(placement.anchor)
        slot:SetAlignment(placement.align)
        slot:SetPosition(placement.position)
        if placement.size ~= nil then slot:SetSize(placement.size) end
        slot:SetZOrder(zOrder)
    end)
    pcall(function()
        widget:SetVisibility(HIT_TEST_INVISIBLE)
        widget:SetRenderOpacity(1.0)
    end)
    return slot
end

--========================================================--
--                     BAR READOUTS                       --
--========================================================--

local function readoutPlacement(candidate, rightMost)
    local rectangle = candidate.rectangle
    local centred = CONFIG.READOUT_PLACEMENT == "center"

    -- An explicit point on the canvas: the readout's centre when centred, its
    -- left edge when not.
    if candidate.point ~= nil then
        return {
            anchor = { X = 0.0, Y = 0.0 },
            align = { X = centred and 0.5 or 0.0, Y = 0.5 },
            position = {
                X = candidate.point.x + CONFIG.TEXT_OFFSET_X,
                Y = candidate.point.y + CONFIG.TEXT_OFFSET_Y,
            },
        }
    end

    if rectangle == nil then
        -- Normalised anchors need no measurement: the middle of the canvas is
        -- the middle of the canvas whatever the bar turns out to be, and its
        -- right edge is its right edge.
        if centred then
            return {
                anchor = { X = 0.5, Y = 0.5 },
                align = { X = 0.5, Y = 0.5 },
                position = { X = CONFIG.TEXT_OFFSET_X, Y = CONFIG.TEXT_OFFSET_Y },
            }
        end
        return {
            anchor = { X = 1.0, Y = 0.5 },
            align = { X = 0.0, Y = 0.5 },
            position = { X = CONFIG.TEXT_OFFSET_X, Y = CONFIG.TEXT_OFFSET_Y },
        }
    end

    if centred then
        return {
            anchor = { X = 0.0, Y = 0.0 },
            align = { X = 0.5, Y = 0.5 },
            position = {
                X = rectangle.x + rectangle.width * 0.5 + CONFIG.TEXT_OFFSET_X,
                Y = rectangle.y + rectangle.height * 0.5 + CONFIG.TEXT_OFFSET_Y,
            },
        }
    end

    -- The three bars are different lengths, so ending each readout at its own
    -- bar produces a staircase. Aligning them is only meaningful when every
    -- readout shares one coordinate space.
    local right = rectangle.x + rectangle.width
    if CONFIG.ALIGN_READOUTS and rightMost ~= nil
        and candidate.layer == "front" then
        right = rightMost
    end
    return {
        anchor = { X = 0.0, Y = 0.0 },
        align = { X = 0.0, Y = 0.5 },
        position = {
            X = right + CONFIG.TEXT_OFFSET_X,
            Y = rectangle.y + rectangle.height * 0.5 + CONFIG.TEXT_OFFSET_Y,
        },
    }
end

local function ensureLabel(cockpit, definition, surfaces)
    local entry = state.labels[definition.key]
    if entry ~= nil and isValid(entry.widget) then return entry end
    state.labels[definition.key] = nil

    local candidates = surfaces.bars[definition.key]
    if candidates == nil or #candidates == 0 then
        return nil, definition.key .. " gauge assembly is unavailable"
    end

    for _, candidate in ipairs(candidates) do
        local label, buildError = constructWidget(TEXT_BLOCK_CLASS,
            candidate.canvas)
        if label == nil then return nil, buildError end
        styleLabel(label, cockpit)

        local zOrder = math.max(topZOrder(candidate.canvas) + 10,
            MINIMUM_Z_ORDER)
        local placement = readoutPlacement(candidate, surfaces.rightMost)
        local slot = place(candidate.canvas, label, placement, zOrder)
        if slot ~= nil then
            entry = {
                widget = label,
                slot = slot,
                definition = definition,
                layer = candidate.layer,
                current = nil,
                maximum = nil,
                -- Only the front layer needs this: there the readout is a
                -- sibling of the assemblies rather than a child, so it does
                -- not inherit the HUD's fade and has to be told.
                sources = (candidate.layer == "front") and candidate.chain
                    or nil,
            }
            state.labels[definition.key] = entry
            -- Logged unconditionally: this one line is what a misplaced
            -- readout is diagnosed from, and needing debug logging on first
            -- only means asking for the screenshot twice.
            local where = "unmeasured"
            if candidate.point ~= nil then
                where = string.format("point %.0f,%.0f",
                    candidate.point.x, candidate.point.y)
            elseif candidate.rectangle ~= nil then
                where = candidate.rectangle.note
            end
            log(string.format("READOUT | %s attached | layer=%s | %s | z=%d",
                definition.key, candidate.layer, where, zOrder))
            return entry
        end
    end

    return nil, definition.key .. " no canvas accepted the readout"
end

local function formatValue(current, maximum)
    if CONFIG.VALUE_FORMAT == "current" then
        return string.format("%d", current)
    end
    if CONFIG.VALUE_FORMAT == "percent" then
        if maximum <= 0 then return "0%" end
        return string.format("%d%%", round((current / maximum) * 100.0))
    end
    return string.format("%d / %d", current, maximum)
end

-- The HUD hides and fades its gauges on its own schedule -- out of combat, in
-- cutscenes, during quest transitions. A readout drawn in front of the bars is
-- not inside the thing being faded, so it would keep hanging in an empty
-- corner.
--
-- Which widget the game actually fades is not knowable from the headers, and
-- reading only the assembly missed it, so the whole chain down to the gauge is
-- sampled: the readout hides if ANY link is hidden and takes the LOWEST
-- opacity found. That follows a fade applied at any depth without having to
-- know which depth the game chose. IsVisible answers for the live Slate
-- widget, which is what a play-only animation actually changes.
local function mirrorVisibility(entry)
    if entry == nil then return end
    if not isValid(entry.widget) then return end

    if state.previewApplied then
        if entry.shown ~= true then
            entry.shown = true
            pcall(function() entry.widget:SetVisibility(HIT_TEST_INVISIBLE) end)
        end
        if entry.opacity ~= 1.0 then
            entry.opacity = 1.0
            pcall(function() entry.widget:SetRenderOpacity(1.0) end)
        end
        return
    end

    if entry.sources == nil then return end

    local shown = true
    local opacity = 1.0
    local sampled = false

    for _, source in ipairs(entry.sources) do
        if isValid(source) then
            local visible, alpha
            local ok = pcall(function()
                visible = source:IsVisible()
                alpha = source:GetRenderOpacity()
            end)
            if ok then
                sampled = true
                if visible == false then shown = false end
                if finiteNumber(alpha) and alpha < opacity then
                    opacity = alpha
                end
            end
        end
    end
    if not sampled then return end

    if entry.shown ~= shown then
        entry.shown = shown
        pcall(function()
            entry.widget:SetVisibility(shown and HIT_TEST_INVISIBLE or COLLAPSED)
        end)
    end
    if entry.opacity ~= opacity then
        entry.opacity = opacity
        pcall(function() entry.widget:SetRenderOpacity(opacity) end)
    end
end

local function stampLabel(entry, current, maximum)
    if entry == nil or not isValid(entry.widget) then return end
    if not finiteNumber(current) or not finiteNumber(maximum) then return end

    local currentValue = round(current)
    local maximumValue = round(maximum)
    if entry.current == currentValue and entry.maximum == maximumValue then
        return
    end
    entry.current = currentValue
    entry.maximum = maximumValue
    pcall(function()
        entry.widget:SetText(FText(formatValue(currentValue, maximumValue)))
    end)
end

--========================================================--
--                    EXPERIENCE BAR                      --
--========================================================--

-- A real instance of the game's own gauge widget, from the class of a gauge
-- already mounted in this cockpit -- so no LoadAsset, and no asset path that
-- could stop resolving after a patch.
local function cloneNativeGauge(cockpit, outer)
    local donorUnit = cockpit[NATIVE_DONOR.unit]
    if not isValid(donorUnit) then
        return nil, "native gauge donor assembly is unavailable"
    end
    local donor = donorUnit[NATIVE_DONOR.gauge]
    if not isValid(donor) then
        return nil, "native gauge donor is unavailable"
    end

    local class = nil
    pcall(function() class = donor:GetClass() end)
    if not isValid(class) then
        return nil, "native gauge donor class is unavailable"
    end

    local widgets = library(WIDGET_LIBRARY)
    if widgets == nil then
        return nil, "WidgetBlueprintLibrary is unavailable"
    end
    local owningPlayer = nil
    pcall(function() owningPlayer = cockpit:GetOwningPlayer() end)
    if not isValid(owningPlayer) then
        return nil, "owning player is unavailable"
    end

    local widget = nil
    local ok, createError = pcall(function()
        widget = widgets:Create(outer, class, owningPlayer)
    end)
    if not ok then return nil, tostring(createError) end
    if not isValid(widget) then
        return nil, "native gauge copy was not created"
    end
    pcall(function() widget:SetGaugeColor(EXP_FILL_COLOR) end)
    return widget, nil
end

-- ResetGaugeValue / ResetGaugeRate rather than the Set* pair: the Set path is
-- the animated one, which drives blink animations and the widget's own timers.
-- Reset just states the value, which is all an experience bar wants.
local function driveNativeGauge(widget, current, span)
    local ratio = 0.0
    if span > 0 then
        ratio = current / span
        if ratio < 0.0 then ratio = 0.0 end
        if ratio > 1.0 then ratio = 1.0 end
    end
    pcall(function()
        widget:ResetGaugeValue(math.floor(current), math.floor(span), 0)
    end)
    pcall(function() widget:ResetGaugeRate(ratio, 1.0) end)
end

local function experienceIntact(exp)
    if exp == nil then return false end
    if exp.wantBar then
        if exp.style == "native" then
            if not isValid(exp.native) then return false end
        elseif not (isValid(exp.back) and isValid(exp.fill)
            and isValid(exp.fillSlot)) then
            return false
        end
    end
    if exp.wantText and not isValid(exp.label) then return false end
    return true
end

local function ensureExperience(cockpit, surfaces)
    if experienceIntact(state.exp) then return state.exp end
    state.exp = nil

    local wantBar = CONFIG.SHOW_EXP_BAR
    local wantText = CONFIG.SHOW_EXP_TEXT
    if not wantBar and not wantText then return nil, nil end

    local definition = BAR_BY_ANCHOR[CONFIG.EXP_ANCHOR]
    local surface = experienceSurface(cockpit, definition)
    if surface == nil then
        return nil, "experience anchor assembly is unavailable"
    end
    local canvas = surface.canvas

    local width = (surface.size ~= nil and surface.size.width)
        or FALLBACK_BAR_WIDTH
    if CONFIG.EXP_BAR_WIDTH > 0.0 then width = CONFIG.EXP_BAR_WIDTH end
    local height = (surface.size ~= nil and surface.size.height)
        or FALLBACK_BAR_HEIGHT
    if CONFIG.EXP_BAR_HEIGHT > 0.0 then height = CONFIG.EXP_BAR_HEIGHT end

    -- Always the normalised edge anchor, never a measured rectangle. This is
    -- the arrangement that put the bar where it belongs, and a measurement
    -- that starts resolving on some future build must not silently move it.
    local above = CONFIG.EXP_PLACEMENT ~= "below"
    local anchor = { X = 0.0, Y = above and 0.0 or 1.0 }
    local boxAlign = { X = 0.0, Y = above and 1.0 or 0.0 }
    local originX = CONFIG.EXP_OFFSET_X
    local originY = CONFIG.EXP_OFFSET_Y
    local centreY = originY + (above and -height * 0.5 or height * 0.5)

    local zOrder = math.max(topZOrder(canvas) + 10, MINIMUM_Z_ORDER)
    local built = {}

    local function boxPlacement(x, w)
        return {
            anchor = anchor,
            align = boxAlign,
            position = { X = x, Y = originY },
            size = { X = w, Y = height },
        }
    end

    local function unwind(message)
        for _, widget in ipairs(built) do
            if isValid(widget) then
                pcall(function() widget:RemoveFromParent() end)
            end
        end
        return nil, message
    end

    local exp = {
        style = "flat",
        wantBar = wantBar,
        wantText = wantText,
        width = width,
        height = height,
    }

    if wantBar then
        if CONFIG.EXP_STYLE == "native" then
            local native, cloneError = cloneNativeGauge(cockpit, canvas)
            if native ~= nil then
                built[#built + 1] = native
                if place(canvas, native,
                    boxPlacement(originX, width), zOrder) == nil then
                    return unwind("experience gauge copy was rejected")
                end
                exp.style = "native"
                exp.native = native
            else
                -- Falling back rather than failing: a HUD without the game's
                -- own frame is still a working experience bar.
                log("EXPERIENCE | native gauge copy unavailable (" ..
                    tostring(cloneError) .. ") | drawing a flat bar instead")
            end
        end

        if exp.style == "flat" then
            local back, backError = constructWidget(IMAGE_CLASS, canvas)
            if back == nil then return unwind(backError) end
            built[#built + 1] = back
            pcall(function() back:SetColorAndOpacity(EXP_BACK_COLOR) end)
            if place(canvas, back,
                boxPlacement(originX, width), zOrder) == nil then
                return unwind("experience bar backing was rejected")
            end

            local fill, fillError = constructWidget(IMAGE_CLASS, canvas)
            if fill == nil then return unwind(fillError) end
            built[#built + 1] = fill
            pcall(function() fill:SetColorAndOpacity(EXP_FILL_COLOR) end)
            local fillSlot = place(canvas, fill,
                boxPlacement(originX, 0.0), zOrder + 1)
            if fillSlot == nil then
                return unwind("experience bar fill was rejected")
            end
            exp.back = back
            exp.fill = fill
            exp.fillSlot = fillSlot
        end
    end

    if wantText then
        local label, labelError = constructWidget(TEXT_BLOCK_CLASS, canvas)
        if label == nil then return unwind(labelError) end
        built[#built + 1] = label
        styleLabel(label, cockpit)

        local placement
        if CONFIG.READOUT_PLACEMENT == "center" then
            placement = {
                anchor = anchor,
                align = { X = 0.5, Y = 0.5 },
                position = {
                    X = originX + width * 0.5 + CONFIG.TEXT_OFFSET_X,
                    Y = centreY + CONFIG.TEXT_OFFSET_Y,
                },
            }
        else
            placement = {
                anchor = anchor,
                align = { X = 0.0, Y = 0.5 },
                position = {
                    X = originX + width + CONFIG.TEXT_OFFSET_X,
                    Y = centreY + CONFIG.TEXT_OFFSET_Y,
                },
            }
        end
        if place(canvas, label, placement, zOrder + 2) == nil then
            return unwind("experience readout was rejected")
        end
        exp.label = label
    end

    state.exp = exp
    log(string.format(
        "EXPERIENCE | %s bar %s %s | at %+.0f,%+.0f (%.0fx%.0f) | z=%d | " ..
        "size from %s",
        exp.style, CONFIG.EXP_PLACEMENT, CONFIG.EXP_ANCHOR,
        originX, originY, width, height, zOrder,
        (surface.size ~= nil and surface.size.note) or "fallback"))
    return exp
end

-- HeroExperience is read as progress INTO the current level, which is what the
-- status screen shows (615 / 24000 at Lv.52). If it ever arrives as a running
-- total instead, the previous level's requirement is the floor of the current
-- span and both numbers are rebased onto it.
local function experienceSpan(playerState, exp)
    local level, current
    local ok = pcall(function()
        level = tonumber(playerState.ExperienceData.HeroLevel)
        current = tonumber(playerState.ExperienceData.HeroExperience)
    end)
    if not ok or level == nil or current == nil then
        local fallback = pcall(function()
            local data = playerState:GetExperienceData()
            level = tonumber(data.HeroLevel)
            current = tonumber(data.HeroExperience)
        end)
        if not fallback then return nil end
    end
    if not finiteNumber(level) or not finiteNumber(current) then return nil end

    if exp.level ~= level then
        local need, floor = nil, nil
        pcall(function() need = tonumber(playerState:GetNextHeroExp(level)) end)
        pcall(function()
            floor = tonumber(playerState:GetNextHeroExp(level - 1))
        end)
        exp.level = level
        exp.need = need
        exp.floor = floor
        dbg(string.format("experience level %d | need=%s floor=%s",
            level, tostring(need), tostring(floor)))
    end

    local need = exp.need
    if not finiteNumber(need) or need <= 0 then
        return { level = level, current = current, span = 0 }
    end

    local floor = 0
    if current > need and finiteNumber(exp.floor)
        and exp.floor > 0 and need > exp.floor then
        floor = exp.floor
    end
    return { level = level, current = current - floor, span = need - floor }
end

local function stampExperience(exp, reading)
    if reading == nil then return end

    if exp.wantText and isValid(exp.label) then
        local numbers
        if reading.span <= 0 then
            numbers = string.format("%d", round(reading.current))
        else
            numbers = string.format("%d / %d",
                round(reading.current), round(reading.span))
        end
        local text = numbers
        if CONFIG.SHOW_EXP_LEVEL then
            text = string.format("Lv.%d   %s", reading.level, numbers)
        end
        if exp.text ~= text then
            exp.text = text
            pcall(function() exp.label:SetText(FText(text)) end)
        end
    end

    if not exp.wantBar then return end

    if exp.style == "native" then
        if exp.value ~= reading.current or exp.spanValue ~= reading.span then
            exp.value = reading.current
            exp.spanValue = reading.span
            driveNativeGauge(exp.native, reading.current, reading.span)
        end
        return
    end

    local ratio = 0.0
    if reading.span > 0 then
        ratio = reading.current / reading.span
        if ratio < 0.0 then ratio = 0.0 end
        if ratio > 1.0 then ratio = 1.0 end
    end
    -- Quantised to whole pixels: below that the resize is invisible and would
    -- only spend a native call per poll for nothing.
    local filled = math.floor(ratio * exp.width)
    if exp.filled ~= filled then
        exp.filled = filled
        pcall(function()
            exp.fillSlot:SetSize({ X = filled, Y = exp.height })
        end)
    end
end

--========================================================--
--                         TICK                           --
--========================================================--

local function readHeroValues(hero)
    local values = {}
    pcall(function()
        local defensive = hero.DefensiveAttributeSet
        if isValid(defensive) then
            values.HP = {
                tonumber(defensive.Health.CurrentValue),
                tonumber(defensive.MaxHealth.CurrentValue),
            }
        end
    end)
    pcall(function()
        local attributes = hero.AttributeSet
        if isValid(attributes) then
            values.STAMINA = {
                tonumber(attributes.Stamina.CurrentValue),
                tonumber(attributes.MaxStamina.CurrentValue),
            }
            values.SP = {
                tonumber(attributes.Soul.CurrentValue),
                tonumber(attributes.MaxSoul.CurrentValue),
            }
        end
    end)
    return values
end

local function needsInjection()
    for _, definition in ipairs(BARS) do
        if CONFIG[definition.setting] then
            local entry = state.labels[definition.key]
            if entry == nil or not isValid(entry.widget) then return true end
        end
    end
    if CONFIG.SHOW_EXP and not experienceIntact(state.exp) then
        return CONFIG.SHOW_EXP_BAR or CONFIG.SHOW_EXP_TEXT
    end
    return false
end

local function updatePreviewMode(active, previewError)
    if previewError ~= nil then
        reportOnce("PREVIEW-MARKER", "PREVIEW ERROR | " .. tostring(previewError))
    else
        clearReport("PREVIEW-MARKER")
    end

    local requested = active == true
    if requested and not state.previewRequested then
        log("PREVIEW | active lease observed")
    elseif not requested and state.previewRequested then
        log("PREVIEW | lease closed or expired")
    end
    state.previewRequested = requested
    if not state.previewRequested then
        if state.previewApplied or state.previewMounted then
            restorePreviewVisibility(isValid(state.cockpit))
        end
        return
    end

    if CONFIG == nil or not CONFIG.ENABLED then
        if state.previewApplied or state.previewMounted then
            restorePreviewVisibility(isValid(state.cockpit))
        end
        return
    end

    local cockpit = resolveCockpit()
    if cockpit == nil then
        reportOnce("PREVIEW-COCKPIT",
            "PREVIEW ERROR | no live cockpit while the preview lease is active")
        return
    end
    clearReport("PREVIEW-COCKPIT")
    applyPreviewVisibility(cockpit)
end

-- A self-rescheduling ExecuteWithDelay + ExecuteInGameThread pair creates a
-- fresh ProcessEvent callback on every pass. On this UE4SS build one invalid
-- callback can be removed while the menu is being rebuilt, leaving the native
-- UnitGauge detached forever. A single persistent game-thread loop owns the
-- lease and its restoration, so closing the marker cannot strand the widget.
local previewLoopHandle = nil
local function previewLoop()
    local ok, previewError = xpcall(function()
        local active, leaseError = readPreviewLease()
        updatePreviewMode(active, leaseError)
    end, debug.traceback)
    if not ok then
        reportOnce("PREVIEW-POLL", "PREVIEW ERROR | loop tick failed: " ..
            tostring(previewError))
    else
        clearReport("PREVIEW-POLL")
    end
end

local function startPreviewLoop()
    local ok, handle = pcall(function()
        return LoopInGameThreadWithDelay(PREVIEW_POLL_MS, previewLoop)
    end)
    if not ok or type(handle) ~= "number" then
        error("[" .. MOD_NAME .. "] PREVIEW ERROR | persistent loop could not start: " ..
            tostring(handle))
    end
    previewLoopHandle = handle
end

local function tick()
    if CONFIG == nil then return end
    if not CONFIG.ENABLED then
        if state.previewApplied or state.previewMounted then
            restorePreviewVisibility(isValid(state.cockpit))
        end
        return
    end

    local cockpit = resolveCockpit()
    if cockpit == nil then return end

    if state.previewRequested then
        applyPreviewVisibility(cockpit)
    elseif state.previewApplied or state.previewMounted then
        restorePreviewVisibility(true)
    end

    -- Resolving costs native calls, and is only worth them when something has
    -- to be built.
    local surfaces = { bars = {}, rightMost = nil }
    if needsInjection() then
        -- Before anything is built, never after: a sweep that ran later would
        -- delete the widgets this run just attached.
        sweepOrphans(cockpit)
        for _, definition in ipairs(BARS) do
            local candidates = readoutCandidates(cockpit, definition)
            surfaces.bars[definition.key] = candidates
            for _, candidate in ipairs(candidates) do
                local rectangle = candidate.rectangle
                if rectangle ~= nil and candidate.layer == "front" then
                    local right = rectangle.x + rectangle.width
                    if surfaces.rightMost == nil
                        or right > surfaces.rightMost then
                        surfaces.rightMost = right
                    end
                end
            end
        end
    end

    for _, definition in ipairs(BARS) do
        if CONFIG[definition.setting] then
            local tag = "INJECT-" .. definition.key
            local entry, injectError = ensureLabel(cockpit, definition, surfaces)
            if entry == nil then
                reportOnce(tag, "INJECT ERROR | " .. tostring(injectError))
            else
                clearReport(tag)
            end
        end
    end

    -- The three cockpit events do the fast path. This re-stamp is the safety
    -- net: it fills a readout injected mid-fight, and covers any value the game
    -- changes without raising its own event.
    local hero = resolveHero(cockpit)
    if isValid(hero) then
        local values = readHeroValues(hero)
        for key, pair in pairs(values) do
            local definition = BAR_BY_KEY[key]
            if definition ~= nil and CONFIG[definition.setting] then
                stampLabel(state.labels[key], pair[1], pair[2])
            end
        end
    end
    for _, entry in pairs(state.labels) do mirrorVisibility(entry) end

    if not CONFIG.SHOW_EXP then return end
    local exp, expError = ensureExperience(cockpit, surfaces)
    if exp == nil then
        if expError ~= nil then
            reportOnce("INJECT-EXP", "INJECT ERROR | " .. tostring(expError))
        end
        return
    end
    clearReport("INJECT-EXP")

    local playerState = resolvePlayerState(cockpit)
    if not isValid(playerState) then
        reportOnce("EXP-STATE", "EXPERIENCE | player state is unavailable")
        return
    end
    clearReport("EXP-STATE")
    stampExperience(exp, experienceSpan(playerState, exp))
end

-- Keep one persistent game-thread callback for the normal reconciliation tick
-- too. Creating a new ProcessEvent action for every pass was the second source
-- of the invalid callback seen while the menu was being edited.
local TICK_LOOP_MS = 100
local tickElapsedMs = 0
local tickLoopHandle = nil
local function tickLoop()
    tickElapsedMs = tickElapsedMs + TICK_LOOP_MS

    local interval = 500
    if CONFIG ~= nil then interval = math.floor(CONFIG.REFRESH_MS) end
    if state.previewRequested then interval = math.min(interval, TICK_LOOP_MS) end
    if tickElapsedMs < interval then return end
    tickElapsedMs = 0

    local ok, tickError = xpcall(tick, debug.traceback)
    if not ok then
        reportOnce("TICK", "TICK ERROR | " .. tostring(tickError))
    else
        clearReport("TICK")
    end
end

local function startTickLoop()
    local ok, handle = pcall(function()
        return LoopInGameThreadWithDelay(TICK_LOOP_MS, tickLoop)
    end)
    if not ok or type(handle) ~= "number" then
        error("[" .. MOD_NAME .. "] TICK ERROR | persistent loop could not start: " ..
            tostring(handle))
    end
    tickLoopHandle = handle
end

--========================================================--
--                         PROBE                          --
--========================================================--

-- Dumps the real widget tree of the cockpit's gauge area. Deducing this layout
-- from the SDK headers got the draw order wrong twice: a header lists a class's
-- members, not which of them parents which.
local PROBE_DEPTH = 8

local function probeTree(root, label)
    local layout = library(LAYOUT_LIBRARY)
    log("PROBE | " .. label)

    local function walk(widget, depth)
        if not isValid(widget) or depth > PROBE_DEPTH then return end
        local detail = ""
        if layout ~= nil then
            local slot = nil
            pcall(function() slot = layout:SlotAsCanvasSlot(widget) end)
            if isValid(slot) then
                pcall(function()
                    local position = slot:GetPosition()
                    local size = slot:GetSize()
                    detail = string.format(
                        " [canvasslot z=%d x=%.0f y=%.0f w=%.0f h=%.0f]",
                        slot:GetZOrder(), position.X, position.Y,
                        size.X, size.Y)
                end)
            else
                detail = " [not a canvas slot]"
            end
        end

        local count = nil
        pcall(function() count = widget:GetChildrenCount() end)
        log(string.format("PROBE | %s%s%s children=%s",
            string.rep("  ", depth), shortName(widget), detail,
            tostring(count)))

        if type(count) ~= "number" then return end
        for index = 0, count - 1 do
            local child = nil
            pcall(function() child = widget:GetChildAt(index) end)
            walk(child, depth + 1)
        end
    end

    walk(root, 0)
end

local function probe()
    local cockpit = resolveCockpit()
    if cockpit == nil then
        log("PROBE | no cockpit is mounted")
        return
    end
    log("PROBE | cockpit " .. objectName(cockpit))

    local unitGauge = cockpit.UnitGauge
    if isValid(unitGauge) then
        probeTree(unitGauge, "cockpit.UnitGauge")
    else
        log("PROBE | cockpit.UnitGauge is unavailable")
    end

    for _, definition in ipairs(BARS) do
        local unit = cockpit[definition.unit]
        if isValid(unit) then
            local root = nil
            pcall(function() root = unit.WidgetTree.RootWidget end)
            if isValid(root) then
                probeTree(root, definition.unit .. " widget tree")
            else
                log("PROBE | " .. definition.unit .. " has no widget tree root")
            end
        else
            log("PROBE | " .. definition.unit .. " is unavailable")
        end
    end
    log("PROBE | done")
end

-- The console output device is only valid for the duration of this synchronous
-- call; using it from a deferred callback is a use-after-free. Reply first,
-- then defer the walk without capturing it.
RegisterConsoleCommandHandler("gaugenumbers", function(_, parameters)
    local action = type(parameters) == "table" and parameters[1] or nil
    if action ~= "probe" then
        log("usage: gaugenumbers probe")
        return true
    end
    log("PROBE | walking the cockpit gauge tree, see UE4SS.log")
    ExecuteInGameThread(function()
        local ok, probeError = xpcall(probe, debug.traceback)
        if not ok then log("PROBE ERROR | " .. tostring(probeError)) end
    end)
    return true
end)

--========================================================--
--                         HOOKS                          --
--========================================================--

local hookCallbacks = {}
local function requireHook(path, callback)
    if type(callback) ~= "function" then
        error("[" .. MOD_NAME .. "] HOOK ERROR | " .. path ..
            " | callback is not a function")
    end
    if hookCallbacks[path] ~= nil then
        error("[" .. MOD_NAME .. "] HOOK ERROR | duplicate path: " .. path)
    end
    -- Keep the exact callback object alive in this Lua state as well as in
    -- UE4SS's registry. This makes the registration auditable and prevents a
    -- hot-reload/GC cycle from leaving a stale callback ref behind.
    hookCallbacks[path] = callback
    local ok, hookError = pcall(function() RegisterHook(path, callback) end)
    if not ok then
        error("[" .. MOD_NAME .. "] HOOK ERROR | " .. path .. " | " ..
            tostring(hookError))
    end
end

-- Runs SYNCHRONOUSLY inside the cockpit's own event, on the game thread.
-- currentParameter and maximumParameter point into the native call frame: they
-- are alive for this call and dead the instant it returns, so they are read
-- here and never captured. Nothing is resolved or constructed on this path
-- either -- injection belongs to the poll, so an event arriving mid-teardown
-- can never reach into a half-built cockpit.
local function changeHook(key)
    local definition = BAR_BY_KEY[key]
    return function(_, currentParameter, maximumParameter)
        if CONFIG == nil or not CONFIG.ENABLED
            or not CONFIG[definition.setting] then
            return
        end
        local entry = state.labels[key]
        if entry == nil then return end

        local ok, hookError = xpcall(function()
            stampLabel(entry, currentParameter:get(), maximumParameter:get())
        end, debug.traceback)
        if not ok then
            reportOnce("HOOK-" .. key, "HOOK ERROR | " .. tostring(hookError))
        end
    end
end

requireHook("/Script/ROD.RODCockpitWidgetBase:OnHealthChangedEvent",
    changeHook("HP"))
requireHook("/Script/ROD.RODCockpitWidgetBase:OnStaminaChangedEvent",
    changeHook("STAMINA"))
requireHook("/Script/ROD.RODCockpitWidgetBase:OnSoulChangedEvent",
    changeHook("SP"))

-- World arrival. Nothing is torn down here on purpose: the cockpit's own
-- validity drives that. This only lets a failure that was silenced in the last
-- world be reported again in this one.
requireHook("/Script/Engine.PlayerController:ClientRestart", function()
    lastReport = {}
    if not state.previewRequested
        and (state.previewApplied or state.previewMounted) then
        restorePreviewVisibility(isValid(state.cockpit))
    end
end)

--========================================================--
--                        STARTUP                         --
--========================================================--

do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 150,
        load = readSettings,
        apply = function()
            -- Geometry, styling and which widgets exist are all baked in at
            -- injection time, so a settings change has to rebuild them to be
            -- seen. This runs on the game thread with the world live, which is
            -- the only context where detaching them is safe.
            local reason = (CONFIG ~= nil and CONFIG.ENABLED)
                and "settings reloaded" or "settings disabled"
            releaseWidgets(isValid(state.cockpit), reason)
            if CONFIG ~= nil and CONFIG.ENABLED then
                local reconciled, reconcileError = xpcall(tick, debug.traceback)
                if not reconciled then
                    reportOnce("TICK", "TICK ERROR | " .. tostring(reconcileError))
                end
            end
        end,
        fail = function(reason)
            if CONFIG ~= nil then CONFIG.ENABLED = false end
            releaseWidgets(isValid(state.cockpit), "settings rejected")
            log("CONFIG ERROR | " .. tostring(reason) .. " | readouts disabled")
        end,
        log = log,
    })
    if attachment == nil then
        error("ModMenuBridge attach failed: " .. tostring(attachmentError))
    end
end

startPreviewLoop()
startTickLoop()

log("READY | gauge readouts follow the cockpit's own change events")
