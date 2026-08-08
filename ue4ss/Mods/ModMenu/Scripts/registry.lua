-- The set of mods the menu shows.
--
-- There is no list here to maintain and nothing for a mod to opt into. Every
-- folder under Mods/ that UE4SS would load as a Lua mod is listed: with its
-- own settings if it ships Scripts/modmenu.lua, and with a plain on/off row
-- driven by enabled.txt if it does not.

local sourceInfo = debug.getinfo(1, "S")
if type(sourceInfo) ~= "table" or type(sourceInfo.source) ~= "string" then
    error("ModMenu registry could not resolve its script source")
end

local sourcePath = sourceInfo.source
if sourcePath:sub(1, 1) == "@" then sourcePath = sourcePath:sub(2) end
local SCRIPT_DIR = sourcePath:match("^(.*[\\/])")
if type(SCRIPT_DIR) ~= "string" or SCRIPT_DIR == "" then
    error("ModMenu registry could not resolve the Scripts directory")
end

local discovery = dofile(SCRIPT_DIR .. "discovery.lua")
local bridge = dofile(SCRIPT_DIR .. "standalone/ModMenuBridge.lua")

if type(discovery) ~= "table" or type(discovery.discover) ~= "function" then
    error("discovery.lua did not return the discovery module")
end
if type(bridge) ~= "table" then
    error("standalone ModMenuBridge.lua did not return a table")
end

local accepted, report = discovery.discover(SCRIPT_DIR, bridge)

print(string.format(
    "[ModMenu] discovery | %d mod(s) | %d with settings | %d on/off only | %d not a mod\n",
    report.registered,
    #report.configured,
    #report.basic,
    #report.skipped
))

-- A mod in this list is still shown; it just lost its settings rows and kept
-- its on/off row, so the reason has to be findable.
for _, item in ipairs(report.invalid) do
    print(string.format(
        "[ModMenu] %s has no usable settings contract | %s\n",
        tostring(item.mod),
        tostring(item.reason)
    ))
end

if #accepted == 0 then
    print("[ModMenu] no mods installed under Mods/\n")
end

return accepted
