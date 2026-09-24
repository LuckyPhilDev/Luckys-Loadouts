-- luacheck: globals LuckyLoadouts PlayerSpellsFrame PlayerSpellsUtil GameTooltip_Hide

LuckyLoadouts = LuckyLoadouts or {}
LuckyLoadouts.Talents = {}

local Talents = LuckyLoadouts.Talents
local S
local swapping
local overlay
local banner
local bannerText
local bannerButton
local bannerCancel
local spots = {}
local pick
local highlighted
local TIMEOUT_SECONDS = 12
-- The ring copies the talent's own border, so it is a circle, square or
-- octagon to match, drawn outside it. Cyan because the tree already uses
-- yellow for taken and green for available.
local RING_SCALE = 1.2
local RING_GLOW_SCALE = 1.4
local PULSE_SECONDS = 1.4
local RING_FALLBACK_ATLAS = "talents-node-circle-yellow"
local TAKE_COLOR = { 0.25, 0.9, 1 }
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function entrySpell(configID, entryID)
    local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
    local definition = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
    return definition and definition.spellID
end

local function nodeInfo(configID, nodeID)
    local info = configID and C_Traits.GetNodeInfo(configID, nodeID)
    if type(info) ~= "table" or not info.ID or info.ID == 0 then return nil end
    return info
end

function Talents.SpellName(talent)
    return talent and talent.spellID and C_Spell.GetSpellName(talent.spellID) or S.UNAVAILABLE
end

function Talents.Icon(talent)
    return talent and talent.spellID and C_Spell.GetSpellTexture(talent.spellID)
end

-- Taken on the active tree, the chosen side for a choice node. Nil when the
-- tree no longer has the node.
function Talents.IsTaken(talent)
    local info = nodeInfo(C_ClassTalents.GetActiveConfigID(), talent.nodeID)
    if not info then return nil end
    if (info.activeRank or 0) == 0 then return false end
    return not (info.activeEntry and talent.entryID) or info.activeEntry.entryID == talent.entryID
end

function Talents.GetBlocker()
    if swapping then return S.SWAP_PENDING end
    return LuckyLoadouts.Loadouts:GetEditBlocker()
end

-- Class and spec talents are paid from separate point pools, so a talent can
-- only make room for one paid from the same pool. A node that reports no cost
-- (a maxed talent may) has an unknown pool, which matches any.
-- Unverified: C_Traits.GetNodeCost on retail.
local function nodeCost(configID, nodeID)
    local costs = C_Traits.GetNodeCost and C_Traits.GetNodeCost(configID, nodeID)
    local cost = type(costs) == "table" and costs[1]
    return cost and cost.ID, cost and cost.amount or 1
end

local function samePool(a, b)
    return a == nil or b == nil or a == b
end

local function log(explain, ...)
    if explain and LuckyLoadouts.Log then LuckyLoadouts.Log(...) end
end

local function pointsToTake(info)
    local purchased = info.ranksPurchased or 0
    -- A choice node already bought only changes sides.
    if #(info.entryIDs or {}) > 1 and purchased > 0 then return 0 end
    return (info.maxRanks or 1) - purchased
end

local REQUIRED_EDGE = Enum.TraitEdgeType.RequiredForAvailability
local SUFFICIENT_EDGE = Enum.TraitEdgeType.SufficientForAvailability

