--========================================================--
--            AincradOpenWorld — config                   --
--  Edit values, save, then RESTART the game to apply.    --
--========================================================--
return {
    ENABLED = true,

    -- Quests to leave completely vanilla (no open-world changes). Add a QuestId here if a
    -- specific quest misbehaves with the whole floor active.
    --   Main story quests are 1xxxx (e.g. 10009), Sub quests are 2xxxx (e.g. 20036).
    -- Example: EXCLUDE_QUEST_IDS = { 10012, 20005 },
    EXCLUDE_QUEST_IDS = {},

    -- Dedicated "Floor N : Free Roam" entries at the quest terminal. Maps a QuestId to the display
    -- name shown in the quest list (every quest already opens the whole floor — this labels chosen
    -- repeatable quests as the official free-roam entries). Pick quests you have available/repeatable;
    -- set to {} to disable renaming.
    FREE_ROAM_QUESTS = {
        [20036] = "Floor 1 : Free Roam",
        [20024] = "Floor 2 : Free Roam",   -- "A Woman's Intuition" (Urbas) — Floor 2 field sub, free variant QST_Free_20024
    },
    FREE_ROAM_DESCRIPTION = "Explore the entire floor freely - every region, enemy camp, treasure chest and terminal is active from the start. The original quest objective is still live: complete it whenever you are ready to end the session and collect the reward, or Give Up to return to town.",

    -- Print [OpenWorld] diagnostics to the UE4SS console/log.
    DEBUG_LOGS = false,

    -- Load the development probe (the 'ow' console commands used during research). Not needed
    -- for normal play.
    PROBE_MODE = false,
}
