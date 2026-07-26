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
| Spawn radius | 100-1500 cm | Random horizontal distance from the natural spawn |
| Random extra species | On/Off | Chooses among enemy classes already loaded by the current world |
| Mutate bosses | On/Off | Allows mutations on natural bosses; bosses are never multiplied or randomised |
| Minimum/maximum scale | 0.25x-4x | Stable random scale range per actor |
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
through `GameplayStatics.BeginDeferredActorSpawnFromClass` and
`FinishSpawningActor`, then applies the source enemy's level through
`SetEnemyLevel`. Ownership is tied to the exact returned actor object; proximity
is never used to claim an actor. Natural actors remain unowned and are never
destroyed by this mod.

Random species are selected only from natural enemy classes already loaded in
the active world. The mod does not synchronously load arbitrary Blueprint
assets during streaming, because native asset loads in that phase can crash the
process.

Reducing the multiplier removes only extras above the new target. Killed extras
are not recreated indefinitely. Travel immediately clears all Lua object
references; processing resumes only after the game's `ClientRestart` signal and
the fixed settlement period.

The safe lobby and a mission are separate worlds. `ClientRestart` preserves the
configured `ENABLED` state, discards the previous world's references, and
requests a fresh enemy scan after settlement. An enabled director therefore
starts in each mission automatically; an OFF/ON toggle is not part of the
activation flow.

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
  entire class is quarantined from spawning for the current world. Queued,
  initializing, or already-owned extras of that class are removed.
- Quest-end hooks destroy owned extras and release all world references before
  Unreal begins collecting the outgoing mission.
- A material that lacks the exact configured colour parameter will keep its
  original appearance and produce an explicit error.
- Actor creation or initialization failures are reported and are not retried
  silently.

## Reverse-engineering references

Implementation contracts were checked against the public
[`toeofcharmander/mod_template`](https://github.com/toeofcharmander/mod_template)
headers, enemy curve tables, and schemas for Echoes of Aincrad. The UE4SS
out-parameter contract used to enumerate `FGameplayAttribute` values was also
checked against the official
[`UE4SS-RE/RE-UE4SS`](https://github.com/UE4SS-RE/RE-UE4SS) Lua binding source
and documentation. Every returned struct element is read once through its
canonical parameter wrapper's `get()`.
No code or assets are loaded from either repository at runtime.
