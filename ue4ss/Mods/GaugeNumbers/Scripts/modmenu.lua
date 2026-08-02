-- ModMenu contract for GaugeNumbers.
--
-- ModMenu discovers this file by walking the Mods folder; nothing outside this
-- mod needs to know it exists. Every key below must match a key this mod's
-- config.lua actually defines, and the bounds must match its own validator --
-- a manifest that has drifted from the config is skipped, not shown.
--
--   label    row label in the menu.
--   summary  one line shown under the label.
--   apply    "live" | "menu" | "restart"
--   settings tunables, in display order. ENABLED is required.

return {
    label = "Gauge Numbers",
    summary = "Live HP, Stamina and SP values plus an EXP bar on the HUD",
    apply = "live",
    settings = {
        { key = "ENABLED", label = "Enabled", type = "bool", default = true },
        { key = "SHOW_HP", label = "HP readout", type = "bool", default = true },
        { key = "SHOW_STAMINA", label = "Stamina readout", type = "bool", default = true },
        { key = "SHOW_SP", label = "SP readout", type = "bool", default = true },
        { key = "READOUT_LAYER", label = "Draw layer", type = "choice", default = "front",
          options = {
              { value = "front", label = "In front of the bars" },
              { value = "inside", label = "Inside the bar" },
              { value = "gauge", label = "Gauge assembly" },
          } },
        { key = "HP_X", label = "HP readout X", type = "number", default = 198, min = 0, max = 1920, step = 2, format = "%.0f px" },
        { key = "HP_Y", label = "HP readout Y", type = "number", default = 92, min = 0, max = 1080, step = 2, format = "%.0f px" },
        { key = "STAMINA_X", label = "Stamina readout X", type = "number", default = 189, min = 0, max = 1920, step = 2, format = "%.0f px" },
        { key = "STAMINA_Y", label = "Stamina readout Y", type = "number", default = 126, min = 0, max = 1080, step = 2, format = "%.0f px" },
        { key = "SP_X", label = "SP readout X", type = "number", default = 161, min = 0, max = 1920, step = 2, format = "%.0f px" },
        { key = "SP_Y", label = "SP readout Y", type = "number", default = 155, min = 0, max = 1080, step = 2, format = "%.0f px" },
        { key = "READOUT_PLACEMENT", label = "Readout position", type = "choice", default = "center",
          options = {
              { value = "center", label = "Centred on the bar" },
              { value = "right", label = "Off the end" },
          } },
        { key = "ALIGN_READOUTS", label = "Align readouts", type = "bool", default = true },
        { key = "VALUE_FORMAT", label = "Readout format", type = "choice", default = "current_max",
          options = {
              { value = "current_max", label = "280 / 280" },
              { value = "current", label = "280" },
              { value = "percent", label = "100%" },
          } },
        { key = "TEXT_OFFSET_X", label = "Readout offset X", type = "number", default = -8, min = -400, max = 400, step = 2, format = "%+.0f px" },
        { key = "TEXT_OFFSET_Y", label = "Readout offset Y", type = "number", default = -18, min = -400, max = 400, step = 2, format = "%+.0f px" },
        { key = "FONT_SIZE", label = "Font size", type = "number", default = 11, min = 6, max = 48, step = 1, format = "%.0f" },
        { key = "SHOW_EXP", label = "Experience block", type = "bool", default = false },
        { key = "SHOW_EXP_BAR", label = "Experience bar", type = "bool", default = true },
        { key = "SHOW_EXP_TEXT", label = "Experience numbers", type = "bool", default = false },
        { key = "SHOW_EXP_LEVEL", label = "Level prefix", type = "bool", default = true },
        { key = "EXP_STYLE", label = "Experience bar style", type = "choice", default = "native",
          options = {
              { value = "native", label = "Game's own gauge" },
              { value = "flat", label = "Flat bar" },
          } },
        { key = "EXP_ANCHOR", label = "Experience anchor", type = "choice", default = "hp",
          options = {
              { value = "hp", label = "HP bar" },
              { value = "stamina", label = "Stamina bar" },
              { value = "sp", label = "SP bar" },
          } },
        { key = "EXP_PLACEMENT", label = "Experience side", type = "choice", default = "above",
          options = {
              { value = "above", label = "Above the gauge" },
              { value = "below", label = "Below the gauge" },
          } },
        { key = "EXP_OFFSET_X", label = "Experience offset X", type = "number", default = 0, min = -400, max = 400, step = 2, format = "%+.0f px" },
        { key = "EXP_OFFSET_Y", label = "Experience offset Y", type = "number", default = -4, min = -400, max = 400, step = 2, format = "%+.0f px" },
        { key = "EXP_BAR_WIDTH", label = "Experience bar width", type = "number", default = 0, min = 0, max = 1200, step = 10, format = "%.0f px" },
        { key = "EXP_BAR_HEIGHT", label = "Experience bar height", type = "number", default = 0, min = 0, max = 40, step = 1, format = "%.0f px" },
        { key = "REFRESH_MS", label = "Reconcile interval", type = "number", default = 500, min = 100, max = 5000, step = 50, format = "%.0f ms" },
        { key = "DEBUG_LOGS", label = "Debug logging", type = "bool", default = false },
    },
}
