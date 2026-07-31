# ModMenu

ModMenu **v1.5.6** adds a native-styled **Mods** entry to Echoes of Aincrad's
Start Menu. It enables or disables compatible UE4SS Lua mods and edits their
supported settings without leaving the game.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

ModMenu includes its own private settings bridge. It does not require the
suite-level `Mods/shared` folder and can be installed by itself.

## Installation

Copy the complete `ModMenu` folder to:

```text
EchoesofAincrad\Binaries\Win64\ue4ss\Mods\ModMenu
```

The installed layout must include:

```text
ModMenu\
├── enabled.txt
├── README.md
└── Scripts\
    ├── main.lua
    ├── main_impl.lua
    ├── config.lua
    ├── registry.lua
    ├── discovery.lua
    ├── store.lua
    ├── panel.lua
    └── standalone\
        └── ModMenuBridge.lua
```

Restart the game after installing, removing, or updating compatible mods.

## Usage

Open the Start Menu, move below its final native or modded row to **Mods**, and
confirm.

- `Up/Down` moves through the panel.
- `Enter` expands a mod or toggles a boolean setting.
- `Left/Right` changes a value or toggles a mod header.
- `Back` or `Esc` closes the panel.

```text
MODS

  - Speed                          ON
      Starting speed          < 1.40x >
      Top speed               < 3.20x >
  + Fast Travel                    ON
  + Enemy Director                 ON
  + XP Notifications               ON

  * restart required    + reopen menu
```

The panel virtualises twelve visible rows. Expanding a mod with more settings
automatically scrolls that fixed viewport, so controller navigation remains
independent of the expanded list's length.

## Automatic discovery and compatibility validation

There is no central list of supported mods. Every mod is self-contained: it
appears in this menu by shipping `Scripts/modmenu.lua` inside its own folder,
declaring its own label, settings, types, choices, numeric bounds, and when a
change takes effect -- next to the `config.lua` those settings live in.

At startup, `Scripts/registry.lua` enumerates every folder under `Mods/` through
`IterateGameDirectories` and validates each mod that opted in. A mod is shown
only if it has:

- `Scripts/main.lua`;
- `Scripts/config.lua`;
- `Scripts/modmenu.lua` declaring its contract;
- a readable and valid effective configuration;
- an `ENABLED` boolean setting;
- every declared setting present with the expected type;
- numeric values inside the declared bounds;
- choice values present in the declared option list;
- valid cross-setting floor and ceiling relationships.

Opting in is not the same as being accepted. The manifest is checked against the
mod's real effective settings, so a contract that has drifted from the config it
describes is skipped with one concise reason in `UE4SS.log` rather than shown.
It cannot make the entire panel fail to open. A folder without a
`Scripts/modmenu.lua` simply has nothing to show and is passed over silently.

Discovery runs when ModMenu starts. Restart the game after adding, removing, or
updating a mod.

## How changes reach another mod

UE4SS gives each Lua mod an isolated state, so ModMenu cannot call another mod
directly. It writes values to that mod's exact `Scripts/runtime.lua` path. The
target mod watches and validates that file from its own state. Nothing is shared
in memory.

Runtime publication is transaction-locked: ModMenu writes a complete staged
file before replacing `runtime.lua`. While the lock exists, readers retain only
their last fully validated configuration and never parse an incomplete table.

| File | Written by | Role |
|---|---|---|
| `Scripts/config.lua` | Player or mod author | Canonical settings, never rewritten by ModMenu |
| `Scripts/runtime.lua` | ModMenu | Optional live overrides applied over `config.lua` |

**Reset** removes runtime overrides and returns control to `config.lua`.

## When changes take effect

Most values apply within about one second. Two labels may carry a marker:

- `+` means close and reopen the Start Menu before the UI change appears.
- `*` means the setting affects construction-time data and may require a complete
  game restart.

The ON/OFF value on a mod header controls both the live `ENABLED` override and
the next-launch `enabled.txt` marker as one transaction. Enabling a script that
UE4SS did not load at startup still requires a complete game restart.

## Diagnostics

The UE4SS console exposes read-only commands:

```text
modmenu list       show every discovered compatible mod and its current values
modmenu probe      dump the live menu widget tree
modmenu buttons    log button codes received by the panel
```

The console requires `GuiConsoleEnabled = 1` under `[Debug]` in
`UE4SS-settings.ini`.

Startup also reports a discovery summary:

```text
[ModMenu] discovery | 10 folder(s) | 5 with a menu | 5 without | 0 invalid
```

## Adding support for another mod

Nothing here changes. The work happens in that mod's own folder:

1. Add `Scripts/modmenu.lua` to the mod, returning `label`, `summary`, `apply`
   and `settings`. The folder name is the identity, so the manifest does not
   repeat it.
2. Use the exact setting keys the mod's `config.lua` defines.
3. Match numeric bounds and choices to that mod's own validator.
4. Ensure the mod reads its exact `Scripts/runtime.lua`, overlays it over
   `config.lua`, and validates the complete result before applying values.
5. Restart the game and check the discovery summary in `UE4SS.log`.

A malformed or unsupported configuration must fail closed in the mod itself.
ModMenu also refuses to expose a mod whose declared contract does not validate
against its actual settings.

## Coexisting with other Start Menu mods

ModMenu and other mods may append rows to the same Start Menu rail. The native
list's arrays cannot be grown safely from UE4SS Lua, so each row is a `MenuIcon`
clone in a donor wrapper outside those native arrays. Only navigation boundaries
are bridged.

ModMenu waits for other injected entries, keeps its own row at the bottom, and
returns upward focus to the row directly above it.

## Crash-safety rules

- Never retain a menu `UObject` across a readiness delay.
- Keep only the current injected context; historical widget tables can pin a
  discarded world through garbage collection.
- Never write an out-of-range native `CurrentIndex`.
- Perform UObject construction and widget-tree changes on the game thread.
- Avoid **Restart All Mods** for this stack. Fully close and relaunch the game
  when scripts or hooks must be reloaded.
