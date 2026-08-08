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
--   rows    two UMG TextBlocks each (label on the left, value on the right),
--           over transparent UButtons that supply exact Slate mouse targets.
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
local HIT_TEST_INVISIBLE = 3

local TEXTBLOCK_CLASS = "/Script/UMG.TextBlock"
local IMAGE_CLASS = "/Script/UMG.Image"
local BUTTON_CLASS = "/Script/UMG.Button"

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

-- "Your settings page is open" -- published to the mod whose rows are expanded,
-- and to no one else.
--
-- A mod that wants to react to being edited (a live preview, say) declares
-- `preview = true` in its own Scripts/modmenu.lua and reads the marker from its
-- own Scripts/preview.lua. That declaration is the entire contract: ModMenu
-- names no mod, requires no mod, and behaves identically whether or not any
-- mod uses it. It used to name one directly, which made an unrelated mod's
-- absence a fault in this menu.
--
-- Exactly one mod can hold the marker at a time -- the expanded one -- so
-- previewMod is what has to be cleared, not a name known up front.
local previewMod = nil
local lastPreviewError = nil

-- Mods switched on from the panel, waiting to be started until the panel is
-- gone. Filled by toggleBool, drained by Panel.flushPendingStarts. A set, not a
-- list: toggling the same mod on and off and on again is one pending start, not
-- three.
local pendingStarts = {}

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
end

local function writePreviewMarker(modName, active)
    local called, written, writeError = pcall(function()
        return store.setPreview(modName, active)
    end)
    if not called then
        writeError = written
        written = false
    end
    if written ~= true then
        local message = tostring(modName) .. ": " ..
            tostring(writeError or "preview state publication failed")
        if lastPreviewError ~= message then
            lastPreviewError = message
            log("preview marker unavailable for " .. message)
        end
        return false
    end
    lastPreviewError = nil
    return true
end

-- Moves the marker to `modName`, or clears it entirely when that is nil. Always
-- best effort: this marker drives an optional convenience in some other mod and
-- is never a reason to refuse the player an action in this one.
local function setPreviewOwner(modName)
    if previewMod == modName then return end
    if previewMod ~= nil then
        writePreviewMarker(previewMod, false)
        previewMod = nil
    end
    if modName ~= nil and writePreviewMarker(modName, true) then
        previewMod = modName
    end
end

-- True when the mod's own manifest asked for the marker.
local function wantsPreview(entry)
    return type(entry) == "table" and entry.preview == true
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
        -- A mod with no settings contract has nothing to read: its whole state
        -- is the enabled.txt marker. A configured mod whose settings have
        -- broken since startup is demoted to the same row rather than taking
        -- the entire panel down with it.
        local configured = entry.configured == true
        local effective = nil
        local enabledSetting = nil

        if configured then
            local ok, result = pcall(store.readEffective, entry.mod)
            if ok then
                effective = result
                for _, setting in ipairs(entry.settings or {}) do
                    if setting.key == "ENABLED" then enabledSetting = setting end
                end
            else
                configured = false
                log(entry.mod .. " settings unreadable, showing on/off only: " ..
                    tostring(result))
            end
        end

        built[#built + 1] = {
            kind = "mod",
            entry = entry,
            effective = effective,
            enabledSetting = enabledSetting,
            configured = configured,
        }

        if configured and expandedMod == entry.mod then
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
        local ok, loaded = pcall(store.isModEnabled, row.entry.mod)
        -- Rendering runs on every cursor move, so an unreadable marker says so
        -- in the row instead of filling the log or throwing out of input.
        if not ok then return "--" end
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
        -- Only a mod with settings has something to expand. One without gets a
        -- blank of the same width, so the labels still line up and the +/- is
        -- never a promise the row cannot keep.
        local prefix = "  "
        if row.configured then
            prefix = expandedMod == row.entry.mod and "- " or "+ "
        end
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

