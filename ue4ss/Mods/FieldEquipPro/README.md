# Field Equip Pro

Field Equip Pro adds a native-styled **Equipment** entry to the Echoes of Aincrad Start Menu.

It opens the game's existing Equipment screen while the player is in the field, allowing equipped weapons, armour and other active gear to be changed without returning to a storage chest.

The mod focuses only on equipped gear. It does not provide remote storage access, item spawning or inventory editing.

Field Equip Pro also includes optional character visibility and camera positioning so the field Equipment screen can present the player character in a way closer to the chest interface.

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.

The [Echoes of Aincrad Mod Menu](https://www.nexusmods.com/echoesofaincrad/mods/84) is optional.

No other gameplay mod is required.

## Installation

Copy the complete `FieldEquipPro` folder to:

```text
[Your Game Folder]\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\
```

The final layout should include:

```text
FieldEquipPro\
├── enabled.txt
├── README.md
└── Scripts\
    ├── config.lua
    ├── main.lua
    ├── modmenu.lua
    └── standalone\
        └── ModMenuBridge.lua
```

Confirm that this file exists:

```text
ue4ss\Mods\FieldEquipPro\Scripts\main.lua
```

Fully restart the game after installing or updating the mod.

Do not place the contents of the `FieldEquipPro` folder directly inside `Mods`, and do not create an extra nested folder such as:

```text
FieldEquipPro\FieldEquipPro\Scripts\main.lua
```

Do not include `runtime.lua`, `runtime.lua.*` or `runtime.rev` when redistributing the mod.

## Main Features

- Adds a native-styled Equipment entry to the Start Menu.
- Opens the game's existing Equipment screen in the field.
- Allows equipped weapons, armour and other active gear to be changed away from storage chests.
- Supports keyboard, controller and mouse navigation.
- Integrates with the existing Start Menu rail rather than replacing the menu.
- Handles the different Start Menu layouts used before and after the beta portion of the game.
- Restores normal Start Menu navigation after leaving Equipment or another native submenu.
- Can reveal the player character while the Equipment screen is open.
- Provides a configurable Equipment camera height.
- Preserves the game's native Equipment widgets, selectors and item behaviour.
- Works as a standalone UE4SS Lua mod.
- Supports optional in-game configuration through the Mod Menu.

## Usage

1. Open the game's Start Menu.
2. Move to the **Equipment** entry.
3. Select it with keyboard, controller or mouse.
4. Change the equipped items through the native Equipment interface.
5. Use the normal Back action to return to the Start Menu.

The injected entry is placed after the native Start Menu entries and participates in the normal menu navigation loop.

Field Equip Pro does not add storage access. Only items already available to the game's Equipment interface can be selected.

## Optional In-Game Configuration

For easier configuration, install:

[Echoes of Aincrad Mod Menu](https://www.nexusmods.com/echoesofaincrad/mods/84)

Open the Start Menu, select **Mods**, and expand **Field Equip Pro**.

Without the Mod Menu, edit:

```text
FieldEquipPro\Scripts\config.lua
```

The mod includes its own private settings bridge and works without a shared mod folder.

## Configuration

The default configuration is:

```lua
return {
    ENABLED = true,
    DEBUG_LOGS = true,
    SHOW_CHARACTER = true,
    CAMERA_HEIGHT = 50.0,
}
```

### ENABLED

Controls whether the Equipment entry is available in newly opened Start Menus.

Because the entry is injected while the menu is being built, changing this setting does not reconstruct a Start Menu that is already open. Close and reopen the Start Menu after changing it.

### SHOW_CHARACTER

Controls whether the player character is revealed while the Equipment screen is open.

The regular Start Menu normally hides the character. When this option is enabled, Field Equip Pro temporarily adjusts that state for the Equipment screen and restores the original menu state when leaving.

Set it to `false` if a future game update causes problems with character presentation or camera ownership. The Equipment screen can still open without this feature.

### CAMERA_HEIGHT

Controls the vertical Equipment camera adjustment in centimetres.

Positive values raise the camera rig and place the character lower in the frame. Negative values move it in the opposite direction.

The accepted range is:

```text
-100 to 200
```

The value is used when the Equipment presentation is opened. Close and reopen the Equipment screen after changing it.

### DEBUG_LOGS

Enables detailed Start Menu, focus, transition and camera diagnostics in:

```text
UE4SS.log
```

This is useful during testing. It may be disabled after the menu and camera behaviour are confirmed on the current game build.

## How It Works

Field Equip Pro listens for construction of the real `WBP_Console_MainMenu_C` widget and adds an Equipment row after the game's active native entries.

The mod does not attempt to resize the native Start Menu item arrays from Lua. Instead, it bridges only the navigation boundaries around its custom row and leaves the game's own rows under native control.

When Equipment is selected, the mod opens the game's existing chest Equipment widget and marks it as the native chest equipment menu kind.

The Equipment screen keeps its normal item lists, category navigation, selectors and validation because the mod does not create a replacement equipment interface.

When returning, Field Equip Pro allows the game's normal submenu lifecycle to run and then rearms its Equipment entry on the surviving Start Menu. If the game rebuilt the menu, the new menu receives a fresh injection through its normal construction notification.

This avoids retaining and remounting an obsolete Start Menu widget across world or menu transitions.

## Character and Camera Handling

When `SHOW_CHARACTER` is enabled, the mod:

- resolves the local hero and controller;
- preserves the previous character visibility state;
- temporarily suppresses the menu hide state required for the Equipment presentation;
- ensures the hero is the active view target when appropriate;
- adjusts `CameraRoot` and the camera boom offsets using the configured height;
- restores the original camera and visibility state when leaving Equipment.

The original values are stored before modification and restored rather than replaced with hard-coded defaults.

## Input and Menu Compatibility

Field Equip Pro supports:

```text
Keyboard
Controller
Mouse
```

The mod observes native menu focus and input events so navigation can enter and leave the injected row without allowing an unsupported custom index to reach the native Start Menu switch.

It also hides the injected Equipment row while a native submenu owns the rail and restores it after the native Back transition completes.

The mod includes additional recovery handling for cases where the Equipment widget or menu is closed through an unusual path.

## Diagnostics

The following UE4SS console commands are available:

```text
fieldequip probe
```

Reports the current controller, menu state, live Equipment row, presented Equipment widget, character visibility, hide keys, camera ownership and reflected debug functions.

```text
fieldequip strings
```

Lists loaded string tables and reports the game's general localisation string table. This is useful when a field-opened Equipment screen displays a missing string-table entry.

```text
fieldequip open3d
```

Runs the reflected `DebugOpen3DMenu` experiment and records whether the current game build presents an Equipment widget through that path.

The UE4SS console requires:

```text
GuiConsoleEnabled = 1
```

under the `[Debug]` section of:

```text
UE4SS-settings.ini
```

## Known Limitations

- Field Equip Pro provides Equipment access, not remote item storage.
- The Equipment entry is added when a new Start Menu is constructed.
- Enabling the mod after the Start Menu already exists requires closing and reopening the menu, or restarting the game.
- Camera framing can vary with character, equipment, animation state and future game updates.
- Some localisation resources normally loaded by a storage chest may not already be resident when Equipment is opened directly in the field.
- The mod relies on reflected Start Menu, Equipment, input and camera contracts from Echoes of Aincrad 1.0.3.
- Future game updates may change widget classes, menu indices, input delegates or camera components.
- Avoid UE4SS Restart All Mods while a menu is open. Fully close and relaunch the game when scripts or hooks must be reloaded.

## Credits and Reference

Field Equip Pro was developed with [Field Equipment Mod](https://www.nexusmods.com/echoesofaincrad/mods/64) by **Sphinksz** as the reference for the original field-equipment concept and expected player workflow.

That mod demonstrated the value of adding Equipment access to the Start Menu while preserving the game's native Equipment interface.

Field Equip Pro expands the concept with additional menu lifecycle handling, keyboard/controller/mouse navigation recovery, optional character presentation, configurable camera positioning, standalone settings support and optional Mod Menu integration.

Built for UE4SS.

Echoes of Aincrad and all related game assets and trademarks belong to their respective owners.
