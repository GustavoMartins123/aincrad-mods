-- Terrain Runner settings
-- 1.00 means normal game speed.

return {
    ENABLED = true,
    START_SPEED = 1.40,
    MAX_SPEED = 3.20,
    SECONDS_TO_MAX_SPEED = 1.80,
    -- Multiplies the physical jump apex. The mod derives the required vertical
    -- launch velocity, so 2.00 means approximately twice the native height.
    JUMP_HEIGHT_MULTIPLIER = 1.00,

    -- Recommended: keeps super speed for exploration only.
    DISABLE_IN_COMBAT = true,
}
