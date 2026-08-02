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

-- Preview failures are held fail-closed until the marker closes or settings are
-- reapplied; a failed preview must never keep constructing UI objects.
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
    HP_X           = { min = 0.0, max = 10000.0 },
    HP_Y           = { min = 0.0, max = 10000.0 },
    STAMINA_X      = { min = 0.0, max = 10000.0 },
    STAMINA_Y      = { min = 0.0, max = 10000.0 },
    SP_X           = { min = 0.0, max = 10000.0 },
    SP_Y           = { min = 0.0, max = 10000.0 },
    TEXT_OFFSET_X  = { min = -400.0, max = 400.0 },
    TEXT_OFFSET_Y  = { min = -400.0, max = 400.0 },
    FONT_SIZE      = { min = 6.0, max = 48.0 },
    EXP_OFFSET_X   = { min = -400.0, max = 400.0 },
    EXP_OFFSET_Y   = { min = -400.0, max = 400.0 },
    EXP_BAR_WIDTH  = { min = 0.0, max = 10000.0 },
    EXP_BAR_HEIGHT = { min = 0.0, max = 10000.0 },
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

-- ModMenu publishes this as an explicit transient marker only while
-- GaugeNumbers is expanded. It is deliberately separate from runtime.lua:
-- preview state must never become a saved player setting. ModMenu clears the
-- marker on startup and on panel close, so editing does not depend on a timer
-- or on repeated parent changes.
local PREVIEW_PATH = SCRIPT_DIR .. "preview.lua"
local PREVIEW_POLL_MS = 250
local previewFingerprint = nil
local previewActive = false
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
local CANVAS_PANEL_CLASS = "/Script/UMG.CanvasPanel"
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
    previewCockpit = nil,
    previewMenuSize = nil,
    previewMenuCanvas = nil,
    previewRoot = nil,
    previewRootSlot = nil,
    previewUnits = nil,
    previewClone = nil,
    previewCloneSlot = nil,
    previewLabels = nil,
    previewMounted = false,
    previewFailed = false,
    previewSweepCanvas = nil,
}

-- Assigned below the widget-lifecycle helpers so releaseWidgets can discard
-- preview copies without reaching into a stale world during teardown.
local restorePreviewVisibility
local restorePreviewMount
local capturePreviewMount
local mountPreviewUnitGauge
local capturePreviewVisibility
local applyPreviewVisibility
local readHeroValues
local createNativeGaugeForPreview
local resolveHero
local mountPreviewReadouts

-- `StaticConstructObject(..., Template=UnitGauge)` only copied the CanvasPanel
-- properties. Its children still belonged to the live HUD, so it was correctly
-- rejected as a shallow alias. A WBP_Cockpit instance is also invalid here: its
-- Construct path owns live cockpit state. The preview therefore creates only
-- the three independent gauge assemblies and never invokes a cockpit method.
local PREVIEW_CLONE_PREFIX = "GaugeNumbers_PreviewUnitGauge_"
local previewCloneSerial = 0

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

-- Read the live UMG design space. Preview slots use these units directly, so
-- the bars track the game's DPI/layout scale instead of a physical monitor
-- resolution.
local function readViewportDesignSize()
    local layout = nil
    local controller = nil
    local width = nil
    local height = nil
    local scale = nil
    local read = pcall(function()
        layout = StaticFindObject(LAYOUT_LIBRARY)
        if not isValid(layout) then error("WidgetLayoutLibrary is unavailable") end
        controller = FindFirstOf("RODInGamePlayerController")
        if not isValid(controller) then
            error("RODInGamePlayerController is unavailable")
        end
        local viewport = layout:GetViewportSize(controller)
        width = tonumber(viewport.X)
        height = tonumber(viewport.Y)
        scale = tonumber(layout:GetViewportScale(controller))
    end)
    if not read or not finiteNumber(width) or not finiteNumber(height)
        or not finiteNumber(scale) or width <= 0.0 or height <= 0.0
        or scale <= 0.0 then
        return nil
    end
    return {
        width = width / scale,
        height = height / scale,
        note = string.format("viewport %.0fx%.0f @ dpi %.3f",
            width, height, scale),
    }
end

local function discardPreviewWidgetState()
    state.previewRoot = nil
    state.previewRootSlot = nil
    state.previewUnits = nil
    state.previewClone = nil
    state.previewCloneSlot = nil
    state.previewLabels = nil
    state.previewMounted = false
end

