-- luacheck: globals LuckyLoadouts PlayerSpellsFrame PlayerSpellsUtil EventUtil

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Settings = {}

local SettingsUI = LuckyLoadouts.Settings
local C = LuckyUI.C
local S
local db
local charDB
local manager
local managerRows = {}
local managerInner
local emptyText
local managerStatus
local managerApply
local managerAssign
local managerNew
local renameDialog
local renameEdit
local renameStatus
local renameTarget
local assignDialog
local assignStatus
local assignCategoryRows = {}
local assignInstanceRows = {}
local assignInstanceInner
local assignCurrentButton
local reminder
local reminderText
local reminderStatus
local reminderSwitch
local reminderApply
local reminderMatch
local settingsPanel
local minimapButton
local showRename
local showAssignments

local function setTextColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3])
end

local function makeText(parent, size, color)
    local text = parent:CreateFontString(nil, "OVERLAY")
    text:SetFont(LuckyUI.BODY_FONT, size, "")
    setTextColor(text, color)
    return text
end

local BUTTON_HEIGHT = 24
local BUTTON_GAP = 8
local DIALOG_PAD = 16
local HEADER_HEIGHT = LuckyUI.HEADER_HEIGHT + 1
local CONTENT_TOP = HEADER_HEIGHT + DIALOG_PAD

local function makeButton(parent, label, width, variant)
    return LuckyUI.CreateButton(parent, label, width or 80, BUTTON_HEIGHT, variant)
end

-- Primary on the left, secondary pinned to the bottom-right corner.
local function placeButtonPair(parent, primary, secondary)
    secondary:SetPoint("BOTTOMRIGHT", -DIALOG_PAD, DIALOG_PAD)
    primary:SetPoint("RIGHT", secondary, "LEFT", -BUTTON_GAP, 0)
end

local function makeIconButton(parent, iconName, tooltip, size)
    return LuckyUI.CreateIconButton(parent, { icon = iconName, size = size or 20, tooltip = tooltip })
end

local function makeSurface(name, width, height, positionKey, title)
    local frame, header = LuckyUI.CreateWindow(name, width, height, title, { db = db, key = positionKey })
    return frame, header, frame.titleText
end

local function setStatus(text, message, errorState)
    text:SetText(message or "")
    local color = errorState and LuckyUI.C.danger or LuckyUI.C.textMuted
    setTextColor(text, color)
end

local function assignedName(configID, byID)
    if not configID then return S.NONE end
    return byID[configID] and byID[configID].name or (S.UNAVAILABLE .. ", " .. S.OVERRIDE_INVALID)
end

local MANAGER_WIDTH = 230
local MANAGER_ROW_HEIGHT = 32
local MANAGER_BAR_HEIGHT = HEADER_HEIGHT
local MANAGER_HINT_HEIGHT = 22
local MANAGER_FOOTER_HEIGHT = 40
local MANAGER_STANDALONE_MAX_HEIGHT = 430
local MANAGER_EMPTY_HEIGHT = 40
local MANAGER_TALENTS_TOP_OFFSET = 20
local SCROLLBAR_GUTTER = 22
local managerScroll

