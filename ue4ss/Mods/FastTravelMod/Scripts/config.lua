-- FastTravelMod settings.
-- The in-game Mods menu writes per-machine overrides to runtime.lua.

return {
    -- Adds a separate "Fast Travel" row to the Start Menu.
    -- A change takes effect the next time the Start Menu is constructed.
    ENABLED = true,

    -- Extra focus, map-destination and catalog messages in UE4SS.log.
    DEBUG_LOGS = false,

    -- Which map screen the Fast Travel row opens. They are different widgets and
    -- they accept different destinations:
    --
    --   "fasttravel" -> WBP_Map_FastTravel_C (URODFastTravelMenuWidget), the
    --                   picker a terminal normally opens. This is the native
    --                   fast travel presentation and confirming a checkpoint on
    --                   it is measured working. It states its own scope in its
    --                   banner -- "Escolha para qual Area Segura ou Terminal de
    --                   Teletransporte voce vai" -- so map pins are drawn on it
    --                   but cannot be confirmed. Use "fasttravel pin <index>"
    --                   in the UE4SS console for those.
    --
    --   "map"        -> WBP_Map_C (URODMapMenuWidgetBase), the reference map,
    --                   titled "Mapa". Its cursor stops on every icon, so it is
    --                   the only screen where a pin could be confirmed, and the
    --                   mod intercepts the confirm before the game places a
    --                   marker with it. That interception has never been
    --                   observed working, and this screen is not the game's
    --                   fast travel UI, so it is opt-in rather than default.
    MAP_TARGET = "fasttravel",

    -- Only used when MAP_TARGET is "map".
    -- The FName handed to ARODAvatarCharacter::ActivateFPCameraMenuAbility as
    -- MenuKey. It selects the opening level sequence in GA_AvatarMenu_Map_C's
    -- LevelSequenceMap, and without a key that resolves there the ability
    -- activates but never displays the map.
    --
    -- Leave empty to resolve it automatically: the mod reads the ability's own
    -- LevelSequenceMap and watches what the game passes when it opens its own
    -- first-person-camera menus. Run "fasttravel menukeys" in the UE4SS console
    -- to see both. Set an exact key here only to override that.
    MAP_MENU_KEY = "",
}
