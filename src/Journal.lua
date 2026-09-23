-- luacheck: globals LuckyLoadouts

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Journal = {}

local Journal = LuckyLoadouts.Journal

-- Keyed by the instance ID GetInstanceInfo reports, so an assignment matches
-- the instance the player is standing in without another journal lookup.
function Journal.Instance(journalID)
    local name, _, _, art, _, _, _, _, _, mapID, _, isRaid = EJ_GetInstanceInfo(journalID)
    if type(name) ~= "string" or type(mapID) ~= "number" or mapID == 0 then return nil end
    return { id = mapID, journalID = journalID, label = name, art = art, category = isRaid and "Raid" or "Dungeon" }
end

local season

-- The Adventure Guide's last tier is Current Season; before a season opens it
-- is empty, so the tier below stands in. The selected tier is shared with the
-- Adventure Guide, so the player's own is put back.
function Journal.Season()
    if season then return season end
    local previous = EJ_GetCurrentTier()
    local excluded = LuckyLoadouts.Constants.SEASON_GROUPING_PAGES
    local found = {}
    for tier = EJ_GetNumTiers(), 1, -1 do
        EJ_SelectTier(tier)
        for _, isRaid in ipairs({ true, false }) do
            for index = 1, 100 do
                local journalID = EJ_GetInstanceByIndex(index, isRaid)
                if not journalID then break end
                local instance = not excluded[journalID] and Journal.Instance(journalID)
                if instance then found[#found + 1] = instance end
            end
        end
        if #found > 0 then break end
    end
    if previous then EJ_SelectTier(previous) end
    if #found > 0 then season = found end
    return found
end

function Journal.Bosses(journalID)
    EJ_SelectInstance(journalID)
    local bosses = {}
    for index = 1, 50 do
        local name, _, encounterID, _, _, _, dungeonEncounterID = EJ_GetEncounterInfoByIndex(index, journalID)
        if not name then break end
        local portrait = select(5, EJ_GetCreatureInfo(1, encounterID))
        bosses[index] = { encounterID = encounterID, dungeonEncounterID = dungeonEncounterID, name = name,
            portrait = portrait or "Interface\\EncounterJournal\\UI-EJ-BOSS-Default" }
    end
    return bosses
end

-- Mirrors Loot Wishlist: the instance ID resolves some raids the player map does not.
function Journal.CurrentJournalID()
    local instanceID = select(8, GetInstanceInfo())
    local uiMapID = C_Map.GetBestMapForUnit("player")
    for _, mapID in ipairs({ instanceID or 0, uiMapID or 0 }) do
        local journalID = mapID > 0 and EJ_GetInstanceForMap(mapID)
        if type(journalID) == "number" and journalID > 0 then return journalID end
    end
    return nil
end

-- Alive bosses whose prerequisites are all dead, in journal order.
function Journal.AvailableBosses(bosses, layout, isKilled)
    local killed = {}
    for _, boss in ipairs(bosses) do killed[boss.encounterID] = isKilled(boss) end
    local available = {}
    for _, boss in ipairs(bosses) do
        local ready = not killed[boss.encounterID]
        for _, requiredID in ipairs(ready and layout and layout[boss.encounterID] or {}) do
            if not killed[requiredID] then ready = false end
        end
        if ready then available[#available + 1] = boss end
    end
    return available
end