local function destroyPreviewWidgets()
    local root = state.previewRoot
    if isValid(root) then
        pcall(function() root:RemoveFromParent() end)
    else
        local clone = state.previewClone
        if isValid(clone) then
            pcall(function() clone:RemoveFromParent() end)
        end
    end
    discardPreviewWidgetState()
end

local function sweepOrphanedPreviewClones(canvas)
    if state.previewSweepCanvas == canvas then return true, nil end
    if not isValid(canvas) then
        return false, "menu preview canvas is unavailable for clone cleanup"
    end

    local count = nil
    local counted = pcall(function() count = tonumber(canvas:GetChildrenCount()) end)
    if not counted or not finiteNumber(count) then
        return false, "could not enumerate the menu preview canvas"
    end

    local orphaned = {}
    for index = 0, count - 1 do
        local child = nil
        local name = nil
        local read = pcall(function()
            child = canvas:GetChildAt(index)
            name = child:GetFullName()
        end)
        if not read or not isValid(child) or type(name) ~= "string" then
            return false, "could not inspect menu preview child " .. tostring(index)
        end
        if string.find(name, PREVIEW_CLONE_PREFIX, 1, true) ~= nil then
            orphaned[#orphaned + 1] = child
        end
    end
    for _, child in ipairs(orphaned) do
        local removed = pcall(function() child:RemoveFromParent() end)
        if not removed then
            return false, "could not remove an orphaned UnitGauge clone"
        end
    end
    state.previewSweepCanvas = canvas
    if #orphaned > 0 then
        log("PREVIEW | removed " .. tostring(#orphaned) ..
            " orphaned UnitGauge clone(s)")
    end
    return true, nil
end

capturePreviewMount = function(cockpit)
    local menuCanvas = resolvePreviewCanvas()
    if menuCanvas == nil then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | live menu SubMenu canvas is unavailable")
        return false
    end

    local viewportSize = readViewportDesignSize()
    if viewportSize == nil then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | viewport design geometry is unavailable")
        return false
    end

    destroyPreviewWidgets()
    local swept, sweepError = sweepOrphanedPreviewClones(menuCanvas)
    if not swept then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | UnitGauge clone cleanup failed: " ..
            tostring(sweepError))
        return false
    end
    state.previewCockpit = cockpit
    state.previewMenuCanvas = menuCanvas
    state.previewMenuSize = viewportSize
    state.previewFailed = false
    clearReport("PREVIEW-MOUNT")
    return true
end

local function placePreviewWidget(canvas, widget, geometry, zOrder)
    local slot = nil
    local ok = pcall(function()
        slot = canvas:AddChildToCanvas(widget)
        slot:SetAutoSize(false)
        slot:SetMinimum({ X = 0.0, Y = 0.0 })
        slot:SetMaximum({ X = 0.0, Y = 0.0 })
        slot:SetAlignment({ X = 0.0, Y = 0.0 })
        slot:SetPosition({ X = geometry.x, Y = geometry.y })
        slot:SetSize({ X = geometry.width, Y = geometry.height })
        slot:SetZOrder(zOrder)
        widget:SetVisibility(HIT_TEST_INVISIBLE)
        widget:SetRenderOpacity(1.0)
    end)
    if not ok or not isValid(slot) then return nil end
    return slot
end

local function requireDistinctPreviewObject(live, copied, label)
    if not isValid(live) then
        return false, "live " .. label .. " is unavailable"
    end
    if not isValid(copied) then
        return false, "preview " .. label .. " is unavailable"
    end
    if live == copied then
        return false, "preview " .. label .. " aliases the live widget"
    end

    local liveName = nil
    local copiedName = nil
    local named = pcall(function()
        liveName = live:GetFullName()
        copiedName = copied:GetFullName()
    end)
    if not named or type(liveName) ~= "string" or type(copiedName) ~= "string" then
        return false, "could not identify preview " .. label
    end
    if liveName == copiedName then
        return false, "preview " .. label .. " has the live widget identity"
    end
    return true, nil
end

local function requirePreviewValues(values, key)
    local pair = type(values) == "table" and values[key] or nil
    if type(pair) ~= "table" or not finiteNumber(pair[1])
        or not finiteNumber(pair[2]) then
        return nil, "live " .. key .. " values are unavailable"
    end
    return pair, nil
end

local function readPreviewGaugeValues(liveCockpit)
    local hero = resolveHero(liveCockpit)
    if not isValid(hero) then
        return nil, "live hero is unavailable for the preview"
    end
    local values = readHeroValues(hero)
    local hp, hpError = requirePreviewValues(values, "HP")
    if hp == nil then return nil, hpError end
    local stamina, staminaError = requirePreviewValues(values, "STAMINA")
    if stamina == nil then return nil, staminaError end
    local sp, spError = requirePreviewValues(values, "SP")
    if sp == nil then return nil, spError end
    return values, nil
end

local function createPreviewRoot(outer)
    local class = nil
    local classRead = pcall(function()
        class = StaticFindObject(CANVAS_PANEL_CLASS)
    end)
    if not classRead or not isValid(class) then
        return nil, "CanvasPanel class is unavailable"
    end

    previewCloneSerial = previewCloneSerial + 1
    local root = nil
    local constructed, constructError = pcall(function()
        root = StaticConstructObject(class, outer,
            FName(PREVIEW_CLONE_PREFIX .. tostring(previewCloneSerial)))
    end)
    if not constructed then return nil, tostring(constructError) end
    if not isValid(root) then
        return nil, "CanvasPanel construction returned no preview root"
    end
    return root, nil
end

local function readPreviewAssemblyLayout(sourceRoot, sourceUnit, key)
    if not isValid(sourceRoot) or not isValid(sourceUnit) then
        return nil, "live " .. key .. " gauge assembly is unavailable"
    end

    local slot = nil
    local parent = nil
    local layout = nil
    local autoSize = nil
    local zOrder = nil
    local parentName = nil
    local read = pcall(function()
        slot = sourceUnit.Slot
        parent = slot.Parent
        layout = slot:GetLayout()
        autoSize = slot:GetAutoSize()
        zOrder = slot:GetZOrder()
    end)
    if not read or not isValid(slot) or not isValid(parent)
        or layout == nil or type(autoSize) ~= "boolean"
        or not finiteNumber(tonumber(zOrder)) then
        return nil, "live " .. key .. " gauge layout is unavailable"
    end
    pcall(function() parentName = parent:GetFullName() end)
    -- The generated gauge assemblies are not guaranteed to be direct children
    -- of UnitGauge. Their own CanvasPanelSlot is the authoritative geometry;
    -- copying that slot into the full-screen preview wrapper preserves the
    -- original assembly position without reparenting the live widget.
    return {
        layout = layout,
        autoSize = autoSize,
        zOrder = tonumber(zOrder),
        parentName = tostring(parentName),
    }, nil
end

local function createPreviewAssembly(widgets, owningPlayer, sourceUnit, outer,
    definition)
    local class = nil
    local classRead = pcall(function() class = sourceUnit:GetClass() end)
    if not classRead or not isValid(class) then
        return nil, "live " .. definition.key .. " gauge class is unavailable"
    end

    local clone = nil
    local created, createError = pcall(function()
        clone = widgets:Create(outer, class, owningPlayer)
    end)
    if not created then return nil, tostring(createError) end

    local distinct, distinctError = requireDistinctPreviewObject(
        sourceUnit, clone, definition.key .. " gauge assembly")
    if not distinct then return nil, distinctError end

    local canvas = nil
    local gauge = nil
    local treeRead = pcall(function()
        canvas = clone[definition.canvas]
        gauge = clone[definition.gauge]
    end)
    if not treeRead or not isValid(canvas) or not isValid(gauge) then
        return nil, "preview " .. definition.key .. " gauge tree is incomplete"
    end
    return clone, nil
end

local function mountPreviewAssembly(root, clone, layout, definition)
    local slot = nil
    local mounted, mountError = pcall(function()
        slot = root:AddChildToCanvas(clone)
        slot:SetLayout(layout.layout)
        slot:SetAutoSize(layout.autoSize)
        slot:SetZOrder(layout.zOrder)
        clone:SetVisibility(HIT_TEST_INVISIBLE)
        clone:SetRenderOpacity(1.0)
        local canvas = clone[definition.canvas]
        local gauge = clone[definition.gauge]
        canvas:SetVisibility(VISIBLE)
        canvas:SetRenderOpacity(1.0)
        gauge:SetVisibility(VISIBLE)
        gauge:SetRenderOpacity(1.0)
    end)
    if not mounted or not isValid(slot) then
        return false, tostring(mountError)
    end
    return true, nil
end

local function setPreviewAssemblyValues(units, values)
    for _, definition in ipairs(BARS) do
        local pair, pairError = requirePreviewValues(values, definition.key)
        if pair == nil then return false, pairError end
        local unit = units[definition.key]
        local gauge = isValid(unit) and unit[definition.gauge] or nil
        if not isValid(gauge) then
            return false, "preview " .. definition.key .. " gauge is unavailable"
        end
        local set, setError = pcall(function()
            gauge:ResetGaugeValue(round(pair[1]), round(pair[2]), 0)
        end)
        if not set then return false, tostring(setError) end
    end
    return true, nil
end

local function createPreviewAssemblies(liveCockpit, root, values)
    local sourceRoot = nil
    local widgets = nil
    local owningPlayer = nil
    local resolved = pcall(function()
        sourceRoot = liveCockpit.UnitGauge
        widgets = StaticFindObject(WIDGET_LIBRARY)
        owningPlayer = liveCockpit:GetOwningPlayer()
    end)
    if not resolved or not isValid(sourceRoot) then
        return nil, "live UnitGauge is unavailable"
    end
    if not isValid(widgets) then
        return nil, "WidgetBlueprintLibrary is unavailable"
    end
    if not isValid(owningPlayer) then
        return nil, "live cockpit owning player is unavailable"
    end

    local layouts = {}
    local sources = {}
    for _, definition in ipairs(BARS) do
        local sourceUnit = nil
        local sourceRead = pcall(function()
            sourceUnit = liveCockpit[definition.unit]
        end)
        if not sourceRead or not isValid(sourceUnit) then
            return nil, "live " .. definition.key .. " gauge assembly is unavailable"
        end
        local layout, layoutError =
            readPreviewAssemblyLayout(sourceRoot, sourceUnit, definition.key)
        if layout == nil then return nil, layoutError end
        log("PREVIEW | " .. definition.key .. " source slot parent=" ..
            tostring(layout.parentName))
        sources[definition.key] = sourceUnit
        layouts[definition.key] = layout
    end

    local units = {}
    for _, definition in ipairs(BARS) do
        local clone, cloneError = createPreviewAssembly(widgets, owningPlayer,
            sources[definition.key], root, definition)
        if clone == nil then return nil, cloneError end
        local mounted, mountError = mountPreviewAssembly(root, clone,
            layouts[definition.key], definition)
        if not mounted then return nil, mountError end
        units[definition.key] = clone
    end

    local copied, copyError = setPreviewAssemblyValues(units, values)
    if not copied then return nil, copyError end
    return units, nil
end

mountPreviewUnitGauge = function()
    if state.previewMounted then return true end

    local cockpit = state.previewCockpit
    local menuCanvas = state.previewMenuCanvas
    if not isValid(cockpit) or not isValid(menuCanvas) then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview cockpit or menu canvas became invalid")
        return false
    end
    local values, valueError = readPreviewGaugeValues(cockpit)
    if values == nil then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview gauge values are unavailable: " ..
            tostring(valueError))
        return false
    end

    local viewport = state.previewMenuSize
    if type(viewport) ~= "table" or not finiteNumber(viewport.width)
        or not finiteNumber(viewport.height) then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview viewport geometry is unavailable")
        return false
    end

    local root, rootError = createPreviewRoot(menuCanvas)
    if root == nil then
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview wrapper creation failed: " ..
            tostring(rootError))
        return false
    end
    local rootSlot = placePreviewWidget(menuCanvas, root, {
        x = 0.0,
        y = 0.0,
        width = viewport.width,
        height = viewport.height,
    }, 1000)
    if rootSlot == nil then
        pcall(function() root:RemoveFromParent() end)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | menu rejected the preview wrapper")
        return false
    end

    local units, assemblyError = createPreviewAssemblies(cockpit, root, values)
    if units == nil then
        pcall(function() root:RemoveFromParent() end)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | independent gauge assembly clone failed: " ..
            tostring(assemblyError))
        return false
    end

    if type(mountPreviewReadouts) ~= "function" then
        pcall(function() root:RemoveFromParent() end)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview readout builder is unavailable")
        return false
    end
    local previewLabels, readoutError =
        mountPreviewReadouts(cockpit, root, units, values)
    if previewLabels == nil then
        pcall(function() root:RemoveFromParent() end)
        reportOnce("PREVIEW-MOUNT",
            "PREVIEW ERROR | preview readout clone failed: " ..
            tostring(readoutError))
        return false
    end

    state.previewRoot = root
    state.previewRootSlot = rootSlot
    state.previewUnits = units
    state.previewClone = nil
    state.previewCloneSlot = nil
    state.previewLabels = previewLabels
    state.previewMounted = true
    log(string.format(
        "PREVIEW | independent gauge assemblies mounted | viewport=%.0fx%.0f",
        viewport.width, viewport.height))
    clearReport("PREVIEW-MOUNT")
    return true
