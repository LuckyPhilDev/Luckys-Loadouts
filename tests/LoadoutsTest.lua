-- luacheck: globals LuckyLoadouts PlayerSpellsFrame TalentFrameBaseMixin Enum C_Timer C_ClassTalents C_Traits C_Map C_PartyInfo
-- luacheck: globals GetSpecialization GetSpecializationInfo InCombatLockdown IsInInstance GetInstanceInfo CreateFrame

local script = arg[0]:gsub("\\", "/")
local root = script:match("^(.*)/tests/[^/]+$") .. "/"

local tests, passed = 0, 0
local function check(condition, message)
    tests = tests + 1
    if not condition then error("FAIL: " .. message, 2) end
    passed = passed + 1
end

local timers = {}
local frames = {}
local currentSpecID = 101
local selectedID = 1
local inCombat = false
local staged = false
local lastSelectedWrites = {}
local canEdit = true
local canCreate = true
local activeConfigID = 900
local loadResult = 2
local mutationCount = 0
local commitCount = 0
local rollbackCount = 0
local commitShouldSucceed = true
local readyForCommit = true
local readyCalls, readyArgCount = 0, nil
local commitConfigIDs = {}
local rollbackConfigIDs = {}
local currentSnapshot
local inInstanceState = true
local instanceTypeState = "party"
local mapID = 100
local configsBySpec = { [101] = { 1, 2 }, [202] = { 3 } }
local configInfo = {
    [1] = { name = "Alpha" },
    [2] = { name = "Beta" },
    [3] = { name = "Gamma" },
}
local createdNames = {}