-- The active tree as the swap would leave it. A talent is reachable when every
-- required parent and at least one sufficient parent is maxed, so Detox can go
-- only while nothing bought below it loses its last way in.
-- Unverified: visibleEdges, GetTreeNodes and that a parent must be maxed, on retail.
-- ponytail: section gates are not checked; a swap keeps the points spent the same.
local function simulatedTree(configID)
    local infos, parents, children, ranks = {}, {}, {}, {}
    local config = C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    for _, nodeID in ipairs(treeID and C_Traits.GetTreeNodes(treeID) or {}) do
        local info = nodeInfo(configID, nodeID)
        infos[nodeID] = info
        for _, edge in ipairs(info and info.visibleEdges or {}) do
            if edge.type == REQUIRED_EDGE or edge.type == SUFFICIENT_EDGE then
                local child = edge.targetNode
                parents[child] = parents[child] or {}
                table.insert(parents[child], { nodeID = nodeID, required = edge.type == REQUIRED_EDGE })
                children[nodeID] = children[nodeID] or {}
                table.insert(children[nodeID], child)
            end
        end
    end

    local function granted(info) return (info.activeRank or 0) - (info.ranksPurchased or 0) end
    local function rank(nodeID) return ranks[nodeID] or infos[nodeID] and infos[nodeID].activeRank or 0 end
    local function maxed(nodeID)
        return infos[nodeID] ~= nil and rank(nodeID) >= (infos[nodeID].maxRanks or 1)
    end

    local tree = {}
    function tree.Reachable(nodeID)
        local hasSufficient, sufficientMet = false, false
        for _, parent in ipairs(parents[nodeID] or {}) do
            if parent.required then
                if not maxed(parent.nodeID) then return false end
            else
                hasSufficient = true
                sufficientMet = sufficientMet or maxed(parent.nodeID)
            end
        end
        return sufficientMet or not hasSufficient
    end
    function tree.Take(nodeID) ranks[nodeID] = infos[nodeID] and infos[nodeID].maxRanks or 1 end
    function tree.GiveUp(nodeID) ranks[nodeID] = infos[nodeID] and granted(infos[nodeID]) or 0 end
    function tree.Restore(nodeID) ranks[nodeID] = nil end
    -- A bought talent below this one that has lost its last way in.
    function tree.Stranded(nodeID)
        for _, child in ipairs(children[nodeID] or {}) do
            local info = infos[child]
            if info and rank(child) > granted(info) and not tree.Reachable(child) then return child end
        end
        return nil
    end
    return tree
end

local function nodeName(configID, nodeID)
    local info = nodeInfo(configID, nodeID)
    return Talents.SpellName({ spellID = info and info.activeEntry and entrySpell(configID, info.activeEntry.entryID) })
end

