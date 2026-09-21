-- luacheck: globals LuckyLoadouts

LuckyLoadouts = LuckyLoadouts or {}

LuckyLoadouts.Defaults = {
    account = {
        devMode = false,
        autoNameNewLoadouts = false,
        minimap = { hide = false, minimapPos = 245 },
        manager = { point = "CENTER", x = 0, y = 0 },
        reminder = { point = "TOP", x = 0, y = -180 },
    },
    character = {
        schemaVersion = 1,
        bySpec = {},
    },
}

function LuckyLoadouts.CopyDefaults(target, defaults)
    target = type(target) == "table" and target or {}
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = LuckyLoadouts.CopyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

function LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if type(characterDB) ~= "table" or type(specID) ~= "number" then return nil end
    characterDB.bySpec = type(characterDB.bySpec) == "table" and characterDB.bySpec or {}
    local data = characterDB.bySpec[specID]
    if type(data) ~= "table" then
        data = { categories = {}, instances = {} }
        characterDB.bySpec[specID] = data
    end
    data.categories = type(data.categories) == "table" and data.categories or {}
    data.instances = type(data.instances) == "table" and data.instances or {}
    return data
end
