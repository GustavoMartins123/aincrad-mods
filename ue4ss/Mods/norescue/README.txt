norescue 0.5.0 — real falls for Echoes of Aincrad
==================================================

Normally EoA never lets you fall: it steers you away from ledges, and if you
do drop too far (past 780 units) your character collapses and gets teleported
back to the last safe spot. This mod turns both off — you walk off a ledge,
you fall, you land. Hard landings still play their stagger/roll animations.

Water is untouched: swimming, drowning and the deep-water teleport all work
exactly as before. Same for pit / out-of-bounds teleports — this mod only
changes falling.

No performance cost: the mod does no per-frame work (it re-applies its two
settings on respawn/zone load and runs a tiny check every 5 seconds).

REQUIREMENTS
------------
UE4SS for Echoes of Aincrad (the EoA-adapted build from Nexus). The stock
UE4SS release does NOT work with this game.

INSTALL
-------
1. Extract the "norescue" folder into your game's UE4SS mods folder:
   ...\Echoes of Aincrad\EchoesofAincrad\Binaries\Win64\ue4ss\Mods\
2. That's it — the included enabled.txt activates it.
   IMPORTANT: do NOT also add norescue to mods.txt or mods.json. A mod that
   is both in a registry and has enabled.txt loads twice and crashes the game.
3. To uninstall, delete the norescue folder.

CONFIG (optional)
-----------------
Edit Scripts\config.lua:
  ENABLED              — master switch (default true)
  DEATH_LANDING_HEIGHT — set 0 to keep the game's fall-teleport but still
                         disable the edge nudge (default: teleport fully off)

Linux/Steam Deck: works the same under Proton.

Source & issue reports: https://github.com/Deaththegrim/echoes-of-aincrad-mods