end

restorePreviewMount = function(restore)
    if restore then
        destroyPreviewWidgets()
    else
        -- World teardown can invalidate a UMG wrapper before the Lua loop sees
        -- the boundary. Drop ownership without dereferencing that old tree.
        discardPreviewWidgetState()
        state.previewSweepCanvas = nil
    end
    return true
end

capturePreviewVisibility = function(cockpit)
    state.previewCockpit = cockpit
    if not capturePreviewMount(cockpit) then
        state.previewCockpit = nil
        return false
    end
    state.previewApplied = true
    return true
end

restorePreviewVisibility = function(restore, resetFailure)
    local hadPreview = state.previewMounted or isValid(state.previewClone)
    restorePreviewMount(restore)
    state.previewApplied = false
    state.previewCockpit = nil
    state.previewMenuSize = nil
    state.previewMenuCanvas = nil
    if resetFailure ~= false then state.previewFailed = false end
    clearReport("PREVIEW-APPLIED")
    if hadPreview then
        reportOnce("PREVIEW-RESTORED",
            "PREVIEW | UnitGauge clone removed; live cockpit tree untouched")
    end
    return true
end

applyPreviewVisibility = function(cockpit)
    if state.previewApplied and state.previewCockpit ~= cockpit then
        restorePreviewVisibility(true)
    end
    if state.previewFailed then return false end
    if not state.previewApplied
        and not capturePreviewVisibility(cockpit) then
        state.previewFailed = true
        return false
    end

    local called, mounted =
        xpcall(mountPreviewUnitGauge, debug.traceback)
    if not called then
        reportOnce("PREVIEW-CLONE",
            "PREVIEW ERROR | independent UnitGauge mount crashed: " ..
            tostring(mounted))
        restorePreviewVisibility(true, false)
        state.previewFailed = true
        return false
    end
    if not mounted then
        restorePreviewVisibility(true, false)
        reportOnce("PREVIEW-CLONE",
            "PREVIEW ERROR | independent gauge assembly mount failed closed")
        state.previewFailed = true
        return false
    end
    clearReport("PREVIEW-CLONE")
    reportOnce("PREVIEW-APPLIED", string.format(
        "PREVIEW | applied from independent gauge assemblies; live HUD untouched"))
    return true
