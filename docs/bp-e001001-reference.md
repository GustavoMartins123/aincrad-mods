# BP_E001001 asset reference

This is a durable reference extracted from a local FModel dump of the Blue Boar
enemy Blueprint. It records asset relationships useful to World Enemy Director
and future mods; it is not a replacement for inspecting the live actor after a
game update.

## Asset identity

| Item | Reference |
|---|---|
| Blueprint package | `/Game/ROD/Blueprints/Characters/Enemies/001_Boars/BP_E001001` |
| Generated class | `BP_E001001_C` |
| Class default object | `Default__BP_E001001_C` |
| Parent Blueprint class | `/Game/ROD/Blueprints/Characters/Enemies/000_Common/BP_EnemyCharacter.BP_EnemyCharacter_C` |
| Enemy ID | `1001` |
| Enemy level | `1` |
| Enemy skin type | `BlueBoar` |

## Component and material ownership

`BP_E001001_C` owns the three additional `HeroCollider` capsule components and
a parkour component, but its visible `CharacterMesh0` is inherited:

```text
BP_E001001_C:CharacterMesh0
  template -> BP_EnemyCharacter_C:CharacterMesh0
```

The child template is a `RODSkeletalMeshComponent` and overrides its physics
asset with:

```text
/Game/ROD/CHR/Enemies/001_Boars/Shared/PHYS_ES_E001_HitVolume
```

Its local transform is `(-30, 0, -75)` and local scale is `(1.5, 1.5, 1.5)`.
The dumped child template contains neither `SkeletalMesh`, `OverrideMaterials`,
nor a material parameter array. Therefore it is not evidence for a parameter
named `Color`, and the boar Blueprint itself is not the asset that selects its
visible material.

## Implication for material investigation

Inspect the parent package next:

```text
/Game/ROD/Blueprints/Characters/Enemies/000_Common/BP_EnemyCharacter
```

Follow `CharacterMesh0` there to `SkeletalMesh` and then to every material slot
or `OverrideMaterials` entry. Inspect the resulting `MaterialInstance`
`VectorParameterValues` values. If the parent also contains no assignment, the
assignment is runtime-driven and must be inspected on a live natural enemy.

## Confirmed runtime mesh assignment

The parent dump also contains no `SkeletalMesh` or `OverrideMaterials` value on
`CharacterMesh0`. This is expected: `BP_EnemyCharacter_C` overrides
`SetupAsset`, while native `ARODEnemyCharacter` exposes
`SynchronousLoadAndSetMesh`. The native runtime field `EnemyAssetData` points
to `URODEnemyAssetData`, whose `Mesh` property supplies the skeletal mesh.

Consequently, the canonical material inspection target is a live, fully
initialized natural enemy, after `SetupAsset` has completed. Static Blueprint
dumps cannot establish the visible material or a valid colour parameter for
this enemy family.

## Live material resolution (verified)

An in-world `BP_E001001_C` instance resolved `CharacterMesh0` to:

```text
/Game/ROD/CHR/Enemies/001_Boars/E001001/SK_CHR_E001001
```

`CharacterMesh0.OverrideMaterials` contained two real dynamic instances, in
slot order:

| Slot | Dynamic instance parent |
|---|---|
| 0 | `/Game/ROD/CHR/Enemies/001_Boars/E001001/Materials/MI_CHR_E001001_Eye` |
| 1 | `/Game/ROD/CHR/Enemies/001_Boars/E001001/Materials/MI_CHR_E001001` |

Both live instances contained the vector override:

```text
Name = Color
Value = (R=0.56, G=0.08, B=0.92, A=1.0)
```

That value exactly matches World Enemy Director's `violet` preset. Thus the
director's current call reaches the actual `MaterialInstanceDynamic` objects.
It does **not** mean that `Color` is a declared shader parameter. Unreal can
retain a dynamic override even when the compiled material does not consume it.

## Parameter result (verified)

The complete persistent parent chain for the two slots is:

```text
slot 0: MID -> MI_CHR_E001001_Eye -> M_CHR_Cel_Enemies
        -> M_CHR_Cel_MaterialTypes_Inst -> M_CHR_Cel_MaterialTypes

slot 1: MID -> MI_CHR_E001001 -> M_CHR_Cel_Enemies_Big
        -> M_CHR_Cel_MaterialTypes_Inst -> M_CHR_Cel_MaterialTypes
```

`Color` occurs only in the two runtime `MaterialInstanceDynamic` overrides
created by the director. It occurs in none of the persistent material-instance
layers. The two asset-specific parent instances instead both expose:

```text
BC = (R=0.895833, G=0.686177, B=0.576916, A=1.0)
ExpressionGUID = 8AAA20D246BED27B84212F98636D6890
```

The matching non-empty expression GUID on both body and eye slots proves that
`BC` is exposed, but it is not a usable live tint path for this variant: both
asset instances set the `BC_Texture` static switch to `true`, and an isolated
runtime write to `BC` produced no visible change.

The shared preset instances instead enable the `addFresnel_On` static switch
and expose this HDR vector parameter on both material paths:

```text
addFresnel_color = (R=0.0, G=1.767918, B=3.0, A=1.0)
ExpressionGUID = EBDC64694B77D865BDD3A7A93858E042
```

This is the evidence-backed colour channel for the Blue Boar family. The
director therefore targets `addFresnel_color`, which produces a coloured
Fresnel/rim-light effect rather than replacing the albedo texture. Test it on
a newly initialized actor with `COLOR_MODE = "fixed"` before treating the name
as valid for another enemy material family.

Do not treat interface membership or a void `SetMaterialColorParameter` call as
proof that a material parameter exists.
