-- ModMenu registry — what the in-game Mods menu shows, and how far each value
-- may be pushed.
--
-- This file is the only place that needs editing when a mod is added or gains a
-- new tunable. Nothing here talks to the other mods directly: ModMenu writes the
-- chosen values into that mod's Scripts/runtime.lua and ModMenuBridge, which the
-- mod itself loads, picks them up within about a second.
--
-- entry fields
--   mod       folder name under Mods/. Must match exactly.
--   label     row label in the menu.
--   summary   one line shown under the label.
--   apply     when a change takes effect:
--               "live"    immediately
--               "menu"    next time the start menu is opened
--               "restart" next time the game is launched
--   settings  list of tunables, in display order.
--
-- setting fields
--   key       the name written to runtime.lua, exactly as the mod reads it.
--   label     row label.
--   type      "bool" | "number" | "choice"
--   default   the value the mod falls back to, shown when nothing overrides it.
--   min/max   inclusive bounds for "number". Chosen to match the safety clamps
--             the mods already apply internally, so the menu can never ask for
--             a value the mod will silently reject.
--   step      increment per left/right press for "number".
--   format    string.format pattern for displaying a "number".
--   options   list of { value, label } for "choice".
--   apply     optional per-setting override of the mod-level apply.

return {
    {
        mod = "SpeedMod",
        label = "Speed",
        summary = "Sprint acceleration on open terrain",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            -- Bounds mirror SAFE_MIN_START / SAFE_MAX_START in SpeedMod.
            { key = "START_SPEED", label = "Starting speed", type = "number",
              default = 1.40, min = 1.00, max = 2.50, step = 0.05, format = "%.2fx" },
            -- Bounds mirror SAFE_MIN_MAX / SAFE_MAX_MAX.
            { key = "MAX_SPEED", label = "Top speed", type = "number",
              default = 3.20, min = 1.00, max = 4.50, step = 0.10, format = "%.2fx" },
            -- Bounds mirror SAFE_MIN_RAMP_SECONDS / SAFE_MAX_RAMP_SECONDS.
            { key = "SECONDS_TO_MAX_SPEED", label = "Time to top speed", type = "number",
              default = 1.80, min = 0.25, max = 10.00, step = 0.05, format = "%.2fs" },
            { key = "DISABLE_IN_COMBAT", label = "Off during combat", type = "bool",
              default = true },
        },
    },

    {
        mod = "AutoPickupMod",
        label = "Auto Pickup",
        summary = "Collect drops without walking onto them",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "PICKUP_RANGE", label = "Pickup range", type = "number",
              default = 1000, min = 0, max = 5000, step = 100, format = "%.0f cm" },
            { key = "ICON_DISPLAY_RANGE", label = "Icon range", type = "number",
              default = 1500, min = 0, max = 5000, step = 100, format = "%.0f cm" },
            { key = "PICKUP_INTERVAL", label = "Scan interval", type = "number",
              default = 0.30, min = 0.05, max = 2.00, step = 0.05, format = "%.2fs" },
            { key = "SHOW_PICKUP_UI", label = "Pickup notification", type = "bool",
              default = true },
            { key = "EXPAND_OPERATABLE", label = "Widen prompt area", type = "bool",
              default = true },
            { key = "ICON_RANGE_PATCH", label = "Patch icon distance", type = "bool",
              default = true },
            { key = "DEBUG_HOOKS", label = "Debug logging", type = "bool", default = false },
        },
    },

    {
        mod = "norescue",
        label = "No Rescue",
        summary = "Real falls: no edge rescue, no fall-death warp",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            -- The game buckets landings into tiers by height. Pushing the death
            -- tier out of reach is the whole mechanic, so this is a two-state
            -- switch rather than a slider over a meaningless range.
            { key = "DEATH_LANDING_HEIGHT", label = "Fall damage death", type = "choice",
              default = 1000000000.0, options = {
                  { value = 1000000000.0, label = "Never" },
                  { value = 0.0, label = "Game default" },
              } },
            { key = "SAFETY_NET_MS", label = "Re-apply interval", type = "number",
              default = 5000, min = 1000, max = 30000, step = 1000, format = "%.0f ms" },
            { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = false },
        },
    },

    {
        mod = "FieldEquipmentMod",
        label = "Field Equipment",
        summary = "Equipment entry in this menu",
        apply = "menu",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = true },
        },
    },

    {
        mod = "AincradOpenWorld",
        label = "Open World",
        summary = "Any quest opens the entire floor",
        -- The floor is opened by growing arrays on each quest manifest as it is
        -- constructed. A change cannot retract a floor that is already open, so
        -- this one is honestly a restart.
        apply = "restart",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = false },
            { key = "PROBE_MODE", label = "Research probe", type = "bool", default = false },
        },
    },
}
