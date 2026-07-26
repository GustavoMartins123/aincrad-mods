# Modifications from the Original Nexus Releases

This document records the intentional differences between this integrated
Echoes of Aincrad mod suite and the exact original packages downloaded from
Nexus Mods.

It is named `MODIFICATIONS.md` rather than `CHANGELOG.md` because its primary
purpose is upstream provenance and patch disclosure, not a chronological
history of this suite's own releases. If the suite receives independently
versioned releases in the future, notable suite-level changes should also be
maintained in a separate `CHANGELOG.md`.

## Document status

| Field | Value |
|---|---|
| Last verified | 2026-07-26 |
| Comparison scope | Six original Nexus packages versus the installed integrated files |
| Comparison method | Relative-path inventory, SHA-256 file comparison, and textual diff of changed source/configuration files |
| Intended audience | Players, reviewers, maintainers, and original mod authors |
| Upstream status | Local integration changes; no claim is made that they were submitted to or accepted by the original authors |

## Documentation method

This document follows three established practices:

1. Changes are written for humans and grouped under consistent categories such
   as **Added**, **Changed**, **Fixed**, **Unchanged**, and **Known
   limitations**, following the principles of [Keep a
   Changelog](https://keepachangelog.com/en/1.1.0/).
2. Each component identifies its exact origin and baseline archive. This is
   adapted from the provenance fields recommended by the Debian [DEP-3 Patch
   Tagging Guidelines](https://dep-team.pages.debian.net/deps/dep3/).
3. Original release numbers are not silently rewritten. If this integrated
   suite adopts its own version later, version changes should communicate API
   compatibility according to [Semantic Versioning](https://semver.org/).

Only notable technical changes are included. Whitespace-only differences,
timestamps, logs, and transient UI state are excluded unless they change
runtime behavior.

## Permissions and attribution

The Nexus Mods pages remain the authoritative source for authorship, credits,
permissions, downloads, and support:

- [UE4SS for Echoes of Aincrad](https://www.nexusmods.com/echoesofaincrad/mods/7)
- [Terrain Runner SpeedMod](https://www.nexusmods.com/echoesofaincrad/mods/45)
- [Auto Pickup Mod](https://www.nexusmods.com/echoesofaincrad/mods/19)
- [No Rescue — Real Falls](https://www.nexusmods.com/echoesofaincrad/mods/35)
- [Aincrad Open World](https://www.nexusmods.com/echoesofaincrad/mods/55)
- [Field Equipment Mod](https://www.nexusmods.com/echoesofaincrad/mods/64)

This document describes technical differences; it does not grant permission to
redistribute any original or modified file. Consult the permissions on each
Nexus Mods page before distributing a modified package.

## Exact comparison baselines

| Component | Original archive | Original version evidence | Integrated state |
|---|---|---|---|
| UE4SS | `UE4SS_1012_EOA 7 1.2.1 2026-07-24T10-03Z V4y6UZcT5.zip` | Nexus package 1.2.1 | Loader binaries unchanged; settings configured |
| Terrain Runner | `SpeedMod v8 Stablized 45 8 2026-07-20T00-09Z 3CxMATjay.zip` | Archive label v8; `main.lua` identifies v7.11 | `main.lua` identifies v7.17 |
| Auto Pickup | `AutoPickupMod 19 1.4 2026-07-23T15-17Z cLQPyYq9t.zip` | Archive label 1.4; `main.lua` identifies v1.3 | `main.lua` identifies v1.4.1 |
| No Rescue | `Norescue 0.5.0 35 1 2026-07-13T13-48Z 3CxMATjJt.zip` | README identifies 0.5.0 | 0.5.0 plus integration changes |
| Aincrad Open World | `AincradOpenWorld V1.0 55 1 2026-07-18T12-32Z V4y6UZc0K.zip` | Archive identifies V1.0 | V1.0 plus runtime bridge |
| Field Equipment | `FieldEquipmentMod 64 1 2026-07-21T11-45Z 8WdQj6lM4.7z` | `main.lua` identifies v1.14.3-release | `main.lua` identifies v1.14.7 |

## UE4SS 1.2.1

**Origin:** [UE4SS for Echoes of Aincrad on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/7)  
**Baseline:** `UE4SS_1012_EOA 7 1.2.1
2026-07-24T10-03Z V4y6UZcT5.zip`

### Changed

- Changed `DefaultExecuteInGameThreadMethod` in `UE4SS-settings.ini` from
  `EngineTick` to `ProcessEvent`.
- Enabled and made visible the interactive UE4SS GUI console by changing
  `GuiConsoleEnabled` and `GuiConsoleVisible` from `0` to `1`.
- Kept the plain external console disabled because the GUI console exposes the
  output and accepts commands.
- Added comments beside these settings explaining why they are intentional.

### Reason

The `ProcessEvent` execution method avoids making every mod dependent on one
shared EngineTick Lua callback. If that callback is removed after an error,
`ExecuteInGameThread` work can otherwise stop across the entire mod stack.

The GUI console is enabled to make live diagnostics and read-only mod commands
available without editing the loader again.

### Unchanged

SHA-256 comparison confirmed that these files are byte-for-byte identical to
the original Nexus archive:

- `dwmapi.dll`
- `ue4ss\UE4SS.dll`
- `ue4ss\UE4SS_Signatures\GNatives.lua`
- `ue4ss\UE4SS_Signatures\GUObjectArray.lua`
- `ue4ss\UE4SS_Signatures\GUObjectHashTables.lua`
- The bundled `BPML_GenericFunctions`, `BPModLoaderMod`, and `Keybinds` mods
- `mods.txt` and `mods.json`
- `Types.lua`, `UEHelpers.lua`, and `jsbProfi.lua`

The gameplay mods, ModMenu, and `ModMenuBridge.lua` were added around the
unchanged loader. They are not modifications to the UE4SS binaries.

## Terrain Runner SpeedMod

**Origin:** [Terrain Runner SpeedMod on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/45)  
**Baseline:** `SpeedMod v8 Stablized 45 8
2026-07-20T00-09Z 3CxMATjay.zip`  
**Original script version:** v7.11  
**Integrated script version:** v7.17

### Added

- Physical jump-height control through
  `CharacterMovement.JumpZVelocity`.
- `JUMP_HEIGHT_MULTIPLIER` in `Scripts\config.lua`.
- A validated jump-height range from 0.25× to 6.00×.
- Persistent hero and movement-component acquisition.
- Native jump-velocity capture and restoration when the mod is disabled.
- Stable movement-component identity through Unreal `GetFullName()`.
- Deduplicated waiting, ready, disabled, jump, and boost diagnostics.
- Live settings integration through the canonical shared
  `ModMenuBridge.lua`.
- `Scripts\runtime.lua` for settings written by ModMenu.

### Changed

- Replaced the legacy setting aliases with the exact public keys used by
  `config.lua`: `START_SPEED`, `MAX_SPEED`, `SECONDS_TO_MAX_SPEED`, and
  `JUMP_HEIGHT_MULTIPLIER`.
- Replaced silent defaults and numeric clamping with strict transactional
  validation. Missing, mistyped, non-finite, or out-of-range values now produce
  an explicit error and disable the mod.
- Raised the validated top-speed limit from 4.50× to 8.00×.
- Replaced the exposed `hero.CharacterMovement` field with the canonical
  `hero:GetMovementComponent()` call.
- Replaced first-live-sample jog learning with the exact
  hero-class-default `CharacterMovement.MaxWalkSpeed` baseline. Resuming while
  Sprint is already held can no longer teach the detector the sprint cap.
- Restricted player discovery to the canonical local host
  `RODWorldHeroCharacter`.
- Reduced hero/movement retry frequency to the loading interval while those
  objects are unavailable.
- Reset the current acceleration ramp after a live speed change so a multiplier
  from the previous configuration cannot remain active.
- Made the `speedmod` console command read-only. Persistent configuration now
  has one path through `config.lua` or ModMenu.

### Fixed

- Fixed permanent-looking startup failure when the hero or movement component
  did not exist yet. The poll now remains active until both become valid.
- Fixed per-frame `JUMP READY` log flooding caused by UE4SS returning different
  Lua wrappers for the same Unreal movement component.
- Fixed stacked jump changes by retaining the native baseline for one real
  Unreal component and restoring it when disabled.
- Fixed partial configuration mutation by validating every field before
  committing any live change.
- Fixed mission transitions retaining a failed swept-offset state. The
  canonical swept movement call now pauses and retries after the new world is
  ready without changing to a secondary movement API.
- Fixed jump baselines being captured from an already modified instance after
  travel by reading the exact hero-class default movement component.
- Fixed checkpoint fast travel latching `mapLeaving` forever when the game
  repositions the existing world without emitting `ClientRestart`.
- Fixed horizontal boost failing to return after sleep while jump height
  remained active.

### Current integrated defaults

The current `runtime.lua` sets:

- Starting speed: 2.50×
- Top speed: 8.00×
- Time to top speed: 1.80 seconds
- Jump height: 6.00×
- Combat protection: inherited from `config.lua` and enabled

### Unchanged

The original terrain grading, swept collision, sprint detection, combat lock,
travel quarantine, teleport protection, and rest/quest transition systems were
retained.

### Known limitations

- Extreme speed and jump values can expose streaming, geometry, collision, or
  scripted-sequence behavior that the game was not designed to handle.
- A full game restart is safer than restarting every Lua mod in an active
  session.

## Auto Pickup Mod

**Origin:** [Auto Pickup Mod on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/19)  
**Baseline:** `AutoPickupMod 19 1.4
2026-07-23T15-17Z cLQPyYq9t.zip`  
**Original script version:** v1.3, despite the archive's 1.4 label  
**Integrated script version:** v1.4.1

### Added

- A separate documented `Scripts\config.lua`.
- ModMenu settings for enabled state, pickup range, icon range, pickup
  interval, notification display, icon-distance patching, prompt-area
  expansion, and debug logging.
- Live settings reload through `ModMenuBridge.lua`.
- `Scripts\runtime.lua` for menu-written settings.
- Persistent hero acquisition with one waiting and one ready transition per
  world lifecycle.

### Changed

- Moved user-facing values that were hard-coded in `main.lua` into the
  documented configuration file.
- Restricted hero discovery to the canonical local host
  `RODWorldHeroCharacter`.
- Made host validation fail closed when `IsHostHero()` cannot be confirmed.
- When pickup distance changes, clears expanded-item caches and previously
  applied range state before applying the new value.
- Made the `autopickup` console command read-only. Persistent configuration has
  one path through `config.lua` or ModMenu.

### Fixed

- Fixed early startup behavior that appeared to stop when the playable hero had
  not spawned yet. The pickup poll now remains scheduled.
- Removed repeated post-travel `no hero yet` messages.
- Prevented stale range caches from delaying a live pickup-distance change.
- Removed force-resume travel watchdogs and alternate arrival paths.
  `ClientRestart` is now the sole mission-ready signal; if it is absent,
  pickup remains paused and reports an explicit transition error.
- Fixed checkpoint fast travel being treated as mission-world replacement.
  Same-world fast travel now clears range references, pauses for six seconds,
  and resumes through the normal persistent poll without requiring
  `ClientRestart`.

### Unchanged

The original pickup scanning, item operation, range expansion, notification,
travel protection, and cooldown behavior was otherwise retained.

### Known limitations

- The game's reliable pickup limit remains around 1000 Unreal units.
- Large ranges increase the number of nearby objects examined and can affect
  performance or stability.

## No Rescue — Real Falls

**Origin:** [No Rescue — Real Falls on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/35)  
**Baseline:** `Norescue 0.5.0 35 1
2026-07-13T13-48Z 3CxMATjJt.zip`  
**Original version:** 0.5.0

### Added

- Live settings integration through `ModMenuBridge.lua`.
- `Scripts\runtime.lua` for enabled state, landing behavior, debug logging, and
  the safety interval.
- Persistent hero acquisition through the existing safety timer.
- Stable hero identity through Unreal `GetFullName()`.
- Deduplicated waiting, ready, lookup, identity, and switch-error diagnostics.
- Native `DeathLandingHeight` capture before modification.
- A reversible live-disable operation.

### Changed

- Replaced optional typed overrides with a complete, strictly validated
  canonical configuration.
- Restricted hero discovery to the canonical local host
  `RODWorldHeroCharacter`.
- Made `ClientRestart` the canonical transition signal and reset the hero and
  game-configuration references without changing the persisted enabled state.

### Fixed

- Fixed the need to manually re-enable the mod when the hero was unavailable
  during the first application attempt; the safety timer now keeps retrying.
- Fixed live disable so it restores both the game's original landing threshold
  and edge-rescue behavior.
- Fixed repeated application caused by temporary wrapper identity by comparing
  the stable Unreal object name.
- Fixed lobby-to-mission travel requiring an OFF/ON toggle; the safety timer
  keeps reacquiring the new world until its exact hero and game configuration
  are available.
- Fixed the expected lobby interval without `RODGameConfig` being reported as
  an exception with a full traceback. The safety timer now reports one
  `WAITING FOR GAME CONFIG` transition and applies only after the canonical
  object exists; malformed objects and failed property access remain errors.

### Unchanged

- The original `README.txt` is byte-for-byte unchanged.
- Water, drowning, deep-water recovery, pit recovery, out-of-bounds recovery,
  and quest-area teleports remain outside the mod's scope.

## Aincrad Open World

**Origin:** [Aincrad Open World on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/55)  
**Baseline:** `AincradOpenWorld V1.0 55 1
2026-07-18T12-32Z V4y6UZc0K.zip`  
**Original version:** V1.0

### Added

- Runtime integration in `main.lua`.
- `ModMenuBridge.lua` support for `ENABLED`, `DEBUG_LOGS`, and `PROBE_MODE`.
- `Scripts\runtime.lua` for ModMenu-written settings.

### Changed

- Menu-world classification now uses the canonical `UWorld.GetFullName`
  contract and reports one explicit fault per distinct unavailable-world state.
- The existing `CONFIG` table is refreshed in place so closures registered by
  the original script observe new values.
- Made the exact script directory, configuration schema, floor-data files, and
  shared bridge mandatory. Invalid inputs now stop new quest mutation with an
  explicit error.
- Restored the canonical `enabled.txt` load marker so the script is registered
  before the lobby-to-mission transition.
- The ModMenu marks this component as affecting newly constructed manifests and
  requiring restart for a reliable clean application.

### Unchanged

Direct comparison confirmed that these original files are byte-for-byte
unchanged:

- `README.md`
- `Scripts\config.lua`
- `Scripts\probe.lua`
- `Scripts\wl01_pieces.lua`
- `Scripts\wl02_pieces.lua`
- `Scripts\wl01_barriers.lua`
- `Scripts\wl02_barriers.lua`

The original quest hooks, Free Roam labeling, manifest expansion, floor-piece
tables, barrier tables, and save-safe runtime design are unchanged.

### Known limitations

- If it was disabled before game launch, turning it ON only creates the
  next-launch marker; the game must then be fully restarted.
- A setting change cannot retract or rebuild a floor whose manifest is already
  active.

### Local state note

The original archive and this enabled installation both contain `enabled.txt`.
An earlier local `enabled.txt.off` marker prevented UE4SS from loading the mod
despite `runtime.lua` saying `ENABLED=true`; that inconsistent marker was
removed.

## Field Equipment Mod

**Origin:** [Field Equipment Mod on Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/64)  
**Baseline:** `FieldEquipmentMod 64 1
2026-07-21T11-45Z 8WdQj6lM4.7z`  
**Original script version:** v1.14.3-release  
**Integrated script version:** v1.16.0

### Added

- A documented `Scripts\config.lua` with `ENABLED` and `DEBUG_LOGS`.
- Runtime settings reload through `ModMenuBridge.lua`.
- `Scripts\runtime.lua` for menu-controlled enabled state and logging.
- Shared-rail discovery for rows appended below Equipment.
- Explicit focus transfer between the native menu, Equipment, and Mods in both
  directions.
- Foreign injected-row detection.

### Changed

- Restricted local-controller lookup to the canonical
  `RODInGamePlayerController`.
- Added an enable guard when the Start Menu is constructed.
- Guarded native `CurrentIndex` writes so an injected row index is never written
  outside the authored native array.
- Clears selection animation from native and injected rows before transferring
  focus.
- Reasserts Equipment's label, texture, and selected presentation without
  moving focus a second time.
- Preserves the standalone wrap behavior when no other injected row exists.
- Replaced delayed construction-callback captures with a construction
  notification that resolves the exact component-owned Start Menu once on the
  game thread.
- Stores only the current Equipment context instead of retaining widget
  references from every historical menu.
- Removed continuous `FindAllOf(WBP_Console_MainMenu_C)` polling during
  gameplay.
- Removed the display-only `WBP_Console_MainMenu_C` clone that used to supply a
  stat panel beside Equipment, along with the `HeroDetail` nudge that positioned
  it. The stat panel no longer appears over the Equipment screen.
- The Equipment screen now shows the character, under the new `SHOW_CHARACTER`
  setting. Three things were needed and each was found by measuring what the
  previous attempt produced on screen:
  1. The character hide the Start Menu applies is undone through the game's
     keyed hide system: `ARODCharacterBase` carries `HiddenInGameKeys`
     (`TArray<FName>`) and `SetAllActorHiddenInGame(bHidden, Key)` adds or
     removes one key, with the actor staying hidden while any key remains. Every
     key present is removed on the way in and restored on the way out, and each
     one is named in the log. `OnMainMenuCharacterHidden(false)`, tried first,
     does not clear them — that attempt produced a correctly framed shot with
     nobody standing in it.
  2. The view target is handed back to the hero with the engine's
     `SetViewTargetWithBlend`, because `OnMainMenuOpened` receives the
     level-sequence `ACameraActor` the Start Menu frames itself with and the view
     can therefore belong to something else. Measured on this build it does not:
     by the time Equipment is up the view is already the hero, and the handover
     logs that it skipped.
  3. The framing itself comes from the widget's own `IsOpenCameraEnable` and
     `OpenForcedCameraSettings`, applied through `ProcessForcedCameraValues`.
     Every parameter in that struct is relative to the player's camera boom,
     which is why the view target has to be the hero before it runs.

  The previous view target is remembered and handed back on the way out, and
  both the hide keys and the view target are only restored to their menu values
  while a Start Menu is actually on screen, so no path can leave the player
  invisible or looking at scenery they cannot move.
  `ProcessForcedCameraValues` is the only place this mod hands a native struct
  back to a native function, so a step log is emitted immediately before it and
  `SHOW_CHARACTER` turns the whole feature off.
- Added a read-only `fieldequip` console command (`probe`, `open3d`).
- Returning from Equipment no longer detaches the real Start Menu and pushes it
  back into its widget component by hand. The mod now rearms in place when the
  menu survived, and otherwise reopens it through `DebugOpenMainMenu` so every
  rail mod receives its normal construction notification.
- The Equipment session is only treated as open once the widget is confirmed to
  exist, so the `EndMenu` the manager fires for the outgoing Start Menu is no
  longer mistaken for the player leaving.
- Added `CAMERA_HEIGHT`, a live setting that raises the camera boom's
  `TargetOffset.Z` while the Equipment screen is up. How high the shot should sit
  is a matter of taste, so it is a Mods-menu slider rather than a constant. The
  original offset is recorded and restored on the way out, and the nudge is
  written a second time after the forced camera finishes interpolating its own
  values.

### Measured on this build

- `ARODInGamePlayerController:DebugOpen3DMenu(ChestMenu, ChestEquipMenu)` is
  present in reflection and callable without error, and does nothing: no widget,
  no visible change, no log. It was tried as the Equipment entry point in
  v1.15.0 and reverted. `RODWidgetBPFunctionLibrary:DebugOpenMenu` + `OpenMenu`
  remains the only working path. `fieldequip open3d` re-runs the experiment if a
  future patch changes it.
- `ARODInGamePlayerController:OnMainMenuCharacterHidden(false)` does not clear
  the Start Menu's character hide. `ARODCharacterBase:SetAllActorHiddenInGame`
  against each key in `HiddenInGameKeys` does.

### Known limitations

- Some Equipment labels can render as `<MISSING STRING TABLE ENTRY>` —
  "Proficiência na Arma", "MOD Único", "MOD Extra", "Armas Obtidas" and similar.
  Item names, descriptions and every other panel resolve normally. The string
  table those particular keys live in is not resident: opening this screen in the
  field skips whatever pulls it in at a chest, and string tables are collectable,
  so whether it is present varies within a session rather than between builds.
  `fieldequip strings` lists what is loaded, which is what naming the asset to
  preload will need.

### Fixed

- Fixed the Mods row, and any other mod's rail row, being lost after visiting
  Equipment. The clone's rail carried only this mod's row, and the by-hand
  restoration produced a Start Menu that no other mod was ever notified about.
- Fixed navigation disappearing when moving upward from Mods to Equipment.
- Fixed focus skipping directly to Settings or requiring an extra directional
  input after returning to Equipment.
- Fixed two menu icons appearing selected simultaneously.
- Fixed Field Equipment stealing focus back from another injected rail row.
- Fixed custom injected indexes being written into the native list's
  `CurrentIndex`.
- Fixed Equipment disappearing when a checkpoint rebuilt the Start Menu.

### Unchanged

The rail injection technique, the navigation bridge around the injected row, and
the equipment workflow itself were retained. The stat-overlay lifecycle and the
by-hand menu restoration it required were removed rather than retained; see
Changed above.

## New integrated ModMenu layer

**Origin:** Added for this integrated suite  
**Original archive:** None of the six Nexus baselines contains ModMenu or
`ModMenuBridge.lua`

**Current script version:** v1.5.2

### Added

- A **Mods** row below the native Start Menu entries.
- A calibrated `M` row icon.
- A settings panel rendered inside the existing menu.
- Keyboard and controller navigation.
- Modal input isolation so the outer Start Menu does not react while the Mods
  panel is open.
- Bidirectional and idempotent focus coordination with Field Equipment.
- A per-mod registry with setting types, ranges, application timing, and
  display formats.
- Persistent values in each mod's `Scripts\runtime.lua`.
- Transactional enable/disable behavior that updates live `ENABLED` state and
  the next-launch `enabled.txt` marker together.
- Rollback to the previous runtime and marker state if either filesystem
  operation fails.
- Transaction-locked `runtime.lua` publication so independent mod readers
  never observe a valid but partially written settings table.
- The shared `ue4ss\Mods\shared\ModMenuBridge.lua` used by isolated Lua states.

### Changed

- Field Equipment is marked `+` because its row is rebuilt when the Start Menu
  is reopened.
- Open World is marked `*` because its effect depends on newly constructed
  quest manifests and may require a restart.
- UE4SS's built-in `mods.txt` and `mods.json` remain unchanged; gameplay Lua
  mods continue to use only their `enabled.txt` markers.
- Uses the same construction-notification acquisition path as Field Equipment,
  with its later 400 ms slot preserving deterministic row order.
- Retains only primitive menu identity while waiting to inject and only the
  current live context afterward.
- Removed continuous global widget scans while the Start Menu does not exist.

### Fixed

- Fixed the display-only Start Menu guard in `injectModsEntry` being gated on an
  `inViewport` variable that was never assigned in that function, so the guard
  was permanently disabled. Rejection happened one layer up in
  `isCanonicalMainMenuCandidate`, which is why it went unnoticed.
- Fixed controller Left/Right handling inside the Mods panel.
- Fixed Back/B closing behavior for the panel.
- Fixed the outer Start Menu receiving the panel's navigation input.
- Fixed Equipment-to-Mods and Mods-to-Equipment focus asymmetry.
- Fixed mod-header toggles changing the wrong mod's enable marker.
- Fixed custom rows writing invalid native list indexes.
- Fixed lobby-to-mission transitions requiring manual OFF/ON cycles. Each
  loaded mod now retains its persisted setting while map-owned references are
  invalidated and reacquired.
- Fixed live numeric edits exposing a partially written `runtime.lua`, which
  could make SpeedMod reject a temporarily missing `START_SPEED`.
- Fixed the Mods row disappearing after checkpoint reconstruction.
- Fixed World Enemy Director retaining outgoing-mission enemy references until
  `ClientRestart`; quest-end events now release references before world
  collection and leave asynchronous actor teardown to Unreal.
- Fixed standalone `ClientRestart` events discarding World Enemy Director
  ownership inside the same mission. Existing extras are now retained instead
  of being rediscovered as natural enemies and multiplied recursively.
- Added a dedicated quarantine for `ServerNotifyQuestTeleportOut` and a
  two-second stable-discovery barrier before the first extra spawn.
- Boss detection now uses the reflected `EnemyRole_Boss` enum together with
  `GoldenGateBoss`. Bosses can be mutated explicitly but can never be
  multiplied or selected by species randomisation.
- Blueprint classes reused by a mission boss are quarantined for that world.
  A late classification after an owned actor was issued now pauses the director
  with an explicit mission-restart error instead of destroying an actor while
  Unreal may still be initializing it asynchronously.
- Fixed a configuration read failure being replaced by registry defaults in the
  panel. Missing, malformed, or invalid canonical settings now fail closed and
  are reported explicitly.

## New World Enemy Director component

**Origin:** New local implementation based on public reflected game contracts

**Original archive:** None of the six Nexus baselines contains this component

**Current script version:** v1.4.10

### Added

- Extra-enemy multiplication, loaded-species randomisation, boss quarantine,
  colour presets, visual scale, Gameplay Ability System combat multipliers,
  movement speed, experience multipliers, world-transition quarantine, and
  exact owned-actor accounting.
- A ModMenu registry entry and strict transactional configuration.

### Changed

- Replaced raw deferred `GameplayStatics` actor construction with the game's
  reflected `RODGameState.RODSpawnActor` population contract.
- Replaced the unsupported reflected `FVector&` output from
  `K2_GetRandomReachablePointInRadius` with complete
  `UNavigationPath` validation through
  `FindPathToLocationSynchronously`.
- Tests up to 12 golden-angle candidates over multiple director cycles,
  retaining the request while the NavMesh is building or candidates remain.
  Only one synchronous path query is allowed per cycle.
- Uses valid, non-partial `UNavigationPath` state as the reachability contract;
  the unreliable zero path-length value exposed by this UE4SS build is not
  treated as a second contract.
- Resolves the natural source enemy by exact object identity for native owner
  and instigator.
- Calls the exact `RODSpawnActor` parameter sequence declared by the supplied
  game header. Runtime UFunction-property enumeration was removed because this
  UE4SS build does not expose `ForEachProperty` on its Lua UFunction wrapper.
- Reports the rejected native property and remaining Lua argument types in one
  compact spawn-contract fault instead of discarding that diagnostic context
  or emitting the full repeated stack dump.
- Invokes `RODSpawnActor` through
  `RODGameState:CallFunction(UFunction, ...)` in the declared C++ parameter
  order. Direct UFunction `__call` invocation on UE4SS build `c838a8ac` left
  its callable table in the marshaling stack and shifted `inOwner` and
  `InInstigator`.
- Acquires the UFunction from the current `RODGameState`, providing
  `CallFunction` with a bound calling context. The bound UFunction reference is
  cleared on every world transition.
- Requires 50-150 cm separation from natural, pending, and owned enemies and
  uses `AdjustIfPossibleButDontSpawnIfColliding`.
- Supplies `FRODSpawnActorOption` with server spawn, source level, `Prowl`
  initial state, initial state location, active perception, and Behavior Tree
  startup.
- Reads ownership only from
  `FRODSpawnActorResult.ServerSpawnActor`.
- Applies random visual size to skeletal-mesh `RelativeScale3D` instead of the
  character actor root, preserving capsule, NavMesh-agent, perception,
  controller, and movement geometry.
- Classifies `ServerDecideFastTravel` as a same-world quarantine. Existing
  ownership is retained and processing resumes after eight seconds instead of
  waiting forever for a `ClientRestart` that checkpoint travel does not emit.

### Failure behavior

Missing navigation, population, result, weak-pointer, mesh, or lifecycle
contracts stop that operation with an explicit error. There is no raw-spawn or
actor-root-scale compatibility path.

A population-call contract failure rolls back the director, clears queued
work, and emits one concise world fault. It is not retried every poll cycle.

## New Experience Notifications component

**Origin:** New local quality-of-life implementation

**Original archive:** None of the six Nexus baselines contains this component

**Current script version:** v1.2.0

### Added

- A live ModMenu toggle for native EXP notifications.
- Exact observation of the single
  `ApplyAcquisition(Source, AcquisitionData)` reward transaction, filtered to
  enemy sources and using `AcquisitionData.ExperiencePoint` directly.
- An `EXP +N` entry built with the game's `URODEventMessageWidget`, inserted in
  the active `URODInfoMessageLogWidget.Information` stack.
- Native timer ownership through `SetMessageTimer`, avoiding Lua references to
  enemy, player, widget, or world objects across travel.
- Immediate read-back validation of the written native rich text, with
  transactional widget removal when the game rejects or replaces `EXP +N`.

The game's `DT_InfoMessageDataTable` contains no EXP row; `1014` and `1015` are
explicitly stealing/collection messages. The component therefore does not
misuse a localization row or substitute an unrelated message key. If the
acquisition or active message-stack contract is unavailable, it reports an
explicit error and does not create another overlay.

## Generated and local-state files

The following files are not upstream source modifications:

| File | Meaning |
|---|---|
| `Scripts\runtime.lua` | Current overrides written by ModMenu |
| `enabled.txt` | UE4SS loads the mod on the next launch |
| `enabled.txt.off` | Local disabled-state marker |
| `ue4ss\UE4SS.log` | Runtime diagnostics |
| `ue4ss\imgui.ini` | UE4SS GUI window state |

The original Auto Pickup and Field Equipment archives store `1` in their
`enabled.txt` files. ModMenu writes the canonical `enabled` marker text. UE4SS
uses the marker's presence, so its contents do not change enablement semantics.

## Maintenance rules for future changes

When this integrated suite changes again:

1. Record the new comparison date in ISO `YYYY-MM-DD` format.
2. Preserve the exact upstream archive filename and Nexus origin.
3. Compare full relative-path inventories before comparing individual files.
4. Verify unchanged files by hash and changed text files by semantic diff.
5. Document the reason and user-visible effect, not only the implementation.
6. Use only the categories that contain notable changes; omit empty headings.
7. Keep generated files and local enablement state separate from source
   modifications.
8. State what remained unchanged so reviewers can see the patch boundary.
9. Keep known limitations beside the component they affect.
10. Do not change an original release's contents while retaining its upstream
    version number. Give the integrated suite its own version when it begins
    publishing independent releases.
11. Maintain a separate chronological `CHANGELOG.md` once this suite has its own
    releases.
12. Recheck each Nexus page's current permissions before distributing modified
    files.

## Methodology references

- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) — human-readable
  notable changes, consistent categories, ISO dates, and omission of empty
  sections.
- [DEP-3 Patch Tagging
  Guidelines](https://dep-team.pages.debian.net/deps/dep3/) — patch origin,
  description, author/status metadata, and last-update traceability.
- [Semantic Versioning 2.0.0](https://semver.org/) — version numbers that
  communicate incompatible changes, compatible features, and fixes once a
  public API/versioned suite exists.
