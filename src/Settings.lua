-- luacheck: globals LuckyLoadouts PlayerSpellsFrame PlayerSpellsUtil EventUtil C_Timer

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
local managerQuickDelete
local managerHint
local quickDeleteMode = false
local dragRow
local dropLine
local renameDialog
local renameTitle
local renamePrompt
local renameSave
local renameEdit
local renameStatus
local renameTarget
local assignDialog
local assignStatus
local assignCategoryRows = {}
local giveUpRow
local reminder
local reminderText
local reminderStatus
local reminderSwitch
local reminderApply
local reminderMatch
local reminderChoices
local reminderChoiceRows = {}
local reminderRowCount = 0
-- What the reminder's main button does and what blocks it, per step.
local reminderAction
local reminderSwitchBlocker = function() return nil end
local reminderNote
local settingsPanel
local minimapButton
local showRename
local showCreate
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

local function makeIconButton(parent, iconName, tooltip, size, color)
    return LuckyUI.CreateIconButton(parent, {
        icon = iconName,
        size = size or 20,
        tooltip = tooltip,
        color = color,
    })
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
local MANAGER_TALENTS_TOP_OFFSET = 0
local SCROLLBAR_GUTTER = 22
local managerScroll

local function setQuickDeleteMode(enabled)
    quickDeleteMode = enabled
    managerHint:SetText(enabled and S.QUICK_DELETE_HINT or S.SWITCH_HINT)
    managerAssign:SetEnabled(not enabled)
    managerNew:SetEnabled(not enabled)
    local pending = LuckyLoadouts.Loadouts:GetPending()
    managerApply:SetShown(not enabled and pending and pending.state == "applyRequired")
    SettingsUI:RefreshManager()
end

local function createManager()
    local managerBar
    manager, managerBar = makeSurface("LuckyLoadoutsManager", MANAGER_WIDTH, MANAGER_STANDALONE_MAX_HEIGHT,
        "manager", S.MANAGER_TITLE)
    manager.bar = managerBar

    managerAssign = makeIconButton(managerBar, "target", S.ASSIGN_TOOLTIP, 16)
    managerAssign:SetPoint("RIGHT", managerBar, "RIGHT", -34, 0)
    managerAssign:SetScript("OnClick", function()
        if assignDialog:IsShown() then assignDialog:Hide() else showAssignments() end
    end)
    managerNew = makeIconButton(managerBar, "plus", S.NEW_TOOLTIP, 16)
    managerNew:SetPoint("RIGHT", managerAssign, "LEFT", -4, 0)
    managerNew:SetScript("OnClick", function()
        if not db.autoNameNewLoadouts then
            showCreate()
            return
        end
        local ok, err = LuckyLoadouts.Loadouts:Create(S.NEW_LOADOUT_NAME)
        if not ok then setStatus(managerStatus, err, true) end
    end)
    managerQuickDelete = makeIconButton(managerBar, "trash", S.QUICK_DELETE, 16, C.danger)
    managerQuickDelete:SetPoint("RIGHT", managerNew, "LEFT", -4, 0)
    managerQuickDelete:SetScript("OnClick", function() setQuickDeleteMode(not quickDeleteMode) end)

    local header = CreateFrame("Frame", nil, manager)
    header:SetHeight(MANAGER_HINT_HEIGHT)
    header:SetPoint("TOPLEFT", 1, -MANAGER_BAR_HEIGHT)
    header:SetPoint("TOPRIGHT", -1, -MANAGER_BAR_HEIGHT)
    LuckySettings.Rich.FillBg(header, C.bgInput)

    managerHint = makeText(header, 10, C.textMuted)
    managerHint:SetPoint("LEFT", 10, 0)
    managerHint:SetPoint("RIGHT", -10, 0)
    managerHint:SetJustifyH("LEFT")
    managerHint:SetText(S.SWITCH_HINT)

    managerScroll = CreateFrame("ScrollFrame", nil, manager, "UIPanelScrollFrameTemplate")
    managerScroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    managerScroll:SetPoint("BOTTOMRIGHT", -1, MANAGER_FOOTER_HEIGHT)
    managerInner = CreateFrame("Frame", nil, managerScroll)
    managerInner:SetSize(MANAGER_WIDTH - 2, 1)
    managerScroll:SetScrollChild(managerInner)

    dropLine = managerInner:CreateTexture(nil, "OVERLAY")
    dropLine:SetHeight(2)
    dropLine:SetColorTexture(C.goldPrimary[1], C.goldPrimary[2], C.goldPrimary[3], 1)
    dropLine:Hide()

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
    manager:SetScript("OnHide", function()
        if quickDeleteMode then setQuickDeleteMode(false) end
    end)
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

-- The gap between rows the cursor is nearest, 1 being above the first row.
local function dropSlot()
    local _, cursorY = GetCursorPosition()
    local offset = managerInner:GetTop() - cursorY / managerInner:GetEffectiveScale()
    local slot = math.floor(offset / MANAGER_ROW_HEIGHT + 0.5) + 1
    return math.max(1, math.min(slot, dragRow.count + 1))
end

local function placeDropLine()
    local y = math.min((dropSlot() - 1) * MANAGER_ROW_HEIGHT, dragRow.count * MANAGER_ROW_HEIGHT - 2)
    dropLine:SetPoint("TOPLEFT", 0, -y)
    dropLine:SetPoint("TOPRIGHT", 0, -y)
end

local function startDrag(row)
    if quickDeleteMode then return end
    row.dragged = true
    dragRow = row
    row:SetAlpha(0.5)
    placeDropLine()
    dropLine:Show()
    managerInner:SetScript("OnUpdate", placeDropLine)