local function createManager()
    local managerBar
    manager, managerBar = makeSurface("LuckyLoadoutsManager", MANAGER_WIDTH, MANAGER_STANDALONE_MAX_HEIGHT,
        "manager", S.MANAGER_TITLE)
    manager.bar = managerBar

    managerAssign = makeIconButton(managerBar, "target", S.ASSIGN, 16)
    managerAssign:SetPoint("RIGHT", managerBar, "RIGHT", -34, 0)
    managerAssign:SetScript("OnClick", function() showAssignments() end)
    managerNew = makeIconButton(managerBar, "plus", S.NEW, 16)
    managerNew:SetPoint("RIGHT", managerAssign, "LEFT", -4, 0)
    managerNew:SetScript("OnClick", function()
        local ok, err = LuckyLoadouts.Loadouts:Create(S.NEW_LOADOUT_NAME)
        if not ok then setStatus(managerStatus, err, true) end
    end)

    local header = CreateFrame("Frame", nil, manager)
    header:SetHeight(MANAGER_HINT_HEIGHT)
    header:SetPoint("TOPLEFT", 1, -MANAGER_BAR_HEIGHT)
    header:SetPoint("TOPRIGHT", -1, -MANAGER_BAR_HEIGHT)
    LuckySettings.Rich.FillBg(header, C.bgInput)

    local hint = makeText(header, 10, C.textMuted)
    hint:SetPoint("LEFT", 10, 0)
    hint:SetPoint("RIGHT", -10, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(S.SWITCH_HINT)

    managerScroll = CreateFrame("ScrollFrame", nil, manager, "UIPanelScrollFrameTemplate")
    managerScroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    managerScroll:SetPoint("BOTTOMRIGHT", -1, MANAGER_FOOTER_HEIGHT)
    managerInner = CreateFrame("Frame", nil, managerScroll)
    managerInner:SetSize(MANAGER_WIDTH - 2, 1)
    managerScroll:SetScrollChild(managerInner)

    emptyText = makeText(managerInner, 12, C.textMuted)
    emptyText:SetPoint("TOPLEFT", 10, -18)
    emptyText:SetPoint("RIGHT", -10, 0)
    emptyText:SetJustifyH("LEFT")

    managerStatus = makeText(manager, 11, C.textMuted)
    managerStatus:SetPoint("BOTTOMLEFT", 10, 9)
    managerStatus:SetPoint("RIGHT", -10, 0)
    managerStatus:SetJustifyH("LEFT")

    managerApply = makeButton(manager, S.APPLY, 90, "primary")
    managerApply:SetPoint("BOTTOMRIGHT", -4, 2)
    managerApply:Hide()
    managerApply:SetScript("OnClick", function()
        local ok, err = LuckyLoadouts.Loadouts:ApplyPending()
        if not ok then setStatus(managerStatus, err, true) end
    end)

    manager:SetScript("OnShow", function() SettingsUI:RefreshManager() end)
end

-- Bolt the manager onto the right edge of the Talents tab, so it opens and
-- closes with it instead of floating on its own.
local function attachToTalents()
    local talents = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talents then return end

    manager:SetParent(PlayerSpellsFrame)
    manager:SetMovable(false)
    manager.bar:SetScript("OnDragStart", nil)
    manager.bar:SetScript("OnDragStop", nil)
    manager.closeButton:Hide()
    managerAssign:ClearAllPoints()
    managerAssign:SetPoint("RIGHT", manager.bar, "RIGHT", -8, 0)
    manager:ClearAllPoints()
    manager:SetPoint("TOPRIGHT", PlayerSpellsFrame, "TOPLEFT", 2, -MANAGER_TALENTS_TOP_OFFSET)
    manager:SetFrameStrata(PlayerSpellsFrame:GetFrameStrata())

    talents:HookScript("OnShow", function() manager:Show() end)
    talents:HookScript("OnHide", function() manager:Hide() end)

    -- Blizzard rebuilds its own loadout dropdown whenever the spec or the
    -- saved configs change, so redraw alongside it rather than guessing which
    -- event settled the data.
    if talents.RefreshLoadoutOptions then
        hooksecurefunc(talents, "RefreshLoadoutOptions", function() SettingsUI:RefreshManager() end)
    end
    -- Keeps the rows disabled for a switch started from Blizzard's own dropdown.
    hooksecurefunc(talents, "SetCommitStarted", function() SettingsUI:RefreshManager() end)

    manager:SetShown(talents:IsShown())
end

StaticPopupDialogs["LUCKY_LOADOUTS_DELETE"] = {
    button2 = CANCEL,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    OnAccept = function(_, configID)
        local ok, err = LuckyLoadouts.Loadouts:Delete(configID)
        if not ok then setStatus(managerStatus, err, true) end
    end,
}

local function confirmDelete(entry)
    local popup = StaticPopupDialogs["LUCKY_LOADOUTS_DELETE"]
    popup.button1 = S.DELETE
    popup.text = string.format(S.DELETE_CONFIRM, entry.name)
    StaticPopup_Show("LUCKY_LOADOUTS_DELETE", nil, nil, entry.id)
end

local function showRowMenu(owner, entry)
    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
        rootDescription:CreateTitle(entry.name)
        rootDescription:CreateButton(S.RENAME, function() showRename(entry) end)
        rootDescription:CreateDivider()
        rootDescription:CreateButton(S.DELETE, function() confirmDelete(entry) end)
    end)