local function placeInCanvas(widget, x, y, width, height, zOrder)
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
        pcall(function() slot:SetSize({ X = width, Y = height or ROW_HEIGHT }) end)
    end
    pcall(function() slot:SetZOrder(zOrder or 50) end)
    return true
end

-- A transparent UButton remains part of Slate's real hit-test grid. Reading its
-- inherited UWidget:IsHovered() state on LMB therefore identifies an exact panel
-- target without converting the world-space menu's geometry to screen space.
-- Text is rendered above it as HIT_TEST_INVISIBLE, so the visible glyphs cannot
-- steal the pointer from the button underneath.
local function constructHitTarget(x, y, width, height)
    local button = constructWidget(BUTTON_CLASS, host)
    if not isValid(button) then return nil end
    if not placeInCanvas(button, x, y, width, height, 45) then return nil end

    local configured, configureError = pcall(function()
        -- UButton exposes IsFocusable as a reflected property on this build; it
        -- has no reflected SetIsFocusable UFunction.
        button.IsFocusable = false
        button:SetColorAndOpacity({ R = 1.0, G = 1.0, B = 1.0, A = 0.0 })
        button:SetBackgroundColor({ R = 1.0, G = 1.0, B = 1.0, A = 0.0 })
        button:SetVisibility(VISIBLE)
        button:SetRenderOpacity(1.0)
        if button.IsFocusable ~= false then
            error("IsFocusable write did not stick")
        end
    end)
    if not configured then
        log("could not configure a panel mouse target: " .. tostring(configureError))
        return nil
    end
    return button
end

local function makeTextNonInteractive(widget)
    if isValid(widget) then
        pcall(function() widget:SetVisibility(HIT_TEST_INVISIBLE) end)
    end
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
    if not isValid(host) then
        host = nil
        styleSource = nil
    end
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
        makeTextNonInteractive(title)
    end

    local footer = constructWidget(TEXTBLOCK_CLASS, host)
    if isValid(footer) then
        pcall(function()
            footer:SetText(FText(
                "Mouse: name expand | value -/+ | Close    Keys: arrows | Enter | Back" ..
                "    * restart    + reopen"))
        end)
        styleText(footer, MUTED_COLOR)
        placeInCanvas(footer, LABEL_X, PANEL_TOP + PANEL_HEIGHT - 44.0, nil)
        makeTextNonInteractive(footer)
    end

    local closeX = PANEL_LEFT + PANEL_WIDTH - 154.0
    local closeY = PANEL_TOP + 27.0
    local closeHit = constructHitTarget(closeX, closeY, 112.0, 40.0)
    if not isValid(closeHit) then
        log("cannot build panel: close mouse target is unavailable")
        destroyPanel()
        return false
    end

    local closeText = constructWidget(TEXTBLOCK_CLASS, host)
    if isValid(closeText) then
        pcall(function() closeText:SetText(FText("[ CLOSE ]")) end)
        styleText(closeText, MUTED_COLOR)
        placeInCanvas(closeText, closeX + 12.0, closeY + 7.0, nil)
        makeTextNonInteractive(closeText)
    end

    titleWidgets = {
        title = title,
        footer = footer,
        background = background,
        closeText = closeText,
        closeHit = closeHit,
    }

    -- Fixed viewport: render maps these widgets onto a moving window in `rows`.
    local rowHitLeft = PANEL_LEFT + 32.0
    local valueHitLeft = VALUE_X - 24.0
    local valueHitRight = PANEL_LEFT + PANEL_WIDTH - 40.0
    local valueHalfWidth = (valueHitRight - valueHitLeft) / 2.0
    for index = 1, MAX_VISIBLE_ROWS do
        local label = constructWidget(TEXTBLOCK_CLASS, host)
        local value = constructWidget(TEXTBLOCK_CLASS, host)
        local y = FIRST_ROW_Y + (index - 1) * ROW_HEIGHT
        if isValid(label) then
            styleText(label, NORMAL_COLOR)
            placeInCanvas(label, LABEL_X, y, nil)
            makeTextNonInteractive(label)
        end
        if isValid(value) then
            styleText(value, NORMAL_COLOR)
            placeInCanvas(value, VALUE_X, y, nil)
            makeTextNonInteractive(value)
        end

        local labelHit = constructHitTarget(
            rowHitLeft, y - 3.0, valueHitLeft - rowHitLeft, ROW_HEIGHT)
        local decrementHit = constructHitTarget(
            valueHitLeft, y - 3.0, valueHalfWidth, ROW_HEIGHT)
        local incrementHit = constructHitTarget(
            valueHitLeft + valueHalfWidth, y - 3.0, valueHalfWidth, ROW_HEIGHT)
        if not isValid(labelHit) or not isValid(decrementHit)
            or not isValid(incrementHit) then
            log("cannot build panel: row " .. tostring(index) ..
                " mouse targets are unavailable")
            destroyPanel()
            return false
        end

        rowWidgets[index] = {
            label = label,
            value = value,
            labelHit = labelHit,
            decrementHit = decrementHit,
            incrementHit = incrementHit,
            y = y,
        }
    end

    -- No AddToViewport: the host is the start menu, already on screen. The
    -- panel's widgets sit above it on Z order alone.
    log("panel built with " .. tostring(MAX_VISIBLE_ROWS) ..
        " virtual row slots and " .. tostring(MAX_VISIBLE_ROWS * 3 + 1) ..
        " exact mouse targets")
    return true
