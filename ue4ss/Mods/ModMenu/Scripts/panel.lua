-- ModMenu panel — the settings list shown when the Mods entry is selected.
--
-- There is no ImGui binding in this UE4SS build and no authored settings widget
-- to borrow, so the panel is assembled from engine UMG primitives:
--
--   host    a clone of the game's own main-menu widget class, used purely as a
--           full-screen canvas. Its authored children are collapsed on creation,
--           so nothing of the original menu shows through. Cloning a class that
--           is known to exist and known to be creatable from Lua avoids guessing
--           at a widget path that may not be loaded.
--   rows    two UMG TextBlocks each (label on the left, value on the right).
--   style   copied off a native menu icon's MenuName text rather than built by
--           hand, because FSlateFontInfo cannot be constructed from Lua. The
--           panel therefore inherits the game's own typography for free.
--
-- The layout is deliberately a single flat list with one mod expanded at a time,
-- which caps it at 13 rows and removes any need for scrolling.

local Panel = {}

local VISIBLE = 0
local COLLAPSED = 1

local TEXTBLOCK_CLASS = "/Script/UMG.TextBlock"
local IMAGE_CLASS = "/Script/UMG.Image"

local PANEL_LEFT = 220.0
local PANEL_TOP = 120.0
local PANEL_WIDTH = 900.0
local PANEL_HEIGHT = 560.0
local ROW_HEIGHT = 34.0
local LABEL_X = PANEL_LEFT + 48.0
local VALUE_X = PANEL_LEFT + 620.0
local FIRST_ROW_Y = PANEL_TOP + 96.0
local SETTING_INDENT = 32.0

local SELECTED_COLOR = { R = 1.0, G = 0.85, B = 0.35, A = 1.0 }
local NORMAL_COLOR = { R = 0.88, G = 0.92, B = 1.0, A = 1.0 }
local MUTED_COLOR = { R = 0.55, G = 0.60, B = 0.70, A = 1.0 }
local HEADER_COLOR = { R = 0.65, G = 0.85, B = 1.0, A = 1.0 }

local registry = nil
local store = nil
local log = function() end
local resolveController = function() return nil end
local resolveUmgLibrary = function() return nil end

local host = nil
local canvas = nil
local rowWidgets = {}
local titleWidgets = nil
local styleSource = nil

local expandedMod = nil
local selectionIndex = 1
local rows = {}
local isOpen = false

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

function Panel.init(dependencies)
    registry = dependencies.registry
    store = dependencies.store
    log = dependencies.log or log
    resolveController = dependencies.resolveController or resolveController
    resolveUmgLibrary = dependencies.resolveUmgLibrary or resolveUmgLibrary
    Panel.hostClassPath = dependencies.hostClassPath
    Panel.styleClassPath = dependencies.styleClassPath
end

--========================================================--
--                     ROW MODEL                          --
--========================================================--

-- Rebuilds the flat list of rows from the registry and each mod's current
-- effective settings. Called on open and after every change so the displayed
-- value is always read back from disk rather than assumed.
local function buildRows()
    local built = {}
    for _, entry in ipairs(registry or {}) do
        local effective = store.readEffective(entry.mod)
        local enabledSetting = nil
        for _, setting in ipairs(entry.settings or {}) do
            if setting.key == "ENABLED" then enabledSetting = setting end
        end

        built[#built + 1] = {
            kind = "mod",
            entry = entry,
            effective = effective,
            enabledSetting = enabledSetting,
        }

        if expandedMod == entry.mod then
            for _, setting in ipairs(entry.settings or {}) do
                if setting.key ~= "ENABLED" then
                    built[#built + 1] = {
                        kind = "setting",
                        entry = entry,
                        setting = setting,
                        effective = effective,
                    }
                end
            end
        end
    end
    rows = built
    if selectionIndex > #rows then selectionIndex = #rows end
    if selectionIndex < 1 then selectionIndex = 1 end
