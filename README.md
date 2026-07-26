# Echoes of Aincrad UE4SS Mod Suite

This guide explains how to install the Echoes of Aincrad-adapted UE4SS build,
install the included gameplay mods, use the integrated in-game Mods menu, and
work around the current known limitations.

The individual Nexus Mods pages remain the download, credit, permissions, and
release-reference pages for their respective projects:

- [UE4SS for Echoes of Aincrad](https://www.nexusmods.com/echoesofaincrad/mods/7)
- [Terrain Runner SpeedMod](https://www.nexusmods.com/echoesofaincrad/mods/45)
- [Auto Pickup Mod](https://www.nexusmods.com/echoesofaincrad/mods/19)
- [No Rescue — Real Falls](https://www.nexusmods.com/echoesofaincrad/mods/35)
- [Aincrad Open World](https://www.nexusmods.com/echoesofaincrad/mods/55)
- [Field Equipment Mod](https://www.nexusmods.com/echoesofaincrad/mods/64)

For an exact source-by-source comparison against the original Nexus archives,
see [Modifications from the Original Nexus Releases](MODIFICATIONS.md).

The Nexus Mods UE4SS package is a modified build adapted specifically for
Echoes of Aincrad. Its primary purpose is loading Lua and Blueprint mods. This
suite does not claim authorship of UE4SS; use the Nexus Mods page above for its
download, credits, permissions, changelog, and support information.

> This document describes the integrated versions in this folder. Their
> settings and compatibility fixes may be newer than the standalone files
> currently described on the individual Nexus pages. Do not mix individual
> script files from different releases.

## Included components

| Component | Purpose | Settings apply |
|---|---|---|
| UE4SS | Loads the Lua and Blueprint mods | Game restart |
| ModMenu | Adds a **Mods** entry to the game's Start Menu | Already integrated |
| Terrain Runner SpeedMod | Accelerating terrain-aware sprint and configurable jump height | Live |
| Auto Pickup Mod | Collects nearby drops and nature items automatically | Live |
| No Rescue | Removes ledge steering and the hard-fall teleport | Live |
| Field Equipment Mod | Opens the native Equipment screen while in the field | Reopen Start Menu |
| World Enemy Director | Multiplies and mutates world enemies | Live |
| Experience Notifications | Shows the exact EXP awarded by each enemy death | Live |
| Aincrad Open World | Opens complete floors and adds Free Roam quest entries | New quest manifests/restart |

## 1. Find the correct Win64 folder

The files must be installed beside the game's real shipping executable, not in
the top-level Steam game folder.

In Steam:

1. Open **Library**.
2. Right-click **Echoes of Aincrad**.
3. Select **Manage → Browse local files**.
4. From the folder Steam opens, enter:

   ```text
   EchoesofAincrad\Binaries\Win64
   ```

You have reached the correct folder when it contains:

```text
EchoesofAincrad-Win64-Shipping.exe
```

A typical installation path is:

```text
...\SteamLibrary\steamapps\common\Echoes of Aincrad\
   EchoesofAincrad\Binaries\Win64
```

The Steam library drive and the folders before `steamapps` may be different on
your computer. The executable name is the reliable way to confirm the target.

## 2. Install the Echoes of Aincrad UE4SS build

Use the [Echoes of Aincrad UE4SS package from Nexus
Mods](https://www.nexusmods.com/echoesofaincrad/mods/7). Do not substitute a
stock UE4SS release: this game requires the adapted Nexus build.

1. Fully close the game.
2. Download the UE4SS archive from the Nexus Mods **Files** tab.
3. Extract the archive.
4. Copy both of the following into the `Win64` folder identified above:

   ```text
   dwmapi.dll
   ue4ss\
   ```

5. Confirm that the final layout resembles:

   ```text
   Win64\
   ├── EchoesofAincrad-Win64-Shipping.exe
   ├── dwmapi.dll
   └── ue4ss\
       ├── UE4SS.dll
       ├── UE4SS-settings.ini
       ├── UE4SS_Signatures\
       └── Mods\
   ```

6. Launch the game once. UE4SS should create or update:

   ```text
   Win64\ue4ss\UE4SS.log
   ```

With `GuiConsoleEnabled = 1` in `UE4SS-settings.ini`, a separate UE4SS
debugging window also appears. The game can still run without keeping that
window in front.

If `dwmapi.dll` or the `ue4ss` folder is one level above or below the shipping
executable, UE4SS will not be injected into the game.

## 3. Install the gameplay mods

Each Lua mod must be a direct child of:

```text
...\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\
```

Close the game before copying or replacing mod files. Extract each downloaded
archive and copy its actual mod folder into `ue4ss\Mods`.

The integrated installation should contain:

```text
ue4ss\Mods\
├── AincradOpenWorld\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── AutoPickupMod\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── FieldEquipmentMod\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── ExperienceNotifications\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── ModMenu\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── norescue\
│   ├── enabled.txt
│   └── Scripts\main.lua
├── shared\
│   └── ModMenuBridge.lua
├── SpeedMod\
│   ├── enabled.txt
│   └── Scripts\main.lua
└── WorldEnemyDirector\
    ├── enabled.txt
    └── Scripts\main.lua
```

Do not create an extra nested directory. This is incorrect:

```text
ue4ss\Mods\SpeedMod\SpeedMod\Scripts\main.lua
```

This is correct:

```text
ue4ss\Mods\SpeedMod\Scripts\main.lua
```

### How Lua mods are enabled

An `enabled.txt` marker in the mod's root folder tells UE4SS to load that mod
on the next game launch. Its contents are irrelevant:

```text
ue4ss\Mods\SpeedMod\enabled.txt
```

An `enabled.txt.off` file means the mod is disabled. The integrated Mods menu
creates or removes the canonical `enabled.txt` marker when a mod is toggled.

Do not also add these Lua mods to `mods.txt` or `mods.json`. Loading the same
mod through both an `enabled.txt` marker and a UE4SS registry can execute it
twice, duplicate hooks, and crash the game. The built-in UE4SS/Blueprint loader
entries already present in those registry files should be left alone.

## 4. Use the in-game Mods menu

Wait until a save has loaded and the playable character is in the world.

1. Open the game's **Start Menu**.
2. Move down to **Mods**.
3. Confirm to open the Mods panel.

Controls:

| Action | Keyboard | Controller |
|---|---|---|
| Move through rows | Up/Down arrows | D-pad or directional navigation |
| Change a value | Left/Right arrows | Left/Right |
| Expand a mod or toggle a switch | Enter | Confirm/A |
| Close the Mods panel | Escape/Back | Back/B |

Only the Mods panel receives directional input while it is open. Closing it
returns control to the normal Start Menu.

The symbols beside mod names mean:

- `+` — close and reopen the Start Menu before judging the change.
- `*` — the change affects newly constructed quest data and may require a full
  game restart.

The ON/OFF value on a mod header represents its UE4SS `enabled.txt` load marker.
Turning an already loaded mod off also disables its live runtime behavior.
Turning on a mod that was not loaded when the game started only prepares it for
the next launch; fully restart the game so UE4SS can execute its script.

Most live values are saved to the target mod's `Scripts\runtime.lua` and are
picked up in about one second. The documented base values remain in
`Scripts\config.lua`. The runtime values shown in the Mods menu take precedence
until they are changed or reset.

The safe lobby and a selected mission are different Unreal worlds. The
integrated mods keep their `ENABLED` setting across that transition, discard
only objects owned by the old world, and reacquire the mission's current hero,
movement component, pickups, game configuration, and enemies. Do not toggle a
mod OFF and ON after entering a mission; a loaded and enabled mod is expected to
activate automatically after its transition-settle interval.

For restart-required changes, close the game normally and launch it again.
Avoid **Restart All Mods** with this stack: reconstructing every hook and
injected widget inside an active session can leave duplicate state or crash
UE4SS.

## 5. How each mod works

### Terrain Runner SpeedMod

[Nexus Mods page](https://www.nexusmods.com/echoesofaincrad/mods/45)

Terrain Runner detects the game's real sprint state and gradually adds swept,
collision-checked movement on top of normal locomotion. It follows measured
terrain grade rather than applying a simple walk-speed property multiplier.
Walls and blocking geometry can therefore stop the extra movement.

The boost is intended for traversal. With **Off during combat** enabled, it is
suspended when the player deliberately locks onto or attacks an enemy. Map
travel, quest transitions, teleports, rest sequences, and player restarts also
temporarily quarantine movement injection.

The integrated version additionally changes physical jump height through the
character movement component. Jump height is converted to the corresponding
vertical launch velocity instead of multiplying height and velocity as if they
were the same measurement.

Available settings:

| Setting | Range | Meaning |
|---|---:|---|
| Starting speed | 1.00×–2.50× | Multiplier applied when the boost begins |
| Top speed | 1.00×–8.00× | Maximum traversal multiplier |
| Time to top speed | 0.25–10.00 seconds | Acceleration duration |
| Jump height | 0.25×–6.00× | Approximate physical jump-apex multiplier |
| Off during combat | On/Off | Disables super speed during deliberate combat |

This suite currently sets top speed to **8.00×** and jump height to **6.00×**
through `runtime.lua`.

The mod waits for the local host hero and its movement component instead of
failing permanently during an early load. The normal diagnostic sequence is
one `WAITING FOR HERO` message followed by one `MOVEMENT READY` and one
`JUMP READY` message.

### Auto Pickup Mod

[Nexus Mods page](https://www.nexusmods.com/echoesofaincrad/mods/19)

Auto Pickup scans around the local hero and operates nearby item drops, pickup
objects, and nature collection objects. It can also widen the prompt area,
extend icon visibility, and retain the normal pickup notification.

Important distance behavior:

- `100 Unreal units = approximately 1 metre`.
- A pickup range of `1000` is approximately 10 metres.
- The game's reliable effective pickup distance is around 1000 units.
- A larger icon range can show items farther away without making them reliably
  collectible from that distance.

Very large scan or icon ranges increase the amount of world data examined and
may cause frame drops or instability. Keep pickup range near 1000 unless a
specific area has been tested.

The integrated version keeps polling when the hero has not spawned yet. It logs
the waiting state once and activates automatically when the hero becomes valid.

### No Rescue — Real Falls

[Nexus Mods page](https://www.nexusmods.com/echoesofaincrad/mods/35)

No Rescue changes two of the game's own runtime systems:

1. It disables the predictive ledge-rescue steering that pushes the hero away
   from a dangerous edge.
2. It raises the hard-fall death/teleport threshold out of reach.

The medium and hard landing animations remain. The mod does not add fall
damage.

It intentionally does not change:

- Swimming or drowning.
- Deep-water recovery.
- Pit and out-of-bounds recovery.
- Quest-area teleports.

No per-frame movement code is used. The settings are applied when the hero is
available and checked again on a configurable safety interval. If the game
starts before the hero exists, the safety loop remains active until the hero is
found.

### Field Equipment Mod

[Nexus Mods page](https://www.nexusmods.com/echoesofaincrad/mods/64)

Field Equipment injects an **Equipment** entry into the game's Start Menu. It
opens the native Equipment screen and allows weapons, armour, and equipped gear
to be changed without returning to a storage chest.

It does not provide item-storage access. Only the normal equipment interface is
opened.

Because the Equipment row is created when the Start Menu is built, enabling or
disabling it is marked with `+`. Close and reopen the Start Menu to rebuild the
row. If it was disabled before launch and therefore never loaded by UE4SS,
restart the game after turning it on.

### World Enemy Director

World Enemy Director preserves the game's natural enemy actors and can create
up to seven additional enemies per natural spawn through
`RODGameState.RODSpawnActor`. Each candidate must first produce a valid,
non-partial `UNavigationPath` on the active NavMesh and remain separated from
other enemies. A request tests up to 12 spiral-distributed candidates over
multiple director cycles, with one synchronous path query per cycle. The spawn
option starts the native Behavior Tree, leaves
perception enabled, and rejects unresolved collisions. Additional species can
be randomised from classes that the current world has already loaded. Every
extra is owned by the exact server actor returned by the game's population
API.

The Mods panel exposes the spawn multiplier and cap, spawn radius, natural-boss
mutation, scale range, fixed or random colour, health, attack, defence,
movement speed, and experience multipliers. Natural quest actors are never
replaced; only exact actors created and owned by this mod may be destroyed when
the multiplier is reduced or the mod is disabled.

Combat multipliers are applied after the enemy's native initialization through
its exact Gameplay Ability System attributes. Health targets `Health` and
`MaxHealth`; attack and defence change `BaseATK` and `BaseDEF` and verify the
calculated `ATK` and `Def` outputs. Live maximum-health changes preserve the
enemy's current HP percentage, and disabling the director reverses only the
deltas it applied.

Bosses are never spawn candidates. The director checks both the reflected
`EnemyRole_Boss` value and `GoldenGateBoss`; the boss option permits mutation
of the natural actor only. A Blueprint class reused by a mission boss is
quarantined for that whole world. Initial discovery must remain stable for two
seconds before any extras are issued. If boss classification nevertheless
arrives after an owned actor was issued, spawning fails closed and requires a
mission restart rather than destroying an initializing actor.

Confirmed travel releases outgoing-world references before Unreal collects the
mission. A standalone `ClientRestart` or quest teleport within the same world
preserves ownership and temporarily quarantines processing, preventing the
director from rediscovering and multiplying its own extras.

Visual size changes target only the enemy skeletal mesh. Character capsules,
NavMesh agents, controllers, perception, and movement remain at native scale,
so large variants do not lose navigation or detection because of actor-root
scaling.

See
[`ue4ss\Mods\WorldEnemyDirector\README.md`](ue4ss/Mods/WorldEnemyDirector/README.md)
for its exact configuration contract, colour requirement, diagnostics, and
known limitations.

### Experience Notifications

Experience Notifications shows `EXP +N` in the game's native side-message
stack after a confirmed enemy death. It correlates
`NotifyEnemyConfirmedDeath` with the host player's exact
`CalcHeroLevelUp(AddExp)` call in either callback order, so the displayed
number is the reward actually applied after the game's own calculations.

The feature creates the game's `URODEventMessageWidget` inside the active
`URODInfoMessageLogWidget.Information` panel and hands its lifetime to the
native message timer. It does not retain enemy, player, widget, or world
objects across travel. Quest and unrelated EXP grants are not displayed.

### Aincrad Open World

[Nexus Mods page](https://www.nexusmods.com/echoesofaincrad/mods/55)

Aincrad Open World expands each supported quest's runtime manifest so the
entire floor can be initialized by the game's native systems. It enables the
full map, regions, enemies, chests, terminals, and exploration beyond the
normal quest area while leaving the original quest entries intact.

It also labels two repeatable quests as dedicated Free Roam entries:

- Quest `20036` — **Floor 1 : Free Roam**
- Quest `20024` — **Floor 2 : Free Roam**

The underlying quest remains active during Free Roam. Complete its objective to
finish normally or use **Give Up** to return to town. The mod changes runtime
quest data and does not write open-world state to the save file.

#### Mission lifecycle

Open World is loaded at game startup from its canonical `enabled.txt` marker.
Its quest-asset notification remains registered while the game moves from the
safe lobby into a mission, so newly constructed mission manifests are expanded
without an OFF/ON toggle.

The mod can expand a quest manifest only when that manifest is created. It
cannot retroactively rebuild a floor that is already active, and it cannot
retract an already expanded floor when switched off. After changing Open World
enablement, fully restart the game and start a new quest session.

### Integrated ModMenu

ModMenu is the compatibility layer that places the **Mods** row beneath the
native Start Menu entries and coordinates its navigation with Field Equipment.

UE4SS isolates each Lua mod, so ModMenu does not call the other mods directly.
It writes validated settings to each mod's `Scripts\runtime.lua`. The target mod
reads and validates that exact file from its own isolated state. Existing mods
may use the shared `ModMenuBridge.lua`; World Enemy Director uses its own strict
canonical loader and disables its operations when configuration is invalid.
Writes are transaction-locked and published from a complete staged file, so a
reader never observes a partially written Lua table.

Disabling a mod is transactional: the menu updates both its live `ENABLED`
setting and its next-launch `enabled.txt` marker. If either filesystem operation
fails, the previous state is restored and an explicit error is logged.

## Known limitations

- **A disabled mod cannot be loaded live:** creating `enabled.txt` prepares the
  next launch; UE4SS still needs a full game restart to execute a script that
  was absent at startup.
- **Extreme traversal values:** 8× speed and 6× jump are available, but scripted
  sequences, narrow interiors, steep geometry, streaming boundaries, and maps
  designed for normal movement may behave unexpectedly.
- **Auto Pickup range:** icons may appear beyond the distance at which the game
  will reliably complete a pickup. Excessive ranges may affect performance or
  stability.
- **No Rescue scope:** it removes fall rescue only. Water, pit, out-of-bounds,
  and quest recovery remain vanilla.
- **Field Equipment scope:** it opens Equipment, not storage.
- **Enemy Director native verification:** its reflected spawn, material, and
  enemy-stat contracts were validated against public dumped headers and still
  require an in-game test after each game update.
- **EXP notification native verification:** reward correlation and the native
  message widget require an in-game test after each game update.
- **Runtime UI rebuilding:** Field Equipment changes need the Start Menu to be
  reopened. Open World changes affect only manifests created after the change.
- **Game updates:** engine classes, widgets, hooks, or signatures can change
  after an Echoes of Aincrad update and may require updated mod files.
- **Local/host character:** hero-dependent behavior targets the local host hero
  and is intended primarily for single-player/local-host use.
- **Hot restarting the entire stack:** avoid UE4SS **Restart All Mods**. Fully
  close and reopen the game when a restart is required.

## Troubleshooting

### UE4SS does not open or no log is created

Check that these three paths exist together:

```text
Win64\EchoesofAincrad-Win64-Shipping.exe
Win64\dwmapi.dll
Win64\ue4ss\UE4SS.dll
```

Make sure the UE4SS archive came from the Echoes of Aincrad Nexus Mods page and
was not replaced with an unadapted stock build.

### A mod is missing from the game

Check all of the following:

- The folder is directly inside `ue4ss\Mods`.
- There is no duplicate nested mod folder.
- `Scripts\main.lua` exists.
- `enabled.txt` exists in the mod root.
- The same Lua mod is not also registered in `mods.txt` or `mods.json`.
- The game was fully restarted after the mod was enabled.

### A mod says `WAITING FOR HERO`

This is expected while loading a save, travelling, or rebuilding the player
character. The current Speed, Auto Pickup, and No Rescue versions keep retrying.
After gameplay resumes, the log should show a single ready message. Repeated
per-frame ready messages indicate an outdated script.

### Open World is enabled but the floor remains vanilla

Confirm that `ue4ss\Mods\AincradOpenWorld\enabled.txt` exists and that
`enabled.txt.off` does not. Fully restart the game, then start a newly
constructed quest session. Do not use an OFF/ON toggle inside the mission:
Open World must already be loaded when the quest manifest is constructed.

### The game crashes at startup

The most common configuration error is loading one Lua mod twice. Remove custom
gameplay mods from `mods.txt` and `mods.json` when their folders already contain
`enabled.txt`.

Also check that files from different releases were not mixed inside one mod
folder.

### Where to find diagnostics

The main log is:

```text
...\EchoesofAincrad\Binaries\Win64\ue4ss\UE4SS.log
```

When reporting a problem, include:

- The relevant end of `UE4SS.log`.
- The mod name.
- Whether the problem happened at game launch, save load, travel, quest start,
  Start Menu navigation, or combat.
- Whether the mod was ON or OFF when the game launched.

Keep debug logging disabled during normal play. Verbose per-frame or per-object
logs can grow quickly and make diagnosis harder.

## Updating or uninstalling

Always close the game before replacing loader or mod files.

To update a mod, replace its complete folder with one coherent release. Do not
copy only `main.lua` from a different version into an older folder.

To uninstall one gameplay mod, remove its folder from `ue4ss\Mods` and restart
the game.

To remove UE4SS entirely, close the game and remove the `dwmapi.dll` and
`ue4ss` files that were installed from the Nexus package. Do not remove the
game's shipping executable or other original game files.

## Credits and release references

Credits, permissions, changelogs, downloads, and support threads are maintained
on the corresponding Nexus Mods pages:

- [UE4SS](https://www.nexusmods.com/echoesofaincrad/mods/7)
- [Terrain Runner SpeedMod](https://www.nexusmods.com/echoesofaincrad/mods/45)
- [Auto Pickup Mod](https://www.nexusmods.com/echoesofaincrad/mods/19)
- [No Rescue — Real Falls](https://www.nexusmods.com/echoesofaincrad/mods/35)
- [Aincrad Open World](https://www.nexusmods.com/echoesofaincrad/mods/55)
- [Field Equipment Mod](https://www.nexusmods.com/echoesofaincrad/mods/64)
