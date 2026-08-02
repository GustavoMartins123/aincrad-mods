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
    -- This gates which spawns are issued; it is not the sleep distance.
    DESPAWN_RADIUS = 6000.0,

    -- Beyond COMBAT_RADIUS centimetres an extra is put to sleep: its
    -- behaviour tree stops and its tick slows right down. An enemy costs an
    -- AI controller, a behaviour tree, perception, movement and a full
    -- ability system whether or not you can see it, and Unreal's visual
    -- culling reduces none of that -- only this does.
    --
    -- An extra that is fighting, dying, or on screen is never put to sleep,
    -- whatever the distance, and sleeping never destroys anything.
    COMBAT_RADIUS = 8000.0,

    -- Set false to keep every extra at full simulation, whatever the distance.
    LOD_ENABLED = true,
    -- Seconds between ticks of a sleeping extra.
    LOD_DORMANT_TICK_S = 0.5,
    -- Slack around the edge so an extra standing exactly on the boundary does
    -- not flip state every scan.
    LOD_HYSTERESIS_CM = 1000.0,

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

    -- EnemyRole_None and EnemyRole_Mob.
    COMMON_HEALTH_MULTIPLIER = 1.0,
    COMMON_ATTACK_MULTIPLIER = 1.0,
    COMMON_DEFENCE_MULTIPLIER = 1.0,
    COMMON_MOVE_SPEED_MULTIPLIER = 1.0,
    COMMON_XP_MULTIPLIER = 1.0,

    -- EnemyRole_Elite.
    ELITE_HEALTH_MULTIPLIER = 1.0,
    ELITE_ATTACK_MULTIPLIER = 1.0,
    ELITE_DEFENCE_MULTIPLIER = 1.0,
    ELITE_MOVE_SPEED_MULTIPLIER = 1.0,
    ELITE_XP_MULTIPLIER = 1.0,

    -- EnemyRole_Boss. Applied only while INCLUDE_BOSSES is true.
    BOSS_HEALTH_MULTIPLIER = 1.0,
    BOSS_ATTACK_MULTIPLIER = 1.0,
    BOSS_DEFENCE_MULTIPLIER = 1.0,
    BOSS_MOVE_SPEED_MULTIPLIER = 1.0,
    BOSS_XP_MULTIPLIER = 1.0,

    POLL_MS = 500,
    DEBUG_LOGS = false,
}
