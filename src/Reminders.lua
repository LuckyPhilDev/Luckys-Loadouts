-- luacheck: globals LuckyLoadouts C_RaidLocks RequestRaidInfo

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Reminders = {}

local Reminders = LuckyLoadouts.Reminders
local S
local characterDB
local controller
local eventFrame
local latestSnapshot
local visitKills = {}
local visitRaid
local categories = { Dungeon = true, Raid = true, Battleground = true, Arena = true, OpenWorld = true, Delve = true }

local function activeDelveState()
    -- Unverified: confirm C_PartyInfo.IsDelveInProgress inside and outside a retail delve.
    if not C_PartyInfo or not C_PartyInfo.IsDelveInProgress then return nil end
    local ok, active = pcall(C_PartyInfo.IsDelveInProgress)
    if not ok or active == nil then return nil end
    return active and true or false
end

local function snapshotKey(category, instanceID)
    return category .. ":" .. tostring(instanceID or 0)
end

-- Kills seen this visit cover what the lockout does not know yet, or at all in
-- Raid Finder, which keeps no lockout.
local function nextBosses(instanceID, difficultyID)
    local raid = instanceID .. ":" .. tostring(difficultyID)
    if visitRaid ~= raid then
        visitRaid = raid
        visitKills = {}
    end
    local journalID = LuckyLoadouts.Journal.CurrentJournalID()
    if not journalID then return nil end
    local function isKilled(boss)
        if visitKills[boss.dungeonEncounterID] then return true end
        return C_RaidLocks.IsEncounterComplete(instanceID, boss.dungeonEncounterID, difficultyID) and true or false
    end
    return LuckyLoadouts.Journal.AvailableBosses(LuckyLoadouts.Journal.Bosses(journalID),
        LuckyLoadouts.Constants.RAID_LAYOUTS[journalID], isKilled)
end

function Reminders.ClassifyContent()
    local inInstance, instanceType = IsInInstance()
    if inInstance == nil then return nil, S.UNKNOWN_CONTENT end

    if not inInstance then
        local mapID = C_Map.GetBestMapForUnit("player")
        if not mapID then return nil, S.UNKNOWN_CONTENT end
        return { category = "OpenWorld", uiMapID = mapID, label = S.CATEGORIES.OpenWorld,
            key = "OpenWorld" }
    end

    local name, infoType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    instanceType = infoType and infoType ~= "" and infoType or instanceType
    if type(name) ~= "string" or name == "" or type(instanceID) ~= "number" then
        return nil, S.UNKNOWN_CONTENT
    end

    local delve = activeDelveState()
    if delve == true then
        return { category = "Delve", instanceID = instanceID, label = name,
            key = snapshotKey("Delve", instanceID) }
    end
    if instanceType == "scenario" and delve == nil then return nil, S.DELVE_UNKNOWN end

    local byType = { party = "Dungeon", raid = "Raid", pvp = "Battleground", arena = "Arena" }
    local category = byType[instanceType]
    if not category then return nil, S.UNKNOWN_CONTENT end
    local snapshot = { category = category, instanceID = instanceID, label = name,
        key = snapshotKey(category, instanceID) }
    if category == "Raid" then
        snapshot.bosses = nextBosses(instanceID, difficultyID)
        -- A kill that opens new bosses is a new visit, so a dismissed reminder can return.
        for _, boss in ipairs(snapshot.bosses or {}) do
            snapshot.key = snapshot.key .. ":" .. tostring(boss.encounterID)
        end
    end
    return snapshot
end

