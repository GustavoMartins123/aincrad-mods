local discoveryPath = assert(arg[1], "discovery.lua path is required")
local registryPath = assert(arg[2], "registry_impl.lua path is required")
local discovery = assert(dofile(discoveryPath))
local registry = assert(dofile(registryPath))

local scriptDir = "/virtual/Mods/ModMenu/Scripts/"
local effective = {
    SpeedMod = {
        ENABLED = true,
        START_SPEED = 1.40,
        MAX_SPEED = 3.20,
        SECONDS_TO_MAX_SPEED = 1.80,
        JUMP_HEIGHT_MULTIPLIER = 1.00,
        DISABLE_IN_COMBAT = true,
    },
    AutoPickupMod = {
        ENABLED = true,
        PICKUP_RANGE = 1000,
        ICON_DISPLAY_RANGE = 1500,
        PICKUP_INTERVAL = 0.30,
        SHOW_PICKUP_UI = true,
        EXPAND_OPERATABLE = true,
        ICON_RANGE_PATCH = true,
        DEBUG_HOOKS = false,
    },
    norescue = {
        ENABLED = true,
        SAFETY_NET_MS = 5000,
        DEATH_LANDING_HEIGHT = 1000000000.0,
        DEBUG_LOGS = false,
    },
    FieldEquipmentMod = {
        ENABLED = true,
        DEBUG_LOGS = true,
        SHOW_CHARACTER = true,
        CAMERA_HEIGHT = 40.0,
    },
    FastTravelMod = {
        ENABLED = true,
        DEBUG_LOGS = false,
        MAP_TARGET = "fasttravel",
        FORCE_CLOSE_KEY = "F8",
        PIN_TRAVEL_KEY = "F9",
        MAP_MENU_KEY = "",
    },
    ExperienceNotifications = {
        ENABLED = true,
        DEBUG_LOGS = false,
    },
    WorldEnemyDirector = {
        ENABLED = true,
        SPAWN_MULTIPLIER = 1,
        MAX_ACTIVE_EXTRAS = 48,
        SPAWN_RADIUS = 300.0,
        DESPAWN_RADIUS = 6000.0,
        SPAWN_IN_EMPTY_AREAS = true,
        RANDOMIZE_EXTRA_SPECIES = false,
        INCLUDE_BOSSES = false,
        SCALE_MIN = 1.0,
        SCALE_MAX = 1.0,
        COLOR_MODE = "off",
        COLOR_PRESET = "crimson",
        COLOR_PARAMETER_NAME = "Color",
        HEALTH_MULTIPLIER = 1.0,
        ATTACK_MULTIPLIER = 1.0,
        DEFENCE_MULTIPLIER = 1.0,
        MOVE_SPEED_MULTIPLIER = 1.0,
        XP_MULTIPLIER = 1.0,
        POLL_MS = 500,
        DEBUG_LOGS = false,
    },
    AincradOpenWorld = {
        ENABLED = true,
        EXCLUDE_QUEST_IDS = {},
        FREE_ROAM_QUESTS = {},
        FREE_ROAM_DESCRIPTION = "test",
        DEBUG_LOGS = false,
        PROBE_MODE = false,
    },
}

local bridge = {}
function bridge.readFile(_path)
    return "present", nil
end
function bridge.readSettings(modName, targetDir)
    local settings = effective[modName]
    if settings == nil then
        return nil, "fingerprint", { error = "missing fixture" }
    end
    return settings, "fingerprint", { error = nil, configPath = targetDir .. "config.lua" }
end

local accepted, report = discovery.discover(scriptDir, registry, bridge)
assert(#accepted == #registry, string.format("accepted %d/%d", #accepted, #registry))
assert(#report.absent == 0)
assert(#report.invalid == 0, report.invalid[1] and report.invalid[1].reason or "invalid")
print(string.format("modmenu registry contract: OK (%d mods)", #accepted))