end

local function stopDrag(row)
    if dragRow ~= row then return end
    local slot = dropSlot()
    dragRow = nil
    row:SetAlpha(1)
    dropLine:Hide()
    managerInner:SetScript("OnUpdate", nil)
    local target = slot > row.index and slot - 1 or slot
    if target == row.index then return end
    local ok, err = LuckyLoadouts.Loadouts:Move(row.entry.id, target)
    if not ok and err then setStatus(managerStatus, err, true) end
end

local function acquireManagerRow(index)
    local row = managerRows[index]
    if row then return row end
    row = CreateFrame("Button", nil, managerInner)
    row:SetHeight(MANAGER_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * MANAGER_ROW_HEIGHT)
    row:SetPoint("TOPRIGHT")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:RegisterForDrag("LeftButton")
    -- Guards against OnClick on release after a drag, so a drop never switches loadouts.
    row:SetScript("OnMouseDown", function() row.dragged = false end)
    row:SetScript("OnDragStart", startDrag)
    row:SetScript("OnDragStop", stopDrag)
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
    row.delete = makeIconButton(row, "trash", S.DELETE, 14, C.danger)
    row.delete:SetPoint("RIGHT", -8, 0)
    row.delete:Hide()
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
    renameDialog, titleBar, renameTitle = makeSurface("LuckyLoadoutsRenameDialog", 360, 163, "manager", S.RENAME_TITLE)
    renameDialog:SetMovable(false)
    titleBar:SetScript("OnDragStart", nil)
    titleBar:SetScript("OnDragStop", nil)

    renamePrompt = makeText(renameDialog, 12, C.textLight)
    renamePrompt:SetPoint("TOPLEFT", DIALOG_PAD, -CONTENT_TOP)
    renamePrompt:SetText(S.RENAME_PROMPT)

    renameEdit = LuckyUI.CreateInput(renameDialog, { width = 360 - DIALOG_PAD * 2, height = BUTTON_HEIGHT })
    renameEdit:SetPoint("TOPLEFT", renamePrompt, "BOTTOMLEFT", 0, -6)

    renameStatus = makeText(renameDialog, 10, C.danger)
    renameStatus:SetPoint("TOPLEFT", renameEdit, "BOTTOMLEFT", 0, -5)
    renameStatus:SetPoint("RIGHT", -DIALOG_PAD, 0)
    renameStatus:SetJustifyH("LEFT")

    renameSave = makeButton(renameDialog, S.SAVE, 90, "primary")
    local cancel = makeButton(renameDialog, S.CANCEL, 90)
    placeButtonPair(renameDialog, renameSave, cancel)
    cancel:SetScript("OnClick", function() renameDialog:Hide() end)
    renameSave:SetScript("OnClick", function()
        local ok, err
        if renameTarget then
            ok, err = LuckyLoadouts.Loadouts:Rename(renameTarget, renameEdit:GetText())
        else
            ok, err = LuckyLoadouts.Loadouts:Create(renameEdit:GetText())
        end
        if not ok then setStatus(renameStatus, err, true) else setStatus(renameStatus, S.LOADING, false) end
    end)
    renameEdit:SetScript("OnEnterPressed", function() renameSave:Click() end)
    renameEdit:SetScript("OnEscapePressed", function() renameDialog:Hide() end)
end

function showRename(entry)
    renameTarget = entry.id
    renameTitle:SetText(S.RENAME_TITLE)
    renamePrompt:SetText(S.RENAME_PROMPT)
    renameSave:SetText(S.SAVE)
    renameEdit:SetText(entry.name)
    renameEdit:HighlightText()
    setStatus(renameStatus, "", false)
    renameDialog:Show()
    renameEdit:SetFocus()
end

function showCreate()
    renameTarget = nil
    renameTitle:SetText(S.CREATE_TITLE)
    renamePrompt:SetText(S.CREATE_PROMPT)
    renameSave:SetText(S.CREATE)
    renameEdit:SetText(S.NEW_LOADOUT_NAME)
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

local ASSIGN_WIDTH = 500
local ASSIGN_MAX_HEIGHT = 640
local ASSIGN_PICKER_WIDTH = 190
-- The scroll area starts below the status line; offsets after this are inside it.
local ASSIGN_SCROLL_TOP = 60
local ASSIGN_CONTENT_WIDTH = ASSIGN_WIDTH - 2 - SCROLLBAR_GUTTER
local ASSIGN_ROW_HEIGHT = 32
local CATEGORY_HEADER_TOP = 9
local CATEGORY_ROWS_TOP = 21
local CATEGORY_ORDER = { "Raid", "Dungeon", "Delve", "OpenWorld", "Battleground", "Arena" }
local SECTION_GAP = 12
local HEADER_TO_CONTENT = 16
local GIVE_UP_HEADER_TOP = CATEGORY_ROWS_TOP + #CATEGORY_ORDER * ASSIGN_ROW_HEIGHT + SECTION_GAP
local GIVE_UP_ROW_TOP = GIVE_UP_HEADER_TOP + HEADER_TO_CONTENT
local GIVE_UP_ICON_SIZE = 20
local GIVE_UP_ICON_GAP = 4
local DUNGEON_HEADER_TOP = GIVE_UP_ROW_TOP + ASSIGN_ROW_HEIGHT + SECTION_GAP
local TILES_TOP = DUNGEON_HEADER_TOP + HEADER_TO_CONTENT
local TILES_PER_ROW = 4
local TILE_GAP = 8
local TILE_WIDTH = (ASSIGN_CONTENT_WIDTH - DIALOG_PAD * 2 - TILE_GAP * (TILES_PER_ROW - 1)) / TILES_PER_ROW
local TILE_HEIGHT = 58
local TILE_ICON_SIZE = 16
local TILE_ICONS_MAX = 4
-- The Adventure Guide draws only this corner of its instance art.
local EJ_ART_COORDS = { 0, 0.68359375, 0, 0.7421875 }
-- A boss portrait is 2:1, a little wider than a tile, so its sides are trimmed.
local PORTRAIT_COORDS = { 0.04, 0.96, 0, 1 }
local assignScroll
local assignContent
local raidHeaders = {}
local tiles = {}