end

local function acquireManagerRow(index)
    local row = managerRows[index]
    if row then return row end
    row = CreateFrame("Button", nil, managerInner)
    row:SetHeight(MANAGER_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * MANAGER_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hover = row:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.06)
    if index % 2 == 0 then
        local stripe = LuckySettings.Rich.FillBg(row, C.bgPanel)
        stripe:SetAlpha(0.5)
    end
    row.highlight = LuckySettings.Rich.FillBg(row, C.highlight, "ARTWORK")
    row.highlight:Hide()
    row.marker = row:CreateTexture(nil, "OVERLAY")
    row.marker:SetSize(3, MANAGER_ROW_HEIGHT)
    row.marker:SetPoint("LEFT", 0, 0)
    row.marker:SetColorTexture(C.goldPrimary[1], C.goldPrimary[2], C.goldPrimary[3], 1)
    row.marker:Hide()
    row.rename = makeIconButton(row, "pencil", S.RENAME, 14)
    row.rename:SetPoint("RIGHT", -8, 0)
    row.name = makeText(row, 12, C.textLight)
    row.name:SetPoint("TOPLEFT", 10, -4)
    row.name:SetPoint("RIGHT", row.rename, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.state = makeText(row, 10, C.textMuted)
    row.state:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
    row.state:SetPoint("RIGHT", row.name, "RIGHT")
    row.state:SetJustifyH("LEFT")
    row.state:SetWordWrap(false)
    managerRows[index] = row
    return row
end

local function createRenameDialog()
    local titleBar
    renameDialog, titleBar = makeSurface("LuckyLoadoutsRenameDialog", 360, 163, "manager", S.RENAME_TITLE)
    renameDialog:SetMovable(false)
    titleBar:SetScript("OnDragStart", nil)
    titleBar:SetScript("OnDragStop", nil)

    local prompt = makeText(renameDialog, 12, C.textLight)
    prompt:SetPoint("TOPLEFT", DIALOG_PAD, -CONTENT_TOP)
    prompt:SetText(S.RENAME_PROMPT)

    renameEdit = LuckyUI.CreateInput(renameDialog, { width = 360 - DIALOG_PAD * 2, height = BUTTON_HEIGHT })
    renameEdit:SetPoint("TOPLEFT", prompt, "BOTTOMLEFT", 0, -6)

    renameStatus = makeText(renameDialog, 10, C.danger)
    renameStatus:SetPoint("TOPLEFT", renameEdit, "BOTTOMLEFT", 0, -5)
    renameStatus:SetPoint("RIGHT", -DIALOG_PAD, 0)
    renameStatus:SetJustifyH("LEFT")

    local save = makeButton(renameDialog, S.SAVE, 90, "primary")
    local cancel = makeButton(renameDialog, S.CANCEL, 90)
    placeButtonPair(renameDialog, save, cancel)
    cancel:SetScript("OnClick", function() renameDialog:Hide() end)
    save:SetScript("OnClick", function()
        local ok, err = LuckyLoadouts.Loadouts:Rename(renameTarget, renameEdit:GetText())
        if not ok then setStatus(renameStatus, err, true) else setStatus(renameStatus, S.LOADING, false) end
    end)
    renameEdit:SetScript("OnEnterPressed", function() save:Click() end)
    renameEdit:SetScript("OnEscapePressed", function() renameDialog:Hide() end)
end

function showRename(entry)
    renameTarget = entry.id
    renameEdit:SetText(entry.name)
    renameEdit:HighlightText()
    setStatus(renameStatus, "", false)
    renameDialog:Show()
    renameEdit:SetFocus()
end

local function showLoadoutPicker(owner, list, onSelect)
    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
        for _, entry in ipairs(list) do
            rootDescription:CreateButton(entry.name, function() onSelect(entry) end)
        end
    end)
end

