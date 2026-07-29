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

    -- Escape hatch. A viewport change such as Alt+Enter can leave the map screen
    -- up with its input dead: Cancelar does nothing and nothing in the game
    -- closes it. This key force-closes it and resets the mod's state. It is a
    -- UE4SS keybind, so it is processed outside the game's input and still works
    -- when the screen has stopped responding. Same as "fasttravel close".
    -- Any name from UE4SS's Key table; empty disables the binding.
    FORCE_CLOSE_KEY = "F8",

    -- Travels to a map pin from the fast travel screen. This needs its own key
    -- because "Confirmar" is greyed out over a pin: that screen accepts only
    -- safe areas and teleport terminals, so the confirm never fires there and
    -- there is nothing for the mod to intercept. With one pin placed the key
    -- takes it; with several it takes the one nearest the cursor.
    -- Any name from UE4SS's Key table; empty disables the binding.
    PIN_TRAVEL_KEY = "F9",

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