Enum = { LoadConfigResult = { Error = 0, NoChangesNecessary = 1, LoadInProgress = 2, Ready = 3 } }
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end }
C_ClassTalents = {
    GetConfigIDsBySpecID = function(specID) return configsBySpec[specID] end,
    GetLastSelectedSavedConfigID = function() return selectedID end,
    GetActiveConfigID = function() return activeConfigID end,
    CanEditTalents = function() return canEdit end,
    CanCreateNewConfig = function() return canCreate end,
    RequestNewConfig = function(name)
        mutationCount = mutationCount + 1
        createdNames[#createdNames + 1] = name
        local configID = 4
        configsBySpec[101][#configsBySpec[101] + 1] = configID
        configInfo[configID] = { name = name }
        return true
    end,
    LoadConfig = function()
        mutationCount = mutationCount + 1
        return loadResult
    end,
    UpdateLastSelectedSavedConfigID = function(specID, configID)
        lastSelectedWrites[#lastSelectedWrites + 1] = { specID = specID, configID = configID }
    end,
    RenameConfig = function(id, name)
        mutationCount = mutationCount + 1
        configInfo[id].name = name
        return true
    end,
}
C_Traits = {
    GetConfigInfo = function(id) return configInfo[id] end,
    ConfigHasStagedChanges = function() return staged end,
    IsReadyForCommit = function(...)
        readyCalls = readyCalls + 1
        readyArgCount = select("#", ...)
        return readyForCommit
    end,
    CommitConfig = function(configID)
        mutationCount = mutationCount + 1
        commitCount = commitCount + 1
        commitConfigIDs[#commitConfigIDs + 1] = configID
        return commitShouldSucceed
    end,
    RollbackConfig = function(configID)
        mutationCount = mutationCount + 1
        rollbackCount = rollbackCount + 1
        rollbackConfigIDs[#rollbackConfigIDs + 1] = configID
    end,
}
C_Map = { GetBestMapForUnit = function() return mapID end }
C_PartyInfo = { IsDelveInProgress = function() return false end }
function GetSpecialization() return 1 end
function GetSpecializationInfo() return currentSpecID, currentSpecID == 101 and "First" or "Second" end
function InCombatLockdown() return inCombat end
function IsInInstance() return inInstanceState, instanceTypeState end
function GetInstanceInfo() return "Test Dungeon", "party", 1, "Normal", 5, false, false, 42 end
function CreateFrame()
    local frame = { events = {} }
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:SetScript(kind, fn) self[kind] = fn end
    frames[#frames + 1] = frame
    return frame
end

local function runTimers()
    local pending = timers
    timers = {}
    for _, timer in ipairs(pending) do timer.fn() end
end

dofile(root .. "Luckys_Loadouts/Strings.lua")
dofile(root .. "Luckys_Loadouts/Defaults.lua")
dofile(root .. "Luckys_Loadouts/Loadouts.lua")
dofile(root .. "Luckys_Loadouts/Reminders.lua")

LuckyLoadouts.Settings = {
    ShowReminder = function() end,
    HideReminder = function() end,
    SetReminderCombat = function() end,
}

LuckyLoadouts.Loadouts:Init()
local characterDB = LuckyLoadouts.CopyDefaults({}, LuckyLoadouts.Defaults.character)
LuckyLoadouts.Reminders:Init(characterDB)

local missingSpecWrites = {
    function() return LuckyLoadouts.Reminders:SetCategory(nil, "Dungeon", 1) end,
    function() return LuckyLoadouts.Reminders:SetCurrentInstance(nil, 1) end,
    function() return LuckyLoadouts.Reminders:SetInstance(nil, 42, 1) end,
    function() return LuckyLoadouts.Reminders:RemoveInstance(nil, 42) end,
}
for index, write in ipairs(missingSpecWrites) do
    local ok, result = pcall(write)
    check(ok and result == false, "assignment write " .. index .. " rejects a missing specialization")
end

local list, err, byID = LuckyLoadouts.Loadouts:Read(101)
check(err == nil and #list == 2 and byID[1].selected, "production loadout read keeps selected identity")

local assignments = LuckyLoadouts.GetSpecAssignments(characterDB, 101)
assignments.categories.Dungeon = 1
assignments.instances[42] = { configID = 2, category = "Dungeon", label = "Test Dungeon" }
local snapshot = { category = "Dungeon", instanceID = 42, label = "Test Dungeon", key = "Dungeon:42" }
local match = LuckyLoadouts.Reminders.ResolveAssignment(assignments, snapshot, byID)
check(match.configID == 2 and match.source == "instance:42", "instance override wins over category default")

local missing = LuckyLoadouts.Reminders.ResolveAssignment(assignments, snapshot, { [1] = byID[1] })
check(missing.configID == 2 and missing.valid == false, "deleted target remains invalid and blocks fallback")
check(assignments.instances[42].configID == 2, "deleted target assignment is retained")

local otherCharacter = LuckyLoadouts.CopyDefaults({}, LuckyLoadouts.Defaults.character)
LuckyLoadouts.GetSpecAssignments(otherCharacter, 101).categories.Dungeon = 2
LuckyLoadouts.GetSpecAssignments(characterDB, 202).categories.Dungeon = 3
check(assignments.categories.Dungeon == 1, "character assignment tables are isolated")
check(LuckyLoadouts.GetSpecAssignments(characterDB, 202).categories.Dungeon == 3,
    "specialization assignment tables are isolated")

local created = LuckyLoadouts.Loadouts:Create("New Loadout")
check(created and createdNames[1] == "New Loadout" and configInfo[4].name == "New Loadout",
    "new loadout uses Blizzard's native creation API")
canCreate = false
local blockedCreate, createError = LuckyLoadouts.Loadouts:Create("Another Loadout")
check(not blockedCreate and createError == LuckyLoadouts.Strings.CREATE_LIMIT,
    "new loadout respects Blizzard's saved-loadout limit")
canCreate = true

local renamed = false
LuckyLoadouts.Loadouts:AddListener(function(kind) if kind == "renamed" then renamed = true end end)
local renameOK = LuckyLoadouts.Loadouts:Rename(2, "  Beta Prime  ")
check(renameOK and renamed and configInfo[2].name == "Beta Prime", "rename observes Blizzard state before success")
check(assignments.instances[42].configID == 2, "rename preserves numeric assignment")

activeConfigID = nil
check(LuckyLoadouts.Loadouts:GetSwitchBlocker(2) == nil,
    "starter build has no active config and therefore no staged changes")
activeConfigID = 900

staged = true
local mutationsBefore = mutationCount
local switchOK, blocker = LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
check(not switchOK and blocker == LuckyLoadouts.Strings.EDITS_STAGED, "staged edits refuse switching")
check(mutationCount == mutationsBefore, "staged refusal makes no native mutation")
staged = false

loadResult = Enum.LoadConfigResult.Error
switchOK = LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
check(not switchOK and LuckyLoadouts.Loadouts:GetPending() == nil, "enum failure clears pending state")

selectedID = 1
loadResult = Enum.LoadConfigResult.NoChangesNecessary
switchOK = LuckyLoadouts.Loadouts:RequestSwitch(1, "test")
check(switchOK and LuckyLoadouts.Loadouts:GetPending() == nil, "no-change succeeds only after selected identity is observed")

selectedID = 1
loadResult = Enum.LoadConfigResult.LoadInProgress
switchOK = LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
check(switchOK and LuckyLoadouts.Loadouts:GetPending().state == "loading", "pending enum remains pending")
selectedID = 2
LuckyLoadouts.Loadouts:ObserveNativeState()
check(LuckyLoadouts.Loadouts:GetPending() == nil, "pending switch completes from observed selected identity")

selectedID = 1
loadResult = Enum.LoadConfigResult.Ready
local lastSwitchEvent
LuckyLoadouts.Loadouts:AddListener(function(kind)
    if kind == "applyRequired" or kind == "switchBlocked" or kind == "switchFailed" then
        lastSwitchEvent = kind
    end
end)
switchOK = LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
check(switchOK and LuckyLoadouts.Loadouts:GetPending().state == "applyRequired", "ready enum requires explicit Apply")
local applyPending = LuckyLoadouts.Loadouts:GetPending()
local blockedSwitch = LuckyLoadouts.Loadouts:RequestSwitch(1, "test")
check(not blockedSwitch and lastSwitchEvent == "switchBlocked"
        and LuckyLoadouts.Loadouts:GetPending() == applyPending
        and applyPending.state == "applyRequired",
    "blocked repeat switch preserves pending Apply affordance")
local applied = LuckyLoadouts.Loadouts:ApplyPending()
check(applied and commitCount == 1 and readyCalls == 1 and readyArgCount == 0
        and commitConfigIDs[#commitConfigIDs] == 900,
    "Apply commits the active working config from an explicit click")
selectedID = 2
LuckyLoadouts.Loadouts:ObserveNativeState()
check(LuckyLoadouts.Loadouts:GetPending() == nil, "Apply completion still requires observed selected identity")

selectedID = 1
activeConfigID = nil
LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
local nilCommitBefore, nilRollbackBefore = commitCount, rollbackCount
local nilApply, nilApplyError = LuckyLoadouts.Loadouts:ApplyPending()
check(not nilApply and nilApplyError == LuckyLoadouts.Strings.NATIVE_UNKNOWN
        and commitCount == nilCommitBefore and rollbackCount == nilRollbackBefore,
    "Apply with no active config performs no commit or rollback")

activeConfigID = 901
readyForCommit = false
LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
local notReadyCommitBefore, notReadyRollbackBefore = commitCount, rollbackCount
local notReadyApply = LuckyLoadouts.Loadouts:ApplyPending()
check(not notReadyApply and commitCount == notReadyCommitBefore and rollbackCount == notReadyRollbackBefore,
    "not-ready Apply performs no rollback")

activeConfigID = 902
readyForCommit = true
commitShouldSucceed = false
LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
local failedApply = LuckyLoadouts.Loadouts:ApplyPending()
check(not failedApply and rollbackCount == 1 and rollbackConfigIDs[#rollbackConfigIDs] == 902
        and commitConfigIDs[#commitConfigIDs] == 902 and LuckyLoadouts.Loadouts:GetPending() == nil,
    "failed Apply rolls back the active working config")
commitShouldSucceed = true
activeConfigID = 900

selectedID = 1
loadResult = Enum.LoadConfigResult.LoadInProgress
local frameSelection, frameCommitID
TalentFrameBaseMixin = { CommitUpdateReasons = { CommitStarted = 1 } }
PlayerSpellsFrame = { TalentsFrame = {
    IsInspecting = function() return false end,
    IsCommitInProgress = function() return frameCommitID ~= nil end,
    SetSelectedSavedConfigID = function(_, configID, autoApply, skipLoad)
        frameSelection = { configID = configID, autoApply = autoApply, skipLoad = skipLoad }
    end,
    SetCommitStarted = function(_, configID) frameCommitID = configID end,
    UpdateConfigButtonsState = function() end,
} }
local writesBefore = #lastSelectedWrites
LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
check(frameSelection and frameSelection.configID == 2 and not frameSelection.autoApply and frameSelection.skipLoad,
    "a switch moves the talent frame's dropdown selection without loading again")
check(frameCommitID == 2, "a loading switch marks the talent frame's commit started so its picker disables")
check(#lastSelectedWrites == writesBefore, "the last-selected pointer waits for the cast to land")
check(LuckyLoadouts.Loadouts:GetPending() ~= nil and LuckyLoadouts.Loadouts:GetSwitchBlocker(2) ~= nil,
    "a pending switch blocks a repeat switch")
LuckyLoadouts.Loadouts:HandleEvent("CONFIG_COMMIT_FAILED")
check(LuckyLoadouts.Loadouts:GetPending() == nil and #lastSelectedWrites == writesBefore,
    "an interrupted commit clears the pending switch and leaves the pointer alone")
check(LuckyLoadouts.Loadouts:GetSwitchBlocker(2) ~= nil,
    "a switch in progress in Blizzard's own dropdown blocks switching")
frameCommitID = nil
check(LuckyLoadouts.Loadouts:GetSwitchBlocker(2) == nil, "Switch works again once no commit is in progress")

LuckyLoadouts.Loadouts:RequestSwitch(2, "test")
frameCommitID = nil
LuckyLoadouts.Loadouts:HandleEvent("TRAIT_CONFIG_UPDATED", activeConfigID)
local lastWrite = lastSelectedWrites[#lastSelectedWrites]
check(lastWrite and lastWrite.specID == 101 and lastWrite.configID == 2,
    "a landed commit moves Blizzard's last-selected pointer to the requested loadout")
selectedID = 2
LuckyLoadouts.Loadouts:ObserveNativeState()
check(LuckyLoadouts.Loadouts:GetPending() == nil, "the switch completes once the pointer moves")
PlayerSpellsFrame, TalentFrameBaseMixin = nil, nil
selectedID = 1

local shown, hidden = {}, 0
local controllerSpec = 101
local controllerCombat = false
local controllerAssignments = {
    [101] = { categories = { Dungeon = 2, Raid = 2 }, instances = {} },
}
local controller = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return controllerSpec end,
    getAssignments = function(specID) return controllerAssignments[specID] end,
    getLoadouts = function() return byID, 1 end,
    inCombat = function() return controllerCombat end,
    snapshot = function() return currentSnapshot end,
    show = function(value, context) shown[#shown + 1] = { value = value, context = context } end,
    hide = function() hidden = hidden + 1 end,
    combatChanged = function(value) controllerCombat = value end,
    after = C_Timer.After,
})

local dungeonA = { category = "Dungeon", instanceID = 10, label = "A", key = "Dungeon:10" }
local dungeonB = { category = "Dungeon", instanceID = 11, label = "B", key = "Dungeon:11" }
controller:Evaluate(dungeonA)
controller:Evaluate(dungeonA)
controller:Dismiss()
controller:Evaluate(dungeonA)
check(#shown == 1, "repeat events and dismissal suppress a second reminder in one visit")
controller:Evaluate(dungeonB)
controller:Evaluate(dungeonA)
check(#shown == 3, "leaving for another valid context resets visit suppression")
controller:AssignmentChanged(101)
check(#shown == 4, "assignment revision reevaluates current visit")
controller:Dismiss()
currentSnapshot = dungeonA
check(controller:Replay() and #shown == 5, "replay shows a dismissed reminder again")

inInstanceState = false
instanceTypeState = "none"
mapID = 100
local openWorldA = LuckyLoadouts.Reminders.ClassifyContent()
mapID = 200
local openWorldB = LuckyLoadouts.Reminders.ClassifyContent()
mapID = 300
local openWorldC = LuckyLoadouts.Reminders.ClassifyContent()
local openWorldShows = 0
local openWorldController = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return 101 end,
    getAssignments = function() return { categories = { OpenWorld = 2 }, instances = {} } end,
    getLoadouts = function() return byID, 1 end,
    inCombat = function() return false end,
    snapshot = function() return openWorldC end,
    show = function() openWorldShows = openWorldShows + 1 end,
    hide = function() end,
    combatChanged = function() end,
    after = C_Timer.After,
})
openWorldController:Evaluate(openWorldA)
openWorldController:Dismiss()
openWorldController:Evaluate(openWorldB)
openWorldController:Evaluate(openWorldC)
check(openWorldShows == 1 and openWorldA.key == openWorldB.key and openWorldB.key == openWorldC.key,
    "open-world zone boundaries remain one visit")
check(openWorldA.instanceID == nil and openWorldA.uiMapID == 100,
    "open-world UI map ID is not stored as an instance ID")
inInstanceState = true
instanceTypeState = "party"

local visibleCombat = false
local visibleCombatShows, visibleCombatHides = 0, 0
local combatTransitions = {}
currentSnapshot = dungeonA
local visibleCombatController = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return 101 end,
    getAssignments = function() return controllerAssignments[101] end,
    getLoadouts = function() return byID, 1 end,
    inCombat = function() return visibleCombat end,
    snapshot = function() return currentSnapshot end,
    show = function() visibleCombatShows = visibleCombatShows + 1 end,
    hide = function() visibleCombatHides = visibleCombatHides + 1 end,
    combatChanged = function(value)
        visibleCombat = value
        combatTransitions[#combatTransitions + 1] = value
    end,
    after = C_Timer.After,
})
visibleCombatController:Evaluate(dungeonA)
visibleCombatController:CombatChanged(true)
visibleCombatController:ScheduleRefresh(false)
runTimers()
check(visibleCombatShows == 1 and visibleCombatHides == 0 and visibleCombatController.visible ~= nil
        and combatTransitions[1] == true,
    "shown reminder survives combat with its switch disabled")
visibleCombatController:CombatChanged(false)
visibleCombatController:ScheduleRefresh(false)
runTimers()
check(visibleCombatShows == 1 and visibleCombatHides == 0 and visibleCombatController.visible ~= nil
        and combatTransitions[2] == false,
    "shown reminder switch is re-enabled after combat")

local combatShown = {}
local combatController = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return 101 end,
    getAssignments = function() return controllerAssignments[101] end,
    getLoadouts = function() return byID, 1 end,
    inCombat = function() return controllerCombat end,
    snapshot = function() return currentSnapshot end,
    show = function(_, context) combatShown[#combatShown + 1] = context.key end,
    hide = function() end,
    combatChanged = function(value) controllerCombat = value end,
    after = C_Timer.After,
})
controllerCombat = true
combatController:Evaluate(dungeonA)
currentSnapshot = dungeonB
combatController:CombatChanged(false)
runTimers()
check(#combatShown == 1 and combatShown[1] == dungeonB.key, "combat deferral reevaluates latest context")

local staleShown = {}
local staleController = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return 101 end,
    getAssignments = function() return controllerAssignments[101] end,
    getLoadouts = function() return byID, 1 end,
    inCombat = function() return false end,
    snapshot = function() return currentSnapshot end,
    show = function(_, context) staleShown[#staleShown + 1] = context.key end,
    hide = function() end,
    combatChanged = function() end,
    after = C_Timer.After,
})
currentSnapshot = dungeonA
staleController:ScheduleRefresh(false)
currentSnapshot = dungeonB
staleController:ScheduleRefresh(false)
runTimers()
check(#staleShown == 1 and staleShown[1] == dungeonB.key, "stale scheduled callback is rejected")

local eventMutations = mutationCount
for _, frame in ipairs(frames) do
    if frame.OnEvent and frame.events.ZONE_CHANGED_NEW_AREA then
        frame.OnEvent(frame, "ZONE_CHANGED_NEW_AREA")
    end
end
runTimers()
check(mutationCount == eventMutations, "event handlers never initiate talent mutation")

print(string.format("LoadoutsTest: %d/%d assertions passed", passed, tests))
