-- luacheck: globals LuckyLoadouts

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Reminders = {}

local Reminders = LuckyLoadouts.Reminders
local S
local characterDB
local controller
local eventFrame
local latestSnapshot
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

function Reminders.ClassifyContent()
    local inInstance, instanceType = IsInInstance()
    if inInstance == nil then return nil, S.UNKNOWN_CONTENT end

    if not inInstance then
        local mapID = C_Map.GetBestMapForUnit("player")
        if not mapID then return nil, S.UNKNOWN_CONTENT end
        return { category = "OpenWorld", uiMapID = mapID, label = S.CATEGORIES.OpenWorld,
            key = "OpenWorld" }
    end

    local name, infoType, _, _, _, _, _, instanceID = GetInstanceInfo()
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
    return { category = category, instanceID = instanceID, label = name,
        key = snapshotKey(category, instanceID) }
end

function Reminders.ResolveAssignment(assignments, snapshot, loadoutsByID)
    if type(assignments) ~= "table" or type(snapshot) ~= "table" then return nil end
    local configID, source, label
    if (snapshot.category == "Dungeon" or snapshot.category == "Raid")
        and type(assignments.instances) == "table"
        and assignments.instances[snapshot.instanceID] ~= nil then
        local override = assignments.instances[snapshot.instanceID]
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

function Reminders.CreateController(callbacks)
    local state = {
        callbacks = callbacks,
        revisions = {},
        generation = 0,
        retries = 0,
    }

    function state:Hide()
        self.visible = nil
        self.callbacks.hide()
    end

    function state:Evaluate(snapshot)
        if not snapshot then
            self:Hide()
            return
        end
        self.latestSnapshot = snapshot
        if self.visitKey ~= snapshot.key then
            self.visitKey = snapshot.key
            self.shownKey = nil
        end

        local specID = self.callbacks.getSpec()
        if not specID then self:Hide(); return end
        local assignments = self.callbacks.getAssignments(specID)
        local byID, selectedID = self.callbacks.getLoadouts(specID)
        local match = Reminders.ResolveAssignment(assignments, snapshot, byID)
        if not match or match.valid ~= true or selectedID == match.configID then
            self.deferred = nil
            self:Hide()
            return
        end

        local revision = self.revisions[specID] or 0
        local identity = table.concat({ snapshot.key, specID, match.source, match.configID, revision }, ":")
        if self.shownKey == identity then return end
        if self.callbacks.inCombat() then
            self.deferred = identity
            self:Hide()
            return
        end

        self.deferred = nil
        self.shownKey = identity
        self.visible = match
        self.callbacks.show(match, snapshot)
    end

    function state:Dismiss()
        self:Hide()
    end

    -- Dev: show again what a dismissal suppressed for this visit.
    function state:Replay()
        self.shownKey = nil
        self:Evaluate(self.callbacks.snapshot())
        return self.visible
    end

    function state:Switched(request)
        if not self.visible or not request or self.visible.configID == request.id then self:Hide() end
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
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
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
