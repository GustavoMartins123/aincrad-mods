-- ModMenu settings.

return {
    -- Adds the Mods entry to the start menu.
    ENABLED = true,

    -- Verbose logging in the UE4SS console. Currently on so native focus wraps
    -- and identity-based redirects show up in UE4SS.log. Set to false once
    -- navigation is behaving.
    DEBUG_LOGS = true,

    -- Drawn over the Mods row. Empty or invalid text makes the row injection
    -- fail explicitly.
    ICON_LETTER = "M",
    -- Position calibrated against the native 64x64 rail icon.
    ICON_LETTER_OFFSET = { X = 38.0, Y = 30.0 },

    -- Letter colour. 1.0 everywhere = white.
    ICON_TINT = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
}
