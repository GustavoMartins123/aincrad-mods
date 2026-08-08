-- ModMenu contract for WorldEnemyDirector.
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
    label = "Enemy Director",
    summary = "Multiply and mutate world enemies",
    apply = "live",
    settings = {
        { key = "ENABLED", label = "Enabled", type = "bool", default = true },
        { key = "SPAWN_MULTIPLIER", label = "Spawn multiplier", type = "number", default = 1, min = 1, max = 8, step = 1, format = "%.0fx" },
        { key = "MAX_ACTIVE_EXTRAS", label = "Maximum extras", type = "number", default = 48, min = 0, max = 200, step = 4, format = "%.0f" },
        { key = "SPAWN_RADIUS", label = "Spawn radius", type = "number", default = 300, min = 100, max = 1500, step = 50, format = "%.0f cm" },
        { key = "DESPAWN_RADIUS", label = "Despawn distance", type = "number", default = 6000, min = 1500, max = 30000, step = 500, format = "%.0f cm" },
        { key = "SPAWN_IN_EMPTY_AREAS", label = "Spawn in empty areas", type = "bool", default = true },
        { key = "RANDOMIZE_EXTRA_SPECIES", label = "Random extra species", type = "bool", default = false },
        { key = "INCLUDE_BOSSES", label = "Mutate bosses", type = "bool", default = false },
        { key = "SCALE_MIN", label = "Minimum scale", type = "number", default = 1, min = 0.25, max = 4, step = 0.25, format = "%.2fx", ceilingKey = "SCALE_MAX" },
        { key = "SCALE_MAX", label = "Maximum scale", type = "number", default = 1, min = 0.25, max = 4, step = 0.25, format = "%.2fx", floorKey = "SCALE_MIN" },
        { key = "COLOR_MODE", label = "Colour mode", type = "choice", default = "off",
          options = {
              { value = "off", label = "Off" },
              { value = "fixed", label = "Fixed" },
              { value = "random", label = "Random" },
          } },
        { key = "COLOR_PRESET", label = "Colour preset", type = "choice", default = "crimson",
          options = {
              { value = "crimson", label = "Crimson" },
              { value = "emerald", label = "Emerald" },
              { value = "azure", label = "Azure" },
              { value = "gold", label = "Gold" },
              { value = "violet", label = "Violet" },
              { value = "cyan", label = "Cyan" },
              { value = "white", label = "White" },
          } },
        { key = "COMMON_HEALTH_MULTIPLIER", label = "Common | Health", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "COMMON_ATTACK_MULTIPLIER", label = "Common | Attack", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "COMMON_DEFENCE_MULTIPLIER", label = "Common | Defence", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "COMMON_MOVE_SPEED_MULTIPLIER", label = "Common | Movement speed", type = "number", default = 1, min = 0.25, max = 3, step = 0.05, format = "%.2fx" },
        { key = "COMMON_XP_MULTIPLIER", label = "Common | Experience", type = "number", default = 1, min = 0, max = 10, step = 0.1, format = "%.1fx" },
        { key = "ELITE_HEALTH_MULTIPLIER", label = "Elite | Health", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "ELITE_ATTACK_MULTIPLIER", label = "Elite | Attack", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "ELITE_DEFENCE_MULTIPLIER", label = "Elite | Defence", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "ELITE_MOVE_SPEED_MULTIPLIER", label = "Elite | Movement speed", type = "number", default = 1, min = 0.25, max = 3, step = 0.05, format = "%.2fx" },
        { key = "ELITE_XP_MULTIPLIER", label = "Elite | Experience", type = "number", default = 1, min = 0, max = 10, step = 0.1, format = "%.1fx" },
        { key = "BOSS_HEALTH_MULTIPLIER", label = "Boss | Health", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "BOSS_ATTACK_MULTIPLIER", label = "Boss | Attack", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "BOSS_DEFENCE_MULTIPLIER", label = "Boss | Defence", type = "number", default = 1, min = 0.1, max = 10, step = 0.1, format = "%.1fx" },
        { key = "BOSS_MOVE_SPEED_MULTIPLIER", label = "Boss | Movement speed", type = "number", default = 1, min = 0.25, max = 3, step = 0.05, format = "%.2fx" },
        { key = "BOSS_XP_MULTIPLIER", label = "Boss | Experience", type = "number", default = 1, min = 0, max = 10, step = 0.1, format = "%.1fx" },
        { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = false },
    },
}
