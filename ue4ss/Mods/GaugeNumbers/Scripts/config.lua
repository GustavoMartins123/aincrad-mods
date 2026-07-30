-- GaugeNumbers settings.
-- The in-game Mods menu writes per-machine overrides to runtime.lua.

return {
    -- Master switch.
    ENABLED = true,

    --====================================================--
    --                  GAUGE READOUTS                    --
    --====================================================--

    -- Which cockpit gauges get a live "current / max" readout.
    -- HP is the green bar, Stamina the orange one (the game's "Vigor"),
    -- SP the cyan one.
    SHOW_HP = true,
    SHOW_STAMINA = true,
    SHOW_SP = true,

    -- The three HUD bars have different lengths, so a readout parked at the
    -- end of each one comes out as a staircase. This lines all three up on the
    -- column just past the longest bar instead. Turn it off to put each number
    -- back at the end of its own bar.
    ALIGN_READOUTS = true,

    -- How the readouts are written.
    --   "current_max" -> 280 / 280
    --   "current"     -> 280
    --   "percent"     -> 100%
    VALUE_FORMAT = "current_max",

    -- Fine adjustment on a position the mod already measured from the game's
    -- own layout. Positive X moves right, positive Y moves down.
    TEXT_OFFSET_X = 14.0,
    TEXT_OFFSET_Y = 0.0,

    -- Font height of the readouts. The typeface is borrowed from the partner
    -- name plate so it matches the rest of the HUD.
    FONT_SIZE = 13.0,

    --====================================================--
    --                  EXPERIENCE BAR                    --
    --====================================================--

    -- Master switch for the whole experience block.
    SHOW_EXP = true,

    -- The three parts of it, individually.
    SHOW_EXP_BAR = true,      -- the bar itself
    SHOW_EXP_TEXT = true,     -- the numbers beside it
    SHOW_EXP_LEVEL = true,    -- the "Lv.52" prefix in those numbers

    -- How the bar is drawn.
    --   "native" -> a real copy of the game's own gauge widget, driven by the
    --               game's own gauge setters. Same art, same frame, same shader
    --               as the HP/Stamina/SP bars, recoloured. Falls back to "flat"
    --               on its own if the copy cannot be made.
    --   "flat"   -> two tinted rectangles drawn by the mod.
    EXP_STYLE = "native",

    -- Which bar the experience bar is positioned against, and parented to.
    -- It shares that bar's coordinate space, so it always lines up with it,
    -- and it fades in and out with the rest of the gauges.
    --   "hp" | "stamina" | "sp"
    EXP_ANCHOR = "hp",

    -- Offset from the TOP-LEFT corner of the anchor bar. Negative Y puts the
    -- experience bar above the gauges, positive Y below them.
    EXP_OFFSET_X = 0.0,
    EXP_OFFSET_Y = -26.0,

    -- Experience bar geometry. Zero copies the anchor bar's own width and
    -- height, which is what keeps all four bars looking like one set.
    EXP_BAR_WIDTH = 0.0,
    EXP_BAR_HEIGHT = 0.0,

    --====================================================--

    -- Reconcile interval. The three gauge readouts are driven by the game's own
    -- change events and update instantly; this poll re-resolves the cockpit
    -- after a map change, re-injects anything the game rebuilt, refreshes the
    -- experience numbers, and re-stamps values in case an event was missed.
    REFRESH_MS = 500,

    -- Injection and resolution breadcrumbs in UE4SS.log. Turn this on to read
    -- the measured bar geometry when something lands in the wrong place.
    DEBUG_LOGS = false,
}
