-- The set of mods the menu shows.
--
-- There is no list here to maintain. Every folder under Mods/ is enumerated,
-- and a mod appears by shipping Scripts/modmenu.lua inside its own folder --
-- so installing, removing or renaming a mod needs no edit outside that mod.

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
    "[ModMenu] discovery | %d folder(s) | %d with a menu | %d without | %d invalid\n",
    report.registered,
    #report.accepted,
    #report.absent,
    #report.invalid
))

for _, item in ipairs(report.invalid) do
    print(string.format(
        "[ModMenu] skipped %s | %s\n",
        tostring(item.mod),
        tostring(item.reason)
    ))
end

if #accepted == 0 then
    print("[ModMenu] no installed mod ships a Scripts/modmenu.lua\n")
end

return accepted