-- Which missing talents a swap can take, and which talents it gives up for
-- them: the first in priority order that are taken, not kept, that Blizzard
-- lets go of, and that nothing kept or taken depends on.
-- ponytail: unspent points are not counted, a refund left over from a bigger
-- talent stays unspent, and missing talents are taken in list order, so one
-- whose parent is also missing must come after it.
function Talents.PlanSwap(missing, giveUps, keep, explain)
    local plan = { take = {}, giveUp = {}, blocked = {}, locked = {} }
    local configID = C_ClassTalents.GetActiveConfigID()
    local tree = simulatedTree(configID)
    local isWanted, used, credit = {}, {}, {}
    for _, talent in ipairs(missing) do isWanted[talent.nodeID] = true end
    for _, talent in ipairs(keep or {}) do isWanted[talent.nodeID] = true end

    -- Points a candidate frees for a talent in this pool, or 0 and why not.
    local function freedBy(candidate, currency)
        if isWanted[candidate.nodeID] then return 0, "wanted here" end
        if used[candidate.nodeID] then return 0, "already given up" end
        local info = nodeInfo(configID, candidate.nodeID)
        local purchased = info and info.ranksPurchased or 0
        if purchased == 0 then return 0, "not taken" end
        local candidateCurrency, amount = nodeCost(configID, candidate.nodeID)
        if not samePool(candidateCurrency, currency) then return 0, "other point pool" end
        -- The node's own flag is what Blizzard's talent frame reads before a
        -- refund; C_Traits.CanRefundRank said no to every taken talent in game.
        if info.canRefundRank == false then return 0, "Blizzard will not remove it" end
        return purchased * amount
    end

    for _, talent in ipairs(missing) do
        local info = nodeInfo(configID, talent.nodeID)
        local currency, amount
        if info then currency, amount = nodeCost(configID, talent.nodeID) end
        local need = info and pointsToTake(info) * amount or math.huge
        local pool = currency or 0
        local have, freed = credit[pool] or 0, {}
        log(explain, "Swap for", Talents.SpellName(talent), "needs", need, "points from pool", tostring(currency))
        tree.Take(talent.nodeID)
        if not tree.Reachable(talent.nodeID) then
            log(explain, "  needs a talent above it first")
            tree.Restore(talent.nodeID)
            plan.locked[#plan.locked + 1] = talent
        else
            for _, candidate in ipairs(giveUps) do
                if have >= need then break end
                local points, reason = freedBy(candidate, currency)
                if points > 0 then
                    tree.GiveUp(candidate.nodeID)
                    local stranded = tree.Stranded(candidate.nodeID)
                    if stranded then
                        tree.Restore(candidate.nodeID)
                        points, reason = 0, "needed by " .. nodeName(configID, stranded)
                    end
                end
                log(explain, "  ", Talents.SpellName(candidate), points > 0 and ("frees " .. points) or reason)
                if points > 0 then
                    used[candidate.nodeID] = true
                    freed[#freed + 1] = candidate
                    have = have + points
                end
            end
            if have >= need then
                credit[pool] = have - need
                plan.take[#plan.take + 1] = talent
                for _, candidate in ipairs(freed) do plan.giveUp[#plan.giveUp + 1] = candidate end
            else
                tree.Restore(talent.nodeID)
                for _, candidate in ipairs(freed) do
                    used[candidate.nodeID] = nil
                    tree.Restore(candidate.nodeID)
                end
                plan.blocked[#plan.blocked + 1] = talent
            end
        end
    end
    return plan
end

local function refund(configID, nodeID)
    local info = nodeInfo(configID, nodeID)
    for _ = 1, info and info.ranksPurchased or 0 do
        if not C_Traits.RefundRank(configID, nodeID) then return false end
    end
    return true
end

local function purchase(configID, talent)
    local info = nodeInfo(configID, talent.nodeID)
    if not info then return false end
    if #(info.entryIDs or {}) > 1 then return C_Traits.SetSelection(configID, talent.nodeID, talent.entryID) end
    for _ = (info.ranksPurchased or 0) + 1, info.maxRanks or 1 do
        if not C_Traits.PurchaseRank(configID, talent.nodeID) then return false end
    end
    return true
end

local function finishSwap()
    swapping = nil
end

-- Takes every wanted talent the plan can make room for, in one apply. Changes
-- only the active talents, never the saved loadout, and leaves nothing staged
-- when any step is refused.
-- Unverified: confirm C_Traits.CommitConfig from a plain button click on retail.
function Talents.Swap(missing, giveUps, keep, onFailed)
    local blocker = Talents.GetBlocker()
    if blocker then return false, blocker end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return false, S.NATIVE_UNKNOWN end
    local plan = Talents.PlanSwap(missing, giveUps, keep, true)
    if #plan.take == 0 then return false, S.SWAP_NOTHING end

    local staged, err = pcall(function()
        for _, talent in ipairs(plan.giveUp) do
            if not refund(configID, talent.nodeID) then
                return string.format(S.SWAP_REFUND_FAILED, Talents.SpellName(talent))
            end
        end
        for _, talent in ipairs(plan.take) do
            if not purchase(configID, talent) then
                return string.format(S.SWAP_PURCHASE_FAILED, Talents.SpellName(talent))
            end
        end
        if not C_Traits.CommitConfig(configID) then return S.SWAP_FAILED end
    end)
    err = not staged and S.SWAP_FAILED or err
    if err then
        pcall(C_Traits.RollbackConfig, configID)
        return false, err
    end

    local token = {}
    swapping = { configID = configID, onFailed = onFailed, token = token }
    C_Timer.After(TIMEOUT_SECONDS, function()
        if swapping and swapping.token == token then finishSwap() end
    end)
    return true
end

function Talents:HandleEvent(event, configID)
    if not swapping then return end
    if event == "CONFIG_COMMIT_FAILED" then
        local failed = swapping
        finishSwap()
        -- An interrupted commit leaves the swap staged, which would block the next try.
        C_Timer.After(0, function()
            if C_Traits.ConfigHasStagedChanges and C_Traits.ConfigHasStagedChanges(failed.configID) then
                pcall(C_Traits.RollbackConfig, failed.configID)
            end
        end)
        if failed.onFailed then failed.onFailed(S.SWAP_FAILED) end
    elseif event == "TRAIT_CONFIG_UPDATED" and configID == swapping.configID then
        finishSwap()
    end
end

local function talentsFrame()
    return PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
end

-- The role a node plays and, for a talent to give up, its priority.
local function roleOf(nodeID)
    if highlighted then return highlighted[nodeID] end
    if not pick then return nil end
    for index, talent in ipairs(pick.getList()) do
        if talent.nodeID == nodeID then return pick.mode, index end
    end
    return nil
end

local function paint()
    for _, spot in ipairs(spots) do
        local role, priority = roleOf(spot.nodeID)
        local color = role == "giveUp" and LuckyUI.C.danger or TAKE_COLOR
        local marked = role ~= nil and spot:IsShown()
        for _, ring in ipairs({ spot.ring, spot.ringGlow }) do
            ring:SetVertexColor(color[1], color[2], color[3])
            ring:SetShown(marked)
        end
        spot.priority:SetText(role == "giveUp" and priority or "")
    end
    if not pick then return end
    local confirming = pick.confirming
    bannerCancel:SetShown(confirming ~= nil)
    if confirming then
        bannerText:SetText(string.format(S.PICK_NOT_TAKEN, Talents.SpellName(confirming)))
        bannerButton:SetText(S.ADD)
    else
        bannerText:SetText(pick.mode == "giveUp" and S.PICK_GIVE_UP or string.format(S.PICK_TAKE, pick.title))
        bannerButton:SetText(S.DONE)
    end
end

local function add(talent)
    local list = pick.getList()
    list[#list + 1] = talent
    pick.onChange()
    paint()
end

local function removePicked(nodeID)
    local list = pick.getList()
    for index, talent in ipairs(list) do
        if talent.nodeID == nodeID then
            table.remove(list, index)
            pick.onChange()
            paint()
            return true
        end
    end
    return false
end

local function newTalent(configID, nodeID, entryID, choice)
    return { nodeID = nodeID, entryID = entryID, spellID = entrySpell(configID, entryID), choice = choice }
end

local function clickSpot(spot)
    if pick.confirming then return end
    if removePicked(spot.nodeID) then return end
    local configID = C_ClassTalents.GetActiveConfigID()
    local info = nodeInfo(configID, spot.nodeID)
    if not info then return end
    local entries = info.entryIDs or {}
    local activeEntryID = info.activeEntry and info.activeEntry.entryID or entries[1]

    if pick.mode == "giveUp" then
        local talent = newTalent(configID, spot.nodeID, activeEntryID)
        -- The tree on show may not be the one the swap will run on, so only ask.
        if (info.ranksPurchased or 0) == 0 then
            pick.confirming = talent
            paint()
        else
            add(talent)
        end
    elseif #entries > 1 then
        MenuUtil.CreateContextMenu(spot, function(_, rootDescription)
            for _, entryID in ipairs(entries) do
                local name = C_Spell.GetSpellName(entrySpell(configID, entryID) or 0) or S.UNAVAILABLE
                rootDescription:CreateButton(name, function() add(newTalent(configID, spot.nodeID, entryID, true)) end)
            end
        end)
    else
        add(newTalent(configID, spot.nodeID, activeEntryID))
    end
end

local function showSpotTooltip(spot)
    if not spot.spellID then return end
    GameTooltip:SetOwner(spot, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(spot.spellID)
    GameTooltip:Show()
end

-- A solid ring in the talent's shape and a wider additive copy that pulseRings pulses.
local function createRing(spot)
    spot.ring = spot:CreateTexture(nil, "OVERLAY", nil, 1)
    spot.ring:SetPoint("CENTER")
    spot.ringGlow = spot:CreateTexture(nil, "OVERLAY")
    spot.ringGlow:SetPoint("CENTER")
    spot.ringGlow:SetBlendMode("ADD")
    for _, ring in ipairs({ spot.ring, spot.ringGlow }) do ring:Hide() end
end

-- One clock for every glow, so they pulse in step however late each was shown.
local function pulseRings()
    local alpha = 0.6 + 0.4 * math.cos(GetTime() * 2 * math.pi / PULSE_SECONDS)
    for _, spot in ipairs(spots) do spot.ringGlow:SetAlpha(alpha) end
end

-- Unverified: StateBorder is the border texture on retail talent buttons.
local function shapeRing(spot, button)
    local border = button.StateBorder
    local atlas = border and border.GetAtlas and border:GetAtlas() or RING_FALLBACK_ATLAS
    local width, height = button:GetSize()
    if border and border.GetSize then width, height = border:GetSize() end
    for ring, scale in pairs({ [spot.ring] = RING_SCALE, [spot.ringGlow] = RING_GLOW_SCALE }) do
        ring:SetAtlas(atlas)
        ring:SetDesaturated(true)
        ring:SetSize(width * scale, height * scale)
    end
end

-- Talent buttons come in circles, squares and octagons; a round hover suits all three.
local function acquireSpot(index)
    local spot = spots[index]
    if spot then return spot end
    spot = CreateFrame("Button", nil, overlay)
    local mask = spot:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints()
    local hover = spot:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.25)
    hover:AddMaskTexture(mask)
    createRing(spot)
    spot.priority = spot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    spot.priority:SetPoint("CENTER", spot, "BOTTOMLEFT", 6, 6)
    spot:SetScript("OnClick", clickSpot)
    spot:SetScript("OnEnter", showSpotTooltip)
    spot:SetScript("OnLeave", GameTooltip_Hide)
    spots[index] = spot
    return spot
end

local function createOverlay(talents)
    -- Clicks land on the overlay, never Blizzard's buttons, so picking stages nothing.
    overlay = CreateFrame("Frame", nil, talents)
    overlay:SetAllPoints(talents)
    overlay:SetFrameStrata("DIALOG")
    overlay:SetScript("OnUpdate", pulseRings)
    overlay:Hide()

    banner = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
    banner:SetSize(600, 44)
    banner:SetPoint("BOTTOM", 0, 12)
    banner:SetBackdrop(LuckyUI.Backdrop)
    local bg, border = LuckyUI.C.bgPanel, LuckyUI.C.goldAccent
    banner:SetBackdropColor(bg[1], bg[2], bg[3], 1)
    banner:SetBackdropBorderColor(border[1], border[2], border[3])
    bannerCancel = LuckyUI.CreateButton(banner, S.CANCEL, 80, 24)
    bannerCancel:SetPoint("RIGHT", -10, 0)
    bannerCancel:SetScript("OnClick", function()
        pick.confirming = nil
        paint()
    end)
    bannerButton = LuckyUI.CreateButton(banner, S.DONE, 80, 24, "primary")
    bannerButton:SetPoint("RIGHT", bannerCancel, "LEFT", -8, 0)
    bannerButton:SetScript("OnClick", function()
        local confirming = pick and pick.confirming
        if confirming then
            pick.confirming = nil
            add(confirming)
        else
            overlay:Hide()
        end
    end)
    bannerText = banner:CreateFontString(nil, "OVERLAY")
    bannerText:SetFont(LuckyUI.BODY_FONT, 12, "")
    bannerText:SetPoint("LEFT", 12, 0)
    bannerText:SetPoint("RIGHT", bannerButton, "LEFT", -10, 0)
    bannerText:SetJustifyH("LEFT")

    overlay:SetScript("OnHide", function()
        -- Closing the Talents window only hides this with it; hide it for real
        -- so it does not come back over the tree once picking has ended.
        overlay:Hide()
        local done = pick and pick.onDone
        pick, highlighted = nil, nil
        if done then done() end
    end)
end

-- Talent buttons exist only once the tab has drawn, so wait a frame after opening it.
-- Unverified: EnumerateAllTalentButtons and GetNodeID on the retail talent frame.
local function showOverlay(interactive)
    if PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab then PlayerSpellsUtil.OpenToClassTalentsTab() end
    C_Timer.After(0, function()
        local talents = talentsFrame()
        if not talents or not talents.EnumerateAllTalentButtons then return end
        if not overlay then createOverlay(talents) end
        local configID = C_ClassTalents.GetActiveConfigID()
        local count = 0
        for button in talents:EnumerateAllTalentButtons() do
            local nodeID = button.GetNodeID and button:GetNodeID()
            if nodeID and button:IsVisible() then
                count = count + 1
                local spot = acquireSpot(count)
                spot:ClearAllPoints()
                spot:SetAllPoints(button)
                shapeRing(spot, button)
                spot.nodeID = nodeID
                local info = nodeInfo(configID, nodeID)
                local entryID = info and (info.activeEntry and info.activeEntry.entryID or (info.entryIDs or {})[1])
                spot.spellID = configID and entrySpell(configID, entryID)
                spot:EnableMouse(interactive)
                spot:Show()
            end
        end
        for index = count + 1, #spots do spots[index]:Hide() end
        overlay:EnableMouse(interactive)
        banner:SetShown(interactive)
        overlay:Show()
        paint()
    end)
end

-- Pick talents on the talent tree itself. mode is "take" for talents wanted
-- somewhere, "giveUp" for the priority list. getList returns the stored list,
-- changed in place; onDone runs when picking ends.
function Talents.StartPick(mode, title, getList, onChange, onDone)
    if overlay then overlay:Hide() end
    highlighted = nil
    pick = { mode = mode, title = title, getList = getList, onChange = onChange, onDone = onDone }
    showOverlay(true)
end

-- Open the talent tree with the talents to take and to give up marked until it closes.
function Talents.PointOut(take, giveUp)
    if overlay then overlay:Hide() end
    highlighted = {}
    for _, talent in ipairs(giveUp or {}) do highlighted[talent.nodeID] = "giveUp" end
    for _, talent in ipairs(take) do highlighted[talent.nodeID] = "take" end
    showOverlay(false)
end

function Talents:Init()
    S = LuckyLoadouts.Strings
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CONFIG_COMMIT_FAILED")
    frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    frame:SetScript("OnEvent", function(_, event, configID) self:HandleEvent(event, configID) end)
end