end

local function readPreviewMarker()
    local contents, readError = MOD_MENU_BRIDGE.readFile(PREVIEW_PATH)
    if readError ~= nil then
        return false, "preview state read failed: " .. tostring(readError)
    end
    if contents == nil then
        previewFingerprint = nil
        previewActive = false
        previewValidationError = nil
        return false, nil
    end

    if contents ~= previewFingerprint then
        local parsed, parseError = MOD_MENU_BRIDGE.evaluateTable(
            contents, "@" .. PREVIEW_PATH)
        previewFingerprint = contents
        previewActive = false
        previewValidationError = nil
        if parsed == nil then
            previewValidationError = "preview state rejected: " .. tostring(parseError)
            return false, previewValidationError
        end
        for key in pairs(parsed) do
            if key ~= "ACTIVE" then
                previewValidationError =
                    "preview state has unknown key: " .. tostring(key)
                return false, previewValidationError
            end
        end
        if type(parsed.ACTIVE) ~= "boolean" then
            previewValidationError = "preview state ACTIVE must be boolean"
            return false, previewValidationError
        end
        previewActive = parsed.ACTIVE
    end

    return previewActive, previewValidationError
end

-- destroy is only ever true on the settings path, where the world is live and
-- the cockpit has just been confirmed valid. Reaching into these widgets after
-- a level change would be a stale dereference, and a stale dereference is an
-- access violation that pcall cannot catch -- there, references are simply
-- dropped and the dead cockpit takes its children with it.
local function releaseWidgets(destroy, reason)
    -- A settings reload rebuilds the preview copies as well as the readouts.
    -- The original cockpit tree is never touched by that cleanup. Every other
    -- release path removes the copies when the object is still live, or simply
    -- drops their Lua ownership during world teardown.
    if reason == "world restart" then
        -- The old world is already entering teardown. Do not even ask UE for
        -- validity here: a wrapper can still look valid while its native
        -- widget tree has been freed. Dropping the preview state is safe; the
        -- next world will capture a fresh live cockpit.
        if restorePreviewVisibility ~= nil then
            restorePreviewVisibility(false)
        end
    elseif restorePreviewVisibility ~= nil then
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