end

local function applyMarker(entry)
    if entry.apply == "restart" then return " *" end
    if entry.apply == "menu" then return " +" end
    return ""
end

local function formatNumber(setting, value)
    local pattern = setting.format or "%.2f"
    local ok, text = pcall(string.format, pattern, value)
    if ok then return text end
    return tostring(value)
end

local function describeValue(row)
    if row.kind == "mod" then
        if row.enabledSetting == nil then return "" end
        local value = store.valueOf(row.effective, row.enabledSetting)
        return value and "ON" or "OFF"
    end

    local setting = row.setting
    local value = store.valueOf(row.effective, setting)
    if setting.type == "bool" then
        return value and "ON" or "OFF"
    end
    if setting.type == "number" then
        return "< " .. formatNumber(setting, value) .. " >"
    end
    if setting.type == "choice" then
        for _, option in ipairs(setting.options or {}) do
            if option.value == value then return "< " .. option.label .. " >" end
        end
        return "< " .. tostring(value) .. " >"
    end
    return tostring(value)
end

local function describeLabel(row)
    if row.kind == "mod" then
        local prefix = expandedMod == row.entry.mod and "- " or "+ "
        return prefix .. row.entry.label .. applyMarker(row.entry)
    end
    return row.setting.label
end

--========================================================--
--                     CONSTRUCTION                       --
--========================================================--

local function constructWidget(classPath, outer)
    local class = StaticFindObject(classPath)
    if not isValid(class) then
        log("widget class unavailable: " .. classPath)
        return nil
    end
    local widget = nil
    pcall(function() widget = StaticConstructObject(class, outer) end)
    if isValid(widget) then return widget end
    log("could not construct " .. classPath)
    return nil
end

-- FSlateFontInfo cannot be built from Lua, so the panel borrows a fully
-- configured one from a native menu label instead.
local function resolveStyleSource(controller, umgLibrary)
    if isValid(styleSource) then return styleSource end
    local class = StaticFindObject(Panel.styleClassPath or "")
    if not isValid(class) or not isValid(umgLibrary) then return nil end

    local donor = nil
    pcall(function() donor = umgLibrary:Create(controller, class, controller) end)
    if not isValid(donor) then return nil end

    local label = nil
    pcall(function() label = donor.MenuName end)
    if not isValid(label) then return nil end

    styleSource = label
    return styleSource
end

local function styleText(widget, color)
    if not isValid(widget) then return end
    if isValid(styleSource) then
        pcall(function() widget:SetFont(styleSource.Font) end)
    end
    pcall(function()
        widget:SetColorAndOpacity({
            SpecifiedColor = color,
            ColorUseRule = 0,
        })
    end)
end

local function placeInCanvas(widget, x, y, width)
    if not isValid(canvas) or not isValid(widget) then return false end
    local slot = nil
    pcall(function() slot = canvas:AddChildToCanvas(widget) end)
    if not isValid(slot) then
        log("canvas rejected a panel widget")
        return false
    end
    pcall(function() slot:SetAutoSize(width == nil) end)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    if width ~= nil then
        pcall(function() slot:SetSize({ X = width, Y = ROW_HEIGHT }) end)
    end
    pcall(function() slot:SetZOrder(50) end)
    return true
end

-- The clone is only wanted for its canvas, so everything the class authored is
-- collapsed before the panel's own widgets go in.
local function collapseAuthoredChildren(panelCanvas)
    local count = nil
    pcall(function() count = panelCanvas:GetChildrenCount() end)
    if type(count) ~= "number" then return end
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = panelCanvas:GetChildAt(index) end)
        if isValid(child) then
            pcall(function() child:SetVisibility(COLLAPSED) end)
        end
    end
end