-- One choice per loadout the next bosses want, bosses sharing one grouped.
local function resolveBosses(entry, snapshot, loadoutsByID)
    if type(entry.bosses) ~= "table" or not snapshot.bosses or not loadoutsByID then return nil end
    local choices, byConfig = {}, {}
    for _, boss in ipairs(snapshot.bosses) do
        local assigned = entry.bosses[boss.encounterID]
        local configID = type(assigned) == "table" and assigned.configID
        local target = configID and loadoutsByID[configID]
        if target then
            local choice = byConfig[configID]
            if choice then
                choice.label = choice.label .. ", " .. boss.name
            else
                choice = { configID = configID, label = boss.name, target = target, portrait = boss.portrait }
                byConfig[configID] = choice
                choices[#choices + 1] = choice
            end
        end
    end
    if #choices == 0 then return nil end
    local ids = {}
    for index, choice in ipairs(choices) do ids[index] = choice.configID end
    local first = choices[1]
    return {
        configID = first.configID,
        source = "boss:" .. table.concat(ids, ","),
        label = first.label,
        target = first.target,
        portrait = first.portrait,
        valid = true,
        choices = #choices > 1 and choices or nil,
    }
end

function Reminders.Offers(match, configID)
    if match.configID == configID then return true end
    for _, choice in ipairs(match.choices or {}) do
        if choice.configID == configID then return true end
    end
    return false
end

function Reminders.ResolveAssignment(assignments, snapshot, loadoutsByID)
    if type(assignments) ~= "table" or type(snapshot) ~= "table" then return nil end
    local configID, source, label
    local instances = type(assignments.instances) == "table" and assignments.instances or {}
    local override = instances[snapshot.instanceID]
    local instanceContent = snapshot.category == "Dungeon" or snapshot.category == "Raid"
    local usable = instanceContent and type(override) == "table" and override.category == snapshot.category
    if usable then
        local bossMatch = resolveBosses(override, snapshot, loadoutsByID)
        if bossMatch then return bossMatch end
    end
    -- An entry holding only boss assignments leaves the rest of the instance to its category.
    if instanceContent and override ~= nil and not (usable and override.configID == nil) then
        source = "instance:" .. tostring(snapshot.instanceID)
        label = type(override) == "table" and override.label or snapshot.label
        if type(override) ~= "table" or override.category ~= snapshot.category
            or type(override.configID) ~= "number" then
            return { source = source, label = label, valid = false }
        end
        configID = override.configID
    else
        configID = type(assignments.categories) == "table" and assignments.categories[snapshot.category] or nil
        if configID == nil then return nil end
        source = "category:" .. snapshot.category
        label = S.CATEGORIES[snapshot.category]
        if type(configID) ~= "number" then
            return { source = source, label = label, valid = false }
        end
    end

    local target = loadoutsByID and loadoutsByID[configID]
    return {
        configID = configID,
        source = source,
        label = label,
        target = target,
        valid = loadoutsByID == nil and nil or target ~= nil,
    }
end

-- The wanted talents isTaken reports missing, one line per dungeon or next boss,
-- each with every talent wanted there so a swap never gives one up.
-- isTaken returns nil for a talent the tree no longer has, which is skipped.
function Reminders.ResolveTalents(assignments, snapshot, isTaken)
    if type(assignments) ~= "table" or type(snapshot) ~= "table" then return nil end
    local sources = {}
    if snapshot.category == "Dungeon" then
        sources[1] = { label = snapshot.label, list = assignments.talents and assignments.talents[snapshot.instanceID] }
    elseif snapshot.category == "Raid" then
        for _, boss in ipairs(snapshot.bosses or {}) do
            sources[#sources + 1] = { label = boss.name, portrait = boss.portrait,
                list = assignments.bossTalents and assignments.bossTalents[boss.encounterID] }
        end
    end
    local lines = {}
    for _, source in ipairs(sources) do
        local missing = {}
        for _, talent in ipairs(type(source.list) == "table" and source.list or {}) do
            if isTaken(talent) == false then missing[#missing + 1] = talent end
        end
        if #missing > 0 then
            lines[#lines + 1] = { label = source.label, portrait = source.portrait, talents = missing, wanted = source.list }
        end
    end
    return #lines > 0 and lines or nil
end

local function talentContent(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        for _, talent in ipairs(line.talents) do parts[#parts + 1] = line.label .. "=" .. tostring(talent.nodeID) end
    end
    return table.concat(parts, ",")
end

function Reminders.CreateController(callbacks)
    local state = {
        callbacks = callbacks,
        revisions = {},
        shown = {},
        generation = 0,
        retries = 0,
    }

    function state:Hide()
        self.visible = nil
        self.visibleKey = nil
        self.callbacks.hide()
    end

    -- The loadout comes first; talents only once it is right or dismissed, so
    -- they are checked against the tree the player will actually play.
    function state:NextStep(snapshot, specID)
        local assignments = self.callbacks.getAssignments(specID)
        local revision = self.revisions[specID] or 0
        local function unseen(identity) return identity == self.visibleKey or not self.shown[identity] end

        local byID, selectedID = self.callbacks.getLoadouts(specID)
        local match = Reminders.ResolveAssignment(assignments, snapshot, byID)
        if match and match.valid == true and not Reminders.Offers(match, selectedID) then
            local identity = table.concat({ snapshot.key, specID, match.source, match.configID, revision }, ":")
            if unseen(identity) then return match, identity, identity end
        end

        local lines = self.callbacks.isTaken and Reminders.ResolveTalents(assignments, snapshot, self.callbacks.isTaken)
        if lines then
            local identity = table.concat({ snapshot.key, specID, "talents", revision }, ":")
            if unseen(identity) then return { talents = lines }, identity, identity .. ":" .. talentContent(lines) end
        end
        return nil
    end

    function state:Evaluate(snapshot)
        if not snapshot then
            self:Hide()
            return
        end
        self.latestSnapshot = snapshot
        if self.visitKey ~= snapshot.key then
            self.visitKey = snapshot.key
            self.shown = {}
        end

        local specID = self.callbacks.getSpec()
        if not specID then self:Hide(); return end
        local match, identity, content = self:NextStep(snapshot, specID)
        if not match then
            self.deferred = nil
            self:Hide()
            return
        end

        if self.visibleKey == identity and self.visibleContent == content then return end
        if self.callbacks.inCombat() then
            self.deferred = identity
            self:Hide()
            return
        end

        self.deferred = nil
        self.shown[identity] = true
        self.visibleKey, self.visibleContent = identity, content
        self.visible = match
        self.callbacks.show(match, snapshot)
    end

    -- Dismissing the loadout moves on to any talents still missing.
    function state:Dismiss()
        self:Hide()
        if self.latestSnapshot then self:Evaluate(self.latestSnapshot) end
    end

    -- Dev: show again what a dismissal suppressed for this visit.
    function state:Replay()
        self.shown = {}
        self:Evaluate(self.callbacks.snapshot())
        return self.visible
    end

    -- The new loadout may still lack a wanted talent, so look again.
    function state:Switched(request)
        if not self.visible or not request or Reminders.Offers(self.visible, request.id) then self:Hide() end
        self:ScheduleRefresh(false)
    end

    function state:AssignmentChanged(specID)
        self.revisions[specID] = (self.revisions[specID] or 0) + 1
        if self.latestSnapshot then self:Evaluate(self.latestSnapshot) end
    end

    function state:CombatChanged(inCombat)
        self.callbacks.combatChanged(inCombat)
        if not inCombat and self.deferred then self:ScheduleRefresh(false) end
    end

    function state:Refresh(token)
        if token ~= self.generation then return end
        local snapshot = self.callbacks.snapshot()
        if not snapshot then
            self:Hide()
            if self.retries < 2 then
                self.retries = self.retries + 1
                self.callbacks.after(0.5, function()
                    if token == self.generation then self:Refresh(token) end
                end)
            end
            return
        end
        self.retries = 0
        self:Evaluate(snapshot)
    end

    function state:ScheduleRefresh(allowRetry)
        self.generation = self.generation + 1
        self.retries = allowRetry and 0 or 2
        local token = self.generation
        self.callbacks.after(0, function() self:Refresh(token) end)
        return token
    end

    return state
end

local function readLoadouts(specID)
    local list, _, byID, selectedID = LuckyLoadouts.Loadouts:Read(specID)
    if not list then return nil, nil end
    return byID, selectedID
end

function Reminders:Init(db)
    S = LuckyLoadouts.Strings
    characterDB = db
    controller = self.CreateController({
        getSpec = function() return LuckyLoadouts.Loadouts:GetCurrentSpec() end,
        getAssignments = function(specID) return LuckyLoadouts.GetSpecAssignments(characterDB, specID) end,
        getLoadouts = readLoadouts,
        isTaken = LuckyLoadouts.Talents.IsTaken,
        inCombat = InCombatLockdown,
        snapshot = function()
            local snapshot = Reminders.ClassifyContent()
            latestSnapshot = snapshot
            return snapshot
        end,
        show = function(match, snapshot) LuckyLoadouts.Settings:ShowReminder(match, snapshot) end,
        hide = function() LuckyLoadouts.Settings:HideReminder() end,
        combatChanged = function(inCombat) LuckyLoadouts.Settings:SetReminderCombat(inCombat) end,
        after = C_Timer.After,
    })

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("BOSS_KILL")
    eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
    eventFrame:SetScript("OnEvent", function(_, event, encounterID)
        if event == "PLAYER_ENTERING_WORLD" then
            RequestRaidInfo()
        elseif event == "BOSS_KILL" then
            visitKills[encounterID] = true
        elseif event == "PLAYER_REGEN_DISABLED" then
            controller:CombatChanged(true)
        elseif event == "PLAYER_REGEN_ENABLED" then
            controller:CombatChanged(false)
        end
        controller:ScheduleRefresh(event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA")
    end)

    LuckyLoadouts.Loadouts:AddListener(function(kind, _, data)
        if kind == "switched" then controller:Switched(data) end
    end)
end

function Reminders:GetLatestSnapshot()
    return latestSnapshot
end

function Reminders:GetController()
    return controller
end

function Reminders:Refresh()
    if controller then controller:ScheduleRefresh(true) end
end

function Reminders:Dismiss()
    if controller then controller:Dismiss() end
end

function Reminders:Replay()
    return controller and controller:Replay()
end

function Reminders:AssignmentChanged(specID)
    if controller then controller:AssignmentChanged(specID) end
end

function Reminders:SetCategory(specID, category, configID)
    if not categories[category] then return false end
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data then return false end
    if configID == nil then
        data.categories[category] = nil
    elseif type(configID) == "number" then
        data.categories[category] = configID
    else
        return false
    end
    self:AssignmentChanged(specID)
    return true
end

function Reminders:SetCurrentInstance(specID, configID)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data then return false end
    local snapshot = latestSnapshot or self.ClassifyContent()
    if not snapshot then return false, S.INSTANCE_UNKNOWN end
    if snapshot.category ~= "Dungeon" and snapshot.category ~= "Raid" then
        return false, S.INSTANCE_INVALID
    end
    data.instances[snapshot.instanceID] = {
        configID = configID,
        category = snapshot.category,
        label = snapshot.label,
    }
    self:AssignmentChanged(specID)
    return true
end

-- A nil boss assigns the whole instance and a nil configID clears. An instance
-- left with nothing assigned is dropped rather than kept empty.
function Reminders:SetInstanceAssignment(specID, instance, boss, configID)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data or type(instance) ~= "table" or type(instance.id) ~= "number" then return false end
    if configID ~= nil and type(configID) ~= "number" then return false end
    local entry = type(data.instances[instance.id]) == "table" and data.instances[instance.id] or {}
    data.instances[instance.id] = entry
    entry.category, entry.label = instance.category, instance.label
    if boss then
        entry.bosses = type(entry.bosses) == "table" and entry.bosses or {}
        entry.bosses[boss.encounterID] = configID and { configID = configID, label = boss.name } or nil
    else
        entry.configID = configID
    end
    if entry.configID == nil and not next(entry.bosses or {}) then data.instances[instance.id] = nil end
    self:AssignmentChanged(specID)
    return true
end

-- The talents wanted in a dungeon, or at a raid boss when one is given.
-- ponytail: emptied lists are kept, they resolve to nothing.
function Reminders:TalentList(specID, instance, boss)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data then return nil end
    local map, key = data.talents, instance.id
    if boss then map, key = data.bossTalents, boss.encounterID end
    map[key] = type(map[key]) == "table" and map[key] or {}
    return map[key]
end

function Reminders:GiveUpList(specID)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    return data and data.giveUp or {}
end

function Reminders:SetInstance(specID, instanceID, configID)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data then return false end
    local entry = data.instances[instanceID]
    if type(entry) ~= "table" or type(configID) ~= "number" then return false end
    entry.configID = configID
    self:AssignmentChanged(specID)
    return true
end

function Reminders:RemoveInstance(specID, instanceID)
    local data = LuckyLoadouts.GetSpecAssignments(characterDB, specID)
    if not data then return false end
    data.instances[instanceID] = nil
    self:AssignmentChanged(specID)
    return true
end
