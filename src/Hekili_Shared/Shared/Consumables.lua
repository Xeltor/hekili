-- Hekili_Shared/Shared/Consumables.lua
-- The consumables every class shares on Forever (shared-content spec §4.3), through Engine/Schema/Shared.lua into `all`: the
-- `potion` action and auras core reads by name, the Healthstone from Forever's items (DB2 1.60.1.70338: the five
-- ranks and their Improved Healthstone variants), the healing potions (L1808), the mana and energy consumables as their
-- own actions, and the on-use items that restore mana. No potion is registered for the `potion` verb, nor flask or
-- food: the default priorities leave them out.
-- Neither `potion`, the Healthstone nor the healing potion has a `now`: the belief sees only spell casts (none names a
-- use spell), and a heal is health, which the belief does not track (spec §4.3). A mana refill names its use spell
-- (below).

local C_Item = Hekili.Client.C_Item
local GetItemCount, IsUsableItem = C_Item.GetItemCount, C_Item.IsUsableItem
local UnitLevel, PlayerHealthFraction = Hekili.Client.UnitLevel, Hekili.Client.PlayerHealthFraction
local L = Hekili:GetLocale("Hekili_Shared")

-- An item's name as the player's client shows it (architecture section 9: names the client translates come from
-- the client): its item data, plain (W PR13), read once here; `fallback` (the shared content's string) while the
-- client has not cached the item. One plain item stands for every rank: 5509 is "Healthstone", 929 "Healing
-- Potion" (the wowsims pin's db.json).
local function itemName(id, fallback)
    local name = C_Item.GetItemInfo(id)
    if type(name) == "string" and name ~= "" then
        return name
    end
    return fallback
end

local class = Hekili.Class
local state = Hekili.State -- upvalue: Hekili setfenv's ability functions to `state`, where the name `state` is not a key

local shared = Hekili:NewShared()

-- State.lua's applyBuff mirrors a potion's aura to `potion`; with no Forever potion registered, `fake_potion` is the
-- alias's only member.
shared:RegisterAura("fake_potion", {
    duration = 30,
    max_stack = 1,
})

shared:RegisterAura("potion", {
    alias = { "fake_potion" },
    aliasMode = "first",
    aliasType = "buff",
    duration = 30,
})

-- The APL verb `potion` (Core.lua resolves it to the chosen potion's action): an item only once a potion is chosen.
shared:RegisterAbility("potion", {
    name = "Potion", -- l10n: verbatim
    listName = "|T136243:0|t |cff00ccff[Potion]|r",
    cast = 0,
    cooldown = 300,
    gcd = "off",

    startsCombat = false,
    toggle = "potions",

    consumable = function()
        return state.args.potion or settings.potion
    end,
    item = function()
        if state.args.potion and class.abilities[state.args.potion] then
            return class.abilities[state.args.potion].item
        end
        if spec.potion and class.abilities[spec.potion] then
            return class.abilities[spec.potion].item
        end
    end,
    bagItem = true,

    handler = function()
        local use = class.specs[0].abilities.potion
        use = use and use.consumable

        if use and use ~= "global_cooldown" then
            class.abilities[use].handler()
            setCooldown(use, action[use].cooldown)
        end
    end,

    usable = function()
        return false, "no Forever potion is registered"
    end,

    copy = "potion_default",
})

-- Item ID, required use level and flat heal from Forever 1.60.1.70959 ItemSparse and SpellEffect.
-- At each rank the base item heals as much as the old 2/2 Improved Healthstone item.
local HEALTHSTONE_DATA = {
    { 19013, 48, 1440 },
    { 9421, 48, 1440 },
    { 19012, 48, 1320 },
    { 19011, 36, 960 },
    { 5510, 36, 960 },
    { 19010, 36, 880 },
    { 19009, 24, 600 },
    { 5509, 24, 600 },
    { 19008, 24, 550 },
    { 19007, 12, 300 },
    { 5511, 12, 300 },
    { 19006, 12, 275 },
    { 19005, 1, 120 },
    { 5512, 1, 120 },
    { 19004, 1, 110 },
}
local HEALTHSTONES = {}
for i, stone in ipairs(HEALTHSTONE_DATA) do
    HEALTHSTONES[i] = stone[1]
end
-- Forever 1.60.1.70959 ItemEffect gives stones/runes category 1153 and potions category 4.
-- Both categories last two minutes. The client supplies live cooldowns for the selected item ID.
local RECOVERY_ITEM_COOLDOWN = 120

-- The first of `items` in the bags and true (the last and false when none: the keybind and icon lookups need an item).
-- A field read (`ability.item`) keeps only the first value.
local function inBags(items)
    for i = 1, #items do
        if GetItemCount(items[i]) > 0 then
            return items[i], true
        end
    end
    return items[#items], false
end

local function healthstone()
    local level, carried
    for _, stone in ipairs(HEALTHSTONE_DATA) do
        if GetItemCount(stone[1]) > 0 then
            level = level or UnitLevel("player") or 0
            if level >= stone[2] then
                if IsUsableItem(stone[1]) == true then
                    return stone, true
                end
                carried = carried or stone
            end
        end
    end
    -- Keep the item's identity and suppress repeat conjuring while a carried stone is temporarily unusable.
    return carried, false
end

shared:RegisterStateExpr("has_healthstone", function()
    return healthstone() ~= nil
end)

shared:RegisterAbility("healthstone", {
    name = itemName(5509, L["Healthstone"]),
    listName = "|T538745:0|t |cff00ccff[" .. itemName(5509, L["Healthstone"]) .. "]|r",
    cast = 0,
    cooldown = RECOVERY_ITEM_COOLDOWN,
    gcd = "off",

    item = function()
        local stone = healthstone()
        return stone and stone[1] or 5512
    end,
    items = HEALTHSTONES,
    bagItem = true,

    startsCombat = false,
    toggle = "defensives",

    usable = function()
        local stone, usable = healthstone()
        if not stone then
            return false, "requires healthstone in bags"
        elseif not usable then
            return false, "healthstone not usable"
        elseif health.current >= health.max and PlayerHealthFraction() == 1 then
            return false, "must be damaged"
        end
        return true
    end,

    handler = function()
        local stone, usable = healthstone()
        if usable then
            gain(stone[3], "health")
            setCooldown("demonic_rune", RECOVERY_ITEM_COOLDOWN)
        end
    end,
})

-- (L1808, owner "Setting per line") the Healthstone line's player-health threshold, on every spec: the translator puts
-- the line in every pack (wowsims's Protection threshold, 30%)
shared:RegisterSetting("healthstone_health", 30, shared:HealthOption("healthstone"))

-- Item IDs, use levels and average heals from the Forever potions' tooltips and pinned WoWSims item data.
-- Restored is placed after Major using its typical endgame heal. Combat and Perishable share their ranks' effects.
local HEALING_POTIONS = { 13446, 282011, 3928, 18839, 1710, 929, 268883, 858, 268882, 118, 268881 }
local POTION_LEVEL = {
    [13446] = 45,
    [282011] = 1,
    [3928] = 35,
    [18839] = 35,
    [1710] = 21,
    [929] = 12,
    [268883] = 12,
    [858] = 3,
    [268882] = 3,
    [118] = 1,
    [268881] = 1,
}
local POTION_HEAL = {
    [13446] = 1400,
    [3928] = 800,
    [18839] = 800,
    [1710] = 520,
    [929] = 320,
    [268883] = 320,
    [858] = 160,
    [268882] = 160,
    [118] = 80,
    [268881] = 80,
}

local function healingPotion()
    local level
    for _, item in ipairs(HEALING_POTIONS) do
        if GetItemCount(item) > 0 then
            level = level or UnitLevel("player") or 0
            if level >= POTION_LEVEL[item] and IsUsableItem(item) == true then
                return item, true
            end
        end
    end
    return 118, false
end

shared:RegisterAbility("healing_potion", {
    name = itemName(929, L["Healing Potion"]),
    listName = "|T136243:0|t |cff00ccff[" .. itemName(929, L["Healing Potion"]) .. "]|r",
    cast = 0,
    cooldown = RECOVERY_ITEM_COOLDOWN,
    gcd = "off",

    item = healingPotion,
    items = HEALING_POTIONS,
    bagItem = true,
    startsCombat = false,
    toggle = "defensives",

    usable = function()
        local _, have = healingPotion()
        return have, "requires a usable healing potion in bags"
    end,

    handler = function()
        local potion = healingPotion()
        local amount = potion == 282011 and 0.30 * health.max or POTION_HEAL[potion]
        gain(amount, "health")
        setCooldown("major_mana_potion", RECOVERY_ITEM_COOLDOWN)
    end,
})

-- the healing potion line's threshold, on every spec (rule 25 puts the line in every pack): 25%, the review's value
shared:RegisterSetting("healing_potion_health", 25, shared:HealthOption("healing_potion"))

-- The mana and energy consumables (C12), best first: item IDs from ItemSparse (DB2 1.60.1.70338); each cooldown from
-- wowsims/forever's db.json (MIT, a reference only): the potion's own 2 min category, and the 2 min category the rune,
-- the tea and the gems share (Thistle Tea's own 5 min); Mana Agate's row is absent there and is taken as its ranks'.
-- Read in game (checkpoint). Offered while one is in the bags and the client calls it usable.
-- Under the Potions toggle (user ruling 2026-10-21: buff and resource consumables go under Potions, health ones under
-- Defensives); with Potions off their lines are skipped and the list falls through to the next.
-- A mana refill (`spells`, `mids`, `spreads`: by rank in `items` order, each item's use spell and that spell's
-- restore, mid +- spread; numbers for one rank) is the use spell's cast success, which the belief tracks (`copy`): the
-- `now` credits the rank the cast was (`cast_id`), the simulation's `handler` the best one in the bags. The roll is
-- unseen, so it credits the average (owner L969): the `now` puts the estimate at the midpoint and the floor and top at
-- the ends, the `handler` gains the midpoint. `worn`: an equipped item (offered only while worn, the core's `equipped`
-- test), also under Potions (owner L1235).
local defensiveItem = { demonic_rune = "healthstone", major_mana_potion = "healing_potion" }
local function consume(key, items, cooldown, name, spells, mids, spreads, worn)
    local function best()
        return inBags(items)
    end
    if type(spells) == "number" then
        spells, mids, spreads = { spells }, { mids }, { spreads }
    end
    local bySpell, byItem = {}, {} -- a use spell's and an item's rank
    for r = 1, spells and #spells or 0 do
        bySpell[spells[r]], byItem[items[r]] = r, r
    end
    shared:RegisterAbility(key, {
        name = name,
        cast = 0,
        cooldown = cooldown,
        gcd = "off",
        copy = spells,

        item = worn and items[1] or best,
        items = items,
        bagItem = not worn,

        startsCombat = false,
        toggle = "potions",

        usable = function()
            if worn then
                return IsUsableItem(items[1]) == true, "not usable"
            end
            local item, have = best()
            if not have then
                return false, "none in the bags"
            end
            return IsUsableItem(item) == true, "not usable"
        end,

        now = spells and function()
            local r = bySpell[cast_id] or 1 -- luacheck: ignore 113 (the `now` context's read, Families/Now.lua)
            gain(mids[r], "mana", spreads[r])
        end or nil,
        handler = spells and function()
            local r = byItem[(best())] or 1
            gain(mids[r], "mana")
            if defensiveItem[key] then
                setCooldown(defensiveItem[key], RECOVERY_ITEM_COOLDOWN)
            end
        end or nil,
    })
end

-- The restores: the wowsims pin's spelldata (e4ef929e54, sim/core/spelldata/spells_auto_gen.go; the DB2's rows), mid
-- +- mid * Variance / 2: 17531 Restore Mana 1800 +- 450 (1350-2250), 16666 Demonic Rune 1200 +- 300 (900-1500); the
-- gems' Replenish Mana 10058 1100 +- 100, 10057 850 +- 75, 10052 600 +- 50, 5405 400 +- 25, their cooldown the items'
-- on-use category 1153, 120 s (the pin's db.json; sim/mage/mana_gems.go), not the spells' 60 s category 30; Robe of
-- the Archmage's 18385 500 +- 125, its item's on-use 300 s (db.json).
consume("major_mana_potion", { 13444 }, RECOVERY_ITEM_COOLDOWN, nil, 17531, 1800, 450)
consume("demonic_rune", { 12662 }, RECOVERY_ITEM_COOLDOWN, nil, 16666, 1200, 300)
consume("thistle_tea", { 7676 }, 300)
consume( -- Ruby, Citrine, Jade, Agate
    "mana_gem",
    { 8008, 8007, 5513, 5514 },
    120,
    "Mana Gem",
    { 10058, 10057, 10052, 5405 },
    { 1100, 850, 600, 400 },
    { 100, 75, 50, 25 }
)
consume("robe_of_the_archmage", { 14152 }, 300, nil, 18385, 500, 125, true)