local function createAssignmentDialog()
    local titleBar
    assignDialog, titleBar = makeSurface("LuckyLoadoutsAssignDialog", 590, 563, "manager", S.ASSIGN_TITLE)
    assignDialog:SetMovable(false)
    titleBar:SetScript("OnDragStart", nil)
    titleBar:SetScript("OnDragStop", nil)

    assignStatus = makeText(assignDialog, 11, C.textMuted)
    assignStatus:SetPoint("TOPLEFT", 16, -41)
    assignStatus:SetPoint("RIGHT", -16, 0)
    assignStatus:SetJustifyH("LEFT")

    local categoryHeader = makeText(assignDialog, 10, C.goldPrimary)
    categoryHeader:SetPoint("TOPLEFT", 16, -69)
    categoryHeader:SetText(S.CATEGORY_DEFAULTS)

    local order = { "Raid", "Dungeon", "Delve", "OpenWorld", "Battleground", "Arena" }
    for index, category in ipairs(order) do
        local categoryKey = category
        local row = CreateFrame("Frame", nil, assignDialog)
        row:SetHeight(32)
        row:SetPoint("TOPLEFT", 12, -81 - (index - 1) * 32)
        row:SetPoint("TOPRIGHT", -12, -81 - (index - 1) * 32)
        row.label = makeText(row, 12, C.textLight)
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetText(S.CATEGORIES[category])
        row.picker = makeButton(row, S.NONE, 220)
        row.picker:SetPoint("RIGHT", -88, 0)
        row.clear = makeButton(row, S.CLEAR, 76)
        row.clear:SetPoint("RIGHT", -4, 0)
        row.picker:SetScript("OnClick", function()
            local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
            local list = LuckyLoadouts.Loadouts:Read(specID)
            if not list then return end
            showLoadoutPicker(row.picker, list, function(entry)
                LuckyLoadouts.Reminders:SetCategory(specID, categoryKey, entry.id)
                setStatus(assignStatus, string.format(S.ASSIGNED, entry.name, S.CATEGORIES[categoryKey]), false)
                SettingsUI:RefreshAssignments()
            end)
        end)
        row.clear:SetScript("OnClick", function()
            local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
            LuckyLoadouts.Reminders:SetCategory(specID, categoryKey, nil)
            setStatus(assignStatus, string.format(S.CLEARED, S.CATEGORIES[categoryKey]), false)
            SettingsUI:RefreshAssignments()
        end)
        assignCategoryRows[categoryKey] = row
    end

    assignCurrentButton = makeButton(assignDialog, S.USE_CURRENT_INSTANCE, 180)
    assignCurrentButton:SetPoint("TOPLEFT", 16, -281)
    assignCurrentButton:SetScript("OnClick", function()
        local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
        local list = LuckyLoadouts.Loadouts:Read(specID)
        if not list then return end
        showLoadoutPicker(assignCurrentButton, list, function(entry)
            local ok, err = LuckyLoadouts.Reminders:SetCurrentInstance(specID, entry.id)
            setStatus(assignStatus, ok and string.format(S.ASSIGNED, entry.name, S.INSTANCE_OVERRIDES) or err, not ok)
            SettingsUI:RefreshAssignments()
        end)
    end)

    local instanceHeader = makeText(assignDialog, 10, C.goldPrimary)
    instanceHeader:SetPoint("TOPLEFT", 16, -319)
    instanceHeader:SetText(S.INSTANCE_OVERRIDES)

    local scroll = CreateFrame("ScrollFrame", nil, assignDialog, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -335)
    scroll:SetPoint("BOTTOMRIGHT", -34, DIALOG_PAD)
    assignInstanceInner = CreateFrame("Frame", nil, scroll)
    assignInstanceInner:SetSize(530, 1)
    scroll:SetScrollChild(assignInstanceInner)

    assignDialog:ClearAllPoints()
    assignDialog:SetPoint("TOPLEFT", manager, "TOPRIGHT", 6, 0)
end

local function acquireInstanceRow(index)
    local row = assignInstanceRows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, assignInstanceInner)
    row:SetHeight(38)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 38)
    row:SetPoint("TOPRIGHT")
    row.label = makeText(row, 12, C.textLight)
    row.label:SetPoint("LEFT", 4, 7)
    row.picker = makeButton(row, S.NONE, 220)
    row.picker:SetPoint("RIGHT", -86, 0)
    row.remove = makeButton(row, S.REMOVE, 76)
    row.remove:SetPoint("RIGHT", -4, 0)
    assignInstanceRows[index] = row
    return row
