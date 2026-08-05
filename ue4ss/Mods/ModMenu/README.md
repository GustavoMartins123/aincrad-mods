# ModMenu

ModMenu **v1.5.7** adds a native-styled **Mods** entry to Echoes of Aincrad's
Start Menu.

It discovers installed UE4SS Lua mods directly from the `Mods` directory. Every
valid standalone Lua mod can be enabled or disabled from the list, while mods
that publish a compatible settings contract can also expose editable values
inside the game.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.
- A UE4SS build that exposes the Lua mod-management API used by `RestartMod`.

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

Fully restart the game after installing, removing or updating mods so discovery
starts from a clean `Mods` directory state.

## Usage

Open the Start Menu, move below its final native or modded row to **Mods**, and
confirm.

- `Up/Down` moves through the panel.
- `Enter` expands a mod or toggles a boolean setting.
- `Left/Right` changes a value or toggles a mod header.
- `Back` or `Esc` closes the panel.

```text
MODS

  - Enemy Director                 ON
      Common | Health          < 1.0x >
      Elite | Health           < 1.0x >
  + XP Notifications               ON
    SomeOtherMod *                  OFF

  * restart required    + reopen menu
```

A row that opens with `+` or `-` has editable settings. A row with neither is a
valid UE4SS Lua mod that publishes no settings contract. It can still be shown
and managed, but there is nothing to expand.

The panel virtualises twelve visible rows. Expanding a mod with more settings
automatically scrolls the fixed viewport, so controller navigation remains
independent of the expanded list's length.

## Automatic discovery

There is no central allow-list of supported mods.

At startup, `Scripts/registry.lua` enumerates the folders under `Mods/` through
`IterateGameDirectories`. A folder is accepted as a standalone Lua mod when it
contains:

```text
<Mod>\Scripts\main.lua
```

The following are intentionally excluded:

- ModMenu itself;
- mods managed by `Mods/mods.txt` or `Mods/mods.json` instead of a per-folder
  `enabled.txt` marker;
- folders that are not Lua mods, such as `shared`;
- folders whose installation cannot be read safely.

Every accepted mod appears in one of two forms.

### On/off only

This is the default for a normal UE4SS Lua mod.

ModMenu reads and writes only the UE4SS launch marker:

```text
Mods\<Mod>\enabled.txt
```

No `runtime.lua` or other settings file is created for a mod that did not
publish a settings contract.

### With editable settings

A mod can add:

```text
Scripts\modmenu.lua
```

next to its `config.lua`. The manifest declares its label, summary, apply mode,
setting keys, types, choices, numeric bounds and optional relationships between
minimum and maximum values.

A configurable integration requires:

- `Scripts/config.lua`;
- a readable and valid effective configuration;
- an `ENABLED` boolean setting;
- every declared setting present with the expected type;
- numeric values inside the declared bounds;
- choice values present in the declared option list;
- valid cross-setting floor and ceiling relationships.

The manifest is checked against the mod's real effective settings. A contract
that has drifted from the configuration it describes loses only its settings
rows: the mod remains visible as on/off only and one concise reason is written
to `UE4SS.log`.

One invalid integration cannot prevent the rest of the panel from opening.

Discovery runs when ModMenu starts. Fully restart the game after adding,
removing, renaming or updating a mod.

## Enabling a mod during the current session

When a mod started the game without `enabled.txt`, switching it to **ON** does
two things:

1. creates the persistent `enabled.txt` marker;
2. calls UE4SS `RestartMod("<FolderName>")`.

`RestartMod` asks UE4SS to create or recreate that mod through its own mod
manager. The target receives its own isolated Lua state, `ModRef`, hooks,
keybinds and lifecycle instead of having its `main.lua` executed inside the
ModMenu state.

The folder name is the identity passed to UE4SS. For example:

```text
Mods\ExperienceNotifications\Scripts\main.lua
```

is started with:

```lua
RestartMod("ExperienceNotifications")
```

`RestartMod` **queues** the reinstall rather than performing it. UE4SS matches
the folder name against its own mod list later, on its event loop, and a name it
cannot match is a warning in `UE4SS.log` and nothing more -- the call itself
cannot report it. So a queued start is not a confirmed one: `UE4SS.log` is where
the outcome is.

If the installed UE4SS build does not expose `RestartMod`, or the call fails,
the marker still stands: the mod is on for the next game launch, the row shows
it as **ON**, and the reason it did not start now is written to `UE4SS.log`.

## Disabling a mod

For every mod, switching the header to **OFF** removes `enabled.txt` and creates
`enabled.txt.off`, preventing UE4SS from starting it on the next launch.

A mod with a settings contract also receives:

```lua
ENABLED = false
```

through its runtime override, allowing a correctly integrated mod to stop its
own live behaviour and clean up whatever it owns.