local function reportAssignment(loadout, name)
    local message = loadout and string.format(S.ASSIGNED, loadout.name, name) or string.format(S.CLEARED, name)
    setStatus(assignStatus, message, false)
    SettingsUI:RefreshAssignments()
end

local function makeSectionHeader(text, top)
    local header = makeText(assignContent, 10, C.goldPrimary)
    header:SetPoint("TOPLEFT", 16, -top)
    header:SetText(text)
    return header
end

-- The owner sets row.assign(specID, loadout), with a nil loadout to clear.
local function createAssignRow(top, height)
    local row = CreateFrame("Frame", nil, assignContent)
    row:SetHeight(height)
    row:SetPoint("TOPLEFT", 12, -top)
    row:SetPoint("TOPRIGHT", -12, -top)
    row.clear = makeIconButton(row, "eraser", S.CLEAR, 16)
    row.clear:SetPoint("RIGHT", -4, 0)
    row.edit = makeIconButton(row, "square-pen", S.EDIT, 16)
    row.edit:SetPoint("RIGHT", -24, 0)
    row.picker = makeButton(row, S.NONE, ASSIGN_PICKER_WIDTH)
    row.picker:SetPoint("RIGHT", row.edit, "LEFT", -6, 0)
    row.label = makeText(row, 12, C.textLight)
    row.label:SetPoint("LEFT", 4, 0)
    row.label:SetPoint("RIGHT", row.picker, "LEFT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    local function pickLoadout(owner)
        local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
        local list = LuckyLoadouts.Loadouts:Read(specID)
        if not list then return end
        showLoadoutPicker(owner, list, function(loadout) row.assign(specID, loadout) end)
    end
    row.picker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.picker:SetScript("OnClick", pickLoadout)
    row.edit:SetScript("OnClick", pickLoadout)
    row.clear:SetScript("OnClick", function() row.assign(LuckyLoadouts.Loadouts:GetCurrentSpec(), nil) end)
    return row
end

local function talentText(talent)
    local Talents = LuckyLoadouts.Talents
    return "|T" .. (Talents.Icon(talent) or 134400) .. ":16|t " .. Talents.SpellName(talent)
end

local function talentNames(talents)
    local names = {}
    for index, talent in ipairs(talents) do names[index] = LuckyLoadouts.Talents.SpellName(talent) end
    return table.concat(names, ", ")
end

-- The Assign window covers the talent tree, so it steps aside while picking.
local function pickTalents(mode, title, getList)
    local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
    if not specID then return end
    assignDialog:Hide()
    LuckyLoadouts.Talents.StartPick(mode, title,
        function() return getList(specID) end,
        function() LuckyLoadouts.Reminders:AssignmentChanged(specID) end,
        function()
            -- Closing the Talents window also ends picking; wait to see if it did.
            C_Timer.After(0, function()
                if manager:IsVisible() then showAssignments() end
            end)
        end)
end

local function showTilePicker(tile)
    local specID = LuckyLoadouts.Loadouts:GetCurrentSpec()
    local list = LuckyLoadouts.Loadouts:Read(specID)
    if not list then return end
    MenuUtil.CreateContextMenu(tile, function(_, rootDescription)
        rootDescription:CreateTitle(tile.title)
        for _, loadout in ipairs(list) do
            rootDescription:CreateButton(loadout.name, function() tile.assign(specID, loadout) end)
        end
        rootDescription:CreateDivider()
        rootDescription:CreateButton(S.CLEAR, function() tile.assign(specID, nil) end)
        rootDescription:CreateDivider()
        rootDescription:CreateButton(S.TALENT_REMINDERS, function() pickTalents("take", tile.title, tile.talentList) end)
    end)
end

local function showTileTooltip(tile)
    GameTooltip:SetOwner(tile, "ANCHOR_TOP")
    GameTooltip:SetText(tile.title)
    for _, talent in ipairs(tile.talents or {}) do GameTooltip:AddLine(talentText(talent), 1, 1, 1) end
    GameTooltip:Show()
end

local function placeTileIcons(tile, talents)
    local shown = 0
    for _, talent in ipairs(talents or {}) do
        if shown == TILE_ICONS_MAX then break end
        shown = shown + 1
        local icon = tile.icons[shown] or tile:CreateTexture(nil, "OVERLAY")
        tile.icons[shown] = icon
        icon:SetSize(TILE_ICON_SIZE, TILE_ICON_SIZE)
        icon:SetPoint("TOPRIGHT", -3 - (shown - 1) * (TILE_ICON_SIZE + 2), -3)
        icon:SetTexture(LuckyLoadouts.Talents.Icon(talent) or 134400)
        icon:Show()
    end
    for index = shown + 1, #tile.icons do tile.icons[index]:Hide() end
end

-- The owner sets tile.title, tile.talentList(specID) and tile.assign(specID, loadout),
-- a nil loadout clearing.
local function createTile()
    local tile = CreateFrame("Button", nil, assignContent, "BackdropTemplate")
    tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
    tile:SetBackdrop(LuckyUI.Backdrop)
    tile:SetBackdropColor(C.bgInput[1], C.bgInput[2], C.bgInput[3], C.bgInput[4])
    tile.art = tile:CreateTexture(nil, "ARTWORK")
    tile.art:SetPoint("TOPLEFT", 1, -1)
    tile.art:SetPoint("BOTTOMRIGHT", -1, 1)
    tile.art:SetTexCoord(unpack(EJ_ART_COORDS))
    tile.portrait = tile:CreateTexture(nil, "ARTWORK", nil, 1)
    tile.portrait:SetAllPoints(tile.art)
    tile.portrait:SetTexCoord(unpack(PORTRAIT_COORDS))
    local shade = tile:CreateTexture(nil, "ARTWORK", nil, 2)
    shade:SetPoint("BOTTOMLEFT", 1, 1)
    shade:SetPoint("BOTTOMRIGHT", -1, 1)
    shade:SetHeight(28)
    shade:SetColorTexture(0, 0, 0, 0.75)
    tile.loadout = makeText(tile, 10, C.goldPrimary)
    tile.loadout:SetPoint("BOTTOMLEFT", 5, 4)
    tile.loadout:SetPoint("BOTTOMRIGHT", -5, 4)
    tile.loadout:SetJustifyH("LEFT")
    tile.loadout:SetWordWrap(false)
    tile.name = makeText(tile, 10, C.textLight)
    tile.name:SetPoint("BOTTOMLEFT", tile.loadout, "TOPLEFT", 0, 2)
    tile.name:SetPoint("BOTTOMRIGHT", tile.loadout, "TOPRIGHT", 0, 2)
    tile.name:SetJustifyH("LEFT")
    tile.name:SetWordWrap(false)
    tile.icons = {}
    local hover = tile:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(tile.art)
    hover:SetColorTexture(1, 1, 1, 0.1)
    tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tile:SetScript("OnClick", showTilePicker)
    tile:SetScript("OnEnter", showTileTooltip)
    tile:SetScript("OnLeave", GameTooltip_Hide)
    return tile
end

local giveUpDrag

-- The gap between give-up icons the cursor is nearest, 1 being before the first.
local function giveUpSlot()
    local offset = GetCursorPosition() / giveUpRow:GetEffectiveScale() - giveUpRow:GetLeft()
    local slot = math.floor(offset / (GIVE_UP_ICON_SIZE + GIVE_UP_ICON_GAP) + 0.5) + 1
    return math.max(1, math.min(slot, #giveUpRow.talents + 1))
end

local function placeGiveUpDropLine()
    local x = (giveUpSlot() - 1) * (GIVE_UP_ICON_SIZE + GIVE_UP_ICON_GAP) - GIVE_UP_ICON_GAP / 2 - 1
    giveUpRow.dropLine:SetPoint("LEFT", x, 0)
end

local function startGiveUpDrag(icon)
    giveUpDrag = icon
    icon:SetAlpha(0.5)
    GameTooltip_Hide()
    placeGiveUpDropLine()
    giveUpRow.dropLine:Show()
    giveUpRow:SetScript("OnUpdate", placeGiveUpDropLine)
end

local function stopGiveUpDrag(icon)
    if giveUpDrag ~= icon then return end
    local slot = giveUpSlot()
    giveUpDrag = nil
    icon:SetAlpha(1)
    giveUpRow.dropLine:Hide()
    giveUpRow:SetScript("OnUpdate", nil)
    local target = slot > icon.index and slot - 1 or slot
    if target == icon.index then return end
    local list = giveUpRow.talents
    table.insert(list, target, table.remove(list, icon.index))
    LuckyLoadouts.Reminders:AssignmentChanged(LuckyLoadouts.Loadouts:GetCurrentSpec())
    SettingsUI:RefreshAssignments()
end

local function showGiveUpTooltip(icon)
    if giveUpDrag then return end
    local talent = giveUpRow.talents[icon.index]
    GameTooltip:SetOwner(icon, "ANCHOR_TOP")
    if talent.spellID then
        GameTooltip:SetSpellByID(talent.spellID)
    else
        GameTooltip:SetText(LuckyLoadouts.Talents.SpellName(talent))
    end
    GameTooltip:AddLine(string.format(S.GIVE_UP_PRIORITY, icon.index), C.goldPrimary[1], C.goldPrimary[2], C.goldPrimary[3])
    GameTooltip:Show()
end

local function acquireGiveUpIcon(index)
    local icon = giveUpRow.icons[index]
    if icon then return icon end
    icon = CreateFrame("Button", nil, giveUpRow)
    icon:SetSize(GIVE_UP_ICON_SIZE, GIVE_UP_ICON_SIZE)
    icon:SetPoint("LEFT", (index - 1) * (GIVE_UP_ICON_SIZE + GIVE_UP_ICON_GAP), 0)
    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints()
    icon.index = index
    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnDragStart", startGiveUpDrag)
    icon:SetScript("OnDragStop", stopGiveUpDrag)
    icon:SetScript("OnEnter", showGiveUpTooltip)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    giveUpRow.icons[index] = icon
    return icon
end

local function sectionHeight(count)
    return math.ceil(count / TILES_PER_ROW) * (TILE_HEIGHT + TILE_GAP) - TILE_GAP
end

local function createAssignmentDialog()
    local titleBar
    assignDialog, titleBar = makeSurface("LuckyLoadoutsAssignDialog", ASSIGN_WIDTH, 300, "manager", S.ASSIGN_TITLE)
    assignDialog:SetMovable(false)
    titleBar:SetScript("OnDragStart", nil)
    titleBar:SetScript("OnDragStop", nil)

    assignStatus = makeText(assignDialog, 11, C.textMuted)
    assignStatus:SetPoint("TOPLEFT", 16, -41)
    assignStatus:SetPoint("RIGHT", -16, 0)
    assignStatus:SetJustifyH("LEFT")

    assignScroll = CreateFrame("ScrollFrame", nil, assignDialog, "UIPanelScrollFrameTemplate")
    assignScroll:SetPoint("TOPLEFT", 1, -ASSIGN_SCROLL_TOP)
    assignScroll:SetPoint("BOTTOMRIGHT", -1 - SCROLLBAR_GUTTER, 1)
    assignContent = CreateFrame("Frame", nil, assignScroll)
    assignContent:SetSize(ASSIGN_CONTENT_WIDTH, 1)
    assignScroll:SetScrollChild(assignContent)

    makeSectionHeader(S.CATEGORY_DEFAULTS, CATEGORY_HEADER_TOP)
    for index, category in ipairs(CATEGORY_ORDER) do
        local row = createAssignRow(CATEGORY_ROWS_TOP + (index - 1) * ASSIGN_ROW_HEIGHT, ASSIGN_ROW_HEIGHT)
        row.label:SetText(S.CATEGORIES[category])
        row.assign = function(specID, loadout)
            LuckyLoadouts.Reminders:SetCategory(specID, category, loadout and loadout.id)
            reportAssignment(loadout, S.CATEGORIES[category])
        end
        assignCategoryRows[category] = row
    end

    makeSectionHeader(S.GIVE_UP_HEADER, GIVE_UP_HEADER_TOP)
    giveUpRow = CreateFrame("Frame", nil, assignContent)
    giveUpRow:SetHeight(ASSIGN_ROW_HEIGHT)
    giveUpRow:SetPoint("TOPLEFT", 16, -GIVE_UP_ROW_TOP)
    giveUpRow:SetPoint("TOPRIGHT", -16, -GIVE_UP_ROW_TOP)
    giveUpRow.icons = {}
    giveUpRow.edit = makeIconButton(giveUpRow, "square-pen", S.EDIT, 16)
    giveUpRow.edit:SetPoint("RIGHT")
    giveUpRow.edit:SetScript("OnClick", function()
        pickTalents("giveUp", nil, function(specID) return LuckyLoadouts.Reminders:GiveUpList(specID) end)
    end)
    giveUpRow.empty = makeText(giveUpRow, 11, C.textMuted)
    giveUpRow.empty:SetPoint("LEFT")
    giveUpRow.empty:SetText(S.GIVE_UP_EMPTY)
    giveUpRow.dropLine = giveUpRow:CreateTexture(nil, "OVERLAY")
    giveUpRow.dropLine:SetSize(2, GIVE_UP_ICON_SIZE + 6)
    giveUpRow.dropLine:SetColorTexture(C.goldPrimary[1], C.goldPrimary[2], C.goldPrimary[3], 1)
    giveUpRow.dropLine:Hide()

    makeSectionHeader(S.DUNGEONS_HEADER, DUNGEON_HEADER_TOP)

    assignDialog:ClearAllPoints()
    assignDialog:SetPoint("TOPLEFT", manager, "TOPRIGHT", 6, 0)
    -- The manager closes with the Talents window, so its dialogs go with it.
    manager:HookScript("OnHide", function()
        assignDialog:Hide()
        renameDialog:Hide()
    end)
end

function showAssignments()
    setStatus(assignStatus, "", false)
    assignDialog:Show()
    SettingsUI:RefreshAssignments()
end

-- Grow to the content, capped at the Talents window's height when it is open.
local function fitAssignments(contentHeight)
    local talentsShown = PlayerSpellsFrame and PlayerSpellsFrame:IsShown()
    local maxHeight = talentsShown and PlayerSpellsFrame:GetHeight() or ASSIGN_MAX_HEIGHT
    local listHeight = math.min(contentHeight, maxHeight - ASSIGN_SCROLL_TOP - 1)
    assignDialog:SetHeight(ASSIGN_SCROLL_TOP + listHeight + 1)
    assignContent:SetHeight(contentHeight)
    assignScroll.ScrollBar:SetShown(contentHeight > listHeight)
end

-- Dungeon tiles, then each raid's name heading tiles for its bosses. A boss
-- portrait stands on its raid's art, dimmed so the portrait reads first.
local function refreshSeason(data, byID)
    local dungeons, raids = {}, {}
    for _, instance in ipairs(LuckyLoadouts.Journal.Season()) do
        table.insert(instance.category == "Raid" and raids or dungeons, instance)
    end
    -- The season's main raid leads; a one-boss raid is a side stop.
    local journalOrder = {}
    for index, raid in ipairs(raids) do journalOrder[raid] = index end
    table.sort(raids, function(a, b)
        local bossesA = #LuckyLoadouts.Journal.Bosses(a.journalID)
        local bossesB = #LuckyLoadouts.Journal.Bosses(b.journalID)
        if bossesA ~= bossesB then return bossesA > bossesB end
        return journalOrder[a] < journalOrder[b]
    end)

    local used = 0
    local function placeTile(top, slot, art, portrait, title, configID, assign, talents, talentList)
        used = used + 1
        local tile = tiles[used] or createTile()
        tiles[used] = tile
        local column, line = (slot - 1) % TILES_PER_ROW, math.floor((slot - 1) / TILES_PER_ROW)
        tile:SetPoint("TOPLEFT", DIALOG_PAD + column * (TILE_WIDTH + TILE_GAP), -(top + line * (TILE_HEIGHT + TILE_GAP)))
        tile.art:SetTexture(art)
        tile.art:SetAlpha(portrait and 0.35 or 1)
        tile.portrait:SetTexture(portrait)
        tile.portrait:SetShown(portrait ~= nil)
        tile.name:SetText(title)
        tile.loadout:SetText(configID and assignedName(configID, byID) or "")
        local border = configID and C.goldAccent or C.borderDark
        tile:SetBackdropBorderColor(border[1], border[2], border[3])
        tile.title, tile.assign, tile.talents, tile.talentList = title, assign, talents, talentList
        placeTileIcons(tile, talents)
        tile:Show()
    end

    for slot, instance in ipairs(dungeons) do
        local entry = data.instances[instance.id]
        placeTile(TILES_TOP, slot, instance.art, nil, instance.label,
            type(entry) == "table" and entry.configID or nil,
            function(specID, loadout)
                LuckyLoadouts.Reminders:SetInstanceAssignment(specID, instance, nil, loadout and loadout.id)
                reportAssignment(loadout, instance.label)
            end,
            data.talents[instance.id],
            function(specID) return LuckyLoadouts.Reminders:TalentList(specID, instance) end)
    end
    local top = TILES_TOP + sectionHeight(#dungeons)

    for raidIndex, raid in ipairs(raids) do
        top = top + SECTION_GAP
        local header = raidHeaders[raidIndex] or makeSectionHeader("", 0)
        raidHeaders[raidIndex] = header
        header:SetPoint("TOPLEFT", 16, -top)
        header:SetText(raid.label:upper())
        header:Show()
        top = top + HEADER_TO_CONTENT
        local entry = data.instances[raid.id]
        local bossAssignments = type(entry) == "table" and type(entry.bosses) == "table" and entry.bosses or {}
        local bosses = LuckyLoadouts.Journal.Bosses(raid.journalID)
        for slot, boss in ipairs(bosses) do
            local assigned = bossAssignments[boss.encounterID]
            placeTile(top, slot, raid.art, boss.portrait, boss.name,
                type(assigned) == "table" and assigned.configID or nil,
                function(specID, loadout)
                    LuckyLoadouts.Reminders:SetInstanceAssignment(specID, raid, boss, loadout and loadout.id)
                    reportAssignment(loadout, boss.name)
                end,
                data.bossTalents[boss.encounterID],
                function(specID) return LuckyLoadouts.Reminders:TalentList(specID, raid, boss) end)
        end
        top = top + sectionHeight(#bosses)
    end
    for index = #raids + 1, #raidHeaders do raidHeaders[index]:Hide() end
    for index = used + 1, #tiles do tiles[index]:Hide() end
    fitAssignments(top + DIALOG_PAD)
end

local REMINDER_WIDTH = 420
local REMINDER_TEXT_TOP = CONTENT_TOP
local REMINDER_LINE_GAP = 6
local REMINDER_CHOICE_HEIGHT = 28

-- Grow to the wrapped text, so a short reminder has no gap above the buttons.
local function fitReminder()
    local status = reminderStatus:GetText()
    local statusHeight = (status and status ~= "") and (REMINDER_LINE_GAP + reminderStatus:GetStringHeight()) or 0
    local choicesHeight = reminderChoices:IsShown() and (REMINDER_LINE_GAP + reminderChoices:GetHeight()) or 0
    reminder:SetHeight(REMINDER_TEXT_TOP + reminderText:GetStringHeight() + choicesHeight + statusHeight
        + DIALOG_PAD + BUTTON_HEIGHT + DIALOG_PAD)
end

local function reminderChoiceRow(index)
    local row = reminderChoiceRows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, reminderChoices)
    row:SetHeight(REMINDER_CHOICE_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * REMINDER_CHOICE_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -(index - 1) * REMINDER_CHOICE_HEIGHT)
    row.switch = makeButton(row, S.SWITCH, 90, "primary")
    row.switch:SetPoint("RIGHT")
    row.text = makeText(row, 12, C.textLight)
    row.text:SetPoint("LEFT")
    row.text:SetPoint("RIGHT", row.switch, "LEFT", -8, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    reminderChoiceRows[index] = row
    return row
end

-- Each button on the reminder with what would block it.
local function reminderSwitches()
    if not reminderMatch then return {} end
    if reminderRowCount == 0 then return { { button = reminderSwitch, blocker = reminderSwitchBlocker } } end
    local switches = {}
    for index = 1, reminderRowCount do
        local row = reminderChoiceRows[index]
        switches[index] = { button = row.switch, blocker = row.blocker }
    end
    return switches
end

local function updateReminderSwitches(blocker)
    for _, switch in ipairs(reminderSwitches()) do
        switch.button:SetEnabled(not (blocker or switch.blocker()))
    end
end

local function setReminderApplying(applying)
    reminderApply:SetShown(applying)
    for _, switch in ipairs(reminderSwitches()) do switch.button:SetShown(not applying) end
end

local function setReminderStatus(message, errorState)
    setStatus(reminderStatus, message, errorState)
    fitReminder()
end

-- A blocker when there is one, otherwise the step's own note.
local function showReminderBlocker(blocker)
    blocker = blocker or reminderSwitchBlocker()
    setReminderStatus(blocker or reminderNote or "", blocker ~= nil)
end

local function createReminder()
    reminder = makeSurface("LuckyLoadoutsReminder", REMINDER_WIDTH, 140, "reminder", S.REMINDER_TITLE)
    reminder:SetFrameStrata("TOOLTIP")
    reminderText = makeText(reminder, 13, C.textLight)
    reminderText:SetPoint("TOPLEFT", DIALOG_PAD, -REMINDER_TEXT_TOP)
    reminderText:SetPoint("RIGHT", -DIALOG_PAD, 0)
    reminderText:SetJustifyH("LEFT")
    reminderChoices = CreateFrame("Frame", nil, reminder)
    reminderChoices:SetPoint("TOPLEFT", reminderText, "BOTTOMLEFT", 0, -REMINDER_LINE_GAP)
    reminderChoices:SetPoint("RIGHT", -DIALOG_PAD, 0)
    reminderChoices:Hide()
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
        if reminderAction then reminderAction() end
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
            group:Toggle({
                label = S.AUTO_NAME_NEW_LOADOUTS,
                desc = S.AUTO_NAME_NEW_LOADOUTS_DESC,
                checked = function() return db.autoNameNewLoadouts end,
                onToggle = function(value) db.autoNameNewLoadouts = value end,
            })
        end)
    end)

    LuckyLoadouts.Loadouts:AddListener(function(kind, message)
        if kind == "renamed" or kind == "created" then renameDialog:Hide() end
        if message then
            setStatus(managerStatus, message, kind == "switchFailed" or kind == "renameFailed" or kind == "deleteFailed")
            if reminder:IsShown() then
                setReminderStatus(message, kind == "switchFailed")
            end
        end
        if kind == "applyRequired" then
            managerApply:SetShown(not quickDeleteMode)
            setReminderApplying(true)
        elseif kind == "switched" or kind == "switchFailed" then
            managerApply:Hide()
            setReminderApplying(false)
        end
        if kind == "refreshed" then SettingsUI:ReplanReminder() end
        if reminder:IsShown() and reminderMatch then
            updateReminderSwitches()
            if kind == "switchFailed" then
                C_Timer.After(0, function()
                    if reminder:IsShown() and reminderMatch then updateReminderSwitches() end
                end)
            end
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

-- Each loadout's assigned categories, then its instance overrides by name.
local function situationsByConfig(specID)
    local data = LuckyLoadouts.GetSpecAssignments(charDB, specID)
    local situations = {}
    local function add(configID, label)
        situations[configID] = situations[configID] or {}
        table.insert(situations[configID], label)
    end
    for _, category in ipairs(CATEGORY_ORDER) do
        local configID = data.categories[category]
        if configID then add(configID, S.SITUATIONS[category]) end
    end
    local instances = {}
    for instanceID, entry in pairs(data.instances) do
        if entry.configID then
            instances[#instances + 1] = { configID = entry.configID, label = entry.label or tostring(instanceID) }
        end
        for _, boss in pairs(type(entry.bosses) == "table" and entry.bosses or {}) do
            instances[#instances + 1] = { configID = boss.configID, label = boss.label }
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
        row.entry, row.index, row.count = rowEntry, index, #list
        row:Show()
        row.name:SetText(rowEntry.name)
        row.highlight:SetShown(not quickDeleteMode and rowEntry.selected)
        row.marker:SetShown(not quickDeleteMode and rowEntry.selected)
        row.rename:SetShown(not quickDeleteMode)
        row.delete:SetShown(quickDeleteMode)
        row.delete:SetEnabled(true)
        setTextColor(row.name, rowEntry.selected and C.goldPrimary or C.textLight)
        local blocker = not quickDeleteMode
            and (rowEntry.selected and S.SWITCH_NO_CHANGE or LuckyLoadouts.Loadouts:GetSwitchBlocker(rowEntry.id))
        local labels = situations[rowEntry.id]
        row.state:SetText(labels and table.concat(labels, ", ") or S.NO_SITUATION)
        row:SetScript("OnClick", function(_, button)
            if quickDeleteMode or row.dragged then return end
            if button == "RightButton" then
                showRowMenu(row, rowEntry)
            elseif not blocker then
                LuckyLoadouts.Loadouts:RequestSwitch(rowEntry.id, "manager")
            end
        end)
        row.rename:SetScript("OnClick", function() showRename(rowEntry) end)
        row.delete:SetScript("OnClick", function()
            row.delete:SetEnabled(false)
            local ok, deleteErr = LuckyLoadouts.Loadouts:Delete(rowEntry.id)
            row.delete:SetEnabled(not ok)
            if not ok then setStatus(managerStatus, deleteErr, true) end
        end)
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
    for category, row in pairs(assignCategoryRows) do
        row.picker:SetText(assignedName(data.categories[category], byID))
    end
    giveUpRow.talents = data.giveUp
    for index, talent in ipairs(data.giveUp) do
        local icon = acquireGiveUpIcon(index)
        icon.texture:SetTexture(LuckyLoadouts.Talents.Icon(talent) or 134400)
        icon:Show()
    end
    for index = #data.giveUp + 1, #giveUpRow.icons do giveUpRow.icons[index]:Hide() end
    giveUpRow.empty:SetShown(#data.giveUp == 0)
    refreshSeason(data, byID)
end

-- Each row is { text, button, onClick, blocker }.
local function showReminderRows(rows)
    for index, entry in ipairs(rows) do
        local row = reminderChoiceRow(index)
        row.text:SetText(entry.text)
        row.switch:SetText(entry.button)
        row.switch:SetScript("OnClick", entry.onClick)
        row.blocker = entry.blocker
        row:Show()
    end
    for index = #rows + 1, #reminderChoiceRows do reminderChoiceRows[index]:Hide() end
    reminderRowCount = #rows
    reminderChoices:SetHeight(#rows * REMINDER_CHOICE_HEIGHT)
end

local function noBlocker() return nil end

local function swapFailed(message)
    setReminderStatus(message, true)
    updateReminderSwitches()
end

-- The talents on each line under key, one a pair of next bosses share listed once.
local function lineTalents(lines, key)
    local talents, seen = {}, {}
    for _, line in ipairs(lines) do
        for _, talent in ipairs(line[key]) do
            if not seen[talent.nodeID] then
                seen[talent.nodeID] = true
                talents[#talents + 1] = talent
            end
        end
    end
    return talents
end

-- Plan the swap against the talents as they stand now: Swap when it can take
-- anything, otherwise open the tree, and a note of what it gives up or cannot do.
local function planTalentStep(explain)
    local Talents = LuckyLoadouts.Talents
    local missing = lineTalents(reminderMatch.talents, "talents")
    local keep = lineTalents(reminderMatch.talents, "wanted")
    local giveUps = LuckyLoadouts.Reminders:GiveUpList(LuckyLoadouts.Loadouts:GetCurrentSpec())
    local plan = Talents.PlanSwap(missing, giveUps, keep, explain)
    local canSwap = #plan.take > 0
    reminderSwitch:SetText(canSwap and S.SWAP or S.OPEN_TALENTS)
    reminderSwitchBlocker = canSwap and Talents.GetBlocker or noBlocker
    reminderAction = function()
        if not canSwap then
            Talents.PointOut(missing)
            return
        end
        local ok, err = Talents.Swap(missing, giveUps, keep, swapFailed)
        setReminderStatus(ok and S.SWAP_PENDING or err, not ok)
        updateReminderSwitches()
    end
    local notes = { #giveUps == 0 and S.SWAP_NO_LIST or nil }
    if #plan.giveUp > 0 then notes[#notes + 1] = string.format(S.SWAP_GIVES_UP, talentNames(plan.giveUp)) end
    if #plan.blocked > 0 and #giveUps > 0 then notes[#notes + 1] = string.format(S.SWAP_CANNOT, talentNames(plan.blocked)) end
    if #plan.locked > 0 then notes[#notes + 1] = string.format(S.SWAP_LOCKED, talentNames(plan.locked)) end
    reminderNote = table.concat(notes, " ")
end

local function talentLines(lines)
    local labels, rows = {}, {}
    for _, line in ipairs(lines) do labels[#labels + 1] = line.label end
    for _, talent in ipairs(lineTalents(lines, "talents")) do rows[#rows + 1] = talentText(talent) end
    return string.format(S.REMINDER_TALENTS, table.concat(labels, ", ")) .. "\n" .. table.concat(rows, "\n")
end

function SettingsUI:ShowReminder(match, snapshot)
    reminderMatch = match
    reminderNote = nil
    local accent = LuckyUI.C.goldPrimary
    local function loadoutName(target)
        return CreateColor(accent[1], accent[2], accent[3]):WrapTextInColorCode(target.name)
    end
    if match.talents then
        showReminderRows({})
        reminderText:SetText(talentLines(match.talents))
        planTalentStep(true)
    elseif match.choices then
        reminderText:SetText(S.REMINDER_CHOOSE)
        local rows = {}
        for index, choice in ipairs(match.choices) do
            rows[index] = {
                text = string.format(S.REMINDER_CHOICE, choice.label, loadoutName(choice.target)),
                button = S.SWITCH,
                blocker = function() return LuckyLoadouts.Loadouts:GetSwitchBlocker(choice.configID) end,
                onClick = function() LuckyLoadouts.Loadouts:RequestSwitch(choice.configID, "reminder") end,
            }
        end
        showReminderRows(rows)
        reminderSwitchBlocker = function() return LuckyLoadouts.Loadouts:GetSwitchBlocker(match.configID) end
    else
        showReminderRows({})
        reminderText:SetText(string.format(S.REMINDER_TEXT, match.label or snapshot.label, loadoutName(match.target)))
        reminderSwitch:SetText(S.SWITCH)
        reminderSwitchBlocker = function() return LuckyLoadouts.Loadouts:GetSwitchBlocker(match.configID) end
        reminderAction = function() LuckyLoadouts.Loadouts:RequestSwitch(match.configID, "reminder") end
    end
    local hasRows = reminderRowCount > 0
    reminderChoices:SetShown(hasRows)
    reminderStatus:SetPoint("TOPLEFT", hasRows and reminderChoices or reminderText, "BOTTOMLEFT", 0, -REMINDER_LINE_GAP)
    reminderSwitch:SetShown(not hasRows)
    setReminderApplying(false)
    updateReminderSwitches()
    showReminderBlocker()
    reminder:Show()
end

-- The tree changing under a shown talent reminder can change what Swap would do.
function SettingsUI:ReplanReminder()
    if not reminder:IsShown() or not reminderMatch or not reminderMatch.talents
        or LuckyLoadouts.Talents.GetBlocker() == S.SWAP_PENDING then return end
    planTalentStep()
    updateReminderSwitches()
    showReminderBlocker()
end

function SettingsUI:HideReminder()
    if reminder then reminder:Hide() end
end

function SettingsUI:SetReminderCombat(inCombat)
    if not reminder or not reminder:IsShown() or not reminderMatch then return end
    updateReminderSwitches(inCombat and S.IN_COMBAT or nil)
    showReminderBlocker(inCombat and S.IN_COMBAT or nil)
end
