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
            return 0.20 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
            return 0.55 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
            return 0.55 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
            return 0.35 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
            return 0.55 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
            return 0.20 * (1 - 0.1 * talent.natural_shapeshifter.rank)
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
local function imported(option, name, desc)
    local o = { section = { name = name, desc = desc } }
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

-- The priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc (a wowsims.com
-- pack's from its recipe, `make wowsims-packs`); edit those and run it, never these blocks
-- (tests/Forever/druid_spec.lua checks they match). Your talents pick one (the selector); /hekili priority <name> keeps another. Restoration is deferred.
spec:RegisterPack(
    "Feral (wowsims.com)",
    20261125005,
    [[Hekili:S3txZPoYY9BHxiOYNGbBJp(UL5uvsTvsTPsUvQ4BE1CKbHrxlqejHD8wu(3(D(ssZx98Hqa27Q9H9GfA6UNE6P7E6E6Mhh)4F7Xhwewe94F9QrxD74Xxnz0Ojp(qX7BJE8HTHZFj8z0h2eUg9))3IYct(4NdEl9T8415dNNUoa)sVNKgUadON2fNu8BBE8jTWmFB08hF4x)F(F)TF9xwIb1JpSkEXIi67hLpxpg(Lp(zXQOp(j7zxUmnl61OSp(5IOLH7sk(4N)l)3)NF8t0J)4NLJFx8LySLF5ISDXlUKGT5HfxgUnj)YWfHBlIFnAi6Vg(3Zt3e8nekYc3KNGi6fOpNIrzC(h)mCXI0n)tOp8s075d)4N)Ayr4VOHug8F9B)neqwvuSn)xU8YNJlwT7jm1FP0RgGGjIIdFA0YrJIUz587Ugb2FB920SceA(33fMTioCJelanGCgx4POqe(sIZlYrimAtrugMKFBvCc(B3TC5q8RmdHV1d3TDiA9jlDj6lF8HW5fXPBYNopmjzg9pMHb03WRUtXJ6BXlNQaIp(pyd8IPx(AywC4tjr0H86STHXlMHx1xeHE)4I8ziICw0MOSNFF2200KVTDxw00XF71WKDrth0BWGb9OGBiA9GIIx2K(2M9e8w9SDBd6xeMGMFd3IMGHfPzVpBrC(84TjXBIggTbtgl6pyq1BfVomz2YDzVx9Liw3tPiYiEtbIpUlld9I)y6nb7h0Z7rnjiWmYQMxzXBztPfrKjf(bzrRdJ3K)JPxhyb9yoe7RJxJw7EnAXS8viEq1B0Z44TmyxyQS3jFv8YI4npJ4fVfLv9TK5u8I0KzPlNH2zLopU4DYc2GI41rxSm(5vfZyt4G7NE7Oaxzoxryo)5D(Fta5)qZWb0TdjO9HZdZXubcd9PBSgMKIE1jywL23Aa3R99j7hmaqIEVoXzKAWxqlewyJiAKdjOziHSHG30X7fE79dmTcAKS0UfS8lnUUfCgLmq8gDRb3JvfzAn4R5Sv)CfP4lG3us4)3UWI45e19y7oeP0WIPJ6tSztE(meeqJfnzmAvcz7(1OK2asvp)aHtPDSdemlrCUFpgT2Lf9mEhui(l(gALABs47ZEkkj9TPxnHGKI0NFojAiYNOOn5iNBY7tC6zg9br9Zq(Xr2(nEeDLtlShUaPAQnOQjMPk(rodjdMNJCt4qPRvrHjfRYls3e9TD5riXYLZEE(cK3hI021JCHJ5c2OBkitFti8MwbHpfM9s(lXYC6BDc4uEBjiCMDINGfP7MVY1z0akwXwJqEeIbXE6tqlYBdZIipkWgQZI(77EfPNXFbloetNY8GYPP98WnZrktWVZ3W)VzvEht3rlsoF3m5SBdr5jLEkf9jgQNveM9CKvna6PMk1lNwIXKeHfCZV83iCJ0gKL(wXPhTGsI(GAQ7Ce4JLb3RNuAMalY7rK99zi7S5rekI82yAnkjbBQM(vypdPOnpkz5m63Bd2HpLIoH4kSTC05K1dD63Hbp5Rehczg4pEruCKJiTY1AjeZDQsnKuG)00AKYtSRo4t4(g6eVectCTMqFmitE91X55OvyBGUyvA2MCqasgl9DCuIGTxPI1v(e(LJsCeLexev9mKFMzVBdbqAdVEc3CiAnYL)OnZXFzyM7GSIORFvbQMqHS)6TqKlMobFbpYiVzvSg4GofEOVXg4ywBwH35kz7VMdGDYllB32IsHn8Q5mK)7p7GX(8vAHuVNsZZXo3Jvzmmgn5X)T3Whr5jiN7FgR(jlLg5hyJQsVCF2zxLFUtcNybXeqwwsAk6BOZUs0qgHtWolAosvygAlAwuyHgKqDf)hJQSfW)(2GE0gSt0GKEb6CzZs3I9zLbE6aSb2LHrzXrZwgNrvFRcU9LAf2Lu6ofINSBloqBRFhhOmIWq6UI84frtcufhyUwtEmJeQvCULWF50xULJHZwd4isNwjc3vKolSOiC(lAyygNp7vM)bAiFBeW600nvS0YzA9ltMT91hkY(QKNaXOYDzmPsCs1OmazwgTZyFPmNvVEFdDwNvhb6DqpgLWgnbpdXEkpdhWQPJ0mLSrRKGjWBWAxLHpI0dcDCb9k8v8PpPsyIpdz)GfVc6GFkAv8Mf(tpljXFiDhsFiYAMEcBX7yQsD1di(y3Sx)ZVQC)gsNbItxSy613oY(QBw8wzYQNedtL0ymLKi05HFlnRyfjo)95IDivudkcF6F(1m4Me9AeXHEeGaE1Bk5D7YWRt6N68XcSC5frAZtZTQt186MDgKzQgdZzlrgPEcPhsdvkIDNi4SWxAazAzDebt6cPggj(7CMWsroNMXmFkyCkh5Tx4IsdRhaAuSwvYk5mqq1kPXYblq33Jv5mqR9NECgGiHuNs(ulji3GyAdSVBJOEHsHwSZrqZaieHPt6xTmokzr5A9IW1i4ZmaVNx3fjo4uhPWNlBnsGu2a9E2F)wCbAetSoze8DTNOZRyd5SL4D5fiUBencJmAIZH22MQ0S11JK7jKLK7NogyN8vGIaT(8jkz3MO8zjyctJplSjg)BvA(LxazVQEb(dP02eT2fb3xfCjlaDPyvE8NXuRCWPySlfRSCv(1mdRNiDHIRl(QBVIWVF6KR7ZgL0sn2DK3dG1DcDgO9Rd3eY75IeCX(WCHYqjE20(SPdZeiGqdxA0H3aTNNhpr2C6DNsjf8bbxMoFxE5H7DNdOBZfXzSb5rf4)oFi1PQ9Cb8I(jYkEs47Kd4QFNeBJ2ETyb21YpdE8HpSiLNELV8uOtZ2FGrL6gvvz(QgeaC2Xj77nqqU8hthC3fJ5mYdyaPAYsFSqCdylTLAp08I1kNVy8OGFu55g9D41puDivEhgSrtZtcFtKKiprMI4EnicI8ka0d5eoC2VWjVrKvEhOiSwLQYN98yi0IpbAtLA7XFwyLz7TF6MS1baZJzPzrm1tLxlY2V8Mxo0HlDzNku8HMr7UKSl5XkLfTbQlvvBM9BLcP4XhYsVcVEsl19HxP3dVoF)v916TBaaAnWdc6R1769Dx)3UZM2D2uRNn9R51)nqxEaQvjCcp9ANQ)ov)DQ()sP6Rt1FNQ)2q1F8geD8AytcgxAcofSdRGa9i9m8rMEX)oIpGzZSyqE)4BgnQp5p2oVyg6b4qX988fCj6KpyOxpsVAw5J2pEsWznPsCNTTgX71CgoXlTHTqKiFxp846DqSOBNGkzoSdv6pEmFTLidLmk6TUqHw4V2ngrf5PtLlbg4cfrCGxOuYlEmYk6XZXnNlj0EmmxkweAjSyRcg8OcwAevmXiv0OkwrHo8RevSWr0c9yFkjfFrGXsqX26hD3aFfOaobGl5KMwXjkOYAjM08kmrZwh)lPKgxehoI9QTZhxKBVKrCQ(jCcxglrK2enwkjeNq1HuriAijXsaHmm3QaefyPwYhkqRjv8HQyPyjEyajv(vCOv4HcnORKoexRGQOdvdYvLWHoaqisUk4aw2TKv4zfByWmVUs0GowXk0WSNcs(Y4qfzy0dcrhW1vbgQ2WPQFbk5c63AOIl0ymJwIfYJ0XkSqD6PPKkALkQqbtaLqbf0MRGcncEMlzcJvmHc0Gkrc6GHQqc1LAPlzQYW)ewreQksnEwct0VBvaHQ2mUsEa42Z0WkiqL75wfpOqIvL4q7sFnPchmRUtu1M6j5kHNWDUvbKlq2LrVw8VZRtOoXS4J7Jh(mL3R8STL6nipmOVUNwUuOadGtczulQ0(Mk(oJpihNbv5IEBXKvuEug6FR1PkFfL5cOrGQuI5BIlBnw3fX1aw8oijoRBR86CKeohHUIYR)UuyGQ0Ti(A7zNQ9E5VT8gRXRNSfMeYAwzO1)BVpLUo4455Wwg(BusZ36GdU8aWTkCtTQ5g(lWZmQ2m)NAQZTYfx(PefxuvlyrzyDTvIgvelweBD4)F9TTa3V22Z(mYrXWz5HlJcuaqoErB6egNAvuYcYilvVWk1NYlTbPQPKbXUTQtVNIqhYitJXoU54tOdIO62alm0LxIYkRWvpTCdotpmbp1AHjqEEksGyUg(3EirvFxqlD6GZsTgS1es84jRW5zTlRZWKHALfvICUclYO6MMbH83I3grMZCJG8mIWUgU7aivTYpToE0Co(jjYTxZxOzCRd3LioaYtkFtQqb5rijIQazYE16POWTbK86uZaojDaQs2B5CheZvjjm5kT1NN4QM0xnYe7Ea4E)Qe0W)vLPmz8q82ty9gmS)pRWA)HoLnvjTc((Tr)cmCMHoXw6BePHpfm6gkkRDM2xDA63XCedYLf34fbnoAhS8m008KudIlACgteGHWreAeeAswueaGlzY4iNpfVPNJEMveOOJyowuWZXlBlIYDhZ8UODsDSZaJaspz5IrAR4zlRmoqhNI8Z48kVh51WtSEkYzJRYAEG02l7nsexlLhhbOEsYOJOi95o3ocutBLLhr3joG89OFhqCBK5ha3vAwoGG99rkEOENniqFIia2J8cj6lc1Oq7KHijdWTyUIeN8NMSgjGZwl)rscYTwMKeGBBKtjrXKV8zxsu9(jnptIAw)KNXjbI9tBUNGvZkQsTrzHsa4F2YhLt7ZftbsnaQgRHFqlQrGgRw8I2cBOAPotUaqBPEu(qqzLwbI8MIBfa6s4boXDWCVPVtEVmxGc9lCg24I(HxVcVr7H6tANox7K(u3ZZhk6i1zQ7NlPkW)WJasywdmXHsxgdxYPGSSh(e36u4hgvCo6s6Uk76drCiXxXhI9i150fDN4C0d1f3Y8zRBQlqDhR(QUO7xTyhwx)oUkgRNXVXDubP7TPDDDd(sknihIVJ7ysWhtYymgVh3bmZg4XPNSl5GYrS7SlYSop9PDbA4O1X2L2iD06D7c45y0f3ffd)dx)Cx0C2zTZUlA54lwpExG4)Y0T3fO66sdUMkQSmCQ777YA))m3b4f1111l4pG1s7SkZ0FB3v4fxA)u2F4vjXJCNIxaHBbCGOhN1jIbmMDa7T8a3X9cSRAAStDO46XhqoFKJqN0pY1KFzMj)wyJED0)(xj)cBZAEgp(Vw(RWm6F5IY8JpmpdjQLfhI(eHY1f11hlq4caACHx2DGDnaWQMPUdQBaavPTl3H0ejijCwhedysnW1gEvEmzluHEeszmPDRzsBsBqAnkAYyI77MjURh5c2zmMhFGBhdweUAEXfnAmsVZmsVP9qADOOX49VygV3oItyMfjypOenHqgJ0XJSpBLjzs4anJAnHpwx8JjuGSYedsG8XfZL5U9yhtOazfqsuW3N4cUSg3vEfivH7fTwUJfVxEDuyQswt25IQQu3HjkzDIAiQgiUOkAONwXuGfDPFxqCHg1Q2d5w0w(9dqwDRPyf7vWIjuQSQZAYQo(W8KfbuUfMyc8L1sw5cGqKunIHMeGycUL1uwjbxhtyhrS5qd7tSHjoYiRmTKWKdhmp1jU6dfvyc4HC7IgKxBaLmz4IhmbKq(EPBRdtAZRibtqIfnzxpXIBAuikgfycGH8qtluKC41H4)sWHS(gtEbsqHXi)sajrlISJbYtxdb1LZLmQzos4H5PsmwG0aGd0Rj05y8Ej4aslGC0zDrbOxr6LG9)Il8rZXYTMKjptIhE9iZyWy4B53mj(CrCm2LzbuiCRrs5FlcCO93CXkLhzAIRRqGDpYr215q7sMBxBMXzMU37wGB5mSvhJyzMmKAOY4QYtvhqGrBHy6whuxcHdPBJeF1JivxfpxFcOlHILDaZb7gEEvdjObs3PYfauqGZLlDyRDRdj05DM3ciT18416l4I2uqGtMNU2IYBMGHlDedEKBVJgixWQCAq5WLe1EJfdbhw)YOTByggMI6msCdKFLqgjyK5PRbBOmHWunKPTJ2E0tq72qPFBGweW1bnoiP45mu0nlLyu1(r135yNvWsx4WJ2WbJf6s)zqxF4qAAFJlUirMPKEXbVzbspRqwGhYUhxzKRrxuB17o2dTnWBXJ9U1(oAy)7GWQGm42ssCCNrYfzfj5ciZ0WeNqMGE8b(mgHfQWaf6mnaAdDgUqrTOUvzObS1DfK9Aw0aBlinRVG4FJbrFNb5qBniy21eOyPOBTf0Wsd2r5Wgkj1ttKTFYryo2IqoOEeYxGMeYbZMbZJcMsilcYUdWTi0ujETmH(QCaVOtlNAvmWV2ojLdhpTGD4OQei)yxcC7sGRFKwxcC7sGBxcC5vG0LaxBPWulTw0La3Ue42LaxfhL6sGRdo7jf)(Ue4cGUUe4wXd7sGBxcCRmS1La3wJQ7sG7PjbUIz(ZSUIc8SBz4UeTr4b0mk)we5Mod9Q)ZD4gIwBawB5puWKpXgJd)Mb)4dBrE9rM3VgMSlchVo4FKlpP)W6EQ(L1f8Nw3UFBDbzpxrzp)jMd45pVUo(7RRHFGDB7FHD7dbVPJ3Vx41XuLH1rZuM2DJLFPXLVGZOasqGwfm3tulzAD4R50v)KfPdK6NduSkasxHNT5lmkGCbeihgnadq(QP1ZNgaFipR0Do3gaElHY3RuGyTFx5roqGOxlzbWR8IC87tAyk2s(detwInwOwK4AguCjPchtsrmVk2sWGTeRyJ(CS7QriflzAWPST4w7wtx6wajllbOZLuW0YnGncz5qYgCGaSMce9cy16)CjznoKvIZhPkKbhpsHHpIGQIBUpbk0KVcptRZrGISybWLC94gvDqj7bK8HsscucGo0o9g5S9qjaboRqhVg)gHGGszcqQIAEFGZNCfbsTqXgXu(JgikrbLajqCc5CSAsL0IjcqT0M4i4bYdzT7MzY6ELQjqmBr3S10pvgfnRTroc28kcLTuxLJGyOywQ1bEci8UjZrWJBXC0q6RmBeJ51G2uAbPttoLwk0GJ50cAoFnKEnt55641t6iKKL0gXyb(3k6QNCAZi2vwqRXuIzgFMttMBz7XNEvxnM1N7minwq5o7RsYZafPMyHf3kzuZ8kHHSSbPyvxw2oKgixRMMnqEnK2ALuV12tLgL7nWPb0faGe5pDop4CZXRf7oEekfY2XsHwBMzs27ML3H3T8W0(nqMFYI3crWhCdwZAZZZNUN3jS95ryyGLKOtl225DMNoTu30JmtaVGwHVCa0VL1(M2C9ium0bkaO4dQ56PVuP82WD56I3vKQEdX94SetswhDMQuomGSqOy9t1fks72CfGqagQihH2(xv1YfUgHiMtk11ogwLBqtQdvOjQxjDON4HwW(bXeHeUahLKl3jzApcgYSTbfl(CzeesO79thdOO5QwSyObNQ2oNhBsPRe7f6KK7v1mXFA22HGRDL3qv43axa8A1ZLeC2Dvs(J2fPO7QKuEvs(6Etso2ktblhzXvRgB3OAoD)0jx3NnmjjbSBwVhyq5m0jn3VFD4MqHAWweY81HD9yl7(iTgpSbo17dpeqAJ7AgbV5J7chHwbMiBi)UtHig0jfupkUpCfDBvjouwFBxP(fIC7To8Q0prKqscFNe2b9Blz7AlXSeEGDD(m63Az1AtoRXeWt7iD0CF45qHtO)aJgrmRx08D3ka6i6iMsVbcsZ)y6G7UymNVfa2SQMW0hlgvh2QFPkjDVzT9GlgpkaHvHxIxNtv4aeCuXgznpj8njQI8izII)9GOjY7aqsKZ5Xz2eNqvr(5DGc661w)K052BDrBAFPamJDYhK3lz7E8bzqHxC7Ntwb0bYpmDRMfuvdfsTKF)YBl)qhUI8)5wDnE5dmmdOTTYh3ZJ1plAAuxaRut436hwRMxegGc1EsYa9HLaW8wibG7VQVwp4dGqSbgrqFTNzaB0XNjSdUO1DY7)WDUZUtE)LVioc0LENATdh9ZMl6mp4vOPZorNDIo7eFv1s2zNOZorRANa6wVeVbrJVk3Dj9rbvv7AScu04rWOjcpi(3rml8QblSS3p(MrJ6t(JTZlMHEaocKsnpAU4tE9i96LLdlX4jbNJu5HzWGn7u1ZBxtsv1wp)PkfVUqwd(J81mYHBw0TGxoufVgmtRLSu2bG9GcSDxqjJIma6v6rLo4VIyn8g6vGBaYgAsK10JbOBTfcW1iklGBMaTyLDcE)4BTk70RUyudGVpDWOgaElfu0NUk70sLg9jSYoTujsNWk70snMEIlStlLz6PSWoTuJPNRc70s9MEUkStVATLN6QLSwTBXN9AqTsdEHBLGAtebvf3CFcu4x9MEIkStVk1up3uCckStOdFCmlStWQj9SvyNGoD)PSWoHU6khZc7eSTQ3Yf2j4nG4OxyNw0n3Yf2PFnGfjyCif2PxxsAciQcPGxf253TCkskCokf2jKoTJDHDcwrPNXc702VvyuC16f2PTyiC0kStBvukfFTzHDcPX6pSf2PLFaSoZf2jKI1VMf2jK26Vyf2juQqvJaBnzvzG7KwyNG)GB5uT(r)yDHD(pgDDJDIZnL6OBStShGHZDclXfzt4Wo63g7exDjyW7g7Ke3kQ0Gn2jHodiuePAkbxBk0kOiIjVc)1EvawAXeHUwj1G6z9PaUzWiB7GNUfG1PcS)zXfShPMDM5KzDjOHB5xeWmNfPjyPJda]]
)
spec:RegisterPack(
    "Balance (wowsims.com)",
    20261125001,
    [[Hekili:TBvZUTnpqWNfFX1g1q)44KMVG4a0GGIMGVguuLELYuuRSynfLkjLtdqGE27szBf5FuBtkAp1lj0l3DMHl3H2eFYDKGyQbi3o2B8j((Jp2ZZNeyEOaibfu2c6CCHKMH)9sQGkzq1Sb3NFVMNPDy5zdTP9GiNgBHkQKlmxljrhevDbWibx9PpF9vNfTcmsqkpogwvbOzDXYzvZmPyW1XCtYvWsqvnlgsOLct1S3(X)VAggUA2tiuYDTCQDJvL8y31C6sleyOvf6GFW5l6C5WrifkQulqHhJRZTuY1vZOXX5YxHlwapODQMDf1qp7aszWhU(oeKuJPqFMR7CUjTmYQE3DsDiIjQyAKxINhmjHD6royBuLNWfyhHYm8CP2PqbyXruZu6xlPgoleRpBepz66WE9Rpx1Hd5sdinv3Sx1VEQlEUwcIxC5mQ5fxBwEUCbx2uFVOYKeN2rDkl6pO3k4sZfXC58Wvc(X94y4Hj5Ef1KAr3U5sieKqgh0NpPj9xsl8f14E(TR)GnjeAqukbDOGpp1mQudH5jjHZzXt9BNfxkb1sCW3YEgvsDkyMqr(5t86NylnubzuUuFXrE7k8eUcgLKZk1thxl(yOr(29qPVnvAaXwFpfpRhOS27VtPPLkfNrLW(x1xmDs7m1gQQLU8TfmyqpdvG9hhGj4fAWbK0ibe)ynVBcwwmS)GbhoZ(BLjscBXf(dFS3kID2WQd8nGvAW7OHBDxupMwDdjaFdqJX255rbxB01piV6PjC5T1pqVMDYLBEBa)FRXzsatXnGItXvDoVrmiDDGwRX8FDWoQdW2m()RJ0KoqQTbOnApl7Xb8hwopEhoBznSD9gn02)yR7Ko0AJdQTq)jojlEVzh8ADk33hTDRXgKeupHBVArWo9Nc2oUR26)Pn2g0)RJtCJBSnp75kTi471PU62u(B7k)H2YNogB2T5q7xl5UmE1EyIDuiO5BG(Nr9VOrD7lIoh9oFs9LeEnrlnP5ksW7HfCbh)zAVB9VcREBY3p]]
)
spec:RegisterPack(
    "Guardian (wowsims.com)",
    20261125005,
    [[Hekili:S31EVnoos(pl(F8zJUhhNe7U7DqCdClgShMd3T4WM9(34OyrhRTLT8PhjBgyKp7hFjjskw8HSCCY2AgGoj6rv)yXIflwSyP7U8U)(D3ggKJU7VE10R(YLxE18PtNF3T5VShD3T7dw9JGhX)YUGT4)9)Oiinmky3R3p65KNZI2MnzvY2XKN7L4KGqcTEOiko)33D3dAjB2E0Q7U93(B)V)(V9RpYP2D3UjkmeXEfu2kq(8RVEF(g0R3ZV2fRtsrpHsF9(q06GI48xV)F))5)617Xx(17firr0fe2MDryAru4fRrPbXpGcsViyFC2fbHb7ZJEcnb)xt(hzj7g)zmBsd2LfJHFi(3tiSnk717dcdt29VH)LFGEjBYR3)Bb5b)Qg4m6)(3)7yISjpFF2VEXfpgLVP4bsl4cLhDmMMyuh8W01tNIMTE13UMqw0A0UmmKWCkzngU4F(Nds)r2pIWnNGDymLI7u(L1f7cja8VKI29hrKF7VHEeTd38YJs2XiDCYZyGGcIZ3GP8VVDFsAoMC)fImqr6IFHmUaEf9vJYYZWnd0UCukH6pVjkgFZhkwVEc(jwIBeBNuSFcU7pnzn(E3DBWkcRZwSkioEj7pwsOZNj6p4RM)5O1lujWR)N8x7tlUi4)RaJ(v0BrE2ryK9qq(IPdPDE0RVmcJOD5JhoWeLWDHpHI7acruv6aYuE5JJkR591ltf6Q)Cyu2(4Gxw(ac3FV4Q5uEKN84JXOjHvAtdPA(lzxanKOdnjo57lUC6qkl1s7jHjpVRda1CZGs8nxUpfLLvKIosyXu7ZYt2H(CrgAjES0YhxfU4sfOD9uxKxoWSODpUCFcTXBIFZ6c(9a3GGcT)It0MjyljHRYssZlpPy1gxBpJymDvqg2cYscjoWUcUdEFqkIEPXw4Ck6Fu8eAxl0Pe4lRblskxA0Rc2TcBcH8iFM8plPwXQThiJMVAgnf7Y2eToNbNsL(SCQqni9rKTr(6btLvL3uSysBWcRf76BdRXgbstEo)nNRGkH(W5rmdAe6tu)oOhjTsxnfTn5j0YvfPzikGOpmbQO44GhI53c)wCGLHIxVKDFlKo4He8C4BWM2IWUhPN4S7rOo9wYVcf)EZwmEroYZrdyVMkF)XoIugcrJ9gsBXwmXM1xIDsA5ZrXHuCj3ptHhNW0hFBuwgU31M3kBss3Lbsp6RYEg3ug4dsQKBLxrSROKfO4OCu11IWO(fBt(ayc865cTa0wewFE3kYndsDMIvqU6sYyMIp(F9CWU8mxiVKZxYpOaXzKdFhB(7WMEzdz8QYm91nFI7CPPf7Zl1YiDKlXRR4r7tTNTrlHg8qsw2Wbm7etIWTCYF7l5X4oogT7rIjN0KGuZZHQ8WddrmARCDx0kjAGXGYR4Ke8DyTTsUqFdxiDkAf26xkEGzkcViJM8G5W93Nwz8x85TqC0oIRYGappyh2OWEIRPCQZEbBkrbO0i0Y1rPm71nP2HstbfXLooHfif7X0hTfpeLRhKuKNffIMpUPMa3bA6L5qO2w5EQWvWe5EbPnVdqaKU0neuKNSmippy1p0iUm2Co0O5pwd6TzFojzxLaTSDwBhH2whwE9kAWUCt0jHLMYwUiQKNmdjJWZcJhtCOuFZM3TpJxoZMtaChnGde(Bt5ZeIhXlZJW(novtlYMzjjt0YMJhOyXU2lJIS8GODi2ACTWHqSpm4xk6pKmnnkdLt8pkBYwmLiuBzJhKlcQmFrV44H6UAz)wdA4IcUfl)kJihQiL4gzjoQTfVuFn6ud2tqjkdLI)zTH)rkcZd1D(JTPHHIl2HYwgh94gDgg56hIpLSgMwMoCKABrPPFG)3phLVjA3CRGeYeBj(IdwH5EoIJn8dGDPHOpKDZIP120KFSd8qCCJ6DxLKLJH0izZ1DCBQHbEokeTPYAnAm2w34QGjZUkwROC0AhJ3MJ(wNSQiBXvh7OWrdW)p4OoHwAvtLCdsdLzfTfTuln1sfbPwiJ1mByKHbWM8R0JQWorFCBW)C4Ord4JsWDvh4)o2h7GLzbRrJBqGmsx6I5Cb3guCi9nlnCvKswOZqoDcFbl0Aqc8KIwnCJx4xQUzKfAYpGxDOnhHO2XWppE5cI2oeUCPPd(0bu(wpzaLrRsWApR0iDpaPM7BVFPFtcExOHBTbIVzkwclkXfLcxrvcEHRPCFSLubYWRfmi0TyHiAxRtiy2Zr7ru5JibOxKomstpZiil(QxfV(uI0kCSOFVkQRh0CdnV32GIy5xGELYNKPqrVewBQk468hTUnsN85tIuGnBKR9HsgL7SHmomIXgcjTffBmsyTsKC1utDgWwvwLKetgyiDlUj4VF5eYaFylsCU)lne8vDrIVuzxcKeUAMkcDwIxkCYZuDL3JY9wQ3RTHpuxR(iwsiZVhYBfAFrnw40tbPreSZ2RXNW2oIcxs2n6qeXWBEgnSDek94ll3J1L(8(IuegipfexGWlaBuTSsEXwhuzlzT3X4UxSOdfgKNK(cj(HRI2hJDuEcAhves0gkFkQaEDr6lv3K4AtcjAK7YZMSQinf)GFFXmSo8aVFR5unvdVwv7knApVjXNXHCHYHqlUESf2tKq8BhTDFkwjpCz2gSmO6jgy89T8YUiu5pdD)ly732ZO0Q7sBtrHjXKO0I1GswfL)cTdBezzVFIo)7sEdE8nl(Y0XUkCUIkC(5T9pBm9)WTqEauJXtMrcOagfKz8ydSOg4Nrmfpq7tns4X(68dJgbOrFqN6m2e0pWDeweJymkWeClKcBi6T4Ydsp9HrM6bnclTdblVPX(TXNrndSSrxFWnetrM6d(y2A13wXg(gxnvcXq)c18qboHnKEVp1iVtC)fLIVM7Vw50s(9wUKYgS8iXwQe4rAK0gqm3iiAvAJOcd)YtelYdDe3R8cXt6BmpqS13XwdSyAGabF48(OTP9HkNSMNhTpnpAoKX)86O1PsHBmVAu8jL32ZBdNsJbxyLX80Od5IL8YWjoDmPLrtejNhg03YT0WqLunZ7IgeRnPDrdfs58SWap6S0Sqfc6YRc5(jO0QOXSVv5rHU3NcrH0OauPTuo4zAtapLUU8KG9QYPjHrNcyMR9jTim5SG8IA1LgenMVMzVfy3Vy31qAp0CQlwEoO(IoMMdnABAYRHojTguzeqEmWOS50yOPcN58wWyAlOsmOnrJ9UqPPqJozLTTQXB)omTeAy50yqNmbF3sdHg2VeY7GUDF8Bk7ClTduryvEg0TWRnPzGk0OR9tWIDrLHEAppzpVQdrrWtKLBif(s(1uJC5dOnr7cTZ(10vhMuKvTVwnWbBJ3A2vae8Izh0F9RkhAGh8ILJ5HlU(ltB2vLgTxbfduehnrcVjhJWR355K08n0ZQXqH44WutGI2I(RFnNUXi8kAPMeJ2d8OZkfv8DNsBlvmUmLDEyOrc2Ux9k2LhMbjHKlxJT0)azB1AckzMRfFPb)WFuzPxctsw3KgXe5EG4O5UWvYBHnHZhQQohqPCX7mxqRv9bcM1PHMKH2g7XsZ2kzGofqwMSGsvd7Dt5U0VocfhwTtQbBXKNpl2brJiJ9pdem54vJDXOrQ2qVbhccjL6XcIMdQ8yhpKcD8nlUeym2vDx(Q0W)gJzYeVDOlrMe7Tp0CeRyweFSyuNi2DzSlb(SFxLuF)Zy0Kp6DvPFxL4BpZhZnv6ezPtUFWtd1v48MfZVEi)Tu6zj(f8YyylJqzJ8HTb7cKYRfz6kMBl1VAz6wEKsLJA6lavcH9feE4Xbrr6C1Pc)2PupGS0iw2CCPNnyDJuOEfvNjNmVBoiePf2Vr7pJdEHUcp9dl4JAoOLlWU0DoC9ISEkTjeJvri067goYObzJMzmVZOJbwE18ddgjP199fJ(2NUuycAaJ)vnw2LLw4mVNS0uGMhS2W6NUC64VxTqa2ZioyVCDCJfNS3gMwfh8SmKOxrfrcpgeGOpcaEOjTGWCpKqVllk)gOgRwlKQlGRl0rjlJRLkPdex)yJg3xo7TTQ474rJYScuZvYwRqoSmnWM4qgG9tP9qYyf55u8OJXYq7M9mvJm9RJbBfXhyP361aLE2HWDShG7wV5QHAD7CmaBnidgpuRBUh6t9W(fj2VirRls8JzQhowxCVRnjCcxgzVL(El99w6)izPR3sFVL(2yPpAhMVpf0IOIXpsvveGT6BUDqARj6pWnBIuLh7VBUC20PdP)X(v5lXxGetmLtKTqeZUEQERQQRc)Y5JFt3QM61LwZNdAw)LC(eyl4fQPHGPewIm9Sv(x205R)ZoznM8l0ocA3Vdh4kjktY7nE(L3YKJVMcFQTPjVejAtcZlrGYHcT99Dj)1pTjrV3W5uNo9sa60Ly9nyt0Pkf7L14oHjBV2M0joT7L45Bvc4Rme8CLk(oaJk7dVrO4Tk98v62p5jQVRQzEWZolL9vWw3K8(se9Tin(LvMpZj0Vey6Ou7x23H2NK)6v9J6G09hW1KwL4)WU5WMeP1hbaq3FKxAG1ddGSFhSzb6KJfGY0TD3beqUL)MCubKyzxDObuuG7QJpGez7GdsGScYh9JuGS983YdxGST033hZajS(E9ahibYQqauZ0kRPN6JEGQj03rhcbzBm)0FCeCVNYUKXmCp2dMGCh37HJOqte1Thwbj6Vx)CSYN3aFIXimRcjUM006FBiDfzH)QPuZ6M(QjoHH00uDZxsfjA2nFtvMa6DBxqqrVA7c65su1EB)IR4n8ER)2Ribq)ccOnzOxS1RGc2zC(T8lZI2M8B83OLjYRi5881ArXeG)bveexwJN3rcRk7vNjuzpOJU9Tn5OaXz4R6IRQT(GHJjQKEG1tZx6fzVhodFZxKhS8o7R)Ie4orFhyK91Q7(IWOFOwLu1ZOE6mNmheuERY9VsmgCBKnPPprf1zgj5oP8ROlkPotx(KENKVHmkUJC6(AYilPolFxzKGWP6lmJYaOt13Agj2Cc(QZiRa(VAF)zKN)6C(LOrEUIpwFtAKW(hLVongMAqEAGbkZu0IVtns86D(xSg3mOmsY(Hw6D3TylyzysQ85CM(ncM8vFg)04F8xPFnP5Pi5D)5YVhW4Fkemk8dNIDQinka)BuWPl(m3LJzfa1ecdL7e7AaIvPm4oPMbqQsrM7uAUcLKCuclaMxtCTHIrKt2ISGhrFIaTVygAZ7cO1Qipra3xndURN6c35cM7UvyibrfUQDje6kct)MzMoR7yADGRi89pzMVFzQGYmpWrEGenrCIW0lNAV1QczAiemZAnHBsx8MOiq1yIbnqXvt7sB3EWMOiq1aKcc(6Cx4L1q1iAaPkcrKpK(8qejAJIGkvlzNluvzUJakvBIAavluxAQAOhReeyXw6xLuxyR4T7yUfRLF9i0vngHjVcXefPQMoRHvDyLeHfZ1dNIUeL(QwjRCbqkemg5qBcSeL3QwkR0GRdMKJm2CmL8jOsuhzunMwcm1ajjIo5EFO4jrjpKBxS4dzJO0gJqOKOKeY3lDdD4ABEffjktSyj765wCtJ74QuiKOegYdnTurznboe9ikpuT3yYlqzpQ1f4ikjPwruDmqT5AiOqcUKXMMJgEjrus4cKfasKImXohdyeLhqwbuJVJlga9kwruU)NCroAoCq1qMEnfz41tnZbJHasCWK81L5XLU0kGIduntk)BzIdn(wiIlImtt0HKcp0jo(qohGiAB7AZcoZ4(GBX)ryIT6qnPkKHmdvgFgruDeryPdInuDWHOahY2gnqnNquxfyiFImefXQoGvIyAk(PzgqNt1VwMRFuqbzPDTuECzeDEN2F(L3FuyczSonApa2o6ejZAka6toaEIscqQSbYLsN6cTlMmJ8wKpGeqpdYDtso01AOAPh1LudKcoiNv1doNtlW7UvmZcjM8jmZ3P5kfSDtLo25sDmfRqrOKz5rcM2MJSdkaYEx2PupV102KpHkTrCNbQlYCK5tHrwl2GMKdEOn4jR)8uVK12QSSgco(TwMKp2dFFdSv7pQaRvCyAM)tycxpvEtlOkVvvufWsQsFnvbu8Cft88tSeWVQSSJLvfd1vLUUWQ0XMiH83vUNPTg(RGVV1FzrtUqB4(HtBfywR4YFxG9rCbOd5wHz(0vzM1jjMd5xDJfz6Jaq3yTXAlmPhvLj9KuAspENeVLwF64URphCTbYRe1hXBBlIZhvvCgSmo3P1Xz3lKZTSso3Qs5SR1Y5ZDXC(G(f0EuAXxr1Ib37eLv46LAChvMNpDTAOLVEughnR(1mCa16Z(vfk)PXElPNcCr54bEkRTYJUQ3UcgQPkgQRLmu)QzODyrdTnvnutLn0(L52Vm3(L52MQh67V15EclGOwC8gmzg6NsOFkH(Pe(GAqSFkH(PeA9ucqzurvPIUTRP79DrNUZ34lISeAFTAU24AUxIeplg1UwnQP4cmn9uN23mSSwJQPmZsw5r7UOkjSmdPjlftvihY)QC22mxDgOUR)akf0Cx37pGsgGw)buQ)ak1FaLenG0FaLSDeD0I18(dOKaI6pGsQtm3FaLmquAJP)ak1FaL6pGs9hqP(dOu)buQ)ak1FaLOMN6pGs9hqjx7rFhFaLGNkq(ae5vOQRb(EnoimZ2CqTItHup0ezeUzJ9xkOiwB4xHCavC6l1QIoRQtvVeFQdvqRPdiSU(vyWPJZGwbJ(q96pd8Afb(tEFwmG)u3s0f8kmXwlr2EeNya4Aj6SEf64tEzvNaylr2voCY2eG64HRHy2sOENDAbICyNTfbyBXD2g80e4zGUhBrc2Pyr7wXzxxWOHqLLOd7s8P72Y1ofvEfD4oTaOlA1ZL4y7qiJpBivk22EezzFu)AQQ5m(Z9nKZndAx3dilM9Djg4UbQJki4qOhCrqaXf)iRl8uEcT4c4yLFYkt8u38Gw3aq8ZBFvJ3NaOdbwO1rykM6JK1MGcQoelbtiHgXzxlJO00CrLNYgWkvGUHXCTCVc(oeJTyr2A84ll1T2k68uMb5YSEkZCwWNG0dXxOifP1vDzkOlW9qS5RwwaiJmgcMVX5T4EjOn((qwYuJVFdi4ya(HAXG7(MHy(FYQG90fvAjk9CbG3fU(6MM29gWsC79Ua2lAaW0(fyjwhndHphaGv2(AgRFpeGStbThcFu2ebi1PzweWDYglySFWWEnazov3EnmQJdBFZ(eh3SbijnKn6g7)qx3sA1gqa1ka3OvdZDE8LsFkRHMdOrrUxwb2LkRFzcQwAXUllT(uSBz3BhPysyOIKtndIBQCoypbFOmuk(N1t)nsralgw2XAvvDz64z2MeIROPRKbzcq(NQ0MTWBOSbzBcTYMqCWkm(YlRPxkPpE1qv5h7WbEahVr92Lvvd5zP64MTUj28USM1(6AgRTD8hUaGXsGf9StNDaY5Hze44EHgFvRNCdsBNnRqBA8A7Ifp98GfkTsLnnwIz2EjJhGNFRsxTQDru63g8pRpU57X9ShoW)d86XcwMfSgnUbfYiQaKn(K9KBqXH03T0WkFtmlp360TfwLg0ZaNnrXCNCtK26FOinZShPpGsXMrvDgzg0838tTtJcAtL3Av3U0eiFAqkxQNeKIUvjyvZvA6DkLHnhw5TQvLdQcoYPJHTbM61BZnuN26kTvH1X6IEMDDki3nmayPn2vlh0TFUGBhVX0wQv8cUCe9C0Eelpa1Wk6nzd61OemcCwq1lxNOjclMrz4r1BjEhnV42GIyL3GEPYhLR)sVgw5TAha5pBDdwQUXqF8YJjNwfzWcoKw9cWjdBXOwhg0A3uzJknJiyResxn1ypeSTTQdQN4Tkp6CxoHA8b2WiN))sJoJQUnXxQ60mciKRMmMqNLbXXjpt1GolIEWnPKaoAhJQBnIDmTD0IwbZqDsLJd72IIaZHrcHdDyfRTmCbGvKGYcda934BgMd1ia8u7fytVKMYtbXfiYkZ7pb99NG((tq))QFc6hcrVfxkv5n(YucQm0pAgzAhnM6u9c8mQGmwFb48gQzjt9dFmBU6BSyBGK8moNS8pdNv86PaHNqZwYkkCA0Z7tBr7KVpTffGBFAl2yCxFAl2N2IipstR(0w88I0k7259PTORaQpTf7tBX(0w0aJO0SpTfl6tBX76tBrBoa1N2InzxFAl2N2I)uM2I))dMNz0LT4OlBrnqDDSrYLBbEaubMrcy7WIlypsn7mZjZ6sqd3YVOuld051jiPJdWp]]
)

-- The hand-built lists the wowsims.com packs replace (wowsims packs plan, P9): a saved choice of one falls back to the
-- spec's default.
spec:RetirePacks({ "Feral", "Guardian", "Balance" })
