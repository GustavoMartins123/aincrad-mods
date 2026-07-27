-- ModMenu registry — what the in-game Mods menu shows, and how far each value
-- may be pushed.
--
-- This file is the only place that needs editing when a mod is added or gains a
-- new tunable. Nothing here talks to the other mods directly: ModMenu writes the
-- chosen values into that mod's Scripts/runtime.lua. Each mod watches that exact
-- file from its own isolated Lua state and validates values before applying them.
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
--   default   documented config.lua value, used only as registry documentation.
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
              default = 3.20, min = 1.00, max = 8.00, step = 0.10, format = "%.2fx" },
            -- Bounds mirror SAFE_MIN_RAMP_SECONDS / SAFE_MAX_RAMP_SECONDS.
            { key = "SECONDS_TO_MAX_SPEED", label = "Time to top speed", type = "number",
              default = 1.80, min = 0.25, max = 10.00, step = 0.05, format = "%.2fs" },
            -- Height is proportional to JumpZVelocity squared. SpeedMod converts
            -- this multiplier to the correct vertical launch velocity.
            { key = "JUMP_HEIGHT_MULTIPLIER", label = "Jump height", type = "number",
              default = 1.00, min = 0.25, max = 6.00, step = 0.25, format = "%.2fx" },
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
              default = 1000, min = 100, max = 5000, step = 100, format = "%.0f cm" },
            { key = "ICON_DISPLAY_RANGE", label = "Icon range", type = "number",
              default = 1500, min = 100, max = 5000, step = 100, format = "%.0f cm" },
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
            { key = "SHOW_CHARACTER", label = "Show character",
              type = "bool", default = true },
            -- Bounds mirror the CAMERA_HEIGHT rule in FieldEquipmentMod. Takes
            -- effect the next time Equipment is opened, not the current screen.
            { key = "CAMERA_HEIGHT", label = "Camera height", type = "number",
              default = 40, min = -100, max = 200, step = 5, format = "%+.0f cm" },
            { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = true },
        },
    },

    {
        mod = "FastTravelMod",
        label = "Fast Travel",
        summary = "Teleport to selected checkpoints and map pins",
        apply = "menu",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "DEBUG_LOGS", label = "Debug logging",
              type = "bool", default = false },
        },
    },

    {
        mod = "ExperienceNotifications",
        label = "XP Notifications",
        summary = "Show EXP earned from each enemy",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "DEBUG_LOGS", label = "Debug logging",
              type = "bool", default = false },
        },
    },

    {
        mod = "WorldEnemyDirector",
        label = "Enemy Director",
        summary = "Multiply and mutate world enemies",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "SPAWN_MULTIPLIER", label = "Spawn multiplier", type = "number",
              default = 1, min = 1, max = 8, step = 1, format = "%.0fx" },
            { key = "MAX_ACTIVE_EXTRAS", label = "Maximum extras", type = "number",
              default = 48, min = 0, max = 200, step = 4, format = "%.0f" },
            { key = "SPAWN_RADIUS", label = "Spawn radius", type = "number",
              default = 300, min = 100, max = 1500, step = 50, format = "%.0f cm" },
            -- Bounds mirror the DESPAWN_RADIUS rule in WorldEnemyDirector.
            { key = "DESPAWN_RADIUS", label = "Despawn distance", type = "number",
              default = 6000, min = 1500, max = 30000, step = 500,
              format = "%.0f cm" },
            { key = "RANDOMIZE_EXTRA_SPECIES", label = "Random extra species",
              type = "bool", default = false },
            { key = "INCLUDE_BOSSES", label = "Mutate bosses",
              type = "bool", default = false },
            { key = "SCALE_MIN", label = "Minimum scale", type = "number",
              default = 1.0, min = 0.25, max = 4.0, step = 0.25,
              format = "%.2fx", ceilingKey = "SCALE_MAX" },
            { key = "SCALE_MAX", label = "Maximum scale", type = "number",
              default = 1.0, min = 0.25, max = 4.0, step = 0.25,
              format = "%.2fx", floorKey = "SCALE_MIN" },
            { key = "COLOR_MODE", label = "Colour mode", type = "choice",
              default = "off", options = {
                  { value = "off", label = "Off" },
                  { value = "fixed", label = "Fixed" },
                  { value = "random", label = "Random" },
              } },
            { key = "COLOR_PRESET", label = "Colour preset", type = "choice",
              default = "crimson", options = {
                  { value = "crimson", label = "Crimson" },
                  { value = "emerald", label = "Emerald" },
                  { value = "azure", label = "Azure" },
                  { value = "gold", label = "Gold" },
                  { value = "violet", label = "Violet" },
                  { value = "cyan", label = "Cyan" },
                  { value = "white", label = "White" },
              } },
            { key = "HEALTH_MULTIPLIER", label = "Health", type = "number",
              default = 1.0, min = 0.1, max = 10.0, step = 0.1, format = "%.1fx" },
            { key = "ATTACK_MULTIPLIER", label = "Attack", type = "number",
              default = 1.0, min = 0.1, max = 10.0, step = 0.1, format = "%.1fx" },
            { key = "DEFENCE_MULTIPLIER", label = "Defence", type = "number",
              default = 1.0, min = 0.1, max = 10.0, step = 0.1, format = "%.1fx" },
            { key = "MOVE_SPEED_MULTIPLIER", label = "Movement speed", type = "number",
              default = 1.0, min = 0.25, max = 3.0, step = 0.05, format = "%.2fx" },
            { key = "XP_MULTIPLIER", label = "Experience", type = "number",
              default = 1.0, min = 0.0, max = 10.0, step = 0.1, format = "%.1fx" },
            { key = "DEBUG_LOGS", label = "Debug logging",
              type = "bool", default = false },
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