-- Tries the widget's own root first, then falls back to hunting the tree for
-- anything that behaves like a canvas.
local function resolveCanvas(widget)
    local candidates = {}

    local root = nil
    pcall(function() root = widget.WidgetTree.RootWidget end)
    if isValid(root) then candidates[#candidates + 1] = root end

    local named = nil
    pcall(function() named = widget:GetRootWidget() end)
    if isValid(named) then candidates[#candidates + 1] = named end

    for _, candidate in ipairs(candidates) do
        local accepted = false
        pcall(function() accepted = candidate.GetChildrenCount ~= nil end)
        if accepted then
            log("panel canvas resolved: " .. objectName(candidate))
            return candidate
        end
    end

    log("panel canvas could not be resolved; run 'modmenu probe' and share the output")
    return nil
end

local function destroyPanel()
    if isValid(host) then
        pcall(function() host:RemoveFromParent() end)
    end
    host = nil
    canvas = nil
    rowWidgets = {}
    titleWidgets = nil
end

local function buildPanel()
    destroyPanel()

    local controller = resolveController()
    local umgLibrary = resolveUmgLibrary()
    local hostClass = StaticFindObject(Panel.hostClassPath or "")
    if not isValid(controller) or not isValid(umgLibrary) or not isValid(hostClass) then
        log("cannot build panel: UI context is unavailable")
        return false
    end

    pcall(function() host = umgLibrary:Create(controller, hostClass, controller) end)
    if not isValid(host) then
        log("cannot build panel: host widget creation returned null")
        return false
    end

    canvas = resolveCanvas(host)
    if not isValid(canvas) then
        destroyPanel()
        return false
    end
    collapseAuthoredChildren(canvas)

    resolveStyleSource(controller, umgLibrary)

    local background = constructWidget(IMAGE_CLASS, host)
    if isValid(background) then
        pcall(function()
            background:SetColorAndOpacity({ R = 0.02, G = 0.03, B = 0.06, A = 0.88 })
        end)
        if isValid(canvas) then
            local slot = nil
            pcall(function() slot = canvas:AddChildToCanvas(background) end)
            if isValid(slot) then
                pcall(function() slot:SetAutoSize(false) end)
                pcall(function() slot:SetPosition({ X = PANEL_LEFT, Y = PANEL_TOP }) end)
                pcall(function() slot:SetSize({ X = PANEL_WIDTH, Y = PANEL_HEIGHT }) end)
                pcall(function() slot:SetZOrder(40) end)
            end
        end
    end

    local title = constructWidget(TEXTBLOCK_CLASS, host)
    if isValid(title) then
        pcall(function() title:SetText(FText("MODS")) end)
        styleText(title, HEADER_COLOR)
        placeInCanvas(title, LABEL_X, PANEL_TOP + 36.0, nil)
    end

    local footer = constructWidget(TEXTBLOCK_CLASS, host)
    if isValid(footer) then
        pcall(function()
            footer:SetText(FText(
                "Up/Down select    Left/Right change    Enter toggle    Back close" ..
                "        * restart required    + reopen menu"))
        end)
        styleText(footer, MUTED_COLOR)
        placeInCanvas(footer, LABEL_X, PANEL_TOP + PANEL_HEIGHT - 44.0, nil)
    end

    titleWidgets = { title = title, footer = footer, background = background }

    -- One label/value pair per possible row: a header for every mod, plus the
    -- settings of whichever single mod is expanded. Slots beyond the current row
    -- count are simply collapsed, so over-allocating slightly is harmless.
    local widest = 0
    for _, entry in ipairs(registry or {}) do
        widest = math.max(widest, #(entry.settings or {}))
    end
    local maxRows = #(registry or {}) + widest

    for index = 1, maxRows do
        local label = constructWidget(TEXTBLOCK_CLASS, host)
        local value = constructWidget(TEXTBLOCK_CLASS, host)
        local y = FIRST_ROW_Y + (index - 1) * ROW_HEIGHT
        if isValid(label) then
            styleText(label, NORMAL_COLOR)
            placeInCanvas(label, LABEL_X, y, nil)
        end
        if isValid(value) then
            styleText(value, NORMAL_COLOR)
            placeInCanvas(value, VALUE_X, y, nil)
        end
        rowWidgets[index] = { label = label, value = value, y = y }
    end

    pcall(function() host:AddToViewport(500) end)
    log("panel built with " .. tostring(maxRows) .. " row slots")
    return true
end

--========================================================--
--                       RENDERING                        --
--========================================================--

function Panel.render()
    if not isOpen then return end

    for index, widgets in ipairs(rowWidgets) do
        local row = rows[index]
        local labelWidget = widgets.label
        local valueWidget = widgets.value

        if row == nil then
            if isValid(labelWidget) then pcall(function() labelWidget:SetVisibility(COLLAPSED) end) end
            if isValid(valueWidget) then pcall(function() valueWidget:SetVisibility(COLLAPSED) end) end
        else
            local selected = index == selectionIndex
            local color = selected and SELECTED_COLOR
                or (row.kind == "mod" and HEADER_COLOR or NORMAL_COLOR)
            local indent = row.kind == "setting" and SETTING_INDENT or 0.0
            local marker = selected and "> " or "  "

            if isValid(labelWidget) then
                pcall(function() labelWidget:SetVisibility(VISIBLE) end)
                pcall(function() labelWidget:SetText(FText(marker .. describeLabel(row))) end)
                styleText(labelWidget, color)
                local slot = nil
                pcall(function() slot = labelWidget.Slot end)
                if isValid(slot) then
                    pcall(function()
                        slot:SetPosition({ X = LABEL_X + indent, Y = widgets.y })
                    end)
                end
            end
            if isValid(valueWidget) then
                pcall(function() valueWidget:SetVisibility(VISIBLE) end)
                pcall(function() valueWidget:SetText(FText(describeValue(row))) end)
                styleText(valueWidget, color)
            end
        end
    end
end

--========================================================--
--                        ACTIONS                         --
--========================================================--

local function commit(entry, key, value)
    local ok, err = store.setValue(entry.mod, key, value)
    if not ok then
        log("could not save " .. entry.mod .. "." .. key .. ": " .. tostring(err))
        return false
    end
    -- Read the row model back off disk so the panel shows what was actually
    -- persisted, not what it hoped to persist.
    buildRows()
    Panel.render()
    return true
end

local function adjustNumber(row, direction)
    local setting = row.setting
    local current = store.valueOf(row.effective, setting)
    local step = setting.step or 1
    local updated = current + step * direction
    if setting.min ~= nil and updated < setting.min then updated = setting.min end
    if setting.max ~= nil and updated > setting.max then updated = setting.max end
    -- Repeated float steps drift visibly (1.4 + 0.05 + 0.05 = 1.5000000000000002)
    -- and that drift would be written to disk, so snap back onto a clean grid.
    local scale = 100000
    updated = math.floor(updated * scale + 0.5) / scale
    if updated == current then return false end
    return commit(row.entry, setting.key, updated)
end

local function cycleChoice(row, direction)
    local setting = row.setting
    local current = store.valueOf(row.effective, setting)
    local options = setting.options or {}
    if #options == 0 then return false end

    local currentIndex = 1
    for index, option in ipairs(options) do
        if option.value == current then currentIndex = index end
    end
    local nextIndex = currentIndex + direction
    if nextIndex < 1 then nextIndex = #options end
    if nextIndex > #options then nextIndex = 1 end
    if nextIndex == currentIndex then return false end
    return commit(row.entry, setting.key, options[nextIndex].value)
end

local function toggleBool(row)
    if row.kind == "mod" then
        if row.enabledSetting == nil then return false end
        local current = store.valueOf(row.effective, row.enabledSetting)
        return commit(row.entry, row.enabledSetting.key, not current)
    end
    local current = store.valueOf(row.effective, row.setting)
    return commit(row.entry, row.setting.key, not current)
end

function Panel.move(delta)
    if #rows == 0 then return end
    selectionIndex = selectionIndex + delta
    if selectionIndex < 1 then selectionIndex = #rows end
    if selectionIndex > #rows then selectionIndex = 1 end
    Panel.render()
end

function Panel.adjust(direction)
    local row = rows[selectionIndex]
    if row == nil then return end

    if row.kind == "mod" then
        -- Left/right on a header is the least surprising place to put the
        -- enable toggle, since that is the header's only value.
        toggleBool(row)
        return
    end

    local setting = row.setting
    if setting.type == "number" then
        adjustNumber(row, direction)
    elseif setting.type == "choice" then
        cycleChoice(row, direction)
    elseif setting.type == "bool" then
        toggleBool(row)
    end
end

function Panel.activate()
    local row = rows[selectionIndex]
    if row == nil then return end

    if row.kind == "mod" then
        -- Enter expands, so a mod's settings are one press away and the enable
        -- toggle stays on left/right.
        expandedMod = expandedMod == row.entry.mod and nil or row.entry.mod
        buildRows()
        -- Keep the header the player just pressed under the cursor.
        for index, candidate in ipairs(rows) do
            if candidate.kind == "mod" and candidate.entry.mod == row.entry.mod then
                selectionIndex = index
                break
            end
        end
        Panel.render()
        return
    end

    toggleBool(row)
end

function Panel.resetSelectedMod()
    local row = rows[selectionIndex]
    if row == nil then return false end
    local ok, err = store.resetMod(row.entry.mod)
    if not ok then
        log("could not reset " .. row.entry.mod .. ": " .. tostring(err))
        return false
    end
    log(row.entry.mod .. " reset to config.lua")
    buildRows()
    Panel.render()
    return true
end

function Panel.isOpen()
    return isOpen
end

function Panel.open()
    if isOpen then return true end
    buildRows()
    if not buildPanel() then return false end
    isOpen = true
    Panel.render()
    return true
end

function Panel.close()
    if not isOpen then return end
    isOpen = false
    destroyPanel()
end

-- Dumps the host widget tree so the exact canvas/child names can be confirmed
-- against a live game rather than guessed at.
function Panel.probe(emit)
    emit = emit or log
    local controller = resolveController()
    local umgLibrary = resolveUmgLibrary()
    local hostClass = StaticFindObject(Panel.hostClassPath or "")

    emit("controller: " .. objectName(controller))
    emit("umg library: " .. objectName(umgLibrary))
    emit("host class: " .. objectName(hostClass))

    if not isValid(controller) or not isValid(umgLibrary) or not isValid(hostClass) then
        emit("probe stopped: UI context is unavailable (open the game first)")
        return
    end

    local probeHost = nil
    pcall(function() probeHost = umgLibrary:Create(controller, hostClass, controller) end)
    emit("host instance: " .. objectName(probeHost))
    if not isValid(probeHost) then return end

    local root = nil
    pcall(function() root = probeHost.WidgetTree.RootWidget end)
    emit("WidgetTree.RootWidget: " .. objectName(root))

    local viaGetter = nil
    pcall(function() viaGetter = probeHost:GetRootWidget() end)
    emit("GetRootWidget(): " .. objectName(viaGetter))

    local target = isValid(root) and root or viaGetter
    if isValid(target) then
        local count = nil
        pcall(function() count = target:GetChildrenCount() end)
        emit("root children: " .. tostring(count))
        for index = 0, (tonumber(count) or 0) - 1 do
            local child = nil
            pcall(function() child = target:GetChildAt(index) end)
            emit(string.format("  [%d] %s", index, objectName(child)))
        end
    end

    emit("TextBlock class: " .. objectName(StaticFindObject(TEXTBLOCK_CLASS)))
    emit("Image class: " .. objectName(StaticFindObject(IMAGE_CLASS)))
end

return Panel