local function isMountedCockpitCandidate(cockpit)
    if not isValid(cockpit) then return false end
    if string.find(objectName(cockpit), "Default__", 1, true) ~= nil then
        return false
    end

    local unitGauge = nil
    local slot = nil
    local parent = nil
    local owningPlayer = nil
    local read = pcall(function()
        unitGauge = cockpit.UnitGauge
        slot = unitGauge.Slot
        parent = slot.Parent
        owningPlayer = cockpit:GetOwningPlayer()
    end)
    return read and isValid(unitGauge) and isValid(slot)
        and isValid(parent) and isValid(owningPlayer)
end

local function findMountedCockpit()
    -- The UI manager owns the one cockpit currently driving the game. Looking
    -- it up through this chain cannot select a detached preview object of the
    -- same class left in the UObject array by a previous Lua reload.
    local controller = nil
    local manager = nil
    local cockpit = nil
    local read = pcall(function()
        controller = FindFirstOf("RODInGamePlayerController")
        if not isValid(controller) then
            error("RODInGamePlayerController is unavailable")
        end
        manager = controller:GetInGameUIManager()
        if not isValid(manager) then
            error("RODInGameUIManager is unavailable")
        end
        cockpit = manager:GetCockpitWidget()
    end)
    if not read then
        return nil, "RODInGameUIManager cockpit chain is unavailable"
    end
    if not isMountedCockpitCandidate(cockpit) then
        return nil, "RODInGameUIManager did not return a mounted cockpit"
    end
    return cockpit, nil
