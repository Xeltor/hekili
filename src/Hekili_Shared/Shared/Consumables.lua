-- Hekili_Shared/Shared/Consumables.lua
-- The consumables every class shares on Forever (shared-content spec §4.3), through Engine/Schema/Shared.lua into `all`: the
-- `potion` action and auras core reads by name, the Healthstone from Forever's items (DB2 1.60.1.70338: the five
-- ranks and their Improved Healthstone variants), and the healing, mana and energy consumables as their own actions.
-- The generic `potion` verb has no configured buff potion. Healing is simulated only when the APL picks the item.

local C_Item = Hekili.Client.C_Item
local GetItemCount, IsUsableItem = C_Item.GetItemCount, C_Item.IsUsableItem
local UnitLevel, PlayerHealthFraction = Hekili.Client.UnitLevel, Hekili.Client.PlayerHealthFraction

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

-- Highest heal first: Major, Greater, Healthstone, Lesser, Minor; each as Improved Healthstone 2/2, 1/2, then plain.
local HEALTHSTONES =
    { 19013, 19012, 9421, 19011, 19010, 5510, 19009, 19008, 5509, 19007, 19006, 5511, 19005, 19004, 5512 }

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
    return inBags(HEALTHSTONES)
end

shared:RegisterAbility("healthstone", {
    name = "Healthstone", -- l10n: verbatim
    listName = "|T538745:0|t |cff00ccff[Healthstone]|r",
    cast = 0,
    cooldown = 120, -- Classic's shared Healthstone cooldown; the item's own is read in game (spec §7 Q5)
    gcd = "off",

    item = healthstone,
    items = HEALTHSTONES,
    bagItem = true,

    startsCombat = false,
    toggle = "defensives",

    usable = function()
        local item, inBags = healthstone()
        if not inBags then
            return false, "requires healthstone in bags"
        elseif not IsUsableItem(item) then
            return false, "healthstone on CD"
        elseif health.current >= health.max and PlayerHealthFraction() == 1 then
            return false, "must be damaged"
        end
        return true
    end,

    handler = function()
        gain(0.25 * health.max, "health")
    end,
})

-- The six standard Forever healing potions, strongest first. Their use levels and
-- average heals are from the Forever item tooltips. They share a two-minute cooldown.
local HEALING_POTIONS = { 13446, 3928, 1710, 929, 858, 118 }
local POTION_LEVEL = { [13446] = 45, [3928] = 35, [1710] = 21, [929] = 12, [858] = 3, [118] = 1 }
local POTION_HEAL = { [13446] = 1400, [3928] = 800, [1710] = 520, [929] = 320, [858] = 160, [118] = 80 }

local function healingPotion()
    local level
    for _, item in ipairs(HEALING_POTIONS) do
        if GetItemCount(item) > 0 then
            level = level or UnitLevel("player") or 0
            if level >= POTION_LEVEL[item] and IsUsableItem(item) then
                return item, true
            end
        end
    end
    return HEALING_POTIONS[#HEALING_POTIONS], false
end

shared:RegisterAbility("healing_potion", {
    name = "Healing Potion", -- l10n: verbatim
    cast = 0,
    cooldown = 120,
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
        gain(POTION_HEAL[healingPotion()], "health")
    end,
})

-- The mana and energy consumables (C12), best first: item IDs from ItemSparse (DB2 1.60.1.70338); each cooldown from
-- wowsims/forever's db.json (MIT, a reference only): the potion's own 2 min category, and the 2 min category the rune,
-- the tea and the gems share (Thistle Tea's own 5 min); Mana Agate's row is absent there and is taken as its ranks'.
-- Read in game (checkpoint). Offered while one is in the bags and the client calls it usable; none has a `now`.
-- Under the Potions toggle (user ruling 2026-10-21: buff and resource consumables go under Potions, health ones under
-- Defensives); with Potions off their lines are skipped and the list falls through to the next.
local function consume(key, items, cooldown, name)
    local function best()
        return inBags(items)
    end
    shared:RegisterAbility(key, {
        name = name,
        cast = 0,
        cooldown = cooldown,
        gcd = "off",

        item = best,
        items = items,
        bagItem = true,

        startsCombat = false,
        toggle = "potions",

        usable = function()
            local item, have = best()
            if not have then
                return false, "none in the bags"
            end
            return IsUsableItem(item) == true, "not usable"
        end,
    })
end

consume("major_mana_potion", { 13444 }, 120)
consume("demonic_rune", { 12662 }, 120)
consume("thistle_tea", { 7676 }, 300)
consume("mana_gem", { 8008, 8007, 5513, 5514 }, 120, "Mana Gem") -- Ruby, Citrine, Jade, Agate
