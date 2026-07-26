# World Enemy Director

World Enemy Director is a UE4SS Lua mod for **Echoes of Aincrad**. It can add
extra enemies beside the game's natural spawns and alter their visible scale,
material colour, health, attack, defence, movement speed, and experience value.

The mod preserves every natural enemy actor. This is deliberate: destroying and
replacing the actor created by a quest can break objective tracking. Species
randomisation therefore applies only to additional enemies owned by this mod.

## Installation

Place this directory at:

```text
EchoesofAincrad\Binaries\Win64\ue4ss\Mods\WorldEnemyDirector
```

Keep `enabled.txt` in the mod root, then restart the game. When the integrated
ModMenu is installed, open the game's Start Menu, choose **Mods**, and expand
**Enemy Director**.

## Settings

| Setting | Range | Behaviour |
|---|---:|---|
| Spawn multiplier | 1x-8x | Total population per natural enemy; 1x adds nothing |
| Maximum extras | 0-200 | Global cap covering live, queued, and pending extras |
| Spawn radius | 100-1500 cm | Radius for reachable NavMesh candidates around the natural spawn |
| Random extra species | On/Off | Chooses among enemy classes already loaded by the current world |
| Mutate bosses | On/Off | Allows mutations on natural bosses; bosses are never multiplied or randomised |
| Minimum/maximum scale | 0.25x-4x | Stable visual scale applied to the skeletal mesh only |
| Colour mode | Off/Fixed/Random | Uses the game's material-parameter interface |
| Colour preset | Seven presets | Colour used by Fixed, or palette used by Random |
| Health/attack/defence | 0.10x-10x | Applies verified additive deltas through the enemy's Gameplay Ability System |
| Movement speed | 0.25x-3x | Changes the reflected speed and calls `SetMovingSpeed` |
| Experience | 0x-10x | Multiplies the reflected experience reward |

`Scripts/config.lua` is the required canonical configuration. The ModMenu writes
live overrides to `Scripts/runtime.lua`. Unknown keys, missing required keys,
wrong types, out-of-range values, and malformed Lua disable all director
operations explicitly. Existing natural mutations are rolled back and owned
extras are destroyed when a live configuration is rejected.

## Spawn and randomisation model

The director listens for `RODEnemyCharacter` construction and pool reuse. For
each eligible natural enemy, it creates up to `SPAWN_MULTIPLIER - 1` actors
through the game's own `RODGameState.RODSpawnActor` population path. The exact
`FRODSpawnActorOption` enables the Behavior Tree, keeps perception active, sets
the source enemy's level, selects the ordinary `Prowl` initial state, and uses
the chosen NavMesh point as `InitialStateLoc`.

Before that call, the director tests up to 12 points distributed in a
golden-angle spiral through
`NavigationSystemV1.FindPathToLocationSynchronously`. Exactly one candidate is
tested per director cycle, bounding synchronous NavMesh work even when the
multiplier and active-extra cap are high. Only a valid, non-partial
`UNavigationPath` is accepted; the UE4SS bridge's zero path-length value is not
used as a second reachability contract. The point must also remain at least 50-150 cm from
natural and already issued enemies, depending on the configured radius. A
request returns to the queue while untested candidates remain. The source
enemy is resolved by exact object identity and supplied as both the native
owner and instigator. The director reflects the live UFunction parameter order
before calling it instead of assuming header order. Creation uses
`AdjustIfPossibleButDontSpawnIfColliding`, so an occupied point is rejected
instead of stacking actors. The returned
`FRODSpawnActorResult.ServerSpawnActor` weak pointer is the sole ownership
contract; proximity is never used to claim an actor. Natural actors remain
unowned and are never destroyed by this mod.

Random species are selected only from natural enemy classes already loaded in
the active world. The mod does not synchronously load arbitrary Blueprint
assets during streaming, because native asset loads in that phase can crash the
process.

Reducing the multiplier removes only extras above the new target. Killed extras
are not recreated indefinitely. A confirmed map-travel signal immediately
releases all outgoing-world Lua references without racing Unreal's asynchronous
actor teardown. Processing resumes only after the matching `ClientRestart`
signal and the fixed settlement period.