A generic on/off-only mod has no universal live shutdown contract. Its header
therefore controls the next launch, but code that was already loaded may remain
active until the game is restarted. ModMenu does not call `UninstallMod` for
unknown mods because uninstalling an arbitrary mod cannot restore widgets,
objects or game state that mod may already have changed, and that mod cannot be
started again by name after removal in the same UE4SS session.

## How editable settings reach another mod

UE4SS gives every Lua mod an isolated state, so ModMenu does not call another
mod's Lua functions directly.

It writes values to that mod's exact path:

```text
Mods\<Mod>\Scripts\runtime.lua
```

The target mod reads and validates those values from its own state.

Runtime publication is transaction-locked. ModMenu writes a complete staged
file before replacing `runtime.lua`; while the lock exists, a compatible reader
keeps its last fully validated configuration instead of parsing an incomplete
Lua table.

| File | Written by | Role |
|---|---|---|
| `Scripts/config.lua` | Player or mod author | Canonical settings, never rewritten by ModMenu |
| `Scripts/modmenu.lua` | Mod author | In-game settings contract |
| `Scripts/runtime.lua` | ModMenu | Optional overrides applied over `config.lua` |
| `Scripts/runtime.rev` | ModMenu | Change notification for readers |
| `Scripts/preview.lua` | ModMenu | Only when the mod set `preview = true`: whether its settings page is open right now |

**Reset** removes runtime overrides and returns control to `config.lua`.

## Giving another mod editable settings

Any valid standalone UE4SS Lua mod already appears with an on/off row. Editable
settings are optional and are implemented entirely inside that mod's own
folder.

1. Add `Scripts/modmenu.lua` returning `label`, `summary`, `apply` and
   `settings`, plus `preview` if the mod wants to be told when its rows are
   expanded.
2. Use the exact keys defined by the mod's `config.lua`.
3. Match all bounds and choices to the mod's own validator.
4. Read `Scripts/runtime.lua`, overlay it over `config.lua`, and validate the
   complete effective configuration before applying anything.
5. Watch for runtime changes when live configuration is supported.
6. Restart the game and check the discovery summary in `UE4SS.log`.

Step 4 is a behaviour, not a required filename. A mod may use a private
`ModMenuBridge.lua`, implement the same watch-overlay-validate cycle directly,
or provide another equivalent implementation.

The settings contract only describes the menu. It does not automatically make
a target mod reload values.

## Apply modes

A manifest declares when changes take effect:

- `live` — the target mod watches and applies runtime changes while loaded;
- `menu` — close and reopen the relevant game menu or interface;
- `restart` — fully restart the game before the change is guaranteed to apply.

Individual settings may override the manifest's default apply mode.

The panel displays:

- `+` for reopen-menu changes;
- `*` for restart-related changes.

## Knowing when your settings are on screen

A mod that wants to react to being edited -- showing a live preview of a value
while the player is changing it, say -- sets `preview = true` in its own
`Scripts/modmenu.lua` and reads `Scripts/preview.lua` from its own folder. The
file returns `{ ACTIVE = true }` while that mod's rows are expanded and
`{ ACTIVE = false }` otherwise.

ModMenu only writes that marker. Whatever the preview *is* belongs to the mod:
it owns the widgets, reads its own live values, and takes them down when the
marker clears.

Only one mod holds the marker at a time, and only a mod that asked for it is
written to at all. ModMenu names no mod anywhere in its code and requires none
to be installed -- the declaration in the mod's own manifest is the entire
contract.

Preview state is transient and is never saved as a player setting.

## Coexisting with other Start Menu mods

ModMenu and other mods may append rows to the same Start Menu rail. The native
list arrays cannot be grown safely from UE4SS Lua, so each custom row uses a
`MenuIcon` clone in a donor wrapper outside those arrays. Only the navigation
boundaries are bridged.

ModMenu waits for other injected entries, keeps its row at the bottom and
returns upward focus to the row directly above it.

## Diagnostics

The UE4SS console exposes these read-only commands:

```text
modmenu list       show discovered mods and their current values
modmenu probe      dump the live Start Menu widget tree
modmenu buttons    enable or disable input-button diagnostic logging
```

The console requires:

```text
GuiConsoleEnabled = 1
```

under `[Debug]` in:

```text
UE4SS-settings.ini
```

Startup reports a discovery summary similar to:

```text
[ModMenu] discovery | 6 mod(s) | 5 with settings | 1 on/off only | 5 skipped
```

A mod whose settings contract was rejected is reported separately with the
reason.

## Crash-safety rules

- Never retain a menu `UObject` across a readiness delay.
- Keep only the current injected context; historical widget tables can pin a
  discarded world through garbage collection.
- Never write an out-of-range native `CurrentIndex`.
- Perform UObject construction and widget-tree changes on the game thread.
- Start another mod through UE4SS `RestartMod`, never through `dofile` from the
  ModMenu Lua state.
- Avoid **Restart All Mods** for this mod stack. Fully close and relaunch the
  game when every script and hook must be rebuilt together.
