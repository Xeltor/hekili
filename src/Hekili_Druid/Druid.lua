-- Hekili_Druid/Druid.lua
-- The Forever Druid (Balance, Feral, Guardian and an idle Restoration: Hekili:NewClass): the Classic Druid kit with
-- Forever's spell data (ranks, costs, cooldowns, cast times and durations from the Forever DB2 at build 1.60.1.70338,
-- wowdb; energy and mana costs are DB2 points, rage the DB2 cost / 10), Forever's Shifting Power, Berserk, Primal Bite
-- and Lacerate, bear rage per white swing in Bear Form only, Enrage's rage over time, Clearcasting as a cost modifier,
-- forms from the belief's Forms source, the bleeds' misses from the combat log, and the default priorities (the
-- wowsims.com packs). Design:
-- docs/superpowers/specs/2026-10-15-forever-druid-pack.md.
-- Talents: the DB2's 47 Classic nodes plus three placeholders the live export replaces (checkpoint Q1). Only rank 1 of
-- each talent is in the Forever DB2, so a modifier is rank 1's value x the rank (Classic's convention), floored at 0;
-- no cooldown or duration modifier is modelled but Improved Shifting Power's (spec D5); gear: Insect Swarm's Swarming
-- Idol and Grovekeeper Eclipse 5-piece (set_bonus, gear-aware spec).
-- Credits: Hekili (registration API and pack format); the abilities, auras, handlers and `swap_form` are ported from
-- Hekili's Classic profile (origin/classic:Classic/Druid.lua). Ported from Taco Dog Forever
-- (src/TacoDogForever_Druid/): Enrage's 10 + 2/s and Faerie Fire free in form
-- (Bear.lua), and the `form` alias over the forms (Expressions.lua's RegisterForms). The Feral, Guardian and Balance
-- (wowsims.com) priorities translate wowsims/forever's default APLs (MIT, https://github.com/wowsims/forever).

local Facade = Hekili.Client
local C_Spell, UnitClassBase = Facade.C_Spell, Facade.UnitClassBase
local L = Hekili:GetLocale("Hekili_Druid")

if UnitClassBase("player") ~= "DRUID" then
    return
end

local state = Hekili.State
local IsCurrentSpell = C_Spell.IsCurrentSpell
local floor, max, min = math.floor, math.max, math.min

local AQUATIC_FORM, TRAVEL_FORM, CAT_FORM = { 1066 }, { 783 }, { 768 }
local BEAR_FORM, MOONKIN_FORM = { 5487, 9634 }, { 24858 } -- Dire Bear Form is Bear Form's second rank.

local function plain(value)
    if Facade.issecretvalue(value) then
        return nil
    end
    return value
end

local aquaticCue = { action = "aquatic_form", ranks = AQUATIC_FORM }
local travelCue = { action = "travel_form", ranks = TRAVEL_FORM }
local catCue = { action = "cat_form", ranks = CAT_FORM }
local bearCue = { action = "bear_form", ranks = BEAR_FORM }
local moonkinCue = { action = "moonkin_form", ranks = MOONKIN_FORM }
local feralCombatCues = { actions = { cat_form = catCue, bear_form = bearCue } }
local pickForm, combatDisplayFormCue

local function inForm(cue)
    local index = plain(Facade.GetShapeshiftForm())
    if index == 0 then
        return false
    end
    if type(index) == "number" then
        local _, _, _, id = Facade.GetShapeshiftFormInfo(index)
        id = plain(id)
        if type(id) == "number" then
            for _, rank in ipairs(cue.ranks) do
                if id == rank then
                    return true
                end
            end
            return false
        end
    end
    return Facade.C_UnitAuras.GetPlayerAuraBySpellID(cue.ranks[1]) ~= nil
end

local function usableFormCue(cue)
    if cue and not inForm(cue) then
        local rank = Facade.KnownRank(cue.ranks)
        if rank > 0 and plain(C_Spell.IsSpellUsable(cue.ranks[rank])) == true then
            return cue
        end
    end
end

local function formCue(specKey)
    return usableFormCue(pickForm(specKey))
end

local function displayFormCue(specKey)
    if Facade.InCombatLockdown() or plain(Facade.UnitAffectingCombat("player")) == true then
        return combatDisplayFormCue(specKey)
    end
    return formCue(specKey)
end

local function holdingTravel()
    if state.combat > 0 or Facade.InCombatLockdown() or plain(Facade.UnitAffectingCombat("player")) == true then
        return false
    end
    if state.buff.travel_form.up or state.buff.aquatic_form.up then
        return true
    end
    local cue, traveling = pickForm(state.spec.key)
    return traveling == true and not state.action[cue.action].disabled and (inForm(cue) or usableFormCue(cue) ~= nil)
end

-- The class kit and its specs (ids the core's: Balance 100111, Feral 100112, Guardian 100113, Restoration 100114).
-- Feral and Guardian ride the Feral Combat tree: its points pick Feral, with Thick Hide 3/3 Guardian (the selector below
-- RegisterTalents); /hekili spec guardian or feral keeps one for the tree.
local recoveryDisplay = {
    upkeep = displayFormCue,
    selfCast = {
        healing_touch = true,
        rejuvenation = true,
        regrowth = true,
        mark_of_the_wild = true,
        thorns = true,
        cure_poison = true,
        abolish_poison = true,
        remove_curse = true,
    },
}
local spec = Hekili:NewClass("DRUID", {
    specs = {
        {
            key = "balance",
            name = L["Balance"],
            tree = 1,
            icon = 136096,
            role = "attack",
            ranged = true,
            package = "Balance (wowsims.com)",
            recoveryDisplay = { upkeep = displayFormCue },
        },
        {
            key = "feral",
            name = L["Feral"],
            tree = 2,
            icon = 132115,
            role = "attack",
            package = "Feral (wowsims.com)",
            supportsLeveling = true,
            recoveryDisplay = recoveryDisplay,
            movement = true, -- the pack reads toggle.movement: the run into melee reaches the damage lines (R8)
        },
        {
            key = "guardian",
            name = L["Guardian"],
            tree = 2,
            icon = 132276,
            role = "tank",
            package = "Guardian (wowsims.com)",
            supportsLeveling = true,
            recoveryDisplay = recoveryDisplay,
            movement = true, -- the pack reads toggle.movement: the run into melee reaches the damage lines (R8)
        },
        { key = "restoration", name = L["Restoration"], tree = 3, icon = 136041, role = "healer", unsupported = true },
    },
    -- the Druid's own GCD (a wait, gcd.max of an off-GCD ability): Cat Form's 1 s strikes, else the spell GCD
    gcd = function()
        return buff.cat_form.up and "totem" or "spell"
    end,
})
if not spec then
    return
end

-- Rank IDs, lowest first (the DB2's), and the per-rank values the DB2 gives.
local CLAW = { 1082, 3029, 5201, 9849, 9850 }
local SHRED = { 5221, 6800, 8992, 9829, 9830 }
local RAKE = { 1822, 1823, 1824, 9904, 1289140 } -- 1289140: Forever's variant
local RIP = { 1079, 9492, 9493, 9752, 9894, 9896, 1289141 }
local FEROCIOUS_BITE = { 1328618, 22568, 22827, 22828, 22829, 31018, 1289142 }
local RAVAGE = { 6785, 6787, 9866, 9867 }
local POUNCE = { 9005, 9823, 9827 }
local POUNCE_BLEED = { 9007, 9824, 9826 }
local COWER = { 8998, 9000, 9892 }
local PROWL = { 5215, 6783, 9913 }
local DASH = { 1850, 9821 }
local SHIFTING_POWER = { 1322605 }
local BERSERK = { 417141 }
local MAUL = { 6807, 6808, 6809, 8972, 9745, 9880, 9881 }
local SWIPE = { 779, 780, 769, 9754, 9908 }
local PRIMAL_BITE = { 407995, 1238069, 1238070, 1238073 } -- Mangle, renamed
local LACERATE = { 1328617, 1328616, 414644, 1235826, 1235827 } -- hotfix 113554: the talent rank 1, rank 2 at 34
local DEMORALIZING_ROAR = { 99, 1735, 9490, 9747, 9898 }
local GROWL = { 6795 }
local BASH = { 5211, 6798, 8983 }
local BASH_STUN = { 2, 3, 4 }
local CHALLENGING_ROAR = { 5209 }
local ENRAGE = { 5229 }
local FRENZIED_REGENERATION = { 22842 }
local FERAL_CHARGE = { 1238122, 16979 } -- the trainer's spell, then the old talent's
local FAERIE_FIRE = { 770, 778, 9749, 9907 }
local FAERIE_FIRE_COST = { 55, 75, 95, 115 }
local WRATH = { 5176, 5177, 5178, 5179, 5180, 6780, 8905, 9912 }
local WRATH_COST = { 10, 20, 40, 50, 70, 80, 100, 120 }
local WRATH_CAST = { 1.5, 1.7, 2, 2, 2, 2, 2, 2 }
-- Eclipse's cut of Starfire's cast by talent rank (DB2 effect 2: -170/-330/-500 ms)
local ECLIPSE_CUT = { 0.17, 0.33, 0.5 }
local STARFIRE = { 2912, 8949, 8950, 8951, 9875, 9876, 25298 }
local STARFIRE_COST = { 95, 135, 180, 230, 275, 315, 340 }
local MOONFIRE = { 8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835 }
local MOONFIRE_COST = { 25, 50, 75, 105, 150, 190, 235, 280, 325, 375 }
local INSECT_SWARM = { 5570, 24974, 24975, 24976, 24977 }
local INSECT_SWARM_COST = { 45, 85, 100, 140, 160 }
local HURRICANE = { 16914, 17401, 17402 }
local HURRICANE_COST = { 880, 1180, 1495 }
local ROOTS = { 339, 1062, 5195, 5196, 9852, 9853 }
local ROOTS_COST = { 50, 65, 80, 95, 110, 125 }
local ROOTS_DURATION = { 12, 15, 18, 21, 24, 27 }
local INNERVATE = { 29166 }
local BARKSKIN = { 22812 }
local NATURES_GRASP = { 16689, 16810, 16811, 16812, 16813, 17329 }
local NATURES_GRASP_COST = { 50, 65, 80, 95, 110, 125 }
local MARK_OF_THE_WILD = { 1126, 5232, 6756, 5234, 8907, 9884, 9885 }
local MARK_OF_THE_WILD_COST = { 20, 50, 100, 160, 240, 340, 445 }
local GIFT_OF_THE_WILD = { 21849, 21850 }
local GIFT_OF_THE_WILD_COST = { 900, 1200 }
local THORNS = { 467, 782, 1075, 8914, 9756, 9910 }
local THORNS_COST = { 35, 60, 105, 170, 240, 320 }
local HEALING_TOUCH = { 5185, 5186, 5187, 5188, 5189, 6778, 8903, 9758, 9888, 9889, 25297 }
local HEALING_TOUCH_COST = { 25, 55, 110, 190, 280, 350, 425, 520, 630, 755, 840 }
local HEALING_TOUCH_CAST = { 1.5, 2, 2.5, 3, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5 }
local REGROWTH = { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }
local REGROWTH_COST = { 70, 125, 170, 210, 250, 305, 370, 445, 525 }
local REJUVENATION = { 774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299 }
local REJUVENATION_COST = { 25, 40, 75, 105, 135, 160, 195, 235, 280, 335, 360 }
-- The manual-press Restoration kit (wowsims pin spells_auto_gen.go: cast, cost, cooldown; a cost below 1 is a percent of
-- base mana). Registered so a press costs what it costs and starts its cooldown; no priority recommends them.
local SWIFTMEND = { 18562 }
local WILD_GROWTH = { 408120, 1238214, 1238215 }
local WILD_GROWTH_COST = { 550, 755, 1050 }
local TRANQUILITY = { 740, 8918, 9862, 9863 }
local TRANQUILITY_COST = { 375, 505, 695, 925 }
local REBIRTH = { 20484, 20739, 20742, 20747, 20748 }
local HIBERNATE = { 2637, 18657, 18658 }
local HIBERNATE_COST = { 90, 120, 150 }
local HIBERNATE_DURATION = { 20, 30, 40 }
local SOOTHE_ANIMAL = { 2908, 8955, 9901 }
local SOOTHE_ANIMAL_COST = { 50, 75, 100 }
local ABOLISH_POISON = { 2893 }
local CURE_POISON = { 8946 }
local REMOVE_CURSE = { 2782 }
local REVIVE = { 1237951 }

-- Gear (gear-aware spec §4; r33 section 0): the item and set IDs the pack's set_bonus reads (wowsims/forever at
-- e2842f0a78, db.json). Registered on the kit: every tree reads the same keys.
local GEAR = {
    swarming_idol = 272430, -- 1291061: Insect Swarm +2 s (sim/druid/item_idols.go:72-80)
    -- Grovekeeper Eclipse (set 2114, sim/druid/item_sets.go:31-52): the 4 pieces the game files ship (Trousers,
    -- Grips, Shoulderpads, Stompers); the head and chest join when they ship. 5-piece 1301242: Insect Swarm +3 s.
    grovekeeper_eclipse = { 273884, 273885, 273886, 273887 },
    grovekeeper_eclipse_5pc = 1301242,
    -- Haruspex's Garb (ZG, set 479, db.json setId; sim/druid/item_sets.go:56-73): five items, the 3-piece's hidden aura
    -- 24479 makes Faerie Fire last 5 s longer.
    haruspex = { 19613, 19838, 19839, 19840, 19955 },
    haruspex_3pc = 24479,
}

-- The forms, in `buff.form`'s member order (one is up at a time).
local FORMS = { "cat_form", "bear_form", "moonkin_form", "travel_form", "aquatic_form" }

-- Shifting Power's energy (DB2 1322605 effect 30, base 40) and bear rage per white swing (spec §2.3, D4): the
-- two-hand rate (4.5 a second) x the form's unhasted 2.5 s swing, 11.25 a swing, and a crit doubles it (22.5: wowsims
-- 7c28cfa731 core/rage.go, from Forever combat logs; owner ruling W1 2026-11-02), until checkpoint Q8.
-- The swing is the form's fixed period, not the belief's out-of-combat base read, which holds the pull's form (1.0 s
-- after a Cat pull) through an in-combat shift (GCD kinds design D4; checkpoint G6 reads both forms' speeds).
local SHIFTING_POWER_ENERGY = 40
local BEAR_RAGE_RATE = 4.5
-- Furor's rage into Bear Form (wowsims forms.go furorRageOnEnterBear): 17057's energize, 10, at 20% a rank (17056
-- effect 1): certain at 5/5.
local FUROR_RAGE = 10
local BEAR_SWING = 2.5
-- Primal Fury ("Blood Frenzy" on Forever, DB2 16958; wowsims/forever talents_feral_combat.go): a melee crit of ours in
-- Bear Form gives 16959's 5 rage, always at 2/2 and half the time at 1/2 (wowsims's ladder): its expected rage. The
-- Cat's combo point on a builder's crit is not declared: combo points are a plain read on Forever.
local PRIMAL_FURY = 5
local function primalFury(rank)
    return PRIMAL_FURY * rank / 2
end
-- A bear strike's `onCrit` (the belief's own crit, Families/Now.lua): a closure per ability.
local function primalFuryOnCrit()
    return function()
        if buff.bear_form.up then
            gain(primalFury(talent.primal_fury.rank), "rage")
        end
    end
end

local function rest(ids)
    local out = {}
    for i = 2, #ids do
        out[#out + 1] = ids[i]
    end
    return out
end

-- The highest known rank of a rank list, from the belief's spellbook: the same answer in the sim's `state`
-- environment and in a `now` handler's (event-facade spec §12a).
-- A helper's environment is the file's, so it keeps this local; a pack function's bare `knownRank` is its environment's.
local rankOf = state.knownRank

local function knows(ids)
    return function()
        return rankOf(ids) > 0
    end
end

-- A per-rank value at the highest known rank, else the first rank's (nothing known yet).
local function byRank(values, ids)
    return values[rankOf(ids)] or values[1]
end

-- Moonglow (16845) on its class mask's spells (Wrath, Moonfire, Starfire, Insect Swarm, Hurricane, Entangling Roots,
-- Thorns) and Improved Wrath (16814 effect 1) on Wrath: the DB2's -25% and -50% are the full ranks'. Moonglow's ranks
-- follow wowsims/forever's ladder (spells_auto_gen.go 16845: -8, -17, -25 %; its log: Moonfire 281.25 at 3/3).
local MOONGLOW = { 0.92, 0.83, 0.75 }
local function moonglow(rank)
    return MOONGLOW[rank] or 1
end

-- regen: energy's base rate a second, the belief's from the build until a plain rate read (energy is secret even out
-- of combat): wowsims/forever's 1 energy every 0.1 s (sim/core/energy.go:48-49).
-- refundOnAvoid (energy here, rage below): the share an ability flagged `refundOnAvoid = true` gives back when dodged,
-- parried or missed (wowsims/forever druid/feral.go refundOnMiss and MissRefund: 0.8 where the DB2 flags Discount
-- Power On Miss), Ferocious Bite's too (wowsims e4ef929e54 ferocious_bite.go: 80% of its 35 base energy); not Swipe,
-- Faerie Fire (Feral) or Demoralizing Roar.
-- bear_pause: no energy comes in Bear Form (wowsims forms.go pauseCatEnergy); out of Cat it comes as in Cat, so the
-- pool at a Cat entry is wowsims's stored energy plus 10 a second outside Bear, capped (Furor's share: swap_form).
spec:RegisterResource(
    Enum.PowerType.Energy,
    { bear_pause = { aura = "bear_form", mult = 0 } },
    nil,
    { regen = 10, refundOnAvoid = 0.8 }
)
spec:RegisterResource(Enum.PowerType.ComboPoints)

spec:RegisterResource(
    Enum.PowerType.Rage,
    {
        -- Rage per white swing in Bear or Dire Bear Form only (the Warrior's speed rule; Cat and caster swings add
        -- none).
        -- `aura` gates it in both layers (the belief's swing entry, spec §0.3; Hekili's forecast); `stop` too.
        -- A white crit adds one more base swing (without the two-hand factor), as wowsims's, and Primal Fury's rage:
        -- `crit`. A yellow crit's Primal Fury is the strikes' `onCrit`.
        -- NAMED GAP (owner 2026-11-07): no `taken` (rage from hits) until CN7 gives the belief its hook; the archived rule
        -- (lane-feralguardian-taken-wip.patch) lifts the Guardian replay 0.632 -> 0.923 but with replay flicker 14.65/min: land it
        -- only with CN7 + CN9, never blind.
        -- shortcut: misses, Natural Reaction and rage from damage taken are unmodelled; the belief's swing-scale
        -- calibration absorbs a steady bias. Upgrade from the combat-log rows once a non-cast `now` exists.
        mainhand = {
            swing = "mainhand",
            aura = "bear_form",

            last = function()
                local swing = state.swings.mainhand
                local t = state.query_time
                if state.mainhand_speed == 0 then
                    return 0
                end
                return swing + floor((t - swing) / state.mainhand_speed) * state.mainhand_speed
            end,

            interval = "mainhand_speed",

            stop = function()
                return state.swings.mainhand == 0 or not state.buff.bear_form.up
            end,
            value = function()
                return BEAR_RAGE_RATE * BEAR_SWING
            end,
            crit = function()
                return BEAR_RAGE_RATE * BEAR_SWING + primalFury(talent.primal_fury.rank)
            end,
        },

        -- Enrage's aura (25503): 2 rage every second for 10 s (DB2: periodic energize 20 every 1000 ms).
        -- No `pausesDecay`: whether Enrage pauses the out-of-combat decay is unverified (checkpoint Q9).
        enrage = {
            aura = "enrage",

            last = function()
                local app = state.buff.enrage.applied
                return app + floor(state.query_time - app)
            end,

            interval = 1,
            value = 2,
        },
    },
    nil,
    {
        -- Out-of-combat rage loss per second: the Warrior's measured 1.25 (its Rage tooltip), until checkpoint Q9 reads
        -- it in Bear Form.
        decay = function()
            return 1.25
        end,
        -- Stepped and front-loaded, as the Warrior's.
        decayInterval = function()
            return 1
        end,
        refundOnAvoid = 0.8, -- the Energy line's note above
    }
)