end

function showAssignments()
    setStatus(assignStatus, "", false)
    assignDialog:Show()
    SettingsUI:RefreshAssignments()
end

local REMINDER_WIDTH = 380
local REMINDER_TEXT_TOP = CONTENT_TOP
local REMINDER_LINE_GAP = 6

-- Grow to the wrapped text, so a short reminder has no gap above the buttons.
local function fitReminder()
    local status = reminderStatus:GetText()
    local statusHeight = (status and status ~= "") and (REMINDER_LINE_GAP + reminderStatus:GetStringHeight()) or 0
    reminder:SetHeight(REMINDER_TEXT_TOP + reminderText:GetStringHeight() + statusHeight
        + DIALOG_PAD + BUTTON_HEIGHT + DIALOG_PAD)
end

local function setReminderStatus(message, errorState)
    setStatus(reminderStatus, message, errorState)
    fitReminder()
end

local function createReminder()
    reminder = makeSurface("LuckyLoadoutsReminder", REMINDER_WIDTH, 140, "reminder", S.REMINDER_TITLE)
    reminderText = makeText(reminder, 13, C.textLight)
    reminderText:SetPoint("TOPLEFT", DIALOG_PAD, -REMINDER_TEXT_TOP)
    reminderText:SetPoint("RIGHT", -DIALOG_PAD, 0)
    reminderText:SetJustifyH("LEFT")
    reminderStatus = makeText(reminder, 11, C.textMuted)
    reminderStatus:SetPoint("TOPLEFT", reminderText, "BOTTOMLEFT", 0, -REMINDER_LINE_GAP)
    reminderStatus:SetPoint("RIGHT", -DIALOG_PAD, 0)
    reminderStatus:SetJustifyH("LEFT")

    local dismiss = makeButton(reminder, S.DISMISS, 90)
    reminderSwitch = makeButton(reminder, S.SWITCH, 90, "primary")
    placeButtonPair(reminder, reminderSwitch, dismiss)
    reminderApply = makeButton(reminder, S.APPLY, 90, "primary")
    reminderApply:SetAllPoints(reminderSwitch)
    reminderApply:Hide()
    dismiss:SetScript("OnClick", function() LuckyLoadouts.Reminders:Dismiss() end)
    reminderSwitch:SetScript("OnClick", function()
        if reminderMatch then LuckyLoadouts.Loadouts:RequestSwitch(reminderMatch.configID, "reminder") end
    end)
    reminderApply:SetScript("OnClick", function()
        local ok, err = LuckyLoadouts.Loadouts:ApplyPending()
        if not ok then setReminderStatus(err, true) end
    end)
end

function SettingsUI:Init(accountDB, characterDB)
    S = LuckyLoadouts.Strings
    db = accountDB
    charDB = characterDB
    createManager()
    EventUtil.ContinueOnAddOnLoaded("Blizzard_PlayerSpells", attachToTalents)
    createRenameDialog()
    createAssignmentDialog()
    createReminder()

    settingsPanel = LuckySettings:NewRichPanel(S.ADDON_NAME, {
        addonFolder = "Luckys_Loadouts",
        db = db,
        showAbout = true,
        devMode = {
            checked = function() return db.devMode end,
            onToggle = function(value) db.devMode = value end,
        },
        minimapButton = {
            checked = function() return not db.minimap.hide end,
            onToggle = function(value)
                if minimapButton then minimapButton:SetShown_Persisted(value) end
            end,
        },
    }, function(panel)
        panel:Group(S.SETTINGS_GENERAL, function(group)
            group:Button({ label = S.OPEN_MANAGER, desc = S.OPEN_MANAGER_DESC,
                onClick = function() SettingsUI:OpenManager() end })
        end)
    end)

    LuckyLoadouts.Loadouts:AddListener(function(kind, message)
        if kind == "renamed" then renameDialog:Hide() end
        if message then
            setStatus(managerStatus, message, kind == "switchFailed" or kind == "renameFailed" or kind == "deleteFailed")
            if reminder:IsShown() then
                setReminderStatus(message, kind == "switchFailed")
            end
        end
        if kind == "applyRequired" then
            managerApply:Show()
            reminderSwitch:Hide()
            reminderApply:Show()
        elseif kind == "switched" or kind == "switchFailed" then
            managerApply:Hide()
            reminderApply:Hide()
            reminderSwitch:Show()
        end
        if reminder:IsShown() and reminderMatch then
            reminderSwitch:SetEnabled(not LuckyLoadouts.Loadouts:GetSwitchBlocker(reminderMatch.configID))
        end
        SettingsUI:RefreshManager()
        if assignDialog:IsShown() then SettingsUI:RefreshAssignments() end
    end)
