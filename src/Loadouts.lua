-- luacheck: globals LuckyLoadouts PlayerSpellsFrame TalentFrameBaseMixin

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Loadouts = {}

local Loadouts = LuckyLoadouts.Loadouts
local S
local charDB
local listeners = {}
local pending
local renamePending
local nextToken = 0
local TIMEOUT_SECONDS = 12

local function emit(kind, message, data)
    for _, listener in ipairs(listeners) do
        listener(kind, message, data)
    end
end

local function currentSpec()
    local index = GetSpecialization()
    if not index then return nil end
    local specID, name = GetSpecializationInfo(index)
    if not specID then return nil end
    return specID, name
end

local function enumValue(name)
    return Enum and Enum.LoadConfigResult and Enum.LoadConfigResult[name]
end

local function resultIs(result, name)
    local value = enumValue(name)
    return value ~= nil and result == value
end

local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

local function verifiedLoadoutNameLimit()
    -- Unverified: confirm the retail rename edit box limit or a documented native constant.
    return nil
end

local function hasStagedChanges()
    local activeID = C_ClassTalents.GetActiveConfigID()
    if not activeID then return false end
    if not C_Traits.ConfigHasStagedChanges then return nil end
    local ok, staged = pcall(C_Traits.ConfigHasStagedChanges, activeID)
    if not ok then return nil end
    return staged and true or false
end

local function nativeCanEdit()
    if not C_ClassTalents.CanEditTalents then return nil end
    local ok, canEdit, reason = pcall(C_ClassTalents.CanEditTalents)
    if not ok or canEdit == nil then return nil end
    return canEdit and true or false, reason
end

local function finishSwitch(kind, message)
    local old = pending
    pending = nil
    emit(kind, message, old)
end

local function startSwitchTimeout(token)
    C_Timer.After(TIMEOUT_SECONDS, function()
        if not pending or pending.token ~= token then return end
        finishSwitch("switchFailed", S.SWITCH_TIMEOUT)
    end)
end

local function startRenameTimeout(token)
    C_Timer.After(TIMEOUT_SECONDS, function()
        if not renamePending or renamePending.token ~= token then return end
        local old = renamePending
        renamePending = nil
        emit("renameFailed", S.RENAME_FAILED, old)
    end)
end

local function requestNativeApply(activeConfigID)
    -- Unverified: confirm C_Traits.CommitConfig is permitted from a plain button click on retail.
    if not C_Traits.IsReadyForCommit or not C_Traits.CommitConfig or not C_Traits.RollbackConfig then
        return false, S.APPLY_UNVERIFIED
    end
    local readyOK, ready = pcall(C_Traits.IsReadyForCommit)
    if not readyOK or ready ~= true then
        return false, S.APPLY_UNVERIFIED
    end
    local commitOK, committed = pcall(C_Traits.CommitConfig, activeConfigID)
    if not commitOK or committed ~= true then
        pcall(C_Traits.RollbackConfig, activeConfigID)
        return false, S.APPLY_UNVERIFIED
    end
    return true
end

local function talentFrame()
    local talents = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talents or not talents.SetSelectedSavedConfigID or talents:IsInspecting() then return nil end
    return talents
end

-- Hand the switch to Blizzard's talent frame the way its own dropdown does.
-- It caches its dropdown selection and never rereads it while still valid, so
-- left stale its Apply saves the active tree into the old loadout. Marking the
-- commit started disables its picker for the cast, and the frame listens for
-- the commit finishing or failing even while hidden, reverting on failure.
local function handOffToTalentFrame(configID, state)
    local talents = talentFrame()
    if not talents then return end
    local autoApply, skipLoad = false, true
    talents:SetSelectedSavedConfigID(configID, autoApply, skipLoad)
    if state == "loading" and TalentFrameBaseMixin then
        talents:SetCommitStarted(configID, TalentFrameBaseMixin.CommitUpdateReasons.CommitStarted)
        talents:UpdateConfigButtonsState()
    end
end

-- Blizzard moves the pointer only once the loadout is live, so an interrupted
-- cast leaves it on the loadout the player still has.
local function markSelected(specID, configID)
    if C_ClassTalents.UpdateLastSelectedSavedConfigID then
        pcall(C_ClassTalents.UpdateLastSelectedSavedConfigID, specID, configID)
    end
end

function Loadouts:Init(characterDB)
    S = LuckyLoadouts.Strings
    charDB = characterDB
end

