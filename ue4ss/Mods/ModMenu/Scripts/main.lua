-- Standalone loader for ModMenu.
--
-- The implementation still requests the suite-level bridge path. This bootstrap
-- redirects only that exact request to the private bridge bundled with ModMenu,
-- then restores the global dofile function immediately after startup finishes.

local sourceInfo = debug.getinfo(1, "S")
if type(sourceInfo) ~= "table" or type(sourceInfo.source) ~= "string" then
    error("ModMenu standalone bootstrap could not resolve its script source")
end

local sourcePath = sourceInfo.source
if sourcePath:sub(1, 1) == "@" then sourcePath = sourcePath:sub(2) end
local SCRIPT_DIR = sourcePath:match("^(.*[\\/])")
if type(SCRIPT_DIR) ~= "string" or SCRIPT_DIR == "" then
    error("ModMenu standalone bootstrap could not resolve the Scripts directory")
end

local IMPLEMENTATION_PATH = SCRIPT_DIR .. "main_impl.lua"
local LEGACY_BRIDGE_PATH = SCRIPT_DIR .. "../../shared/ModMenuBridge.lua"
local LOCAL_BRIDGE_PATH = SCRIPT_DIR .. "standalone/ModMenuBridge.lua"
local originalDofile = dofile

if type(originalDofile) ~= "function" then
    error("ModMenu standalone bootstrap requires Lua dofile")
end

local function routedDofile(path)
    if path == LEGACY_BRIDGE_PATH then
        return originalDofile(LOCAL_BRIDGE_PATH)
    end
    return originalDofile(path)
end

local ok, result = xpcall(function()
    dofile = routedDofile
    return originalDofile(IMPLEMENTATION_PATH)
end, debug.traceback)

dofile = originalDofile

if not ok then error(result) end
return result
