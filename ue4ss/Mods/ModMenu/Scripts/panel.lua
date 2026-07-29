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
-- The layout is a single flat list with one mod expanded at a time. Twelve UMG
-- row pairs are virtualised over that model so a mod may expose more settings
-- without drawing through the footer or losing controller navigation.

local Panel = {}

-- ESlateVisibility
local VISIBLE = 0
local COLLAPSED = 1
local HIDDEN = 2

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
local MAX_VISIBLE_ROWS = 12

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
-- Every widget this panel put into the host, so closing can take out exactly
-- what it added and nothing else.
local addedWidgets = {}
-- The canvas the panel borrows is the menu's own SubMenu area, which the game
-- keeps hidden until a submenu opens. Its visibility is forced on while the
-- panel is up and put back exactly as it was on close.
local restoreVisibility = nil

local expandedMod = nil
local selectionIndex = 1
local scrollOffset = 0
local rows = {}
local isOpen = false

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
end

-- The panel draws into the start menu that is already on screen.
--
-- It used to create its own clone of WBP_Console_MainMenu_C to use as a blank
-- canvas. That class is the one both this mod and FieldEquipmentMenu watch with
-- NotifyOnNewObject, so creating it made both mods try to inject a rail row into
-- a widget that had never been constructed or added to the viewport — reading a
-- null Slot, which crashed the game outright. Never construct a widget of a
-- watched class; borrow the live one instead.
--
-- `icon` is this mod's own rail icon, used purely as a source of font and colour
-- so no styling widget has to be created either.
function Panel.attachTo(liveMenu, icon)
    host = liveMenu
    if isValid(icon) then
        local label = nil
        pcall(function() label = icon.MenuName end)
        if isValid(label) then styleSource = label end
    end
end

--========================================================--
--                     ROW MODEL                          --
--========================================================--