function Loadouts:AddListener(listener)
    listeners[#listeners + 1] = listener
end

function Loadouts:GetCurrentSpec()
    return currentSpec()
end

function Loadouts:Read(specID)
    specID = specID or currentSpec()
    if not specID then return nil, S.NO_SPEC end

    local ids = C_ClassTalents.GetConfigIDsBySpecID(specID)
    if type(ids) ~= "table" then return nil, S.LOADOUT_DATA_UNKNOWN end

    local selectedID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    local list, byID = {}, {}
    for _, configID in ipairs(ids) do
        local info = C_Traits.GetConfigInfo(configID)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            local entry = {
                id = configID,
                name = info.name,
                selected = selectedID ~= nil and configID == selectedID,
            }
            list[#list + 1] = entry
            byID[configID] = entry
        end
    end
    -- Loadouts the player has not placed yet (new ones) follow, alphabetically.
    local spec = LuckyLoadouts.GetSpecAssignments(charDB, specID)
    local rank = {}
    for position, configID in ipairs(spec and spec.order or {}) do rank[configID] = position end
    table.sort(list, function(a, b)
        local rankA, rankB = rank[a.id] or math.huge, rank[b.id] or math.huge
        if rankA ~= rankB then return rankA < rankB end
        if a.name == b.name then return a.id < b.id end
        return a.name < b.name
    end)
    return list, nil, byID, selectedID
end

function Loadouts:GetSwitchBlocker(configID)
    if pending then return S.SWITCH_PENDING end
    local talents = talentFrame()
    if talents and talents:IsCommitInProgress() then return S.SWITCH_PENDING end
    if InCombatLockdown() then return S.IN_COMBAT end

    local specID = currentSpec()
    if not specID then return S.NO_SPEC end
    local list, err, byID = self:Read(specID)
    if not list then return err end
    if not byID[configID] then return S.LOADOUT_MISSING end

    local staged = hasStagedChanges()
    if staged == nil then return S.NATIVE_UNKNOWN end
    if staged then return S.EDITS_STAGED end

    local canEdit, reason = nativeCanEdit()
    if canEdit == nil then return S.NATIVE_UNKNOWN end
    if not canEdit then
        return type(reason) == "string" and reason ~= "" and reason or S.NATIVE_BLOCKED
    end
    return nil
end

function Loadouts:RequestSwitch(configID, source)
    local blocker = self:GetSwitchBlocker(configID)
    if blocker then
        emit("switchBlocked", blocker, { id = configID, source = source })
        return false, blocker
    end

    local specID = currentSpec()
    local ok, result = pcall(C_ClassTalents.LoadConfig, configID, true)
    if not ok then
        emit("switchFailed", S.SWITCH_FAILED, { id = configID, source = source })
        return false, S.SWITCH_FAILED
    end

    if resultIs(result, "Error") then
        emit("switchFailed", S.SWITCH_FAILED, { id = configID, source = source })
        return false, S.SWITCH_FAILED
    end

    nextToken = nextToken + 1
    pending = { id = configID, specID = specID, source = source, token = nextToken }

    if resultIs(result, "NoChangesNecessary") then
        pending.state = "noChange"
        markSelected(specID, configID)
        emit("switchPending", S.SWITCH_NO_CHANGE, pending)
    elseif resultIs(result, "LoadInProgress") then
        pending.state = "loading"
        emit("switchPending", S.SWITCH_PENDING, pending)
    elseif resultIs(result, "Ready") then
        pending.state = "applyRequired"
        emit("applyRequired", S.SWITCH_READY, pending)
    else
        finishSwitch("switchFailed", S.SWITCH_RESULT_UNKNOWN)
        return false, S.SWITCH_RESULT_UNKNOWN
    end
    if pending then handOffToTalentFrame(configID, pending.state) end

    startSwitchTimeout(nextToken)
    self:ObserveNativeState()
    return true
end

function Loadouts:ApplyPending()
    if not pending or pending.state ~= "applyRequired" then return false, S.APPLY_UNVERIFIED end
    if InCombatLockdown() then return false, S.IN_COMBAT end
    if currentSpec() ~= pending.specID then
        finishSwitch("switchFailed", S.SPEC_CHANGED)
        return false, S.SPEC_CHANGED
    end
    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    if not activeConfigID then
        finishSwitch("switchFailed", S.NATIVE_UNKNOWN)
        return false, S.NATIVE_UNKNOWN
    end
    local ok, err = requestNativeApply(activeConfigID)
    if not ok then
        finishSwitch("switchFailed", err)
        return false, err
    end
    pending.state = "applying"
    emit("switchPending", S.SWITCH_PENDING, pending)
    return true
end

function Loadouts:ObserveNativeState()
    if renamePending then
        if currentSpec() ~= renamePending.specID then
            local old = renamePending
            renamePending = nil
            emit("renameFailed", S.SPEC_CHANGED, old)
        else
            local info = C_Traits.GetConfigInfo(renamePending.id)
            if info and info.name == renamePending.name then
                local old = renamePending
                renamePending = nil
                emit("renamed", S.RENAME_OK, old)
            end
        end
    end

    if not pending then return end
    if currentSpec() ~= pending.specID then
        finishSwitch("switchFailed", S.SPEC_CHANGED)
        return
    end

    local list, _, byID, selectedID = self:Read(pending.specID)
    if not list then return end
    if not byID[pending.id] then
        finishSwitch("switchFailed", S.LOADOUT_MISSING)
    elseif selectedID == pending.id then
        local message = pending.state == "noChange" and S.SWITCH_NO_CHANGE or S.SWITCH_OK
        finishSwitch("switched", message)
    end
end

function Loadouts:Rename(configID, value)
    local specID = currentSpec()
    if not specID then return false, S.NO_SPEC end
    local list, err, byID = self:Read(specID)
    if not list then return false, err end
    if not byID[configID] then return false, S.LOADOUT_MISSING end

    local name = trim(type(value) == "string" and value or "")
    if name == "" then return false, S.RENAME_BLANK end
    local limit = verifiedLoadoutNameLimit()
    if limit and #name > limit then return false, S.RENAME_LIMIT_NATIVE end

    local ok, result = pcall(C_ClassTalents.RenameConfig, configID, name)
    if not ok or result == false then return false, S.RENAME_LIMIT_NATIVE end

    nextToken = nextToken + 1
    renamePending = { id = configID, specID = specID, name = name, token = nextToken }
    startRenameTimeout(nextToken)
    self:ObserveNativeState()
    return true
end

-- Blizzard has no ordering API, so this only reorders the addon's own lists.
function Loadouts:Move(configID, toIndex)
    local specID = currentSpec()
    if not specID then return false, S.NO_SPEC end
    local list, err = self:Read(specID)
    if not list then return false, err end
    local order, from = {}, nil
    for position, entry in ipairs(list) do
        order[position] = entry.id
        if entry.id == configID then from = position end
    end
    if not from then return false, S.LOADOUT_MISSING end
    if not order[toIndex] then return false end
    table.insert(order, toIndex, table.remove(order, from))
    LuckyLoadouts.GetSpecAssignments(charDB, specID).order = order
    emit("refreshed")
    return true
end

function Loadouts:Create(name)
    if not currentSpec() then return false, S.NO_SPEC end
    if InCombatLockdown() then return false, S.IN_COMBAT end
    name = trim(type(name) == "string" and name or "")
    if name == "" then return false, S.RENAME_BLANK end
    if not C_ClassTalents.CanCreateNewConfig or not C_ClassTalents.RequestNewConfig then
        return false, S.CREATE_FAILED
    end
    if not C_ClassTalents.CanCreateNewConfig() then return false, S.CREATE_LIMIT end

    local ok, created = pcall(C_ClassTalents.RequestNewConfig, name)
    if not ok or created ~= true then return false, S.CREATE_FAILED end
    emit("created", S.CREATE_OK)
    return true
end

function Loadouts:Delete(configID)
    local specID = currentSpec()
    if not specID then return false, S.NO_SPEC end
    if InCombatLockdown() then return false, S.IN_COMBAT end
    local list, err, byID = self:Read(specID)
    if not list then return false, err end
    if not byID[configID] then return false, S.LOADOUT_MISSING end
    if pending and pending.id == configID then
        finishSwitch("switchFailed", S.LOADOUT_MISSING)
    end

    local ok, result = pcall(C_ClassTalents.DeleteConfig, configID)
    if not ok or result == false then
        emit("deleteFailed", S.DELETE_FAILED)
        return false, S.DELETE_FAILED
    end
    emit("deleted", S.DELETE_OK)
    return true
end

function Loadouts:GetPending()
    return pending
end

function Loadouts:CancelPending(message)
    if pending then finishSwitch("switchFailed", message or S.SWITCH_FAILED) end
end

function Loadouts:HandleEvent(event, configID)
    -- An interrupted loadout cast leaves nothing else to observe, so take
    -- Blizzard's failure at its word instead of waiting out the timeout.
    if event == "CONFIG_COMMIT_FAILED" and pending then
        -- An interrupted load leaves the loadout staged, and staged changes block
        -- every retry. Blizzard's talent frame undoes them only while it is shown,
        -- so whatever it leaves a frame later is rolled back here. A switch never
        -- starts over staged edits, so nothing of the player's is lost.
        C_Timer.After(0, function()
            local activeID = C_ClassTalents.GetActiveConfigID()
            if activeID and hasStagedChanges() then
                pcall(C_Traits.RollbackConfig, activeID)
                emit("refreshed")
            end
        end)
        self:CancelPending(S.SWITCH_FAILED)
    end
    -- The active config updating is how Blizzard's own frame knows a commit landed.
    if event == "TRAIT_CONFIG_UPDATED" and pending
            and (pending.state == "loading" or pending.state == "applying")
            and configID == C_ClassTalents.GetActiveConfigID() then
        markSelected(pending.specID, pending.id)
    end
    self:ObserveNativeState()
    emit("refreshed")
end