end

-- The cockpit's own lifetime is the mod's lifecycle. Nothing else resets the
-- widget state: as long as this object is valid the widgets inside it are valid
-- too, and when the world tears it down IsValid stops answering and the
-- references are dropped here. That is also what keeps a second ClientRestart
-- inside one world from stacking a duplicate set of widgets.
local function resolveCockpit()
    if isValid(state.cockpit) then return state.cockpit end
    if state.cockpit ~= nil then releaseWidgets(false, "cockpit went invalid") end

    local found, findError = findMountedCockpit()
    if found == nil then
        reportOnce("COCKPIT",
            "COCKPIT ERROR | canonical mounted WBP_Cockpit_C is unavailable: " ..
            tostring(findError))
        return nil
    end

    state.cockpit = found
    clearReport("COCKPIT")
    dbg("cockpit resolved | " .. objectName(found))
    return found
end

resolveHero = function(cockpit)
    local hero = weakObject(cockpit.HeroCharacterRef)
    if not isValid(hero) then
        reportOnce("HERO",
            "HERO ERROR | canonical cockpit HeroCharacterRef is unavailable")
        return nil
    end
    clearReport("HERO")
    return hero
end

local function resolvePlayerState(cockpit)
    local playerState = weakObject(cockpit.PlayerStateRef)
    if not isValid(playerState) then
        reportOnce("PLAYER-STATE",
            "PLAYER STATE ERROR | canonical cockpit PlayerStateRef is unavailable")
        return nil
    end
    clearReport("PLAYER-STATE")
    return playerState
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

-- Gauge widgets are not CanvasPanel children on this build. Their slot therefore
-- cannot provide a size, and their cached geometry becomes zero when the game's
-- menu collapses the cockpit. The widget's desired size remains the authoritative
-- design-space size in that state.
local function measureWidgetDesiredSize(widget)
    if not isValid(widget) then return nil end

    local width = nil
    local height = nil
    local read = pcall(function()
        local size = widget:GetDesiredSize()
        width = tonumber(size.X)
        height = tonumber(size.Y)
    end)
    if not read or not finiteNumber(width) or not finiteNumber(height)
        or width <= 1.0 or height <= 1.0 then
        return nil
    end
    return {
        width = width,
        height = height,
        note = string.format("desired w=%.0f h=%.0f", width, height),
    }
end

local function measureGaugeSize(widget)
    return measureWidgetDesiredSize(widget)
end

-- Drawing ON a bar means out-ranking everything already in that canvas, and a
-- fixed ZOrder is a guess about a layout the mod does not own.
--
-- The floor matters as much as the survey: SlotAsCanvasSlot returns nothing
-- for a child whose parent is not a CanvasPanel. A survey that reads no slot at
-- all reports 0 and would put the readout on layer 10 -- under anything the
-- HUD placed higher.
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
    return { canvas = canvas, size = measureGaugeSize(unit[definition.gauge]) }