-- Rebuilds the flat list of rows from the registry and each mod's current
-- effective settings. Called on open and after every change so the displayed
-- value is always read back from disk rather than assumed.
local function ensureSelectionVisible()
    local maximumOffset = math.max(0, #rows - MAX_VISIBLE_ROWS)
    if selectionIndex <= scrollOffset then
        scrollOffset = selectionIndex - 1
    elseif selectionIndex > scrollOffset + MAX_VISIBLE_ROWS then
        scrollOffset = selectionIndex - MAX_VISIBLE_ROWS
    end
    if scrollOffset < 0 then scrollOffset = 0 end
    if scrollOffset > maximumOffset then scrollOffset = maximumOffset end
end

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
    ensureSelectionVisible()
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
        -- UE4SS decides whether a mod runs at all, from enabled.txt. That is the
        -- state worth showing on the header; the mod's own ENABLED setting is
        -- just one of its settings and lives in the expanded list.
        local loaded = store.isModEnabled(row.entry.mod)
        return loaded and "ON" or "OFF"
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
    addedWidgets[#addedWidgets + 1] = widget
    -- A freshly constructed widget does not reliably start visible, and the
    -- container it lands in may have been hidden, so say so explicitly.
    pcall(function() widget:SetVisibility(VISIBLE) end)
    pcall(function() widget:SetRenderOpacity(1.0) end)
    pcall(function() slot:SetAutoSize(width == nil) end)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    if width ~= nil then
        pcall(function() slot:SetSize({ X = width, Y = ROW_HEIGHT }) end)
    end
    pcall(function() slot:SetZOrder(50) end)
    return true
end

-- The start menu's root is a RetainerBox (it renders the whole menu through a
-- material), and a RetainerBox has no AddChildToCanvas. Having children is
-- therefore not enough to be a canvas — the tree has to be walked until a real
-- CanvasPanel turns up.
local CANVAS_FRAGMENT = "CanvasPanel"
local MAX_TREE_DEPTH = 8

local function collectCanvasPanels(widget)
    local found = {}
    local seen = {}

    local function walk(current, depth)
        if not isValid(current) or depth > MAX_TREE_DEPTH then return end
        local key = objectName(current)
        if seen[key] then return end
        seen[key] = true

        if string.find(key, CANVAS_FRAGMENT, 1, true) ~= nil then
            found[#found + 1] = current
        end

        local count = nil
        pcall(function() count = current:GetChildrenCount() end)
        if type(count) ~= "number" then return end
        for index = 0, count - 1 do
            local child = nil
            pcall(function() child = current:GetChildAt(index) end)
            walk(child, depth + 1)
        end
    end

    local root = nil
    pcall(function() root = widget.WidgetTree.RootWidget end)
    if not isValid(root) then
        pcall(function() root = widget:GetRootWidget() end)
    end
    walk(root, 0)
    return found
end

-- Attaching is the only honest test that a widget really is a usable canvas, so
-- each candidate is tried for real and the first one that accepts a child wins.
local function resolveCanvas(widget, probe)
    local candidates = collectCanvasPanels(widget)
    log(string.format("found %d candidate canvas panel(s)", #candidates))

    for _, candidate in ipairs(candidates) do
        local slot = nil
        pcall(function() slot = candidate:AddChildToCanvas(probe) end)
        if isValid(slot) then
            log("panel canvas resolved: " .. objectName(candidate))
            return candidate, slot
        end
    end

    log("no canvas accepted a child; run 'modmenu probe' and share the output")
    return nil, nil
end

-- Walks from the canvas up through its parents, forcing anything collapsed or
-- hidden to be visible and recording enough to put it all back. Only COLLAPSED
-- and HIDDEN are touched: HIT_TEST_INVISIBLE still draws, and overriding it
-- would needlessly change how the menu handles the mouse.
local function forceVisibleChain(startWidget)
    local restore = {}
    local current = startWidget
    local level = 0

    while isValid(current) and level < 6 do
        local visibility = nil
        local opacity = nil
        pcall(function() visibility = current:GetVisibility() end)
        pcall(function() opacity = current:GetRenderOpacity() end)
        log(string.format("  chain[%d] visibility=%s opacity=%s %s",
            level, tostring(visibility), tostring(opacity), objectName(current)))

        local changed = false
        if visibility == COLLAPSED or visibility == HIDDEN then
            if pcall(function() current:SetVisibility(VISIBLE) end) then changed = true end
        end
        if type(opacity) == "number" and opacity < 1.0 then
            if pcall(function() current:SetRenderOpacity(1.0) end) then changed = true end
        end
        if changed then
            restore[#restore + 1] =
                { widget = current, visibility = visibility, opacity = opacity }
        end

        local parent = nil
        pcall(function() parent = current.Slot.Parent end)
        current = parent
        level = level + 1
    end

    return restore
end

local function restoreVisibilityChain()
    for _, entry in ipairs(restoreVisibility or {}) do
        if isValid(entry.widget) then
            if entry.visibility ~= nil then
                pcall(function() entry.widget:SetVisibility(entry.visibility) end)
            end
            if entry.opacity ~= nil then
                pcall(function() entry.widget:SetRenderOpacity(entry.opacity) end)
            end
        end
    end
    restoreVisibility = nil
end

-- Takes out only what the panel put in. The host belongs to the game, so
-- detaching it would tear the start menu down with it.
local function destroyPanel()
    for _, widget in ipairs(addedWidgets) do
        if isValid(widget) then pcall(function() widget:RemoveFromParent() end) end
    end
    addedWidgets = {}
    restoreVisibilityChain()
    canvas = nil
    rowWidgets = {}
    titleWidgets = nil
    host = nil
    styleSource = nil
end

local function buildPanel()
    destroyPanel()

    if not isValid(host) then
        log("cannot build panel: the start menu is not on screen")
        return false
    end

    -- The backing panel doubles as the probe that identifies a usable canvas,
    -- so the very first attachment is also the test.
    local background = constructWidget(IMAGE_CLASS, host)
    if not isValid(background) then
        log("cannot build panel: could not construct the backing image")
        return false
    end

    local backgroundSlot = nil
    canvas, backgroundSlot = resolveCanvas(host, background)
    if not isValid(canvas) then
        destroyPanel()
        return false
    end

    -- The canvas the game hands over is its SubMenu area, which stays collapsed
    -- until a submenu opens. Without this the whole panel is built correctly and
    -- renders nothing at all.
    restoreVisibility = forceVisibleChain(canvas)

    addedWidgets[#addedWidgets + 1] = background
    pcall(function() background:SetVisibility(VISIBLE) end)
    pcall(function() background:SetRenderOpacity(1.0) end)
    pcall(function()
        background:SetColorAndOpacity({ R = 0.02, G = 0.03, B = 0.06, A = 0.88 })
    end)
    pcall(function() backgroundSlot:SetAutoSize(false) end)
    pcall(function() backgroundSlot:SetPosition({ X = PANEL_LEFT, Y = PANEL_TOP }) end)
    pcall(function() backgroundSlot:SetSize({ X = PANEL_WIDTH, Y = PANEL_HEIGHT }) end)
    pcall(function() backgroundSlot:SetZOrder(40) end)

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
                "Up/Down select    Left/Right change    Enter expand/toggle    Back close" ..
                "        * restart required    + reopen menu"))
        end)
        styleText(footer, MUTED_COLOR)
        placeInCanvas(footer, LABEL_X, PANEL_TOP + PANEL_HEIGHT - 44.0, nil)
    end

    titleWidgets = { title = title, footer = footer, background = background }

    -- Fixed viewport: render maps these widgets onto a moving window in `rows`.
    for index = 1, MAX_VISIBLE_ROWS do
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

    -- No AddToViewport: the host is the start menu, already on screen. The
    -- panel's widgets sit above it on Z order alone.
    log("panel built with " .. tostring(MAX_VISIBLE_ROWS) .. " virtual row slots")
    return true
end

--========================================================--
--                       RENDERING                        --
--========================================================--

function Panel.render()
    if not isOpen then return end

    for index, widgets in ipairs(rowWidgets) do
        local modelIndex = scrollOffset + index
        local row = rows[modelIndex]
        local labelWidget = widgets.label
        local valueWidget = widgets.value

        if row == nil then
            if isValid(labelWidget) then pcall(function() labelWidget:SetVisibility(COLLAPSED) end) end
            if isValid(valueWidget) then pcall(function() valueWidget:SetVisibility(COLLAPSED) end) end
        else
            local selected = modelIndex == selectionIndex
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

    if titleWidgets ~= nil and isValid(titleWidgets.title) then
        local first = #rows == 0 and 0 or scrollOffset + 1
        local last = math.min(#rows, scrollOffset + MAX_VISIBLE_ROWS)
        pcall(function()
            titleWidgets.title:SetText(FText(string.format(
                "MODS    %d-%d / %d",
                first,
                last,
                #rows
            )))
        end)
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
    if setting.floorKey ~= nil then
        local floorValue = tonumber(row.effective[setting.floorKey])
        if floorValue ~= nil and updated < floorValue then updated = floorValue end
    end
    if setting.ceilingKey ~= nil then
        local ceilingValue = tonumber(row.effective[setting.ceilingKey])
        if ceilingValue ~= nil and updated > ceilingValue then updated = ceilingValue end
    end
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
        -- This is one UI toggle backed by an atomic store operation. enabled.txt
        -- controls the next launch and the runtime ENABLED value controls the
        -- already-loaded Lua state; neither half may change without the other.
        local loaded = store.isModEnabled(row.entry.mod)
        if loaded ~= nil then
            local wanted = not loaded
            local enabledKey = nil
            if row.enabledSetting ~= nil then
                enabledKey = row.enabledSetting.key
            end
            local ok, err = store.setEnabledState(
                row.entry.mod,
                enabledKey,
                wanted
            )
            if not ok then
                log("could not switch " .. row.entry.mod .. ": " .. tostring(err))
                return false
            end
            buildRows()
            Panel.render()
            return true
        end

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
    ensureSelectionVisible()
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
        local opening = expandedMod ~= row.entry.mod
        if opening then
            expandedMod = row.entry.mod
        else
            expandedMod = nil
        end
        buildRows()
        -- Opening lands on the first actual setting. Keeping the cursor on the
        -- header made the next Left/Right press disable the whole mod when the
        -- player reasonably expected to edit the newly opened settings.
        local headerIndex = nil
        for index, candidate in ipairs(rows) do
            if candidate.kind == "mod" and candidate.entry.mod == row.entry.mod then
                headerIndex = index
                break
            end
        end
        if headerIndex == nil then
            log("row model lost the selected mod header: " .. row.entry.mod)
            return
        end
        selectionIndex = headerIndex
        if opening and rows[selectionIndex + 1] ~= nil
            and rows[selectionIndex + 1].kind == "setting"
            and rows[selectionIndex + 1].entry.mod == row.entry.mod then
            selectionIndex = selectionIndex + 1
        end
        ensureSelectionVisible()
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
    isOpen = false
    destroyPanel()
    expandedMod = nil
    selectionIndex = 1
    scrollOffset = 0
    host = nil
    styleSource = nil
end

-- Dumps the host widget tree so the exact canvas/child names can be confirmed
-- against a live game rather than guessed at.
-- Inspects the live start menu. It must never create a widget of its own: doing
-- that is what crashed the game, because both mods watch the main-menu class for
-- construction and would inject into the throwaway instance.
function Panel.probe(emit)
    emit = emit or log

    emit("controller: " .. objectName(resolveController()))
    emit("live host: " .. objectName(host))

    if not isValid(host) then
        emit("probe stopped: open the start menu first, then run this again")
        return
    end

    local root = nil
    pcall(function() root = host.WidgetTree.RootWidget end)
    emit("WidgetTree.RootWidget: " .. objectName(root))

    local viaGetter = nil
    pcall(function() viaGetter = host:GetRootWidget() end)
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
