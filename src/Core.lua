-- luacheck: globals LuckyLoadouts LuckyLoadoutsDB LuckyLoadoutsCharDB SLASH_LUCKYLOADOUTS1

LuckyLoadouts = LuckyLoadouts or {}

local ADDON_NAME = "Luckys_Loadouts"
local initialized = false
local frame = CreateFrame("Frame")

local function initialize()
    if initialized then return end
    initialized = true

    LuckyLoadoutsDB = LuckyLoadouts.CopyDefaults(LuckyLoadoutsDB, LuckyLoadouts.Defaults.account)
    LuckyLoadoutsCharDB = LuckyLoadouts.CopyDefaults(LuckyLoadoutsCharDB, LuckyLoadouts.Defaults.character)
    LuckyLoadoutsCharDB.schemaVersion = 1

    local S = LuckyLoadouts.Strings
    LuckyLoadouts.Log = LuckyLog:New(S.PREFIX, function() return LuckyLoadoutsDB.devMode end)
    LuckyLoadouts.Loadouts:Init(LuckyLoadoutsCharDB)

    local function openFromMinimap(_, button)
        if button == "RightButton" then
            LuckyLoadouts.Settings:OpenSettings()
        elseif button == "MiddleButton" then
            LuckyLoadoutsDB.devMode = not LuckyLoadoutsDB.devMode
            print(S.PREFIX, LuckyLoadoutsDB.devMode and S.DEV_ON or S.DEV_OFF)
        else
            LuckyLoadouts.Settings:OpenManager()
        end
    end

    local function addTooltip(tooltip)
        tooltip:AddLine(S.MINIMAP_TITLE)
        tooltip:AddLine(S.MINIMAP_LEFT, 0.8, 0.8, 0.8)
        tooltip:AddLine(S.MINIMAP_RIGHT, 0.8, 0.8, 0.8)
        tooltip:AddLine(S.MINIMAP_MIDDLE, 0.8, 0.8, 0.8)
    end

    local minimap = LuckyMinimap:Create({
        name = "LuckyLoadoutsMinimapButton",
        tocname = ADDON_NAME,
        text = S.ADDON_NAME,
        icon = 136129,
        dbKey = "minimap",
        db = LuckyLoadoutsDB,
        defaultAngle = 245,
        onClick = openFromMinimap,
        tooltip = addTooltip,
    })

    LuckyLoadouts.Settings:Init(LuckyLoadoutsDB, LuckyLoadoutsCharDB)
    LuckyLoadouts.Settings:SetMinimapButton(minimap)
    LuckyLoadouts.Reminders:Init(LuckyLoadoutsCharDB)

    SLASH_LUCKYLOADOUTS1 = "/ll"
    SlashCmdList.LUCKYLOADOUTS = function(msg)
        if strtrim(msg or ""):lower() == "remind" and LuckyLoadoutsDB.devMode then
            if not LuckyLoadouts.Reminders:Replay() then print(S.PREFIX, S.DEV_NO_REMINDER) end
            return
        end
        LuckyLoadouts.Settings:OpenSettings()
    end

    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    frame:RegisterEvent("PLAYER_TALENT_UPDATE")
    frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    frame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED")
    frame:RegisterEvent("SELECTED_LOADOUT_CHANGED")
    frame:RegisterEvent("CONFIG_COMMIT_FAILED")

    -- Blizzard's dropdown moves the last-selected pointer after the trait
    -- events have reached us, and moving it client-side fires no event.
    hooksecurefunc(C_ClassTalents, "UpdateLastSelectedSavedConfigID", function()
        LuckyLoadouts.Loadouts:HandleEvent("SELECTED_LOADOUT_CHANGED")
    end)
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        frame:UnregisterEvent("ADDON_LOADED")
        initialize()
        return
    end
    LuckyLoadouts.Loadouts:HandleEvent(event, arg1)
end)