end

--========================================================--
--                       RENDERING                        --
--========================================================--

local function setHitTargetsVisibility(widgets, visibility)
    if isValid(widgets.labelHit) then
        pcall(function() widgets.labelHit:SetVisibility(visibility) end)
    end
    if isValid(widgets.decrementHit) then
        pcall(function() widgets.decrementHit:SetVisibility(visibility) end)
    end
    if isValid(widgets.incrementHit) then
        pcall(function() widgets.incrementHit:SetVisibility(visibility) end)
    end
end

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
            setHitTargetsVisibility(widgets, COLLAPSED)
        else
            local selected = modelIndex == selectionIndex
            local color = selected and SELECTED_COLOR
                or (row.kind == "mod" and HEADER_COLOR or NORMAL_COLOR)
            local indent = row.kind == "setting" and SETTING_INDENT or 0.0
            local marker = selected and "> " or "  "

            if isValid(labelWidget) then
                pcall(function() labelWidget:SetVisibility(HIT_TEST_INVISIBLE) end)
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
                pcall(function() valueWidget:SetVisibility(HIT_TEST_INVISIBLE) end)
                pcall(function() valueWidget:SetText(FText(describeValue(row))) end)
                styleText(valueWidget, color)
            end
            setHitTargetsVisibility(widgets, VISIBLE)
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
        -- controls the next launch and, when the mod has one, the runtime
        -- ENABLED value controls the already-loaded Lua state; neither half may
        -- change without the other.
        local read, loaded = pcall(store.isModEnabled, row.entry.mod)
        if not read then
            log("could not read the load state of " .. row.entry.mod ..
                ": " .. tostring(loaded))
            return false
        end

        -- No contract, no runtime key: the store then writes enabled.txt alone.
        local enabledKey = nil
        if row.enabledSetting ~= nil then
            enabledKey = row.enabledSetting.key
        end

        local nextState = not loaded
        local ok, err = store.setEnabledState(
            row.entry.mod,
            enabledKey,
            nextState
        )
        if not ok then
            log("could not switch " .. row.entry.mod .. ": " .. tostring(err))
            return false
        end

        -- Past this point enabled.txt has already changed on disk, so the switch
        -- has happened whatever else does or does not work. Starting the mod in
        -- this session is a separate, best-effort step on top of it: if it
        -- fails, the mod is still on for the next launch, which is the state the
        -- row shows. Returning early here instead skipped the redraw below and
        -- left the row displaying the value it had before the press, so the menu
        -- said OFF about a mod that was written on -- and pressing again to
        -- "fix" it read the new state and switched it back off.
        --
        -- The start itself is deferred to panel close; see flushPendingStarts.
        -- Switching back off drops the pending start rather than leaving one
        -- queued against a mod the player has since turned off.
        pendingStarts[row.entry.mod] = nextState == true or nil

        buildRows()
        Panel.render()
        return true
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
        -- toggle stays on left/right. A mod with no settings has nothing to
        -- open, so there Enter switches it rather than doing nothing at all.
        if not row.configured then
            toggleBool(row)
            return
        end

        local opening = expandedMod ~= row.entry.mod
        local nextExpanded = opening and row.entry.mod or nil
        if nextExpanded ~= expandedMod then
            -- Best effort. This used to refuse to expand when the marker could
            -- not be written, so on an install missing the one mod it named,
            -- no mod's settings could be opened at all -- Enter did nothing,
            -- with the reason only in the log.
            setPreviewOwner((opening and wantsPreview(row.entry)) and row.entry.mod or nil)
        end
        expandedMod = nextExpanded
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

