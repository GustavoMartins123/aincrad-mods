# ModMenu

ModMenu **v1.5.7** adds a native-styled **Mods** entry to Echoes of Aincrad's
Start Menu. It enables or disables compatible UE4SS Lua mods and edits their
supported settings without leaving the game.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

ModMenu carries its own settings bridge inside its folder. It reads nothing
from `Mods/shared` and can be installed by itself.

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
    SomeOtherMod *                 ON

  * restart required    + reopen menu
```

A row that opens with `+` or `-` has settings to expand. A row with neither,
like `SomeOtherMod` above, is a mod that ships no settings contract: it is
still listed and still switches on and off, it simply has nothing underneath.

The panel virtualises twelve visible rows. Expanding a mod with more settings
automatically scrolls that fixed viewport, so controller navigation remains
independent of the expanded list's length.

## Automatic discovery

There is no central list of supported mods and nothing for a mod to opt into.
Dropping a mod into `Mods/` is the whole of installing it here.

At startup, `Scripts/registry.lua` enumerates every folder under `Mods/`
through `IterateGameDirectories`. A folder is listed when it holds a
`Scripts/main.lua` -- that is, when UE4SS would load it as a Lua mod. Three
kinds of folder are left out, because an ON/OFF row could not tell the truth
about any of them:

- ModMenu itself, which must not offer the one switch that cannot be undone
  from in-game;
- mods named in `Mods/mods.txt` or `Mods/mods.json`, which UE4SS switches from
  those files rather than from a per-folder `enabled.txt`;
- folders that are not Lua mods at all, such as `shared`.

A listed mod appears in one of two shapes.

**On/off only.** The default. The menu offers the one thing it can know without
being told: whether UE4SS loads the mod, held in `Mods/<Mod>/enabled.txt`.
Nothing is written inside the mod's own folder.

**With settings.** The mod ships `Scripts/modmenu.lua` next to the `config.lua`
those settings live in, declaring its own label, settings, types, choices,
numeric bounds, and when a change takes effect. Its row expands. This shape
requires all of:

- `Scripts/config.lua`;
- a readable and valid effective configuration;
- an `ENABLED` boolean setting;
- every declared setting present with the expected type;
- numeric values inside the declared bounds;
- choice values present in the declared option list;
- valid cross-setting floor and ceiling relationships.

The manifest is checked against the mod's real effective settings, so a
contract that has drifted from the config it describes **loses its settings
rows, never its place in the list**: the mod falls back to on/off and says why
in `UE4SS.log`. One broken contract cannot make the panel fail to open.

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
| `Scripts/preview.lua` | ModMenu | Only if the mod set `preview = true`: is its settings page open right now |

**Reset** removes runtime overrides and returns control to `config.lua`.

### Knowing when your settings are on screen

A mod that wants to react to being edited -- showing a live preview of a value
while the player is changing it, say -- sets `preview = true` in its own
`Scripts/modmenu.lua` and reads `Scripts/preview.lua` from its own folder. The
file returns `{ ACTIVE = true }` while that mod's rows are expanded and
`{ ACTIVE = false }` otherwise, and it is transient state, never a saved
setting.

Only one mod holds it at a time, and only a mod that asked for it is written to
at all. ModMenu names no mod anywhere in its code and requires none to be
installed: the declaration in the mod's own manifest is the entire contract.

None of this touches a mod listed on/off only. That mod has no settings
contract, so ModMenu writes nothing inside its folder and never plants a
`runtime.lua` in a mod that never asked for one -- its `enabled.txt` marker is
the whole of the state the menu owns.

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
[ModMenu] discovery | 6 mod(s) | 5 with settings | 1 on/off only | 5 not a mod
```

A mod that meant to have settings and did not get them is named on its own
line, with the reason:

```text
[ModMenu] SomeMod has no usable settings contract | SomeMod: SCALE is above the registered maximum
```

## Giving a mod editable settings

Any installed mod already appears here with an on/off row. Nothing has to be
done to get that, and nothing here changes to grant it.

Exposing that mod's *settings* is the opt-in, and the work happens entirely in
that mod's own folder:

1. Add `Scripts/modmenu.lua` to the mod, returning `label`, `summary`, `apply`
   and `settings`, plus `preview` if the mod wants to know when its rows are
   expanded. The folder name is the identity, so the manifest does not repeat
   it.
2. Use the exact setting keys the mod's `config.lua` defines.
3. Match numeric bounds and choices to that mod's own validator.
4. Ensure the mod reads its exact `Scripts/runtime.lua`, overlays it over
   `config.lua`, and validates the complete result before applying values.
5. Restart the game and check the discovery summary in `UE4SS.log`.

Step 4 is a behaviour, not a file. Copying a `ModMenuBridge.lua` into the mod
is one way to get it; `WorldEnemyDirector` writes the same watch-overlay-
validate loop directly in its own `main.lua` and works identically.

A malformed or unsupported configuration must fail closed in the mod itself.
ModMenu refuses to expose settings whose declared contract does not validate
against the mod's actual configuration, and shows the mod on/off only.

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
