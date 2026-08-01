-- Loader for GaugeNumbers.
--
-- The implementation lives in main_impl.lua, and every file it needs -- the
-- bridge included -- is resolved from this mod's own folder. UE4SS's entry
-- point therefore stays one unconditional dofile with no path routing.

local sourceInfo = debug.getinfo(1, "S")
if type(sourceInfo) ~= "table" or type(sourceInfo.source) ~= "string" then
    error("GaugeNumbers loader could not resolve its script source")
end

local sourcePath = sourceInfo.source
if sourcePath:sub(1, 1) == "@" then sourcePath = sourcePath:sub(2) end
local SCRIPT_DIR = sourcePath:match("^(.*[\\/])")
if type(SCRIPT_DIR) ~= "string" or SCRIPT_DIR == "" then
    error("GaugeNumbers loader could not resolve the Scripts directory")
end

local ok, result = xpcall(function()
    return dofile(SCRIPT_DIR .. "main_impl.lua")
end, debug.traceback)

if not ok then error(result) end
return result
