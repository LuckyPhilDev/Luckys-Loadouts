-- luacheck: globals LuckyLoadouts PlayerSpellsFrame TalentFrameBaseMixin Enum C_Timer C_ClassTalents C_Traits C_Map C_PartyInfo ExportUtil
-- luacheck: globals GetSpecialization GetSpecializationInfo InCombatLockdown IsInInstance GetInstanceInfo CreateFrame
-- luacheck: globals LOADOUT_ERROR_BAD_STRING
-- luacheck: globals C_RaidLocks EJ_GetInstanceForMap EJ_SelectInstance EJ_GetEncounterInfoByIndex EJ_GetCreatureInfo

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
local deletedConfigIDs = {}
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

Enum = {
    LoadConfigResult = { Error = 0, NoChangesNecessary = 1, LoadInProgress = 2, Ready = 3 },
    TraitEdgeType = { VisualOnly = 0, SufficientForAvailability = 2, RequiredForAvailability = 3 },
}
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
    DeleteConfig = function(id)
        mutationCount = mutationCount + 1
        deletedConfigIDs[#deletedConfigIDs + 1] = id
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

dofile(root .. "src/Strings.lua")
dofile(root .. "src/Constants.lua")
dofile(root .. "src/Defaults.lua")
dofile(root .. "src/Journal.lua")
dofile(root .. "src/Loadouts.lua")
dofile(root .. "src/Reminders.lua")
dofile(root .. "src/Talents.lua")

LuckyLoadouts.Settings = {
    ShowReminder = function() end,
    HideReminder = function() end,
    SetReminderCombat = function() end,
}

local characterDB = LuckyLoadouts.CopyDefaults({}, LuckyLoadouts.Defaults.character)
LuckyLoadouts.Loadouts:Init(characterDB)
LuckyLoadouts.Talents:Init()
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

check(LuckyLoadouts.Loadouts:Move(1, 2), "dropping a loadout lower succeeds")
local moved = LuckyLoadouts.Loadouts:Read(101)
check(moved[1].id == 2 and moved[2].id == 1, "moved loadout keeps its new position")
check(not LuckyLoadouts.Loadouts:Move(1, 3), "a loadout cannot drop past the end of the list")
check(LuckyLoadouts.Loadouts:Move(1, 1) and LuckyLoadouts.Loadouts:Read(101)[1].id == 1,
    "dropping a loadout back on top restores the order")

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
local blankCreate, blankCreateError = LuckyLoadouts.Loadouts:Create("   ")
check(not blankCreate and blankCreateError == LuckyLoadouts.Strings.RENAME_BLANK,
    "new loadout rejects blank names")
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

local reentered = false
LuckyLoadouts.Loadouts:AddListener(function(kind)
    if kind == "switchPending" and not reentered then
        reentered = true
        LuckyLoadouts.Loadouts:ObserveNativeState()
    end
end)
selectedID = 1
loadResult = Enum.LoadConfigResult.NoChangesNecessary
local reenteredSwitchOK = LuckyLoadouts.Loadouts:RequestSwitch(1, "test")
check(reenteredSwitchOK and LuckyLoadouts.Loadouts:GetPending() == nil,
    "a synchronous switch listener may finish the pending switch")

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
local handedRollbacks = rollbackCount
LuckyLoadouts.Loadouts:HandleEvent("CONFIG_COMMIT_FAILED", activeConfigID)
check(LuckyLoadouts.Loadouts:GetPending() == nil and #lastSelectedWrites == writesBefore,
    "an interrupted commit clears the pending switch and leaves the pointer alone")
runTimers()
check(rollbackCount == handedRollbacks, "a failed load the shown talent frame already undid is not rolled back again")
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

-- Switching from the reminder with the Talents window hidden.
loadResult = Enum.LoadConfigResult.LoadInProgress
LuckyLoadouts.Loadouts:RequestSwitch(2, "reminder")
staged = true
local unhandedRollbacks = rollbackCount
LuckyLoadouts.Loadouts:HandleEvent("CONFIG_COMMIT_FAILED", activeConfigID)
runTimers()
check(rollbackCount == unhandedRollbacks + 1 and rollbackConfigIDs[#rollbackConfigIDs] == activeConfigID,
    "an interrupted load left staged is rolled back")
staged = false
check(LuckyLoadouts.Loadouts:GetPending() == nil and LuckyLoadouts.Loadouts:GetSwitchBlocker(2) == nil,
    "after the rollback the switch can be tried again")

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

local deleteEvent, deleteMessage
LuckyLoadouts.Loadouts:AddListener(function(kind, message)
    if kind == "deleted" or kind == "deleteFailed" then
        deleteEvent, deleteMessage = kind, message
    end
end)
local quickDeleteOK = LuckyLoadouts.Loadouts:Delete(1)
check(quickDeleteOK and #deletedConfigIDs == 1 and deletedConfigIDs[1] == 1,
    "quick delete sends one native deletion request")
check(deleteEvent == "deleted" and deleteMessage == LuckyLoadouts.Strings.DELETE_OK,
    "quick delete reports success")

-- The Voidspire: Averzian opens Vorasius and Salhadaar, both open Vaelgor & Ezzorak.
local VOIDSPIRE_BOSSES = {
    { encounterID = 2733, dungeonEncounterID = 3001, name = "Imperator Averzian" },
    { encounterID = 2734, dungeonEncounterID = 3002, name = "Vorasius" },
    { encounterID = 2736, dungeonEncounterID = 3003, name = "Fallen-King Salhadaar" },
    { encounterID = 2735, dungeonEncounterID = 3004, name = "Vaelgor & Ezzorak" },
}
local voidspireLayout = LuckyLoadouts.Constants.RAID_LAYOUTS[1307]
local function nextNames(killedNames)
    local names = {}
    local available = LuckyLoadouts.Journal.AvailableBosses(VOIDSPIRE_BOSSES, voidspireLayout,
        function(boss) return killedNames[boss.name] == true end)
    for index, boss in ipairs(available) do names[index] = boss.name end
    return table.concat(names, ", ")
end
check(nextNames({}) == "Imperator Averzian", "only the entrance boss is next in a fresh raid")
check(nextNames({ ["Imperator Averzian"] = true }) == "Vorasius, Fallen-King Salhadaar",
    "the entrance boss opens both wings, in journal order")
check(nextNames({ ["Imperator Averzian"] = true, Vorasius = true }) == "Fallen-King Salhadaar",
    "a boss needing two kills waits for both")
check(#LuckyLoadouts.Journal.AvailableBosses(VOIDSPIRE_BOSSES, nil, function() return false end) == 4,
    "a raid with no layout treats every living boss as next")

-- Standing in the raid, with Averzian dead on the lockout.
local killedEncounters = { [3001] = true }
C_RaidLocks = { IsEncounterComplete = function(_, dungeonEncounterID) return killedEncounters[dungeonEncounterID] end }
function EJ_GetInstanceForMap() return 1307 end
function EJ_SelectInstance() end
function EJ_GetCreatureInfo() end
function EJ_GetEncounterInfoByIndex(index)
    local boss = VOIDSPIRE_BOSSES[index]
    if not boss then return nil end
    return boss.name, nil, boss.encounterID, nil, nil, nil, boss.dungeonEncounterID
end
local realGetInstanceInfo = GetInstanceInfo
function GetInstanceInfo() return "The Voidspire", "raid", 16, "Mythic", 20, false, false, 2900 end
local raidSnapshot = LuckyLoadouts.Reminders.ClassifyContent()
check(raidSnapshot.category == "Raid" and #raidSnapshot.bosses == 2
        and raidSnapshot.key == "Raid:2900:2734:2736",
    "a raid snapshot carries the next bosses, and a new set of them makes a new visit")
GetInstanceInfo = realGetInstanceInfo

local raidData = LuckyLoadouts.GetSpecAssignments(characterDB, 101)
raidData.categories.Raid = 1
local voidspire = { id = 2900, journalID = 1307, category = "Raid", label = "The Voidspire" }
local loadoutsByID = { [1] = { id = 1, name = "Alpha" }, [2] = { id = 2, name = "Beta" } }
LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, VOIDSPIRE_BOSSES[2], 2)
local bossMatch = LuckyLoadouts.Reminders.ResolveAssignment(raidData, raidSnapshot, loadoutsByID)
check(bossMatch.configID == 2 and bossMatch.label == "Vorasius" and not bossMatch.choices,
    "one assigned next boss gives a single suggestion")

LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, VOIDSPIRE_BOSSES[3], 1)
local choiceMatch = LuckyLoadouts.Reminders.ResolveAssignment(raidData, raidSnapshot, loadoutsByID)
check(choiceMatch.choices and #choiceMatch.choices == 2
        and LuckyLoadouts.Reminders.Offers(choiceMatch, 1) and LuckyLoadouts.Reminders.Offers(choiceMatch, 2),
    "next bosses wanting different loadouts offer each as a choice")

LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, VOIDSPIRE_BOSSES[3], 2)
local sharedMatch = LuckyLoadouts.Reminders.ResolveAssignment(raidData, raidSnapshot, loadoutsByID)
check(not sharedMatch.choices and sharedMatch.label == "Vorasius, Fallen-King Salhadaar",
    "next bosses sharing a loadout are one suggestion")

local freshSnapshot = { category = "Raid", instanceID = 2900, label = "The Voidspire", key = "Raid:2900",
    bosses = { VOIDSPIRE_BOSSES[1] } }
local fallback = LuckyLoadouts.Reminders.ResolveAssignment(raidData, freshSnapshot, loadoutsByID)
check(fallback.source == "category:Raid" and fallback.configID == 1,
    "an unassigned next boss leaves the raid to its category default")

LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, nil, 2)
local instanceMatch = LuckyLoadouts.Reminders.ResolveAssignment(raidData, freshSnapshot, loadoutsByID)
check(instanceMatch.source == "instance:2900" and instanceMatch.configID == 2,
    "an instance assignment beats the category when no next boss is assigned")

LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, nil, nil)
LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, VOIDSPIRE_BOSSES[2], nil)
LuckyLoadouts.Reminders:SetInstanceAssignment(101, voidspire, VOIDSPIRE_BOSSES[3], nil)
check(raidData.instances[2900] == nil, "clearing every assignment drops the instance entry")


