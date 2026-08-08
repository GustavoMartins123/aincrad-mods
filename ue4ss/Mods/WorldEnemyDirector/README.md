# World Enemy Director

World Enemy Director **v1.8.1 Beta** is a UE4SS Lua/C++ mod for **Echoes of
Aincrad**.

It can increase enemy population around the player and apply configurable
mutations to enemy size, colour, health, attack, defence, movement speed and
experience rewards.

The current release is marked **Beta** because the direct-spawn combat contract
is not fully solved yet. The collision, AI and registry validation introduced in
1.8.1 reduces invalid additional enemies, but does not eliminate every case.

## Beta combat limitation

Some additional enemies may occasionally fail to exchange damage correctly
with the player. Companion attacks generally continue to work. The remaining
combat-initialization issue is under investigation.

This version should not be described as completely fixing the previous
invincible-enemy bug.

A more accurate summary is:

```text
Reduced cases of non-functional additional enemies and added collision-channel
repair, AI validation, registry validation and stable admission checks.
```

## Requirements

- Echoes of Aincrad **1.0.3**.
- The Echoes of Aincrad-compatible UE4SS build.
- The native bridge included in `dlls/main.dll`.

The [Echoes of Aincrad Mod Menu](https://www.nexusmods.com/echoesofaincrad/mods/84)
is optional.

World Enemy Director implements its own runtime settings reader and works as a
standalone installation.

## Installation

Copy the complete `WorldEnemyDirector` folder to:

```text
[Your Game Folder]\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\
```

The final installation must include:

```text
WorldEnemyDirector\
├── enabled.txt
├── README.md
├── dlls\
│   └── main.dll
└── Scripts\
    ├── config.lua
    ├── main.lua
    └── modmenu.lua
```

Confirm that these files exist:

```text
ue4ss\Mods\WorldEnemyDirector\Scripts\main.lua
ue4ss\Mods\WorldEnemyDirector\dlls\main.dll
```

Fully restart the game after installing or updating the mod.

Do not distribute machine-local files created by the Mod Menu:

```text
Scripts\runtime.lua
Scripts\runtime.lua.*
Scripts\runtime.rev
```

## Main Features

- Keeps the game's natural enemy actors.
- Adds configurable additional enemies around natural origins.
- Can create additional enemies in otherwise empty areas.
- Supports total population multipliers from `1x` to `8x`.
- Limits queued, pending and active additional enemies through a global cap.
- Uses NavMesh projection and path validation before issuing an additional
  enemy.
- Uses only enemy classes already loaded naturally in the active world.
- Never randomises a mission boss species.
- Provides separate mutation profiles for the reflected Common, Elite and Boss
  roles.
- Supports separate health, attack, defence, movement-speed and experience
  multipliers for each profile.
- Supports configurable visual scale.
- Supports fixed or random colour presets through the game's material-parameter
  interface.
- Can put distant additional enemies to sleep to reduce AI and tick cost.
- Supports live configuration through the optional Mod Menu.
- Includes detailed status and debug diagnostics.

## Configuration

Edit:

```text
WorldEnemyDirector\Scripts\config.lua
```

or open **Mods → Enemy Director** through the optional Mod Menu.

The configuration is strict. Every required key must exist with the expected
type and range. Unknown keys, malformed Lua, invalid relationships and
unsupported values stop director operations instead of applying a partial
configuration.

### Population

```lua
SPAWN_MULTIPLIER = 1
MAX_ACTIVE_EXTRAS = 48
SPAWN_RADIUS = 300.0
DESPAWN_RADIUS = 6000.0
SPAWN_IN_EMPTY_AREAS = true
RANDOMIZE_EXTRA_SPECIES = false
```

`SPAWN_MULTIPLIER = 1` preserves the original population and adds nothing.
Higher values request up to `SPAWN_MULTIPLIER - 1` additional enemies for an
eligible natural origin.

`MAX_ACTIVE_EXTRAS` limits the combined queued, pending and already issued
additional population.

`SPAWN_RADIUS` controls the NavMesh search area around the origin.

Despite its historical name, `DESPAWN_RADIUS` does not forcibly destroy an
already issued actor. It limits which origins can issue new work and removes
queued requests that moved out of the active area. Death, pooling, despawn and
world teardown remain owned by the game.

`RANDOMIZE_EXTRA_SPECIES` selects only from compatible enemy classes already
loaded naturally in the current world. It never synchronously loads arbitrary
Blueprint assets during streaming.

### Mutation profiles

The current configuration exposes three profiles:

```text
COMMON_*
ELITE_*
BOSS_*
```

Each profile has independent values for:

```text
HEALTH_MULTIPLIER
ATTACK_MULTIPLIER
DEFENCE_MULTIPLIER
MOVE_SPEED_MULTIPLIER
XP_MULTIPLIER
```

The profile is selected from the enemy's reflected `EnemyRole`. This is an
internal mutation role, not a guarantee that the player-facing appearance or
difficulty label matches the same category.

Some enemies that visually appear stronger may still use the game's Common
role. Conversely, some normal field variants may use a Boss-related internal
role. The director follows the reflected runtime value rather than guessing by
Blueprint name or visible strength.

### Mission-boss protection

Mutation profile selection and spawn protection are separate decisions.

The director identifies a mission boss through mission-specific staging data,
including:

```text
GoldenGateBoss
BossEventSequence
BossFinisherLevelSequence
```

A mission boss is excluded from population multiplication and species
randomisation.

`INCLUDE_BOSSES` controls whether actors using the Boss mutation profile may
receive configured stat mutations. It does not make mission bosses eligible as
additional spawn origins.

This distinction is intentional because `EnemyRole` alone does not reliably
identify the actual mission boss.

### Scale

```lua
SCALE_MIN = 1.0
SCALE_MAX = 1.0
```

A stable random scale is selected once per tracked enemy between the configured
minimum and maximum.

The current implementation applies size to the enemy actor while restoring the
skeletal mesh to its authored relative scale. Scaling the actor keeps the
visible body and its collision hierarchy in the same coordinate space.

This replaced the older mesh-only approach, where a visually enlarged enemy
could remain inside an unscaled collision capsule and player attacks could pass
through the rendered body.

### Colour

```lua
COLOR_MODE = "off"
COLOR_PRESET = "crimson"
COLOR_PARAMETER_NAME = "addFresnel_color"
```

`COLOR_MODE` accepts:

```text
off
fixed
random
```

Available presets are:

```text
crimson
emerald
azure
gold
violet
cyan
white
```

Colour uses the game's `RODMaterialParameterInterface` and the exact parameter
named by `COLOR_PARAMETER_NAME`.

A successful void interface call does not prove that the active cooked material
visibly uses the parameter. The mod therefore reads the live material instances
for diagnostics, but it does not invent a second material path or silently try
unrelated parameter names.

Some enemy materials may keep their original appearance when they do not expose
the configured parameter in a visible branch.

### Distance banding

```lua
COMBAT_RADIUS = 8000.0
LOD_ENABLED = true
LOD_DORMANT_TICK_S = 0.5
LOD_HYSTERESIS_CM = 1000.0
```

Additional enemies outside `COMBAT_RADIUS` can have their behaviour tree stopped
and their actor and movement ticks slowed.

An additional enemy is not put to sleep while it is:

- fighting;
- dying or dead;
- waiting for admission;
- recently rendered on screen.

`LOD_HYSTERESIS_CM` prevents repeated sleep/wake changes near the distance
boundary.

Distance banding is a performance feature rather than a correctness contract.
If it cannot safely classify an enemy, that enemy remains at full simulation
instead of stopping population management.

## Spawn and admission process

The director keeps every natural actor. It does not destroy and replace quest
enemies, because quest tracking may retain the exact actor created by the game.

Additional enemies are issued through the deferred actor-spawn path and then
registered into the game's enemy collections through the native bridge.

Before an additional enemy is accepted as active, the director verifies:

- the actor completed its normal initialization lifecycle;
- actor collision is enabled;
- the root capsule hierarchy is valid;
- movement is active and bound to the root capsule;
- the AI controller possesses the expected enemy;
- the behaviour tree is running and not paused;
- Blackboard, path-following and perception components are available;
- the actor is registered in both required native enemy collections;
- the physical contract remains stable across three admission samples.

The candidate remains unmutated until admission succeeds.

## Collision-channel repair

A profile name such as `Pawn` or `Custom` is not enough to describe the real
collision behaviour. Unreal stores the effective response for every collision
and trace channel separately.

The director captures the complete physical contract from a natural enemy of
the same class, including:

- root capsule responses;
- multi-capsule responses;
- extra body-part capsule responses;
- component identity and attachment relationships;
- collision size and body availability.

When a newly issued enemy differs, the director realigns the affected channel
responses through `SetCollisionResponseToChannel` and verifies the contract
again before admission.

This specifically targets cases where an additional enemy existed physically
but one attack trace channel changed from its natural response, causing some
attacks to pass through it.

The repair has reduced the previous fully non-functional spawn cases, but the
remaining player-versus-enemy damage issue shows that collision responses are
not the only initialization contract involved.

## Combat attributes

The director waits for the enemy's native initialization before resolving its
Gameplay Ability System attributes.

It requires the reflected contracts for:

```text
Health
MaxHealth
ATK
BaseATK
Def
BaseDEF
```

Health, attack and defence changes are applied as verified additive Gameplay
Ability System deltas. Attack and defence target their mutable base attributes
and then verify the calculated final values.

Live health changes preserve the current HP percentage.

The corresponding source fields are also kept synchronized because other game
systems read them for enemy parameters and rewards.

Movement speed updates the reflected value and calls the enemy's own
`SetMovingSpeed` function.

Experience changes update the reflected enemy reward value.

## Runtime configuration

The Mod Menu writes optional overrides to:

```text
Scripts\runtime.lua
```

World Enemy Director reads `config.lua`, overlays `runtime.lua`, validates the
complete result and then applies it.

Runtime publication uses:

```text
runtime.lua.next
runtime.lua.lock
runtime.rev
```

While a transaction lock exists, the director keeps its previous validated
settings and does not read a partially written table.

Changes to population shape may pause and rebuild director work. Existing
issued actors remain under the game's lifecycle rather than being destroyed to
force the new cap immediately.

## Travel and world transitions

The director distinguishes cross-world travel from same-world repositioning.

During travel it pauses new work, clears outgoing Lua references and asks the
native bridge to sanitize only exact object graphs belonging to issued enemies.
The game remains authoritative for actor destruction and world teardown.

Same-world quest or checkpoint transitions use a short quarantine. The current
quest-teleport settlement period is approximately two seconds before director
processing resumes.

A `ClientRestart` after a real world transition starts a clean scan. A
standalone `ClientRestart` inside the same world retains known ownership so an
existing additional enemy is not rediscovered as a natural origin and
multiplied again.

## Diagnostics

Run:

```text
enemy_director_status
```

in the UE4SS console.

The command reports configuration health, world pause and fault state, natural
and owned enemy counts, queued requests, pending initialization, admitted
actors and loaded enemy classes.

Set:

```lua
DEBUG_LOGS = true
```

only while diagnosing. Normal operation avoids per-tick logging.

The UE4SS console requires:

```text
GuiConsoleEnabled = 1
```

under `[Debug]` in:

```text
UE4SS-settings.ini
```

## Known Limitations

- **Beta:** some additional enemies may occasionally fail to exchange damage
  correctly with the player. Companion attacks generally continue to work.
- The remaining combat-initialization issue is not considered fixed in 1.8.1.
- Only enemy classes already loaded naturally in the current world can be used
  for species randomisation.
- Natural quest actors are intentionally not replaced.
- Internal Common, Elite and Boss mutation roles do not always match the
  player's visual interpretation of enemy strength.
- Mission-boss detection depends on readable mission staging fields. An
  unreadable result fails closed and protects the class from multiplication.
- A class discovered as a mission-boss class is removed from the population
  catalog for that world.
- `DESPAWN_RADIUS` does not forcibly remove an already issued actor.
- A material without the exact configured parameter may keep its original
  appearance.
- Additional spawns depend on the active NavMesh and current World Partition
  readiness.
- Actor creation, registration or admission failures may pause spawning and
  retry after a backoff instead of repeatedly issuing invalid actors.
- Future game updates may change reflected classes, offsets, attributes,
  collision channels, material parameters or lifecycle behaviour.

## Credits

Built for UE4SS.

Echoes of Aincrad and all related game assets and trademarks belong to their
respective owners.
