-- luacheck: globals LuckyLoadouts

LuckyLoadouts = LuckyLoadouts or {}

LuckyLoadouts.Constants = {
    -- Current Season pages the Adventure Guide lists as instances but which only
    -- group loot real instances carry: 1319 Keystone Dungeons, 1312 the season
    -- raids. Season data, copied from Loot Wishlist.
    SEASON_GROUPING_PAGES = { [1319] = true, [1312] = true },

    -- Journal instance ID -> { [journal encounter ID] = { prerequisite encounter IDs } }.
    -- Every listed prerequisite must be dead before the boss counts as next.
    -- A raid with no entry gates nothing, so every boss still alive is next.
    -- ponytail: copied from Loot Wishlist's RAID_LAYOUTS, move to Luckys_Utils if a third addon needs it.
    RAID_LAYOUTS = {
        -- Aberrus, the Shadowed Crucible
        [1208] = {
            [2522] = {},                  -- Kazzara: entrance boss
            [2529] = { 2522 },            -- Amalgamation Chamber
            [2530] = { 2529 },            -- Forgotten Experiments
            [2524] = { 2522 },            -- Assault of the Zaqali
            [2525] = { 2524 },            -- Rashok
            [2532] = { 2525, 2530 },      -- Zskarn: after both wings
            [2527] = { 2532 },            -- Magmorax
            [2523] = { 2527 },            -- Echo of Neltharion
            [2520] = { 2523 },            -- Sarkareth
        },
        -- The Voidspire
        [1307] = {
            [2733] = {},                  -- Imperator Averzian
            [2734] = { 2733 },            -- Vorasius
            [2736] = { 2733 },            -- Fallen-King Salhadaar
            [2735] = { 2734, 2736 },      -- Vaelgor & Ezzorak: after both
            [2737] = { 2735 },            -- Lightblinded Vanguard
            [2738] = { 2737 },            -- Crown of the Cosmos
        },
        -- The Dreamrift
        [1314] = {
            [2795] = {},                  -- Chimaerus the Undreamt God
        },
        -- March on Quel'Danas
        [1308] = {
            [2739] = {},                  -- Belo'ren, Child of Al'ar
            [2740] = { 2739 },            -- Midnight Falls
        },
        -- The Venomous Abyss: the two crypts clear in either order, then the
        -- raid converges on the Twin Fangs.
        [1320] = {
            [2888] = {},                  -- Nek'zali the Soulcoiler: entrance boss
            [2874] = { 2888 },            -- Entombed Sentinels: Vile Crypt
            [2882] = { 2874 },            -- Vashnik the Malignant
            [2894] = { 2888 },            -- The Lost Explorers: Crypt of the Soulcoilers
            [2871] = { 2894 },            -- Sszorak
            [2887] = { 2882, 2871 },      -- The Twin Fangs: after both crypts
            [2883] = { 2887 },            -- The Coiled Altar
            [2895] = { 2883 },            -- Ula'tek
        },
    },
}
