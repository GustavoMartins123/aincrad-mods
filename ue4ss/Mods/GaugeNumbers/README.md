# Gauge Numbers

Puts the real values on Echoes of Aincrad's cockpit gauges — `280 / 280` beside
the HP, Stamina and SP bars — and adds an experience bar with the level and the
`current / until next level` numbers that otherwise only exist on the status
screen. The experience bar is drawn with a copy of the game's own gauge widget,
so it matches the rest of the HUD.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

The in-game ModMenu is optional. Gauge Numbers includes its own private settings
bridge and works when installed by itself.

## Installation

Copy the complete `GaugeNumbers` folder to:

```text
EchoesofAincrad\Binaries\Win64\ue4ss\Mods\GaugeNumbers
```

The installed layout must include:

```text
GaugeNumbers\
├── enabled.txt
├── README.md
└── Scripts\
    ├── main.lua
    ├── main_impl.lua
    ├── config.lua
    └── standalone\
        └── ModMenuBridge.lua
```

Restart the game after installing or enabling the mod.

## How it works

### The readouts follow the game's own events

`URODCockpitWidgetBase` raises one event per gauge whenever its value changes,
each carrying the new value and the maximum:

```text
OnHealthChangedEvent  (NewHealth,    MaxHealth)
OnStaminaChangedEvent (NewSp,        NewMaxSp)
OnSoulChangedEvent    (NewSoulValue, MaxSoul)
```

`WBP_Cockpit_C` does not override any of them, so the mod hooks the native class
and every instance is covered. The handlers run synchronously inside the event
on the game thread: the hook parameters point into the native call frame and are
dead the instant it returns, so they are read there and never captured. The
handlers resolve nothing and construct nothing — they only stamp a widget that
already exists.

A 500 ms reconcile poll owns everything else: resolving the cockpit, injecting
the widgets, refreshing the experience numbers, and re-reading
`DefensiveAttributeSet.Health` / `AttributeSet.Stamina` / `AttributeSet.Soul` so
a readout attached mid-fight is filled immediately and no missed event can leave
a stale number on screen.

### Placement is measured, not guessed

Each cockpit gauge assembly (`PlayerUnitGauge_HP`, `PlayerUnitGauge_Stamina`,
`PlayerUnitGauge_Soul`) owns a CanvasPanel. A `UTextBlock` is constructed into
that canvas, and its position comes from reading the gauge's own
CanvasPanelSlot through `WidgetLayoutLibrary.SlotAsCanvasSlot`.

The three HUD bars are different lengths, so a readout parked at the end of each
one comes out as a staircase. `ALIGN_READOUTS` (on by default) measures all
three in one pass and puts every readout on the column just past the longest
bar. `TEXT_OFFSET_X` / `TEXT_OFFSET_Y` are corrections on top of that.

The typeface is borrowed from the partner name plate so it matches the rest of
the HUD; without a partner mounted, the TextBlock's own default font is used.

Every assembly wraps itself in an `InvalidationBox`. A cached subtree keeps
repainting the text it was cached with, which would freeze each readout on its
first value, so caching is turned off on the assemblies the mod writes into.

### The experience bar

With `EXP_STYLE = "native"` the bar is a real instance of the game's own gauge
widget — same art, same frame, same shader as the HP/Stamina/SP bars, recoloured
through `SetGaugeColor`. The class comes from `GetClass()` on a gauge already
mounted in this cockpit, so there is no `LoadAsset` and no asset path that could
stop resolving after a patch.

The donor is deliberately `WBP_StaminaGauge_Player_C`: it is the only player
gauge with **no blueprint graph at all** — no `UberGraphFrame`, no `Construct`,
no `ExecuteUbergraph`. Copying the HP or SP gauge would run their construction
logic against a widget that has no avatar behind it. The copy is driven with
`ResetGaugeValue` / `ResetGaugeRate` rather than the `Set*` pair, because the
`Set*` path is the animated one that drives blink animations and the widget's
own timers; `Reset*` just states the value, which is all an experience bar
wants. If the copy cannot be made for any reason, the mod logs why and draws
`EXP_STYLE = "flat"` instead — two tinted rectangles, a backing and a fill
driven by its own slot width.