The safe lobby and a mission are separate worlds. A `ClientRestart` that follows
confirmed travel starts a clean scan of the new world. A standalone
`ClientRestart` inside the same mission instead retains ownership of all
existing extras; forgetting that ownership would make the director rediscover
its own actors as natural spawns and multiply them again. Quest teleports pause
the director for eight seconds while retaining the same-world state. Checkpoint
fast travel uses that same quarantine because it repositions the current world
without guaranteeing a `ClientRestart`. An enabled director therefore starts
in each mission automatically; an OFF/ON toggle is not part of the activation
flow.

Before issuing any extra spawn, the initial discovery batch must remain stable
for two seconds. This gives delayed boss initialization events time to remove
their Blueprint classes from both the origin list and the randomisation catalog.

## Combat attributes

The director waits for the enemy's native `OnFinishedInitialize` lifecycle
event before accessing combat state. It then asks that enemy's `AbilitySystem`
for its reflected attributes and requires the exact `Health`, `MaxHealth`,
`ATK`, `BaseATK`, `Def`, and `BaseDEF` contracts. Missing or rejected attributes
produce an explicit per-enemy error; the mod does not substitute a display-only
property.

HP changes target `MaxHealth` and `Health`. Attack and defence changes target
the mutable `BaseATK` and `BaseDEF` inputs, then verify the calculated `ATK` and
`Def` outputs. All changes go through
`ARODCharacterBase.ApplyInstantGameplayEffect` as additive GAS deltas. The
director also keeps the enemy's source fields synchronized because the game
uses those fields for enemy parameter and reward calculations. Live health
changes preserve the current HP percentage. Disabling the director applies the
inverse deltas, restores the source fields, and does not silently heal damaged
enemies.

Visible size is applied to the enemy's skeletal-mesh `RelativeScale3D`, not to
the character actor root. The capsule, Character Movement component, NavMesh
agent, controller, perception origin, and Behavior Tree therefore retain their
native scale. This prevents giant visual variants from changing the movement
and detection geometry that their AI was authored for.

## Colour requirement

Colour uses one exact material parameter named by `COLOR_PARAMETER_NAME`
(`Color` by default). The enemy must implement
`RODMaterialParameterInterface`. If that contract is absent, colour mutation is
rejected for that actor and the error is written to `UE4SS.log`; the mod does not
guess another parameter or material path.

## Diagnostics

Run this read-only command in the UE4SS console:

```text
enemy_director_status
```

It reports configuration health, world pause/fault state, natural and owned
enemy counts, queued creations, actors pending initialization, and loaded enemy
classes.
Enable `DEBUG_LOGS` only while diagnosing; normal operation avoids per-tick
logging.

## Known limitations

- Only classes already loaded naturally in the current world can be randomised.
- Natural quest actors are intentionally not replaced.
- `EnemyRole_Boss` and `GoldenGateBoss` actors are permanently excluded from
  the spawn catalog and multiplication origins. The boss setting affects
  mutations only.
- If a mission promotes a normally common Blueprint class to boss role, that
  entire class is quarantined from spawning for the current world. Queued
  requests are removed. If the class is identified only after an owned actor
  has already been issued, the director fails closed and requires a mission
  restart instead of destroying an actor during asynchronous initialization.
- Quest-end hooks release all outgoing-world Lua references before Unreal
  begins collection. Unreal remains the authoritative owner of actor teardown.
- A material that lacks the exact configured colour parameter will keep its
  original appearance and produce an explicit error.
- A spawn is skipped with an explicit error only after all 12 NavMesh path
  candidates fail. A NavMesh that is still building or locked keeps the
  request queued without consuming its candidate budget.
- An actor-creation contract failure rolls back current director changes,
  clears queued work, and pauses the director after one concise `WORLD ERROR`.
  The same invalid native call is not retried or expanded into repeated Lua
  stack dumps.
- Actor initialization failures are reported and are not retried silently.

## Reverse-engineering references

Implementation contracts were checked against the public
[`toeofcharmander/mod_template`](https://github.com/toeofcharmander/mod_template)
headers, enemy curve tables, navigation declarations, and
`FRODSpawnActorOption` schema for Echoes of Aincrad. The UE4SS parameter
contract used for `FGameplayAttribute` enumeration was also checked against the
official
[`UE4SS-RE/RE-UE4SS`](https://github.com/UE4SS-RE/RE-UE4SS) Lua binding source
and documentation. Every returned struct element is read once through its
canonical parameter wrapper's `get()`.
No code or assets are loaded from either repository at runtime.
