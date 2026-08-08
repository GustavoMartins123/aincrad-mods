local discoveryPath = assert(arg[1], "discovery.lua path is required")
local discovery = assert(dofile(discoveryPath))

local root = os.tmpname()
os.remove(root)
assert(os.execute(string.format('mkdir -p "%s/Mods/ModMenu/Scripts"', root)))

local scriptDir = root .. "/Mods/ModMenu/Scripts/"
local files = {}
local effective = {}

local bridge = {}
function bridge.readFile(path)
    return files[path], nil
end
function bridge.readSettings(modName, targetDir)
    local value = effective[modName]
    if value == nil then
        return nil, "fingerprint", { error = "config rejected" }
    end
    return value, "fingerprint", { error = nil, configPath = targetDir .. "config.lua" }
end

local function entry(modName)
    return {
        mod = modName,
        label = modName,
        summary = "test integration",
        apply = "live",
        settings = {
            { key = "ENABLED", label = "Enabled", type = "bool", default = true },
            { key = "VALUE", label = "Value", type = "number",
              default = 1, min = 0, max = 2, step = 1, format = "%.0f" },
        },
    }
end

local registry = {
    entry("AbsentMod"),
    entry("ValidMod"),
    entry("MissingMain"),
    entry("WrongType"),
}

local function target(modName, fileName)
    return scriptDir .. "../../" .. modName .. "/Scripts/" .. fileName
end

files[target("ValidMod", "main.lua")] = "return true"
files[target("ValidMod", "config.lua")] = "return {}"
effective.ValidMod = { ENABLED = true, VALUE = 2 }

files[target("MissingMain", "config.lua")] = "return {}"
effective.MissingMain = { ENABLED = true, VALUE = 1 }

files[target("WrongType", "main.lua")] = "return true"
files[target("WrongType", "config.lua")] = "return {}"
effective.WrongType = { ENABLED = true, VALUE = "not-a-number" }

local accepted, report = discovery.discover(scriptDir, registry, bridge)
assert(#accepted == 1 and accepted[1].mod == "ValidMod")
assert(#report.accepted == 1 and report.accepted[1] == "ValidMod")
assert(#report.absent == 1 and report.absent[1] == "AbsentMod")
assert(#report.invalid == 2)
assert(report.invalid[1].mod == "MissingMain")
assert(report.invalid[2].mod == "WrongType")
assert(discovery.reportFingerprint(report) ~= "")

os.execute(string.format('rm -rf "%s"', root))
print("modmenu discovery: OK")
