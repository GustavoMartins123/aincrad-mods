local MOD_NAME = "GaugeNumbers"
local MOD_VERSION = "1.1.0"

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
    VALUE_FORMAT = { current_max = true, current = true, percent = true },
    EXP_STYLE    = { native = true, flat = true },
    EXP_ANCHOR   = { hp = true, stamina = true, sp = true },
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

--========================================================--
--                       CONSTANTS                        --
--========================================================--

-- ESlateVisibility. Everything the mod adds is decoration, so it is mounted
-- HitTestInvisible: it can never swallow a click or become a focus target
-- belonging to the HUD underneath.
local HIT_TEST_INVISIBLE = 3

local TEXT_BLOCK_CLASS = "/Script/UMG.TextBlock"
local IMAGE_CLASS = "/Script/UMG.Image"
local LAYOUT_LIBRARY = "/Script/UMG.Default__WidgetLayoutLibrary"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"

local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local EXP_FILL_COLOR = { R = 1.0, G = 0.78, B = 0.28, A = 1.0 }
local EXP_BACK_COLOR = { R = 0.02, G = 0.03, B = 0.05, A = 0.55 }

-- unit    the cockpit member holding the whole bar assembly.
-- canvas  the CanvasPanel inside it that owns the bar's coordinate space.
-- gauge   the gauge widget itself, measured to place things against it.
local BARS = {
    {
        key = "HP",
        anchor = "hp",
        setting = "SHOW_HP",
        unit = "PlayerUnitGauge_HP",
        canvas = "HPGauge",
        gauge = "HP",
    },
    {
        key = "STAMINA",
        anchor = "stamina",
        setting = "SHOW_STAMINA",
        unit = "PlayerUnitGauge_Stamina",
        canvas = "StaminaGauge",
        gauge = "Stamina",
    },
    {
        key = "SP",
        anchor = "sp",
        setting = "SHOW_SP",
        unit = "PlayerUnitGauge_Soul",
        canvas = "SoulGauge",
        gauge = "Soul",
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

-- Used only when no bar could be measured, so the experience bar still lands
-- somewhere sane instead of on top of a gauge. Designer pixels at 1080p.
local FALLBACK_ANCHOR = { x = 35.0, y = 88.0, width = 320.0, height = 12.0 }

--========================================================--
--                        STATE                           --
--========================================================--

local state = {
    cockpit = nil,
    labels = {},        -- [barKey] = { widget, current, maximum }
    exp = nil,
    fontDonor = nil,
}

-- destroy is only ever true on the settings path, where the world is live and
-- the cockpit has just been confirmed valid. Reaching into these widgets after
-- a level change would be a stale dereference, and a stale dereference is an
-- access violation that pcall cannot catch -- there, references are simply
-- dropped and the dead cockpit takes its children with it.
local function releaseWidgets(destroy, reason)
    if destroy then
        local doomed = {}
        for _, entry in pairs(state.labels) do
            doomed[#doomed + 1] = entry.widget
        end
        if state.exp ~= nil then
            doomed[#doomed + 1] = state.exp.native
            doomed[#doomed + 1] = state.exp.back
            doomed[#doomed + 1] = state.exp.fill
            doomed[#doomed + 1] = state.exp.label
        end
        for _, widget in ipairs(doomed) do
            if isValid(widget) then
                pcall(function() widget:RemoveFromParent() end)
            end
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
--                  WIDGET CONSTRUCTION                   --
--========================================================--

local function constructWidget(classPath, outer)
    local class = nil
    local ok = pcall(function() class = StaticFindObject(classPath) end)
    if not ok or not isValid(class) then
        return nil, "widget class is unavailable: " .. classPath
    end
    local widget = nil
    local built, buildError = pcall(function()
        widget = StaticConstructObject(class, outer)
    end)
    if not built then return nil, tostring(buildError) end
    if not isValid(widget) then
        return nil, "construction returned no widget: " .. classPath
    end
    return widget, nil
end

-- A CanvasPanelSlot is the only slot type carrying a position, and
-- SlotAsCanvasSlot is the sanctioned way to ask for one: reading .Slot directly
-- would hand back whatever slot type the parent happens to use.
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
    return geometry
end

-- One measuring pass over all three bars. The readout column and the
-- experience bar are both derived from it, so they agree with each other.
local function measureBars(cockpit)
    local layout = { bars = {}, rightMost = nil }
    for _, definition in ipairs(BARS) do
        local unit = cockpit[definition.unit]
        if isValid(unit) then
            local geometry = measure(unit[definition.gauge])
            if geometry ~= nil then
                layout.bars[definition.key] = geometry
                local right = geometry.x + geometry.width
                if layout.rightMost == nil or right > layout.rightMost then
                    layout.rightMost = right
                end
                dbg(string.format("%s measured | x=%.1f y=%.1f w=%.1f h=%.1f",
                    definition.key, geometry.x, geometry.y,
                    geometry.width, geometry.height))
            else
                dbg(definition.key .. " unmeasured")
            end
        end
    end
    return layout
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
    -- The gauges sit over open world, so the readout needs its own contrast.
    pcall(function() label:SetShadowOffset({ X = 1.0, Y = 1.0 }) end)
    pcall(function()
        label:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
    end)
end

-- Every gauge assembly caches its own drawing. A cached subtree keeps
-- repainting what it was cached with, which would freeze anything the mod adds
-- under it on its first value.
local function stopCaching(unit)
    pcall(function() unit.InvalidationBox_root:SetCanCache(false) end)
end

local function placeLabel(canvas, label, x, y, zOrder)
    local slot = nil
    local ok = pcall(function() slot = canvas:AddChildToCanvas(label) end)
    if not ok or not isValid(slot) then return nil end
    pcall(function()
        slot:SetAutoSize(true)
        slot:SetMinimum({ X = 0.0, Y = 0.0 })
        slot:SetMaximum({ X = 0.0, Y = 0.0 })
        slot:SetAlignment({ X = 0.0, Y = 0.5 })
        slot:SetPosition({ X = x, Y = y })
        slot:SetZOrder(zOrder)
    end)
    pcall(function()
        label:SetVisibility(HIT_TEST_INVISIBLE)
        label:SetRenderOpacity(1.0)
    end)
    return slot
end

--========================================================--
--                     BAR READOUTS                       --
--========================================================--

local function ensureLabel(cockpit, definition, layout)
    local entry = state.labels[definition.key]
    if entry ~= nil and isValid(entry.widget) then return entry end
    state.labels[definition.key] = nil

    local unit = cockpit[definition.unit]
    if not isValid(unit) then
        return nil, definition.key .. " gauge assembly is unavailable"
    end
    local canvas = unit[definition.canvas]
    if not isValid(canvas) then
        return nil, definition.key .. " gauge canvas is unavailable"
    end
    stopCaching(unit)

    local label, buildError = constructWidget(TEXT_BLOCK_CLASS, unit)
    if label == nil then return nil, buildError end
    styleLabel(label, cockpit)

    local geometry = layout.bars[definition.key]
    local slot
    if geometry ~= nil then
        -- The three bars are different lengths, so ending each readout at its
        -- own bar produces a staircase. Aligning them means every readout uses
        -- the longest bar's right edge, in its own canvas's coordinates.
        local right = geometry.x + geometry.width
        if CONFIG.ALIGN_READOUTS and layout.rightMost ~= nil then
            right = layout.rightMost
        end
        slot = placeLabel(canvas, label,
            right + CONFIG.TEXT_OFFSET_X,
            geometry.y + geometry.height * 0.5 + CONFIG.TEXT_OFFSET_Y,
            40)
    else
        -- Unmeasured: anchor to the canvas's own right edge instead.
        local ok = pcall(function() slot = canvas:AddChildToCanvas(label) end)
        if ok and isValid(slot) then
            pcall(function()
                slot:SetAutoSize(true)
                slot:SetMinimum({ X = 1.0, Y = 0.5 })
                slot:SetMaximum({ X = 1.0, Y = 0.5 })
                slot:SetAlignment({ X = 0.0, Y = 0.5 })
                slot:SetPosition({
                    X = CONFIG.TEXT_OFFSET_X,
                    Y = CONFIG.TEXT_OFFSET_Y,
                })
                slot:SetZOrder(40)
            end)
            pcall(function()
                label:SetVisibility(HIT_TEST_INVISIBLE)
                label:SetRenderOpacity(1.0)
            end)
        else
            slot = nil
        end
    end
    if not isValid(slot) then
        return nil, definition.key .. " canvas rejected the readout"
    end

    entry = { widget = label, current = nil, maximum = nil }
    state.labels[definition.key] = entry
    log("READOUT | " .. definition.key .. " attached")
    return entry
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

local function placeBox(canvas, widget, x, y, w, h, zOrder)
    local slot = nil
    local ok = pcall(function() slot = canvas:AddChildToCanvas(widget) end)
    if not ok or not isValid(slot) then return nil end
    pcall(function()
        slot:SetAutoSize(false)
        slot:SetMinimum({ X = 0.0, Y = 0.0 })
        slot:SetMaximum({ X = 0.0, Y = 0.0 })
        slot:SetAlignment({ X = 0.0, Y = 0.0 })
        slot:SetPosition({ X = x, Y = y })
        slot:SetSize({ X = w, Y = h })
        slot:SetZOrder(zOrder)
    end)
    pcall(function()
        widget:SetVisibility(HIT_TEST_INVISIBLE)
        widget:SetRenderOpacity(1.0)
    end)
    return slot
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

local function ensureExperience(cockpit, layout)
    if experienceIntact(state.exp) then return state.exp end
    state.exp = nil

    local wantBar = CONFIG.SHOW_EXP_BAR
    local wantText = CONFIG.SHOW_EXP_TEXT
    if not wantBar and not wantText then return nil, nil end

    local definition = BAR_BY_ANCHOR[CONFIG.EXP_ANCHOR]
    local unit = cockpit[definition.unit]
    if not isValid(unit) then
        return nil, "experience anchor assembly is unavailable"
    end
    local canvas = unit[definition.canvas]
    if not isValid(canvas) then
        return nil, "experience anchor canvas is unavailable"
    end
    stopCaching(unit)

    local anchor = layout.bars[definition.key] or FALLBACK_ANCHOR
    if layout.bars[definition.key] == nil then
        dbg("experience anchor unmeasured | using fallback placement")
    end

    local originX = anchor.x + CONFIG.EXP_OFFSET_X
    local originY = anchor.y + CONFIG.EXP_OFFSET_Y
    local width = anchor.width
    if CONFIG.EXP_BAR_WIDTH > 0.0 then width = CONFIG.EXP_BAR_WIDTH end
    local height = anchor.height
    if CONFIG.EXP_BAR_HEIGHT > 0.0 then height = CONFIG.EXP_BAR_HEIGHT end

    local built = {}
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
            local native, cloneError = cloneNativeGauge(cockpit, unit)
            if native ~= nil then
                built[#built + 1] = native
                if placeBox(canvas, native, originX, originY,
                    width, height, 38) == nil then
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
            local back, backError = constructWidget(IMAGE_CLASS, unit)
            if back == nil then return unwind(backError) end
            built[#built + 1] = back
            pcall(function() back:SetColorAndOpacity(EXP_BACK_COLOR) end)
            if placeBox(canvas, back, originX, originY,
                width, height, 38) == nil then
                return unwind("experience bar backing was rejected")
            end

            local fill, fillError = constructWidget(IMAGE_CLASS, unit)
            if fill == nil then return unwind(fillError) end
            built[#built + 1] = fill
            pcall(function() fill:SetColorAndOpacity(EXP_FILL_COLOR) end)
            local fillSlot = placeBox(canvas, fill, originX, originY,
                0.0, height, 39)
            if fillSlot == nil then
                return unwind("experience bar fill was rejected")
            end
            exp.back = back
            exp.fill = fill
            exp.fillSlot = fillSlot
        end
    end

    if wantText then
        local label, labelError = constructWidget(TEXT_BLOCK_CLASS, unit)
        if label == nil then return unwind(labelError) end
        built[#built + 1] = label
        styleLabel(label, cockpit)

        local right = originX + width
        if CONFIG.ALIGN_READOUTS and layout.rightMost ~= nil then
            right = layout.rightMost
        end
        if placeLabel(canvas, label,
            right + CONFIG.TEXT_OFFSET_X,
            originY + height * 0.5, 40) == nil then
            return unwind("experience readout was rejected")
        end
        exp.label = label
    end

    state.exp = exp
    log(string.format("EXPERIENCE | %s bar at %.1f,%.1f (%.0fx%.0f)",
        exp.style, originX, originY, width, height))
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

local function tick()
    if CONFIG == nil or not CONFIG.ENABLED then return end

    local cockpit = resolveCockpit()
    if cockpit == nil then return end

    -- Measuring is only worth its native calls when something has to be built.
    local layout = { bars = {}, rightMost = nil }
    if needsInjection() then layout = measureBars(cockpit) end

    for _, definition in ipairs(BARS) do
        if CONFIG[definition.setting] then
            local tag = "INJECT-" .. definition.key
            local entry, injectError = ensureLabel(cockpit, definition, layout)
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

    if not CONFIG.SHOW_EXP then return end
    local exp, expError = ensureExperience(cockpit, layout)
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

local function poll()
    -- The interval is decided HERE, synchronously. Computing it inside the
    -- deferred callback races the scheduler and pins the cadence.
    local interval = 500
    if CONFIG ~= nil then interval = math.floor(CONFIG.REFRESH_MS) end

    ExecuteInGameThread(function()
        local ok, tickError = xpcall(tick, debug.traceback)
        if not ok then
            reportOnce("TICK", "TICK ERROR | " .. tostring(tickError))
        end
    end)
    ExecuteWithDelay(interval, poll)
end

--========================================================--
--                         HOOKS                          --
--========================================================--

local function requireHook(path, callback)
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
end)

--========================================================--
--                        STARTUP                         --
--========================================================--

do
    local attachment, attachmentError = MOD_MENU_BRIDGE.attach({
        modName = MOD_NAME,
        scriptDir = SCRIPT_DIR,
        pollMs = 750,
        load = readSettings,
        apply = function()
            -- Geometry, styling and which widgets exist are all baked in at
            -- injection time, so a settings change has to rebuild them to be
            -- seen. This runs on the game thread with the world live, which is
            -- the only context where detaching them is safe.
            releaseWidgets(isValid(state.cockpit), "settings reloaded")
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

poll()

log("READY | gauge readouts follow the cockpit's own change events")
