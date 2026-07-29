-- World Enemy Director
--
-- This is the canonical configuration. Every key is required and validated
-- strictly. The in-game Mods menu writes optional live overrides to runtime.lua.
return {
    ENABLED = true,

    -- 1 keeps the game's original population. Higher values add this many total
    -- enemies per natural spawn, up to the hard safety limit of 8.
    SPAWN_MULTIPLIER = 1,
    MAX_ACTIVE_EXTRAS = 48,
    SPAWN_RADIUS = 300.0,

    -- How far you can get from an extra before the director takes it back,
    -- in centimetres. Origins here are placed in the persistent level and
    -- never unload, so without this the extras from the first area you
    -- visit keep the whole budget forever and no new area gets any.
    -- Freed slots are handed back to their origin, so returning refills.
    DESPAWN_RADIUS = 6000.0,
    SPAWN_IN_EMPTY_AREAS = true,
    RANDOMIZE_EXTRA_SPECIES = false,
    INCLUDE_BOSSES = false,

    SCALE_MIN = 1.0,
    SCALE_MAX = 1.0,

    -- COLOR_MODE: "off", "fixed", or "random".
    -- COLOR_PRESET: "crimson", "emerald", "azure", "gold", "violet",
    --               "cyan", or "white".
    COLOR_MODE = "off",
    COLOR_PRESET = "crimson",
    COLOR_PARAMETER_NAME = "Color",

    HEALTH_MULTIPLIER = 1.0,
    ATTACK_MULTIPLIER = 1.0,
    DEFENCE_MULTIPLIER = 1.0,
    MOVE_SPEED_MULTIPLIER = 1.0,
    XP_MULTIPLIER = 1.0,

    POLL_MS = 500,
    DEBUG_LOGS = false,
}
