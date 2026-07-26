-- FieldEquipmentMenu settings.
-- The in-game Mods menu writes to runtime.lua, which is applied on top of this file.

return {
    -- Adds the Equipment entry to the start menu.
    -- Switching this off in-game takes effect the next time you open the menu:
    -- the entry is injected as the menu is built, so an already-open menu keeps
    -- the row it was created with.
    ENABLED = true,

    -- Verbose logging in the UE4SS console.
    DEBUG_LOGS = true,
}
