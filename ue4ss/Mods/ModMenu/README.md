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

## Diagnostics

The UE4SS console exposes read-only status and diagnostics:

```
modmenu list                              show every mod and its current values
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

## Three rules learned the crash way

**Never construct a widget of a watched class.** The panel originally created its
own `WBP_Console_MainMenu_C` to use as a blank canvas. That is the exact class
both mods watch with `NotifyOnNewObject`, so creating one made *both* of them try
to inject a rail row into a widget that had never been constructed or added to
the viewport. Reading its null `Slot` crashed the game outright
(`EXCEPTION_ACCESS_VIOLATION` on a tiny address). The panel now draws into the
menu that is already on screen and creates nothing but `TextBlock`s and an
`Image`. Field Equipment survives making its own clone only because it sets an
internal flag to skip its own notification — a flag ModMenu cannot reach from a
separate Lua state.

**Never write an out-of-range `CurrentIndex`.** That field is the native list's
cursor into `Item_0..Item_6`. The Mods row sits past the end of that array, so
writing its index points the game's own Blueprint at a row that does not exist.
`focusIcon` only writes values the array can hold; the row's highlight comes from
the widget calls, not the cursor.

**Do engine work on the game thread.** Input arrives through `ExecuteWithDelay`,
which runs on the async thread. Constructing UObjects or editing the widget tree
from there is the other reliable way to crash. Everything that touches the engine
goes through `ExecuteInGameThread` first.
