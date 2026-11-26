-- Hekili_Paladin/Paladin.lua
-- The Forever Paladin (Protection, Retribution and an idle Holy, one spec a talent tree: Hekili:NewClass): the Paladin
-- kit with Forever's spell data (ranks, costs, cooldowns, cast times and durations from the Forever DB2 at build
-- 1.60.1.70338, wowdb; a cost percentage there is a fraction of the believed maximum, as the Druid's), the seals as
-- player auras (one at a time: a seal's `now` takes the others down), Twist of Light's Echoes, Swift
-- Judgement, Holy Shield's charges spent by blocks on us (`consumedBy`), Hammer of Wrath through the target health
-- gate, mana under the five-second rule (`fsr`), and the default priorities (the wowsims.com packs, translated from
-- wowsims/forever's APLs by tools/wowsims/; no in-game check yet). Research: the class-completion research §3.
-- Judgement does not consume the seal (wowsims/forever judgement.go and the DB2 tooltip); the in-game checkpoint asks.
-- Talents: the DB2's 44 Classic nodes and the Forever-only ones this file reads; a modifier is rank 1's value x the
-- rank, floored at 0, except where the DB2 holds the full-rank value on rank 1 (Benediction, Holy Conduit: each one's
-- comment).
-- The seven seals (Justice, Light and Wisdom too), Judgement's debuff on the target (modelled from the cast, not
-- refreshed by our hits), Templar's Bulwark and Forbearance, and the own procs the Cooldown Manager follows are
-- registered; the Justice sets' 5-piece bonuses read as set_bonus.
-- Unmodelled: Seal of Fury's absorb (the same spell id as the seal, tagged: no id of its own), the seals' attack
-- speed and per-hit effects, Reckoning's and Vengeance's gains (our own hits and crits are unseen), the Echoes'
-- gains (the belief holds them from the aura read).
-- Credits: Hekili (registration API and pack format; `mainhand_remains` follows Hekili's Classic Warrior profile,
-- origin/classic:Classic/Warrior.lua, as Hekili_Warrior/Warrior.lua has it). wowsims/forever (MIT,
-- ui/specs/paladin/*/apls/*.apl.json and sim/paladin/) is the reference for the priorities and the seal, Echo,
-- Judgement and Holy Shield rules; no code is copied.

local Hekili = Hekili -- State expressions run in the simulation's environment.
local Facade = Hekili.Client
local UnitClassBase, IsSpellUsable = Facade.UnitClassBase, Facade.C_Spell.IsSpellUsable
local L = Hekili:GetLocale("Hekili_Paladin")

if UnitClassBase("player") ~= "PALADIN" then
    return
end

local state = Hekili.State
local min, max = math.min, math.max
local RIGHTEOUS_FURY = { 25780, 407627 } -- 407627: the rune's (D4: registered, inert unless learned)

-- The class kit and one spec a talent tree (ids the core's: Holy 100021, unsupported; Protection 100022, Retribution
-- 100023; the client's one pseudo-spec, 1486, only keys the legacy profile the core migrates). Icons: the DB2 tabs'.
local spec = Hekili:NewClass("PALADIN", {
    specs = {
        { key = "holy", name = L["Holy"], tree = 1, icon = 135920, role = "healer", unsupported = true },
        {
            key = "protection",
            name = L["Protection"],
            tree = 2,
            icon = 135893,
            role = "tank",
            supportsLeveling = true,
            recoveryDisplay = {
                upkeep = { action = "righteous_fury", ranks = RIGHTEOUS_FURY },
                below = 80,
                spells = { holy_light = true, flash_of_light = true },
                selfCast = {
                    holy_light = true,
                    flash_of_light = true,
                    lay_on_hands = true,
                    blessing_of_freedom = true,
                    cleanse = true,
                    purify = true,
                },
                combat = {
                    holy_light = true,
                    flash_of_light = true,
                    lay_on_hands = true,
                    templars_bulwark = true,
                    divine_protection = true,
                    divine_shield = true,
                    healing_potion = true,
                    healthstone = true,
                },
            },
            package = "Protection (wowsims.com)",
        },
        {
            key = "retribution",
            name = L["Retribution"],
            tree = 3,
            icon = 135873,
            role = "attack",
            package = "Retribution (wowsims.com)",
            movement = true, -- the pack reads toggle.movement: the opener's move reaches the Judgement chain (R5/R12)
        },
    },
})
if not spec then
    return
end

-- Rank IDs, lowest first (the DB2's), and each rank's mana cost where it is flat.
local SEAL_OF_COMMAND = { 20375, 20915, 20918, 20919, 20920 }
local SEAL_OF_COMMAND_COST = { 65, 110, 140, 180, 210 }
local SEAL_OF_RIGHTEOUSNESS = { 20154, 21084, 20287, 20288, 20289, 20290, 20291, 20292, 20293 }
local SEAL_OF_RIGHTEOUSNESS_COST = { 20, 20, 40, 60, 90, 120, 140, 170, 200 }
local SEAL_OF_THE_CRUSADER = { 21082, 20162, 20305, 20306, 20307, 20308 }
local SEAL_OF_THE_CRUSADER_COST = { 25, 40, 65, 90, 125, 160 }
local SEAL_OF_FURY = { 1311649, 1311656, 20163, 20419, 20421, 20422, 20423 } -- Forever's; ranks 1-2 Forever-only
local SEAL_OF_FURY_COST = { 40, 60, 90, 120, 140, 170, 200 }
-- The other three seals (wowsims's data, the pin's spells_auto_gen: Justice 13% of the base mana, Light and Wisdom flat).
local SEAL_OF_JUSTICE = { 20164 }
local SEAL_OF_JUSTICE_COST = { 0.13 }
local SEAL_OF_LIGHT = { 20165, 20347, 20348, 20349 }
local SEAL_OF_LIGHT_COST = { 110, 140, 180, 210 }
local SEAL_OF_WISDOM = { 20166, 20356, 20357 }
local SEAL_OF_WISDOM_COST = { 135, 170, 200 }
local JUDGEMENT = { 20271 }
local SWIFT_JUDGEMENT = { 1310994 }
local BASE_MANA = 1512 -- a fraction cost is of base mana (wowsims's ExtraClassBaseStats, level 60; Spec.lua)
local HAMMER_OF_WRATH = { 24275, 24274, 24239 }
local HAMMER_OF_WRATH_COST = { 295, 360, 425 }
local HOLY_STRIKE = { 679, 678, 1866, 680, 2495, 5569, 10332, 10333 }
local HOLY_STRIKE_COST = { 5, 9, 12, 14, 16, 17, 19, 20 }
local CONSECRATION = { 26573, 20116, 20922, 20923, 20924 }
local CONSECRATION_COST = { 135, 235, 320, 435, 565 }
-- The Undead/Demon ranks, then the ranks that hit any target (Retribution skill line); the highest known is cast.
local EXORCISM = { 879, 5614, 5615, 10312, 10313, 10314, 415068, 415069, 415070, 415071, 415072, 415073 }
local EXORCISM_ANY = 7 -- 415068's place in EXORCISM: the first rank that hits any target
local UNDEAD_DEMON = { "undead", "demon" }
local ANY_TYPE = { "any" } -- usable_on: a living attackable target of any type
local EXORCISM_COST = { 85, 135, 180, 235, 285, 345, 85, 135, 180, 235, 285, 345 }
local HOLY_SHOCK = { 1311606, 20473, 20929, 20930 } -- rank 1 Forever-only
local HOLY_SHOCK_COST = { 160, 225, 275, 325 }
-- Four ranks, from the owner's in-game tooltips (2026-11-06; in game beats wowsims and the DB2): 100 / 150 / 195 / 240
-- mana, learned at 30 / 40 / 50 / 60. Rank 4 (1239570, build 70755) is in wowsims after our pin (041cd46cec); DB2
-- 70707's three-rank 150 / 195 / 240 ladder at 40 / 50 / 60 lacks it.
local HOLY_SHIELD = { 20925, 20927, 20928, 1239570 }
local HOLY_SHIELD_COST = { 100, 150, 195, 240 }
local DEVOTION_AURA = { 465, 10290, 643, 10291, 1032, 10292, 10293 }
local RETRIBUTION_AURA = { 7294, 10298, 10299, 10300, 10301 }
-- Lane A (coverage; the pin's sim/paladin/spell_data_auto_gen.go ladders, costs and cooldowns from its spells_auto_gen.go).
local HOLY_LIGHT = { 635, 639, 647, 1026, 1042, 3472, 10328, 10329, 25292 }
local HOLY_LIGHT_COST = { 35, 60, 110, 190, 275, 365, 465, 580, 660 }
local FLASH_OF_LIGHT = { 19750, 19939, 19940, 19941, 19942, 19943 }
local FLASH_OF_LIGHT_COST = { 35, 50, 70, 90, 115, 140 }
local LAY_ON_HANDS = { 633, 2800, 10310 }
local LAY_ON_HANDS_MANA = { [633] = 0, [2800] = 250, [10310] = 550 }
local HOLY_WRATH = { 2812, 10318 }
local HOLY_WRATH_COST = { 645, 805 }
local HAMMER_OF_JUSTICE = { 853, 5588, 5589, 10308 }
local HAMMER_OF_JUSTICE_COST = { 30, 50, 75, 100 }
local BLESSING_OF_PROTECTION = { 1022, 5599, 10278 }
local BLESSING_OF_PROTECTION_COST = { 25, 45, 0.07 } -- rank 3 is 7% of base mana
local BLESSING_OF_SACRIFICE = { 6940, 20729 }
local BLESSING_OF_SACRIFICE_COST = { 80, 100 }
local DIVINE_SHIELD = { 642, 1020 }
local DIVINE_SHIELD_COST = { 75, 110 }
local DIVINE_PROTECTION = { 498, 5573 }
local DIVINE_PROTECTION_COST = { 15, 35 }
-- Turn Evil (talent 1328370) overrides the three Turn Undead ranks with its own (1328374, 1328373, 1328372: same costs)
local TURN_UNDEAD = { 2878, 5627, 10326, 1328374, 1328373, 1328372 }
local REPENTANCE = { 20066 }
local TURN_UNDEAD_COST = { 35, 50, 75, 35, 50, 75 }
local LIGHTS_VIGIL = { 1310911, 1311590, 1311595 }
local LIGHTS_VIGIL_COST = { 730, 1000, 1340 }

local function rest(ids)
    local out = {}
    for i = 2, #ids do
        out[#out + 1] = ids[i]
    end
    return out
end

-- The highest known rank of a rank list, from the belief's spellbook: the same answer in the sim's `state`
-- environment and in a `now` handler's (event-facade spec §12a).
local knownRank = state.knownRank

local function knows(ids)
    return function()
        return knownRank(ids) > 0
    end
end

local function byRank(values, ids)
    return values[knownRank(ids)] or values[1]
end

-- Usable now, or only short of mana, by the plain read (Hammer of Wrath's health gate).
local function reactive(ids)
    local r = knownRank(ids)
    if r == 0 then
        return false
    end
    local usable, noMana = IsSpellUsable(ids[r])
    return usable == true or noMana == true
end

-- The seals. Unsealed Wrath's Echoes (hotfix 113554; the talent keeps Twist of Light's 1310735) come from our landed
-- hits, not the seal swap: the `unsealed_wrath` reaction (below) stores them.
local SEALS = {
    "seal_of_command",
    "seal_of_righteousness",
    "seal_of_the_crusader",
    "seal_of_fury",
    "seal_of_justice",
    "seal_of_light",
    "seal_of_wisdom",
}

-- A seal cast's effect (the `now` and the `handler`, two closures so each gets its own environment): the other seal up
-- goes down.
local function sealCast(key)
    return function()
        for i = 1, #SEALS do
            local other = SEALS[i]
            if other ~= key and buff[other].up then
                removeBuff(other)
            end
        end
        applyBuff(key)
    end
end

-- Benediction (20101 aura 108 misc 14, the cost, base -10 on the rank-1 spell only; its class mask covers every cost
-- here but Hammer of Wrath's): 2% less a rank (wowsims's log of the 5/5 build: Seal of Command 151.2 = 210 x 0.8 x 0.9,
-- Holy Strike 18). Written out in each cost: a cost function runs in the state's environment, a helper would not.
-- Holy Conduit (1237268 aura 108 misc 14, base -40 on Consecration's, Hammer of Wrath's and Exorcism's class mask
-- bits; 2 ranks in wowsims's tree): 20% less a rank (wowsims's log of the 2/2 build: Consecration 339 of 565).
local function conduitCost(costs, ids)
    return function()
        return byRank(costs, ids) * (1 - 0.2 * talent.holy_conduit.rank) * (1 - 0.02 * talent.benediction.rank)
    end
end

-- The seals' multiplier (Unsealed Wrath has no cost cut since hotfix 113554), given the caller's `talent` (the state's:
-- a cost function runs in the state's environment, this helper in the file's).
local function sealMult(t)
    return 1 - 0.02 * t.benediction.rank
end

local function sealCost(costs, ids)
    return function()
        local c = byRank(costs, ids)
        return c < 1 and c or c * sealMult(talent) -- a percent of base: its cut is the cost modifier below
    end
end

local function seal(key, ids, costs)
    return {
        id = ids[1],
        copy = rest(ids),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = sealCost(costs, ids),
        spendType = "mana",

        startsCombat = false,
        known = knows(ids),

        now = sealCast(key),
        handler = sealCast(key),
    }
end

-- A self-buff with no other effect (the auras, Righteous Fury, Divine Favor).
local function selfBuff(key, ids, extra)
    local a = {
        id = ids[1],
        copy = #ids > 1 and rest(ids) or nil,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        startsCombat = false,
        known = knows(ids),

        now = function()
            applyBuff(key)
        end,
        handler = function()
            applyBuff(key)
        end,
    }
    for k, v in pairs(extra or {}) do
        a[k] = v
    end
    return a
end

-- Reverence (1310899): 15/30% of the spirit regen while casting by rank (wowsims's curve, e5a9cd2a2d: 2 ranks).
local REVERENCE = { 0.15, 0.3 }

-- The five-second rule (C3): spirit and mp5 regen per second, the declared starting point the out-of-combat read and
-- the in-combat calibration replace, as wowsims's e4ef929e54 logs measure them at 60: Retribution 11.9 spirit + 5.1
-- casting = 17.0 outside (Reverence 2/2's share is the 5.1: the share below is the static share those parts hold; was
-- 13.65 + 8.25 before its gear lost the Soulforge pieces), Protection 0 while casting and 16.5 outside (was 17.38). Forever's Spirit regen is `6.25 + Spirit/8` a second for every class
-- (wowsims mana.go:75-76), not Classic's formula. Holy Shock known (the Holy Shock build, a Retribution spec on its own
-- gear): its own e4ef929e54 log, 2.513 a 0.1 s tick outside, 0.754 casting: 17.59 spirit + 7.54 casting (was
-- Retribution's 11.9 / 5.1).
-- state.spec: the functions run in the state's environment (the file's `spec` is the class). The core resolves them
-- at the build, before its talent walk, so the Holy Shock build is told by the spellbook (knownRank), not talent.*.
spec:RegisterResource(Enum.PowerType.Mana, nil, nil, {
    fsr = {
        spirit = function()
            if state.spec.retribution and knownRank(HOLY_SHOCK) > 0 then
                return 17.59
            end
            return state.spec.retribution and 11.9 or 16.5
        end,
        mp5 = function()
            if state.spec.retribution and knownRank(HOLY_SHOCK) > 0 then
                return 7.54
            end
            return state.spec.retribution and 5.1 or 0
        end,
        share = function() -- Reverence's rank (the belief reads it after its talent walk), never the spec
            return REVERENCE[talent.reverence.rank] or 0
        end,
    },
    base = BASE_MANA,
})

-- Talents: { talent tree (1 Holy, 2 Protection, 3 Retribution: the dominant tree picks the spec), rank 1's spell, max
-- rank }: Forever's tree as wowsims/forever's ui/sim/talents/trees/paladin.json lists it (tools/wowsims/talents.lua
-- writes it; tests/Forever/talent_trees_spec.lua checks it and the spec detection over it). A key is Classic's where the
-- talent exists there (code reads `talent.<key>.rank`), else the snake_case of the node's name.
spec:RegisterTalents({
    -- Holy (tree 1)
    spiritual_focus = { 1, 20205, 5 },
    divine_strength = { 1, 20262, 5 },
    healing_light = { 1, 20237, 3 },
    reverence = { 1, 1310899, 2 },
    improved_seals = { 1, 20224, 5 },
    purifying_power = { 1, 429144, 2 },
    divine_favor = { 1, 20216, 1 },
    illumination = { 1, 20210, 5 },
    holy_conduit = { 1, 1237268, 2 },
    divine_precision = { 1, 1310904, 2 },
    infusion_of_light = { 1, 426065, 2 },
    oath_of_light = { 1, 1328548, 1 },
    consecrated_ground = { 1, 1310905, 2 },
    holy_shock = { 1, 1311606, 1 },
    boundless_light = { 1, 1328550, 2 },
    holy_power_talent = { 1, 5923, 5 },
    lights_vigil = { 1, 1310911, 1 },
    -- Protection (tree 2)
    divine_intellect = { 2, 20257, 5 },
    redoubt = { 2, 20127, 5 },
    precision = { 2, 20189, 3 },
    guardians_favor = { 2, 20174, 2 },
    sacred_duty = { 2, 1224697, 2 },
    templars_bulwark = { 2, 1311015, 1 },
    improved_hammer_of_justice = { 2, 20487, 3 },
    shield_specialization = { 2, 20150, 2 },
    toughness = { 2, 20143, 5 },
    swift_judgement = { 2, 1310994, 1 },
    improved_righteous_fury = { 2, 20468, 3 },
    anticipation = { 2, 20096, 5 },
    stoicism = { 2, 1328546, 2 },
    holy_shield = { 2, 20925, 1 },
    reckoning = { 2, 20177, 5 },
    iron_creed = { 2, 1311034, 3 },
    shieldsworn = { 2, 1328544, 1 }, -- hotfix 113554
    -- Retribution (tree 3)
    deflection = { 3, 20060, 5 },
    benediction = { 3, 20101, 5 },
    improved_judgement = { 3, 25956, 2 },
    conviction = { 3, 20117, 3 },
    sanctified_judgement = { 3, 1311074, 3 },
    vindication = { 3, 9452, 3 },
    unyielding_faith = { 3, 9453, 2 },
    seal_of_command = { 3, 20375, 1 },
    pursuit_of_justice = { 3, 26022, 2 },
    eye_for_an_eye = { 3, 9799, 2 },
    sacred_arbiter = { 3, 1311087, 1 },
    two_handed_weapon_specialization = { 3, 20111, 3 },
    turn_evil = { 3, 1328370, 2 },
    repentance = { 3, 20066, 1 },
    vengeance = { 3, 20049, 3 },
    champion_of_the_light = { 3, 1311084, 5 }, -- hotfix 113554 (replaces Instrument of Law)
    twist_of_light = { 3, 1310735, 1 },
})

-- The Justice sets (wowsims item_sets.go; the item ids the pin's db.json ships, four pieces each so far): only the
-- 5-piece bonuses move a recommendation's timing (a hidden aura each, read through set_bonus); the 2- and 4-piece
-- bonuses are stats, nothing the belief models.
-- Benediction's -2% a rank and Purifying Power's -10% a rank on the percent-of-base costs (Seal of Justice, Cleanse,
-- Purify, Judgement, Blessing of Freedom, Righteous Fury): each cost is rounded whole, then cut unrounded (wowsims mana.go
-- newManaCost, then spell.go ApplyCostModifiers; L1793 item 1). The flat costs take theirs in their own function.
spec:RegisterCostMod({
    talent = "benediction",
    pct = { -0.02, -0.04, -0.06, -0.08, -0.1 },
    spells = { 20164, 4987, 1152, 20271, 1044, 25780 },
})
spec:RegisterCostMod({
    talent = "purifying_power",
    pct = { -0.1, -0.2 },
    spells = { 4987, 1152 },
})
spec:RegisterGear("justice_battlegear", 273908, 273909, 273910, 273911)
spec:RegisterGear("justice_armor", 273912, 273913, 273914, 273915)
spec:RegisterGear("justice_battleplate", 273916, 273917, 273918, 273919)
spec:RegisterSetBonus("justice_battlegear_5pc", 1301702)
spec:RegisterSetBonus("justice_armor_5pc", 1301694)
spec:RegisterSetBonus("justice_battleplate_5pc", 1301697)

spec:RegisterAuras({
    justice_battlegear_5pc = { id = 1301702, duration = 3600, max_stack = 1 },
    justice_armor_5pc = { id = 1301694, duration = 3600, max_stack = 1 },
    justice_battleplate_5pc = { id = 1301697, duration = 3600, max_stack = 1 },
    -- The seals are one family (L727): the Cooldown Manager's Seals entry says a seal is up or none is, our last seal
    -- cast says which.
    seal_of_command = { id = 20375, copy = rest(SEAL_OF_COMMAND), duration = 30, max_stack = 1, family = "seals" },
    seal_of_righteousness = {
        id = 20154,
        copy = rest(SEAL_OF_RIGHTEOUSNESS),
        duration = 30,
        max_stack = 1,
        family = "seals",
    },
    seal_of_the_crusader = {
        id = 21082,
        copy = rest(SEAL_OF_THE_CRUSADER),
        duration = 30,
        max_stack = 1,
        family = "seals",
    },
    seal_of_fury = { id = 1311649, copy = rest(SEAL_OF_FURY), duration = 30, max_stack = 1, family = "seals" },
    -- Unsealed Wrath's Echoes (hotfix 113554 rows: 15 s, 3 stacks): each landed white swing stores a stack of the
    -- active seal's; a swing under another seal spends them (the `unsealed_wrath` reaction, below).
    echo_of_command = { id = 1311703, duration = 15, max_stack = 3 },
    echo_of_righteousness = { id = 1311704, duration = 15, max_stack = 3 },
    echo_of_fury = { id = 1311701, duration = 15, max_stack = 3 },
    echo_of_justice = { id = 1311705, duration = 15, max_stack = 3 },
    echo_of_light = { id = 1328198, duration = 15, max_stack = 3 },
    echo_of_wisdom = { id = 1328206, duration = 15, max_stack = 3 },
    seal_of_justice = { id = 20164, duration = 30, max_stack = 1, family = "seals" },
    seal_of_light = { id = 20165, copy = rest(SEAL_OF_LIGHT), duration = 30, max_stack = 1, family = "seals" },
    seal_of_wisdom = { id = 20166, copy = rest(SEAL_OF_WISDOM), duration = 30, max_stack = 1, family = "seals" },
    -- Holy Shield: +30% block for 10 s, 4 charges (DB2 ProcCharges), each block or partial block on us spending one.
    holy_shield = {
        id = 20925,
        copy = rest(HOLY_SHIELD),
        duration = 10,
        max_stack = 4,
        consumedBy = { BLOCK = true, BLOCKED = true },
    },
    righteous_fury = { id = 25780, copy = { 407627 }, duration = 1800, max_stack = 1 },
    -- Post-resurrection legacy buff: actual duration is observed; one minute at its first rank.
    the_quick_and_the_dead = { id = 1262310, duration = 60, max_stack = 1 },
    retribution_aura = { id = 7294, copy = rest(RETRIBUTION_AURA), duration = 3600, max_stack = 1 },
    divine_favor = { id = 20216, duration = 3600, max_stack = 1 },
    -- Consecration's area aura on the target (1280353, DB2: 0.6 s on area enemies, refreshed by each 1 s tick; the one
    -- the client and wowsims's log show; 1310905 "Consecrated Ground" targets the caster): its 8 s and the 0.6 s tail
    -- (wowsims consecration.go), modelled from our cast (target auras are unreadable in combat).
    consecrated_ground = { id = 1280353, duration = 8.6, max_stack = 1 },

    -- Judgement's debuffs on the target (B4; wowsims judgement.go, buffs/paladin.go): 40 s (Justice's 10 s, Fury's taunt
    -- 3 s), refreshed by our landed white swings and Windfury Totem's strike, not by Holy Strike, Seal of Command or the
    -- judgements (wowsims 016f21f4cc, EV-0117; unmodelled: Judgement itself recasts every cooldown).
    judgement_of_the_crusader = {
        id = 20188,
        copy = { 20300, 20301, 20302, 20303, 21183 },
        duration = 40,
        max_stack = 1,
    },
    judgement_of_light = { id = 20185, copy = { 20344, 20345, 20346 }, duration = 40, max_stack = 1 },
    judgement_of_wisdom = { id = 20186, copy = { 20354, 20355 }, duration = 40, max_stack = 1 },
    judgement_of_justice = { id = 20184, duration = 10, max_stack = 1 },
    judgement_of_fury = { id = 20232, duration = 3, max_stack = 1 },
    -- Vindication's debuff on the target (B5, wowsims talents_retribution.go:82-121: -AP, 30 s, a proc: observed only).
    vindication = { id = 440667, duration = 30, max_stack = 1 },

    -- Templar's Bulwark's absorb (B2, 8 s) and the Forbearance it brings (60 s less Sacred Duty's 5 s a rank).
    templars_bulwark = { id = 1311015, duration = 8, max_stack = 1 },
    forbearance = { id = 25771, duration = 60, max_stack = 1 },

    -- Own procs (B3; no priority reads them, the Cooldown Manager follows their presence): Vengeance 5 stacks 30 s, a
    -- landed crit; Redoubt 5 charges 10 s, one a block; Reckoning's stored extra attacks (4, until the next swing).
    vengeance = { id = 20050, duration = 30, max_stack = 5 },
    -- (the Cooldown Manager's items link the talents' own IDs too: 20127, 20177)
    redoubt = {
        id = 20128,
        copy = { 20127 },
        duration = 10,
        max_stack = 5,
        consumedBy = { BLOCK = true, BLOCKED = true },
    },
    reckoning = { id = 1326084, copy = { 20177 }, duration = 3600, max_stack = 4 },
    -- Iron Creed's 6 s (-2/4/6% damage taken, a Holy Strike under Righteous Fury) and Shieldsworn's spell block (6 s, every
    -- Holy Strike with a shield, landed or avoided: wowsims 61607b27d7): modelled from our Holy Strikes, neither has a Cooldown Manager item.
    iron_creed = { id = 1311033, copy = { 440668 }, duration = 6, max_stack = 1 }, -- 440668: the ID the Cooldown Manager links
    shieldsworn_block = { id = 1328551, duration = 6, max_stack = 1 },

    -- The Paladin auras (B6, one up at a time), Consecration's ranks (B7: wowsims registers each rank's dot; the Cooldown
    -- Manager's item links the five and 1280345-1280349 as a self aura: needs in-game check which unit shows it), the
    -- Holy-only auras (B8, Holy is unsupported) and the blessings (item 200215 etc.: our own casts, no priority reads them).
    paladin_autoattacking = { duration = 3600, max_stack = 1 },
    sanctity_aura = { id = 20218, duration = 3600, max_stack = 1 },
    devotion_aura = { id = 465, copy = rest(DEVOTION_AURA), duration = 3600, max_stack = 1 },
    concentration_aura = { id = 19746, duration = 3600, max_stack = 1 },
    fire_resistance_aura = { id = 19891, copy = { 19899, 19900 }, duration = 3600, max_stack = 1 },
    frost_resistance_aura = { id = 19888, copy = { 19897, 19898 }, duration = 3600, max_stack = 1 },
    shadow_resistance_aura = { id = 19876, copy = { 19895, 19896 }, duration = 3600, max_stack = 1 },
    consecration = {
        id = 26573,
        copy = { 20116, 20922, 20923, 20924, 1280345, 1280346, 1280347, 1280348, 1280349 },
        duration = 8,
        max_stack = 1,
    },
    infusion_of_light = { id = 437063, duration = 15, max_stack = 1 },
    lights_vigil = { id = 1310909, copy = { 1311593, 1311597 }, duration = 30, max_stack = 1 },
    lights_vigil_target = { id = 1310910, copy = { 1311594, 1311599 }, duration = 30, max_stack = 1 },
    oath_of_light = { id = 1328548, duration = 300, max_stack = 1 },
    blessing_of_might = {
        id = 19740,
        copy = { 19834, 19835, 19836, 19837, 19838, 25291, 25782, 25916 },
        duration = 300,
        max_stack = 1,
    },
    blessing_of_kings = { id = 20217, copy = { 25898 }, duration = 300, max_stack = 1 },
    blessing_of_wisdom = {
        id = 19742,
        copy = { 19850, 19852, 19853, 19854, 25290, 25894, 25918 },
        duration = 300,
        max_stack = 1,
    },
    blessing_of_salvation = { id = 1038, copy = { 25895 }, duration = 300, max_stack = 1 },
    blessing_of_light = { id = 19977, copy = { 19978, 19979, 25890 }, duration = 300, max_stack = 1 },
    -- The auras the abilities above apply, under the spell IDs the Cooldown Manager links (cdm/paladin.lua). One aura
    -- a Cooldown Manager item: Divine Shield's and Divine Protection's invulnerability is one (the item links both).
    hammer_of_justice = {
        id = 1324513,
        copy = { 1324515, 1324516, 1324517 },
        duration = 6,
        max_stack = 1,
        debuffRetryDelay = 30,
    },
    turn_undead = { id = 1324543, copy = { 1324545, 1324546 }, duration = 20, max_stack = 1 },
    repentance = { id = 1324538, duration = 6, max_stack = 1 },
    blessing_of_freedom = { id = 1044, duration = 10, max_stack = 1 },
    blessing_of_sacrifice = { id = 6940, copy = { 20729 }, duration = 30, max_stack = 1 },
    blessing_of_protection = { id = 1022, copy = { 5599, 10278 }, duration = 10, max_stack = 1 },
    divine_shield = { id = 642, copy = { 1020, 498, 5573 }, duration = 12, max_stack = 1 },
    voice_of_truth = { id = 1310897, duration = 6, max_stack = 1 },
    -- Librams (item_librams.go; item-level, external: the walk reads them where plain).
    holy_alacrity = { id = 449982, duration = 10, max_stack = 1 },
    tenets_of_the_silver_hand = { id = 1302545, duration = 3600, max_stack = 1 },
})

-- Purifying Power's cooldown cut by rank (429144's second curve {-17, -33} %): Exorcism and Holy Wrath.
local PURIFYING_POWER_CD = { [0] = 0, 0.17, 0.33 }

-- Any seal up: Judgement's requirement.
-- Sanctified Judgement (1311074, Forever-only, 3 ranks: a 33/66/100% chance to return 20/40/60%): 60% of the seal's
-- base cost x (2 - its cost multiplier) at 3/3 (tests/Forever/wowsims/paladin_retribution.log:439, Seal of Command
-- up: "Gained 161.280 mana from {SpellID: 1311074}" = 210 x 1.28 x 0.6); below 3/3 the belief and the forecast count
-- the mean (chance x refund), as the Rogue's Relentless Strikes.
-- The fourth field is the judgement debuff the seal puts on the target (none for Command and Righteousness: damage only).
local SEAL_BASE = {
    { "seal_of_command", SEAL_OF_COMMAND_COST, SEAL_OF_COMMAND },
    { "seal_of_righteousness", SEAL_OF_RIGHTEOUSNESS_COST, SEAL_OF_RIGHTEOUSNESS },
    { "seal_of_the_crusader", SEAL_OF_THE_CRUSADER_COST, SEAL_OF_THE_CRUSADER, "judgement_of_the_crusader" },
    { "seal_of_fury", SEAL_OF_FURY_COST, SEAL_OF_FURY, "judgement_of_fury" },
    { "seal_of_justice", SEAL_OF_JUSTICE_COST, SEAL_OF_JUSTICE, "judgement_of_justice" },
    { "seal_of_light", SEAL_OF_LIGHT_COST, SEAL_OF_LIGHT, "judgement_of_light" },
    { "seal_of_wisdom", SEAL_OF_WISDOM_COST, SEAL_OF_WISDOM, "judgement_of_wisdom" },
}
local SJ_CHANCE = { 0.33, 0.66, 1 }
local SJ_REFUND = { 0.2, 0.4, 0.6 }
-- A Judgement's cast effect, Judgement's and Swift Judgement's (the `now` and the `handler`, two closures so each gets
-- its own environment): the seal's judgement debuff, and the refund.
local function judgementCast()
    return function()
        for i = 1, #SEAL_BASE do
            local s = SEAL_BASE[i]
            if buff[s[1]].up then
                if s[4] then
                    applyDebuff("target", s[4])
                end
                local sj = talent.sanctified_judgement.rank
                if sj > 0 then
                    local mult = sealMult(talent)
                    local cost = byRank(s[2], s[3])
                    -- the mean: chance 33/66/100% x refund 20/40/60% (the talent's two curves, wowsims's spell data)
                    gain((cost < 1 and cost * BASE_MANA or cost) * (2 - mult) * SJ_CHANCE[sj] * SJ_REFUND[sj], "mana") -- Justice's is a fraction
                end
                return
            end
        end
    end
end

spec:RegisterStateExpr("seal_up", function()
    return buff.seal_of_command.up
        or buff.seal_of_righteousness.up
        or buff.seal_of_the_crusader.up
        or buff.seal_of_fury.up
        or buff.seal_of_justice.up
        or buff.seal_of_light.up
        or buff.seal_of_wisdom.up
end)

-- Keep single-target recovery on its existing breakable-control policy.
local function noCrowdControl(ranks, auraID, t)
    local count = Facade.DebuffCount(auraID, t)
    return count == 0 or count == nil and knownRank(ranks) == 0
end

local function paladinNoBreakableControl()
    local t = Facade.GetTime()
    return noCrowdControl(TURN_UNDEAD, 1324543, t) and noCrowdControl(REPENTANCE, 1324538, t)
end

-- Holy Strike is a ten-second cooldown before Shieldsworn. Give two real attempts time to land
-- on the same enemy before escalating to Judgement of Fury. Judgement and Swift Judgement both
-- unleash the active seal; classify the real cast from the player's observed seal at cast time.
local recovery
do
    local builders = {}
    for _, ranks in ipairs({ HOLY_STRIKE, EXORCISM, HAMMER_OF_WRATH }) do
        for _, id in ipairs(ranks) do
            builders[id] = true
        end
    end
    local shocks = {}
    for _, id in ipairs(HOLY_SHOCK) do
        shocks[id] = true
    end
    -- Holy Shock shares a cast ID between healing and damage. Only count a named hostile cast
    -- when a heal on the player, a group member, a pet, focus or mouseover cannot explain it.
    local function distinctRecipient(unit, name)
        local exists = Facade.UnitExists(unit)
        if not Facade.issecretvalue(exists) and exists == false or Facade.UnitIsUnit(unit, "target") == true then
            return true
        end
        local recipient = Facade.UnitName(unit)
        return recipient ~= nil and recipient ~= name
    end
    local healTargets = {}
    for _, group in ipairs({ "raid", "party" }) do
        local units = { "player", "pet", "focus", "mouseover" }
        for i = 1, group == "raid" and 40 or 4 do
            units[#units + 1] = group .. i
            units[#units + 1] = group .. "pet" .. i
        end
        healTargets[group] = units
    end
    local function offensiveShock(name)
        if not name or name == "" or name ~= Facade.UnitName("target") then
            return false
        end
        local raid = Facade.IsInRaid()
        if Facade.issecretvalue(raid) or raid == nil then
            return false
        end
        for _, unit in ipairs(healTargets[raid and "raid" or "party"]) do
            if not distinctRecipient(unit, name) then
                return false
            end
        end
        return true
    end
    local function criticalVictim(member)
        local health = Facade.GroupMemberHealthFraction(member)
        return health ~= nil and health > 0 and health <= 0.25
    end

    recovery = Hekili:NewTankRecovery(spec, {
        specKey = "protection",
        window = 15,
        meleeSpell = function()
            return HOLY_STRIKE[knownRank(HOLY_STRIKE)]
        end,
        rangeSpell = function()
            -- Swift itself has a self-only range row. The learned hostile probes cap it at ten yards.
            return JUDGEMENT[knownRank(JUDGEMENT)]
                or knownRank(SWIFT_JUDGEMENT) > 0 and HAMMER_OF_JUSTICE[knownRank(HAMMER_OF_JUSTICE)]
                or HOLY_STRIKE[knownRank(HOLY_STRIKE)]
        end,
        safePack = paladinNoBreakableControl,
        urgentVictim = criticalVictim,
        classifyCast = function(id, name)
            if id == 20271 or id == 1310994 then
                local aura = Facade.C_UnitAuras.GetPlayerAuraBySpellID
                if aura(SEAL_OF_FURY[1]) then
                    return "rescue"
                elseif aura(SEAL_OF_RIGHTEOUSNESS[1]) or aura(SEAL_OF_COMMAND[1]) then
                    return "builder"
                end
            elseif builders[id] or shocks[id] and offensiveShock(name) then
                return "builder"
            end
        end,
    })

    spec:RegisterStateExpr("prot_paladin_loose_target", function()
        local sample = recovery.evidence()
        return sample and sample.loose or false
    end)

    spec:RegisterStateExpr("prot_paladin_recovery_pack", function()
        local sample = recovery.evidence()
        return sample and sample.other or false
    end)

    spec:RegisterStateExpr("prot_paladin_ground_pickup", function()
        local sample = recovery.evidence(true)
        return sample and sample.otherMelee and not sample.criticalOther or false
    end)

    spec:RegisterStateExpr("prot_paladin_loose_melee", function()
        local sample = recovery.evidence()
        return sample and sample.loose and sample.looseMelee or false
    end)

    spec:RegisterStateExpr("prot_paladin_urgent_pickup", function()
        local sample = recovery.evidence()
        return sample and sample.criticalOther or false
    end)

    spec:RegisterStateExpr("prot_paladin_last_resort", function()
        local member = state.prot_paladin_loose_target
        return member
                and debuff.judgement_of_fury.down
                and not Facade.DebuffImmunity("judgement_of_fury", Facade.UnitGUID("target"), Facade.GetTime())
                and (criticalVictim(member) or not state.prot_paladin_urgent_pickup and recovery.lastResort())
            or false
    end)

    local function usableSoon(spell, mana, horizon)
        local action = state.action[spell]
        return action.known and not action.disabled and action.cost <= mana and state.cooldown[spell].remains <= horizon
    end

    local function liveMana()
        return min(state.mana.lo, state.mana.actual_lo or state.mana.lo)
    end

    local function canJudge(mana, horizon)
        return usableSoon("judgement", mana, horizon) or usableSoon("swift_judgement", mana, horizon)
    end

    spec:RegisterStateExpr("prot_paladin_prepare_taunt", function()
        return buff.seal_of_fury.down
            and state.prot_paladin_last_resort
            and canJudge(liveMana() - action.seal_of_fury.cost, gcd.max)
    end)

    spec:RegisterStateExpr("prot_paladin_fury_taunt_ready", function()
        return action.seal_of_fury.known and buff.seal_of_fury.up and state.prot_paladin_last_resort
    end)

    spec:RegisterStateExpr("prot_paladin_judgement_allowed", function()
        -- Fury Judgement also deals Holy damage when the mob is already ours. While off-tanking
        -- (including a boss handoff), damage Judgements are available from a different seal.
        return buff.seal_of_fury.down
            or target.is_dummy
            or state.prot_paladin_last_resort
            or not state.prot_paladin_recovery_pack and recovery.holdingTarget()
    end)

    spec:RegisterStateExpr("prot_paladin_recover_threat", function()
        local sample = recovery.evidence()
        if not sample or not sample.other then
            return false
        end
        local mana, horizon = liveMana(), state.gcd.remains
        if
            sample.otherMelee
            and not sample.criticalOther
            and state.prot_pal_can_consecrate
            and usableSoon("consecration", mana, horizon)
        then
            return false
        end
        if
            sample.criticalOther
            and (
                buff.seal_of_fury.up and canJudge(mana, horizon)
                or usableSoon("seal_of_fury", mana, horizon) and canJudge(mana - action.seal_of_fury.cost, gcd.max)
            )
        then
            return true
        end
        return sample.otherMelee
                and (not sample.criticalOther or sample.criticalMelee)
                and state.weapon.size > 0
                and usableSoon("holy_strike", mana, horizon)
            or usableSoon("holy_shock", mana, horizon)
            or (buff.seal_of_righteousness.up or buff.seal_of_command.up) and canJudge(mana, horizon)
    end)
end

local function plain(value)
    if not Facade.issecretvalue(value) then
        return value
    end
end

local function paladinContext()
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    if instance == "none" or instance == "party" or instance == "scenario" or instance == "raid" then
        return instance
    end
end

-- Only the next real action can depend on the player's health. A forecast cannot know how
-- much a heal will restore, whether it crits, or how much damage will arrive during its cast.
spec:RegisterStateExpr("prot_pal_self_heal", function()
    local heal = state.action[state.this_action]
    return heal ~= nil
        and state.offset == 0
        and state.OnToggleDisplay("defensives")
        and paladinContext() ~= nil
        and not state.paladin_incapacitated
        and buff.casting.down
        and plain(Facade.UnitIsDeadOrGhost("player")) == false
        and plain(Facade.IsMounted()) == false
        and plain(Facade.UnitOnTaxi("player")) == false
        and Hekili:CanSelfCastHelpfulSpell(heal.id)
        and plain(Facade.UnitAffectingCombat("player")) == (combat > 0)
end)

spec:RegisterStateExpr("prot_pal_emergency_heal", function()
    if not state.prot_pal_self_heal then
        return false
    end
    -- Do not spend all mana because a forecast eventually reaches the end of an immunity.
    -- The observed aura represents both Divine Shield and Divine Protection.
    local immunity = Facade.C_UnitAuras.GetPlayerAuraBySpellID(DIVINE_SHIELD[1])
    return not immunity or immunity.expirationTime > 0 and immunity.expirationTime - Facade.GetTime() <= state.gcd.max
end)

local function additionalAttacker()
    for unit in pairs(recovery.plates) do
        if
            plain(Facade.UnitIsUnit(unit, "target")) ~= true
            and plain(Facade.UnitExists(unit)) == true
            and plain(Facade.UnitCanAttack("player", unit)) == true
            and plain(Facade.UnitIsDead(unit)) ~= true
            and plain(Facade.UnitAffectingCombat(unit)) ~= false
        then
            return true
        end
    end
    return false
end

local function startableHeal()
    if not state.prot_pal_self_heal or state.moving then
        return nil
    end
    local heal = state.action[state.this_action]
    if heal.cost <= min(state.mana.lo, state.mana.actual_lo or state.mana.lo) then
        return heal
    end
end

-- Hardcasting interrupts melee and blocks. An active tank needs a full protected casting
-- window. While solo, a quick heal can still be worthwhile against a single ordinary enemy.
local function canCastHeal(large)
    local heal = startableHeal()
    if not heal then
        return false
    end
    if state.combat == 0 then
        return Facade.PlayerEatingOrDrinking() == false
    end
    local pressure = recovery.evidence()
    if pressure and (pressure.loose or pressure.other) then
        return false
    end
    local cast = heal.cast_time
    if state.buff.divine_shield.up and state.buff.divine_shield.remains >= cast then
        return true
    end
    if additionalAttacker() then
        return false
    end
    -- Healing does not break Repentance or Turn Undead. A controlled enemy can give us time
    -- to cast even though it is deliberately ineligible for every hostile recommendation.
    local controlled =
        max(state.debuff.hammer_of_justice.remains, state.debuff.repentance.remains, state.debuff.turn_undead.remains)
    if controlled > 0 and controlled >= cast and Facade.TargetInPlayerCombat() == true then
        return true
    end
    if not state.prot_pal_attack_target then
        return false
    end
    if not state.solo or plain(Facade.IsInRaid()) ~= false then
        return recovery.otherTank()
    end
    return not large and not state.boss and not state.target.is_boss
end

spec:RegisterStateExpr("prot_pal_cast_heal", function()
    return canCastHeal(false)
end)
spec:RegisterStateExpr("prot_pal_big_heal", function()
    return canCastHeal(true)
end)

-- If the pack is entirely ours, a cast at critical health may be the last available way
-- to live through it. The health-gated APL tries the trained instant defenses first.
spec:RegisterStateExpr("prot_pal_desperate_solo_heal", function()
    local heal = startableHeal()
    return heal ~= nil
        and state.prot_pal_solo_immunity
        and additionalAttacker()
        and state.buff.divine_shield.remains < heal.cast_time
end)

-- Against a single solo opponent a stun can buy a full cast. Reserve the mana for both actions.
local function canHealAfterStun(heal, manaLeft)
    return heal.known and not heal.disabled and heal.cost <= manaLeft and Hekili:CanSelfCastHelpfulSpell(heal.id)
end

spec:RegisterStateExpr("prot_pal_stun_to_heal", function()
    if
        not state.OnToggleDisplay("defensives")
        or not state.prot_pal_attack_target
        or not state.prot_pal_solo_immunity
        or state.moving
        or state.paladin_incapacitated
        or state.offset > 0
        or additionalAttacker()
        or Facade.TargetInPlayerCombat() ~= true
        or not target.within10
        or target.outside10
        or debuff.hammer_of_justice.up
        or buff.divine_shield.up
    then
        return false
    end
    local manaLeft = min(mana.lo, mana.actual_lo or mana.lo) - action.hammer_of_justice.cost
    return canHealAfterStun(action.flash_of_light, manaLeft) or canHealAfterStun(action.holy_light, manaLeft)
end)

local function hostileNPC(unit)
    return plain(Facade.UnitExists(unit)) == true
        and plain(Facade.UnitCanAttack("player", unit)) == true
        and plain(Facade.UnitIsDead(unit)) == false
        and plain(Facade.UnitIsPlayer(unit)) == false
end

spec:RegisterStateExpr("prot_pal_attack_target", function()
    local instance = paladinContext()
    if not instance or debuff.repentance.up or debuff.turn_undead.up or not hostileNPC("target") then
        return false
    end
    if target.is_dummy or Facade.TargetInPlayerCombat() == true then
        return true
    end
    -- A deliberately selected idle outdoor enemy can start a pull. Inside an instance,
    -- and once fighting outdoors, require evidence that the selected enemy belongs to our fight.
    return instance == "none"
        and plain(Facade.IsInRaid()) == false
        and (combat == 0 or state.false_start > 0)
        and plain(Facade.UnitAffectingCombat("target")) == false
end)

-- Verified raid trash uses the same mana and ground rules as dungeon trash. On a boss,
-- in an ongoing raid encounter, or with an unreadable raid classification, use the tanked raid priority.
local function raidPriority()
    if paladinContext() ~= "raid" and plain(Facade.IsInRaid()) ~= true then
        return false
    end
    if state.boss or state.target.is_boss or plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) ~= false then
        return true
    end
    local kind, level = plain(Facade.UnitClassification("target")), plain(Facade.UnitLevel("target"))
    return type(level) ~= "number"
        or level <= 0
        or not (kind == "elite" or kind == "rareelite" or kind == "normal" or kind == "rare" or kind == "minus")
end

spec:RegisterStateExpr("prot_pal_raid_prep", function()
    return target.is_dummy or raidPriority()
end)

spec:RegisterStateExpr("prot_pal_sustained", function()
    return state.prot_pal_attack_target and state.prot_pal_raid_prep
end)

spec:RegisterStateExpr("prot_pal_field", function()
    return paladinContext() ~= nil and not target.is_dummy and not raidPriority()
end)

spec:RegisterStateExpr("prot_pal_durable", function()
    local kind = plain(Facade.UnitClassification("target"))
    return boss or target.is_boss or kind == "elite" or kind == "rareelite" or kind == "worldboss"
end)

spec:RegisterStateExpr("prot_pal_self_utility", function()
    return state.offset == 0 and Hekili:CanSelfCastHelpfulSpell(action[state.this_action].id)
end)

-- In group content dispels may be assigned or have encounter-specific consequences.
-- On an ordinary solo outdoor pull the shared aura reader identifies actual removable effects.
spec:RegisterStateExpr("prot_pal_solo_dispel", function()
    return state.solo
        and paladinContext() == "none"
        and plain(Facade.GetNumGroupMembers()) == 0
        and not state.boss
        and not state.target.is_boss
        and state.prot_pal_combat_defense
        and state.prot_pal_attack_target
        and not state.paladin_incapacitated
        and state.prot_pal_self_utility
end)

local function inGroundRange(unit, probe)
    if plain(Facade.C_Spell.IsSpellInRange(probe, unit)) == true then
        return true
    end
    local _, far = Facade.LibRangeCheck:GetRange(unit)
    far = plain(far)
    return type(far) == "number" and far <= 8
end

local function plateInOurFight(unit, victim)
    if plain(Facade.UnitAffectingCombat(unit)) ~= true then
        return false
    end
    local raid = plain(Facade.UnitInRaid(victim))
    return plain(Facade.UnitIsUnit(victim, "player")) == true
        or plain(Facade.UnitIsUnit(victim, "pet")) == true
        or plain(Facade.UnitInParty(victim)) == true
        or type(raid) == "number" and raid > 0
        or type(plain(Facade.UnitThreatSituation("player", unit))) == "number"
        or type(plain(Facade.UnitThreatSituation("pet", unit))) == "number"
end

-- Consecration is centered on the caster. Two readable plates establish two enemies in its radius
-- even if their relationship to the selected target is hidden. Stay with an existing nearby fight.
local packTime, packTarget, packNearby
local function groundPack()
    local t, key = Facade.GetTime(), Facade.TargetMemoryKey()
    if t == packTime and key == packTarget then
        return packNearby
    end
    packTime, packTarget = t, key
    packNearby = false
    if plain(Facade.UnitAffectingCombat("player")) ~= true then
        return false
    end
    local probe = HOLY_STRIKE[knownRank(HOLY_STRIKE)] or 6603
    local selectedNearby = hostileNPC("target") and inGroundRange("target", probe)
    local selectedEngaged = Facade.TargetInPlayerCombat() == true
    local foughtNearby = selectedNearby and selectedEngaged
    local count, distinct = 0, false
    for unit, victim in pairs(recovery.plates) do
        if hostileNPC(unit) and inGroundRange(unit, probe) then
            local same = plain(Facade.UnitIsUnit(unit, "target"))
            count, distinct = count + 1, distinct or same == false
            foughtNearby = foughtNearby or same == true and selectedEngaged or plateInOurFight(unit, victim)
            if foughtNearby and (count >= 2 or selectedNearby and distinct) then
                packNearby = true
                break
            end
        end
    end
    return packNearby
end

spec:RegisterStateExpr("prot_pal_pack", function()
    return state.max_targets ~= 1 and state.toggle.mode ~= "single" and groundPack()
end)

spec:RegisterStateExpr("prot_pal_tanking", function()
    if target.is_dummy then
        return true
    end
    local role = Facade.GroupRole("player")
    if recovery.otherTank() then
        return false
    end
    if solo and not (state.prot_pal_raid_prep and role == "TANK") then
        return equipped.shield and (state.prot_pal_durable or state.prot_pal_pack)
    end
    if role ~= "TANK" and role ~= "NONE" then
        return false
    end
    return role == "TANK" or recovery.holdingTarget()
end)

-- Righteous Fury is self upkeep for Protection, including an assigned off-tank.
-- An unassigned group can use the selected spec unless someone else has the tank assignment.
spec:RegisterStateExpr("prot_pal_maintain_fury", function()
    if
        not paladinContext()
        or buff.righteous_fury.up
        or buff.casting.up
        or state.paladin_incapacitated
        or plain(Facade.UnitIsDeadOrGhost("player")) ~= false
        or plain(Facade.IsMounted()) ~= false
        or plain(Facade.UnitOnTaxi("player")) ~= false
        or plain(Facade.UnitHasVehicleUI("player")) ~= false
        or action.righteous_fury.cost > min(mana.lo, mana.actual_lo or mana.lo)
        or Facade.C_UnitAuras.GetPlayerAuraBySpellID(RIGHTEOUS_FURY[1])
    then
        return false
    end
    local inCombat = plain(Facade.UnitAffectingCombat("player"))
    if inCombat == nil or not inCombat and Facade.PlayerEatingOrDrinking() ~= false then
        return false
    end
    local grouped = plain(Facade.IsInGroup())
    if grouped == false then
        return true
    end
    local ownRole = Facade.GroupRole("player")
    if grouped ~= true or ownRole ~= "TANK" and ownRole ~= "NONE" then
        return false
    end
    if ownRole == "TANK" then
        return true
    end
    local raid, count = plain(Facade.IsInRaid()), plain(Facade.GetNumGroupMembers())
    if raid == nil or type(count) ~= "number" or count < 1 or recovery.otherTank() then
        return false
    end
    local prefix = raid and "raid" or "party"
    for i = 1, raid and count or count - 1 do
        if Facade.GroupRole(prefix .. i) == "TANK" then
            return false
        end
    end
    return true
end)

spec:RegisterStateExpr("prot_pal_aura_missing", function()
    return buff.retribution_aura.down
        and buff.devotion_aura.down
        and buff.concentration_aura.down
        and buff.sanctity_aura.down
        and buff.fire_resistance_aura.down
        and buff.frost_resistance_aura.down
        and buff.shadow_resistance_aura.down
end)

spec:RegisterStateExpr("prot_pal_start_attack", function()
    return state.prot_pal_field
        and state.prot_pal_attack_target
        and state.weapon.size > 0
        and target.within5
        and not target.outside5
        and plain(Facade.C_Spell.IsCurrentSpell(6603)) == false
        and buff.paladin_autoattacking.down
end)

spec:RegisterHook("reset_precast", function()
    if state.spec.protection then
        if plain(Facade.C_Spell.IsCurrentSpell(6603)) == true then
            applyBuff("paladin_autoattacking")
        elseif buff.paladin_autoattacking.up then
            removeBuff("paladin_autoattacking")
        end
    end
end)

spec:RegisterStateExpr("prot_pal_shield_pressure", function()
    if not equipped.shield then
        return false
    end
    local inMelee = target.within5 and not target.outside5
    if solo then
        -- Threat numbers need not exist for a solo player. A confirmed engaged melee enemy
        -- targeting us is the evidence that a block can help on a durable pull or pack.
        return (state.prot_pal_durable or state.prot_pal_pack)
            and (
                inMelee
                    and Facade.TargetInPlayerCombat() == true
                    and plain(Facade.UnitIsUnit("targettarget", "player")) == true
                or state.prot_pal_other_melee > 0
            )
    end
    return inMelee and recovery.holdingTarget() or state.prot_pal_other_melee > 0
end)

-- Expensive discretionary spells leave room for the next Holy Strike and, under melee pressure,
-- the next Holy Shield. The live lower bound prevents a forecasted mana return funding a cast early.
spec:RegisterStateExpr("prot_pal_spare_mana", function()
    local available = min(mana.lo, mana.actual_lo or mana.lo)
    if action.holy_strike.known and not action.holy_strike.disabled then
        available = available - action.holy_strike.cost
    end
    if
        state.toggle.defensives
        and state.prot_pal_shield_pressure
        and action.holy_shield.known
        and not action.holy_shield.disabled
    then
        available = available - action.holy_shield.cost
    end
    return available
end)

spec:RegisterStateExpr("prot_pal_ground_safe", function()
    return paladinContext() ~= nil
        and hostileNPC("target")
        and (target.is_dummy or Facade.TargetInPlayerCombat() == true)
end)

local function canConsecrate()
    local consecration = state.action.consecration
    return consecration.known
        and not consecration.disabled
        and state.prot_pal_spare_mana >= consecration.cost
        and state.debuff.consecrated_ground.remains <= state.gcd.max
end

spec:RegisterStateExpr("prot_pal_can_consecrate", function()
    return state.prot_pal_ground_safe and canConsecrate()
end)

spec:RegisterStateExpr("prot_pal_consecrate_pack", function()
    return state.prot_pal_pack and canConsecrate()
end)

-- A self absorb can help through a target switch or with no enemy selected. Read player combat
-- directly so a simulated pull in a later recommendation slot never spends a defensive.
spec:RegisterStateExpr("prot_pal_combat_defense", function()
    return paladinContext() ~= nil
        and plain(Facade.UnitAffectingCombat("player")) == true
        and plain(Facade.UnitIsDeadOrGhost("player")) == false
        and not target.is_dummy
end)

do
    local function attackingMe(unit, victim)
        return plain(Facade.UnitExists(unit)) == true
            and plain(Facade.UnitIsDead(unit)) == false
            and plain(Facade.UnitCanAttack("player", unit)) == true
            and plain(Facade.UnitIsPlayer(unit)) == false
            and plain(Facade.UnitAffectingCombat(unit)) == true
            and plain(Facade.UnitIsUnit(victim, "player")) == true
    end

    -- Changing to a loose caster does not stop the other mobs' melee swings. Count only
    -- distinct engaged nameplates with a positive melee range reading and the Paladin as victim.
    local scanTime, scanTarget, otherMelee
    spec:RegisterStateExpr("prot_pal_other_melee", function()
        local t, key = Facade.GetTime(), Facade.TargetMemoryKey()
        if t ~= scanTime or key ~= scanTarget then
            scanTime, scanTarget, otherMelee = t, key, 0
            local probe = HOLY_STRIKE[knownRank(HOLY_STRIKE)] or 6603
            for unit, victim in pairs(recovery.plates) do
                if
                    plain(Facade.UnitIsUnit(unit, "target")) == false
                    and attackingMe(unit, victim)
                    and plain(Facade.C_Spell.IsSpellInRange(probe, unit)) == true
                then
                    otherMelee = otherMelee + 1
                end
            end
        end
        return otherMelee
    end)

    -- UNIT_COMBAT can identify a real hit on us even without a selected enemy or attacker GUID.
    -- Hidden amounts cannot establish its size. Three actual melee attackers are separate evidence.
    local hardHitUntil = 0
    spec:RegisterUnitEvent("UNIT_COMBAT", "player", nil, function(_, _, kind, _, amount)
        amount = plain(amount)
        if state.spec.protection and plain(kind) == "WOUND" and type(amount) == "number" and amount > 0 then
            local maximum = Facade.PlayerHealthMaximum()
            if maximum and amount >= maximum * 0.25 then
                hardHitUntil = Facade.GetTime() + 5
            end
        end
    end)
    local function clearHit()
        hardHitUntil = 0
    end
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", clearHit)
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", clearHit)

    spec:RegisterStateExpr("prot_pal_heavy_pressure", function()
        if not state.prot_pal_combat_defense then
            return false
        end
        if Facade.GetTime() < hardHitUntil then
            return true
        end
        local others = state.prot_pal_other_melee
        return others >= 3
            or others >= 2 and target.within5 and not target.outside5 and attackingMe("target", "targettarget")
    end)

    spec:RegisterStateExpr("prot_pal_iron_creed_due", function()
        return talent.iron_creed.enabled
            and action.righteous_fury.known
            and buff.righteous_fury.up
            and buff.iron_creed.remains <= gcd.max
    end)

    -- Temporary immunity makes mobs ignore the Paladin. Only offer it on an ordinary outdoor
    -- solo fight where the visible combatants are enemies attacking us and nobody else can be seen
    -- sharing the pull. Unknown roles, victims or encounter state do not establish that.
    local function soloOpponent(unit, victim)
        if
            plain(Facade.UnitExists(unit)) == false
            or plain(Facade.UnitIsDead(unit)) == true
            or plain(Facade.UnitAffectingCombat(unit)) == false
            or plain(Facade.UnitIsUnit(unit, "player")) == true
        then
            return true, false
        end
        local level = plain(Facade.UnitLevel(unit))
        local kind = plain(Facade.UnitClassification(unit))
        -- Insecure tank threat can expose an ungrouped ally even when their plate is hidden.
        -- A truly solo enemy may have no threat number at all.
        local threat = plain(Facade.UnitThreatSituation("player", unit))
        local mine = attackingMe(unit, victim)
            and (threat == nil or threat == 3)
            and type(level) == "number"
            and level > 0
            and (kind == "normal" or kind == "elite" or kind == "rare" or kind == "rareelite" or kind == "minus")
        return mine, mine
    end

    spec:RegisterStateExpr("prot_pal_solo_immunity", function()
        if
            not state.prot_pal_combat_defense
            or paladinContext() ~= "none"
            or not solo
            or boss
            or target.is_boss
            or state.encounterID > 0
            or plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) ~= false
            or plain(Facade.IsInGroup()) ~= false
            or plain(Facade.IsInRaid()) ~= false
            or plain(Facade.GetNumGroupMembers()) ~= 0
            or plain(Facade.UnitExists("pet")) ~= false
            or plain(Facade.UnitExists("boss1")) ~= false
        then
            return false
        end
        local safe, opponent = soloOpponent("target", "targettarget")
        if not safe or not soloOpponent("focus", "focustarget") or not soloOpponent("mouseover", "mouseovertarget") then
            return false
        end
        for unit, victim in pairs(recovery.plates) do
            local alone, mine = soloOpponent(unit, victim)
            if not alone then
                return false
            end
            opponent = opponent or mine
        end
        return opponent
    end)
end

-- The time to the next main-hand swing (Hekili_Warrior/Warrior.lua's, after Hekili's Classic profile): the swing gap
-- Consecration and Exorcism wait for.
spec:RegisterStateExpr("mainhand_remains", function()
    -- out of combat no swing runs (nextMH is 0): anchor it at this evaluation, or its phase free-runs with the clock
    local mh = (nextMH == 0 and combat == 0) and now or nextMH
    if now == query_time then
        local real = mh - now
        return real > 0 and real or 0
    end
    if query_time <= mh then
        return mh - query_time
    end
    if mainhand_speed <= 0 then
        return 0
    end -- no swing speed read yet
    return mainhand_speed - (query_time - mh) % mainhand_speed
end)

-- Unsealed Wrath's Echoes (wowsims talents_retribution.go applyUnsealedWrath): a landed melee hit stores a stack of the
-- active seal's Echo and spends the other Echoes (Seal of the Crusader has none: a hit under it changes nothing). The
-- reaction below runs it at our landed main-hand swing.
local ECHO_OF = {
    seal_of_command = "echo_of_command",
    seal_of_righteousness = "echo_of_righteousness",
    seal_of_fury = "echo_of_fury",
    seal_of_justice = "echo_of_justice",
    seal_of_light = "echo_of_light",
    seal_of_wisdom = "echo_of_wisdom",
}
local ECHOES = {
    "echo_of_command",
    "echo_of_righteousness",
    "echo_of_fury",
    "echo_of_justice",
    "echo_of_light",
    "echo_of_wisdom",
}
-- The Echoes at a landed main-hand swing, and only there (the Retribution log stores no Echo at a Holy Strike's hit,
-- 3.50 and 13.50). The core runs it as of the swing's time (a seal swapped before its row is not yet up).
-- Unsealed Wrath's proc cooldown, 0.1 s (1310735's ICDMs on 70938, hotfix push 114060; wowsims 8f7ad04996): every
-- proc refreshes the own Echo to its full 15 s, so one with more than 14.9 s left was stored under 0.1 s ago, and an
-- extra attack in that swing's instant (Windfury Totem's, an item's) neither stores nor spends.
-- shortcut: a proc under another seal inside those 0.1 s is not seen; upgrade if reactions get their own cooldown.
local ECHO_TIME, UNSEALED_WRATH_ICD = 15, 0.1
local function landing()
    if not talent.twist_of_light.enabled then
        return
    end
    local own
    for i = 1, #SEALS do
        if ECHO_OF[SEALS[i]] and buff[SEALS[i]].up then
            own = ECHO_OF[SEALS[i]]
        end
    end
    if not own or buff[own].remains > ECHO_TIME - UNSEALED_WRATH_ICD then
        return
    end
    for i = 1, #ECHOES do
        if ECHOES[i] == own then
            addStack(own)
        elseif buff[ECHOES[i]].up then
            removeBuff(ECHOES[i])
        end
    end
end
spec:RegisterReaction("unsealed_wrath", { who = "target", outcome = "land", hand = "main", now = landing })

-- A Holy Strike's effects, the `now` and the `handler` (two closures). A Shieldsworn Holy Strike with a shield restores
-- 4% of the maximum mana only when it lands (the Shield Specialization trigger, wowsims talents_protection.go:137-174: its
-- chance is 100% at rank 2 only; 105 at 2627 in the Protection log, none on the log's misses and dodges) and grants the
-- spell block for 6 s on every strike, avoided too (wowsims 61607b27d7); under Righteous Fury it grants Iron Creed's 6 s. `landed` (the `handler`'s: the simulation's
-- forecast) adds the mana. The belief's `now` does not: an avoid undoes only a target aura (Families/Now.lua), so a
-- gain at the cast would stay on a miss and promote a cast we cannot afford; its `onLand` (audit C10, run at a paid
-- wound or crit) adds the mana. Live that is idle until target rows are plain again (gaps.md).
local function holyStruck(landed)
    return function()
        if talent.shieldsworn.enabled and equipped.shield then
            if landed and talent.shield_specialization.rank >= 2 then
                gain(0.04 * mana.max, "mana")
            end
            applyBuff("shieldsworn_block")
        end
        if talent.iron_creed.enabled and buff.righteous_fury.up then
            applyBuff("iron_creed")
        end
    end
end

-- Holy Strike's landed hit (`onLand`): Shieldsworn's mana only (the cast's `now` has the auras).
local function holyLanded()
    return function()
        if talent.shieldsworn.enabled and equipped.shield and talent.shield_specialization.rank >= 2 then
            gain(0.04 * mana.max, "mana")
        end
    end
end

-- Forbearance's length: 60 s, 5 s shorter a rank of Sacred Duty (wowsims forbearance.go) and 10 s shorter under the
-- Justice Battleplate 5-piece (1301697); given the caller's `talent` and `set_bonus` (a cost or effect function runs in
-- the state's environment, this helper in the file's).
local function forbearanceTime(t, sb)
    return 60 - 5 * t.sacred_duty.rank - (sb.justice_battleplate_5pc > 0 and 10 or 0)
end

-- Templar's Bulwark's effects (the `now` and the `handler`): the absorb, and Forbearance.
local function templarsBulwark()
    return function()
        applyBuff("templars_bulwark")
        applyBuff("forbearance", forbearanceTime(talent, set_bonus))
    end
end

-- The coverage abilities' shared pieces (each returns a function that runs in the state's environment).
local function plainCost(costs, ids)
    return function()
        return byRank(costs, ids)
    end
end
local function benedictionCost(costs, ids)
    return function()
        return byRank(costs, ids) * (1 - 0.02 * talent.benediction.rank)
    end
end
-- Purifying Power (429144): -10% a rank on Cleanse and Purify, 8% of base mana.
local function cleanseCost()
    return function()
        return 0.08
    end
end
local function spendsFavor()
    return function()
        removeBuff("divine_favor")
    end
end
local function stuns(key)
    return function()
        applyDebuff("target", key)
    end
end
-- A shield: the invulnerability (one aura for both shields: the Cooldown Manager's item links both) and Forbearance.
-- Both shields share Category 37 (pin: 300 s, Sacred Duty -30 s a rank), so a press starts the other's cooldown.
local function shielded(ids, short, long, other)
    return function()
        applyBuff("divine_shield", knownRank(ids) >= 2 and long or short)
        applyBuff("forbearance", forbearanceTime(talent, set_bonus))
        setCooldown(other, 300 - 30 * talent.sacred_duty.rank)
    end
end

spec:RegisterAbilities({
    recover_threat = {
        name = L["Recover Threat"],
        texture = Hekili.TargetSwapTexture,
        unlisted = true,
        targetSwap = true,
        targetSwapSafe = recovery.safeLanding,
        gcd = "off",
        startsCombat = false,
        usable = function()
            return state.prot_paladin_recover_threat
        end,
    },
    auto_attack = {
        id = 6603,
        texture = 135274, -- INV_Sword_04: the same Attack artwork with every equipped weapon.
        cast = 0,
        cooldown = 0,
        gcd = "off",
        startsCombat = true,
        known = knows({ 6603 }),
        nobuff = "paladin_autoattacking",
        usable = function()
            return state.prot_pal_start_attack
        end,
        handler = function()
            applyBuff("paladin_autoattacking")
        end,
    },
    devotion_aura = selfBuff("devotion_aura", DEVOTION_AURA),
    seal_of_command = seal("seal_of_command", SEAL_OF_COMMAND, SEAL_OF_COMMAND_COST),
    seal_of_righteousness = seal("seal_of_righteousness", SEAL_OF_RIGHTEOUSNESS, SEAL_OF_RIGHTEOUSNESS_COST),
    seal_of_the_crusader = seal("seal_of_the_crusader", SEAL_OF_THE_CRUSADER, SEAL_OF_THE_CRUSADER_COST),
    seal_of_fury = seal("seal_of_fury", SEAL_OF_FURY, SEAL_OF_FURY_COST),
    seal_of_justice = seal("seal_of_justice", SEAL_OF_JUSTICE, SEAL_OF_JUSTICE_COST),
    seal_of_light = seal("seal_of_light", SEAL_OF_LIGHT, SEAL_OF_LIGHT_COST),
    seal_of_wisdom = seal("seal_of_wisdom", SEAL_OF_WISDOM, SEAL_OF_WISDOM_COST),

    -- Unleashes the seal up (it stays up: wowsims judgement.go, the DB2 tooltip).
    judgement = {
        id = 20271,
        cast = 0,
        -- Improved Judgement (25956, Forever DB2: aura 107 misc 11, -1000 ms a rank): 1 s shorter a rank; the Justice
        -- Battlegear 5-piece (1301702): 0.5 s shorter
        cooldown = function()
            return 10 - talent.improved_judgement.rank - (set_bonus.justice_battlegear_5pc > 0 and 0.5 or 0)
        end,
        gcd = "off",

        spend = function()
            return 0.06
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows({ 20271 }),
        ladder = false, -- also needs a seal: a short answer may be the seal (C9)

        usable = function()
            return seal_up, "requires a seal"
        end,

        now = judgementCast(),
        handler = judgementCast(),
    },

    -- Forever-only (talent; hotfix 113554, wowsims swift_judgement.go): a second Judgement on its own 60 s cooldown,
    -- free, off the GCD, no reset of Judgement's.
    swift_judgement = {
        id = 1310994,
        cast = 0,
        cooldown = 60,
        gcd = "off",

        startsCombat = true,
        known = knows({ 1310994 }),

        usable = function()
            return seal_up, "requires a seal"
        end,

        now = judgementCast(),
        handler = judgementCast(),
    },

    -- Only at or below 20% of the target's health: the belief's target health reads the usability answer. Champion of
    -- the Light (1311084, 5 ranks; hotfix 113554, wowsims applyChampionOfTheLight): its cast 0.2 s shorter a rank.
    hammer_of_wrath = {
        id = 24275,
        expects = "travel",
        velocity = 35,
        school = "holy",
        copy = rest(HAMMER_OF_WRATH),
        cast = function()
            return max(0, 1 - 0.2 * talent.champion_of_the_light.rank)
        end,
        cooldown = 6,
        gcd = "totem",

        spend = function() -- Holy Conduit only (Benediction's mask leaves it out)
            return byRank(HAMMER_OF_WRATH_COST, HAMMER_OF_WRATH) * (1 - 0.2 * talent.holy_conduit.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HAMMER_OF_WRATH),
        healthGate = 0.2,

        usable = function()
            return reactive(HAMMER_OF_WRATH), "requires target health under 20 percent"
        end,
    },

    holy_strike = {
        id = 679,
        copy = rest(HOLY_STRIKE),
        cast = 0,
        cooldown = function() -- Shieldsworn (1328544; hotfix 113554, wowsims holy_strike.go): 4 s off
            return talent.shieldsworn.enabled and 6 or 10
        end,
        gcd = "spell",

        spend = function()
            return byRank(HOLY_STRIKE_COST, HOLY_STRIKE) * (1 - 0.02 * talent.benediction.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HOLY_STRIKE),

        now = holyStruck(),
        handler = holyStruck(true),
        onLand = holyLanded(),
    },

    consecration = {
        id = 26573,
        copy = rest(CONSECRATION),
        cast = 0,
        cooldown = 8,
        gcd = "spell",

        spend = conduitCost(CONSECRATION_COST, CONSECRATION),
        spendType = "mana",

        startsCombat = true,
        known = knows(CONSECRATION),

        now = function()
            applyDebuff("target", "consecrated_ground")
        end,

        handler = function()
            applyDebuff("target", "consecrated_ground")
        end,
    },

    exorcism = {
        id = 879,
        copy = rest(EXORCISM),
        cast = 0,
        cooldown = function() -- Purifying Power (429144): -17/-33% (the pin's curve; mask 1:2097152, 2:1073750016)
            return 15 * (1 - PURIFYING_POWER_CD[talent.purifying_power.rank])
        end,
        gcd = "spell",

        spend = conduitCost(EXORCISM_COST, EXORCISM),
        spendType = "mana",

        startsCombat = true,
        known = knows(EXORCISM),

        -- The 879 ranks (Holy) hit only an Undead or Demon target (the DB2 tooltip; wowsims casts none at its
        -- Mechanical target); the 415068 ranks any target, still a living attackable one (L1160).
        usable_on = function()
            if knownRank(EXORCISM) < EXORCISM_ANY then
                return UNDEAD_DEMON
            end
            return ANY_TYPE
        end,
    },

    holy_shock = {
        id = 1311606,
        copy = rest(HOLY_SHOCK),
        cast = 0,
        cooldown = function() -- the Justice Armor 5-piece (1301694): 1 s shorter
            return set_bonus.justice_armor_5pc > 0 and 9 or 10
        end,
        gcd = "spell",

        spend = function()
            return byRank(HOLY_SHOCK_COST, HOLY_SHOCK) * (1 - 0.02 * talent.benediction.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HOLY_SHOCK),

        now = function()
            removeBuff("divine_favor")
        end,

        handler = function()
            removeBuff("divine_favor")
        end,
    },

    divine_favor = selfBuff("divine_favor", { 20216 }, {
        cooldown = 120,
        gcd = "off",
        spend = 0.04,
        spendType = "mana",
        toggle = "cooldowns",
    }),

    holy_shield = {
        id = 20925,
        copy = rest(HOLY_SHIELD),
        cast = 0,
        cooldown = 10,
        gcd = "spell",

        spend = function()
            return byRank(HOLY_SHIELD_COST, HOLY_SHIELD) * (1 - 0.02 * talent.benediction.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(HOLY_SHIELD),
        equipped = "shield",

        now = function()
            applyBuff("holy_shield", nil, 4)
        end,

        handler = function()
            applyBuff("holy_shield", nil, 4)
        end,
    },

    -- Templar's Bulwark (talent 1311015; wowsims templars_bulwark.go, a major cooldown the default casts at the pull): an
    -- absorb of the maximum health for 8 s and Forbearance, 110 mana, 300 s less 30 s a rank of Sacred Duty; refused
    -- under Forbearance.
    templars_bulwark = {
        id = 1311015,
        cast = 0,
        cooldown = function()
            return 300 - 30 * talent.sacred_duty.rank
        end,
        gcd = "off",

        spend = function() -- Benediction's mask names Bulwark (2:2097152)
            return 110 * (1 - 0.02 * talent.benediction.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        toggle = "defensives",
        known = knows({ 1311015 }),

        usable = function()
            return not buff.forbearance.up, "forbearance"
        end,

        now = templarsBulwark(),
        handler = templarsBulwark(),
    },

    -- Lane A (coverage): the heals, the blessings and shields, and the utility spells a Paladin presses (a manual press
    -- costs what it costs and starts its cooldown). Values: the pin's rows; Benediction's mask (20101) takes the stuns,
    -- cleanses, blessings, shields, Repentance and Templar's Bulwark, not the heals, Holy Wrath, Turn Undead or Light's Vigil.
    -- A heal or Holy Shock spends Divine Favor (its mask 0:2149605376: Holy Light, Flash of Light, Holy Shock).
    holy_light = {
        id = 635,
        copy = rest(HOLY_LIGHT),
        defensives = true,
        cast = 2.5,
        cooldown = 0,
        gcd = "spell",

        spend = plainCost(HOLY_LIGHT_COST, HOLY_LIGHT),
        spendType = "mana",

        startsCombat = false,
        known = knows(HOLY_LIGHT),

        now = spendsFavor(),
        handler = spendsFavor(),
    },

    flash_of_light = {
        id = 19750,
        copy = rest(FLASH_OF_LIGHT),
        defensives = true,
        cast = 1.5,
        cooldown = 0,
        gcd = "spell",

        spend = plainCost(FLASH_OF_LIGHT_COST, FLASH_OF_LIGHT),
        spendType = "mana",

        startsCombat = false,
        known = knows(FLASH_OF_LIGHT),

        now = spendsFavor(),
        handler = spendsFavor(),
    },

    -- Lay on Hands empties our pool without interrupting spirit regeneration. Only its recipient
    -- receives the rank's mana. The observed cast tracks the selected unit, which a macro can override.
    lay_on_hands = {
        id = 633,
        copy = rest(LAY_ON_HANDS),
        defensives = true,
        cast = 0,
        cooldown = 1200,
        gcd = "spell",

        startsCombat = false,
        known = knows(LAY_ON_HANDS),
        toggle = "defensives",

        now = function()
            capResource("mana", 0)
            -- Until a readable mana sample arrives, the recipient of a manual cast is unknown.
            -- luacheck: push read globals resetResource cast_id
            resetResource("mana", 0, LAY_ON_HANDS_MANA[cast_id])
            -- luacheck: pop
        end,
        handler = function()
            capResource("mana", 0)
            if
                state.this_action ~= "lay_on_hands"
                or not state.spec.protection
                or state.hardcast
                or state.player.queued_ability == "lay_on_hands"
            then
                return
            end
            local selfCast, boundID = Hekili:CanSelfCastHelpfulSpell(LAY_ON_HANDS[1])
            local amount = selfCast and LAY_ON_HANDS_MANA[boundID or LAY_ON_HANDS[knownRank(LAY_ON_HANDS)]]
            if amount and amount > 0 then
                gain(amount, "mana")
            end
        end,
    },

    -- Holy Conduit's cost cut and Purifying Power's cooldown cut (neither Benediction: not in its mask); Undead and Demons.
    holy_wrath = {
        id = 2812,
        copy = rest(HOLY_WRATH),
        cast = 2,
        cooldown = function()
            return 60 * (1 - PURIFYING_POWER_CD[talent.purifying_power.rank])
        end,
        gcd = "spell",

        spend = function()
            return byRank(HOLY_WRATH_COST, HOLY_WRATH) * (1 - 0.2 * talent.holy_conduit.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HOLY_WRATH),

        usable_on = function()
            return UNDEAD_DEMON
        end,
        range = 20, -- the radius around the caster (the pin: RadiusMax 20); checked by the range filter
        -- Self-centred: its own range answer is nil on every target (L187). A known 879 Exorcism rank (the same two
        -- types) confirms the target's type while it reads secret; a 415068 rank hits any target, so it confirms none.
        rangeSpell = function()
            local r = knownRank(EXORCISM)
            if r > 0 and r < EXORCISM_ANY then
                return EXORCISM[r]
            end
        end,
    },

    -- Improved Hammer of Justice (20487): -5 s a rank.
    hammer_of_justice = {
        id = 853,
        copy = rest(HAMMER_OF_JUSTICE),
        cast = 0,
        cooldown = function()
            return 60 - 5 * talent.improved_hammer_of_justice.rank
        end,
        gcd = "spell",

        spend = benedictionCost(HAMMER_OF_JUSTICE_COST, HAMMER_OF_JUSTICE),
        spendType = "mana",

        startsCombat = true,
        known = knows(HAMMER_OF_JUSTICE),
        debuffApplication = "hammer_of_justice",
        priorityInterruptRange = { 0, 10 },
        priorityInterruptStun = true,

        now = stuns("hammer_of_justice"),
        handler = stuns("hammer_of_justice"),
    },

    -- Purifying Power (429144): -10/-20% cost.
    cleanse = {
        id = 4987,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = cleanseCost(),
        spendType = "mana",

        startsCombat = false,
        toggle = "defensives",
        known = knows({ 4987 }),
    },

    purify = {
        id = 1152,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = cleanseCost(),
        spendType = "mana",

        startsCombat = false,
        toggle = "defensives",
        known = knows({ 1152 }),
    },

    -- Guardian's Favor (20174): Freedom lasts 3 s longer a rank, Protection's cooldown is 60 s shorter a rank.
    blessing_of_freedom = {
        id = 1044,
        cast = 0,
        cooldown = 20,
        gcd = "spell",

        spend = function()
            return 0.1
        end,
        spendType = "mana",

        startsCombat = false,
        toggle = "defensives",
        known = knows({ 1044 }),

        now = function()
            applyBuff("blessing_of_freedom", 10 + 3 * talent.guardians_favor.rank)
        end,
        handler = function()
            applyBuff("blessing_of_freedom", 10 + 3 * talent.guardians_favor.rank)
        end,
    },

    blessing_of_protection = {
        id = 1022,
        copy = rest(BLESSING_OF_PROTECTION),
        cast = 0,
        cooldown = function()
            return 300 - 60 * talent.guardians_favor.rank
        end,
        gcd = "spell",

        spend = benedictionCost(BLESSING_OF_PROTECTION_COST, BLESSING_OF_PROTECTION),
        spendType = "mana",

        startsCombat = false,
        known = knows(BLESSING_OF_PROTECTION),

        usable = function()
            return not buff.forbearance.up, "forbearance"
        end,

        now = function()
            applyBuff("blessing_of_protection")
            applyBuff("forbearance", forbearanceTime(talent, set_bonus))
        end,
        handler = function()
            applyBuff("blessing_of_protection")
            applyBuff("forbearance", forbearanceTime(talent, set_bonus))
        end,
    },

    blessing_of_sacrifice = {
        id = 6940,
        copy = rest(BLESSING_OF_SACRIFICE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = benedictionCost(BLESSING_OF_SACRIFICE_COST, BLESSING_OF_SACRIFICE),
        spendType = "mana",

        startsCombat = false,
        known = knows(BLESSING_OF_SACRIFICE),

        now = function()
            applyBuff("blessing_of_sacrifice")
        end,
        handler = function()
            applyBuff("blessing_of_sacrifice")
        end,
    },

    -- Sacred Duty (1224697): -30/-60 s on both shields' cooldown; both bring Forbearance and refuse under it.
    divine_shield = {
        id = 642,
        copy = rest(DIVINE_SHIELD),
        cast = 0,
        cooldown = function()
            return 300 - 30 * talent.sacred_duty.rank
        end,
        gcd = "spell",

        spend = benedictionCost(DIVINE_SHIELD_COST, DIVINE_SHIELD),
        spendType = "mana",

        startsCombat = false,
        known = knows(DIVINE_SHIELD),
        toggle = "defensives",

        usable = function()
            return not buff.forbearance.up, "forbearance"
        end,

        now = shielded(DIVINE_SHIELD, 10, 12, "divine_protection"),
        handler = shielded(DIVINE_SHIELD, 10, 12, "divine_protection"),
    },

    divine_protection = {
        id = 498,
        copy = rest(DIVINE_PROTECTION),
        cast = 0,
        cooldown = function()
            return 300 - 30 * talent.sacred_duty.rank
        end,
        gcd = "spell",

        spend = benedictionCost(DIVINE_PROTECTION_COST, DIVINE_PROTECTION),
        spendType = "mana",

        startsCombat = false,
        known = knows(DIVINE_PROTECTION),
        toggle = "defensives",

        usable = function()
            return not buff.forbearance.up, "forbearance"
        end,

        now = shielded(DIVINE_PROTECTION, 6, 8, "divine_shield"),
        handler = shielded(DIVINE_PROTECTION, 6, 8, "divine_shield"),
    },

    repentance = {
        id = 20066,
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        spend = function()
            return 60 * (1 - 0.02 * talent.benediction.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows({ 20066 }),

        now = stuns("repentance"),
        handler = stuns("repentance"),
    },

    -- Turn Evil (1328370): -0.5/-1 s cast, -5/-10 s cooldown (its three ranks override these; same costs).
    turn_undead = {
        id = 2878,
        copy = rest(TURN_UNDEAD),
        cast = function()
            return 1.5 - 0.5 * talent.turn_evil.rank
        end,
        cooldown = function()
            return 30 - 5 * talent.turn_evil.rank
        end,
        gcd = "spell",

        spend = plainCost(TURN_UNDEAD_COST, TURN_UNDEAD),
        spendType = "mana",

        startsCombat = true,
        known = knows(TURN_UNDEAD),

        now = stuns("turn_undead"),
        handler = stuns("turn_undead"),
    },

    divine_intervention = {
        id = 19752,
        cast = 0,
        cooldown = 3600,
        gcd = "spell",

        startsCombat = false,
        known = knows({ 19752 }),
    },

    -- The Holy talent (1310911): a 30 s buff on the target and the caster; its Holy Shock cooldown skip is unmodelled.
    lights_vigil = {
        id = 1310911,
        copy = rest(LIGHTS_VIGIL),
        cast = 1.5,
        cooldown = 6,
        gcd = "spell",

        spend = plainCost(LIGHTS_VIGIL_COST, LIGHTS_VIGIL),
        spendType = "mana",

        startsCombat = false,
        known = knows(LIGHTS_VIGIL),

        now = function()
            applyBuff("lights_vigil")
        end,
        handler = function()
            applyBuff("lights_vigil")
        end,
    },

    oath_of_light = {
        id = 1328548,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.08,
        spendType = "mana",

        startsCombat = false,
        known = knows({ 1328548 }),

        now = function()
            applyBuff("oath_of_light")
        end,
        handler = function()
            applyBuff("oath_of_light")
        end,
    },

    -- Forever-only (level 20, 180 s): pushback and mechanic immunity for 6 s; no cost row.
    voice_of_truth = {
        id = 1310897,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        startsCombat = false,
        known = knows({ 1310897 }),

        now = function()
            applyBuff("voice_of_truth")
        end,
        handler = function()
            applyBuff("voice_of_truth")
        end,
    },

    righteous_fury = selfBuff("righteous_fury", RIGHTEOUS_FURY, {
        spend = function()
            if
                buff.the_quick_and_the_dead.up
                and combat == 0
                and plain(Facade.UnitAffectingCombat("player")) == false
            then
                return 0
            end
            return 0.3 -- Benediction discounts the rounded cost through RegisterCostMod.
        end,
        spendType = "mana",
    }),
    retribution_aura = selfBuff("retribution_aura", RETRIBUTION_AURA),
})

-- Retribution's opener (re-pin rulings R15/R16; wowsims's default.apl.json "Move to melee" group at e2842f0a78): the
-- sequences move1 (Judgement, then Seal of Command) and move2 (Judgement, then Seal of Righteousness), each run once a
-- fight, at the pull, as stepped windows over their casts (the pack's `# Window:` lines; move3 folds to never). Each
-- evaluator is its sequence's condition (the header's), in combat, before the fight's first main-hand swing: the
-- swing lands on arrival in melee, where wowsims's sequence completes, so the window closes there (`close_on_false`)
-- or at its last step. No aura shows this span. (Each evaluator runs in the belief's `now` context: written in each.)
spec:RegisterWindow("move1", {
    evaluator = function()
        return talent.seal_of_command.enabled and combat > 0 and lastSwing(1) < combat
    end,
    duration = "combat",
    close_on_false = true,
    steps = { "judgement", "seal_of_command" },
})
spec:RegisterWindow("move2", {
    evaluator = function()
        return (not talent.twist_of_light.enabled or not talent.seal_of_command.enabled)
            and combat > 0
            and lastSwing(1) < combat
    end,
    duration = "combat",
    close_on_false = true,
    steps = { "judgement", "seal_of_righteousness" },
})

-- Pack from the talents (Engine/Schema/Selectors.lua; after the Hekili classic branch's pack selectors), as wowsims's
-- own Retribution page picks its APL (ui/specs/paladin/retribution/spec.ts: `holyShock` talented, the Holy Shock list):
-- Retribution ahead with Holy Shock taken (wowsims's Holy Shock build is 23/0/28) runs Holy Shock (wowsims.com); any other
-- Retribution build runs the default, Retribution (wowsims.com). A Holy-dominant build stays on Holy.
spec:RegisterSelector(
    "holy_shock",
    { spec = "retribution", pack = "Holy Shock (wowsims.com)" },
    function(tab1, tab2, tab3)
        return tab3 > tab1 and tab3 > tab2 and talent.holy_shock.rank > 0
    end
)

-- (L1808, owner "Setting per line") the health threshold of the packs' Divine Shield (20%) and Lay on Hands (15%)
-- lines (the recipes' `extra`, the def-int-beyond-wowsims review's defaults): a 1-100 slider on every spec
spec:RegisterSetting("divine_shield_health", 20, spec:HealthOption("divine_shield"))
spec:RegisterSetting("lay_on_hands_health", 15, spec:HealthOption("lay_on_hands"))
-- (owner 2026-11-24) a Dwarf's Stoneform in Protection (wowsims.com) (translator rule 13: a tank's defensive racial) at
-- or below Protection Warrior's 50%; Protection's own, not a shared setting (rule 25 would put the line in every pack)
spec:RegisterSetting("stoneform_health", 50, spec:HealthOption("stoneform"), "protection")

-- The priorities, one a spec, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit
-- those (a wowsims.com pack: its recipe, tools/wowsims/specs/) and run it, never these blocks
-- (tests/Forever/paladin_spec.lua checks they match).
spec:RegisterPack(
    "Retribution (wowsims.com)",
    20261126000,
    [[Hekili:LRvBVTTnq4Fl5lE2BPYYoTzDbvfOdffldDbfZ9ZsMwI2IlsIgIuXXag(3(oQ3mLefTSDtIB7xAT5jE3Z9gfVhh7r2F1EIhIJTVBS54RhnA81MMM2t4RxITNSe5EpAb8Hiui8V)lMhtMLWj0OTt7VIUIrczgU0WbIhDDaf5ju3Sesa)2i7zk1mBj21EYx(WN)WhV9UBI3Ps7j(eppC2(WmxD27MTt5(4TtZxB4CAm(bC82PE45OKa(2PF4lFE7uy5TtRQLeYqbcydxIcqEKOHsiyiAzaByUkmGVyakpyWLGXIrrSaWz8GptfgNW2of55rJ(f4d3JxZm2o9Jio6gfGQ))C7xbL4Z5lz3mC4cc3pzMWpgw7rha6eWoAM5Ctt8RN7(2RmGqBmDojaI)ixbkzglJXWMNH4wUOGaNSLDcim(LIeLLyHhaW6GymYIiSNdkjgT9VBS)FZAOAn4Iy8D7()s8wGdXr8svy5rEGeHDy(eCG3LK5w(yua334(i6QOE5FzPl)DwmmNtIwWmQSfNShPuHascqRDaq4JI8yDtJY7ixH9GGf3bYToaGJxGJCxNkPx)lYSuvyKP9nxmlz(8AsswoqgDzQNXPr4ltyyh685olC9Sg1nOkTDfUUyf4XCwsfRCS6FNguyc155q6dyho1jehGXclvgM8PbRDyqRX94IGKcjKihOZybUsOQSCPPJ0perIe5lNyS4JS3zvUc0wI9ELPXOE1FO3BbRoOxFoDXIaSHa0c13R)ksKhDv6cJGe2gPVpwKa3OXD05nBUOMM7DrDvl7Wc3KWXHSMomNeIb4F(IDFui0OaG2zvmI7F5CQBclpzvyMQpIH4WblZnnYsnYKJpJZzs6i1xpTkZcixw6x0Z4sPbagKLeJrER1ShLBjhs9vi0doBxOOxzoyWzCaNbhjjQHG38ecrW0MduGWb4RGZJeIcil85g4i0SaSxVCP12xP4SZSRlfqrP7uilwOwmnHfHzSkN4R(jaGdkjvgeU6Ron1R9007HeHopxQftFeOF)2CYn9BZ7vUEZs68vefmxOfeBAfdzMc76tBgczC4MJV3A0GFERZReqoOCU(c)nA3ViERT0UwLtDX90i9uQI2NtThuxTwRyZPvzwx9tyrwl3AheIDZCG0xQ99f8XpsJDjSWZAOR(W8XcmRVfO1xy11dpYSrT3TvOMS3j1HMx4MPgHOh)1X7ghu8)nhx0sAW40fsnFQfQlr2jmAz0rRcybZT74gNWqE44DQuL0kQvKmkNuXsZigvYMr4h576UB2pxVOQXPinhWPks0)69MyP2d3tBjt72SB()4dX)hFQ(FRVWRjIuULUglkoMO65fnUz(iJ3axxpcjgu2jGcxgX80UNUIjIl3LSSS9jfWKpwU6z0sn2NJoG9KhWXmyR1OWtCKntW0xLsbyH7sPtmpJz)N2tKQofcZzWYEsjiTN4gdJohtq2toPoxnLU2Ca)1aMoREq9O78PABZEsA2v42G9V6BuG5WBP3tG51DjWC8TTndpv2CLGe4ZfT0QQLkuu5ZiH1tS75iBF03)K5r5SjRZHQW7OSxTFA)uXPQQY9ctjZy6HzPVzCT2gzRhsxIeBQhMx0Kgwv9a6m7oswpCl3GGwHXFtRnGAR8uiAxFDjIRFr7SZUDY(5CQE6naLR7yCq5HuNgbA796(nVVVUl8R)g)D4k)IWXV3XWrj9VYHJUt87lGN922R5kuVAoF)wr67ZTpVRfUQFv9L0)rlNAkz3kXQtRK)KEzuJn9ut0XZDgdshJmBjF04MwsTDVCukFaCkFKKkNguQFlIU67Ait(zKn5No6K)HRdOBdwmQ9jB2B9WE4K9uzA(fIQ59Y18tgzZ)4xc2(WB3nQ(L3LEr55RJP9cYYC1K6ITpS83RUy5W0c3R9rrosQT3)zyJtnC9bpKmCTx8E88D31I5XzZTx(3iLUj31gAfR3KwDDtNRVyunV6zOTnHAWUkg3Re51XlFUvL7puyQZC(z2f3L9JA1bTKf1eyR)RJ0mOQ43pXoprIs4(uip8x47jbKTt7)P8)YatfB))]]
)
spec:RegisterPack(
    "Protection (wowsims.com)",
    20261126000,
    [[Hekili:TZvBVnoUr4Fl(lU2OBTvCIttxCoaBXHIUfxxCa5(SLPLOT5fzrbrQK6Ia)BVdPEXIuIsK2oz7bSF42l2uAEEMHKZlKd8YBw(BlFkeXXl)2mVz3FZnZU3ZZB5t8dj4LpLGcEgTf(Jy0E4F)1ukhhWj04JRg9k9vgzpBsaD)yXtEiIIcfsBDgjI)14LRBvWSeCaiPV8lF5N)63(CsLex(0osyio)1WSGoq7ZhxX3HpUQ47MUHMIFbNECviEdklIFC1x(1F54k4RpUsrizKPc4zttqrOqs80tWpfLeXMwiGjWhMaIoA8NaOsrXSiqrcH)MkGMWoUcfgsJ)tWF8m(aBYXv)mIJ(CluA0)(R)giKDCEc7ZtNULW3LTwOft1E0XGmbMJw7TXZdF3MGhUDcywtPBirGPhjzjBsskgE51i(ID0Od(rKT74FkKWsIqh8xJJOVUyU3NiBwu8uEd50TBJWtavdhZiVGzdfATpyc8xt26VdJIo(VAi()8IPBIqSD(0nTcYdwdsaIX7afJQXvdHuHWX0mM)MS0dkcDD2MntuhFsi914tYEpIeZH)toMb5J5PK1zIb8rzPifeQe0gcok80hfpO)EcJrI32UydXVqpFzoCqUmNOZUjphdky7qYaBOycVHDYeICu8ZcWK2X6VT0k2nivM9ymJ1fAJgnqhW3k1ofmLA24HJgi)2SK3gz8PAHXzjJhpUDkJY4uFeNdEd)ugddVYg)TbHlUPDAZ4OuEXZB)sMb5lg1NUYsadWjrNXeRgXHV1e2uej0hqjzC7ljmOCLgbWLQFqAgdfItpXN2g9c5u5IMYPPt86DXN27PNS3l)xVpETUQ(Q(W8qP7xAdniJTyMv4zP)P)W4v6k5lsOVCAmgs9yV41eR947k4qXhsc4)0cgMZbfJnP6X9ZhguNcTiK8cS33NTtyvYfXB5UouhP((CaFoEpSxjL5Vol6vuQUUOUv6(5cw2XoiGuVCq4NHXYsX5MrDeAmL7efURpkKB69ZhYwkiKpSQFhkoKz3er93OCUih6h70hdEpoDloo4G8LU4PpfIRAPUrAPgOOkFhy4o0EqGI9r)oeFIeGDDcLXZI9H9AnC4lvm5gIMBa7FcS2Rxo)z9Qk7OHQEERxZPJZgqqd8tK(8pxv)KeUyT3iz0MOVwgaLLB2PXkVIfkmJgr9j73Nft4hmJTQcoZnfSpmepyEnXTIZ5i5M7fbbDkPazWjiikS9N3WvbKidonnlHZggILB7fPlbwxrwOdwtzSHdYF1jeWrR4ZfF8vOwBs8nEvJtZ4msig(Mcj1GxfPr9IWkqOPGA4xHVnjKuQtIdxqM2lkfdkwwSYB)7zHBbVDX8MBIueGq65VTFkgfQyszVs2W9Vgska(F4GuKCgx)f3MsZIHm4jbpdM7AzSg7x9Ey1emdOVa2u(oaO(OvXddrU1YorMundsl8zCJxkIsbHUhhHXdFfJsezsr(V4h9ohtCUWkw6PmsLe8rrWQFC45B9ptqYnc7OqIEDjrRkgPE9tDhg256NMp3wr7w9txOC7KZZSw2HywcwSip37M1S)QHW6iSSCjP7MumoKUxX7PwENTauXAM9Wwn5snyJlpLgnCq5iK4aeSdKWfhY5qd(Lv9HoVMxFC0gFO6TiWBzEAVTq5gz(geHraFTjIIWWIHeclY5t8HieGbuL7wsaeg4TgJKqjmWVqBdb)ngXW6PlMKLs2C4IOJ7GQ5MZ(cCmmhP4ounm4C9OG1MbjPq2ybIjk)WmvV5goeIhVOdHWIsyF0Msy7jiCJdFO98mQgV7dly4avpWcFoW0bnT1edACmcgyX3RtrOi2ImBslmD97KPAYkpvx1sXRHwthbgs)OGcnNMoL3HVLPn09cH(2MCj5y4aYTMNA3jluZQlt0Cpkg94II1fvp9KakJFwjV8(Y(2lq4vyIDN9KOA5XPTrIffW(eiCNyZuH1qdazne(CYE8cVXQAYTn0KB960q3q0AMB8)HMgqy7TxPUm(uIxdI0E(KoqLznOYSEmnvikjdmRWrr5ljl3dhwuIXeCSisz4BLf518j0cE6SJJWSube1ZBSEvmQ66d6Q6dQv508y0TZG2KwwF66xdaC4q3754rf5RKBGGYUdZ2V)qTLcL3iuZGRncD4Qh1MYUF3l96XR6Wgp51m)GgdO0ireRAdKIfj2W(PfJAzqXAmHG(lEJh3L9WcoBi7MrnJUxYiX)korw)IVy4GwZeWQ5jRY2X4wWQR97KGlojbgAJt70uDADXoqAr3DjTixwypCK2(J3ojg1KK6QMGwG2ycjTgPPMEU8PxWPm4H1AjNicJZK9buE7Va)53K9fuHjD5FhgQE1Tl)2CVYwsz5tNQbE5tbPeooLGG)YIl(S8SgwYbg1nGpudq1s7Df0QtlqG6T2J65RMkiENgILIxTuQwHWXsUeOn3eAAU)BfpJbCQfqraY9garjc2zJqpHSee4VQrahqQ7I(oPl1hcwbk8niwZcG)GbTV1sbTHBTvtOLffEgvfkuH)MMkul(OWtqLkvRW9UvK6LSla4gptgPY7vUU86)EvC76OnDDHsM1JJU7NxNz2FcnMV)xZMx9hxYVE8lENT8Z67N2r(P7bT8HRFdXUn5(rCf3DUKq3fTMj)M59RLVVx)DNSx3LFllyQcPPF)xwUwQ(vJlXupcGPvq5wf5Ux3wtu7fT4AuvxRlzOEicnRYTEMN9ShiR0BbB0Jz017D6AUD3KDb32UKN6bg0xl9(B1QP9IKenfhrzRGB2Pl6o6LKQNqiZ8SGNwB8AcFpriAbEHWk76E72W3autU970LYP87(JXv(l1u9ObnvNM32Vn5not3rTPTbvhtGrS1VEFP4T1NS2HJ4gi6UvlfA9tgWOeTQ5cKWyR)s1UpWiWk9DGeaDhDkf9LxnUrPzSHeKfyQ7X68NLDOncKiR7w6sxa4k(6(LuTPIJ0XkOKYQN60T94iSR1hKi2tsGZRLgvFNhHLDVGe2EYERoSNVIQcPUJc94hxnnTLoDqsGEYnB2vrNnbUPY3x3SjgAnuw)xn6)30)fs91KNUIgYWLec6VXm6QZm6Sljeu9otj7L3RgxfM6cD09N2tmc7pRadZ4xLU5qYCtEI77mhDVnpKWP7S(SoojtDaIeH(ZjZ1lj7CB(dBY07otNcBVhrOb6)XFcH3PhKOFlE)ogRMETPNrAK)qEfuk25ZnBuB71ejiMcy0tQIoCp791eksAy7z22zEDoqQZOdpQnd3x)PiuP52MQSfjS((Qys2AmCGA)G4o76TNw(o1ulsT2uOKY7E0D19YiQs3UizOXtMOZYoCGJFiTbt3xJTurnDtINT3UlSbzKK6CUWr7Md6UXwKG78frEnq2I7NCUEGjRVHL65tMBTVSUTrYgBpnLU9WABtTiH02OvD4A3yp68b3Koc95E9qv1O535(ZXMesV3uSREDDCzn2JeB3owOl3xzlMtjp0Jty1sCxA3hZ97Jf5YEVjV79LMPH(eskttoN7m4DDRgx89f)0rS8hDj0p6sil7Hh5Qpxdo7ecwef2u1HQ(jDa)E6Di(p6nO2ueR7nOUw954pwow(ltJYVwosUzkqzPTQ(plon5xBp1LYXg)65iDlZLta7Oaj(N4NjrKJRg9pk(Hfto8Y)h]]
)
spec:RegisterPack(
    "Holy Shock (wowsims.com)",
    20261126000,
    [[Hekili:9Ev7UTTnu0NL(NmBSmjz3USUGQbKHIHMHUGaO8BjrtELfNPffePsMbc0Z(U0swIsww1EiRiajmxE55C4x3dv4IWNcdyene(WsVL3SyXYB888cd07YHWGCcDdzn2iJSf)9xKIDvXbPs6MQ4zViFrX3QCOYTZnPUtijmdCRk5c99zHRgfzvoqddE8UVE3NV)HBlaDbFvPMlZcds5mgupoqrNIVBRI1PqvCtm3ezb8muufZGesPqxfF3JFTkgdxf3hLsURrbk3CIGW4zUwkWLKluUPy(rkt6o4)7G4lMFnYxbjtjW5ddBln8ZvvXegtM9dyJnWoLtv8NjAYTJORz)19pHGKQ15QBDDxZ1PLRmtf3bPohXeLpzLxINh8He6hFVdU6wit4cClGqncv5Kxa4Gxr0(uIqevhosWv6Rn7v(MapJInIOu81zalIuwqQ(ZJg)p67oocuIs3n6)UKTg2cz6wi8z8N5zaUsXbb7AEIFkqe6uNnzYxYUQ5FYP6p5RaTMNTw50Bir1P0ciQebzxekIusgtDEiApIgaVcxS0r42Bek4I1qgD3(EUA27QzQVmQr)13TQmjzqpL5ZTvxn8kTmdUUubrYKKO1uM)IZtQwdFKPUjcMwuU0e5)k(DimcfT7H9r3ofk(hGwq2RHejTu5VSx)N(OIceafVDGnicJINnRz52eaPlQGVovdYsvgOunZK6L9XZax(FDw7M2eO86eGuaBj8m1N8x4n)QZcS2KSxmA6JkLcg2OFFnC8B(tIoUyp)sLGvTObcWQN)VPhRpUbgN)6UUabmV)nQoqSd3ClmH8SS44Bcx6IdHTBes3BhyhLSfRwyu9l4UAAZH)AcpWx)uCmh799E1m3n1FIoSm0ganAa2p55SSh)W)ilOC12UIXJxS23YzAFaJwQVVmSh8QshANOWT)HDf04mIwuQimOOdYX69yy7Dj3F095UYgHbOFMch8GxaykCOmpu4yiXOpS)jjqgzLayH)(blp8HdJXwyWE6qgc14pbn()tHtVA8Oik4AOGtWNF8nlXoM)fYks(4uz7oDzm9M5RDkJnJSF)azBDvZS81onSCUUSzXXwEgA)WfqBNH2LZ8rMHgY)5ZK827nMbDZj2FTDb6Ds8HFzWi60(BIT4z6l(2AmoPZ43lRXj8g)(yooL74BG9O1HRbV1QUWzu9NInsPt8u3hpX5ul1ys7xpZ7a2(W9ocFPBbglydXl8MuGMS3N2Ws3wupTx8zzgBrBFuAVcVyVkovv9dg41ooTFj1uEotUxAIFS9)u(kF7Jgh7)xR2t15z47A)Ya7TKjF)qnRNygobPdFHZXeoYBGcBMKKsDQ5e7xGnCbh)47)O5BR33D4)c]]
)

-- The hand-built lists the wowsims.com priorities replaced: a saved choice of one falls back to its spec's default.
spec:RetirePacks({ "Protection", "Retribution" })
