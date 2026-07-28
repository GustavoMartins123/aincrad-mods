-- FastTravelMod settings.
-- The in-game Mods menu writes per-machine overrides to runtime.lua.

return {
    -- Adds a separate "Fast Travel" row to the Start Menu.
    -- A change takes effect the next time the Start Menu is constructed.
    ENABLED = true,

    -- Extra focus, map-destination and catalog messages in UE4SS.log.
    DEBUG_LOGS = false,

    -- Which map screen the Fast Travel row opens. They are different widgets:
    --   "fasttravel" -> WBP_Map_FastTravel_C (URODFastTravelMenuWidget), the
    --                   destination picker a terminal normally opens, reached
    --                   here through ARODPlayerState::OpenMenu(FastTravelMenu).
    --   "map"        -> WBP_Map_C (URODMapMenuWidgetBase), the reference map
    --                   titled "Mapa / Detalhes da Area de Missao", reached
    --                   through the GA_AvatarMenu_Map_C ability. Kept for
    --                   diagnosis; it is not the fast travel screen.
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
