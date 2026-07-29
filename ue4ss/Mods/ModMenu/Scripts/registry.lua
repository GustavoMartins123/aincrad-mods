-- Auto-discovered ModMenu registry.
--
-- registry_impl.lua remains the explicit compatibility allow-list. Only entries
-- whose target mod is installed and whose effective settings match that contract
-- are returned to the menu and its console diagnostics.

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

local registry = dofile(SCRIPT_DIR .. "registry_impl.lua")
local discovery = dofile(SCRIPT_DIR .. "discovery.lua")
local bridge = dofile(SCRIPT_DIR .. "standalone/ModMenuBridge.lua")

if type(registry) ~= "table" then error("registry_impl.lua must return a table") end
if type(discovery) ~= "table" or type(discovery.discover) ~= "function" then
    error("discovery.lua did not return the discovery module")
end
if type(bridge) ~= "table" then
    error("standalone ModMenuBridge.lua did not return a table")
end

local accepted, report = discovery.discover(SCRIPT_DIR, registry, bridge)

print(string.format(
    "[ModMenu] auto-discovery | %d compatible | %d absent | %d invalid\n",
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
    print("[ModMenu] no compatible installed mods were discovered\n")
end

return accepted
