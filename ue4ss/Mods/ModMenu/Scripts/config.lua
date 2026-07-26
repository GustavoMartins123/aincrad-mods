-- ModMenu settings.

return {
    -- Adds the Mods entry to the start menu. With this off the console command
    -- (`modmenu list`) still works.
    ENABLED = true,

    -- Verbose logging in the UE4SS console. Currently on so the menu's focus
    -- transitions ("focus 4 -> 5", "focus 5 -> 0 => redirect to Mods") show up
    -- in UE4SS.log. Set to false once navigation is behaving.
    DEBUG_LOGS = true,

    -- Drawn over the Mods row instead of an icon texture. A TextBlock needs no
    -- asset to exist, so this cannot fail the way a wrong asset path can.
    -- Set to "" to use ICON_ASSET below instead.
    ICON_LETTER = "M",
    -- Nudge the letter if it does not sit centred on the row.
    ICON_LETTER_OFFSET = { X = 20.0, Y = 12.0 },

    -- Texture for the Mods row icon. Only used when ICON_LETTER is "".
    --
    -- To pick a different one, open the start menu and run `modmenu icons icon`
    -- in the UE4SS console — it lists the textures the game currently has
    -- loaded, filtered by the text you pass. Paste a path from that list here.
    -- Narrower searches work too: `modmenu icons menu`, `modmenu icons item`.
    ICON_ASSET =
        "/Game/ROD/Widget/Common/IconImage/ItemCategoryIconImage/T_ItemCategoryIcon_Unknown",

    -- Colour multiplier over that texture. Useful for telling the Mods row apart
    -- from another injected row using the same art. 1.0 everywhere = untouched.
    ICON_TINT = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
}
