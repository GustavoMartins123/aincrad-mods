-- AutoPickupMod settings.
-- Edit and save: the change applies in-game within about a second, no restart.
-- The in-game Mods menu writes to runtime.lua instead, which is applied on top
-- of this file, so anything you change in the menu wins until you reset it there.

return {
    ENABLED = true,

    -- Pickup radius in centimeters. 100 = 1 meter.
    PICKUP_RANGE = 1000,

    -- How far away the pickup icon is still drawn, in centimeters.
    ICON_DISPLAY_RANGE = 1500,

    -- The small "obtained X" notification.
    SHOW_PICKUP_UI = true,

    -- Seconds between pickup sweeps. Lower is more responsive and more costly.
    PICKUP_INTERVAL = 0.3,

    -- Patch the icon's own display distance so it matches ICON_DISPLAY_RANGE.
    -- Turn off to leave the game's authored icon distance alone.
    ICON_RANGE_PATCH = true,

    -- Grow each item's OperatableArea so the pickup prompt reaches as far as
    -- PICKUP_RANGE does.
    EXPAND_OPERATABLE = true,

    -- Verbose hook/state logging in the UE4SS console.
    DEBUG_HOOKS = false,
}