end

-- WHERE a readout draws. A readout centred ON its bar has to be painted AFTER
-- the gauge art and no ZOrder can achieve that from a canvas painted first.
-- The selected layer is a strict contract: if that exact canvas cannot accept
-- the widget, injection reports an error instead of silently changing layers.
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
            -- in the canvas's own UI layout units, which the HUD's own layout
            -- is authored in rather than in physical monitor pixels.
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
    elseif CONFIG.READOUT_LAYER == "gauge" then
        local assembly = unit[definition.canvas]
        if isValid(assembly) then
            candidates[#candidates + 1] = {
                canvas = assembly,
                layer = "gauge",
                chain = chain,
                rectangle = measure(gauge),
            }
        end
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
    if not built then return nil, tostring(buildError) end
    if not isValid(widget) then
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
    -- The partner name plate is the text block mounted in the cockpit and
    -- styled for it. A missing donor is reported by the caller rather than
    -- silently changing typography.
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
    if donor == nil then error("partner nameplate font donor is unavailable") end
    pcall(function() label:SetFont(donor.Font) end)
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

local function ensureLabel(cockpit, definition, surfaces, entries, fontCockpit)
    if type(entries) ~= "table" then
        return nil, "readout storage is unavailable"
    end
    if not isValid(fontCockpit) then
        return nil, "readout font cockpit is unavailable"
    end

    local entry = entries[definition.key]
    if entry ~= nil and isValid(entry.widget) then return entry end
    entries[definition.key] = nil

    local candidates = surfaces.bars[definition.key]
    if candidates == nil or #candidates == 0 then
        return nil, definition.key .. " gauge assembly is unavailable"
    end

    for _, candidate in ipairs(candidates) do
        local label, buildError = constructWidget(TEXT_BLOCK_CLASS,
            candidate.canvas)
        if label == nil then return nil, buildError end
        styleLabel(label, fontCockpit)

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
            entries[definition.key] = entry
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

-- Preview labels are rebuilt into the independent assembly tree. The live
-- cockpit supplies only the font donor; it is never a parent, source of a
-- visibility change, or event target.
local function previewReadoutCandidates(previewRoot, previewUnits, definition)
    local unit = previewUnits[definition.key]
    if not isValid(unit) then return {} end

    local canvas = unit[definition.canvas]
    local gauge = unit[definition.gauge]
    local chain = { unit, canvas, gauge }
    stopCaching(unit, "InvalidationBox_root")

    if CONFIG.READOUT_LAYER == "inside" and isValid(gauge) then
        local root = nil
        pcall(function() root = gauge.WidgetTree.RootWidget end)
        if isValid(root) then
            return { { canvas = root, layer = "inside", chain = chain,
                normalised = true } }
        end
        return {}
    end
    if CONFIG.READOUT_LAYER == "front" then
        if not isValid(previewRoot) then return {} end
        return { {
            canvas = previewRoot,
            layer = "front",
            chain = chain,
            point = {
                x = CONFIG[definition.posX],
                y = CONFIG[definition.posY],
            },
        } }
    end
    if CONFIG.READOUT_LAYER == "gauge" and isValid(canvas) then
        return { {
            canvas = canvas,
            layer = "gauge",
            chain = chain,
            rectangle = measure(gauge),
        } }
    end
    return {}
end

mountPreviewReadouts = function(liveCockpit, previewRoot, previewUnits, values)
    if not isValid(liveCockpit) or not isValid(previewRoot)
        or type(previewUnits) ~= "table" then
        return nil, "live cockpit or independent preview tree is unavailable"
    end
    if type(CONFIG) ~= "table" then
        return nil, "GaugeNumbers configuration is unavailable"
    end

    local labels = {}
    local surfaces = { bars = {}, rightMost = nil }
    for _, definition in ipairs(BARS) do
        if CONFIG[definition.setting] then
            local candidates = previewReadoutCandidates(previewRoot,
                previewUnits, definition)
            if #candidates == 0 then
                return nil, "preview " .. definition.key ..
                    " gauge has no " .. tostring(CONFIG.READOUT_LAYER) ..
                    " readout canvas"
            end
            surfaces.bars[definition.key] = candidates
            for _, candidate in ipairs(candidates) do
                local rectangle = candidate.rectangle
                if rectangle ~= nil and candidate.layer == "front" then
                    local right = rectangle.x + rectangle.width
                    if surfaces.rightMost == nil or right > surfaces.rightMost then
                        surfaces.rightMost = right
                    end
                end
            end
        end
    end

    for _, definition in ipairs(BARS) do
        if CONFIG[definition.setting] then
            local built, entry, buildError = pcall(ensureLabel,
                liveCockpit, definition, surfaces, labels, liveCockpit)
            if not built then return nil, tostring(entry) end
            if entry == nil then return nil, tostring(buildError) end

            local pair, pairError = requirePreviewValues(values, definition.key)
            if pair == nil then return nil, pairError end
            stampLabel(entry, pair[1], pair[2])
        end
    end
    return labels, nil