-- Reflection (17106): 17/33/50% of the spirit regen while casting by rank (wowsims's curve, e5a9cd2a2d).
local REFLECTION = { 0.17, 0.33, 0.5 }

-- Mana: secret even out of combat. A cost below 1 is a percent of base mana (DB2 PowerCostPct: the forms, Shifting
-- Power, Innervate), priced in both layers from `base`: wowsims's 1244 at 60 (its log: Shifting Power and Cat Form
-- 684 = 55%, Innervate 62 = 5%, whole mana rounded down) until the client's cost read teaches the player's own. The
-- five-second rule (C3): spirit regen a second outside it, none inside it, the declared start the out-of-combat read
-- replaces (wowsims/forever's Feral and Balance logs: 2.175 and 2.2 mana a 0.1 s tick outside it, pre-raid gear).
spec:RegisterResource(
    Enum.PowerType.Mana,
    {
        -- Innervate's regen (spirit x 5, all of it while casting) is the shared entry every mana user has
        -- (Hekili_Shared/Shared/Auras.lua), the Druid's own cast included: not declared here (it would count twice).
        -- The Serenity Field trinket's buff (item 272439; DB2 aura 1291103: aura 29 Spirit +72, 15 s; an item's buff any
        -- Druid may wear; the other classes' packs: docs/dev/gaps.md): Spirit +72 raises the spirit regen S = 6.25 +
        -- Spirit/8 by 9 a second, so the part x (S + 9) / S, Spirit the belief's out-of-combat read (druid_balance.log:
        -- 12.61 -> 17.11 a second casting at Spirit 139 and Reflection 3/3, + 0.5 x 9); 1 before that read.
        serenity_field = {
            aura = "serenity_field",
            item = 272439, -- the replay's key: wowsims logs the buff by its item
            spirit = function()
                local _, s = stat("UnitStat", 5)
                return s > 0 and 1 + 9 / (6.25 + s / 8) or 1
            end,
        },
    },
    nil,
    {
        -- the share: Reflection's rank (the belief reads it after its talent walk). shortcut: the seeds are the
        -- unreflected builds' (Feral, Guardian); a Reflection build (wowsims's Balance export, 3/3) starts from them
        -- until the out-of-combat read splits its own parts.
        fsr = {
            spirit = 22,
            mp5 = 0,
            share = function()
                return REFLECTION[talent.reflection.rank] or 0
            end,
        },
        base = 1244, -- wowsims's ExtraClassBaseStats, level 60
    }
)

-- Talents: { talent tree (1 Balance, 2 Feral Combat, 3 Restoration: the dominant tree picks the spec), rank 1's
-- spell, max rank }: Forever's tree as wowsims/forever's ui/sim/talents/trees/druid.json lists it
-- (tools/wowsims/talents.lua writes it; tests/Forever/talent_trees_spec.lua checks it and the spec detection over it). A
-- key is Classic's where the talent exists there (code reads `talent.<key>.rank`), else the snake_case of the node's
-- name.
spec:RegisterTalents({
    -- Balance (tree 1)
    improved_wrath = { 1, 16814, 5 },
    genesis = { 1, 1223081, 5 },
    moonglow = { 1, 16845, 3 },
    improved_moonfire = { 1, 16821, 2 },
    natures_majesty = { 1, 1223082, 2 },
    natures_reach = { 1, 16819, 2 },
    improved_entangling_roots = { 1, 16918, 3 },
    natures_splendor = { 1, 1223083, 1 },
    insect_swarm = { 1, 5570, 1 },
    vengeance = { 1, 16909, 5 },
    improved_starfire = { 1, 16850, 5 },
    improved_natures_grasp = { 1, 17245, 2 },
    natures_grace = { 1, 16880, 1 },
    eclipse = { 1, 408248, 3 },
    moonfury = { 1, 16896, 5 },
    moonkin_form = { 1, 24858, 1 },
    -- Feral Combat (tree 2)
    ferocity = { 2, 16934, 5 },
    furor = { 2, 17056, 5 }, -- hotfix 113554: moved to Feral Combat
    feline_swiftness = { 2, 17002, 2 },
    feral_instinct = { 2, 16947, 3 },
    brutal_impact = { 2, 16940, 2 },
    thick_hide = { 2, 16929, 3 },
    improved_shred = { 2, 16966, 3 },
    savage_fury = { 2, 16998, 2 },
    feral_charge = { 2, 1238122, 1 },
    sharpened_claws = { 2, 16942, 2 },
    predatory_strikes = { 2, 16972, 3 },
    lacerate = { 2, 1328617, 1 }, -- hotfix 113554: Lacerate's rank 1 is a talent
    predatory_discipline = { 2, 1328613, 1 }, -- hotfix 113554: Bite keeps its extra energy
    primal_fury = { 2, 16958, 2 }, -- "Blood Frenzy" on Forever
    leader_of_the_pack = { 2, 17007, 1 },
    natural_instinct = { 2, 1223242, 2 },
    rend_and_tear = { 2, 1223246, 5 },
    natural_reaction = { 2, 417051, 5 },
    primal_bite = { 2, 407995, 1 },
    shifting_power = { 2, 1322605, 1 },
    -- Restoration (tree 3)
    natures_focus = { 3, 17063, 5 },
    heart_of_the_wild = { 3, 17003, 5 }, -- hotfix 113554: moved to Restoration
    improved_healing_touch = { 3, 17069, 5 },
    reflection = { 3, 17106, 3 },
    natural_shapeshifter = { 3, 16833, 3 },
    subtlety = { 3, 17118, 3 },
    gift_of_nature = { 3, 17104, 5 },
    bloom = { 3, 1328621, 1 },
    tranquil_spirit = { 3, 24968, 5 },
    improved_rejuvenation = { 3, 17111, 3 },
    swiftmend = { 3, 18562, 1 },
    natures_swiftness = { 3, 17116, 1 },
    living_spirit = { 3, 1309631, 3 },
    improved_tranquility = { 3, 17123, 2 },
    improved_regrowth = { 3, 17074, 5 },
    wild_growth = { 3, 408120, 1 },
})