end

function SettingsUI:SetMinimapButton(button)
    minimapButton = button
end

function SettingsUI:OpenSettings()
    settingsPanel:Open()
end

function SettingsUI:OpenManager()
    if PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab then
        PlayerSpellsUtil.OpenToClassTalentsTab()
    elseif not manager:IsShown() then
        manager:Show()
    end
    self:RefreshManager()
end

-- Wrap the rows, capped at the talents window's height when docked to it.
local function fitManager(contentHeight)
    local chrome = MANAGER_BAR_HEIGHT + MANAGER_HINT_HEIGHT + MANAGER_FOOTER_HEIGHT
    local docked = PlayerSpellsFrame and manager:GetParent() == PlayerSpellsFrame
    local maxHeight = docked and (PlayerSpellsFrame:GetHeight() - MANAGER_TALENTS_TOP_OFFSET)
        or MANAGER_STANDALONE_MAX_HEIGHT
    local listHeight = math.min(contentHeight, maxHeight - chrome)
    manager:SetHeight(chrome + listHeight)

    local scrollable = contentHeight > listHeight
    local gutter = scrollable and SCROLLBAR_GUTTER or 0
    managerScroll.ScrollBar:SetShown(scrollable)
    managerScroll:SetPoint("BOTTOMRIGHT", -1 - gutter, MANAGER_FOOTER_HEIGHT)
    managerInner:SetSize(MANAGER_WIDTH - 2 - gutter, math.max(contentHeight, 1))
end

local SITUATION_ORDER = { "Raid", "Dungeon", "Delve", "OpenWorld", "Battleground", "Arena" }