local function readHitTargetHover(widget, description)
    if not isValid(widget) then
        return nil, tostring(description) .. " mouse target is invalid"
    end
    local hovered = nil
    local hoverOk, hoverError = pcall(function() hovered = widget:IsHovered() end)
    if not hoverOk or type(hovered) ~= "boolean" then
        return nil, tostring(description) .. " hover is unreadable: " ..
            tostring(hoverError)
    end
    return hovered, nil
end

local function selectMouseRow(modelIndex)
    selectionIndex = modelIndex
    ensureSelectionVisible()
    Panel.render()
end

-- Handles exactly one LMB press through the transparent UButton hit targets
-- built with the panel. A label selects its row and expands/collapses a mod
-- header. The left and right halves of the value perform the same -1/+1 action
-- as controller Left/Right, including boolean and mod enable toggles.
--
-- nil means the canonical hit-test contract failed and the caller must close the
-- modal panel; false means the click was simply outside every interactive area.
function Panel.clickHovered()
    if not isOpen then return false, nil end

    if titleWidgets == nil then
        return nil, "panel title widgets are unavailable"
    end
    local closeHovered, closeError =
        readHitTargetHover(titleWidgets.closeHit, "close")
    if closeHovered == nil then return nil, closeError end
    if closeHovered then return true, "close" end

    for slotIndex, widgets in ipairs(rowWidgets) do
        local modelIndex = scrollOffset + slotIndex
        local row = rows[modelIndex]
        if row ~= nil then
            local labelHovered, labelError =
                readHitTargetHover(widgets.labelHit, "row label")
            if labelHovered == nil then return nil, labelError end
            if labelHovered then
                selectMouseRow(modelIndex)
                if row.kind == "mod" then Panel.activate() end
                return true, "label"
            end

            local decrementHovered, decrementError =
                readHitTargetHover(widgets.decrementHit, "value decrement")
            if decrementHovered == nil then return nil, decrementError end
            if decrementHovered then
                selectMouseRow(modelIndex)
                Panel.adjust(-1)
                return true, "decrement"
            end

            local incrementHovered, incrementError =
                readHitTargetHover(widgets.incrementHit, "value increment")
            if incrementHovered == nil then return nil, incrementError end
            if incrementHovered then
                selectMouseRow(modelIndex)
                Panel.adjust(1)
                return true, "increment"
            end
        end
    end

    return false, nil
end

function Panel.resetSelectedMod()
    local row = rows[selectionIndex]
    if row == nil then return false end
    -- No settings contract means no runtime.lua of ours to take away.
    if row.kind == "mod" and not row.configured then
        log(row.entry.mod .. " has no menu-written settings to reset")
        return false
    end
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