-- Spec and pack from the talents (Engine/Schema/Selectors.lua; after the Hekili classic branch's pack selectors).
-- wowsims's Guardian and Feral builds both spend 32 points in Feral Combat; only Guardian takes Thick Hide (3/3, with
-- Feral Instinct, Lacerate and Primal Bite), so Feral Combat ahead with all of Thick Hide is Guardian (one stray point
-- does not turn a Feral build). Anything else on the tree is Feral (the tree's first spec), unless the player
-- activated Guardian for it.
spec:RegisterSelector("guardian", { spec = "guardian", pack = "Guardian (wowsims.com)" }, function(tab1, tab2, tab3)
    return tab2 > tab1 and tab2 > tab3 and talent.thick_hide.rank >= 3
end)

spec:RegisterGear("swarming_idol", GEAR.swarming_idol)
spec:RegisterGear("grovekeeper_eclipse", unpack(GEAR.grovekeeper_eclipse))
spec:RegisterSetBonus("grovekeeper_eclipse_5pc", GEAR.grovekeeper_eclipse_5pc)
spec:RegisterGear("haruspex", unpack(GEAR.haruspex))
spec:RegisterSetBonus("haruspex_3pc", GEAR.haruspex_3pc)

spec:RegisterAuras({
    feral_autoattacking = { duration = 3600, max_stack = 1 },
    regrowth = { id = 8936, copy = rest(REGROWTH), duration = 21, max_stack = 1 },
    rejuvenation = { id = 774, copy = rest(REJUVENATION), duration = 12, max_stack = 1 },
    serenity_field = { id = 1291103, duration = 15, max_stack = 1 },
    -- The forms are one family (L727, owner: as the seals): the Cooldown Manager's Druid Forms entry says a form is up
    -- or none is, our last form cast says which; the plain shapeshift read (Game/State/Sources/Forms.lua) wins.
    aquatic_form = {
        id = 1066,
        duration = 3600,
        max_stack = 1,
        family = "forms",
    },
    barkskin = {
        id = 22812,
        duration = 15,
        max_stack = 1,
    },
    bash = {
        id = 5211,
        -- 1324487/8/90: the debuff ids the Cooldown Manager's Bash entry links
        copy = { 6798, 8983, 1324487, 1324488, 1324490 },
        duration = function()
            return (BASH_STUN[knownRank(BASH)] or 2) + 0.5 * talent.brutal_impact.rank
        end,
        max_stack = 1,
    },
    bear_form = {
        id = 5487,
        copy = { 9634 },
        duration = 3600,
        max_stack = 1,
        family = "forms",
    },
    berserk = {
        id = 417141,
        duration = 15,
        max_stack = 1,
    },
    -- The Howling Idol's equip aura (272427): "Reduces the cooldown of your Shifting Power ability" (DB2 1291059).
    howling_idol = {
        id = 1291059,
        duration = 3600,
        max_stack = 1,
    },
    -- The Grovekeeper Eclipse 5-piece's hidden aura (1301242): tracked so set_bonus.grovekeeper_eclipse_5pc reads it
    -- (both environments read the belief's record: Facade GetPlayerAuraBySpellID; gear-aware spec §2).
    grovekeeper_eclipse_5pc = {
        id = 1301242,
        duration = 3600,
        max_stack = 1,
    },
    -- The Haruspex's Garb 3-piece's hidden aura (24479): tracked so set_bonus.haruspex_3pc reads it.
    haruspex_3pc = {
        id = 24479,
        duration = 3600,
        max_stack = 1,
    },
    -- The Idol of Ferocity's equip aura (22397; wowsims e4ef929e54 sim/druid/item_idols.go, 27851 "Reduced Claw and Rake
    -- Cost"): Claw and Rake cost 2 less (the cost modifier below; class_items_test.go). The Feral pack branches on it.
    -- Not yet checked in game.
    idol_of_ferocity = {
        id = 27851,
        duration = 3600,
        max_stack = 1,
    },
    -- The Idol of the Dream's equip aura (220606; wowsims e4ef929e54 sim/druid/items.go, 446212 "Improved Rip"): Rip
    -- lasts 2 s longer, its ticks unchanged (rip below; TestIdolOfTheDreamExtendsRipWithoutChangingItsTicks). The Feral
    -- pack branches on it. Not yet checked in game.
    idol_of_the_dream = {
        id = 446212,
        duration = 3600,
        max_stack = 1,
    },
    -- The Wolfshead Helm's equip aura (8345, DB2 17768): Shifting Power +5 energy, Enrage's instant rage +50%
    -- (wowsims/forever sim/druid/items.go; its log gains the aura at 0 s and 45 energy a Shifting Power).
    wolfshead_helm = {
        id = 17768,
        duration = 3600,
        max_stack = 1,
    },
    -- Classic's alias without the other classes' bleeds.
    bleed = {
        alias = { "rake", "rip", "pounce_bleed", "lacerate" },
        aliasType = "debuff",
        aliasMode = "longest",
    },
    cat_form = {
        id = 768,
        duration = 3600,
        max_stack = 1,
        family = "forms",
    },
    challenging_roar = {
        id = 5209,
        duration = 6,
        max_stack = 1,
    },
    -- Omen of Clarity's proc (a passive on Forever): the next covered ability is free (the cost modifier below). It
    -- procs at most once per 10 s (16864's SpellAuraOptions.ProcCategoryRecovery 10000; wowsims ICDMs 10000), the ICD
    -- wowsims names by 16864.
    clearcasting = {
        id = 16870,
        duration = 15,
        max_stack = 1,
        icd = 10,
        icdSpell = 16864,
    },
    -- Poised (passive 1328829, buff 1328827; wowsims dd2fda98b9, hotfix 113351/113578): out of combat at full energy
    -- the next Claw, Rake, Shred, Ravage, Pounce, Rip, Ferocious Bite or Cower costs 10 less (the cost modifier
    -- below). Not yet checked in game.
    poised = {
        id = 1328827,
        duration = 3600,
        max_stack = 1,
    },
    dash = {
        id = 1850,
        copy = rest(DASH),
        duration = 15,
        max_stack = 1,
    },
    demoralizing_roar = {
        id = 99,
        copy = rest(DEMORALIZING_ROAR),
        duration = 30,
        max_stack = 1,
    },
    eclipse = {
        id = 408255,
        copy = { 441260, 408248 }, -- 408248: the talent's CDM item (cooldownID 199506)
        duration = 15,
        max_stack = 4,
    },
    entangling_roots = {
        id = 339,
        copy = rest(ROOTS),
        duration = function()
            return ROOTS_DURATION[knownRank(ROOTS)] or 12
        end,
        max_stack = 1,
    },
    -- The rage entry's aura: 25503 is the 10 s buff, 5229 the cast.
    enrage = {
        id = 25503,
        copy = { 5229 },
        duration = 10,
        tick_time = 1,
        max_stack = 1,
    },
    faerie_fire = {
        id = 770,
        copy = rest(FAERIE_FIRE),
        duration = function() -- the Haruspex's Garb 3-piece: +5 s
            return 40 + (set_bonus.haruspex_3pc > 0 and 5 or 0)
        end,
        max_stack = 1,
    },
    feral_charge_effect = {
        id = 19675,
        copy = { 414923 }, -- the Cooldown Manager's Feral Charge entry links it too
        duration = 4,
        max_stack = 1,
    },
    -- Cat or Bear Form: Faerie Fire's free cost and cooldown.
    feral_form = {
        alias = { "cat_form", "bear_form" },
        aliasType = "buff",
        aliasMode = "first",
    },
    form = {
        alias = FORMS,
        aliasType = "buff",
        aliasMode = "first",
    },
    frenzied_regeneration = {
        id = 22842,
        copy = { 22845 }, -- the buff the Cooldown Manager links
        duration = 10,
        tick_time = 1,
        max_stack = 1,
    },
    -- mark_of_the_wild and gift_of_the_wild are Hekili_Shared/Shared/Auras.lua's: every class carries them (L971).
    growl = {
        id = 6795,
        duration = 3,
        max_stack = 1,
    },
    hurricane = {
        id = 16914,
        -- 1278965/1278968/1278759: the debuff each rank's tick puts on the target (ranks 1-3), the IDs the viewer reports
        copy = { 17401, 17402, 1278965, 1278968, 1278759 },
        duration = 10,
        tick_time = 1,
        max_stack = 1,
        -- off the Cooldown Manager (cdm-facts fix round 1 I3): its item lights at the first tick, about 1 s after the
        -- cast, but the `now` writes the debuff at the cast, so a verdict at cast + W0 would close a landed Hurricane
        cdm = false,
    },
    innervate = {
        id = 29166,
        duration = 20,
        tick_time = 1,
        max_stack = 1,
    },
    insect_swarm = {
        id = 5570,
        copy = rest(INSECT_SWARM),
        duration = function() -- the one expression both environments evaluate (gear-aware spec §5)
            return 12
                + 2 * talent.natures_splendor.rank
                + (set_bonus.swarming_idol > 0 and 2 or 0)
                + (set_bonus.grovekeeper_eclipse_5pc > 0 and 3 or 0) -- Q1: the 5-piece aura, or 5 pieces worn
        end,
        tick_time = 2,
        dot = "debuff", -- Insect Swarm's schedule
        max_stack = 1,
    },
    lacerate = {
        id = 1328617,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in WoW Forever.
        copy = { 1328616, 414644, 1235826, 1235827, 414647 }, -- 414647: the viewer's Lacerate (no rank text)
        duration = 15,
        tick_time = 3,
        max_stack = 5,
    },
    -- Maul queued on the next swing (C_Spell.IsCurrentSpell, applied in reset_precast), a full swing long.
    maul = {
        duration = function()
            return state.mainhand_speed
        end,
        max_stack = 1,
    },
    moonfire = {
        id = 8921,
        copy = rest(MOONFIRE),
        duration = function()
            return (knownRank(MOONFIRE) > 1 and 12 or 9) + 3 * talent.natures_splendor.rank
        end,
        tick_time = 3,
        dot = "debuff", -- upstream's aura field (Engine/Sim/State.lua:3302): Moonfire's schedule
        max_stack = 1,
    },
    moonkin_form = {
        id = 24858,
        duration = 3600,
        max_stack = 1,
        family = "forms",
    },
    natures_grace = {
        id = 16886,
        copy = { 16880 }, -- the talent's CDM item (cooldownID 199845)
        duration = 3,
        max_stack = 1,
    },
    -- The next Wrath is instant (it spends the buff; the pin's flags reach Wrath, not Starfire).
    natures_swiftness = {
        id = 17116,
        duration = 3600,
        max_stack = 1,
    },
    natures_grasp = {
        id = 16689,
        copy = rest(NATURES_GRASP),
        duration = 45,
        max_stack = 1,
    },
    pounce = {
        id = 9005,
        copy = rest(POUNCE),
        duration = function()
            return 2 + 0.5 * talent.brutal_impact.rank
        end,
        max_stack = 1,
    },
    pounce_bleed = {
        id = 9007,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in WoW Forever.
        copy = rest(POUNCE_BLEED),
        duration = 18,
        tick_time = 3,
        max_stack = 1,
    },
    -- A stealth: the IsStealthed read puts it up or down (Sources/Forms.lua, C5), so a mob that breaks it takes it down.
    -- shortcut: a Night Elf's Shadowmeld also reads IsStealthed true (unprobed in combat, Rogue Q5): believed prowled.
    prowl = {
        id = 5215,
        copy = rest(PROWL),
        duration = 3600,
        max_stack = 1,
        isStealthed = true,
    },
    rake = {
        id = 1822,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in WoW Forever.
        copy = rest(RAKE),
        duration = 9,
        tick_time = 3,
        max_stack = 1,
    },
    rip = {
        id = 1079,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in WoW Forever.
        copy = rest(RIP),
        duration = function() -- the Idol of the Dream's 2 s (above)
            return buff.idol_of_the_dream.up and 14 or 12
        end,
        tick_time = 2,
        max_stack = 1,
    },
    thorns = {
        id = 467,
        copy = rest(THORNS),
        duration = 600,
        max_stack = 1,
    },
    travel_form = {
        id = 783,
        duration = 3600,
        max_stack = 1,
        family = "forms",
    },
    -- Auras the Cooldown Manager's buff entries link (cdm fixture, the owner's export): every rank, the pin's durations.
    -- Nothing reads them but the map; Wild Growth's and Abolish Poison's land on the healed ally.
    wild_growth = { id = 408120, copy = { 1238214, 1238215 }, duration = 7, max_stack = 1 },
    tranquility = { id = 740, copy = { 8918, 9862, 9863 }, duration = 10, max_stack = 1 },
    hibernate = {
        id = 2637,
        copy = { 18657, 18658 },
        duration = function()
            return HIBERNATE_DURATION[knownRank(HIBERNATE)] or 20 -- the pin: 20 / 30 / 40 s by rank
        end,
        max_stack = 1,
    },
    soothe_animal = { id = 2908, copy = { 8955, 9901 }, duration = 15, max_stack = 1 },
    abolish_poison = { id = 2893, duration = 8, max_stack = 1 },
    starfire_stun = { id = 16922, duration = 3, max_stack = 1 }, -- Improved Starfire's stun
    leader_of_the_pack = { id = 24932, duration = 3600, max_stack = 1 },
    moonkin_aura = { id = 24907, duration = 3600, max_stack = 1 },
})

-- Clearcasting (16870): aura 108 misc 14 (cost) -100% on the abilities its class masks name (15973374 / 100664659 /
-- 1024 / 142606400 against SpellClassSet 7), so the next one is free; a covered cast whose declared cost is above 0
-- takes the charge. The rank-1 IDs of the covered abilities this file registers (higher ranks resolve through each
-- ability's `copy`), from
--   select distinct o.SpellID, n.Name_lang from SpellClassOptions o join SpellName n on n.ID=o.SpellID
--     join SpellPower p on p.SpellID=o.SpellID where o.SpellClassSet=7 and (p.ManaCost>0 or p.PowerCostPct>0) and not
--     ((o.SpellClassMask_0 & 15973374)=0 and (o.SpellClassMask_1 & 100664659)=0 and (o.SpellClassMask_2 & 1024)=0
--     and (o.SpellClassMask_3 & 142606400)=0)
-- Covered but unregistered: the rune spells. Wild Growth (408120, mask word 1 bit 26) is covered. Not covered: Wrath, Faerie Fire, Cower,
-- Challenging Roar, Mark and Gift of the Wild, Shifting Power. Checkpoint Q6 confirms Primal Bite and Demoralizing Roar
-- (usable at 0 rage with Clearcasting up).
spec:RegisterCostMod({
    aura = "clearcasting",
    pct = -1,
    charges = 1,
    spells = {
        8921,
        2912,
        5570,
        16914,
        5185,
        8936,
        774,
        1082,
        1822,
        5221,
        1079,
        1328618,
        9005,
        6785,
        779,
        6807,
        1328617,
        5211,
        1238122,
        339,
        467,
        16689,
        407995,
        99,
        740,
        18562,
        408120,
    },
})
-- Natural Shapeshifter's -10% a rank on the form costs, percent of base: the cost is rounded whole, then cut
-- unrounded (wowsims mana.go newManaCost, then spell.go ApplyCostModifiers; L1793 item 1).
spec:RegisterCostMod({
    talent = "natural_shapeshifter",
    pct = { -0.1, -0.2, -0.3 },
    spells = { 1066, 5487, 768, 24858, 783, 1322605 },
})

-- Poised (1328827): aura 107 misc 14 -10 flat Energy on the class mask {8622080, 536870912} against SpellClassSet 7 (the
-- eight abilities wowsims's mechanics_test names; rank-1 IDs, the ranks through each ability's `copy`); one charge.
spec:RegisterCostMod({
    aura = "poised",
    flat = -10,
    charges = 1,
    spells = { 1082, 1822, 5221, 6785, 9005, 1079, 1328618, 8998 },
})

-- The Idol of Ferocity (27851): aura 107 misc 14 -2 flat Energy on Claw and Rake (wowsims e4ef929e54
-- class_items_test.go; rank-1 IDs, the ranks through each ability's `copy`).
spec:RegisterCostMod({
    aura = "idol_of_ferocity",
    flat = -2,
    spells = { 1082, 1822 },
})

-- Nature's Grace (16886; wowsims talents_balance.go applyNaturesGrace): its 10% cast speed (effect 0) shortens every
-- spell GCD, and effect 1 cuts the GCD 10% more on its class mask's spells (these, by rank 1 ID). The wowsims Balance
-- log: 1.5 / 1.1 x 0.9 = 1.227 s on the mask, 1.364 s off it (Innervate).
-- shortcut: the cast speed is a modifier because no haste the belief reads holds the 3 s buff; upgrade if a plain
-- in-combat spell haste read is found to include it (the GCD would then take it twice).
spec:RegisterGcdMod({ aura = "natures_grace", pct = 1 / 1.1 - 1 })
spec:RegisterGcdMod({
    aura = "natures_grace",
    pct = -0.1,
    spells = { 339, 467, 770, 774, 1126, 2912, 5176, 5185, 5570, 8921, 8936, 16689, 16914, 21849 },
})

-- wowsims's druidBleedIsActive (wowsims/forever sim/druid/feral.go targetIsBleeding, apl_values.go): Rake, Rip, Lacerate
-- or Pounce's bleed on the target. Its assumeBleedActive (both requests set it) has no in-game reading: the real target.
spec:RegisterStateExpr("druid_bleed_active", function()
    return debuff.rake.up or debuff.rip.up or debuff.lacerate.up or debuff.pounce_bleed.up
end)

spec:RegisterStateExpr("druid_holding_travel", holdingTravel)

spec:RegisterStateExpr("druid_form_intent", function()
    if state.display == "Primary" and state.combat == 0 and state.offset == 0 then
        local cue = formCue(state.spec.key)
        return cue ~= nil and cue.action == state.this_action and state.buff[cue.action].down
    end
    return false
end)

-- Form choice and pulls use the actual assignment, enemy and melee witnesses. A damage
-- display's forced target count cannot establish that a second mob is fighting the party.
local function instanceType()
    local _, instance = Facade.IsInInstance()
    return plain(instance)
end

local function feralField()
    local instance = instanceType()
    return (instance == "none" or instance == "party" or instance == "scenario")
        and plain(Facade.IsInRaid()) == false
        and not state.target.is_dummy
        and not (state.level >= 60 and (state.boss or state.target.is_boss))
end
spec:RegisterStateExpr("feral_field", feralField)

local function groupedInstance()
    local instance = instanceType()
    return (instance == "party" or instance == "raid" or instance == "scenario")
        and (plain(Facade.GetNumGroupMembers()) or 0) > 1
end

-- A party member's control is visible on the affected unit even when our own aura ledger is empty.
local feralCrowdControlled, packAt, swipeAt
do
    local ids = {}
    for _, ranks in ipairs({
        ROOTS,
        HIBERNATE,
        { 118, 12824, 12825, 12826, 1320379, 1324187, 1324188, 1324189 }, -- Polymorph
        { 6770, 2070, 11297, 1324482, 1324483, 1324484 }, -- Sap
        { 2094, 1324477, 1776, 1777, 8629, 11285, 11286, 1324481 }, -- Blind, Gouge
        { 3355, 14308, 14309, 1324500, 1324501, 1324502, 19503, 1324499 }, -- Freezing Trap, Scatter Shot
        { 20066, 1324538, 9484, 9485, 10955, 1324415, 1324420, 1324422 }, -- Repentance, Shackle
        { 5782, 6213, 6215, 1324448, 1324451, 1324453, 710, 18647, 1324462, 1324463, 6358 }, -- Fear, Banish, Seduction
    }) do
        for _, id in ipairs(ranks) do
            ids[id] = true
        end
    end
    local observed, readAt = {}, {}
    spec:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        readAt.target, packAt, swipeAt = nil, nil, nil
    end)
    local function invalidate(_, unit)
        unit = plain(unit)
        if unit then
            readAt[unit], packAt, swipeAt = nil, nil, nil
        end
    end
    spec:RegisterEvent("UNIT_AURA", invalidate)
    spec:RegisterEvent("NAME_PLATE_UNIT_ADDED", invalidate)
    spec:RegisterEvent("NAME_PLATE_UNIT_REMOVED", invalidate)
    feralCrowdControlled = function(unit)
        if not unit then
            return nil
        end
        local now = Facade.GetTime()
        if readAt[unit] ~= now then
            readAt[unit] = now
            observed[unit] = Facade.UnitHasObservedDebuff(unit, ids)
        end
        return observed[unit]
    end
end

local function controlledTarget()
    if state.debuff.hibernate.up or state.debuff.entangling_roots.up then
        return true
    end
    local controlled = feralCrowdControlled("target")
    if controlled ~= nil then
        return controlled
    end
    local plate = Facade.TargetMemoryPlate(Facade.TargetMemoryKey())
    return plate ~= nil and feralCrowdControlled(plate) == true
end

spec:RegisterStateExpr("feral_group_enemy", function()
    return groupedInstance()
        and not holdingTravel()
        and not controlledTarget()
        and Facade.TargetInPlayerCombat() == true
end)

spec:RegisterStateExpr("feral_sustained", function()
    if feralField() then
        return false
    end
    if groupedInstance() then
        return state.feral_group_enemy
    end
    local instance = instanceType()
    return state.target.is_dummy
        or (instance ~= "party" and instance ~= "scenario")
        or Facade.TargetInPlayerCombat() == true
end)

spec:RegisterStateExpr("feral_pull", function()
    if not feralField() or holdingTravel() or controlledTarget() then
        return false
    end
    local engaged = Facade.TargetInPlayerCombat()
    return engaged == true or engaged == false and instanceType() == "none" and (combat == 0 or state.false_start > 0)
end)

local partyUnits = { "party1", "party2", "party3", "party4" }
local function partyHasTank()
    local answer = false
    for _, unit in ipairs(partyUnits) do
        local exists = plain(Facade.UnitExists(unit))
        local role = exists and Facade.GroupRole(unit)
        if role == "TANK" then
            return true
        end
        if exists == nil or exists and not role then
            answer = nil
        end
    end
    return answer
end

local function partyIdle()
    if plain(Facade.UnitAffectingCombat("player")) ~= false then
        return false
    end
    for _, unit in ipairs(partyUnits) do
        local exists = plain(Facade.UnitExists(unit))
        if exists == nil or exists and plain(Facade.UnitAffectingCombat(unit)) ~= false then
            return false
        end
    end
    return true
end

local function groupTank()
    local count = plain(Facade.GetNumGroupMembers())
    if not count or count < 2 then
        return false
    end
    local instance = instanceType()
    if instance ~= "none" and instance ~= "party" and instance ~= "raid" and instance ~= "scenario" then
        return false
    end
    local role = Facade.GroupRole("player")
    if role == "TANK" then
        return true
    end
    return role == "NONE" and instance == "party" and partyHasTank() == false
end

local function targetIntent()
    local exists = plain(Facade.UnitExists("target"))
    if exists ~= true then
        return exists
    end
    local attackable = plain(Facade.UnitCanAttack("player", "target"))
    if attackable ~= true then
        return attackable
    end
    local dead = plain(Facade.UnitIsDead("target"))
    if dead ~= nil then
        return not dead
    end
end

local function targetFacingAway()
    if plain(Facade.UnitExists("targettarget")) == true then
        local attackingUs = plain(Facade.UnitIsUnit("targettarget", "player"))
        if attackingUs ~= nil then
            return not attackingUs
        end
    end
end

local function combatForm(specKey)
    local role = Facade.GroupRole("player")
    if role == "HEALER" then
        return
    end
    if specKey == "balance" then
        return moonkinCue
    end
    if groupTank() or specKey == "guardian" and instanceType() == "raid" and role == "NONE" then
        return bearCue
    end
    local knowsCat = Facade.KnownRank(CAT_FORM) > 0
    local catBuilder = Facade.KnownRank(CLAW) > 0
        or role == "DAMAGER"
            and Facade.KnownRank(SHRED) > 0
            and (plain(Facade.GetNumGroupMembers()) or 0) > 1
            and Facade.TargetInPlayerCombat() == true
            and (state.settings.behind or targetFacingAway())
    if not knowsCat or not catBuilder and Facade.KnownRank(BEAR_FORM) > 0 then
        return bearCue
    end
    -- Let a current Bear finish a pull the party has already started.
    if inForm(bearCue) and Facade.TargetInPlayerCombat() == true then
        return bearCue
    end
    return catCue
end

local function canShift()
    return plain(Facade.UnitIsDeadOrGhost("player")) == false
        and plain(Facade.IsMounted()) == false
        and plain(Facade.UnitOnTaxi("player")) == false
end

pickForm = function(specKey)
    if
        Facade.InCombatLockdown()
        or plain(Facade.UnitAffectingCombat("player")) ~= false
        or not canShift()
        or Facade.PlayerEatingOrDrinking() ~= false
    then
        return
    end
    local hostile = targetIntent()
    if hostile == nil then
        return
    end
    local instance = instanceType()
    if instance == "party" or instance == "raid" then
        return hostile and combatForm(specKey) or nil
    end
    local wet = plain(Facade.IsSwimming("player"))
    local speed = wet == false and plain(Facade.GetUnitSpeed("player"))
    local travel
    if type(speed) == "number" and speed > 0 then
        local outdoors = plain(Facade.IsOutdoors())
        local outdoorWorld = outdoors == true and instance == "none"
        if outdoorWorld or outdoors == false then
            travel = outdoorWorld and Facade.KnownRank(TRAVEL_FORM) > 0 and travelCue
                or Facade.KnownRank(CAT_FORM) > 0 and catCue
        end
    end
    if travel then
        if not hostile then
            return travel, true
        end
        local near, far = Facade.RangeLib("target")
        local close = type(far) == "number" and far <= 10
        if not close and (type(near) == "number" and near >= 10 or inForm(travel)) then
            return travel, true
        end
    end
    if hostile then
        return combatForm(specKey)
    end
    if wet == true then
        return aquaticCue, true
    end
end

combatDisplayFormCue = function(specKey)
    if not canShift() or Facade.GroupRole("player") == "HEALER" then
        return
    end
    if specKey ~= "balance" and groupTank() then
        return usableFormCue(bearCue)
    end
    if targetIntent() ~= true then
        return
    end
    if specKey == "balance" then
        return usableFormCue(moonkinCue)
    end
    if inForm(bearCue) or inForm(catCue) and combatForm(specKey) ~= bearCue then
        return
    end
    -- The rotation decides the combat shift when coming from caster or travel form.
    local cat, bear = usableFormCue(catCue), usableFormCue(bearCue)
    return cat and bear and feralCombatCues or cat or bear
end

-- Opening a fresh dungeon pull is a tank decision. Only the selected enemy is eligible,
-- between fights and with the whole party idle. Never reuse this permission for an area attack or taunt.
spec:RegisterStateExpr("feral_tank_opener", function()
    if
        state.offset ~= 0
        or state.combat > 0
        or instanceType() ~= "party"
        or not groupedInstance()
        or not groupTank()
        or (Facade.GroupRole("player") ~= "TANK" and not state.spec.guardian)
        or plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) ~= false
        or not (state.buff.bear_form.up or state.buff.form.down and not state.action.bear_form.known)
        or controlledTarget()
        or Facade.TargetInPlayerCombat() ~= false
        or not partyIdle()
    then
        return false
    end
    return true
end)

spec:RegisterStateExpr("feral_enrage", function()
    if state.feral_sustained and instanceType() ~= "party" then
        return true
    end
    if state.combat > 0 or max(state.rage.lo, state.rage.actual_lo) > 20 then
        return false
    end
    if instanceType() == "party" then
        if not state.feral_tank_opener then
            return false
        end
    elseif not state.feral_pull then
        return false
    end
    local near, far = Facade.LibRangeCheck:GetRange("target")
    near, far = plain(near), plain(far)
    return type(near) == "number" and near >= 5 and type(far) == "number" and far <= 30
end)

spec:RegisterStateExpr("feral_bear_fight", function()
    return state.feral_pull or instanceType() == "party" and not state.target.is_dummy and state.feral_group_enemy
end)

local function bearAreaFight()
    return feralField() or instanceType() == "party" and not state.target.is_dummy and groupedInstance()
end

spec:RegisterStateExpr("feral_maul_allowed", function()
    if buff.frenzied_regeneration.up then
        return false
    end
    if not state.feral_bear_fight then
        return true
    end
    -- A queued Maul also costs the Rage the white swing would have generated.
    local advanced = action.primal_bite.known and not action.primal_bite.disabled
        or action.lacerate.known and not action.lacerate.disabled
    local cleaving = action.swipe_bear.known and not action.swipe_bear.disabled and state.feral_swipe_pack
        or advanced and state.feral_pack and state.feral_area_safe
    if cleaving and state.rage.lo <= 50 then
        return false
    end
    if advanced and state.rage.lo <= 35 then
        return false
    end
    if state.toggle.defensives and action.frenzied_regeneration.known and cooldown.frenzied_regeneration.ready then
        local health = Facade.PlayerHealthFraction()
        if health and health <= 0.25 and state.rage.lo - action.maul.cost < 10 then
            return false
        end
    end
    return true
end)

spec:RegisterStateExpr("feral_bear_burst", function()
    local bite = action.primal_bite
    if
        state.combat == 0
        or not state.feral_bear_contact
        or not buff.bear_form.up
        or buff.berserk.up
        or buff.frenzied_regeneration.up
        or not bite.known
        or bite.disabled
        or state.rage.lo < 2 * bite.cost
        or state.feral_dying
        or plain(C_Spell.IsSpellInRange(bite.id, "target")) ~= true
    then
        return false
    end
    -- Berserk lets successive Bites cleave for 15s. Spend it on a proven pack or durable enemy.
    return state.feral_swipe_pack or state.feral_durable
end)

local recovery = Hekili:NewTankRecovery(spec, {
    specKey = "feral",
    alternateSpecKey = "guardian",
    avoidUnit = feralCrowdControlled,
    canTaunt = function(guid, now)
        return not Facade.DebuffImmunity("growl", guid, now)
    end,
    meleeSpell = function()
        return GROWL[rankOf(GROWL)] or MAUL[rankOf(MAUL)]
    end,
    classifyCast = function(id)
        if id == GROWL[1] then
            return "rescue"
        end
    end,
})

-- A spell with a five-yard range can narrow a coarse distance bracket. Area spells
-- centered on the Druid cannot measure an individual enemy with their own range check.
local function observedRange(unit)
    local near, far = Facade.LibRangeCheck:GetRange(unit)
    near, far = plain(near), plain(far)
    if type(far) ~= "number" or far > 5 then
        local melee = MAUL[rankOf(MAUL)]
            or GROWL[rankOf(GROWL)]
            or CLAW[rankOf(CLAW)]
            or PRIMAL_BITE[rankOf(PRIMAL_BITE)]
        if melee and plain(C_Spell.IsSpellInRange(melee, unit)) == true then
            return 0, 5
        end
    end
    return near, far
end

local function fightingGroup(unit, victim, threat, attackingPlayer)
    return plain(Facade.UnitAffectingCombat(unit)) == true
        and (type(threat) == "number" or attackingPlayer or plain(Facade.UnitInParty(victim)) == true)
end

local function hostileNPC(unit)
    return plain(Facade.UnitCanAttack("player", unit)) == true
        and plain(Facade.UnitIsDead(unit)) == false
        and plain(Facade.UnitIsPlayer(unit)) == false
end

local function inRadius(unit, radius)
    local _, far = observedRange(unit)
    return type(far) == "number" and far <= radius
end

-- Cache the conservative footprint used by form choice and selecting targets for bleeds.
local packTarget, multiple, clearArea, holdingPack
local function readPack()
    local now, key = Facade.GetTime(), Facade.TargetMemoryKey()
    if packAt == now and packTarget == key then
        return
    end
    packAt, packTarget, multiple, clearArea, holdingPack = now, key, false, false, false
    if Facade.TargetInPlayerCombat() ~= true or controlledTarget() then
        return
    end
    local _, targetRange = observedRange("target")
    if type(targetRange) ~= "number" or targetRange > 10 then
        return
    end
    clearArea, holdingPack = true, true
    for unit, victim in pairs(recovery.plates) do
        local hostile, dead = plain(Facade.UnitCanAttack("player", unit)), plain(Facade.UnitIsDead(unit))
        if hostile ~= false and dead ~= true then
            local near, far = observedRange(unit)
            local same = plain(Facade.UnitIsUnit(unit, "target"))
            if same ~= true and (type(near) ~= "number" or near <= 10) then
                local threat = plain(Facade.UnitThreatSituation("player", unit))
                local attackingPlayer = plain(Facade.UnitIsUnit(victim, "player")) == true
                local engaged = hostile == true
                    and dead == false
                    and plain(Facade.UnitIsPlayer(unit)) == false
                    and fightingGroup(unit, victim, threat, attackingPlayer)
                if not engaged or feralCrowdControlled(unit) == true then
                    clearArea = false
                elseif targetRange <= 5 and same == false and type(far) == "number" and far <= 5 then
                    multiple = true
                end
                if not attackingPlayer or threat ~= 2 and threat ~= 3 then
                    holdingPack = false
                end
            end
        end
    end
end

spec:RegisterStateExpr("feral_pack", function()
    if state.max_targets == 1 or state.toggle.mode == "single" then
        return false
    end
    readPack()
    return multiple
end)
spec:RegisterStateExpr("feral_area_safe", function()
    readPack()
    return clearArea and state.active_dot.hibernate == 0 and state.active_dot.entangling_roots == 0
end)

spec:RegisterStateExpr("feral_held_pack", function()
    return instanceType() == "party"
        and groupTank()
        and state.feral_pack
        and state.feral_area_safe
        and holdingPack
        and recovery.holdingTarget()
end)

local function swipeReach(spell, unit)
    local inRange = spell and plain(C_Spell.IsSpellInRange(spell, unit))
    if inRange ~= nil then
        return inRange
    end
    if inRadius(unit, 5) then
        return true
    end
end

local swipeContact, swipePack
local function readSwipe()
    local now = Facade.GetTime()
    if swipeAt == now then
        return
    end
    swipeAt, swipeContact, swipePack = now, false, false
    if not bearAreaFight() then
        return
    end
    local targetEngaged = Facade.TargetInPlayerCombat()
    if targetEngaged ~= true then
        if plain(Facade.UnitAffectingCombat("player")) ~= true or targetEngaged == nil and not hostileNPC("target") then
            return
        end
    end
    local spell = SWIPE[rankOf(SWIPE)]
    local inRange = swipeReach(spell, "target")
    if inRange == nil then
        local plate = Facade.TargetMemoryPlate(Facade.TargetMemoryKey())
        inRange = plate and swipeReach(spell, plate)
    end
    if inRange ~= true then
        return
    end

    local closePlates, hasAdd, hasFight = 0, false, targetEngaged == true
    for unit, victim in pairs(recovery.plates) do
        if hostileNPC(unit) and swipeReach(spell, unit) == true then
            local same = plain(Facade.UnitIsUnit(unit, "target"))
            if not hasFight and same ~= true then
                local threat = plain(Facade.UnitThreatSituation("player", unit))
                hasFight = fightingGroup(unit, victim, threat, plain(Facade.UnitIsUnit(victim, "player")) == true)
            end
            closePlates = closePlates + 1
            -- Two different plates prove a pack even if the client hides which one is selected.
            hasAdd = hasAdd or same == false or closePlates >= 2
            if hasFight and hasAdd then
                break
            end
        end
    end
    swipeContact, swipePack = hasFight, hasFight and hasAdd
end

spec:RegisterStateExpr("feral_bear_contact", function()
    readSwipe()
    return swipeContact
end)

spec:RegisterStateExpr("feral_swipe_pack", function()
    if state.max_targets == 1 or state.toggle.mode == "single" then
        return false
    end
    readSwipe()
    return swipePack
end)

do
    local bossUnits = { "boss1", "boss2", "boss3", "boss4", "boss5" }

    -- Count only confirmed loose enemies. Other mobs in the Roar footprint do not veto it.
    local function looseForRoar(unit, victim)
        if
            not hostileNPC(unit)
            or not inRadius(unit, 10)
            or plain(Facade.UnitAffectingCombat(unit)) ~= true
            or plain(Facade.UnitLevel(unit)) == -1
            or plain(Facade.UnitClassification(unit)) == "worldboss"
        then
            return false
        end
        local threat = plain(Facade.UnitThreatSituation("player", unit))
        if threat ~= 0 and threat ~= 1 then
            return false
        end
        for _, member in ipairs(partyUnits) do
            if
                plain(Facade.UnitIsUnit(victim, member)) == true
                and plain(Facade.UnitExists(member)) == true
                and plain(Facade.UnitIsPlayer(member)) == true
                and plain(Facade.UnitIsDead(member)) == false
            then
                local role = Facade.GroupRole(member)
                local guid, now = plain(Facade.UnitGUID(unit)), Facade.GetTime()
                return (role == "HEALER" or role == "DAMAGER")
                    and (plain(Facade.UnitAffectingCombat("player")) == true or plain(
                        Facade.UnitAffectingCombat(member)
                    ) == true)
                    and not Facade.DebuffImmunity("growl", guid, now)
                    and not Facade.DebuffImmunity("challenging_roar", guid, now)
            end
        end
    end

    spec:RegisterStateExpr("feral_challenging_roar", function()
        if
            state.offset ~= 0
            or instanceType() ~= "party"
            or not state.OnToggleDisplay("defensives")
            or not state.buff.bear_form.up
            or not groupTank()
            or state.max_targets == 1
            or state.toggle.mode == "single"
            or state.boss
            or state.target.is_boss
            or plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) == true
            or plain(Facade.UnitIsDeadOrGhost("player")) ~= false
            or min(state.rage.lo, state.rage.actual_lo) < state.action.challenging_roar.cost
        then
            return false
        end
        for _, unit in ipairs(bossUnits) do
            if plain(Facade.UnitExists(unit)) == true then
                return false
            end
        end
        local selected = looseForRoar("target", "targettarget")
        local closePlates = 0
        for unit, victim in pairs(recovery.plates) do
            if looseForRoar(unit, victim) then
                closePlates = closePlates + 1
                if closePlates >= 2 or selected and plain(Facade.UnitIsUnit(unit, "target")) == false then
                    return true
                end
            end
        end
        return false
    end)

    -- Two real wounds of at least 10% maximum health within five seconds establish sustained
    -- pressure. A single spike, secret amount or amounts from the preceding pull cannot arm it.
    local previousWound, pressureUntil
    spec:RegisterUnitEvent("UNIT_COMBAT", "player", nil, function(_, _, kind, _, amount)
        if (state.spec.feral or state.spec.guardian) and plain(kind) == "WOUND" and type(plain(amount)) == "number" then
            local maximum = Facade.PlayerHealthMaximum()
            if maximum and amount >= maximum * 0.10 then
                local now = Facade.GetTime()
                if previousWound and now - previousWound <= 5 then
                    pressureUntil = now + 5
                end
                previousWound = now
            end
        end
    end)
    local function clearWounds()
        previousWound, pressureUntil = nil, nil
    end
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", clearWounds)
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", clearWounds)

    spec:RegisterStateExpr("feral_regeneration_pressure", function()
        if
            not pressureUntil
            or Facade.GetTime() >= pressureUntil
            or instanceType() ~= "party"
            or not state.feral_defense
            or not state.feral_group_enemy
            or not groupTank()
            or not recovery.holdingTarget()
            or inRadius("target", 5) ~= true
            or min(state.rage.lo, state.rage.actual_lo) < 30
        then
            return false
        end
        for unit, victim in pairs(recovery.plates) do
            local threat = plain(Facade.UnitThreatSituation("player", unit))
            if
                (threat == 2 or threat == 3)
                and plain(Facade.UnitIsUnit(unit, "target")) == false
                and plain(Facade.UnitIsUnit(victim, "player")) == true
                and plain(Facade.UnitCanAttack("player", unit)) == true
                and plain(Facade.UnitIsDead(unit)) == false
                and plain(Facade.UnitIsPlayer(unit)) == false
                and plain(Facade.UnitAffectingCombat(unit)) == true
                and inRadius(unit, 5) == true
            then
                return true
            end
        end
        return false
    end)
end

local function roarEnemy(unit, victim, held)
    if not hostileNPC(unit) or not inRadius(unit, 10) then
        return false
    end
    local threat = plain(Facade.UnitThreatSituation("player", unit))
    local attackingPlayer = plain(Facade.UnitIsUnit(victim, "player")) == true
    if held and not attackingPlayer and threat ~= 2 and threat ~= 3 then
        return false
    end
    return fightingGroup(unit, victim, threat, attackingPlayer)
end

local function anyRoarEnemy(held)
    if roarEnemy("target", "targettarget", held) then
        return true
    end
    for unit, victim in pairs(recovery.plates) do
        if roarEnemy(unit, victim, held) then
            return true
        end
    end
    return false
end

spec:RegisterStateExpr("feral_defensive_roar", function()
    if not state.toggle.defensives then
        return false
    end
    return instanceType() == "party" and groupTank() and anyRoarEnemy(true)
        or feralField() and instanceType() ~= "party" and state.feral_swipe_pack
end)

spec:RegisterStateExpr("feral_roar_in_combat", function()
    if bearAreaFight() then
        return anyRoarEnemy(false)
    end
    if groupedInstance() then
        return Facade.TargetInPlayerCombat() == true
    end
    local instance = instanceType()
    return state.target.is_dummy
        or instance ~= "party" and instance ~= "scenario"
        or Facade.TargetInPlayerCombat() == true
end)
spec:RegisterStateExpr("feral_damage_enemy", function()
    return (plain(Facade.GetNumGroupMembers()) or 0) > 1
        and Facade.GroupRole("player") == "DAMAGER"
        and (state.feral_group_enemy or state.feral_pull and Facade.TargetInPlayerCombat() == true)
end)

-- Claw works from the front, including the first solo swing. A damage player
-- who skipped Claw can still use Shred when another party member holds the mob.
local function hasCatBuilder()
    local cat, claw, shred = state.action.cat_form, state.action.claw, state.action.shred
    return cat.known
        and not cat.disabled
        and (
            claw.known and not claw.disabled
            or shred.known and not shred.disabled and state.feral_damage_enemy and state.feral_behind
        )
end

local function betweenPulls()
    return state.offset == 0
        and state.combat == 0
        and state.buff.casting.down
        and plain(Facade.UnitIsDeadOrGhost("player")) == false
        and plain(Facade.UnitAffectingCombat("player")) == false
        and plain(Facade.IsMounted()) == false
        and plain(Facade.UnitOnTaxi("player")) == false
        and Facade.PlayerEatingOrDrinking() == false
        and state.buff.prowl.down
end

spec:RegisterStateExpr("feral_sustained_form", function()
    local role = Facade.GroupRole("player")
    if feralField() or holdingTravel() or role == "HEALER" then
        return false
    end
    if not groupedInstance() then
        return true
    end
    -- Dungeons can infer an unassigned role. In a raid or scenario an
    -- unassigned druid starting in caster form can use the pack's own opener.
    return role == "NONE" and instanceType() ~= "party" and buff.feral_form.down
end)
spec:RegisterStateExpr("feral_wants_bear", function()
    local role = Facade.GroupRole("player")
    if not action.bear_form.known or holdingTravel() or role == "HEALER" then
        return false
    end
    if groupTank() then
        return true
    end
    if not hasCatBuilder() then
        return state.feral_pull or role == "DAMAGER" and state.feral_group_enemy
    end
    return state.feral_pull
        and (role == "NONE" or role == "TANK")
        and state.feral_pack
        and (state.solo or partyHasTank() == false)
end)
spec:RegisterStateExpr("feral_wants_cat", function()
    local role = Facade.GroupRole("player")
    if role == "HEALER" or not hasCatBuilder() or holdingTravel() or state.feral_wants_bear then
        return false
    end
    -- Keep a manual or emergency Bear shift until the whole pull ends, including when
    -- the healer enters combat before the druid.
    if buff.bear_form.up and (combat > 0 or Facade.TargetInPlayerCombat() == true or not partyIdle()) then
        return false
    end
    local instance = instanceType()
    if instance == "none" then
        return state.feral_pull
    end
    if instance == "raid" or instance == "scenario" then
        return role == "DAMAGER"
            and groupedInstance()
            and (
                state.feral_group_enemy
                or betweenPulls() and plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) == false
            )
    end
    if instance ~= "party" or (role ~= "NONE" and role ~= "DAMAGER") then
        return false
    end
    if state.feral_group_enemy then
        return role == "DAMAGER" or partyHasTank() == true
    end
    -- A damage player can prepare Cat between pulls without selecting or attacking an enemy.
    return betweenPulls()
        and partyHasTank() == true
        and partyIdle()
        and plain(Facade.C_InstanceEncounter.IsEncounterInProgress()) == false
end)
spec:RegisterStateExpr("feral_loose_target", function()
    return state.offset == 0
        and (state.feral_pull or state.feral_group_enemy)
        and groupTank()
        and recovery.looseVictim() ~= nil
        and not Facade.DebuffImmunity("growl", Facade.UnitGUID("target"), Facade.GetTime())
end)
local pickupSpells = { "growl", "primal_bite", "lacerate", "maul" }
spec:RegisterStateExpr("feral_recover_threat", function()
    if
        state.offset ~= 0
        or not (state.feral_pull or state.feral_group_enemy)
        or not groupTank()
        or not state.buff.bear_form.up
    then
        return false
    end
    local sample = recovery.evidence()
    if not sample or not sample.other then
        return false
    end
    local rage = min(state.rage.lo, state.rage.actual_lo or state.rage.lo)
    for _, key in ipairs(pickupSpells) do
        local a = state.action[key]
        if
            (key ~= "growl" or sample.otherTauntable)
            and a.known
            and not a.disabled
            and state.cooldown[key].ready
            and a.cost <= rage
        then
            return true
        end
    end
    return false
end)

-- A plain spell answer wins. When hidden, a confirmed distance bracket can still prove a
-- supported action is in reach. An unknown interval or one crossing a range boundary cannot.
local meleeActions = {
    auto_attack = true,
    bash = true,
    claw = true,
    ferocious_bite = true,
    lacerate = true,
    maul = true,
    primal_bite = true,
    rake = true,
    ravage = true,
    rip = true,
    shred = true,
    swipe_bear = true,
}
spec:RegisterStateExpr("feral_spell_range", function()
    local key = state.this_action
    local ability = action[key]
    if not ability then
        return false
    end
    local range = plain(C_Spell.IsSpellInRange(ability.id, "target"))
    if range ~= nil then
        return range
    end
    local plate = Facade.TargetMemoryPlate(Facade.TargetMemoryKey())
    if plate and recovery.plates[plate] then
        range = plain(C_Spell.IsSpellInRange(ability.id, plate))
        if range ~= nil then
            return range
        end
    end
    local near, far = Facade.LibRangeCheck:GetRange("target")
    near, far = plain(near), plain(far)
    if not far then
        return false
    end
    if meleeActions[key] then
        return far <= 5
    end
    if key == "faerie_fire" or key == "wrath" or key == "moonfire" then
        return far <= 30
    end
    return key == "feral_charge" and near ~= nil and near >= 8 and far <= 25
end)

spec:RegisterStateExpr("feral_attack_in_range", function()
    if state.feral_sustained then
        return not groupedInstance() or state.feral_spell_range
    end
    return state.feral_pull and state.feral_spell_range
end)

local function targetLife()
    local seconds = state.target.real_ttd
    if seconds < 3600 then
        return seconds - state.offset - state.delay
    end
end

spec:RegisterStateExpr("feral_dying", function()
    local seconds = targetLife()
    if seconds then
        return seconds <= 3
    end
    local health = Facade.TargetHealthUpperFraction()
    return health ~= nil and health <= 0.25
end)

spec:RegisterStateExpr("feral_bleed_worthwhile", function()
    local seconds = targetLife()
    if seconds then
        return seconds >= 6
    end
    return not state.feral_dying
end)

spec:RegisterStateExpr("feral_leveling_rip", function()
    return instanceType() == "none" and (targetLife() or 0) >= 6
end)

local function durableEnemy(unit)
    local kind = plain(Facade.UnitClassification(unit))
    return kind == "elite" or kind == "rareelite" or kind == "worldboss"
end

spec:RegisterStateExpr("feral_durable", function()
    return state.target.is_boss or durableEnemy("target")
end)

spec:RegisterStateExpr("feral_bite_fallback", function()
    return not action.rip.known
        or action.rip.disabled
        or Facade.DebuffImmunity("rip", Facade.UnitGUID("target"), Facade.GetTime()) ~= nil
end)

local spreadAuras = { rake = {}, faerie_fire = {}, lacerate = {} }
for key, family in pairs({ rake = RAKE, faerie_fire = FAERIE_FIRE, lacerate = LACERATE }) do
    for _, id in ipairs(family) do
        spreadAuras[key][id] = true
    end
end

local function spreadVictim(unit, victim, key)
    if key == "lacerate" then
        local threat = plain(Facade.UnitThreatSituation("player", unit))
        return (threat == 2 or threat == 3) and plain(Facade.UnitIsUnit(victim, "player")) == true
    end
    if key == "rake" then
        -- Preserve the tank's focus when the Cat or a healer draws an add.
        for _, member in ipairs(partyUnits) do
            if plain(Facade.UnitIsUnit(victim, member)) == true and Facade.GroupRole(member) == "TANK" then
                return true
            end
        end
        return false
    end
    return plain(Facade.UnitIsUnit(victim, "player")) == true or plain(Facade.UnitInParty(victim)) == true
end

local function spreadEnemy(unit, victim, key)
    if
        plain(Facade.UnitCanAttack("player", unit)) ~= true
        or plain(Facade.UnitIsDead(unit)) ~= false
        or plain(Facade.UnitIsPlayer(unit)) ~= false
        or plain(Facade.UnitAffectingCombat(unit)) ~= true
        or not spreadVictim(unit, victim, key)
        or feralCrowdControlled(unit) ~= false
    then
        return false
    end
    local inRange = plain(C_Spell.IsSpellInRange(state.action[key].id, unit))
    if inRange == nil then
        local _, far = Facade.LibRangeCheck:GetRange(unit)
        far = plain(far)
        inRange = type(far) == "number" and far <= (key == "faerie_fire" and 30 or 5)
    end
    return inRange == true
end

local function spreadMissing(unit, victim, key)
    local guid = plain(Facade.UnitGUID(unit))
    local health = Facade.ObservedUnitHealthFraction(unit)
    return guid ~= nil
        and (health == nil or health > 0.25)
        and (key ~= "lacerate" or durableEnemy(unit))
        and (unit ~= "target" or key == "faerie_fire" or state.feral_bleed_worthwhile)
        and spreadEnemy(unit, victim, key)
        and not Facade.DebuffBlocked(key, state.now, guid)
        and Facade.UnitHasObservedDebuff(unit, spreadAuras[key], key ~= "faerie_fire") == false
end

local function spreadRole(key)
    if key == "rake" then
        return state.buff.cat_form.up and Facade.GroupRole("player") == "DAMAGER" and state.combo_points.current == 0
    end
    if key == "lacerate" then
        return state.buff.bear_form.up and state.feral_held_pack
    end
    return key == "faerie_fire" and instanceType() == "party" and state.buff.bear_form.up and groupTank()
end

spec:RegisterHook("CanAcceptCycleTarget", function(key)
    if spreadAuras[key] and state.feral_field then
        return spreadRole(key) and spreadMissing("target", "targettarget", key)
    end
end)

spec:RegisterStateExpr("feral_spread_target", function()
    local key = state.this_action
    if
        state.offset ~= 0
        or state.combat == 0
        or not state.settings.cycle
        or state.max_targets == 1
        or state.toggle.mode == "single"
        or not state.feral_pull
        or (plain(Facade.GetNumGroupMembers()) or 0) <= 1
        or not spreadRole(key)
    then
        return false
    end
    if state.cycleInfo.selected then
        return spreadMissing("target", "targettarget", key)
    end
    if
        not spreadEnemy("target", "targettarget", key)
        or Facade.UnitHasObservedDebuff("target", spreadAuras[key], key ~= "faerie_fire") ~= true
    then
        return false
    end
    local current = plain(Facade.UnitGUID("target"))
    if not current then
        return false
    end
    for unit, victim in pairs(recovery.plates) do
        if
            plain(Facade.UnitGUID(unit)) ~= current
            and plain(Facade.UnitIsUnit("target", unit)) == false
            and spreadMissing(unit, victim, key)
        then
            return true
        end
    end
    return false
end)

spec:RegisterStateExpr("feral_primary", function()
    return state.filter == "none"
end)
spec:RegisterStateExpr("feral_interrupt", function()
    return state.offset == 0
        and state.OnToggleDisplay("interrupts")
        and debuff.casting.up
        and Facade.TargetInPlayerCombat() == true
        and not controlledTarget()
        and (state.combat > 0 or (plain(Facade.GetNumGroupMembers()) or 0) > 1)
        and Facade.TargetCastInterruptible()
        and state.pve_priority_interrupt
end)

spec:RegisterStateExpr("feral_defense", function()
    local instance = instanceType()
    return state.offset == 0
        and (instance == "none" or instance == "party" or instance == "raid" or instance == "scenario")
        and plain(Facade.UnitIsDeadOrGhost("player")) == false
        and plain(Facade.UnitAffectingCombat("player")) == true
        and state.OnToggleDisplay("defensives")
end)

local function healNeedsCaster()
    return plain(Facade.GetCVar("autoUnshift")) ~= "1" and "feral_form" or nil
end

-- Casting a humanoid heal with automatic unshifting enabled leaves the form. A heal on a
-- groupmate has the same form transition; only the actual player's aura proves a self HoT.
local function healEffect(consumesSwiftness)
    return function()
        for i = 1, #FORMS do
            removeBuff(FORMS[i])
        end
        removeBuff("maul")
        if consumesSwiftness then
            removeBuff("natures_swiftness")
        end
    end
end

spec:RegisterStateExpr("feral_prowling", function()
    return action.prowl.known and buff.prowl.up
end)
spec:RegisterStateExpr("feral_behind", function()
    if state.settings.behind then
        return true
    end
    local facingAway = targetFacingAway()
    if facingAway ~= nil then
        return facingAway
    end
    return buff.prowl.up and plain(Facade.UnitAffectingCombat("target")) == false
end)

-- Routine cast-time recovery needs a break between enemies. A hidden target fact
-- cannot establish that the selected unit is harmless.
local function restingTarget()
    return plain(Facade.UnitExists("target")) == false
        or plain(Facade.UnitIsDead("target")) == true
        or plain(Facade.UnitCanAttack("player", "target")) == false
end
spec:RegisterStateExpr("feral_resting_target", restingTarget)

local function preparing()
    return feralField()
        and betweenPulls()
        and (not groupTank() or partyIdle())
        and (
            restingTarget()
            or Facade.TargetInPlayerCombat() == false and Facade.UnitIsUnit("targettarget", "player") ~= true
        )
end
local function selfSpell(key)
    local a = state.action[key]
    return a.known
        and not a.disabled
        and (a.cast_time == 0 or not state.moving)
        and a.cost <= min(state.mana.lo, state.mana.actual_lo or state.mana.lo)
        and Hekili:CanSelfCastHelpfulSpell(a.id)
end
-- Another Druid's Gift covers Mark even before this character learns the group buff.
spec:RegisterStateExpr("feral_mark_missing", function()
    return buff.mark_of_the_wild.down and buff.gift_of_the_wild.down
end)
spec:RegisterStateExpr("feral_prepare_spell", function()
    return preparing() and state.buff.form.down and selfSpell(state.this_action)
end)
spec:RegisterStateExpr("feral_prepare_heal", function()
    return preparing()
        and state.OnToggleDisplay("defensives")
        and selfSpell(state.this_action)
        and (state.buff.form.down or state.buff.feral_form.up and not healNeedsCaster())
end)
spec:RegisterStateExpr("feral_prepare_elite", function()
    if not state.feral_prepare_spell or not state.feral_pull or instanceType() ~= "none" then
        return false
    end
    local kind = plain(Facade.UnitClassification("target"))
    return (kind == "elite" or kind == "rareelite")
        and state.action.bear_form.known
        and state.mana.lo >= state.action.regrowth.cost + state.action.bear_form.cost
end)
spec:RegisterStateExpr("feral_self_dispel", function()
    return state.OnToggleDisplay("defensives")
        and state.buff.form.down
        and selfSpell(state.this_action)
        and (preparing() or state.feral_defense and state.solo and state.feral_pull)
end)
spec:RegisterStateExpr("feral_unshift_heal", function()
    return healNeedsCaster()
        and preparing()
        and state.OnToggleDisplay("defensives")
        and (
            selfSpell("healing_touch")
            or selfSpell("regrowth")
            or selfSpell("rejuvenation") and state.buff.rejuvenation.down
        )
end)
spec:RegisterStateExpr("feral_emergency_bear", function()
    return state.feral_defense
        and state.feral_pull
        and state.solo
        and state.target.is_targeting_player
        and state.buff.cat_form.up
end)
spec:RegisterStateExpr("feral_caster_heal", function()
    return state.feral_defense
        and state.feral_pull
        and state.solo
        and state.buff.form.down
        and not state.action.bear_form.known
        and selfSpell(state.this_action)
end)

-- A shift (Classic's swap_form, Forever's rules): the other forms and a queued Maul go; into Bear all rage is lost,
-- then Furor's 10 at 20% a rank (wowsims forms.go): the sim from its floor, so at 5/5 only (the belief's `now` sets
-- 1-4/5's unseen roll as [0, 10]); into Cat the rage stays (wowsims's Cat Form leaves it: the decay takes it out of
-- combat) and the energy becomes Furor's 20% a rank of the pool (wowsims forms.go restoreCatEnergy; the pool is its
-- stored energy, bear_pause above): none untalented, as the owner's client showed (L586). wowsims keeps the bar on a
-- first entry with nothing stored, its pull only: the belief cannot tell one after a /reload, so every entry takes
-- the share. The forms' `now` write the same lines.
spec:RegisterStateFunction("swap_form", function(form)
    for i = 1, #FORMS do
        removeBuff(FORMS[i])
    end
    removeBuff("maul")
    if form == "bear_form" then
        spend(rage.lo, "rage") -- the sim's floor (border batch 2)
        if talent.furor.rank >= 5 then
            gain(FUROR_RAGE, "rage")
        end
    elseif form == "cat_form" then
        spend(energy.lo * (5 - talent.furor.rank) / 5, "energy") -- keeps rank / 5 of the sim's floor (border batch 2)
    end
    applyBuff(form)
end)