end

--========================================================--
--                    EXPERIENCE BAR                      --
--========================================================--

-- A real instance of the game's own gauge widget, from the class of a gauge
-- already mounted in this cockpit -- so no LoadAsset, and no asset path that
-- could stop resolving after a patch.
createNativeGaugeForPreview = function(cockpit, donor, outer)
    if not isValid(donor) then return nil, "native gauge donor is unavailable" end
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
    return widget, nil
end

local function cloneNativeGauge(cockpit, outer)
    local donorUnit = cockpit[NATIVE_DONOR.unit]
    if not isValid(donorUnit) then
        return nil, "native gauge donor assembly is unavailable"
    end
    local donor = donorUnit[NATIVE_DONOR.gauge]
    if not isValid(donor) then
        return nil, "native gauge donor is unavailable"
    end

    local widget, createError =
        createNativeGaugeForPreview(cockpit, donor, outer)
    if widget == nil then return nil, createError end
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

    local width = nil
    if CONFIG.EXP_BAR_WIDTH > 0.0 then
        width = CONFIG.EXP_BAR_WIDTH
    elseif surface.size ~= nil then
        width = surface.size.width
    end
    local height = nil
    if CONFIG.EXP_BAR_HEIGHT > 0.0 then
        height = CONFIG.EXP_BAR_HEIGHT
    elseif surface.size ~= nil then
        height = surface.size.height
    end
    if not finiteNumber(width) or width <= 1.0
        or not finiteNumber(height) or height <= 1.0 then
        return nil, "experience anchor gauge geometry is unavailable"
    end

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
        style = "none",
        wantBar = wantBar,
        wantText = wantText,
        width = width,
        height = height,
    }

    if wantBar then
        if CONFIG.EXP_STYLE == "native" then
            local native, cloneError = cloneNativeGauge(cockpit, canvas)
            if native == nil then
                return unwind("native experience gauge unavailable: " ..
                    tostring(cloneError))
            end
            built[#built + 1] = native
            if place(canvas, native,
                boxPlacement(originX, width), zOrder) == nil then
                return unwind("experience gauge copy was rejected")
            end
            exp.style = "native"
            exp.native = native
        elseif CONFIG.EXP_STYLE == "flat" then
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
        (surface.size ~= nil and surface.size.note) or "configured"))
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
    if not ok or level == nil or current == nil then return nil end
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

readHeroValues = function(hero)
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
        state.previewFailed = false
        log("PREVIEW | active marker observed")
    elseif not requested and state.previewRequested then
        log("PREVIEW | marker closed")
    end
    state.previewRequested = requested
    if not state.previewRequested then
        state.previewFailed = false
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
            "PREVIEW ERROR | no live cockpit while the preview marker is active")
        return
    end
    clearReport("PREVIEW-COCKPIT")
    applyPreviewVisibility(cockpit)
end

-- A self-rescheduling ExecuteWithDelay + ExecuteInGameThread pair creates a
-- fresh ProcessEvent callback on every pass. On this UE4SS build one invalid
-- callback can be removed while the menu is being rebuilt. A single persistent
-- game-thread loop owns the marker and its independent preview copies.
local previewLoopHandle = nil
local function previewLoop()
    local ok, previewError = xpcall(function()
        local active, markerError = readPreviewMarker()
        updatePreviewMode(active, markerError)
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
            local entry, injectError = ensureLabel(cockpit, definition, surfaces,
                state.labels, cockpit)
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
    -- ClientRestart is the canonical world boundary. Do not dereference or
    -- remove the old widget tree here: it may already be in teardown. Drop
    -- only Lua ownership and let the next stable tick sweep the old prefixed
    -- widgets from the newly resolved cockpit before rebuilding them.
    releaseWidgets(false, "world restart")
    sweptCockpit = nil
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
