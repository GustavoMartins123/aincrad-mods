# ModMenu

A **Mods** entry in Echoes of Aincrad's start menu. Enable or disable the other
mods and retune their values without leaving the game.

Open the start menu, go down past the last entry to **Mods**, press Enter.
`Up/Down` moves, `Enter` expands a mod or toggles a switch, `Left/Right` changes
a value, `Back`/`Esc` closes.

```
MODS

  - Speed                          ON
      Starting speed          < 1.40x >
      Top speed               < 3.20x >
      Time to top speed       < 1.80s >
      Off during combat            ON
  + Auto Pickup                    ON
  + No Rescue                      ON
  + Field Equipment +              ON
  + Open World *                   ON

  * restart required    + reopen menu
```

## How a change reaches the other mod

UE4SS gives every Lua mod its own isolated state, so ModMenu cannot call into
SpeedMod directly. It writes the value to that mod's `Scripts/runtime.lua`, and
the mod picks it up itself through `Mods/shared/ModMenuBridge.lua`, which watches
its settings files on a slow poll. Nothing is shared in memory.

Two files per mod, both optional:

| file | written by | role |
|------|-----------|------|
| `Scripts/config.lua` | you, in a text editor | documented defaults, never rewritten by ModMenu |
| `Scripts/runtime.lua` | ModMenu | applied on top of `config.lua`, so it always wins |

`config.lua` keeps its comments and stays the place to set defaults. **Reset**
deletes the overrides and hands control back to it. Editing `config.lua` by hand
while the game runs also hot-reloads — no restart needed for that either.

## When a change takes effect

Most values apply within about a second. Two mods are marked because they
honestly cannot:

- **`+` Field Equipment** — its row is injected as the start menu is *built*, so
  an `ENABLED` change lands the next time you open the menu.
- **`*` Open World** — it opens a floor by growing arrays on each quest manifest
  as that manifest is constructed. Switching it off cannot retract a floor that
  is already open, so it takes a restart.

## Console

Everything the panel does is also reachable from the UE4SS console, which is the
fallback if the panel fails to build on a given game build:

```
modmenu list                              show every mod and its current values
modmenu set SpeedMod START_SPEED 1.8      change one value (bounds enforced)
modmenu set norescue ENABLED off          on/off for switches
modmenu reset SpeedMod                    drop overrides, back to config.lua
modmenu open | close                      drive the panel
modmenu probe                             dump the widget tree to the UE4SS log
modmenu buttons                           log the button codes the panel receives
```

The console needs `GuiConsoleEnabled = 1` under `[Debug]` in `UE4SS-settings.ini`.

## Adding a mod to the menu

Two steps.

1. Add an entry to `Scripts/registry.lua` naming the mod's folder, its settings,
   and their bounds. Keep the bounds matched to whatever the mod already clamps
   internally, so the menu can never ask for a value the mod will reject.
2. In that mod's `main.lua`, attach to the bridge:

```lua
local bridge = -- see the loader block in any of the other mods
bridge.attach({
    modName = "YourMod",
    scriptDir = SCRIPT_DIR,
    load = applyExternalConfig,  -- your existing config.lua parser
    apply = pushValuesIntoTheGame, -- optional; runs on the game thread
})
```

`load` receives the merged `config.lua` + `runtime.lua` table and should validate
it exactly as the mod already does at startup — that same validation is what
guards against a bad value arriving from the menu.

## Sitting next to Field Equipment

Both mods append a row to the same start-menu rail. The native list's TArrays
cannot be grown from UE4SS Lua, so each row is a MenuIcon clone parked in a donor
wrapper, sitting outside the list's own arrays, with only the navigation
boundaries bridged.

That means the two mods have to agree on order. ModMenu counts the rows already
on the rail and places itself underneath, and `FieldEquipmentMod` was changed to
stop assuming it is the final row: it now looks for a row below it and hands
focus over instead of wrapping to the top. With ModMenu absent that code path
collapses back to the original behavior, so Field Equipment still works alone.

ModMenu injects on a 400ms delay against Field Equipment's 100ms, so the rows it
counts are already in place.
