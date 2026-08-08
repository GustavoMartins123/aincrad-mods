# Experience Notifications

Experience Notifications **v1.2.2** shows the exact hero experience awarded by
a confirmed enemy death as an `EXP +N` entry in Echoes of Aincrad's native
side-message stack.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

The in-game ModMenu is optional. Experience Notifications includes its own
private settings bridge and works when installed by itself.

## Installation

Copy the complete `ExperienceNotifications` folder to:

```text
EchoesofAincrad\Binaries\Win64\ue4ss\Mods\ExperienceNotifications
```

The installed layout must include:

```text
ExperienceNotifications\
├── enabled.txt
├── README.md
└── Scripts\
    ├── main.lua
    ├── main_impl.lua
    ├── config.lua
    ├── modmenu.lua
    └── standalone\
        └── ModMenuBridge.lua
```

Fully restart the game after installing or updating the mod.

## How it works

The mod reads the game's single
`RODGameState.ApplyAcquisition(Source, AcquisitionData)` transaction. It
requires `Source` to be a `RODEnemyCharacter` and displays the transaction's
exact `AcquisitionData.ExperiencePoint` value rather than estimating a reward
from the enemy class. Quest rewards and other non-enemy acquisitions are not
displayed.

The message is an instance of the game's own `URODEventMessageWidget`, inserted
into the active `URODInfoMessageLogWidget.Information` panel. The native message
log owns its lifetime through `SetMessageTimer`; Lua does not retain an inserted
message widget after publication.

The active message-log and widget-library references are cached only while they
remain valid. Version 1.2.2 clears those local caches on `ClientRestart`, so a
world or player-controller transition cannot keep the notification resolver
pointing at the previous world's interface.

Before insertion, the mod writes `EXP +N` to the native rich-text block and
reads it back immediately. A rejected or replaced value prevents insertion and
reports an explicit display error. A later panel failure removes the partial
widget transactionally.

## Configuration

Edit `Scripts/config.lua` or use the optional in-game ModMenu:

```lua
return {
    ENABLED = true,
    DEBUG_LOGS = false,
}
```

When ModMenu is installed, machine-local overrides are written to
`Scripts/runtime.lua`. That file is optional and should not be included when
redistributing the mod.

If the acquisition or active message-stack contract is absent, the operation
reports an explicit error and does not create a substitute overlay.
