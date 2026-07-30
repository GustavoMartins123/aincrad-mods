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
    ├── registry_impl.lua
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

`Scripts/registry_impl.lua` is the explicit compatibility allow-list. It defines
the supported mod folder names, labels, setting keys, types, choices, numeric
bounds, and when each change takes effect.

At startup, `Scripts/registry.lua` automatically checks every registered
integration and returns only mods that are both installed and compatible.
A compatible mod must have:

- `Scripts/main.lua`;
- `Scripts/config.lua`;
- a readable and valid effective configuration;
- an `ENABLED` boolean setting registered with ModMenu;
- every exposed setting present with the expected type;
- numeric values inside the registered bounds;
- choice values present in the registered option list;
- valid cross-setting floor and ceiling relationships.

Registered mods that are not installed are ignored silently. A partially
installed or incompatible mod is skipped and receives one concise reason in
`UE4SS.log`. It cannot make the entire panel fail to open.

Discovery runs when ModMenu starts. Restart the game after adding, removing, or
updating a compatible mod.

ModMenu intentionally does not scan arbitrary folders and guess configuration
contracts. A mod becomes compatible only after an explicit entry is added to
`registry_impl.lua`; startup discovery then decides whether that registered
integration is actually present and valid.

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
[ModMenu] auto-discovery | 3 compatible | 5 absent | 0 invalid
```

## Adding support for another mod

1. Add one entry to `Scripts/registry_impl.lua`.
2. Match the target folder and setting keys exactly.
3. Match numeric bounds and choices to the target mod's validator.
4. Ensure the target mod reads its exact `Scripts/runtime.lua`, overlays it over
   `config.lua`, and validates the complete result before applying values.
5. Restart the game and check the auto-discovery summary in `UE4SS.log`.

A malformed or unsupported target configuration must fail closed in the target
mod. ModMenu also refuses to expose a registry integration whose startup
contract does not validate.

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
