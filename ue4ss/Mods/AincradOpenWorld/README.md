# Aincrad Open World

Free roam for Aincrad. The mod adds dedicated **"Floor 1 : Free Roam"** and **"Floor 2 : Free Roam"**
entries to the town quest terminal, and taking one loads the **entire floor as an open world**: the
full detailed map, every region's enemies, treasure chests, and terminals active from the start, no
quest barriers, and no out-of-bounds punishment. The vanilla quest entries are untouched — the free
roam entries are separate duplicates, so you can always play everything exactly as shipped.

On top of that, **every regular field quest you take also opens its whole floor** — take any quest
and roam far beyond its objective area, with all regions alive.

## How a session works

Pick a Free Roam entry at the terminal (it appears alongside the vanilla quest it is based on). You
load into the floor with everything active. The underlying quest objective stays live as the natural
way to end the session: complete it whenever you are ready to collect the reward, or Give Up to
return to town. Nothing about your save is modified.

## Installation

1. Download and unzip.
2. Drop the AincradOpenWorld folder into your UE4SS Mods folder:
   `...\Echoes of Aincrad\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\`
3. Launch the game. The included enabled.txt loads it automatically.

To uninstall, delete the AincradOpenWorld folder. Your quests and save are unaffected.

## Configuration (Scripts/config.lua)

Edit, save, restart the game.

| Setting | Default | What it does |
|---|---|---|
| `ENABLED` | `true` | Master switch. |
| `FREE_ROAM_QUESTS` | Floor 1 + Floor 2 | Which quests get a Free Roam duplicate, and the label shown. Keys are QuestIds. |
| `FREE_ROAM_DESCRIPTION` | (text) | The description shown in the terminal info panel for Free Roam entries. |
| `EXCLUDE_QUEST_IDS` | `{}` | Quests to leave completely vanilla (no floor opening) if one misbehaves. |
| `DEBUG_LOGS` | `false` | Verbose diagnostics to UE4SS.log. |
| `PROBE_MODE` | `false` | Loads the development probe (`ow` console commands). Not needed for play. |

The Free Roam entry for a floor appears when its base quest is available at the terminal:
Floor 1 uses quest 20036, Floor 2 uses quest 20024 ("A Woman's Intuition", from Urbas).

## How it works (short version)

Quest setup in this game is driven by a per-quest manifest that lists which regions and barriers the
quest activates. The mod grows that manifest at load time so it covers the whole floor, and the
game's own initialization does the rest — real spawns, real chests, real terminals, real map. The
Free Roam entries are duplicates of the designated quests, launched through the game's own free
quest variant system, so starting and finishing them uses only native game flow. Full technical
notes live with the project.

## Compatibility

Works alongside other UE4SS Lua mods. Save-safe: everything happens to runtime data, nothing is
written to your save file.