-- Each loadout's assigned categories, then its instance overrides by name.
local function situationsByConfig(specID)
    local data = LuckyLoadouts.GetSpecAssignments(charDB, specID)
    local situations = {}
    local function add(configID, label)
        situations[configID] = situations[configID] or {}
        table.insert(situations[configID], label)
    end
    for _, category in ipairs(SITUATION_ORDER) do
        local configID = data.categories[category]
        if configID then add(configID, S.SITUATIONS[category]) end
    end
    local instances = {}
    for instanceID, entry in pairs(data.instances) do
        if entry.configID then
            instances[#instances + 1] = { configID = entry.configID, label = entry.label or tostring(instanceID) }
        end
    end
    table.sort(instances, function(a, b) return a.label < b.label end)
    for _, instance in ipairs(instances) do add(instance.configID, instance.label) end
    return situations
end

function SettingsUI:RefreshManager()
    if not manager then return end
    local list, err, _, selectedID = LuckyLoadouts.Loadouts:Read()
    if not list then
        emptyText:SetText(err)
        emptyText:Show()
        for _, row in ipairs(managerRows) do row:Hide() end
        fitManager(MANAGER_EMPTY_HEIGHT)
        return
    end
    emptyText:SetText(#list == 0 and S.EMPTY or "")
    emptyText:SetShown(#list == 0)
    if #list > 0 and not selectedID and not LuckyLoadouts.Loadouts:GetPending() then
        setStatus(managerStatus, S.NO_SAVED_SELECTED, false)
    end
    local situations = situationsByConfig(LuckyLoadouts.Loadouts:GetCurrentSpec())
    for index, entry in ipairs(list) do
        local rowEntry = entry
        local row = acquireManagerRow(index)
        row:Show()
        row.name:SetText(rowEntry.name)
        row.highlight:SetShown(rowEntry.selected)
        row.marker:SetShown(rowEntry.selected)
        setTextColor(row.name, rowEntry.selected and C.goldPrimary or C.textLight)
        local blocker = rowEntry.selected and S.SWITCH_NO_CHANGE or LuckyLoadouts.Loadouts:GetSwitchBlocker(rowEntry.id)
        local labels = situations[rowEntry.id]
        row.state:SetText(labels and table.concat(labels, ", ") or S.NO_SITUATION)
        row:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                showRowMenu(row, rowEntry)
            elseif not blocker then
                LuckyLoadouts.Loadouts:RequestSwitch(rowEntry.id, "manager")
            end
        end)
        row.rename:SetScript("OnClick", function() showRename(rowEntry) end)
    end
    for index = #list + 1, #managerRows do managerRows[index]:Hide() end
    fitManager(#list == 0 and MANAGER_EMPTY_HEIGHT or #list * MANAGER_ROW_HEIGHT)
end

function SettingsUI:RefreshAssignments()
    self:RefreshManager()
    if not assignDialog:IsShown() then return end
    local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
    local list, _, byID = LuckyLoadouts.Loadouts:Read(specID)
    if not list then return end
    local data = LuckyLoadouts.GetSpecAssignments(charDB, specID)
    local snapshot = LuckyLoadouts.Reminders:GetLatestSnapshot()
    assignCurrentButton:SetShown(snapshot ~= nil
        and (snapshot.category == "Dungeon" or snapshot.category == "Raid"))
    for category, row in pairs(assignCategoryRows) do
        row.picker:SetText(assignedName(data.categories[category], byID))
    end
    local entries = {}
    for instanceID, entry in pairs(data.instances) do
        entries[#entries + 1] = { instanceID = instanceID, entry = entry }
    end
    table.sort(entries, function(a, b)
        return tostring(a.entry.label or a.instanceID) < tostring(b.entry.label or b.instanceID)
    end)
    for index, item in ipairs(entries) do
        local instanceID = item.instanceID
        local row = acquireInstanceRow(index)
        row:Show()
        row.label:SetText(item.entry.label or tostring(item.instanceID))
        row.picker:SetText(assignedName(item.entry.configID, byID))
        row.picker:SetScript("OnClick", function()
            showLoadoutPicker(row.picker, list, function(entry)
                LuckyLoadouts.Reminders:SetInstance(specID, instanceID, entry.id)
                setStatus(assignStatus, string.format(S.ASSIGNED, entry.name, item.entry.label or tostring(instanceID)), false)
                SettingsUI:RefreshAssignments()
            end)
        end)
        row.remove:SetScript("OnClick", function()
            LuckyLoadouts.Reminders:RemoveInstance(specID, instanceID)
            SettingsUI:RefreshAssignments()
        end)
    end
    for index = #entries + 1, #assignInstanceRows do assignInstanceRows[index]:Hide() end
    assignInstanceInner:SetHeight(math.max(#entries * 38, 1))
end

function SettingsUI:ShowReminder(match, snapshot)
    reminderMatch = match
    local accent = LuckyUI.C.goldPrimary
    local loadoutName = CreateColor(accent[1], accent[2], accent[3]):WrapTextInColorCode(match.target.name)
    reminderText:SetText(string.format(S.REMINDER_TEXT, match.label or snapshot.label, loadoutName))
    local blocker = LuckyLoadouts.Loadouts:GetSwitchBlocker(match.configID)
    setReminderStatus(blocker or "", blocker ~= nil)
    reminderSwitch:SetEnabled(not blocker)
    reminderSwitch:Show()
    reminderApply:Hide()
    reminder:Show()
end

function SettingsUI:HideReminder()
    if reminder then reminder:Hide() end
end

function SettingsUI:SetReminderCombat(inCombat)
    if not reminder or not reminder:IsShown() or not reminderMatch then return end
    local blocker = inCombat and S.IN_COMBAT or LuckyLoadouts.Loadouts:GetSwitchBlocker(reminderMatch.configID)
    reminderSwitch:SetEnabled(not blocker)
    setReminderStatus(blocker or "", blocker ~= nil)
end
