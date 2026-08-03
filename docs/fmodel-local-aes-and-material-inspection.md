# Inspecting local encrypted assets with FModel

This procedure exists to inspect the materials actually used by **Echoes of
Aincrad** assets, especially while diagnosing World Enemy Director colour
mutation. It applies only to the local game installation being investigated.

## Security boundary

The game's pak AES key is private runtime material. Never put it in source,
documentation, screenshots, logs, issue reports, chat transcripts, or a
repository. Do not use a guessed key or a key copied from another installation.
If recovery or validation fails, stop and report the failure explicitly.

## FModel setup

1. Start FModel with its own installation directory as the working directory.
   Its **Output Directory** must be FModel's own output folder, not a folder
   inside the game installation.
2. In `Directory > Selector`, select the game directory that contains the
   `Content` folder:

   ```text
   <game-root>\EchoesofAincrad
   ```

3. Select `GAME_UE5_3`.
4. Do not use `Content\Paks` as FModel's game directory. FModel finds the
   archives beneath the selected game directory.

The `Could not load virtual paths, plugin manifest may not exist` warning does
not supply a key and is not a successful package load. The authoritative check
is a non-zero package count after the archives are loaded.

## Generate a mapping for unversioned packages

This game uses unversioned UE5 package properties. An AES key lets FModel read
the archives, but it cannot decode a Blueprint's property names without a
matching `.usmap` file. Do not use a mapping taken from another game or an older
game build.

The installed UE4SS build can generate the mapping from the running game:

1. Start the game and enter a playable area containing the target enemy, so its
   Blueprint class is loaded.
2. Press `Ctrl` + numeric keypad `6` (with Num Lock enabled). This is the
   installed `Keybinds` mod's `DumpUSMAP` binding.
3. Wait for UE4SS to report `Mappings Generation Completed Successfully`.
   It creates a `*.usmap` file beside the installed `UE4SS.dll`; in this
   installation that is `Binaries\Win64\ue4ss`. The generated filename can
   vary.
4. In FModel, open `Settings`, enable **Local Mapping File**, select that exact
   `*.usmap` file, save, and restart FModel.

If the completion message or the output file is absent, treat generation as a
failure and stop there. A generic mapping can omit the game's Blueprint
classes and make FModel silently decode fields incorrectly.

## Recover the key from the local running game

The key is present in the game's memory once it has loaded the pak archives.
Launch the game and enter a playable world before scanning.

Use a scanner that does all of the following:

1. Opens **`EchoesofAincrad-Win64-Shipping.exe`**, not the outer
   `EchoesofAincrad.exe` launcher. Both can exist at the same time; scanning the
   launcher is a false target and will report no key.
2. Enumerates committed readable memory regions and reads them without writing
   to the process.
3. Tests 32-byte candidate windows aligned to 16 bytes as AES-256 keys.
4. Validates each candidate against the encrypted first index block of the
   locally installed `pakchunk0-WindowsClient.pak` archive using AES-256 ECB.
5. Accepts a candidate only when decryption produces a plausible Unreal pak
   index mount-point `FString` (a valid positive length followed by `.` or `/`).

This validation is essential: a RAM scan finds many arbitrary 32-byte values;
the pak-index check distinguishes the real key from random memory. The public
[`aincrad-save-editor`](https://github.com/Deaththegrim/aincrad-save-editor)
implements this process in its local **Recover from running game** action. Its
source is the reference for the scanner behaviour, not a source of a key.

When recovery succeeds, paste the value directly into `Directory > AES` as the
main key in FModel. Do not persist, print, or copy the value anywhere else.

## Load and inspect the target material

1. In FModel's **Archives** view, load all archives.
2. Confirm that the package count is non-zero. An encrypted-archive error means
   the key was not accepted; do not continue as though packages were loaded.
3. Search for the enemy Blueprint, for example `BP_E001001`.
4. In its properties, follow the `Mesh` component to its `SkeletalMesh`.
5. Open each entry in the skeletal mesh `Materials` array.
6. In a `MaterialInstance`, inspect `VectorParameterValues` and record only the
   exposed `ParameterInfo.Name` values. If necessary, walk to the parent
   material instance as well.

`COLOR_PARAMETER_NAME` must match an actually exposed vector parameter for the
material slot being changed. `RODMaterialParameterInterface` membership alone
does not prove that a parameter named `Color` exists or that the call affects a
real material instance.

For the recorded inheritance chain of the inspected Blue Boar, see
[`BP_E001001 asset reference`](bp-e001001-reference.md).

## Inspect a runtime-assigned enemy mesh

Some enemy Blueprints intentionally leave `CharacterMesh0` without a static
`SkeletalMesh`. The game assigns it after the actor initializes. For those
enemies, use the installed UE4SS Live Viewer instead of continuing through
static Blueprint packages:

1. Load a playable area containing a **natural** instance of the target enemy.
2. Open the UE4SS GUI Console and select the **Live View** tab. Both required
   GUI settings are already enabled in the local UE4SS configuration.
3. Right-click the search box, enable **Instances only**, then search for the
   generated class name, for example `BP_E001001_C`.
4. Select an actual actor instance, never `Default__BP_E001001_C`.
5. Follow `Mesh` to `CharacterMesh0`, then record its `SkeletalMesh`,
   `OverrideMaterials`, and `Materials` entries. Also inspect `EnemyAssetData`
   and its `Mesh` value when present.
6. Open every resolved `MaterialInstance` and record exposed
   `VectorParameterValues.ParameterInfo.Name` values.

This procedure is read-only. Do not call `SetupAsset`,
`SynchronousLoadAndSetMesh`, or any material setter from Live View while
diagnosing the asset graph.

## Distinguish a write from a visible colour change

`SetMaterialColorParameter` is a void interface call. A dynamic material can
store a value under any `FName`, including a name that no compiled material
expression consumes. Seeing a value in a live MID therefore proves only that
the write reached that MID.

Walk every persistent parent material instance and distinguish these cases:

| Result | Meaning | Required response |
|---|---|---|
| The name exists only in a MID created at runtime | The setter wrote an unconsumed override. | Reject that name as the colour parameter. |
| The name appears in a parent `VectorParameterValues` entry with a non-empty `ExpressionGUID` | It is a real exposed parameter candidate. | Make one isolated visual test on the exact enemy/material family. |
| The name is absent from every material layer | It is not established as usable. | Do not configure or claim it as a valid global parameter. |

For `BP_E001001_C` specifically, the observed `Color` value matched the
director's violet preset but existed only on the live MIDs. Both actual parent
slots expose `BC` with the same expression GUID. This identifies the reason
the current `Color` configuration has no visible effect and supplies `BC` as
a species-specific test candidate; it does not establish a global name for all
enemy material families.

## Failure handling

| Observation | Required response |
|---|---|
| FModel reports a missing Oodle or vgmstream support DLL | Repair or update the FModel installation, then start it from its own directory. |
| Scanner reports no key | Verify that the playable world is loaded and that the scanner selected the Shipping process; then scan again. |
| Candidate does not decrypt the local pak index | Reject it. Do not try to force it into FModel. |
| FModel still reports encrypted archives after the key is supplied | Treat the key entry as rejected and re-run local recovery/validation. |
| A material has no exposed suitable vector parameter | Record that result; do not invent a parameter name or claim that the current material can be tinted. |
