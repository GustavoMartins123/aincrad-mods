-- ModMenu contract for FastTravelMod.
--
-- ModMenu discovers this file by walking the Mods folder; nothing outside this
-- mod needs to know it exists. Every key below must match a key this mod's
-- config.lua actually defines, and the bounds must match its own validator --
-- a manifest that has drifted from the config is skipped, not shown.
--
--   label    row label in the menu.
--   summary  one line shown under the label.
--   apply    "live" | "menu" | "restart"
--   settings tunables, in display order. ENABLED is required.

return {
    label = "Fast Travel",
    summary = "Teleport to selected checkpoints and map pins",
    apply = "menu",
    settings = {
        { key = "ENABLED", label = "Enabled", type = "bool", default = true },
        { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = false },
    },
}
