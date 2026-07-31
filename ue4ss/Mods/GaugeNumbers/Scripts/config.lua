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

    -- Which layer the READOUTS draw on. This does not affect the experience
    -- bar, which has its own arrangement and stays put.
    --   "front"  -> the cockpit's UnitGauge canvas, which holds the three gauge
    --               assemblies. Painted AFTER all of them, so this is the only
    --               layer where a number can sit ON a bar instead of behind its
    --               art. Positioned from the HP_X/Y pairs below.
    --   "inside" -> the gauge widget's own root panel.
    --   "gauge"  -> the assembly canvas the gauge sits in.
    -- Both of the latter are painted before the gauge art, so a centred number
    -- lands behind the bar there; they are only useful with
    -- READOUT_PLACEMENT = "right", which puts the number clear of the art.
    -- Whatever is chosen, the mod falls back to "gauge" if that canvas will not
    -- take the widget -- attaching is the only honest test that it can.
    READOUT_LAYER = "front",

    -- Where each readout sits on that canvas, in its design-space pixels.
    -- These are the centre of each bar, and design space does not change with
    -- resolution, so one set of numbers holds everywhere. With
    -- READOUT_PLACEMENT = "center" the number is centred on the point; with
    -- "right" the point is its left edge.
    -- Tune these live from the in-game Mods menu until they sit right.
    HP_X = 198.0,
    HP_Y = 92.0,
    STAMINA_X = 189.0,
    STAMINA_Y = 126.0,
    SP_X = 161.0,
    SP_Y = 155.0,

    -- Where each number sits.
    --   "center" -> on top of its own bar, centred. Needs no measurement to be
    --               right, and the bars being different lengths stops
    --               mattering.
    --   "right"  -> off the end of the bar, outside the HUD.
    READOUT_PLACEMENT = "center",

    -- Only used by "right". The three HUD bars have different lengths, so a
    -- readout parked at the end of each one comes out as a staircase. This
    -- lines all three up on the column just past the longest bar instead.
    ALIGN_READOUTS = true,

    -- How the readouts are written.
    --   "current_max" -> 280 / 280
    --   "current"     -> 280
    --   "percent"     -> 100%
    VALUE_FORMAT = "current_max",

    -- Correction applied to ALL THREE readouts, on top of the points above.
    -- The points describe where the bars actually are; this absorbs the
    -- constant offset between that and where the text lands, which measured
    -- the same on every bar (down and to the right of the point given).
    -- This is the pair to reach for first when the numbers sit slightly off:
    -- moving all three together is almost always what is wanted, and it is two
    -- controls instead of six.
    TEXT_OFFSET_X = -8.0,
    TEXT_OFFSET_Y = -18.0,

    -- Font height of the readouts. The typeface is borrowed from the partner
    -- name plate so it matches the rest of the HUD.
    FONT_SIZE = 11.0,

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

    -- Which gauge the experience bar is positioned against, and parented to.
    -- It shares that gauge's coordinate space, so it always lines up with it,
    -- and it fades in and out with the rest of the HUD.
    --   "hp" | "stamina" | "sp"
    EXP_ANCHOR = "hp",

    -- Which edge of that gauge it hangs off.
    --   "above" -> the bar's bottom edge sits on the gauge's top edge
    --   "below" -> the bar's top edge sits on the gauge's bottom edge
    -- This is a normalised anchor, so it lands correctly without depending on
    -- any measurement.
    EXP_PLACEMENT = "above",

    -- Fine adjustment on that edge. Negative Y moves further up.
    EXP_OFFSET_X = 0.0,
    EXP_OFFSET_Y = -4.0,

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
