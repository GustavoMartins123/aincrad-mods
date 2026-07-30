-- FieldEquipPro settings.
-- The in-game Mods menu writes to runtime.lua, which is applied on top of this file.

return {
    -- Adds the Equipment entry to the start menu.
    -- Switching this off in-game takes effect the next time you open the menu:
    -- the entry is injected as the menu is built, so an already-open menu keeps
    -- the row it was created with.
    ENABLED = true,

    -- Verbose logging in the UE4SS console.
    DEBUG_LOGS = true,

    -- Show your character on the Equipment screen, the way it looks at a chest:
    -- the start menu hides the character, so this reveals it again and moves the
    -- camera into the equip close-up around it.
    --
    -- This is the one setting that hands a native struct back to a native
    -- function. If the game ever stops surviving that, switch it off: the screen
    -- still opens, just with the character hidden and the camera left alone.
    SHOW_CHARACTER = true,

    -- How much higher than normal the camera sits on the Equipment screen, in
    -- centimetres. Raising it lowers your character in frame and shows more
    -- above them; negative values do the opposite. Adjust it from the Mods menu
    -- with the screen open and you can see each step. Ignored when
    -- SHOW_CHARACTER is off, and 0 leaves the boom exactly where the game put it.
    CAMERA_HEIGHT = 50.0,
}
