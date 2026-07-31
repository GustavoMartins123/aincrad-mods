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

### Which layer it draws on

Each cockpit gauge assembly (`PlayerUnitGauge_HP`, `PlayerUnitGauge_Stamina`,
`PlayerUnitGauge_Soul`) owns a CanvasPanel, but a readout parented *inside* one
is painted with that assembly — and the assembly's canvas is painted before the
gauge widget sitting next to it. No ZOrder inside that canvas can lift a number
above art that is not in the canvas, which is why centring the readouts on the
bars first put them behind the bars.

`READOUT_LAYER = "front"` (the default) parents everything to the cockpit's own
`UnitGauge` canvas instead. That canvas holds the three assemblies, so a child
added there is painted after all of them. It needs the assembly's own rectangle
in that canvas to position against; when that cannot be read, the mod falls back
to `"gauge"` — living inside the assembly, where it fades with the bar it
belongs to but is painted behind the art.

`READOUT_PLACEMENT = "center"` (the default) puts each number on top of its own
bar. It is expressed as a **normalised anchor** on that gauge's canvas — the
middle of the canvas is the middle of the canvas at any resolution, whether or
not the mod managed to measure anything — so it lands correctly on its own, and
the bars being different lengths stops mattering.

`READOUT_PLACEMENT = "right"` puts the numbers off the end of the bars instead.
That one *does* need geometry, read from the gauge's own CanvasPanelSlot through
`WidgetLayoutLibrary.SlotAsCanvasSlot`, and because the three HUD bars are
different lengths it comes out as a staircase unless `ALIGN_READOUTS` (on by
default) puts every readout on the column just past the longest bar.

`TEXT_OFFSET_X` / `TEXT_OFFSET_Y` are corrections on top of either.

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

`EXP_ANCHOR` picks which gauge it is positioned against and parented to, so it
shares that gauge's coordinate space and always lines up with it.
`EXP_PLACEMENT` picks which edge it hangs off, again as a normalised anchor that
needs no measurement: `"above"` puts the bar's bottom edge on the gauge's top
edge, `"below"` puts its top edge on the gauge's bottom edge. `EXP_OFFSET_Y` is
a nudge from there. Zero width or height copies the anchor bar's own, which is
what keeps all four bars looking like one set — only the SIZE has a fallback if
the anchor bar could not be measured.

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
    READOUT_LAYER = "front",        -- "front" | "gauge"
    READOUT_PLACEMENT = "center",   -- "center" | "right"
    ALIGN_READOUTS = true,          -- only used by "right"
    VALUE_FORMAT = "current_max",   -- "current_max" | "current" | "percent"
    TEXT_OFFSET_X = 0.0,
    TEXT_OFFSET_Y = 0.0,
    FONT_SIZE = 13.0,

    SHOW_EXP = true,
    SHOW_EXP_BAR = true,
    SHOW_EXP_TEXT = true,
    SHOW_EXP_LEVEL = true,
    EXP_STYLE = "native",           -- "native" | "flat"
    EXP_ANCHOR = "hp",              -- "hp" | "stamina" | "sp"
    EXP_PLACEMENT = "above",        -- "above" | "below"
    EXP_OFFSET_X = 0.0,
    EXP_OFFSET_Y = -4.0,
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

## Tuning and diagnosis

Every injection writes one line per widget to `UE4SS.log`, with no debug flag
needed — this is what a misplaced readout is diagnosed from:

```text
READOUT | HP attached | layer=front | unit x=… y=… w=… h=… + gauge x=… | z=…
EXPERIENCE | native bar above hp | layer=front | at …,… (…x…) | z=… | anchor …
```

`layer=gauge` means the front layer could not be resolved, `unmeasured` means no
rectangle could be read at all, and the `native`/`flat` word says whether the
copy of the game's gauge was made. A settings change re-injects immediately, so
tuning offsets is live through the ModMenu.

For the layout itself, the UE4SS console command

```text
gaugenumbers probe
```

walks the cockpit's real widget tree — `cockpit.UnitGauge` and each assembly —
and logs every node with its slot type, ZOrder, position and size. Deducing that
tree from the SDK headers got the draw order wrong twice: a header lists a
class's members, not which of them parents which.

If a gauge assembly or its canvas is absent, the mod reports the exact missing
contract once and leaves the HUD untouched rather than drawing a substitute
overlay.
