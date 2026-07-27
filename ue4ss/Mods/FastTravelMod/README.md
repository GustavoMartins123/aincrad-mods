# FastTravelMod

An independent **Echoes of Aincrad** mod that adds a **Fast Travel** entry to
the Start Menu and turns the game's regular map into a destination selection
screen.

## Version 0.3.7 scope

- resolves the map ability owned by the local hero's Ability System, closes the
  Start Menu, waits for `GA_AvatarMenu_Main_C` to end, and activates the regular
  map with the ability's own `GameplayEvent` trigger;
- can be started from anywhere without requiring proximity to a terminal;
- uses the map icon currently hovered by the cursor or focused by navigation;
- accepts checkpoints, teleport terminals, safe areas, and map pins;
- captures the position supplied by the game for each icon through
  `URODMapMenuWidgetBase::UpdateIcon`;
- requests teleportation through the native
  `ARODAvatarCharacter::ServerDebugTeleportGimmick(FVector)` RPC;
- closes the map and explicitly restores the gameplay camera;
- does not impersonate terminal access or use the
  `ServerDecideFastTravel` transaction;
- integrates `ENABLED` and `DEBUG_LOGS` with ModMenu.

The contract was audited against the **1.0.3** game SDK/template.

| Responsibility | Canonical contract |
|---|---|
| Close the Start Menu | `ARODInGamePlayerController::EndMainMenu(true)` |
| Observe menu transition | `GA_AvatarMenu_Main_C::BP_IsActive()` |
| Resolve ability ownership | `UGameplayAbility::GetAbilitySystemComponentFromActorInfo()` |
| Resolve activation trigger | Local `GA_AvatarMenu_Map_C::AbilityTriggers` |
| Open the map | `URODAbilitySystemComponent::TryActivateAbilityWithPayloadFromClass(...)` |
| Map ability | `GA_AvatarMenu_Map_C` |
| Widget | `URODMapMenuWidgetBase` / `WBP_Map_C` |
| Selected icon | `MapItemWidget.CurrentTargetIconWidget` |
| Icon type | `URODIconForMapWidgetBase::GetMapIconKind()` |
| Destination position | `Location` argument of `URODMapMenuWidgetBase::UpdateIcon` |
| Teleport | `ARODAvatarCharacter::ServerDebugTeleportGimmick(FVector)` |
| Close the map | `ARODInGamePlayerController::EndMapMenu(AllClose)` |

## Usage

1. Start the game with UE4SS and enter the world.
2. Open the Start Menu.
3. Select `Fast Travel`.
4. Hover a destination on the map or move navigation focus to it.
5. Single-click it or press the accept button.

If no icon is selected, or if the selected icon is not an allowed type, the mod
consumes the confirmation and reports an explicit error. It does not create a
marker or select another destination.

## Allowed destinations

The values below come from `EMapIconKind` in the 1.0.3 SDK.

| Group | Types |
|---|---|
| Checkpoints and terminals | `AccessGimmick` (11), `AccessGimmick_Restart` (12) |
| Teleport gates | `TeleportGate` (14), `TeleportGate_Restart` (15) |
| Safe areas | `SafeArea` (16), `SafeAreaRestart` (17) |
| Hero pins | `HeroPin1..3` (24–26) |
| Pillar pins | `PillarPin1..5` (27–31) |
| Instant pins | `InstantPin1..3` (32–34) |

Enemy, quest, chest, shop, NPC, and other point-of-interest icons are not
accepted by this version. Adding a new icon type must be deliberate and
audited; there is no generic destination acceptance.

## Travel completion and camera recovery

Version 0.2.0 artificially initiated the native terminal access flow. After a
travel operation, the game could remain in this state:

```text
FastTravelStatus=Decide(2)
PSAcsGmkStatus=0
bAccessingTerminal=false
CurrentAcsGmkID=None
```

This represents a completed but unclosed transaction. Version 0.3.7 recognizes
only this exact combination, calls
`ARODPlayerState::ServerCancelFastTravel()` to close it, and restores the
camera. Any other `Decide` state is treated as an actual active travel
transaction and map opening fails.

After a map teleport, the mod closes the menu and calls:

- `StopCameraAnimation`;
- `ResetFov`;
- `ResetCameraViewPointLocation(true)`;
- `ResetCameraBoomArmLength`;
- `ResetMenuRotation`;
- `ResetMenuCameraTransform`;
- `OnEnablePlayableFollowCamera`.

This prevents the terminal-flow close-up camera from remaining active.

## Configuration

Edit `Scripts/config.lua` or use the in-game `Mods` menu:

- `ENABLED`: shows or hides the Start Menu entry;
- `DEBUG_LOGS`: records focus, map destinations, and captured positions.

`Scripts/runtime.lua` contains machine-local state written by ModMenu.

## Diagnostics

UE4SS console commands:

```text
fasttravel status
fasttravel open
fasttravel terminals
fasttravel pins
```

- `status` displays mod state and schedules a read of the old native travel
  transaction;
- `open` opens the map in teleport mode;
- `terminals` lists terminal and checkpoint IDs for diagnostics;
- `pins` lists `Kind`, `Pos`, `Actor`, and `Timestamp` for each `FRODMapPin`.

A valid selection produces a line similar to:

```text
teleporting to selected map icon | kind=HeroPin1(24) | pos=(...)
```

A failure produces `FAST TRAVEL ERROR` or `FAIL-CLOSED` followed by the contract
that could not be validated.

## Fail-closed policy

The mod has one teleport route:

1. close the Start Menu through `EndMainMenu(true)`;
2. wait until `GA_AvatarMenu_Main_C::BP_IsActive()` returns false for every
   loaded instance;
3. require exactly one `GA_AvatarMenu_Map_C` owned by the local hero's Ability
   System, require exactly one `GameplayEvent` trigger on that ability, and
   activate its exact generated class with that trigger through the same
   Ability System;
4. require `GA_AvatarMenu_Map_C` to construct `WBP_Map_C`;
5. identify the exact `CurrentTargetIconWidget`;
6. require an allowed `EMapIconKind`;
7. require the position captured for that same widget by `UpdateIcon`;
8. call `ServerDebugTeleportGimmick` with that position.

The mod does not:

- select a substitute terminal;
- reuse `CheckPointID` as a fake source terminal;
- write `FastTravelStatus`, `PSAcsGmkStatus`, or `bAccessingTerminal`;
- directly modify the actor location;
- use another icon's coordinates when the selection cannot be resolved;
- call `OpenDirectingMapMenu` directly without its owning gameplay ability;
- open another widget when `WBP_Map_C` fails.

If any canonical step fails, no teleport request is sent.
If map construction fails after ability activation, the mod cancels that exact
ability to restore the pre-open state.

## Compatibility with the other menu mods

The entry is created 250 ms after Start Menu construction:

- `FieldEquipmentMod` is added at 100 ms;
- `FastTravelMod` is added at 250 ms;
- `ModMenu` is added at 400 ms.

The mod uses a native wrapper from `WBP_Console_MainMenu_List` and bridges only
the navigation boundaries.
