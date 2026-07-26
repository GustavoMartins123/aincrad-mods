# ModMenu

A **Mods** entry in Echoes of Aincrad's Start Menu. It enables or disables the
installed Lua mods and edits their supported settings without leaving the game.

Open the Start Menu, move below its final native or modded row to **Mods**, and
confirm. `Up/Down` moves, `Enter` expands a mod or toggles a switch,
`Left/Right` changes a value, and `Back`/`Esc` closes the panel.

```text
MODS

  - Speed                          ON
      Starting speed          < 1.40x >
      Top speed               < 3.20x >
  + Auto Pickup                    ON
  + No Rescue                      ON
  + Field Equipment +              ON
  + Enemy Director                 ON
  + Open World *                   ON

  * restart required    + reopen menu
```

The panel virtualises thirteen visible rows. Expanding a mod with more settings
automatically scrolls that fixed viewport, so controller navigation is
independent of the expanded list's length.

## How changes reach another mod

UE4SS gives each Lua mod an isolated state, so ModMenu cannot call another mod
directly. It writes values to that mod's exact `Scripts/runtime.lua` path. The
target mod watches and validates that file from its own state. Most existing
mods use `Mods/shared/ModMenuBridge.lua`; a mod with a stricter loader can own
the same file contract. Nothing is shared in memory.

| File | Written by | Role |
|---|---|---|
| `Scripts/config.lua` | Player or mod author | Canonical settings, never rewritten by ModMenu |
| `Scripts/runtime.lua` | ModMenu | Optional live overrides applied over `config.lua` |

**Reset** removes runtime overrides and returns control to `config.lua`.
Whether that file is required and whether hand edits hot-reload are contracts
owned and validated by each target mod.

## When changes take effect

Most values apply within about one second. Two mod labels carry a marker:

- `+` Field Equipment: its rail entry is added while the Start Menu is built,
  so close and reopen that menu after changing its enabled state.
- `*` Open World: it changes quest manifests while they are constructed. It
  cannot retract a floor that is already open and may require a restart.

The ON/OFF value on a mod header controls both the live `ENABLED` override and
the next-launch `enabled.txt` marker as one transaction. Enabling a script that
UE4SS did not load at startup still requires a complete game restart.

## Diagnostics

The UE4SS console exposes read-only commands:

```text
modmenu list       show every registered mod and its current values
modmenu probe      dump the live menu widget tree
modmenu buttons    log button codes received by the panel
```

The console requires `GuiConsoleEnabled = 1` under `[Debug]` in
`UE4SS-settings.ini`.

## Adding a mod

1. Add one entry to `Scripts/registry.lua`. The folder name and setting keys
   must exactly match the target mod. Numeric bounds must match its validator.
2. In the target mod, watch only its exact `Scripts/runtime.lua` path, merge it
   over `config.lua`, and validate the complete result before applying any
   value. A malformed or unsupported value must report an explicit error and
   leave the mod fail-closed.

Existing bridge users may attach through `ModMenuBridge`; a strict mod may
implement the same canonical file contract directly.

## Coexisting with Field Equipment

Both mods append a row to the same Start Menu rail. The native list's arrays
cannot be grown safely from UE4SS Lua, so each row is a `MenuIcon` clone in a
donor wrapper outside those native arrays. Only the navigation boundaries are
bridged.

ModMenu waits 400 ms before injecting, after Field Equipment's 100 ms delay,
then counts all rows already present and places itself below them. Field
Equipment hands downward focus to the next modded row; ModMenu owns both of its
boundaries and returns upward focus to the row directly above it.

While the settings panel is open, ModMenu consumes its directional, confirm,
and back inputs. The outer Start Menu does not receive those events.

## Crash-safety rules

- Never construct a widget of a class watched by `NotifyOnNewObject`. The panel
  draws into the live Start Menu and creates only `TextBlock` and `Image`
  children.
- Never write an out-of-range native `CurrentIndex`. The modded row sits beyond
  the authored `Item_0..Item_6` array; its highlight is controlled through the
  widget, not by lying to the native cursor.
- Perform UObject construction and widget-tree changes on the game thread.
  Input can arrive from UE4SS's asynchronous thread.
- Avoid **Restart All Mods** for this stack. Fully close and relaunch the game
  when scripts or hooks must be reloaded.