`EXP_ANCHOR` picks which bar it is positioned against and parented to, so it
shares that bar's coordinate space and always lines up with it. `EXP_OFFSET_Y`
is measured from the **top-left corner** of that bar: negative puts the
experience bar above the gauges (the default, `-26`), positive puts it below.
Zero width or height copies the anchor bar's own, which is what keeps all four
bars looking like one set.

`SHOW_EXP` switches the whole block; `SHOW_EXP_BAR`, `SHOW_EXP_TEXT` and
`SHOW_EXP_LEVEL` switch the bar, the numbers and the `Lv.52` prefix
individually.

### Experience values

`ARODPlayerState.ExperienceData` supplies the level and the experience, and
`GetNextHeroExp(level)` the requirement, refreshed only when the level changes.
The experience is read as progress *into* the current level, which is what the
status screen shows (`615 / 24000` at Lv.52). Should a build ever report it as a
running total instead, the previous level's requirement becomes the floor of the
current span and both numbers are rebased onto it — the only signal that can
distinguish the two without guessing is a current value that exceeds the
requirement, so the simple reading is preferred otherwise. Turn on `DEBUG_LOGS`
to see the raw level, requirement and floor in `UE4SS.log`.

### Lifecycle

The cockpit's own validity is the lifecycle. Its widgets die with it, so nothing
is torn down on a map change: the references are dropped once `IsValid` stops
answering, and the next poll rebuilds against the new cockpit. Reaching into
those widgets after the world changed would be a stale dereference, and a stale
dereference is an access violation that `pcall` cannot catch.

The widgets *are* detached properly on a settings change, which runs on the game
thread with the world live — geometry, styling and which widgets exist are baked
in at injection time, so a settings change has to rebuild them to be seen.

## Configuration

Edit `Scripts/config.lua` or use the optional in-game ModMenu:

```lua
return {
    ENABLED = true,

    SHOW_HP = true,
    SHOW_STAMINA = true,
    SHOW_SP = true,
    ALIGN_READOUTS = true,
    VALUE_FORMAT = "current_max",   -- "current_max" | "current" | "percent"
    TEXT_OFFSET_X = 14.0,
    TEXT_OFFSET_Y = 0.0,
    FONT_SIZE = 13.0,

    SHOW_EXP = true,
    SHOW_EXP_BAR = true,
    SHOW_EXP_TEXT = true,
    SHOW_EXP_LEVEL = true,
    EXP_STYLE = "native",           -- "native" | "flat"
    EXP_ANCHOR = "hp",              -- "hp" | "stamina" | "sp"
    EXP_OFFSET_X = 0.0,
    EXP_OFFSET_Y = -26.0,           -- negative is above the gauges
    EXP_BAR_WIDTH = 0.0,            -- 0 copies the anchor bar
    EXP_BAR_HEIGHT = 0.0,           -- 0 copies the anchor bar

    REFRESH_MS = 500,
    DEBUG_LOGS = false,
}
```

The Stamina bar is the orange one the HUD calls Vigor; SP is the cyan one.

When ModMenu is installed, machine-local overrides are written to
`Scripts/runtime.lua`. That file is optional and should not be included when
redistributing the mod.

## Tuning placement

The defaults are measured from the game's own layout, so nothing should need
tuning. If something lands in the wrong place, turn on `DEBUG_LOGS` and read the
`measured | x= y= w= h=` line each bar writes when the widgets are built. An
`unmeasured` line means that bar's slot could not be read and the mod fell back
to the canvas edge — that is when the offsets are worth changing. A settings
change re-injects immediately, so tuning is live through the ModMenu.

If a gauge assembly or its canvas is absent, the mod reports the exact missing
contract once and leaves the HUD untouched rather than drawing a substitute
overlay.