-- Talent reminders. Class pool 1: 10 Soothe (unbought), 20 Roar, 40 Typhoon (two ranks),
-- 60 Cyclone (unbought), 70 a talent others depend on. Spec pool 2: 30 a choice node, 50 a spec talent.
local nodes = {
    [10] = { ID = 10, activeRank = 0, ranksPurchased = 0, maxRanks = 1, entryIDs = { 101 }, pool = 1 },
    [20] = { ID = 20, activeRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 201 }, pool = 1,
        activeEntry = { entryID = 201 } },
    [30] = { ID = 30, activeRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 301, 302 }, pool = 2,
        activeEntry = { entryID = 301 } },
    [40] = { ID = 40, activeRank = 2, ranksPurchased = 2, maxRanks = 2, entryIDs = { 401 }, pool = 1,
        activeEntry = { entryID = 401 } },
    [50] = { ID = 50, activeRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 501 }, pool = 2,
        activeEntry = { entryID = 501 } },
    [60] = { ID = 60, activeRank = 0, ranksPurchased = 0, maxRanks = 1, entryIDs = { 601 }, pool = 1 },
    [70] = { ID = 70, activeRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 701 }, pool = 1,
        activeEntry = { entryID = 701 }, canRefundRank = false },
    [80] = { ID = 80, activeRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 801 }, pool = 1,
        activeEntry = { entryID = 801 }, maxed = true },
}
local talentCalls = {}
local refundAllowed = true
C_Traits.GetNodeInfo = function(_, nodeID) return nodes[nodeID] or { ID = 0 } end
C_Traits.GetNodeCost = function(_, nodeID)
    if nodes[nodeID].maxed then return {} end
    return { { ID = nodes[nodeID].pool, amount = 1 } }
