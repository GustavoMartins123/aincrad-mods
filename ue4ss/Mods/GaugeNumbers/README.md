# Gauge Numbers

Gauge Numbers is a configurable HUD enhancement for Echoes of Aincrad.

It adds live numeric readouts to the game's existing HP, Stamina and SP gauges and can also add an experience display with the current level, experience progress and an optional gauge-style bar.

The mod does not change player attributes, regeneration, damage, stamina consumption or experience rewards. It only reads values already maintained by the game and presents them on the HUD.

The default layout is only a starting point. Every readout can be enabled independently, reformatted and repositioned, and the experience display can be arranged separately from the three status gauges.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

The [Echoes of Aincrad Mod Menu](https://www.nexusmods.com/echoesofaincrad/mods/84) is optional.

Gauge Numbers includes its own private settings bridge and works as a standalone installation.

## Installation

Copy the complete `GaugeNumbers` folder to:

```text
[Your Game Folder]\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\
```

The final layout should include:

```text
GaugeNumbers\
├── enabled.txt
├── README.md
└── Scripts\
    ├── config.lua
    ├── main.lua
    ├── main_impl.lua
    ├── modmenu.lua
    └── standalone\
        └── ModMenuBridge.lua
```

Confirm that this file exists:

```text
ue4ss\Mods\GaugeNumbers\Scripts\main.lua
```

Fully restart the game after installing or updating the mod.

Do not include `runtime.lua`, `runtime.lua.*`, `runtime.rev` or the transient
`preview.lua*` files when redistributing the mod.

## Main Features

- Displays live HP values.
- Displays live Stamina values.
- Displays live SP values.
- Supports `current / maximum`, current-only and percentage formats.
- Allows each status readout to be enabled independently.
- Supports centred readouts or values placed beside the gauges.
- Allows global offsets and individual design-space positions to be adjusted.
- Can add the current level and experience progress to the HUD.
- Can use a copy of the game's native gauge widget for the experience bar.
- Falls back to a simple flat experience bar when the native gauge cannot be created safely.
- Allows the experience display to be anchored to HP, Stamina or SP.
- Supports live configuration through the optional in-game Mod Menu.
- Shows the game's native player gauges temporarily while Gauge Numbers is
  expanded in that menu, then restores their previous visibility.
- Works without the Mod Menu through `Scripts\config.lua`.

## Usage

No manual activation is required.

After loading into the game, the configured readouts are attached to the existing cockpit HUD. They follow the visibility and lifecycle of the game's own gauges.

The default format is:

```text
280 / 280
```

The experience display can show:

```text
Lv.52   615 / 24000
```

The orange gauge is called Stamina in this mod and Vigor in some parts of the game's interface. SP is the cyan Soul gauge.

## Optional In-Game Configuration

For easier tuning, install:

[Echoes of Aincrad Mod Menu](https://www.nexusmods.com/echoesofaincrad/mods/84)

Open the Start Menu, select **Mods**, and expand **Gauge Numbers**.

Changes are applied by rebuilding only the widgets created by this mod. The game's original HUD widgets are not replaced.

Without the Mod Menu, edit:

```text
GaugeNumbers\Scripts\config.lua
```

## Configuration

The complete default configuration is:

```lua
return {
    ENABLED = true,

    SHOW_HP = true,
    SHOW_STAMINA = true,
    SHOW_SP = true,

    READOUT_LAYER = "front",

    HP_X = 198.0,
    HP_Y = 92.0,
    STAMINA_X = 189.0,
    STAMINA_Y = 126.0,
    SP_X = 161.0,
    SP_Y = 155.0,

    READOUT_PLACEMENT = "center",
    ALIGN_READOUTS = true,
    VALUE_FORMAT = "current_max",

    TEXT_OFFSET_X = -8.0,
    TEXT_OFFSET_Y = -18.0,
    FONT_SIZE = 11.0,

    SHOW_EXP = true,
    SHOW_EXP_BAR = true,
    SHOW_EXP_TEXT = true,
    SHOW_EXP_LEVEL = true,

    EXP_STYLE = "native",
    EXP_ANCHOR = "hp",
    EXP_PLACEMENT = "above",

    EXP_OFFSET_X = 0.0,
    EXP_OFFSET_Y = -4.0,
    EXP_BAR_WIDTH = 0.0,
    EXP_BAR_HEIGHT = 0.0,

    REFRESH_MS = 500,
    DEBUG_LOGS = false,
}
```

### Status Readouts

The following switches control which values are displayed:

```text
SHOW_HP
SHOW_STAMINA
SHOW_SP
```

`VALUE_FORMAT` accepts:

```text
current_max   280 / 280
current       280
percent       100%
```

`READOUT_PLACEMENT` accepts:

```text
center   places the number over its gauge
right    places the number beside the gauge
```

`ALIGN_READOUTS` aligns the three values into one column when `READOUT_PLACEMENT` is set to `right`.

### Readout Layers

`READOUT_LAYER` accepts:

```text
front    draws on the cockpit gauge canvas, in front of the gauge assemblies
inside   attempts to attach inside the gauge widget
 gauge   attaches to the gauge assembly canvas
```

`front` is the recommended default for centred text.

The `inside` and `gauge` layers can be useful for alternative layouts, but the gauge artwork may draw over centred text. The mod falls back safely when a selected layer cannot accept the widget.

### Positioning

The individual positions are:

```text
HP_X / HP_Y
STAMINA_X / STAMINA_Y
SP_X / SP_Y
```

These values use the HUD's design-space coordinates rather than physical monitor pixels. The defaults match the current game HUD, but they remain configurable for custom layouts and future interface changes.

Use these first for broad positioning:

```text
TEXT_OFFSET_X
TEXT_OFFSET_Y
```

They move all three status readouts together without changing their relative spacing.

`FONT_SIZE` controls the numeric text size.

### Experience Display

`SHOW_EXP` controls the complete experience block.

Its individual parts can also be controlled through:

```text
SHOW_EXP_BAR
SHOW_EXP_TEXT
SHOW_EXP_LEVEL
```

`EXP_STYLE` accepts:

```text
native   uses a copy of the game's own gauge widget
flat     uses a simple backing and fill drawn by the mod
```

The native style is preferred. If it cannot be created, the mod automatically uses the flat style instead.

`EXP_ANCHOR` accepts:

```text
hp
stamina
sp
```

`EXP_PLACEMENT` accepts:

```text
above
below
```

Use `EXP_OFFSET_X` and `EXP_OFFSET_Y` for fine positioning.

When `EXP_BAR_WIDTH` or `EXP_BAR_HEIGHT` is `0`, the mod copies the dimensions of the selected anchor gauge. Non-zero values allow a custom size.

### Refresh Interval

The HP, Stamina and SP readouts are updated immediately through the game's own gauge-change events.

`REFRESH_MS` controls a separate reconciliation pass that:

- recovers after map or HUD reconstruction;
- fills newly attached readouts immediately;
- refreshes experience progress;
- corrects a value if a native event was missed.

The default is `500` milliseconds.

## How It Works

The mod hooks the native cockpit gauge events:

```text
OnHealthChangedEvent
OnStaminaChangedEvent
OnSoulChangedEvent
```

The hook parameters are read synchronously while the native call is active. They are not retained or used by delayed callbacks.

The mod also reads the player's current attribute sets during reconciliation so newly created widgets do not remain empty until the next value change.

Experience information is read from the local player state's experience data. The mod displays progress into the current level and uses the game's own next-level requirement when available.

All added widgets are non-interactive and cannot consume mouse, keyboard or controller input.

## Diagnostics

Run the following command in the UE4SS console:

```text
gaugenumbers probe
```

The command writes the live cockpit gauge tree, slot types, positions, sizes and Z-order information to:

```text
UE4SS.log
```

This is useful when tuning offsets or diagnosing a game update that changed the HUD layout.

The UE4SS console requires:

```text
GuiConsoleEnabled = 1
```

under the `[Debug]` section of:

```text
UE4SS-settings.ini
```

Enable `DEBUG_LOGS` for additional resolution, experience and injection diagnostics.

## Known Limitations

- The default coordinates are based on the current Echoes of Aincrad HUD.
- Large interface changes from future game updates may require new default positions.
- Alternative HUD scaling, ultrawide layouts or other HUD mods may require offset adjustments.
- The native experience bar depends on a compatible gauge widget being available in the mounted cockpit.
- When the native bar cannot be created, the flat fallback is used.
- The mod displays the values reported by the game and does not alter or correct gameplay calculations.

## Credits

Built for UE4SS.

Echoes of Aincrad and all related game assets and trademarks belong to their respective owners.