spec:RegisterHook("reset_precast", function()
    -- The form comes from the belief's Forms source (Game/State/Sources/Forms.lua) through the aura walk.
    local maul = knownRank(MAUL)
    if maul > 0 and IsCurrentSpell(MAUL[maul]) then
        applyBuff("maul")
    end
end)

spec:RegisterAbilities({
    auto_attack = {
        id = 6603,
        texture = 135274,
        cooldown = 0,
        gcd = "off",
        startsCombat = true,
        known = knows({ 6603 }),
        nobuff = "feral_autoattacking",
        usable = function()
            return (state.feral_pull or state.feral_group_enemy or state.feral_tank_opener)
                and buff.prowl.down
                and state.feral_spell_range
                and plain(IsCurrentSpell(6603)) == false
        end,
        handler = function()
            applyBuff("feral_autoattacking")
        end,
    },
    recover_threat = {
        name = L["Recover Threat"],
        texture = Hekili.TargetSwapTexture,
        unlisted = true,
        targetSwap = true,
        targetSwapSafe = recovery.safeLanding,
        gcd = "off",
        startsCombat = false,
        usable = function()
            return state.feral_recover_threat
        end,
    },
    aquatic_form = {
        id = 1066,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return 0.20
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(AQUATIC_FORM),
        nobuff = "aquatic_form",

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            for i = 1, #FORMS do
                removeBuff(FORMS[i])
            end
            removeBuff("maul")
            applyBuff("aquatic_form")
        end,

        handler = function()
            swap_form("aquatic_form")
        end,
    },

    barkskin = {
        id = 22812,
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        startsCombat = false,
        known = knows(BARKSKIN),
        toggle = "defensives",

        now = function()
            applyBuff("barkskin")
        end,

        handler = function()
            applyBuff("barkskin")
        end,
    },

    bash = {
        id = 5211,
        copy = rest(BASH),
        cast = 0,
        debuffApplication = "bash",
        cooldown = function()
            return 60 - 15 * talent.brutal_impact.rank -- Brutal Impact 16940 effect 1: -15 / -30 s on Bash
        end,
        gcd = "spell",

        spend = 10,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims bash.go; DB2 Discount Power On Miss
        known = knows(BASH),
        toggle = "interrupts",
        form = "bear_form",
        priorityInterruptRange = { 0, 5 },
        priorityInterruptStun = true,
        priorityInterruptNeedsKickable = true, -- the Bear priorities require an explicitly interruptible cast
        priorityInterruptBlocked = feralCrowdControlled,

        now = function()
            applyDebuff("target", "bash", (BASH_STUN[knownRank(BASH)] or 2) + 0.5 * talent.brutal_impact.rank)
        end,

        handler = function()
            applyDebuff("target", "bash")
        end,
    },

    bear_form = {
        id = 5487,
        copy = { 9634 },
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return 0.55
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(BEAR_FORM),
        defensives = true,
        nobuff = "bear_form",

        now = function()
            for i = 1, #FORMS do
                removeBuff(FORMS[i])
            end
            removeBuff("maul")
            local f = talent.furor.rank -- all rage goes, then Furor's (swap_form): certain at 5/5, a roll below
            -- luacheck: push read globals resetResource (the belief's verb, Families/Now.lua: a `now` only)
            resetResource("rage", f >= 5 and FUROR_RAGE or 0, f > 0 and f < 5 and FUROR_RAGE or 0)
            -- luacheck: pop
            applyBuff("bear_form")
        end,

        handler = function()
            swap_form("bear_form")
        end,
    },

    berserk = {
        id = 417141,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        startsCombat = false,
        known = knows(BERSERK),
        toggle = "cooldowns",
        -- "Requires Cat Form, Bear Form, Dire Bear Form" (DB2 text): whichever is up.
        form = function()
            if buff.bear_form.up then
                return "bear_form"
            end
            return "cat_form"
        end,

        now = function()
            applyBuff("berserk")
            setCooldown("primal_bite", 0) -- Berserk removes Primal Bite's cooldown (DB2 text)
        end,

        handler = function()
            applyBuff("berserk")
            setCooldown("primal_bite", 0)
        end,
    },

    cat_form = {
        id = 768,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return 0.55
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(CAT_FORM),
        nobuff = "cat_form",

        now = function()
            for i = 1, #FORMS do
                removeBuff(FORMS[i])
            end
            removeBuff("maul")
            spend(energy.current * (5 - talent.furor.rank) / 5, "energy") -- Furor (swap_form)
            applyBuff("cat_form")
        end,

        handler = function()
            swap_form("cat_form")
        end,
    },

    challenging_roar = {
        id = 5209,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 600,
        gcd = "spell",

        spend = 15,
        spendType = "rage",

        startsCombat = true,
        known = knows(CHALLENGING_ROAR),
        toggle = "defensives",
        form = "bear_form",

        now = function()
            applyDebuff("target", "challenging_roar")
        end,

        handler = function()
            applyDebuff("target", "challenging_roar")
        end,
    },

    claw = {
        id = 1082,
        copy = rest(CLAW),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return max(0, 45 - talent.ferocity.rank)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims claw.go; DB2 Discount Power On Miss
        known = knows(CLAW),
        form = "cat_form",

        -- a builder's point only on a landed hit (wowsims claw.go:13-16): the plain read after the cast proves which
        now = function()
            gain(1, "combo_points")
        end,

        handler = function()
            gain(1, "combo_points")
        end,
    },

    cower = {
        id = 8998,
        copy = rest(COWER),
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = 20,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims cower.go; DB2 Discount Power On Miss
        known = knows(COWER),
        form = "cat_form",
    },

    dash = {
        id = 1850,
        copy = rest(DASH),
        cast = 0,
        cooldown = 300,
        gcd = "off",

        startsCombat = false,
        known = knows(DASH),
        form = "cat_form",

        now = function()
            applyBuff("dash")
        end,

        handler = function()
            applyBuff("dash")
        end,
    },

    demoralizing_roar = {
        id = 99,
        -- it deals no damage, so its ticket pays its own avoid only, never a Maul's wound in its frame
        expects = "debuff",
        areaDebuff = { aura = "demoralizing_roar", radius = 10, melee = MAUL },
        copy = rest(DEMORALIZING_ROAR),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 10,
        spendType = "rage",

        startsCombat = true,
        known = knows(DEMORALIZING_ROAR),
        form = "bear_form",

        now = function()
            applyDebuff("target", "demoralizing_roar")
        end,

        handler = function()
            applyDebuff("target", "demoralizing_roar")
        end,
    },

    -- 10 rage now (DB2 effect 30 base 100), then 2 a second for 10 s from its aura (the rage resource's entry).
    enrage = {
        id = 5229,
        cast = 0,
        cooldown = 60,
        gcd = "off",

        startsCombat = false,
        known = knows(ENRAGE),
        form = "bear_form",

        now = function()
            gain(buff.wolfshead_helm.up and 15 or 10, "rage")
            applyBuff("enrage")
        end,

        handler = function()
            gain(buff.wolfshead_helm.up and 15 or 10, "rage")
            applyBuff("enrage")
        end,
    },

    entangling_roots = {
        id = 339,
        copy = rest(ROOTS),
        cast = function()
            return buff.natures_swiftness.up and 0 or 1.5
        end,
        debuffApplication = "entangling_roots",
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(ROOTS_COST, ROOTS) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(ROOTS),
        nobuff = "feral_form",

        now = function()
            removeBuff("natures_swiftness")
            applyDebuff("target", "entangling_roots", ROOTS_DURATION[knownRank(ROOTS)] or 12)
        end,

        handler = function()
            removeBuff("natures_swiftness")
            applyDebuff("target", "entangling_roots")
        end,
    },

    faerie_fire = {
        id = 770,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(FAERIE_FIRE),
        cast = 0,
        -- Free with a 6 s cooldown in Cat or Bear Form (TDF Bear.lua; checkpoint Q7 confirms).
        cooldown = function()
            return (buff.cat_form.up or buff.bear_form.up) and 6 or 0 -- not the `feral_form` alias: no belief read
        end,
        -- 1 s in Cat Form: the Cat Form passive's GCD mod (wowsims pin spells_auto_gen.go:2014, 3025 effect 4: -500 ms
        -- on this mask); the Bear Form passives (1178, 9635) carry none, so Bear keeps the spell GCD.
        gcd = function()
            return buff.cat_form.up and "totem" or "spell"
        end,

        spend = function()
            if buff.cat_form.up or buff.bear_form.up then
                return 0
            end
            return byRank(FAERIE_FIRE_COST, FAERIE_FIRE)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(FAERIE_FIRE),

        now = function()
            applyDebuff("target", "faerie_fire")
        end,

        handler = function()
            applyDebuff("target", "faerie_fire")
        end,
    },

    feral_charge = {
        id = 1238122,
        copy = { 16979 },
        -- no damage (DB2, wowsims): its ticket takes its own avoid only. The root lands when the charge arrives: its
        -- Cooldown Manager item lit 863 ms after the cast (L361), so the charge's speed widens the belief's verdict
        -- window for it alone (L450).
        -- shortcut: 21 yd/s, not 25 / 0.863 = 29: that one sample's distance is unknown, and if it was shorter than 25
        -- yd the true speed is lower, so 29 would close a landed full-range root (cdm-facts fix round 1); upgrade with a
        -- probe line pairing the charge's distance with its root's light
        expects = "debuff",
        velocity = 21,
        cast = 0,
        cooldown = 15,
        gcd = "off",

        -- 5 in Bear Form only: the DB2 stance mask (0x91) holds Cat Form too, where a usable answer pinned the floor at
        -- 5 out of combat with the client's bar at 0 (owner 2026-11-12; the poll repeats it every pass). A cost of 0
        -- is no rage rung, and a Cat-Form charge spends no rage.
        spend = function()
            return buff.bear_form.up and 5 or 0
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(FERAL_CHARGE),
        interrupts = true,
        form = "bear_form",
        priorityInterruptRange = { 8, 25 },
        priorityInterruptBlocked = feralCrowdControlled,

        now = function()
            applyDebuff("target", "feral_charge_effect")
        end,

        handler = function()
            applyDebuff("target", "feral_charge_effect")
        end,
    },

    -- Bite converts all the energy left after its cost (DB2 22568 text), Clearcasting's free Bite too.
    ferocious_bite = {
        id = 1328618, -- hotfix 113554: rank 1 at 24 (22568 now rank 2)
        copy = rest(FEROCIOUS_BITE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = 35,
        spendType = "energy",
        -- max_energy=1's cap: Bite converts all the energy it has, uncapped (wowsims ferocious_bite.go
        -- `extra := CurrentEnergy()`), so the core's cost-plus-cap clamp at the pool's max means full energy
        excess_cap = function()
            return energy.max
        end,

        startsCombat = true,
        -- wowsims e4ef929e54 ferocious_bite.go refundOnMiss: 80% of the 35 base energy back on an avoid
        refundOnAvoid = true,
        -- ferocious_bite.go:32-40: the extra energy is spent on a landed bite only, so an avoid gives `now`'s spend back
        refundNowOnAvoid = true,
        known = knows(FEROCIOUS_BITE),
        form = "cat_form",

        usable = function()
            return combo_points.current > 0, "requires combo points"
        end,

        -- Predatory Discipline (hotfix 113554, wowsims ferocious_bite.go): the extra energy stays. Spent at the cast;
        -- an avoid gives it back (refundNowOnAvoid). `onLand` would idle it on live (target rows secret).
        now = function()
            if not talent.predatory_discipline.enabled then
                spend(energy.current, "energy")
            end
        end,

        handler = function()
            spend(combo_points.current, "combo_points")
            if not talent.predatory_discipline.enabled then
                spend(energy.lo, "energy") -- the sim's floor (border batch 2)
            end
        end,
    },

    -- Its rage drain is unmodelled: health is secret, and the drain stops at full health.
    frenzied_regeneration = {
        id = 22842,
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        startsCombat = false,
        known = knows(FRENZIED_REGENERATION),
        toggle = "defensives",
        form = "bear_form",

        now = function()
            applyBuff("frenzied_regeneration")
        end,

        handler = function()
            applyBuff("frenzied_regeneration")
        end,
    },

    gift_of_the_wild = {
        id = 21849,
        copy = rest(GIFT_OF_THE_WILD),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(GIFT_OF_THE_WILD_COST, GIFT_OF_THE_WILD)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(GIFT_OF_THE_WILD),
        nobuff = "feral_form",

        now = function()
            applyBuff("gift_of_the_wild")
        end,

        handler = function()
            applyBuff("gift_of_the_wild")
        end,
    },

    growl = {
        id = 6795,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 8,
        gcd = "off",

        startsCombat = true,
        debuffApplication = "growl",
        known = knows(GROWL),
        form = "bear_form",

        now = function()
            applyDebuff("target", "growl")
        end,

        handler = function()
            applyDebuff("target", "growl")
        end,
    },

    healing_touch = {
        id = 5185,
        copy = rest(HEALING_TOUCH),
        cast = function()
            if buff.natures_swiftness.up then
                return 0
            end
            -- Naturalist 17069 effect 0: -0.1 s a rank on Healing Touch (and Wild Growth)
            return byRank(HEALING_TOUCH_CAST, HEALING_TOUCH) - 0.1 * talent.improved_healing_touch.rank
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            -- Tranquil Spirit 24968: -2% a rank on Healing Touch and Tranquility
            return byRank(HEALING_TOUCH_COST, HEALING_TOUCH) * (1 - 0.02 * talent.tranquil_spirit.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(HEALING_TOUCH),
        defensives = true,
        nobuff = healNeedsCaster,
        effect = function()
            return healEffect(true)
        end,
    },

    hurricane = {
        id = 16914,
        copy = rest(HURRICANE),
        cast = 10,
        channeled = true,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(HURRICANE_COST, HURRICANE) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HURRICANE),
        nobuff = "feral_form",
        aura = "hurricane",

        now = function()
            applyDebuff("target", "hurricane")
        end,

        start = function()
            applyDebuff("target", "hurricane")
        end,
    },

    innervate = {
        id = 29166,
        cast = 0,
        cooldown = 360,
        gcd = "spell",

        spend = function()
            return 0.05
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(INNERVATE),
        toggle = "cooldowns",

        -- From any other form: the client leaves it to cast (Classic's handler, swap_form( "" )); the Feral priority
        -- shifts back after it.
        -- wowsims/forever: castable in Moonkin Form; UNMEASURED on Forever (checkpoint in layout.md)
        now = function()
            for i = 1, #FORMS do
                if FORMS[i] ~= "moonkin_form" then
                    removeBuff(FORMS[i])
                end
            end
            removeBuff("maul")
            applyBuff("innervate")
        end,

        handler = function()
            for i = 1, #FORMS do
                if FORMS[i] ~= "moonkin_form" then
                    removeBuff(FORMS[i])
                end
            end
            removeBuff("maul")
            applyBuff("innervate")
        end,
    },

    insect_swarm = {
        id = 5570,
        expects = "ticks",
        school = "nature", -- its debuff dot aura: 2 s ticks over its duration (talent and gear)
        copy = rest(INSECT_SWARM),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(INSECT_SWARM_COST, INSECT_SWARM) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(INSECT_SWARM),
        nobuff = "feral_form",

        now = function()
            applyDebuff("target", "insect_swarm") -- the aura's own duration (talent and gear)
        end,

        handler = function()
            applyDebuff("target", "insect_swarm")
        end,
    },

    lacerate = {
        id = 1328617,
        copy = rest(LACERATE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        -- Shredding Attacks: -1 rage a rank, wowsims's (its log: Cost = 13 at 2/3); the DB2 text's ${$m2/-10} reads 6
        -- (m2 = -60; checkpoint Q12)
        spend = function()
            return max(0, 15 - talent.improved_shred.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims lacerate.go; DB2 Discount Power On Miss
        onCrit = primalFuryOnCrit(),
        known = knows(LACERATE),
        form = "bear_form",

        now = function()
            applyDebuff("target", "lacerate", 15, min(5, debuff.lacerate.stack + 1))
        end,

        handler = function()
            applyDebuff("target", "lacerate", 15, min(5, debuff.lacerate.stack + 1))
        end,
    },

    mark_of_the_wild = {
        id = 1126,
        copy = rest(MARK_OF_THE_WILD),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(MARK_OF_THE_WILD_COST, MARK_OF_THE_WILD)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(MARK_OF_THE_WILD),
        nobuff = "feral_form",

        now = function()
            applyBuff("mark_of_the_wild")
        end,

        handler = function()
            applyBuff("mark_of_the_wild")
        end,
    },

    maul = {
        id = 6807,
        copy = rest(MAUL),
        cast = 0,
        cooldown = 0,
        gcd = "off",

        spend = function()
            return max(0, 15 - talent.ferocity.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims maul.go; DB2 Discount Power On Miss
        onCrit = primalFuryOnCrit(),
        -- The belief: paid at the main hand's next swing, which then brings no rage. Hekili's own simulation pays
        -- at the press (the Warrior's Heroic Strike alike), so the two differ by up to one swing.
        onNextSwing = true,
        known = knows(MAUL),
        form = "bear_form",

        usable = function()
            return not buff.maul.up, "Maul is already queued"
        end,

        handler = function()
            applyBuff("maul")
        end,
    },

    moonfire = {
        id = 8921,
        expects = "instant",
        school = "arcane", -- its debuff dot aura ticks every 3 s, 9 or 12 s by rank
        copy = rest(MOONFIRE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(MOONFIRE_COST, MOONFIRE) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(MOONFIRE),
        nobuff = "feral_form",

        now = function()
            local base = knownRank(MOONFIRE) > 1 and 12 or 9 -- rank 1 lasts 9 s
            applyDebuff("target", "moonfire", base + 3 * talent.natures_splendor.rank)
        end,

        handler = function()
            applyDebuff("target", "moonfire")
        end,
    },

    moonkin_form = {
        id = 24858,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return 0.35
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(MOONKIN_FORM),
        nobuff = "moonkin_form",

        now = function()
            for i = 1, #FORMS do
                removeBuff(FORMS[i])
            end
            removeBuff("maul")
            applyBuff("moonkin_form")
        end,

        handler = function()
            swap_form("moonkin_form")
        end,
    },

    natures_swiftness = {
        id = 17116,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        startsCombat = false,
        known = knows({ 17116 }),
        nobuff = "moonkin_form", -- the pin: the row bars it on Moonkin Form

        now = function()
            applyBuff("natures_swiftness")
        end,

        handler = function()
            applyBuff("natures_swiftness")
        end,
    },

    natures_grasp = {
        id = 16689,
        copy = rest(NATURES_GRASP),
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        spend = function()
            return byRank(NATURES_GRASP_COST, NATURES_GRASP) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(NATURES_GRASP),
        nobuff = "feral_form",

        now = function()
            applyBuff("natures_grasp")
        end,

        handler = function()
            applyBuff("natures_grasp")
        end,
    },

    pounce = {
        id = 9005,
        copy = rest(POUNCE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = 50,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims pounce.go; DB2 Discount Power On Miss
        known = knows(POUNCE),
        missable = "pounce_bleed",
        buff = "prowl",

        now = function()
            removeBuff("prowl")
            applyDebuff("target", "pounce", 2 + 0.5 * talent.brutal_impact.rank)
            applyDebuff("target", "pounce_bleed")
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("prowl")
            applyDebuff("target", "pounce")
            applyDebuff("target", "pounce_bleed")
            gain(1, "combo_points")
        end,
    },

    primal_bite = {
        id = 407995,
        copy = rest(PRIMAL_BITE),
        cast = 0,
        -- 6 s (DB2 category); Berserk (417141, DB2 text) "removes its cooldown": its `now` and handler end the running
        -- one and none starts while it is up (the belief evaluates this in its own context, Families/Casts.lua).
        cooldown = function()
            return buff.berserk.up and 0 or 6
        end,
        gcd = "spell",

        spend = function()
            return max(0, 20 - talent.ferocity.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims primal_bite.go; DB2 Discount Power On Miss
        onCrit = primalFuryOnCrit(),
        known = knows(PRIMAL_BITE),
        form = "bear_form",
    },

    prowl = {
        id = 5215,
        copy = rest(PROWL),
        cast = 0,
        cooldown = 10,
        gcd = "off",

        startsCombat = false,
        known = knows(PROWL),
        form = "cat_form",

        usable = function()
            return combat == 0, "cannot be in combat"
        end,

        now = function()
            applyBuff("prowl")
        end,

        handler = function()
            applyBuff("prowl")
        end,
    },

    rake = {
        id = 1822,
        copy = rest(RAKE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return max(0, 40 - talent.ferocity.rank)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims rake.go; DB2 Discount Power On Miss
        known = knows(RAKE),
        -- a dodged, parried or missed cast leaves no debuff (core: Engine/Schema/Spec/Abilities.lua trackMisses)
        missable = true,
        form = "cat_form",

        now = function()
            applyDebuff("target", "rake")
            gain(1, "combo_points")
        end,

        handler = function()
            applyDebuff("target", "rake")
            gain(1, "combo_points")
        end,
    },

    ravage = {
        id = 6785,
        copy = rest(RAVAGE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = 60,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims ravage.go; DB2 Discount Power On Miss
        known = knows(RAVAGE),
        buff = "prowl",

        now = function()
            removeBuff("prowl")
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("prowl")
            gain(1, "combo_points")
        end,
    },

    regrowth = {
        id = 8936,
        copy = rest(REGROWTH),
        cast = function()
            return buff.natures_swiftness.up and 0 or 2
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(REGROWTH_COST, REGROWTH)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(REGROWTH),
        defensives = true,
        nobuff = healNeedsCaster,
        effect = function()
            return healEffect(true)
        end,
    },

    rejuvenation = {
        id = 774,
        copy = rest(REJUVENATION),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(REJUVENATION_COST, REJUVENATION)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(REJUVENATION),
        defensives = true,
        nobuff = healNeedsCaster,
        effect = function()
            return healEffect(false)
        end,
    },

    rip = {
        id = 1079,
        debuffApplication = "rip",
        copy = rest(RIP),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = 30,
        spendType = "energy",

        startsCombat = true,
        expects = "debuff", -- no direct damage (wowsims rip.go: CalcAndDealOutcome): a white wound in its frame is never its
        refundOnAvoid = true, -- wowsims rip.go; DB2 Discount Power On Miss
        known = knows(RIP),
        missable = true,
        form = "cat_form",

        usable = function()
            return combo_points.current > 0, "requires combo points"
        end,

        now = function()
            applyDebuff("target", "rip")
        end,

        handler = function()
            applyDebuff("target", "rip")
            spend(combo_points.current, "combo_points")
        end,
    },

    -- Forever's Tiger's Fury replacement: 55% of base mana into 40 energy (DB2 1322605). No toggle: it is the core.
    shifting_power = {
        id = 1322605,
        cast = 0,
        -- spec D5; checkpoint Q4. 8 s by hotfix 113554 (wowsims 5508974417; Improved Shifting Power removed; the
        -- DB2 70707 base file still says 16). The Howling Idol's equip aura (1291059) takes 0.5 s off (DB2 1291059
        -- effect 1310233 -500 ms; wowsims sim/druid/item_idols.go and TestHowlingIdolShortensShiftingPower, both pins).
        cooldown = function()
            return buff.howling_idol.up and 7.5 or 8
        end,
        gcd = "totem",

        spend = function()
            return 0.55
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(SHIFTING_POWER),
        form = "cat_form",

        now = function()
            gain(SHIFTING_POWER_ENERGY + (buff.wolfshead_helm.up and 5 or 0), "energy")
        end,

        handler = function()
            gain(SHIFTING_POWER_ENERGY + (buff.wolfshead_helm.up and 5 or 0), "energy")
        end,
    },

    shred = {
        id = 5221,
        copy = rest(SHRED),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return max(0, 60 - 6 * talent.improved_shred.rank)
        end, -- Shredding Attacks
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims shred.go; DB2 Discount Power On Miss
        known = knows(SHRED),
        form = "cat_form",

        -- Shred needs us behind the target: the packs' Shred and Claw lines choose by `target.is_targeting_player`,
        -- `settings.behind` and Shredding Attacks (tools/wowsims/specs/druid_feral.lua, L602)
        now = function()
            gain(1, "combo_points")
        end,

        handler = function()
            gain(1, "combo_points")
        end,
    },

    starfire = {
        id = 2912,
        expects = "instant",
        school = "arcane",
        copy = rest(STARFIRE),
        -- 3.5 s less Improved Starfire (0.1 a rank) and the Eclipse cut, then Nature's Grace's 10 % cast speed
        cast = function()
            local t = 3.5 - 0.1 * talent.improved_starfire.rank
            if buff.eclipse.up then
                t = t - (ECLIPSE_CUT[talent.eclipse.rank] or 0)
            end
            if buff.natures_grace.up then
                t = t / 1.1
            end
            return t
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(STARFIRE_COST, STARFIRE) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(STARFIRE),
        nobuff = "feral_form",

        -- Every Starfire cast spends an Eclipse charge, a missed one too (wowsims talents_balance.go applyEclipse); the
        -- belief at the cast with `removeStack` (aura audit C4).
        now = function()
            if buff.eclipse.up then
                removeStack("eclipse")
            end
        end,

        handler = function()
            if buff.eclipse.up then
                removeStack("eclipse")
            end
        end,
    },

    swipe_bear = {
        id = 779,
        copy = rest(SWIPE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return max(0, 20 - talent.ferocity.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(SWIPE),
        form = "bear_form",
        onCrit = primalFuryOnCrit(),
    },

    thorns = {
        id = 467,
        copy = rest(THORNS),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(THORNS_COST, THORNS) * moonglow(talent.moonglow.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(THORNS),
        nobuff = "feral_form",

        now = function()
            applyBuff("thorns")
        end,

        handler = function()
            applyBuff("thorns")
        end,
    },

    travel_form = {
        id = 783,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return 0.20
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(TRAVEL_FORM),
        nobuff = "travel_form",

        now = function()
            for i = 1, #FORMS do
                removeBuff(FORMS[i])
            end
            removeBuff("maul")
            applyBuff("travel_form")
        end,

        handler = function()
            swap_form("travel_form")
        end,
    },

    -- Swiftmend (consumes a Rejuvenation or Regrowth: no HoT aura in the pack, so only the press is modelled).
    swiftmend = {
        id = 18562,
        cast = 0,
        cooldown = 15,
        gcd = "spell",

        spend = 0.2,
        spendType = "mana",

        startsCombat = false,
        known = knows(SWIFTMEND),
        nobuff = "feral_form",
    },

    wild_growth = {
        id = 408120,
        copy = rest(WILD_GROWTH),
        cast = function()
            return 3 - 0.1 * talent.improved_healing_touch.rank -- Naturalist's mask holds Wild Growth
        end,
        cooldown = 6,
        gcd = "spell",

        spend = function()
            return byRank(WILD_GROWTH_COST, WILD_GROWTH)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(WILD_GROWTH),
        nobuff = "feral_form",
    },

    tranquility = {
        id = 740,
        copy = rest(TRANQUILITY),
        cast = 10,
        channeled = true,
        cooldown = function()
            return 300 * (1 - 0.3 * talent.improved_tranquility.rank) -- Improved Tranquility 17123 effect 1: -30 / -60%
        end,
        gcd = "spell",

        spend = function()
            return byRank(TRANQUILITY_COST, TRANQUILITY) * (1 - 0.02 * talent.tranquil_spirit.rank)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(TRANQUILITY),
        nobuff = "feral_form",
    },

    rebirth = {
        id = 20484,
        copy = rest(REBIRTH),
        cast = function()
            return buff.natures_swiftness.up and 0 or 2
        end,
        cooldown = 1800,
        gcd = "spell",

        spend = 0.85,
        spendType = "mana",

        startsCombat = false,
        known = knows(REBIRTH),
        nobuff = "feral_form",

        now = function()
            removeBuff("natures_swiftness")
        end,

        handler = function()
            removeBuff("natures_swiftness")
        end,
    },

    hibernate = {
        id = 2637,
        copy = rest(HIBERNATE),
        cast = function()
            return buff.natures_swiftness.up and 0 or 1.5
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(HIBERNATE_COST, HIBERNATE)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(HIBERNATE),
        nobuff = "feral_form",

        now = function()
            removeBuff("natures_swiftness")
        end,

        handler = function()
            removeBuff("natures_swiftness")
        end,
    },

    soothe_animal = {
        id = 2908,
        copy = rest(SOOTHE_ANIMAL),
        cast = function()
            return buff.natures_swiftness.up and 0 or 1.5
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(SOOTHE_ANIMAL_COST, SOOTHE_ANIMAL)
        end,
        spendType = "mana",

        startsCombat = false,
        known = knows(SOOTHE_ANIMAL),
        nobuff = "feral_form",

        now = function()
            removeBuff("natures_swiftness")
        end,

        handler = function()
            removeBuff("natures_swiftness")
        end,
    },

    abolish_poison = {
        id = 2893,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.16,
        spendType = "mana",

        startsCombat = false,
        defensives = true,
        known = knows(ABOLISH_POISON),
        nobuff = "feral_form",
    },

    cure_poison = {
        id = 8946,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.16,
        spendType = "mana",

        startsCombat = false,
        defensives = true,
        known = knows(CURE_POISON),
        nobuff = "feral_form",
    },

    remove_curse = {
        id = 2782,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = 0.1,
        spendType = "mana",

        startsCombat = false,
        defensives = true,
        known = knows(REMOVE_CURSE),
        nobuff = "feral_form",
    },

    revive = {
        id = 1237951,
        cast = 10,
        cooldown = 0,
        gcd = "off", -- the pin's row has no GCD

        spend = 0.75,
        spendType = "mana",

        startsCombat = false,
        known = knows(REVIVE),
        nobuff = "feral_form",
    },

    -- Cat Form's Feral Charge (the pin's 414924: 30 s, the spell GCD, no cost, Cat stance only); the Bear Form charge
    -- above spends 5 rage.
    feral_charge_cat = {
        id = 414924,
        cast = 0,
        cooldown = 30,
        gcd = "spell",

        startsCombat = true,
        known = knows(FERAL_CHARGE),
        form = "cat_form",
    },

    wrath = {
        id = 5176,
        expects = "travel",
        velocity = 20,
        school = "nature",
        copy = rest(WRATH),
        cast = function()
            if buff.natures_swiftness.up then
                return 0
            end
            local t = byRank(WRATH_CAST, WRATH) - 0.1 * talent.improved_wrath.rank
            if buff.natures_grace.up then
                t = t / 1.1
            end
            return t
        end,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return byRank(WRATH_COST, WRATH)
                * moonglow(talent.moonglow.rank)
                * (1 - 0.5 * talent.improved_wrath.rank / 5)
        end,
        spendType = "mana",

        startsCombat = true,
        known = knows(WRATH),
        nobuff = "feral_form",

        -- Nature's Swiftness spent (the handler's), and Eclipse's charges (R §9 open: +1 or +2 a Wrath) while the
        -- talent is known.
        now = function()
            removeBuff("natures_swiftness")
            if talent.eclipse.rank > 0 then
                addStack("eclipse", nil, 2)
            end
        end,

        handler = function()
            removeBuff("natures_swiftness")
            if talent.eclipse.rank > 0 then
                addStack("eclipse", nil, 2)
            end
        end,
    },
})

-- The setting the packs' Shred and Claw lines read (TDF's name and default): Shred as if always behind the target, the
-- target attacking us or not (L603); Guardian's is below (its imported cat lists).
local behind = {
    type = "toggle",
    name = L["Always Behind"],
    desc = L["Hekili assumes you are always behind the target. Below 2 ranks of Shredding Attacks, Claw is still preferred unless Clearcasting makes Shred free."],
    width = "full",
}
spec:RegisterSetting("behind", false, behind, "feral", "balance")
-- (L1808) Barkskin outside Bear Form, 50% (the review's value; the owner: "barkskin is available in all forms", so no
-- line is gated on a form): Balance's own line reads barkskin_health (any form), Feral's own list barkskin_cat_health
-- (every form but Bear, where the imported Guardian line reads barkskin_health: one line a form, never two), each on
-- its own page before any imported section; on Guardian's page too under Cat Form (below: Guardian imports Feral's
-- lists). Feral's and Guardian's pages each show both, so each label names its form, as the sections do.
spec:RegisterSetting("barkskin_health", 50, spec:HealthOption("barkskin"), "balance")
spec:RegisterSetting("barkskin_cat_health", 50, spec:HealthOption("barkskin", "cat_form"), "feral")

-- The maintenance debuff (tools/wowsims/apl.lua rule 15; the recipe's `maintenance`): a raid's debuff, off in game
-- (open-world mobs die before it pays off), on under the harness (`sim`: wowsims's raid boss).
local roar = {
    type = "toggle",
    name = L["Maintain Demoralizing Roar"],
    desc = L["Refresh Demoralizing Roar when it expires on your target. With Defensives enabled, also use it on engaged packs and single dungeon enemies you are tanking."],
    width = "full",
    sim = true,
}
spec:RegisterSetting("maintain_demoralizing_roar", false, roar, "guardian")

-- The settings the imported lists read (APLs/packs.lua: Guardian's lists in Feral's pack for Bear Form, Feral's in
-- Guardian's for Cat Form), on the importing spec's page too, below its own under a section. Each spec keeps its own
-- value: `settings.x` reads the active spec's (sharing the other spec's would need a cross-spec read in the core).
local sections = {} -- one section table a name: the options page opens a section once for consecutive settings in it
local function imported(option, name, desc)
    sections[name] = sections[name] or { name = name, desc = desc }
    local o = { section = sections[name] }
    for k, v in pairs(option) do
        o[k] = v
    end
    return o
end
spec:RegisterSetting(
    "maintain_demoralizing_roar",
    false,
    imported(
        roar,
        L["Bear Form (Guardian)"],
        L["These settings come from the Guardian priority. They apply only while you are in Bear Form."]
    ),
    "feral"
)
-- (L1808, owner "Setting per line") the health thresholds of Guardian's defensive lines (its wowsims values), on Feral's
-- page too under Bear Form: Feral imports those lines
for _, s in ipairs({
    { "barkskin_health", 60, "barkskin", "bear_form" },
    { "frenzied_regeneration_health", 25, "frenzied_regeneration" },
}) do
    spec:RegisterSetting(s[1], s[2], spec:HealthOption(s[3], s[4]), "guardian")
    spec:RegisterSetting(
        s[1],
        s[2],
        imported(
            spec:HealthOption(s[3], s[4]),
            L["Bear Form (Guardian)"],
            L["These settings come from the Guardian priority. They apply only while you are in Bear Form."]
        ),
        "feral"
    )
end
spec:RegisterSetting(
    "behind",
    false,
    imported(
        behind,
        L["Cat Form (Feral)"],
        L["These settings come from the Feral priority. They apply only while you are in Cat Form."]
    ),
    "guardian"
)
spec:RegisterSetting(
    "barkskin_cat_health",
    50,
    imported(
        spec:HealthOption("barkskin", "cat_form"),
        L["Cat Form (Feral)"],
        L["These settings come from the Feral priority. They apply only while you are in Cat Form."]
    ),
    "guardian"
)

-- The priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc (a wowsims.com
-- pack's from its recipe, `make wowsims-packs`); edit those and run it, never these blocks
-- (tests/Forever/druid_spec.lua checks they match). Your talents pick one (the selector); /hekili priority <name> keeps another. Restoration is deferred.
spec:RegisterPack(
    "Feral (wowsims.com)",
    20261126004,
    [[Hekili:S31wVnoYY5Fl(ffrmtKLSL8mNfwdqcwKGnizrq8MxLgAjklEgkrfsk74fc(3(PVrY(w1xOOKSNL7d7yXlD91vxDvvxvxnNnA2Fm7HLHfrZ(9BgEZDJgDZDdhoE2dfVUlA2d7cx8JWNq)X2WnO)))wuwyYBFV)lPVKhVjFWI0nb4h61K0WL4g6X9Xjf)22zpQTnZ3fTy2d)6)Z)7V9R)YkCtn7H1XlxgrF(O8f6PWV823lwh923zx76vPzrphL923xgTkCFsXBF)F5)()8TVJU8BFV893hFnMA5xVmBF8YRjuBryX1H7sYVoCz4UI4NJgG(1G)EE62GpJirw428eeOxI(7umjJZF77HlxMU9Fc9h)i618bV99FnSi8x0aL()x)2FGAK1ff7Y)LRV(P4I17FeJ(RLE0auBIqC4JdxnCy04vl(6TOM932SlnRarM)99HzlJd3kXcqVqoJl8yuiIEjX5f5icgTTikdd5xwhNGV7(vRgGFK5i6TzW(DdqJpzPRq3C2dHlkIt3MpDrysYC6pMJBOpJhDNIFRphVAQst82)b7f)00RFomlo8XKi6R888DHXlNJh1xgHE(4I85iqopABu2tVoFxAAYN3TplA6Op)CyY(OP9VQF)(xrBUbOXdkj(X20x2EGq3QRTFxqVIWeu)BWouhmSin715lJZxeVljEB0GOTyySSx)(vpv8MWK5R2N9A1nrSUhtrWiEBbIpUpld9GFB64Gd9VY73AsqGzIv1VYI3X6slJiDk8fYI2egVn)BtVnWc5XCi2TJ3Gg7EoA5881iEq1tCLX33Yl7ctL9m5RJxveV9jeV4LOSQ7s6tXlttMNUAoAMv6I4Ixjdy9lI3e9PvXpTUyoRdhC)07gg4kZ5gcZ5VU9)XbK)d1d7tNoKGMhUimhJcef6rNynijf9OtWSkTpvFUh7lto0VpGe9bDIZi1G)anqyHnIWihrq9qcSHAVPJoi80h6BAe0iS0ofS8Mgh3cUGsgiEJUXG7XQImng8XS3QVVIu8fWBkj8)BFyr8cI6ESDhIuAyX0H9i2SjxFoQfqVlQZy0QeY29ZrjTrlvD9JSDkTJDKnZkeN7pJrJDzrpHNbfIVXNrJu7scFD(JrjPVm9MjeIC16OWKI1uLl9ksF6PKObipKI2MJC1jVhXfO50le1ld5vhzY4OH0XrTuAWsuB1gyCcfJqOI)nNJKiZZronCS4IYpYls3g9595riH0vZFAXsKViIy72H(Z)CH20jmeMHjYp(eq(hdZ(r(pILhfURbKIoku2GoZ4XD(I09lwRV3Qs0(uQITIH8Ke3ehOxbjoSlmlICPaBKol6VV)zK(j)fb5imTlZ3uo1TxeUDbsje(z(m()nVYRAQMar48fZWz)wIsxkEkNKqmWpVim7PiRAo0JMk1sNxWysIWcT5h(BeTr6nYsFP48twqjrFin1nqs7JLbpOhkntGf51jYVG5i7Z5reerEAmwJssWM4P3c7rjLS5rjRMtVVT2o8Xu0klxJ9baT(A9To9E4MNClXxH0d8NUieh5irRCjxIWCRgvdKc8htBqkpXUiHxz8lOvktaM4ynbFSwM84BIZZrJW2A6I1PzBZbBqY7sFghLiyZvQyDLxHF4OKgrjXfrvxd5FA2R2iaK2WBNW1hI2GwQq02f4BgM5Etwb66hva1eeY(1lHixtDQ9f8KJ8KvXOGR1PTh6o2AoM1M14zUs(fuZbWohMLTFxrPWgE0CoYV)NCW0F(ATT0vpMMNJxuawLXGyuNh)BVBFeYtqlk4jS6NSuAeJGnQk9W9yR5v(6ojCIfetazzjPPO7q7DLKH8go12zrlqQcZqtrZIcl0qeQl8FByLTa(N3wRhTf7Uni0lqRNBE6oS3TSMN(c2A2vHrzXrZxfNrvFR2Chk1kSpP0Dkepz)oCa628koaBeHH09f5XlJMeOkoWCcNCzgeQvCUJWF50xUJJHZgd4aPtJeH7lsNhwueU4hAyyg7phu6)bAGVnaSjnDBflTSNw)WuNM1hcZEQWtamQCxgtQKMunk9rMLrZmoukZz1R3xqRkA9jaV9VIHe2BtOZaSNYZXb6A6qnDjByLeecEdw7Rm8rKEqKJlyzHpJxNkvct8Ai7hS4CqF5hJwhVDP)4zfjUfP7r6drwZ0dSLVIrL6OhqC1gFq)1VPC(gsNbItxSC6T3n0(OBw8ozyDLedtfAmMsseALZVKMvSMKFGECXCKkQbfzq9x)ww7Me9CeXHEudb8OJl5D7ZWJt6768XqSC4fbTfP5w1PAECZodYmQXT58viJupI0dPbLIu3jaNf(JgatlJJO2KoqQHrIVNZalf5CAgZ8PGXPCK3EHllnSEeKPkMe42wiceSFSBrX9tZJkWRSjVkIdyFQMtFIggkc9XaYnuW9(mq4cfbJ8J7eTUjCKUkodukPYz)LstngMz5F4ESg9(AnVFfN9DsMoOshud1iVmzkBTRmJO9MIqlUrqitFicHXj9wRIJswwovAz4gu7Z8V5aVPbs6jO(PIx27g08Dz)FoW(9lXfO3yI1oJWsdOpkx(ll5r57ZlqC3iAGFzyIB9cTnQ0Oz0JCUkK8Q7Nocqr5nMhB4hAo0sMjBFovuY(Tr5ZtWDznZuzSm(NQ0VjH(NQcD(vx22Gw7WR7JVUK2NUCQl)(xWCPD05uUlN6SKt)XmL6F41YkoI7R9OkwY9tNCBp2BjjeH9q9vz(bNwzOLfFyt42qENzLAxSBTFs5vjo72(SPJZSnG4i3oYaEQ5bEE8ezxa(6phYG4OoSkDX(8Yij5oVvNcbctPF9QviUyEGl6Q0)IilLe(kjAk6N9ZuoCqlvGD0(9G)V4itq5P34lpfssPxFJgImQE18(HjaqiCYHR6liX)TP9)6NgX5ycGrVQol9YcbPIn0wQxsZdwBq5tJgg8TkVnPpdVMNQiIW7KJnmTij8frirUImI4EmiarEea8qwVhNnxCMcfzLFfuewR6ALaDCHdq1PysdoClnDwZv8b(rHBF3XXSpbD26O96rV0SiUAiOQNY0RC7jpWHDMCNkCCimqZULSl6XiLfTrQdvvkt8BKcP4ZhyPxH7vsd19GhPpapoF)n90UcHaaYAGhe0t7kso0Th57wpF365TUE(pM7r(aDj9QwLaS5Iov)UaRov)DQ()5v1xNQ)ov)THQ)4TiC8CytcZyAcoV7dQAbAify0J09I)teFaZMzrx9(rJhoSh5h7wumhDbCqgFAXsU0oZhM3BhQxnRCOfgnj4IMioU12wt4dAwdN4ouYwiAK3ytESxMiw0TdOsMdBrL(thZ7rpYRsEl6wmsbl87XmJKIC1PY1jgC1uj(IFsPUW84nRWJNV3cUTeGhVMl1qfToV8R4D8OmVAeMOfvtRwwxk4WV64Yl(JwAf7tDBDCKZyDA5vtRzVrb25GRlRMwwwkKYADy18YWsZuo)R7QgxPtos9k1aNwIBVUQCQiJCIwgRJQ2KmwQBkNi1Xu2uAGKyDsrEn3ktkL2sTUOuATDnOSOuflfRdkdePYFKJTmOuWGU6EsCScQSNunKxvNt6Aaci5kZjyz3swHNL1Kb3d0vht03vSmMm7HHKpqou2sg98q0XDDLPKQ1EQ6xG6sIE3y4YssJPnADij)MowgsQDpn1DuRu2rkucOoJOnT5YmsJGN56kI6IiqzfP0Aq1re9LHkJi1HAPTkSYR)oSSHuvKACniMWVBLjKQ2mU6ccy)e1WYSrL75wzbPaXQ6aQDXxtkdiZQ7evTPUcWY2tyNtR0Klr2Lrpw8FYRtOoHU4WeGF95kpx5AIl1BqUyqpDxTCOqPn8zntiybTR)RqR23SSWhoQLXzuXU0u5krb2qJCitufvVAhMtfLhLH(3A18Y79DUyZeOk4YxBi2RpIQsdbSSqWrI2VG9iisePIqJfsIDiRwhjG(Ydv4iUrKy56gr1iIXn9oBkUU98UHruVJTMZM2k3fsjHlWs5L1WIu0dRmTi(yhyZBUx(ULBHtEZKTqNq2WkJS(xcouCD0Hb2bnM8BePMR5eNtI(GAk56Av9n8nW9mQXm)7AQ9TYbx(UeLwullyrzytTvIgvGflITj8)VEt6GplmpW(B06ecNNhUkkqPbYXdAtNW4uRJswsEZsRlSDBw5E9HuzPYnX(DAurgHwJzMgFD46JpIwhQQxJSSxuURIRCcR6QLtW7x51aHuSlZmotVuLPzc9wKIetwO7qk4aKeSVJZLUIY5)Mk5o0Ii)0jzXTmmxKkGHHATAwsCUs10OYPM1c5VeVlI0N5EdY1itn0WE7dPyw(Q1j9GBvcscOh0CdnV3MW9jIVa5kLpjDfhKlHejQCSI9O1DrHT8k5XPgnCs6aubU3I)oi9RcjmCLuuWdUQo9ndnXU7dQPOklG83QmVCJgGN1cRLHr9)zfw730PAQkZOWBIs6nWTZC0Y7tFHin8UGr3qrzT90EQDt)wtSyerTSMpXMghAmwYSAAY4QBIp140Yj0guvVhtl0Ku1j0aUKGSZAs78gDN803jGOZwI8uO65kLEIsONVK7PTdFQtZNarpBj8tAk8fl1FoGJZrsaDEK3JKN5jvphjg0vznpiA7LIqjW1sjluOvplPnuuK(sNarb00wPsu0nKJiPI6Nbe3gPxeWnNMLOryFMKc6U3PCe0xksd7rYhf9AHAuODsdPK54wmHKID(ZtQjfOzRLKsjb5wlDLcTBBK4srXKp8PWuu9(znzMIAwFNNwtbW(UnbNWQzfvP2OuDk04V3s6PtZZft0sDdu9Ug(KevtanwT4fTfMq1sFBjeA0w6RmXaqzLwPf5nf3knOlbs4I(nOWB0E2)AuiGq)cdIF8u)qHxHf5ubKl43QcTmKZ9xTIbIoGDH((viPcX)WQCI(4r4aUmgMLZbSSh2f3(wpCCO4s8DUWvzxFaXXexgFa7j6BFHOBixIVcgItzEV99WqaDNQVmgIUT1IFJm0pJRIX6zCFCNuq6EB63ndd(Gk9soexi3PKGVPK3XyCICVHz2apnFvnKCx5e(91qKzDz(sBiGHt23CdPjsNSV(gc05u8D4qum8NUVihIMZUOFBoeTC8b7R0Ha4)W896qa1117EnkQSmCU)YDiR9)983WdrDDDFnpoIXs7SkZ4VT)UEio0(U8l8HkepXFRpei4oahiUIZ6eXagZoG9ZXd3P9sSRAAStDS0A2diNpYrKB2VFZWBUB0OBqs)JN9a5BY)S)y2d4hh9V)(i8pyNimZ(xl)(7J(xUOtp7HfzirTS4q0FrqUUO1oRarlGwJlS0U3y3c0yv9u3BQXanvPTl3BPjsTKWADqmGj1nU2aXYtj)cCOhHIgd07md0j(a0wnk0yW9fZG72HnMnn7bUztyX7QEjxmTXq4RMHW4tfeQdOngf)nZO4UHCI9Syg3yCPj0ZyimAODoHChGegrZsiAc7SU4otqGSsidYQ8XtZfru7XCMGazfxsi4ltCHwwJxlVINQWeJgz3ZItmVUnmQK1aEPqvLAsmOK1LQbunqCrv0qpwXiWIo4ViiUqJ2v7rCl6v)YriRUZumM9kiZeKkRKTgw1XvMhwKMYTWltAFznOvUoiebwJuOjbwMqBz9MvsW1Xs2rcBoKY(etzIdqYktlbMCyK5rN4Opu0KjnpK7A0GdBRrjDgU4itAsiF20n1HjT5veKjeXIMSBNyX9oAlkg9ysdd5zN2wrYrzhIBmHgY6Bm59iHegJymPjjArKDtqU7AiyWCoVrnZrcRmpkXubsdaoaXMiNJXjMqdiTaYr11ffGEfHyc1)BUWhnhd4AitUMep82HMPGXW(Ypzs86I0yKl9cOq)wtKYFl24qZV5IXkpX0epyHacFIJiSZHeM03U1mJZmUp4waF5mSvhBzzMmKAOY4Xk40oRB3GaQ2cXcUoyWeGdPBJex2tiQRIdSpbcMGyzhWCWUHNBTrczG0DQSHdfe4Czto2A7YrcoH0)ADr9clDK9JtYX9cbMwuulPb50DgVWfmTGaNSIogYLoDlihIP2YNmmkLgSGmvezQ9ylwvSdvUiMWqR4s7kJMIe)6M2GU1HjrlP5IIIe1TysGPTXLdpgErf7h(hYdjCML5OLmAhBXagdUn7OLPTpBzm0f155XyiBlqEEWG557SOrPdHrnK9LtMI)ZWjtJYrtdAqaFiaGJypUpdzSRuIr1Kk1iQJhRiwoWA84eRHXcD5Wjr3rwJu3(RU43nPNso2A491GCITilWdfvcUZqbn6IoXhZnhGMD4TuZb3oPBA3J6gmJDcKj4ws(KBz6UizjkfnbkMmWGtijMZEGpzNyrqCJ65Q2CUDHsQw9PkJMMT(a05GMrnWtqNMDe64)zOJ(drNJ9u0HWUGwxNUXwqZqnyIMdZZKuMnr2AlhWC8005OooD(aCE6C0SzWe7Hrczqq25bUbHMkXRLj0tLd4fo)IzlFI5EW2I5DicjfS1NxT3hM1T3d627bUa0U9Eq7bHU9Eq3Epyw3EpWHSVRfRfD79GU9Eq3EpqXbRU9EGdojkL6PU9Eaa5627bv8WU9Eq3EpOYWw3EpO1qD3EpOn37bwNcWYVOzDff4E3QW9jAJmeOzu(PiYNpt0QDHBXneT2aS2Yp47K)I9oo8TFF2d7qE9r63phMSpchNp4pwXN1pq6NRVq6GFI07(gPdYEUHYE(lmhWZpt6o(Ds3Whk92(lLEpO2B6OdheECmQmmoAgzANnwEtJdFbxqbKGaTkyUNOwY04WhZUR(o7TSSxdLlbO0C45jIhMeqUacK7JgqbiF1065tdAFipR0To3g08wc6VxPoXZd8npYDce6TKVaVYNYP)ifeJyl5wqmjl(Xq1ssxZ8IljC48bmX8Xylve2siJFOvtgzGgmTLHcNYsJBNmH6stdiSSeypxsDtlFwfsGLdjPWbayn1j6f3Q1B6ssECiBgxoOkK5hps9HpIGQIBU3bk0KNdpth0jarwSv4soICdvhvsIaHpuYvGsC0XEOisIjauItGZM0P7msKaiOuTaKIPMFKj6toMarlumvmL3P(IsuqjEcKMqovRMmkTuI0Oworfj0bYZATZMzY6ELIkqkBr3S10wvg9nRN4IeQ5vKnBPdGrcHHI1Pwh)jnH3NhJe64wSknK2lZgXyEnOnvyq60KtfMcgCmxyq95BH0Rzk)yNUJVrcKSKUjglW)tTX6oN2mPzPMK8)0BKxtGP0R5wwI85yDSMY6Z5gKglOCU9rjPBGIutSWIBLmXzEKWq25GuSQl7ChZzTyRMEoqEnK2ALu212DLgLZoWUb0ghGeXqDop485izlEqssqkKTJvcNcGMHS3NRKh)bljg7GfoBw8oiaF0NfHwpNj95GM8mEstsyyqU972GTDEN5UtlDWts6jGBSRWFCe43YyFtphkjigAbfai(Oohk1wAwJb3oz6I1NqO(y)aOqZXAAPpHhX8BSnRQ2baxOxz03Sru(q1kAeDSLTSMJGPoCRoJhUi0kbjilHGUzvolY7QBwVBtxX53ejLSu5sLILcCagYgi1YLi2T54gbagQxlHZZ0QAPmCdIqmxkRRSqSbYGMutZqDuW9RRUvysBdUTOHY5ca5gLWLBDNTgGbR2vdMb8zlNiK2(7NocWSWnMhsfoHAp0wUs0MSrBl1KXW0Duqi25uTrXhxJ2bW1lQd(0IaUOGnjy4HKHlPiVBZi9Z2wXPBZivUzK(4UxK(qROg8mjqqsOX27Q4x3pDYT9yVMKug2z(xvywCk(HINXHdBc3gkCYci2Y8NUa1VB5jWtRXdbJ6x74ZaGKm3MGdEIn32Hdncmr2bKV(rx8fARrPgmjF446uXq4u17ZBQVYOLcuNGa6FrK(scFLe4m9QtyABkPSeDGxoXf0x(YZ3a6bzcuCvLdUKp8CiPRE9nA8ZS(CZ7AXaijxet5Q(cZu(20(F9tJ48jcWwBvhMEzX4sYg9lv3P7jRTJ9Prddquv4H41NvfqlbhSSbRfjHViHkYLKbf)ZbHjYZaajYAF5m3J3saI8ZVckOR3sWJYrE6IhLXwFYf9SKbS8DLdgMxZUUIpqDkJg3DKdgNiwH7PkWhEH5PkQHtSEUxVYkvzGdLNYFTnyGh(ad(dsXH8cL9y8ZIUo1bWkfv(n(H1R6fWauPFLKmqpyjamVfsa4(B6PDTpbqe2aJiON2vBHn75th2bhq7IzXpDRyVlMfF4lGQaDPiTw7aSjLwY6GWYjUdCRs1zNOZorNDIpQAj7St0zNOvTtaTfDI3IW4ZYNiS(OGQ6iwTQPOreHHjcpi(prml8OblOZ3pA8WH9i)y3II5OlGJVQ0Xdpx0xVDOE9YYbgz0KGlrsqXmyOCCQz921qQ6CTGFvLIB5oRHFsER65WUZ7oOmxO61GzSwYszla2dey7dia5TiVaDBXPId(TzP5utB60DDNPd21A8yO1TE8DWD4XwaFqE0IvvnynM0AvvTxNGynO9950dRbnVLIY7DEvvBP29Ehwv1wQTVlwvvBPAVVOfvTLc((Yvu1wQ27lvrvBPwVVufvTxhhTN7kvUwDDX796)UsZFHBL)Dtebvf3CVduOuR3)J27oihegeika6zXD6fX4E334cDbrt00dGN9sasTr7NptCMc14UM0KslnmtHYdAbu1IyElSrXcGQgovFnevnuYD1qvdhIVMevnQJMwIQgUfkOmQAO1cZrvtInRmQAzlAsVDn(gu1IwnLcxIXHIqeQAY2isQ2YzbQAumnRrvd1Cxru1K1j4uvG6OQztW(yhknavntZDS80evnkI1plQA24kL)HXAu1OaRRtu1OO1Rmu1Ojn2NJC7RBRXeClkQA4EMCroBJhwju1qq4)rvpFfguHEzVS51D5FC0evnQlbTlQAHmWnavnB9xzZKmLHSPPeuf8tVYN96XmFXeD7EwVI)C4ZGNw6HFtJpNQV)zDhpC5Q7M75PT7V37BC2VlC6UHd]]
)
spec:RegisterPack(
    "Balance (wowsims.com)",
    20261126000,
    [[Hekili:TFvxVTUnm0Fl9LSeScBN2SU7kAkWUOyy9ITlgMV7v5ilthRffjpj5KvGc)BFu25dfN41MmmSx2ljkuKNdLi5XoKXKVqIZOwG85BIU5UXJV5UOOisS9LsGexszlOZXfs6s8ZpsfujdQNnCTATHV0eWulh5C7fHIM5GkTIlSpljPNevtjWiXp9R)2ZpDFAlyK4cEwg0gbyy9XY91ZSfOXn2cZvAyfORNLb50kHTE23)l)u9m0C9S9iuXdDCAcZ0v8SWnCgslfOP2adWFe87gLC01ifAQ0iWepdxRCuYn1ZOzzk5xHlwaVycQN9e1sV)ePYWF(5VGGuyTLM7ddNZTfvPUSpSJRJqmXmMMgLhfbtYzF42a8AuRY5c8gHYSCL0euQbm4uQDk9pQOwolbJF5188PBmhnO5C1yoHlTG0w)PJI(RNgINRvG4IdNrTxCSlvk5cUCx8xLwLNh4BnOQCWWRAHRqjY4Y5jTj8RhXXOttYAn1w4q3T5kibKWsoyEyYo3VKRWl6I78VU(x8scHoLQxyquCWwauHTiyHuTwoyZpkz2hMAaRfr0eS17K2D9bQ1IXQKW1vgirLNNmNLnD87dzVW7bC3rQu5SCP4VhHtqbiQKGjrWNxypKaFV4sjOxHkaowxsLuhnjc1dtIgK7cnrdlPCP5XBJ6wbZ5A46CfRYm9MMQygSRo62dRHhsLbqSnRPyr)eH5VFNqlQ0AoJkHJ75FC6eFpnwQ2lVAUmho8klvGnkbatWlnqaiPPci71gE3ASQC0GHdpTNdoWtKe2Ihhp61RAjoylRbWFcSkxbA0bnLnZR1FIeJIHg0wNNti4gRP5jtTA04Yp38KQnSt(4wrs8BV5AsmtZTGMtXv9o4rSiD9GM38(7hSB7bST6aVFKM0ds(kb(ODw6eNqOWX530dNBLc857Thd7iG4i4Uoe4n75kR7i0tH4848yPfhTF7zq7EHJZN5JeDCK)H3j5(IsU4(UEkg7KL8ZV3qEYH34Ooa617CS60HnCoJK4gDd3aJdTUdHhJwhrl)tW(n6GAFdJ7u58j6i1Ugi6ocU3)(f7(hR293k3T)ySD3DN6XnPCFZ6nAJex3q8UxX5)fa)pqaSTq0BR3dtAksyzIwzluAs8pcl4co()a(HnVMFZ2K)6d]]
)
spec:RegisterPack(
    "Guardian (wowsims.com)",
    20261126004,
    [[Hekili:S31EVnoos(pl5F8zJUh32jXP7DqCdC7nypmhUDWHnZ9V2TIfDS2wXYNEKSzGr(SF8LKiPyXhYY2jtlmathRhv9JflwvXIfPwmDXVV4UWGC0IF7YjxEZ0PxEZKjxV4U8x2HwC3UGvFp4b8FSn4r8)))Siinmky7RFB4ZjpNf9y24vjpoI8CVeNeesO19frX5)62f3RLSz7qRwC3V8p(F)1F5NFGtTf3TjkmeXEfu2kq(8ZV(T8nOx)g)AFADsk6ju6RFleToOio)1V9V))8F)63Wx(1VjqIIOpryB2NctlIc)0AuAq89OG0pfSlo7tbHb7YJEcng)RX)ZSKTJ(iMnPbBZIXWpe)3je2gL963ccdt2(VH)JVJEjB8RF7xcYd(znWz4F)x)Dmr2KNVl7N)0NEikFtX9KwWNuE0ryAIrDW9twpzc661R(YveYIwJ2MHHeMtjRXWf)V)1G0VN99iCZjylgtP4oLFADX2qca)BPOT)re5V(hOhqBXnV8OKTmsJLxryeTkz76Ohksjp0guqC(gYTsrzBsIdjnL)J4GSSOv4NKiYWx(z67MHL2Rkia55ni8nEjPiTMcezsX2ueweEFmctLF9XDjP54R(3iYyLEpmGY4DGRiqloklpdlMqBZruG98MOy8nVVy96X4Nyjwi944IDJXQxPjRX3BXDbRinTS5RcIJxY(XscD(ir)eF18pgTEUkbE9)I)AFy(Nc()kWsNv0BrE2HyKDFq(8jdOkh0RVmcJOT5JgCHjkHvrEcf3beIOk2bKP8YhgvwZ1LwMkOk9XWOSDXbVS8EuCYZZVCgLhxWudg)9TjpVDqEYdpG1bcR0DhqhNTKDb0aIg744KVoF6KbuaOLtJdX0QdG4mgeHaL4BUChEyqgEOXbclM0ilpzl6JfzOL4rUlFyv48Pkq7Qj(l9CG1rBFy5UeQOWe3VU75(9CttkC6MwWjwxqjbDvQtA65jfR2OVT2KNdzmDvqg2YZscj2ZUcwvyxqkIEPrw4Ck6Fw8eABl0(e4lRblskxA0yB0RWMEipYhj)VLuRF12rKrZNnJMITzBIwNZGt5WJSCQqni9bKnlg6btL1OtkwmPnyH1ID9TH1yZfPjpNFY5kOsOpCEiZ0hH(e1V96rsR0vtrpM8eA5QI0mefq0hMavuCmjSb2TWVfhyzO41lz33cPdUpb77Fd2SxeoSn9eNDpc1P3s(vO43B2IXlYrEo8c2RPYxQXW9qiAK3q6rSftSj)L4GRw(CuCifxY9Zu4Xjm9XFmchW32hSfLZMK0TzG0J(QSNXnLb(GKk5w5ve7kkzbkokhvDTimQFXMRiatGxntOfGEeH1N3UICZGuNPyfKRUKmMP4J)RNd2MN5c5LcAt(bfioJC47ylYiM7LnKXRkrbu38jHbMMwSlVulJ0rUepFNhS7OpBJwcDX9jzzdUGzNyCeULt(TVKhJ74y02hiMCstcsn7dv5HheIy0w56UOvs0aJbLxXjj47WABLCH(gUq6u0kS1V0LK5AHNCstEWcu)RtQm(l(8wioAljOAqGNhSfBuyhjiwo1zVGnLOauAeA56OuM96MuBFPPGI4YaNWcKIDy6JEepeLRhKuKNffIMnQPMapuB6L5qO2w5oQWvWe5obPnVdqaKU0neuKNSmippy131iUm2C23O5psd6TzFoHm)BUaTSDwBhHfBC51ROb7YnrNewAkB5IOsEYmKme7fgpMyFP(MTOBFgpXNnhb4o8coq4VnLpJjreVmpch34enTiBMLKmrlBo(cfl21rzuKLheTfXMBSfoeIJHb)sr)HKPPHzOCs8rzJFetjc1w24b5IGkZx0loAGURw2V1GgUOGRFoXeukn9l(p2Tk)2kWR9vxYEYUCw7M9nPyZyGs)i3najuYhrB146AWf7iYrugkf)V1UMgQ0DVVw9CKTXavtS1KCCELGS8XlLDmvpX5Yoy4q1gIs7Ep)3phLVjA7Srs6piBagofeU1ceEFEJWbgcM4b35znjCJTO4ITOSLXrpSrNpvUPfXNs24KwTHb(23ydKqENlXxCWkY4hehB4hahnmXus2TZNu7ou(X2ZhrER6DxLKLJH0qzp9DCBQrSbCui6oM1A04NUUXvbtMlz8W1sd9DmEBA4EDYQIS5xEOgWhEb()anyl0sRAQKBqAOmhWTOLAPPwQii1czSM5(JmmaoAHk9OkSt0hFm4FHTzDbFucURAp)VXtplyzwWA0OgeiJ0LoFgxWTbfhsFZsFEfPK5ipGtNWxWcTgKahpLntZOuSLEDbZj0KVVinZwm0uhm4NhpttrBhcxU00XWQ4GOSMFzE8fSlvfDbL9RsW6uR0nnR9qA)(QuugjUq8Qnz3(oe5Nm1qHz)6IkKROkjFdz2vuPOKct2oYYy5ws3eTc2jem75ODiQ8rKa0lsh0PPRziK)b1RggLrKwHJeNGLIY9En3qZ79yqrS8lqVs5tYMSg9sy1PQih5pADBK6Q6dIuG57Y1(qjt4D2ijhgizdHK2IIfjjSwjsUCIPodyBqRssIjdmKUf3G9xNoMypa2(fN7)udbFvxK4lv2LajHR8RrOZYG44KNP6kVfL7TuVxBdFGUw9bK7bwusK3k0(SNTWPNcsJiyNTy4pHTDefUKuogHiIH38mA(Hju6HxWXBNe)XDfPimqEkiUaHNP)WAzL8S63RYwssEIXDVyrhkmipj9fsIQxfTdhlpAmAlves0gkFkQaEDr6lv3KeiucjT3BZZgVQifpXY8Vo)ASo8fE)wZOAQgETQ2vA0oEtI7XHCHYHqZVAKf2tKq8Bh94UuSsE4YSnyzq1tCHX33Yl7IqL)m0fkJnXPNrPv3L2MIctIjlhawdkzvu(l0oSHK8R8bQ)3L8g8OBNFZKrUkCUKkC(XT9F9OrS4FgYZuFm2zgjZvyuq84XgyrnWFnXu8fAFQHcp2NNTF4qan696uNXMG(oUJWIyeJrbMGBHuydrV5t3l907hAQh0iS0oeS8Mg73gDg1mWYgD9b3smfzQp49zRvFBfB4BuLReIH(5QfkfCffj9EFOrHr5(lkLix3FTs3s(9wUufrScDYVkyXJmM2giXkTKoTUMuHHFfYKxshDScm)H6kMNdIBglujVOSMC7c10GlmP2wxsQCYAHi1(6qQ5qn)l8OwxRpUX8Qr)hvEBVWICQoBCHvglKOoKlwkCiN40Hu3qnrKCHcrFl3Qtivs1SWGAqS2uxqnuiLleid8OZQdiviORWFK7NGQ7NgETRk0hDVpfIc15dOsBPCWZ66bouaDfYd7vLRJhJbtWmx7tD7ykid5jdRRoDA4zNzVfyXpz31qD500rgRqCuFrhRdNgTnnfEtNu3nQmcOqByu2CD20uHZCH1ySUAujg0s1XExO6OPrNSYIJ14TFdw3mnSCAmzvMGVB1jtd7xcfgt3wOjnLDUvxmQiSQqy6w41M6GrfA05mkyXUOYqpTNNSYA1P2i4jYetKs7j)AQz88E0MOTH2z)A6SktkYQw9Sg4GT8En7kas6X171F9llhAGh8ILJ5HZV6Mjn7QsJ2PGIluehnrcVjhJWZm65K08n0nH0aH8)WutGYsJ(RFfNUXi8mHPMeJ2b8OxxkQ4RQL2wQy(Ck78WqJKKEV6vSlpmdscjxUgBP)EYYX1euYmxl(sd(U)OYsVeMKSUjnIjY9aXrZvVRK3clENpuvSKHSx7lvvmeX2byvdPBUiGv5JDM2SiFGMSduv94gpIulQhB(ll1H8Uws06b8cbxG00)Y6zBSown1ligfPaYIJvkvnS(yL1nX6iuCy1Qvh8iM8Cp(7fn4oY)AcXuqQnwPOgf)e9gCiiuH5hkiAAaYJvvsk983oFkG9Olnl5ff877gFnDqVJ5QwJlH0v0AsnNM2nf3Sbhkg1155EVNlPTUFnbvF)Z4AbCWRjw)AcYxCT3Nlj47oBOY9WE6CPscC78zxnG)wk6mK4(ErT5lyZfA7qS)XGTbs17KmDfR5P6xTSODpqPYb5Yfqzty9IHh4TxuKot199xEFQHrMunR(HM6POu3OBQmOUsJzX6TxihDS)IQPeh8cn3a6hkZhPVxlxGdW9CeikzM4AlblRIqi9Gbdn6eXOPrZRf)iavSz7VyOK(8xNp8lFyQqqfaoSQASSllLYfEpzPrgnpyTZGpmDYOVwnTi2ZiAgPmdaJedqXgMwfh8SmKOxrfrcpgeGOpcaEOLjJG)sYI2ilk)cOgRwBVnM6)zoHmDXyesciA5GKleZ8rdH7nhMSTdABvzM0JgLzf4M5GPEaXGYcFCSd184pK2JjJvL9P5rhJftln7zQSm4xhd2kMpWsV1Zlu6zha3XUhUB92lhOnu9raS1Gmy0aTtnyFFX22pX6(jwBDI1Vpl22r6wXMAtcWEh6T03BP36GYEl9)zYsxVL(El9TXsF0wmFFkOf57JVjcRiaB2)C7G0wt0FGB2ePkpRM3o96jtgq)XUv5lXxGKTpLtSaHCbE1e9wvvZcW0zJoPlVv98sR5ZEnZ)sUsySL8e1cOXuP2rCpBL)LnD(8)StwJLTfTJG297WwmuIYKk2KVJkA52bPMcFOTBmejs0MTiIebkhk0233L9OXPCBJ4n4o2BGejaDQ2kjnyA0PztLiRBEY2EjABUh5nAIeppvB5eLHUNRnFIdWOYUYjcfNQnKIs3(rFRP4QAMh8SZ2KkkyRB2Ukse9uSXvKvMpZBHfjW0rBMf5yoA)2ArVQFuhSbxacPPvB1f4WJyorA9MEbmSj5PuyD7VihHcZlqNSryuC(2DBjg5w(jzZXiXYUABYOOa3vBygjY2bBDgzfK37BIgz75NYTtJST032BSgjS(wDl2ibYQuhuZ0kRPh7nBJQj03qB7gzBm)WVbCCVNYUKXmCp0TIJCh3BHnLtte1TBphj6VtVpw5DnIp5MeMvHKqtAA9VnKUISWFaSQzDZy1eDyi5MQB(OyjrZU5ZJ1yWOB7cckgvBxqpxY)258JNL3G9u)z0scG(L8q)KOEbcVsM4rchNVpYwAfhN4p3wJLNjZ55dVLIPd)tg5X5ZELdWQYo3zcv2twPBFMQoiqCg(aD5QARpy4qYMPhy948r7soQJZWNVl5blVX(qEjbUJ0N0l5y06UpUx6hQvjv9mBPoZjZjpL3QC)d(LHWnzon9jBQoZiPWqLFfDzx1z6YD6Du(CGPeCYX7ddMSK6S8jctcchRpwykdGowF2WKyZr4diMSc4F2(uIj7)6C(rft2xX7RpVysy)9YhAmdUgKDdCHINIw8jhtIxVX)4J5MbLHs2p0sVf3HTGLHj5IF7YjxEZ0PxEZKjxV4o6Nj(f)(I7Wpn(F(TPK)MxsMl(RLFs4X)RqsSWpCkoOI0Oa8FrbNU86SihZkaQjK(k3j2vaeRszWDsDnaPkfzUtPzkuskqjSaywnX1M0gro5xEg8iRveGEJzGoZhG2PzSIaUpBgCxnP1IPf3jmCHOEx1kfsagbcFXmeU(ybH60FrqXFXmkUzIGAppftTgxAYufbctNyxsO2aOPEWSgIM0uPlpvueOAeYGUQ4SWDrf1EsQOiq1WLcc(8mx4L1u8iA4PkZs4E2cEQLeTTrqLQfWZfQQmtsaLQTunGQfQlnvn0JvccSyd(ZsQlSzk3Dm3ID1pFa6QgZmLxPMIIuvJS1WQoDuIWIfYItzLIsFvlOvHoiL6gJCOnjKIYBv7MvAW1jHYrgBoxu(KmkAaqQgtlbMAcOerNCVpuEOOKhkCnwELSruAJrifuuscfZMUHoCTnVY(eLjwSKD1mlH3Xd4vk1tucdfzNwQOmxchY6eLhQ2Bmf9OCK46s4eLKuRiQHjO2CnKmjHG3yU5OPLseLeUazbGKHjtSZXenr5bKva18c5IbqVYXeL7)fxKJMtJunKPxtrgE1eZCWyQJehmjFDzEm1Lwbu(JQzs5VLjo04BHm1iYmnzvskTsh58k5CILOTTRml4mJ79UL3ibhB1POsvidzgQmVosbTZB2TiZmDqoLQtQef4q22Oj45iI6Qek5tgLOiwnaSsetlPqnEaDU0cBzTfsbfKL21s1nMr05Dzg6xDgsHjKX60ODay7GlCnRLCOp1C4rQOdPYgOqkDQl0UyYmYBr9hsa91qHBsQzVwdvl9OUukIuWbfSQEW5CziU4oXkzKyYNWmi3C6sBIuwt4)OnNL4ugBXhKDEjKykoRKNbDzsRKD5C91DbFRZgLwwlKSkfUd53akQIs94U54i35ZJCkwH8yWm0lbtBHK0bNs5EFAKPUn8PTjiho6MtsJLha4WlNJmFo9Y1IniVmWwsbpWfonhQ5WNxQ(5JT19MwMgdx2y90m)qpVhAGT6PwiWAftbZG8bzQ72J(BxoUvA3z4ZP6q8b8u8P)y8bu8Cjt88dSeWVddDhpjFmCu(01NLpVFm)odkqv5E926WQs047bLUO5CO65y)X9OsxR4cmJsDI)Da9t3ob17UJq9ZUsju5p0iph(iC1zJyK2ZW3d6q89OCk(E4boFh9OCKpJXzq5Stjzi(iEB75T(bDGRdEIR3Ph56UFMR3YdD9wDQR76XU(5(CxFpqovo7zf7GghDjDCeuQautZJxdK6OZKDa5Eh0QDon0(0SnpaOzoXQhr53rg7pmw8j9uGPkbp0xzwPE0vD6oDFnD8(6657RFhWVD4j8BBoIFnDg)2NGG(ee0NGG2Cu)(2ldbJoEN2Vwc9hSOv6Dj07sO3LW7udI9Ue6Dj0AxcqL)r156EBNt3B7ti(oFjdZP7AfxNBCn3lrINNC8UE0XtXfuE(B423mSSEGYtz2LMxtxA3fvjHvEunzPy9Y5qriMZw8)Qnq4I(D3xqZAHWmL63DF97UVdccr97UV(D3x)U7ZH93MwSM3V7(equ)U7t1HE)U7ZarPnM(D3x)U7RF391V7(63DF97UV(D3x)U7JAEQF391V7(CTh9n8U7d2vG82bZRuCxd8DAcqW2U7RDCkKgHMiJWnBC8sbfXAtBluaOIUVu)egWoQ3QNIpnGkO50bKoy)of)PJZGMbJ(ue7pd8Agb(tEFMmG)u3s2f8k9YEEk17r(LbaVLS66vkNp6Fdeia2soGLtdTFItDC01utBjPWxFkHLC6QTLRyB5R2pWQjH1aDK2YGSt5W2TVKc6sIneQSKvzxYRD3(TvGIkVYQCN(1kq0APl5)2HunF2qQuoX9iJ0(O(1uvZz8N7BQQBMSVUhqwCq4sUZDduhuYZHqp4KNaYN(b(rCGYtOjLaNJ9J230bA4HqZ3aiV7T)t8GpjEhcSqZ)WuU4hkRnbLmEiwcwaenYpVwgrPP5Vaeu2afeT2HXCTCVsApeJTyr2AE8lpxQT9fIGYmOqT1tzwWc(KCFi(cLHjTH4ltbDj8hInF2YehzKXWIay0VfpkbTRlaKLm11fObeCCHbGAXGRANH1k4O95MGozulz3Nla8(RmrDtt7AkyjF)E)1Mq0aGP1zWsosAM6Foaa)muuZy9R9aKDkO1E49YIpaPoz5exAyNSGeg7hmSgfqMt1Tgfd74093SpXXfPassdzJUX6w01TKwTWfqTcWfO1GVZd)7EbL1q(aA8fPqwb2LpdgLfeBPf7U87Gbf7GPQ3AwLKs)a)hKZ8SQMLwsuE(UD4Pi7ABoCuSMnqPtxTyRBoU6IDerlkdLI)3Ap3dv0neZe9iTJYCjscWu8Rn5pqcFnhQECbotfxmbqKTjJNfCUS(O2Vgk02InVJ2HVqE84TaJcwX0(PixTTOcUHL6K35kCes3NcIS5AJBnu3jqMjvp)3)aMddb(uiJDGeAY5mVjehSImsU84huzpvu5pr(X2VNBC4w1BxEq6ihkvh3S1f9f4PAiy0xCO7)rWiRTD474gOHMq(jpEoRiBsSHGoNeA8vTEYniTDwOlTPXRTlw8iLa8CtSuztt4cSaeiJhGdcRsxTQDru6Fm4FvFgmSd3ZUFp)hb4jxSmlynAudkKrubiRQp7j3GIdPVBP3F(k0xEyoqR5bvAq3yO2efwQ8lXw)9fPzMN209OuSdt1iMbp3c5BLTgNHvvtPO62LMahwfekLr8lZJGJDPQ43OyEvcwHDLUj9xkABoAZBnUQjxjmjKMCe)uDh61RLNB4iwRR0TfsnJlALw1abpKZmayPACqlh0uAdGNZxMRGV2XlOvpp75ODiwjXQHv0BYmrOrlyiOpt1lxxZvcZpxzWu1BjEhnV4JbfXkVb9sLpkF2(0RH1ERITN)S1nyPd)j6JxUtt1RidnpBT6fGUoBXGzhglB3WAJJTirWwjKUCIXEiylHv71vXBvU7tNoMAtc2mkN))uJoJQUnXxQAdbdiKRCDtOZYG44KNPAqNfrp4QWtahTJrniiXoM2oArRGzGoPYHH9VyXBnl8scHdDijmTmdyG7G7YZwd6FXxFxhoMnWbcuGn9sAkpfexGijBQ)qOO)qOO)qO4p7hcfdGO38PshEn3mHGkd9JMrM2rJPoDOFEgvqgP)e69wQzjt9dVpBU6BSyBGKsUpNmzrdh3c1UaHDOzRUDfoqhY7RGx7KVVcE7RGxheNAdYSVcE9cS9vWRcO()3ORG3bpUu4L3xYORGxI1bn6k4D0vW7ORGx8yrGnZrxbVqTSrxbVjo6k4D0vW7ORGxWzIhDf8c1MWB8WORG3rxbVJmwbVeoBg0ITi5YTapWRaZibSDyXfShPMDM5KzDjOHB5xuQLb6OYfK0Xb4d]]
)

-- The hand-built lists the wowsims.com packs replace (wowsims packs plan, P9): a saved choice of one falls back to the
-- spec's default.
spec:RetirePacks({ "Feral", "Guardian", "Balance" })