end
C_Traits.RefundRank = function(_, nodeID)
    talentCalls[#talentCalls + 1] = "refund:" .. nodeID
    return refundAllowed
end
C_Traits.PurchaseRank = function(_, nodeID)
    talentCalls[#talentCalls + 1] = "purchase:" .. nodeID
    return true
end
C_Traits.SetSelection = function(_, nodeID, entryID)
    talentCalls[#talentCalls + 1] = "select:" .. nodeID .. ":" .. entryID
    return true
end

local Talents = LuckyLoadouts.Talents
local function talent(nodeID, entryID, choice) return { nodeID = nodeID, entryID = entryID, choice = choice } end
local soothe, roar, otherSide = talent(10, 101), talent(20, 201), talent(30, 302, true)
local typhoon, specTalent, cyclone, anchored = talent(40, 401), talent(50, 501), talent(60, 601), talent(70, 701)
local gone = talent(99, 999)
check(Talents.IsTaken(soothe) == false and Talents.IsTaken(roar) == true
        and Talents.IsTaken(otherSide) == false and Talents.IsTaken(gone) == nil,
    "a talent is taken only at rank, on its own side of a choice node, and unknown once removed")

local talentData = LuckyLoadouts.GetSpecAssignments({}, 101)
talentData.talents[42] = { soothe, gone }
local dungeonSnapshot = { category = "Dungeon", instanceID = 42, label = "Den", key = "Dungeon:42" }
local lines = LuckyLoadouts.Reminders.ResolveTalents(talentData, dungeonSnapshot, Talents.IsTaken)
check(lines and #lines == 1 and lines[1].label == "Den" and #lines[1].talents == 1 and lines[1].talents[1] == soothe
        and lines[1].wanted == talentData.talents[42],
    "a dungeon lists its missing talents, skipping any the tree no longer has")
talentData.bossTalents[2734] = { otherSide }
talentData.bossTalents[2736] = { roar }
lines = LuckyLoadouts.Reminders.ResolveTalents(talentData, raidSnapshot, Talents.IsTaken)
check(lines and #lines == 1 and lines[1].label == "Vorasius",
    "a raid lists only the next bosses still missing a talent")

-- The loadout step comes first, then the talents, and taking them clears the reminder.
local talentShown = {}
local talentController = LuckyLoadouts.Reminders.CreateController({
    getSpec = function() return 101 end,
    getAssignments = function() return { categories = { Dungeon = 2 }, instances = {}, talents = talentData.talents } end,
    getLoadouts = function() return byID, 1 end,
    isTaken = Talents.IsTaken,
    inCombat = function() return false end,
    snapshot = function() return dungeonSnapshot end,
    show = function(value) talentShown[#talentShown + 1] = value end,
    hide = function() end,
    combatChanged = function() end,
    after = C_Timer.After,
})
talentController:Evaluate(dungeonSnapshot)
check(#talentShown == 1 and talentShown[1].configID == 2, "the loadout reminder shows before talents")
talentController:Dismiss()
check(#talentShown == 2 and talentShown[2].talents, "dismissing the loadout moves on to the talents")
talentController:Evaluate(dungeonSnapshot)
check(#talentShown == 2, "an unchanged talent reminder is not shown again")
nodes[10].activeRank = 1
talentController:Evaluate(dungeonSnapshot)
check(talentController.visible == nil, "taking every wanted talent clears the reminder")
nodes[10].activeRank = 0
talentController:Evaluate(dungeonSnapshot)
check(#talentShown == 2, "a dismissed or cleared talent reminder stays away for the visit")

-- Planning a swap from the give-up priority list.
local function ids(talents)
    local out = {}
    for index, value in ipairs(talents) do out[index] = value.nodeID end
    return table.concat(out, ",")
end
local plan = Talents.PlanSwap({ soothe }, { cyclone, anchored, specTalent, roar, typhoon })
check(ids(plan.take) == "10" and ids(plan.giveUp) == "20" and #plan.blocked == 0,
    "the first talent in priority order that is taken, free to remove and from the same pool is given up")
plan = Talents.PlanSwap({ soothe }, { talent(80, 801) })
check(ids(plan.giveUp) == "80", "a maxed talent reporting no cost can still be given up")
plan = Talents.PlanSwap({ soothe }, { roar, typhoon }, { roar })
check(ids(plan.giveUp) == "40", "a talent wanted here is never given up")
plan = Talents.PlanSwap({ soothe, cyclone }, { roar })
check(ids(plan.take) == "10" and ids(plan.blocked) == "60",
    "a talent left without room is reported instead of swapped")
plan = Talents.PlanSwap({ soothe, cyclone }, { typhoon })
check(ids(plan.take) == "10,60" and ids(plan.giveUp) == "40", "a two-rank talent makes room for two")
check(ids(plan.freedFor[10]) == "40" and ids(plan.freedFor[60]) == "",
    "each taken talent names what it gave up, none when spare points covered it")
plan = Talents.PlanSwap({ otherSide }, {})
check(ids(plan.take) == "30" and #plan.giveUp == 0, "a choice node already bought changes sides for free")
plan = Talents.PlanSwap({ soothe }, {})
check(#plan.take == 0 and ids(plan.blocked) == "10", "with nothing to give up the swap cannot happen")

-- Dependencies: every node lists its children in visibleEdges.
local SUFFICIENT = Enum.TraitEdgeType.SufficientForAvailability
local function edges(parentID, ...)
    local list = {}
    for _, child in ipairs({ ... }) do list[#list + 1] = { targetNode = child, type = SUFFICIENT } end
    nodes[parentID].visibleEdges = list
end
configInfo[activeConfigID] = { treeIDs = { 1 } }
C_Traits.GetEntryInfo = function() return {} end
C_Traits.GetTreeNodes = function() return { 10, 20, 30, 40, 50, 60, 70, 80 } end
edges(20, 10)
plan = Talents.PlanSwap({ soothe }, { roar, typhoon })
check(ids(plan.take) == "10" and ids(plan.giveUp) == "40", "a talent the wanted one needs is never given up for it")
edges(20, 80)
edges(40, 80)
plan = Talents.PlanSwap({ soothe, cyclone }, { roar, typhoon })
check(ids(plan.take) == "10" and ids(plan.giveUp) == "20" and ids(plan.blocked) == "60",
    "a talent can go while another parent still reaches what is below, but not the last one")
edges(20)
edges(40, 60)
plan = Talents.PlanSwap({ soothe, cyclone }, { typhoon })
check(ids(plan.take) == "10" and ids(plan.locked) == "60", "a talent whose parent the swap gives up is locked")
for _, node in pairs(nodes) do node.visibleEdges = nil end
configInfo[activeConfigID] = nil

-- Swapping.
staged, canEdit, inCombat, commitShouldSucceed = false, true, false, true
local commitsBefore, rollbacksBefore = commitCount, rollbackCount
check(Talents.Swap({ soothe, otherSide }, { roar })
        and table.concat(talentCalls, ",") == "refund:20,purchase:10,select:30:302"
        and commitCount == commitsBefore + 1,
    "a swap gives up what the plan says, takes every talent it can and applies once")
check(Talents.GetBlocker() == LuckyLoadouts.Strings.SWAP_PENDING and not Talents.Swap({ soothe }, { roar }),
    "a second swap waits for the first to land")
Talents:HandleEvent("TRAIT_CONFIG_UPDATED", activeConfigID)
check(Talents.GetBlocker() == nil, "the swap ends when the active talents update")

talentCalls, refundAllowed = {}, false
commitsBefore = commitCount
local refused, refusedErr = Talents.Swap({ soothe }, { roar })
check(not refused and refusedErr and commitCount == commitsBefore and rollbackCount == rollbacksBefore + 1
        and #talentCalls == 1,
    "a refused refund rolls back and applies nothing")
refundAllowed = true

talentCalls = {}
check(not Talents.Swap({ soothe }, { cyclone }) and #talentCalls == 0, "a swap with no room changes nothing")

local swapFailure
check(Talents.Swap({ soothe }, { roar }, nil, function(message) swapFailure = message end), "a swap starts")
Talents:HandleEvent("CONFIG_COMMIT_FAILED")
check(swapFailure == LuckyLoadouts.Strings.SWAP_FAILED and Talents.GetBlocker() == nil,
    "an interrupted swap reports and can be tried again")

-- Creating a loadout from a talent string.
local Loadouts = LuckyLoadouts.Loadouts
local importedLoadouts = {}
local createStartedWithRanks
local importEntries = { { nodeID = 11, ranksPurchased = 2, selectionEntryID = 1 } }
LOADOUT_ERROR_BAD_STRING = "bad string"
configInfo[activeConfigID] = { name = "Active", treeIDs = { 77 } }
ExportUtil = { MakeImportDataStream = function(text) return { text = text } end }
C_Traits.GetLoadoutSerializationVersion = function() return 2 end
C_ClassTalents.ImportLoadout = function(configID, entries, name)
    importedLoadouts[#importedLoadouts + 1] = { configID = configID, entries = entries, name = name }
    return true
end
PlayerSpellsFrame = { TalentsFrame = {
    IsInspecting = function() return false end,
    SetSelectedSavedConfigID = function() end,
    OnTraitConfigCreateStarted = function(_, hasRanks) createStartedWithRanks = hasRanks end,
    ReadLoadoutHeader = function(_, stream) return stream.text ~= "bad", 2, 101, { 0 } end,
    IsHashEmpty = function() return true end,
    ReadLoadoutContent = function() return {} end,
    ConvertToImportLoadoutEntryInfo = function() return importEntries end,
} }

check(Loadouts:Create("Imported", "  ABC  ") and importedLoadouts[1].name == "Imported"
        and importedLoadouts[1].configID == activeConfigID and createStartedWithRanks == true,
    "a new loadout with a string is made through Blizzard's import API")
local badOK, badErr = Loadouts:Create("Imported", "bad")
check(not badOK and badErr == LOADOUT_ERROR_BAD_STRING and #importedLoadouts == 1, "a bad string makes nothing")
PlayerSpellsFrame = nil

print(string.format("LoadoutsTest: %d/%d assertions passed", passed, tests))
