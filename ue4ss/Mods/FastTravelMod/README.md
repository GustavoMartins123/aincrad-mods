# FastTravelMod

FastTravelMod **v0.14.0** adds a native-styled **Fast Travel** entry to the
Start Menu in **Echoes of Aincrad**. It opens the game's own fast-travel screen
and lets the player travel from anywhere on a floor without standing beside a
terminal.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

The in-game ModMenu is optional. FastTravelMod includes its own private settings
bridge and works when installed by itself.

## Installation

Copy the complete `FastTravelMod` folder to:

```text
EchoesofAincrad\Binaries\Win64\ue4ss\Mods\FastTravelMod
```

The installed layout must include:

```text
FastTravelMod\
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

## Where it works

Fast Travel is available on **floor maps only**. It is intentionally unavailable
in town because the town world does not contain the floor's accessible terminal
and checkpoint destinations.

The Start Menu entry is omitted when the current world has no valid travel
destination, so opening the menu in town does not expose a non-functional row.

## Usage

1. Enter a floor map.
2. Open the Start Menu.
3. Select **Fast Travel**.
4. Select a checkpoint, teleport terminal, gate, or safe area.
5. Confirm the destination.

The default screen is the game's native `WBP_Map_FastTravel_C` destination
picker. `MAP_TARGET = "map"` remains available in `Scripts/config.lua` as an
experimental diagnostic path, but it is not the recommended travel screen.

## How travel is performed

The native screen chooses a destination and reports its ID through
`ARODPlayerState::ServerDecideFastTravel(ID)`. FastTravelMod resolves that ID
against `ARODGameState::RODAccessibleGimmicks`, obtains the destination's arrival
position, and moves the local hero with:

```text
AActor::K2_TeleportTo(FVector, FRotator)
```

`ARODAvatarCharacter::ServerDebugTeleportGimmick` is **not** used. It was tested
on the supported build and did not move the hero.

This is a verified position change, not the complete native terminal transaction.
The terminal fade, arrival cutscene, and partner-warp sequence may therefore not
play.

## Map pins

The fast-travel screen displays map pins for orientation, but its native
**Confirm** action accepts only normal travel destinations. It does not confirm
pins.

Press **F9** by default to travel to the selected or hovered map pin. Pin
coordinates are projected onto the navigation mesh before the hero is moved; a
pin that cannot be projected is rejected.

The key can be changed with `PIN_TRAVEL_KEY` in `Scripts/config.lua`. Set it to
an empty string to disable the binding.

## Recovery key

A viewport change such as Alt+Enter can occasionally leave the map visible with
its normal input no longer responding.

Press **F8** by default to force-close the map, restore gameplay input, and reset
the mod's active menu state. The console command below performs the same action:

```text
fasttravel close
```

The key can be changed with `FORCE_CLOSE_KEY` in `Scripts/config.lua`. Set it to
an empty string to disable the binding.

## Configuration

Edit `Scripts/config.lua` or use the optional in-game ModMenu.

| Setting | Default | Meaning |
|---|---|---|
| `ENABLED` | `true` | Shows the Fast Travel entry when the current floor has destinations |
| `DEBUG_LOGS` | `false` | Enables additional destination and UI diagnostics |
| `MAP_TARGET` | `"fasttravel"` | Chooses the native fast-travel screen or experimental reference map |
| `MAP_MENU_KEY` | `""` | Optional exact menu-key override for the reference-map path |
| `FORCE_CLOSE_KEY` | `"F8"` | Emergency map-close key |
| `PIN_TRAVEL_KEY` | `"F9"` | Map-pin travel key |

When ModMenu is installed, machine-local overrides are written to
`Scripts/runtime.lua`. That file is optional and should not be included when
redistributing the mod.

## Console diagnostics

```text
fasttravel status
fasttravel open
fasttravel close
fasttravel terminals
fasttravel pins
fasttravel pin <index>
fasttravel menukeys
```

Diagnostics stop rather than guessing when a required game object, destination,
widget, or position cannot be validated.

## Known limitations

- Floor maps only; town is intentionally unsupported.
- The move uses `K2_TeleportTo`, not the complete terminal travel transaction.
- Pins require the F9 binding because the native fast-travel screen disables its
  normal confirmation action over a pin.
- `MAP_TARGET = "map"` is experimental and is not the default supported path.
- Game updates may change reflected classes, widget fields, or menu contracts.