-- Starts the mods switched on during this panel session, and reports how many
-- were queued so the caller knows whether the rail is about to change.
--
-- Deferred rather than done at the keypress, because a mod started while the
-- panel is up comes back into a start menu that is already open and injects its
-- rail row immediately -- building a donor list and forcing a layout prepass
-- underneath a panel that is covering the whole menu. That is the stutter on
-- switching a mod on, and the half-resolved tree behind it: two mods editing
-- the same widget hierarchy, one of them from under a modal panel that owns the
-- screen and the input.
--
-- Waiting costs nothing. enabled.txt is already written, the row already reads
-- ON, and nothing on the rail is visible until the panel closes anyway -- so
-- the only thing the delay changes is that the newcomer lands on a rail nobody
-- is standing on. The caller then reconciles the order.
local function startPendingMod(modName)
    -- enabled.txt is the truth, and it can have moved since the press -- through
    -- this panel or from anywhere else. Never start a mod that is not switched
    -- on at the moment the start actually happens, or toggling one on and back
    -- off before closing would start it anyway.
    local read, enabled = pcall(store.isModEnabled, modName)
    if not read then
        log("could not confirm the load state of " .. modName ..
            " before starting it: " .. tostring(enabled))
        return false
    end
    if enabled ~= true then
        log(modName .. " was switched off again before it started; leaving it alone")
        return false
    end

    if type(RestartMod) ~= "function" then
        -- A real Lua global registered by the loader, not a UObject method, so
        -- this test means what it says here.
        log(modName .. " is switched on for the next launch, but could not be " ..
            "started now: this UE4SS build does not expose RestartMod")
        return false
    end

    local called, callError = pcall(function() RestartMod(modName) end)
    if not called then
        log(modName .. " is switched on for the next launch, but could not be " ..
            "started now: " .. tostring(callError))
        return false
    end

    -- Queued, not started. RestartMod only enqueues a reinstall and resolves the
    -- folder name later, on the loader's event loop; a name it cannot match is a
    -- warning in UE4SS.log and nothing here. So this must not claim the mod is
    -- running.
    log("UE4SS start queued for " .. modName .. "; UE4SS.log has the outcome")
    return true
end

function Panel.flushPendingStarts()
    local names = {}
    for modName in pairs(pendingStarts) do names[#names + 1] = modName end
    -- Cleared up front: a start that fails is not retried on the next close.
    pendingStarts = {}
    if #names == 0 then return 0 end
    -- Deterministic order, so one session's log reads like the next.
    table.sort(names)

    local queued = 0
    for _, modName in ipairs(names) do
        if startPendingMod(modName) then queued = queued + 1 end
    end
    return queued
end

function Panel.open()
    if isOpen then return true end
    buildRows()
    if not buildPanel() then return false end
    isOpen = true
    Panel.render()
    return true
end

-- Closing always succeeds.
--
-- This used to return false without closing when the preview marker could not
-- be published, on the reasoning that a stuck marker is the more dangerous
-- state. It is not, and the reasoning does not survive contact with what
-- actually happens: refusing to close does not clear the marker either, so it
-- stays exactly as stuck -- and now the player is stuck with it, holding a
-- panel that swallows every button (handleButton consumes everything while
-- isOpen) over a start menu they can no longer use. Back does nothing, Escape
-- does nothing, and there is no mouse path out. That is the "I can use the
-- menu but I cannot close it" report.
--
-- It needed no exotic conditions. The marker was addressed to one named mod
-- that this menu does not require and does not ship with, so on any install
-- without that folder io.open failed and the very first Back press trapped the
-- player. The marker is now addressed only to a mod that asked for it, and
-- either way a marker is never worth the way out.
function Panel.close()
    setPreviewOwner(nil)
    isOpen = false
    destroyPanel()
    expandedMod = nil
    selectionIndex = 1
    scrollOffset = 0
    if not isValid(host) then
        host = nil
        styleSource = nil
    end
    return true
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
