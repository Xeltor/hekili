-- Hekili_Warlock/Warlock.lua
-- The Forever Warlock (Affliction, Demonology and Destruction, one spec a talent tree: Hekili:NewClass): the Warlock
-- kit with Forever's spell data (ranks, costs, cooldowns, cast times and durations from the Forever DB2 at build
-- 1.60.1.70338, wowdb), mana under the five-second rule (`fsr`), the casts and the five channels (Drain Life, Drain
-- Soul, Wrack, Rain of Fire, Hellfire: `channeled`, `tick_time`; unhasted, as wowsims's rows), the DoTs, Banes and
-- Curses on the target from our casts (one Bane and one Curse a target: each removes the others), Soul Shards as an
-- item count (`soul_shards`, item 6265: Soul Fire, Shadowburn and the summons need one), Life Tap's mana (its rank's
-- amount, its level gain and Spirit, Improved Life Tap's +10% a rank), the demon (RegisterPets: the five summons;
-- Demonic Sacrifice's effects, ended by a summon unless Demonic Pact keeps another demon's), Nightfall's Shadow
-- Trance (an instant Shadow Bolt), Decimation (a faster Soul Fire with no shard; its talent's shorter cooldown),
-- Demonic Sacrifice (the demon out for its effect), Amplify Curse (spent by Bane of Agony and Curse of Weakness),
-- Conflagrate on our Immolate (consumed unless Shadow and Flame keeps it), Demonic Brand from Searing Pain, Wrack's
-- debuff, the talents' cast and cost cuts (Bane, Improved Corruption, Cataclysm, Master Summoner), and the school
-- lockouts (Hekili_Shared's locked_out_<school>). The priorities are the five wowsims.com packs in APLs/packs.lua
-- (Affliction, SM Ruin, Demonology, Shadow Brand, Destruction); the abilities and auras below are what wowsims/forever's
-- five Warlock builds (ui/specs/warlock/dps/builds/*.build.json) cast or read.
-- Research: docs/research/2026-10-15-forever-warlock/research.md.
-- From wowsims/forever's data (MIT, https://github.com/wowsims/forever; sim/warlock/ and sim/core/spelldata), where the
-- Forever DB2 at 70338 lacks it: the live talent tree (ui/sim/talents/trees/warlock.json: its 52 nodes, their trees and
-- ranks; the DB2's Talent table is the older one), the talents' per-rank values (spells_auto_gen.go's curves: the DB2
-- carries the top rank's on rank 1), the Soul Shard reagents (soul_shards.go useReagents: Soul Fire, Shadowburn, the
-- Voidwalker, Succubus, Incubus and Felhunter), the demon each Demonic Sacrifice effect belongs to
-- (talents_demonology.go: Imp 18789, Felhunter 18790, Succubus 18791, Voidwalker 18792; the Incubus, absent from
-- wowsims, as the Succubus: the same Sayaad), the base mana (1373 at 60: base_stats_auto_gen.go) and the starting regen
-- (the five builds' logs at 60, preraid gear).
-- Not on Forever (the DB2 has no row): Backlash, Dark Pact, Curse of Shadow; Curse of Agony and Doom are Banes.
-- The demon's mana is the client's (`pet.mana`: UnitPower("pet"), plain; central fix 27), read, not predicted.
-- Unmodelled: the procs' rolls (Nightfall's Shadow Trance, Revelation: the player aura walk reads them where plain,
-- the spell's glow in combat; Decimation is also applied by a Shadow Bolt or Searing Pain the simulation lands on a
-- target under 35% health, which is secret on Forever), speculative shard refunds and gains, Demonic Energies' mana
-- share to the demon, the demon's own spells, Bane of Havoc's damage share, and pushback.
-- Credits: Hekili (registration API and pack format). wowsims/forever (MIT) is the reference for the mechanics above;
-- no code is copied.

local Facade = Hekili.Client
local UnitClassBase = Facade.UnitClassBase
local GetItemCount = Facade.C_Item.GetItemCount
local L = Hekili:GetLocale("Hekili_Warlock")

if UnitClassBase("player") ~= "WARLOCK" then
    return
end

local state = Hekili.State
local floor = math.floor

-- The class kit and one spec a talent tree (ids the core's: Affliction 100091, Demonology 100092, Destruction 100093;
-- the client's one pseudo-spec, assumed 1490, only keys the legacy profile the core migrates). Icons: the DB2 talent
-- tabs'. Each spec's package is its wowsims.com pack (APLs/packs.lua).
local spec = Hekili:NewClass("WARLOCK", {
    specs = {
        {
            key = "affliction",
            name = L["Affliction"],
            tree = 1,
            icon = 136145,
            role = "attack",
            ranged = true,
            package = "Affliction (wowsims.com)",
        },
        {
            key = "demonology",
            name = L["Demonology"],
            tree = 2,
            icon = 136172,
            role = "attack",
            ranged = true,
            package = "Demonology (wowsims.com)",
            movement = true, -- the Demonology and Shadow Brand packs read toggle.movement: the move reaches Hellfire (R8)
        },
        {
            key = "destruction",
            name = L["Destruction"],
            tree = 3,
            icon = 136186,
            role = "attack",
            ranged = true,
            package = "Destruction (wowsims.com)",
            movement = true, -- the Destruction pack's Hellfire line reads toggle.movement (re-pin e5a9cd2a2d, R8)
        },
    },
})
if not spec then
    return
end

-- Rank IDs, lowest first (the DB2's), each rank's mana cost, cast time or duration.
local SHADOW_BOLT = { 686, 695, 705, 1088, 1106, 7641, 11659, 11660, 11661, 25307 }
local SHADOW_BOLT_COST = { 25, 40, 70, 110, 160, 210, 265, 315, 370, 380 }
local SHADOW_BOLT_CAST = { 1.7, 2.2, 2.8, 3, 3, 3, 3, 3, 3, 3 }
local IMMOLATE = { 348, 707, 1094, 2941, 11665, 11667, 11668, 25309 }
local IMMOLATE_COST = { 25, 45, 90, 155, 220, 295, 370, 380 }
local CORRUPTION = { 172, 6222, 6223, 7648, 11671, 11672, 25311 }
local CORRUPTION_COST = { 35, 55, 100, 160, 225, 290, 340 }
local CORRUPTION_DURATION = { 12, 15, 18, 18, 18, 18, 18 }
local BANE_OF_AGONY = { 980, 1014, 6217, 11711, 11712, 11713 }
local BANE_OF_AGONY_COST = { 25, 50, 90, 130, 170, 215 }
local CURSE_OF_THE_ELEMENTS = { 440892, 1311676, 1311677, 1311680 } -- Forever's own (class mask 0 in spell_skill)
local CURSE_OF_THE_ELEMENTS_COST = { 50, 100, 150, 200 }
local CURSE_OF_RECKLESSNESS = { 704, 7658, 7659, 11717 }
local CURSE_OF_RECKLESSNESS_COST = { 35, 60, 90, 115 }
local CURSE_OF_WEAKNESS = { 702, 1108, 6205, 7646, 11707, 11708 }
local CURSE_OF_WEAKNESS_COST = { 20, 35, 70, 95, 130, 175 }
local SIPHON_LIFE = { 18265, 18879, 18880, 18881 }
local SIPHON_LIFE_COST = { 150, 205, 285, 365 }
local DRAIN_LIFE = { 689, 699, 709, 7651, 11699, 11700 } -- the 403677-403689 family (15 s, SoD) is not Forever's
local DRAIN_LIFE_COST = { 55, 85, 135, 185, 240, 300 }
local DRAIN_SOUL = { 1120, 8288, 8289, 11675 }
local DRAIN_SOUL_COST = { 55, 125, 210, 290 }
local DEATH_COIL = { 6789, 17925, 17926 }
local DEATH_COIL_COST = { 435, 525, 600 }
local CONFLAGRATE = { 1293817, 1293818, 17962, 18930, 18931, 18932 }
local CONFLAGRATE_COST = { 100, 130, 165, 200, 230, 255 }
local SHADOWBURN = { 17877, 18867, 18868, 18869, 18870, 18871 }
local SHADOWBURN_COST = { 105, 130, 190, 245, 305, 365 }
local SEARING_PAIN = { 5676, 17919, 17920, 17921, 17922, 17923 }
local SEARING_PAIN_COST = { 45, 68, 91, 118, 141, 168 }
local INCINERATE = { 412758, 1293812, 1293813 }
local INCINERATE_COST = { 205, 265, 325 }
local SOUL_FIRE = { 6353, 17924 }
local SOUL_FIRE_COST = { 305, 335 }
local RAIN_OF_FIRE = { 5740, 6219, 11677, 11678 }
local RAIN_OF_FIRE_COST = { 295, 605, 885, 1185 }
local HELLFIRE = { 1949, 11683, 11684 }
local HELLFIRE_COST = { 645, 975, 1300 }
-- Life Tap: effect 0's points by rank and each rank's base level; +1 a level to ten above it (DB2 per_level 1,
-- MaxLevel = BaseLevel + 10; wowsims lifetap.go: base + Spirit of health, with Improved Life Tap scaling the mana).
local LIFE_TAP = { 1454, 1455, 1456, 11687, 11688, 11689 }
local LIFE_TAP_POINTS = { 20, 65, 130, 210, 300, 420 }
local LIFE_TAP_LEVEL = { 6, 16, 26, 36, 46, 56 }
local SHOOT = 5019
local ATTACK = { 6603 }

-- The talents' per-rank values (wowsims's curves; the DB2 carries the top rank's on rank 1): Cataclysm 3/6/10% off
-- the Destruction spells' cost (17778; DB2 mask: Shadow Bolt, Immolate, Rain of Fire, Soul Fire, Hellfire, Shadowburn,
-- Searing Pain, Conflagrate, Incinerate; wowsims's logs: 342 = 380 x 0.9 at 3/3).
local CATACLYSM = { 0.03, 0.06, 0.1 }

local SOUL_SHARD = 6265 -- the item (ItemSparse)

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

local function plain(value)
    if not Facade.issecretvalue(value) then
        return value
    end
end

local function pveInstance(instance)
    return instance == "none" or instance == "party" or instance == "scenario" or instance == "raid"
end

local function contextualInstance()
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    return pveInstance(instance) and instance ~= "raid" and plain(Facade.IsInRaid()) == false
end

local function hostileNPC(unit)
    return plain(Facade.UnitExists(unit)) == true
        and plain(Facade.UnitCanAttack("player", unit)) == true
        and plain(Facade.UnitIsPlayer(unit)) == false
        and plain(Facade.UnitIsDeadOrGhost(unit)) == false
end

local function targetEngaged(unit, victim)
    return plain(Facade.UnitAffectingCombat(unit)) == true
        and (
            type(plain(Facade.UnitThreatSituation("player", unit))) == "number"
            or plain(Facade.UnitIsUnit(victim, "player")) == true
            or plain(Facade.UnitIsUnit(victim, "pet")) == true
            or plain(Facade.UnitInParty(victim)) == true
        )
end

spec:RegisterStateExpr("warlock_pve_context", function()
    local _, instance = Facade.IsInInstance()
    return pveInstance(plain(instance)) and plain(Facade.UnitIsDeadOrGhost("player")) == false
end)

spec:RegisterStateExpr("warlock_pve_target", function()
    return state.warlock_pve_context and hostileNPC("target") and not target.is_dummy
end)

spec:RegisterStateExpr("warlock_outdoors", function()
    return plain(Facade.IsInInstance()) == false and plain(Facade.IsInRaid()) == false
end)

spec:RegisterStateExpr("warlock_contextual", function()
    return contextualInstance() and state.warlock_pve_target and (level < 60 or not (boss or target.is_boss))
end)

spec:RegisterStateExpr("warlock_short_pull", function()
    local classification = plain(Facade.UnitClassification("target"))
    return state.warlock_contextual
        and not (boss or target.is_boss)
        and (classification == "normal" or classification == "rare")
end)

spec:RegisterStateExpr("warlock_engaged", function()
    return state.warlock_pve_target and (state.warlock_outdoors or targetEngaged("target", "targettarget"))
end)

local plates, victims = {}, {}
for i = 1, 40 do
    local plate = "nameplate" .. i
    plates[i], victims[i] = plate, plate .. "target"
end

-- Rain of Fire's ground location stays under the player's control. Count only engaged enemies in its 30-yard reach.
local aoeCheckedAt, aoeCount
local function engagedInRainRange(unit, victim)
    if not hostileNPC(unit) or not targetEngaged(unit, victim) then
        return false
    end
    local _, upper = Facade.LibRangeCheck:GetRange(unit)
    upper = plain(upper)
    return type(upper) == "number" and upper <= 30
end

local function engagedRangedTargets(time)
    if aoeCheckedAt == time then
        return aoeCount
    end
    aoeCheckedAt, aoeCount = time, 0
    if not engagedInRainRange("target", "targettarget") then
        return 0
    end
    aoeCount = 1
    local first
    for i = 1, #plates do
        local unit = plates[i]
        if
            engagedInRainRange(unit, victims[i])
            and plain(Facade.UnitIsUnit(unit, "target")) == false
            and (not first or plain(Facade.UnitIsUnit(unit, first)) == false)
        then
            aoeCount = aoeCount + 1
            if first then
                break
            end
            first = unit
        end
    end
    return aoeCount
end

spec:RegisterStateExpr("warlock_aoe", function()
    return active_enemies >= 3 and state.warlock_pve_target and engagedRangedTargets(now) >= 3
end)

spec:RegisterStateExpr("warlock_cleave", function()
    return active_enemies >= 2 and state.warlock_pve_target and engagedRangedTargets(now) >= 2
end)

spec:RegisterStateExpr("warlock_pet_tanking", function()
    return plain(Facade.UnitIsUnit("targettarget", "pet")) == true and Facade.PetAlive() == true
end)

local function canPrepare(sim)
    if
        not sim.warlock_pve_context
        or sim.combat > 0
        or sim.buff.movement.up
        or plain(Facade.IsMounted()) ~= false
        or plain(Facade.UnitAffectingCombat("player")) ~= false
    then
        return false
    end
    local exists = plain(Facade.UnitExists("target"))
    return exists == false
        or (exists == true and plain(Facade.UnitIsPlayer("target")) == false and not sim.target.is_dummy)
end

spec:RegisterStateExpr("warlock_can_prepare", function()
    return contextualInstance() and canPrepare(state)
end)

-- Project health costs, shards and prep only inside the current recommendation.
spec:RegisterStateTable("warlock_forecast", {
    healthSpent = 0,
    summoned = false,
    funneled = false,
    shooting = false,
    attacking = false,
    shardsSpent = 0,
})

spec:RegisterHook("reset_preauras", function()
    local forecast = warlock_forecast
    forecast.healthSpent, forecast.summoned, forecast.funneled = 0, false, false
    forecast.shooting, forecast.attacking, forecast.shardsSpent = false, false, 0
end)

spec:RegisterStateExpr("warlock_pet_on_target", function()
    return Facade.PetAlive() == true
        and (plain(Facade.UnitIsUnit("pettarget", "target")) == true or state.warlock_pet_tanking)
end)

spec:RegisterStateExpr("warlock_can_summon", function()
    return state.warlock_can_prepare
        and not warlock_forecast.summoned
        and Facade.PetAlive() == false
        and buff.demonic_sacrifice.down
end)

local function knows(ids)
    return function()
        return knownRank(ids) > 0
    end
end

local function byRank(values, ids)
    return function()
        return values[knownRank(ids)] or values[1]
    end
end

local function lifeTapCost(playerLevel, spirit)
    local rank = math.max(knownRank(LIFE_TAP), 1)
    local learnedLevel = LIFE_TAP_LEVEL[rank]
    local levelGain = math.min(math.max(playerLevel - learnedLevel, 0), 10)
    return LIFE_TAP_POINTS[rank] + levelGain + spirit
end

local function readableHealthAfter(cost)
    local fraction = Facade.PlayerHealthFraction()
    if fraction then
        return fraction - (state.warlock_forecast.healthSpent + cost) / state.health.max
    end
end

spec:RegisterStateExpr("warlock_life_tap_safe", function()
    if warlock_forecast.funneled then
        return false
    end
    local _, spirit = stat("UnitStat", 5)
    local remaining = readableHealthAfter(lifeTapCost(level, spirit))
    return remaining ~= nil and remaining >= (combat > 0 and 0.55 or 0.40)
end)

spec:RegisterStateExpr("warlock_health_low", function()
    local fraction = Facade.PlayerHealthFraction()
    return fraction ~= nil and fraction > 0 and fraction <= 0.65
end)

local function spellInRange(ids, unit)
    local id = ids[knownRank(ids)]
    return id ~= nil and plain(Facade.C_Spell.IsSpellInRange(id, unit)) == true
end

spec:RegisterStateExpr("warlock_drain_life_in_range", function()
    return spellInRange(DRAIN_LIFE, "target")
end)

spec:RegisterStateExpr("warlock_shard_target", function()
    if not state.warlock_pve_target or not targetEngaged("target", "targettarget") then
        return false
    end
    local targetLevel = plain(Facade.UnitLevel("target"))
    return type(targetLevel) == "number"
        and targetLevel > 0
        and plain(Facade.UnitIsTrivial("target")) == false
        and spellInRange(DRAIN_SOUL, "target")
end)

spec:RegisterStateExpr("warlock_target_low", function()
    local fraction = Facade.TargetHealthUpperFraction()
    return fraction > 0 and fraction <= 0.25
end)

spec:RegisterStateExpr("warlock_shard_window", function()
    return state.warlock_shard_target and state.warlock_target_low
end)

spec:RegisterStateExpr("warlock_wanding", function()
    return ranged.wand
        and not buff.movement.up
        and (warlock_forecast.shooting or plain(Facade.C_Spell.IsCurrentSpell(SHOOT)) == true)
        and plain(Facade.C_Spell.IsSpellInRange(SHOOT, "target")) == true
end)

-- The same, less Cataclysm's cut (DB2 17778 effect 0: aura 108 misc 14, a cost percent).
local function cataclysmic(values, ids)
    return function()
        local r = talent.cataclysm.rank
        return (values[knownRank(ids)] or values[1]) * (1 - (CATACLYSM[min(r, 3)] or 0))
    end
end

-- Doomcaller's Attire (AQ, set 499, db.json setId; sim/warlock/item_sets.go): five pieces; the 3-piece 26116 (Immolate's
-- damage) and the 5-piece 26117 (Shadow Bolt -15% mana, a percent modifier added to Cataclysm's: DB2 effect 702131).
local DOOMCALLER = { 21334, 21335, 21336, 21337, 21338 }
spec:RegisterGear("doomcaller", unpack(DOOMCALLER))
spec:RegisterSetBonus("doomcaller_3pc", 26116)
spec:RegisterSetBonus("doomcaller_5pc", 26117)

-- Shadow Bolt's mana: Cataclysm's cut and the Doomcaller 5-piece's.
local function boltCost()
    return function()
        local cut = (CATACLYSM[min(talent.cataclysm.rank, 3)] or 0) + (set_bonus.doomcaller_5pc > 0 and 0.15 or 0)
        return (SHADOW_BOLT_COST[knownRank(SHADOW_BOLT)] or SHADOW_BOLT_COST[1]) * (1 - cut)
    end
end

-- A cast time less Bane's 0.1 s a rank (DB2 17788 effect 0: aura 107 misc 10 on Shadow Bolt, Immolate and Incinerate),
-- hasted. `base`: a number, or a table by rank of `ids`. The reads are arguments: a field function's caller passes its
-- own `talent` and `haste` (Hekili setfenv's only the field function itself, never a closure it calls).
local function banedTime(base, ids, bane, h)
    local b = ids and (base[knownRank(ids)] or base[1]) or base
    return (b - 0.1 * bane) * h
end
local function baned(base, ids)
    return function()
        return banedTime(base, ids, talent.bane.rank, haste)
    end
end

-- Each spell refuses while an interrupt has its school locked out (Hekili_Shared's locked_out_<school>, C10); in the
-- belief's `now` context the names are absent: never locked.
local function unlocked(school)
    if school == "fire" then
        return function()
            return not locked_out_fire, "fire locked out"
        end
    end
    return function()
        return not locked_out_shadow, "shadow locked out"
    end
end

local function remainingShards(forecast)
    local spent = forecast and forecast.shardsSpent or 0
    return math.max(0, GetItemCount(SOUL_SHARD) - spent)
end

local function spendShard(forecast)
    forecast.shardsSpent = (forecast.shardsSpent or 0) + 1
end

-- The simulator passes its state for forecast costs. The live belief checks only the bag count for its cost ladder.
local function sharded(fire, waived)
    return function(sim)
        if remainingShards(sim and sim.warlock_forecast) < 1 and not (waived and buff[waived].up) then
            return false, "no soul shard"
        end
        if fire then
            return not locked_out_fire, "fire locked out"
        end
        return not locked_out_shadow, "shadow locked out"
    end
end

-- The five-second rule (C3): spirit and mp5 regen per second, the declared starting point the out-of-combat read and
-- the in-combat calibration replace: wowsims's logs at 60 (re-pin e2842f0a78: the four Human builds on the preraid
-- gear, 1.52 a 0.1 s tick inside the rule, 5.333 outside it, Blessing of Wisdom's mp5 included; was the Orc builds'
-- 1.04 / 4.428, Affliction's still 1.12 / 4.433). UNMEASURED in game.
-- Fel Energy (the Voidwalker sacrifice, aura 18792, DB2 aura 21: 2 every 4000 ms; wowsims talents_demonology.go:168-185):
-- 2% of max mana every 4 s while it is up, the tick times counted from its application.
-- Soul Harvest (437032, 2 ranks; its buff 1242853, 10 s: aura 110 regen +100% and aura 134 100% while casting, both
-- scaled 50/100% by rank, wowsims talents_affliction.go applySoulHarvest): the spirit part x (1 + 0.5 x rank) and that
-- share while casting; the belief opens it at our kill (the "kill" reaction, below).
spec:RegisterResource(
    Enum.PowerType.Mana,
    {
        soul_harvest = {
            aura = "soul_harvest",
            spirit = function()
                return 1 + 0.5 * talent.soul_harvest.rank
            end,
            share = function()
                return 0.5 * talent.soul_harvest.rank
            end,
        },
        fel_energy = {
            aura = "fel_energy",

            last = function()
                local app = state.buff.fel_energy.applied
                return app + 4 * floor((state.query_time - app) / 4)
            end,

            interval = 4,
            value = function()
                local max = mana and mana.max
                return type(max) == "number" and 0.02 * max or 0 -- inert before the first read
            end,
        },
    },
    nil,
    {
        fsr = { spirit = 38.13, mp5 = 15.2 },
        base = 1373, -- a fraction cost is of base mana (wowsims's ExtraClassBaseStats, level 60; Spec.lua)
    }
)

-- Soul Shards stay live in the bags. The forecast only spends confirmed shards and never assumes a refund or gain.
local function shardCount()
    return remainingShards(warlock_forecast)
end
spec:RegisterStateExpr("soul_shards", shardCount)
spec:RegisterStateExpr("warlock_shard_count", shardCount)

-- The Curses and the Banes: one of each per Warlock per target (wowsims warlock.go deactivateOtherCurses/Banes).
local CURSES =
    { "curse_of_the_elements", "curse_of_recklessness", "curse_of_weakness", "curse_of_tongues", "curse_of_exhaustion" }
local BANES = { "bane_of_agony", "bane_of_doom" }

-- The Demonic Sacrifice effect each demon leaves (the demons' creature IDs: the summons' effect 0, DB2).
local SACRIFICE = {
    imp = "burning_shadow",
    voidwalker = "fel_energy",
    succubus = "touch_of_fire",
    incubus = "touch_of_fire",
    felhunter = "fel_stamina",
}
local SACRIFICES = { "burning_shadow", "fel_stamina", "touch_of_fire", "fel_energy" }
local DEMONS = { "imp", "voidwalker", "succubus", "incubus", "felhunter" }

-- The demon out in the simulation's `pet` (nil: none, or the belief's `now` context, which has no `pet`).
local function demonOut(p)
    for i = 1, p and #DEMONS or 0 do
        if p[DEMONS[i]].up then
            return DEMONS[i]
        end
    end
end

spec:RegisterPets({
    imp = { id = 416, spell = "summon_imp", duration = 3600 },
    voidwalker = { id = 1860, spell = "summon_voidwalker", duration = 3600 },
    succubus = { id = 1863, spell = "summon_succubus", duration = 3600 },
    incubus = { id = 185317, spell = "summon_incubus", duration = 3600 },
    felhunter = { id = 417, spell = "summon_felhunter", duration = 3600 },
})

local function corruptionDuration()
    return CORRUPTION_DURATION[knownRank(CORRUPTION)] or 18
end

spec:RegisterAuras({
    -- The target's (unreadable in combat), modelled from our casts.
    corruption = {
        id = 172,
        copy = rest(CORRUPTION),
        duration = corruptionDuration,
        max_stack = 1,
    },
    immolate = { id = 348, copy = rest(IMMOLATE), duration = 15, max_stack = 1 },
    bane_of_agony = { id = 980, copy = rest(BANE_OF_AGONY), duration = 24, max_stack = 1 },
    bane_of_doom = { id = 603, duration = 60, max_stack = 1 },
    curse_of_the_elements = { id = 440892, copy = rest(CURSE_OF_THE_ELEMENTS), duration = 300, max_stack = 1 },
    curse_of_recklessness = { id = 704, copy = rest(CURSE_OF_RECKLESSNESS), duration = 120, max_stack = 1 },
    curse_of_weakness = { id = 702, copy = rest(CURSE_OF_WEAKNESS), duration = 120, max_stack = 1 },
    siphon_life = { id = 18265, copy = rest(SIPHON_LIFE), duration = 30, max_stack = 1 },
    wrack = { id = 1316697, duration = 6, max_stack = 1 }, -- the channel's debuff: +10% from Corruption and Agony
    -- Searing Pain's brand (Demonic Brand 1293695): 10 s, 2 charges a rank (wowsims's curve; its logs land 6 at 3/3).
    -- shortcut: the demon's attacks spend the charges (unseen); the model keeps them all for the 10 s.
    demonic_brand = { id = 1293696, duration = 10, max_stack = 6 },
    -- Improved Shadow Bolt's (a Shadow Bolt crit's: the belief's own crit, Shadow Bolt's `onCrit`).
    shadow_vulnerability = { id = 17794, duration = 12, max_stack = 1 },

    -- Bane of Havoc's (1225228, 300 s; wowsims bane_of_havoc.go): one target at a time, never the main one (the pack's
    -- other_target=1 line, option D).
    bane_of_havoc = { id = 1225228, copy = { 1324473 }, duration = 300, max_stack = 1 }, -- 1324473: the client's buff

    -- The player's. The procs (their rolls unseen; the player aura walk reads them where plain, in combat the glow of
    -- the spell they light: `overlay`, needs in-game check): Nightfall's next Shadow Bolt instant; Decimation's
    -- faster Soul Fire with no shard (below 35% target health).
    shadow_trance = { id = 17941, duration = 10, max_stack = 1, overlay = 686 },
    decimation = { id = 440873, duration = 10, max_stack = 1, overlay = 6353 },
    amplify_curse = { id = 18288, duration = 30, max_stack = 1 },
    -- The Doomcaller's Attire bonuses' hidden auras: tracked so set_bonus.doomcaller_* reads them.
    doomcaller_3pc = { id = 26116, duration = 3600, max_stack = 1 },
    doomcaller_5pc = { id = 26117, duration = 3600, max_stack = 1 },
    -- The weapon enchant 8217's proc (wowsims enchants.go revelationBuffs; each class has its own id): the next
    -- Shadow Bolt's crit chance +100%, one charge. A random proc: read, never predicted.
    revelation = { id = 1323392, duration = 15, max_stack = 1 },
    -- Shadow and Flame's (Conflagrate: the Shadow buff, Shadowburn: the Fire buff; wowsims talents_destruction.go; its
    -- names.json calls the first plain `shadow`).
    shadow_and_flame_shadow = { id = 1293816, duration = 20, max_stack = 1 },
    shadow_and_flame_fire = { id = 426311, duration = 20, max_stack = 1 },
    -- Soul Harvest's kill buff (10 s, regen +100% at 2/2): opened at our kill (the "kill" reaction, below).
    soul_harvest = { id = 1242853, copy = { 437032 }, duration = 10, max_stack = 1 }, -- 437032: the talent's, which the Cooldown Manager links
    -- Demonology and armor auras are read from the player aura walk where plain.
    fel_domination = { id = 18708, duration = 15, max_stack = 1 },
    soul_link = { id = 19028, copy = 25228, duration = 3600, max_stack = 1 },
    demonic_knowledge = { id = 412732, duration = 3600, max_stack = 1 },
    master_demonologist = { id = 23785, duration = 3600, max_stack = 1 }, -- one id for the four demons' effects
    demon_armor = { id = 11735, copy = { 706, 1086, 11733, 11734 }, duration = 1800, max_stack = 1 },
    blood_pact = { id = 11767, duration = 3600, max_stack = 1 },
    -- The channels' own auras (the kit models the channels: `channeled`).
    hellfire_channel = { id = 11684, duration = 15, max_stack = 1 },
    rain_of_fire_channel = { id = 11678, duration = 8, max_stack = 1 },
    drain_soul_channel = { id = 11675, duration = 15, max_stack = 1 },
    drain_life_channel = { id = 11700, duration = 5, max_stack = 1 },
    shoot = { id = SHOOT, duration = 1.2, max_stack = 1 },
    -- Demonic Sacrifice's effects (2 h; wowsims: until a summon cancels it).
    burning_shadow = { id = 18789, duration = 7200, max_stack = 1 },
    fel_stamina = { id = 18790, duration = 7200, max_stack = 1 },
    touch_of_fire = { id = 18791, duration = 7200, max_stack = 1 },
    fel_energy = { id = 18792, duration = 7200, max_stack = 1 },
    demonic_sacrifice = {
        alias = SACRIFICES,
        aliasMode = "first",
        aliasType = "buff",
        duration = 7200,
    },
})

-- The coverage lane's auras, each on the ID the Cooldown Manager links (CooldownViewer.lua build); durations from the
-- pin's spell rows at the top rank. The target's (Fear, Howl of Terror, Banish, Death Coil's horror, Subjugate Demon,
-- Aftermath's daze, the two curses) are never applied here but by our own casts below; the player's are the wards, armor,
-- Demon Skin and Detect Invisibility.
spec:RegisterAuras({
    fear = { id = 1324448, copy = { 1324451, 1324453 }, duration = 20, max_stack = 1 }, -- the client's ranks
    howl_of_terror = { id = 5484, copy = { 17928 }, duration = 15, max_stack = 1 },
    banish = { id = 1324462, copy = { 1324463 }, duration = 30, max_stack = 1 },
    death_coil = { id = 1324459, duration = 3, max_stack = 1 }, -- the horror
    subjugate_demon = { id = 1324468, duration = 300, max_stack = 1 },
    aftermath = { id = 18118, copy = { 18119 }, duration = 5, max_stack = 1 }, -- Conflagrate's daze
    curse_of_tongues = { id = 1714, copy = { 11719 }, duration = 30, max_stack = 1 },
    curse_of_exhaustion = { id = 18223, duration = 12, max_stack = 1 },
    shadow_ward = { id = 6229, copy = { 11739, 11740, 28610 }, duration = 30, max_stack = 1 },
    demon_skin = { id = 687, copy = { 696 }, duration = 1800, max_stack = 1 },
    detect_invisibility = { id = 132, copy = { 2970, 11743 }, duration = 600, max_stack = 1 },
})

-- A DoT's or Curse's `now` and `handler`: its debuff on the target, the others of its group (`group`: a Curse's or a
-- Bane's) removed, Amplify Curse spent (`amplified`: Bane of Agony and Curse of Weakness, DB2 18288 effect 0's mask;
-- wowsims: spent at the cast). `duration`: the debuff's when its aura's is a function (a `now` must pass it: the belief
-- writes nothing for a function duration, Families/Now.lua).
local function lands(key, group, amplified, duration)
    return function()
        for i = 1, group and #group or 0 do
            if group[i] ~= key then
                removeDebuff("target", group[i])
            end
        end
        applyDebuff("target", key, duration and duration())
        if amplified then
            removeBuff("amplify_curse")
        end
    end
end

-- Shadow Bolt's: Shadow Trance spent by an instant cast (wowsims talents_affliction.go), and Revelation's charge by
-- any cast (wowsims enchants.go: the next cast the crit modifier reaches).
-- In the belief `instant` is true only for a cast that started none (Families/Now.lua); the sim's cast time is 0 while
-- the buff is up, so its handler spends on the buff alone.
-- `sim`: the simulation's handler, which also reads the target's health for Decimation: a landed Shadow Bolt (or Searing
-- Pain) at a target under 35% (wowsims talents_demonology.go), and applies Shadow Vulnerability for Revelation's
-- guaranteed crit. The belief's `now` has no target to read (its health is secret on Forever: the glow read of
-- `decimation` carries it in game; the crit's own `onCrit` carries the vulnerability).
local function bolted(sim)
    if sim then
        return function()
            if buff.shadow_trance.up then
                removeBuff("shadow_trance")
            end
            if buff.revelation.up then
                removeBuff("revelation")
                if talent.improved_shadow_bolt.rank > 0 then
                    applyDebuff("target", "shadow_vulnerability")
                end
            end
            if talent.decimation.rank > 0 and target.health.pct < 35 then
                applyBuff("decimation")
            end
        end
    end
    return function()
        if instant and buff.shadow_trance.up then
            removeBuff("shadow_trance")
        end
        if buff.revelation.up then
            removeBuff("revelation")
        end
    end
end

-- Shadow Bolt's `onCrit` (the belief's own crit, Families/Now.lua): Improved Shadow Bolt's Shadow Vulnerability on the
-- target (DB2 17793; wowsims's logs: 17794 for 12 s after a crit), the only way the belief sees it.
local function vulnerable()
    return function()
        if talent.improved_shadow_bolt.rank > 0 then
            applyDebuff("target", "shadow_vulnerability")
        end
    end
end

-- Searing Pain's: Demonic Brand's charges on the target, 2 a rank.
-- `sim`: also Decimation at a target under 35%, as Shadow Bolt's (`bolted`).
local function branded(sim)
    if sim then
        return function()
            local r = talent.demonic_brand.rank
            if r > 0 then
                applyDebuff("target", "demonic_brand", nil, 2 * min(r, 3))
            end
            if talent.decimation.rank > 0 and target.health.pct < 35 then
                applyBuff("decimation")
            end
        end
    end
    return function()
        local r = talent.demonic_brand.rank
        if r > 0 then
            applyDebuff("target", "demonic_brand", nil, 2 * min(r, 3))
        end
    end
end

-- Conflagrate's: our Immolate consumed, unless Shadow and Flame keeps it (20% a rank, wowsims's curve); and with the
-- talent its Shadow damage buff.
-- shortcut: the roll is unseen; below 5/5 the Immolate is taken as consumed (an early recast at worst).
local function conflagrated()
    return function()
        if talent.shadow_and_flame.rank < 5 then
            removeDebuff("target", "immolate")
        end
        if talent.shadow_and_flame.rank > 0 then
            applyBuff("shadow_and_flame_shadow")
        end
    end
end

-- Shadowburn's: with Shadow and Flame its Fire damage buff (the shard refund is unmodelled).
local function burned(predicted)
    return function()
        if predicted then
            spendShard(warlock_forecast)
        end
        if talent.shadow_and_flame.rank > 0 then
            applyBuff("shadow_and_flame_fire")
        end
    end
end

-- Life Tap's simulated health cost matters for the next Tap in the same prediction window.
local function tapped(predicted)
    return function()
        local _, spirit = stat("UnitStat", 5)
        local amount = lifeTapCost(level, spirit)
        if predicted then
            warlock_forecast.healthSpent = (warlock_forecast.healthSpent or 0) + amount
        end
        gain(amount * (1 + 0.1 * talent.improved_life_tap.rank), "mana")
    end
end

-- A summon's: the demon (the belief models the pet unit up until its first observation; in the simulation the demon
-- out is dismissed first, the same demon included: wowsims summon.go), and Demonic Sacrifice's effect cancelled (any
-- demon's without Demonic Pact, the sacrificed demon's own with it).
local function summons(key, predicted, shard)
    return function()
        removeBuff("fel_domination") -- the next summon spends it (wowsims talents_demonology.go applyFelDomination)
        local out = demonOut(pet) -- nil in the belief's `now` context (no `pet`)
        if out then
            dismissPet(out)
        end
        summonPet(key)
        if predicted then
            warlock_forecast.summoned = true
            if shard then
                spendShard(warlock_forecast)
            end
        end
        local pact = talent.demonic_pact.enabled
        for i = 1, #SACRIFICES do
            if not pact or SACRIFICES[i] == SACRIFICE[key] then
                removeBuff(SACRIFICES[i])
            end
        end
    end
end

-- A summon: 10 s, -2 s and -20% cost a rank of Master Summoner (wowsims's curve; DB2 18709 mask: the five summons),
-- and Fel Domination's -5.5 s and -50% while its buff is up (DB2 18708 effects 0, 1, the same mask); unhasted; `cost` a fraction of base mana (PowerCostPct), `shard` its Soul Shard.
local function summon(key, id, cost, shard)
    return {
        id = id,
        cast = function()
            return max(0, 10 - 2 * talent.master_summoner.rank - (buff.fel_domination.up and 5.5 or 0))
        end,
        cooldown = 0,
        gcd = "spell",

        -- Fel Domination's -50% adds to Master Summoner's -20% a rank (both percent cost modifiers on the summons)
        spend = function()
            return cost * (1 - 0.2 * talent.master_summoner.rank - (buff.fel_domination.up and 0.5 or 0))
        end,
        spendType = "mana",
        spendBase = true, -- the 1 (100%) a fraction too

        startsCombat = false,
        known = knows({ id }),
        usable = shard and sharded() or unlocked("shadow"),

        now = summons(key),
        handler = summons(key, true, shard),
    }
end

-- Demonic Sacrifice's: the demon out dismissed, every effect ended, the sacrificed demon's own up (wowsims
-- talents_demonology.go). The belief's `now` has no demon key: its dismissal is of the pet unit (any key) and the new
-- effect is the player aura walk's.
local function sacrifices()
    return function()
        local key = demonOut(pet)
        for i = 1, #SACRIFICES do
            removeBuff(SACRIFICES[i])
        end
        if key then
            applyBuff(SACRIFICE[key])
        end
        dismissPet(key or "demon")
    end
end

-- As with the Priest's Shoot, one wand-speed channel represents the delayed first shot.
local function wandDuration(speed)
    return speed and speed > 0 and speed or 1.2
end

local function wandSpeed()
    return wandDuration(stat("UnitRangedDamage"))
end

local function shot(predicted)
    return function()
        applyDebuff("target", "shoot", wandDuration(stat("UnitRangedDamage")))
        if predicted then
            warlock_forecast.shooting = true
        end
    end
end

spec:RegisterAbilities({
    shadow_bolt = {
        id = 686,
        expects = "travel",
        velocity = 20,
        school = "shadow",
        copy = rest(SHADOW_BOLT),
        cast = function()
            if buff.shadow_trance.up then
                return 0 -- DB2 17941: -100% cast time on Shadow Bolt
            end
            return banedTime(SHADOW_BOLT_CAST, SHADOW_BOLT, talent.bane.rank, haste)
        end,
        cooldown = 0,
        gcd = "spell",

        spend = boltCost(),
        spendType = "mana",

        startsCombat = true,
        known = knows(SHADOW_BOLT),
        usable = unlocked("shadow"),

        now = bolted(false),
        handler = bolted(true),
        onCrit = vulnerable(),
    },

    immolate = {
        id = 348,
        copy = rest(IMMOLATE),
        cast = baned(2),
        cooldown = 0,
        gcd = "spell",

        spend = cataclysmic(IMMOLATE_COST, IMMOLATE),
        spendType = "mana",

        startsCombat = true,
        known = knows(IMMOLATE),
        usable = unlocked("fire"),
        missable = true,

        now = lands("immolate"),
        handler = lands("immolate"),
    },

    -- 2 s, -0.4 s a rank of Improved Corruption (wowsims's curve; DB2 17810 mask: Corruption); wowsims's logs: 0.8 s at
    -- 3/5, 0.4 s at 4/5.
    corruption = {
        id = 172,
        copy = rest(CORRUPTION),
        cast = function()
            return max(0, 2 - 0.4 * talent.improved_corruption.rank) * haste
        end,
        debuffApplication = "corruption",
        cooldown = 0,
        gcd = "spell",

        spend = byRank(CORRUPTION_COST, CORRUPTION),
        spendType = "mana",

        startsCombat = true,
        known = knows(CORRUPTION),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("corruption", nil, nil, corruptionDuration),
        handler = lands("corruption", nil, nil, corruptionDuration),
    },

    bane_of_agony = {
        id = 980,
        debuffApplication = "bane_of_agony",
        copy = rest(BANE_OF_AGONY),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(BANE_OF_AGONY_COST, BANE_OF_AGONY),
        spendType = "mana",

        startsCombat = true,
        known = knows(BANE_OF_AGONY),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("bane_of_agony", BANES, true),
        handler = lands("bane_of_agony", BANES, true),
    },

    -- One hit at the end of its minute; 60 s cooldown (DB2 RecoveryTime).
    bane_of_doom = {
        id = 603,
        debuffApplication = "bane_of_doom",
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        spend = 300,
        spendType = "mana",

        startsCombat = true,
        known = knows({ 603 }),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("bane_of_doom", BANES),
        handler = lands("bane_of_doom", BANES),
    },

    -- Bane of Havoc (the Destruction talent's spell; wowsims bane_of_havoc.go): 5% of base mana, a Bane (it takes our
    -- other Bane off its target). The pack casts it on another target only (other_target=1: Recommend Target Swaps).
    -- shortcut: Agony and Doom do not take Havoc off their target here (wowsims's deactivateOtherBanes does); add
    -- bane_of_havoc to BANES if a pack ever casts a Bane on the Havoc target.
    bane_of_havoc = {
        id = 1225228,
        expects = "debuff", -- a dummy aura, no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 0,
        gcd = "off", -- wowsims: no SpellCooldowns row, so off the GCD (its TODO; ledger: confirm in game)

        spend = 0.05,
        spendType = "mana",

        startsCombat = true,
        known = knows({ 1225228 }),
        missable = true,

        now = lands("bane_of_havoc", BANES),
        handler = lands("bane_of_havoc", BANES),
    },

    curse_of_the_elements = {
        id = 440892,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(CURSE_OF_THE_ELEMENTS),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(CURSE_OF_THE_ELEMENTS_COST, CURSE_OF_THE_ELEMENTS),
        spendType = "mana",

        startsCombat = true,
        known = knows(CURSE_OF_THE_ELEMENTS),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("curse_of_the_elements", CURSES),
        handler = lands("curse_of_the_elements", CURSES),
    },

    curse_of_recklessness = {
        id = 704,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(CURSE_OF_RECKLESSNESS),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(CURSE_OF_RECKLESSNESS_COST, CURSE_OF_RECKLESSNESS),
        spendType = "mana",

        startsCombat = true,
        known = knows(CURSE_OF_RECKLESSNESS),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("curse_of_recklessness", CURSES),
        handler = lands("curse_of_recklessness", CURSES),
    },

    curse_of_weakness = {
        id = 702,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(CURSE_OF_WEAKNESS),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(CURSE_OF_WEAKNESS_COST, CURSE_OF_WEAKNESS),
        spendType = "mana",

        startsCombat = true,
        known = knows(CURSE_OF_WEAKNESS),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("curse_of_weakness", CURSES, true),
        handler = lands("curse_of_weakness", CURSES, true),
    },

    siphon_life = {
        id = 18265,
        debuffApplication = "siphon_life",
        copy = rest(SIPHON_LIFE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(SIPHON_LIFE_COST, SIPHON_LIFE),
        spendType = "mana",

        startsCombat = true,
        known = knows(SIPHON_LIFE),
        usable = unlocked("shadow"),
        missable = true,

        now = lands("siphon_life"),
        handler = lands("siphon_life"),
    },

    -- The channels: unhasted (wowsims: the rows carry no haste attribute); a channel's `handler` never runs in Hekili's
    -- simulation (`start`).
    drain_life = {
        id = 689,
        copy = rest(DRAIN_LIFE),
        cast = 5,
        channeled = true,
        tick_time = 1,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(DRAIN_LIFE_COST, DRAIN_LIFE),
        spendType = "mana",

        startsCombat = true,
        known = knows(DRAIN_LIFE),
        usable = unlocked("shadow"),
    },

    drain_soul = {
        id = 1120,
        copy = rest(DRAIN_SOUL),
        cast = 15,
        channeled = true,
        tick_time = 3,
        cooldown = 0,
        gcd = "spell",

        spend = byRank(DRAIN_SOUL_COST, DRAIN_SOUL),
        spendType = "mana",

        startsCombat = true,
        known = knows(DRAIN_SOUL),
        usable = unlocked("shadow"),
    },

    wrack = {
        id = 1316697,
        cast = 6,
        channeled = true,
        tick_time = 1,
        cooldown = 0,
        gcd = "spell",

        spend = 200,
        spendType = "mana",

        startsCombat = true,
        known = knows({ 1316697 }),
        usable = unlocked("shadow"),

        now = lands("wrack"),
        start = lands("wrack"),
    },

    rain_of_fire = {
        id = 5740,
        copy = rest(RAIN_OF_FIRE),
        cast = 8,
        channeled = true,
        tick_time = 2,
        cooldown = 0,
        gcd = "spell",

        spend = cataclysmic(RAIN_OF_FIRE_COST, RAIN_OF_FIRE),
        spendType = "mana",

        startsCombat = true,
        known = knows(RAIN_OF_FIRE),
        usable = unlocked("fire"),
    },

    hellfire = {
        id = 1949,
        copy = rest(HELLFIRE),
        cast = 15,
        channeled = true,
        tick_time = 1,
        cooldown = 0,
        gcd = "spell",

        spend = cataclysmic(HELLFIRE_COST, HELLFIRE),
        spendType = "mana",

        startsCombat = true,
        known = knows(HELLFIRE),
        usable = unlocked("fire"),
    },

    -- 120 s category cooldown.
    death_coil = {
        id = 6789,
        expects = "travel",
        velocity = 24,
        school = "shadow",
        copy = rest(DEATH_COIL),
        cast = 0,
        cooldown = 120,
        gcd = "spell",

        spend = byRank(DEATH_COIL_COST, DEATH_COIL),
        spendType = "mana",

        startsCombat = true,
        known = knows(DEATH_COIL),
        usable = unlocked("shadow"),
    },

    -- Our Immolate on the target is its condition (wowsims conflagrate.go); 10 s category cooldown.
    conflagrate = {
        id = 1293817,
        copy = rest(CONFLAGRATE),
        cast = 0,
        cooldown = 10,
        gcd = "spell",

        spend = cataclysmic(CONFLAGRATE_COST, CONFLAGRATE),
        spendType = "mana",

        startsCombat = true,
        known = knows(CONFLAGRATE),
        usable = function()
            if not debuff.immolate.up then
                return false, "no immolate"
            end
            return not locked_out_fire, "fire locked out"
        end,

        now = conflagrated(),
        handler = conflagrated(),
    },

    -- A Soul Shard; 15 s category cooldown.
    shadowburn = {
        id = 17877,
        copy = rest(SHADOWBURN),
        cast = 0,
        cooldown = 15,
        gcd = "spell",

        spend = cataclysmic(SHADOWBURN_COST, SHADOWBURN),
        spendType = "mana",

        startsCombat = true,
        known = knows(SHADOWBURN),
        usable = sharded(),

        now = burned(),
        handler = burned(true),
    },

    searing_pain = {
        id = 5676,
        copy = rest(SEARING_PAIN),
        cast = function()
            return 1.5 * haste
        end,
        cooldown = 0,
        gcd = "spell",

        spend = cataclysmic(SEARING_PAIN_COST, SEARING_PAIN),
        spendType = "mana",

        startsCombat = true,
        known = knows(SEARING_PAIN),
        usable = unlocked("fire"),
        missable = "demonic_brand",

        now = branded(false),
        handler = branded(true),
    },

    incinerate = {
        id = 412758,
        expects = "travel",
        velocity = 20,
        school = "fire",
        copy = rest(INCINERATE),
        cast = baned(2.5),
        cooldown = 0,
        gcd = "spell",

        spend = cataclysmic(INCINERATE_COST, INCINERATE),
        spendType = "mana",

        startsCombat = true,
        known = knows(INCINERATE),
        usable = unlocked("fire"),
    },

    -- 6 s, -0.4 s a rank of Bane (DB2 17788 effect 1), then Decimation's -20% a rank (440873 effect 0 at the talent's
    -- rank: wowsims's logs 2.4 s = (6 - 2) x 0.6 at 5/5 and 2/2); 60 s, -45% a rank of Decimation (440870 effect 1); a
    -- Soul Shard, none under Decimation.
    soul_fire = {
        id = 6353,
        expects = "travel",
        velocity = 24,
        school = "fire",
        copy = rest(SOUL_FIRE),
        cast = function()
            local c = 6 - 0.4 * talent.bane.rank
            if buff.decimation.up then
                c = c * (1 - 0.2 * talent.decimation.rank)
            end
            return c * haste
        end,
        cooldown = function()
            return 60 * (1 - 0.45 * talent.decimation.rank)
        end,
        gcd = "spell",

        spend = cataclysmic(SOUL_FIRE_COST, SOUL_FIRE),
        spendType = "mana",

        startsCombat = true,
        known = knows(SOUL_FIRE),
        usable = sharded(true, "decimation"),

        handler = function()
            local proc = buff.decimation
            local castStart = buff.casting.applied
            local waived
            if castStart > 0 then
                waived = proc.applied > 0 and proc.applied <= castStart and proc.expires > castStart
            else
                waived = proc.up
            end
            if not waived then
                spendShard(warlock_forecast)
            end
        end,
    },

    life_tap = {
        id = 1454,
        copy = rest(LIFE_TAP),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        startsCombat = false,
        known = knows(LIFE_TAP),
        usable = unlocked("shadow"),

        now = tapped(),
        handler = tapped(true),
    },

    auto_attack = {
        id = ATTACK[1],
        cast = 0,
        cooldown = 0,
        gcd = "off",
        startsCombat = true,
        known = knows(ATTACK),
        usable = function()
            if
                not state.warlock_contextual
                or not state.warlock_engaged
                or ranged.wand
                or state.main_hand.size == 0
                or buff.casting.up
                or warlock_forecast.attacking
                or plain(Facade.C_Spell.IsCurrentSpell(ATTACK[1])) ~= false
            then
                return false, "requires an equipped melee weapon and autoattack off"
            end
            local inRange = plain(Facade.C_Spell.IsSpellInRange(ATTACK[1], "target"))
            return inRange == true or (inRange == nil and target.within5 and not target.outside5),
                "requires confirmed melee range"
        end,
        handler = function()
            warlock_forecast.attacking = true
        end,
    },

    shoot = {
        id = SHOOT,
        expects = "travel",
        velocity = 20,
        school = "physical",
        cast = wandSpeed,
        channeled = true,
        tick_time = wandSpeed,
        cooldown = 0,
        gcd = "off",

        startsCombat = true,
        known = knows({ SHOOT }),
        usable = function()
            if not ranged.wand then
                return false, "requires equipped wand"
            end
            if
                buff.movement.up
                or warlock_forecast.shooting
                or plain(Facade.C_Spell.IsCurrentSpell(SHOOT)) ~= false
            then
                return false, "cannot start wand shooting"
            end
            return plain(Facade.C_Spell.IsSpellUsable(SHOOT)) == true and plain(
                Facade.C_Spell.IsSpellInRange(SHOOT, "target")
            ) == true,
                "shoot unavailable or target range unknown"
        end,

        now = shot(),
        start = shot(true),
    },

    -- Off the GCD; 180 s.
    amplify_curse = {
        id = 18288,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        startsCombat = false,
        toggle = "cooldowns",
        known = knows({ 18288 }),

        now = function()
            applyBuff("amplify_curse")
        end,
        handler = function()
            applyBuff("amplify_curse")
        end,
    },

    summon_imp = summon("imp", 688, 0.8),
    summon_voidwalker = summon("voidwalker", 697, 1, true),
    summon_succubus = summon("succubus", 712, 1, true),
    summon_incubus = summon("incubus", 713, 1, true),
    summon_felhunter = summon("felhunter", 691, 1, true),

    -- The talent's (18788): no cast time, cost, cooldown or GCD row (DB2); needs a demon out.
    demonic_sacrifice = {
        id = 18788,
        cast = 0,
        cooldown = 0,
        gcd = "off",

        startsCombat = false,
        known = knows({ 18788 }),
        usable = function()
            local p = pet -- the simulation's; the belief's `now` context has none (the client's answer decides)
            if p and not demonOut(p) then
                return false, "no demon"
            end
            return true
        end,

        now = sacrifices(),
        handler = sacrifices(),
    },
})

-- The kit's utility casts. Ranks, costs, and cooldowns come from the
-- pin's spell rows; `CostPct` ones as fractions of base mana.
do
    local FEAR = { 5782, 6213, 6215 }
    local HOWL_OF_TERROR = { 5484, 17928 }
    local HOWL_OF_TERROR_COST = { 150, 200 }
    local BANISH = { 710, 18647 }
    local BANISH_COST = { 100, 200 }
    local SUBJUGATE_DEMON = { 1098, 11725, 11726 }
    local SUBJUGATE_DEMON_COST = { 300, 500, 700 }
    local HEALTH_FUNNEL = { 755, 3698, 3699, 3700, 11693, 11694, 11695 }
    -- The complete ten-second channel's health cost, with fractional ticks rounded up.
    -- Forever spell data: https://db.icy-veins.com/wow-forever/spells/11695 (rank 7).
    local HEALTH_FUNNEL_COST = { 71, 125, 194, 299, 395, 532, 699 }
    local DRAIN_MANA = { 5138, 6226, 11703, 11704 }
    local DRAIN_MANA_COST = { 95, 155, 225, 310 }
    local SHADOW_WARD = { 6229, 11739, 11740, 28610 }
    local SHADOW_WARD_COST = { 135, 195, 255, 320 }
    local DEMON_SKIN = { 687, 696 }
    local DEMON_SKIN_COST = { 50, 120 }
    local DEMON_ARMOR = { 706, 1086, 11733, 11734, 11735 }
    local DEMON_ARMOR_COST = { 275, 520, 800, 1150, 1580 }
    local DETECT_INVISIBILITY = { 132, 2970, 11743 }
    local DETECT_INVISIBILITY_COST = { 50, 90, 140 }
    local CURSE_OF_TONGUES = { 1714, 11719 }
    local CURSE_OF_TONGUES_COST = { 80, 110 }

    spec:RegisterStateExpr("warlock_funnel_safe", function()
        if not canPrepare(state) or buff.casting.up or warlock_forecast.funneled or Facade.PetAlive() ~= true then
            return false
        end
        local rank = knownRank(HEALTH_FUNNEL)
        if rank == 0 then
            return false
        end
        local petHealth = Facade.PetHealthFraction()
        local playerHealth = readableHealthAfter(0)
        return petHealth ~= nil
            and petHealth > 0
            and petHealth <= 0.55
            and playerHealth ~= nil
            and playerHealth >= 0.80
            and playerHealth - HEALTH_FUNNEL_COST[rank] / health.max >= 0.60
            and plain(Facade.C_Spell.IsSpellInRange(HEALTH_FUNNEL[rank], "pet")) == true
    end)

    -- A buff on ourselves; a demon armor ends the other armor (one at a time).
    local function armored(aura)
        return function()
            removeBuff(aura == "demon_armor" and "demon_skin" or "demon_armor")
            applyBuff(aura)
        end
    end
    local function buffed(aura)
        return function()
            applyBuff(aura)
        end
    end
    -- A debuff on the target (Fear, Howl of Terror, Banish, Subjugate Demon).
    local function debuffed(aura)
        return function()
            applyDebuff("target", aura)
        end
    end

    spec:RegisterAbilities({
        -- 15% of base mana, 1.5 s (the pin's rows; Forever's own aura ids are the client's).
        fear = {
            id = 5782,
            school = "shadow",
            copy = rest(FEAR),
            cast = function()
                return 1.5 * haste
            end,
            cooldown = 0,
            gcd = "spell",

            spend = 0.15,
            spendType = "mana",

            startsCombat = true,
            known = knows(FEAR),
            usable = unlocked("shadow"),

            now = debuffed("fear"),
            handler = debuffed("fear"),
        },

        -- 2 s cast, 40 s category cooldown.
        howl_of_terror = {
            id = 5484,
            school = "shadow",
            copy = rest(HOWL_OF_TERROR),
            cast = function()
                return 2 * haste
            end,
            cooldown = 40,
            gcd = "spell",

            spend = byRank(HOWL_OF_TERROR_COST, HOWL_OF_TERROR),
            spendType = "mana",

            startsCombat = true,
            known = knows(HOWL_OF_TERROR),
            usable = unlocked("shadow"),

            now = debuffed("howl_of_terror"),
            handler = debuffed("howl_of_terror"),
        },

        banish = {
            id = 710,
            school = "shadow",
            copy = rest(BANISH),
            cast = function()
                return 1.5 * haste
            end,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(BANISH_COST, BANISH),
            spendType = "mana",

            startsCombat = true,
            known = knows(BANISH),
            usable = unlocked("shadow"),

            now = debuffed("banish"),
            handler = debuffed("banish"),
        },

        -- 3 s cast, a Soul Shard (the pin's rows; its 300 s is the control's duration, no cooldown row).
        subjugate_demon = {
            id = 1098,
            school = "shadow",
            copy = rest(SUBJUGATE_DEMON),
            cast = function()
                return 3 * haste
            end,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(SUBJUGATE_DEMON_COST, SUBJUGATE_DEMON),
            spendType = "mana",

            startsCombat = true,
            known = knows(SUBJUGATE_DEMON),
            usable = sharded(),

            now = debuffed("subjugate_demon"),
            handler = function()
                spendShard(warlock_forecast)
                applyDebuff("target", "subjugate_demon")
            end,
        },

        -- The pin's channels (10 s and 5 s, a tick a second, unhasted as Drain Life). Health Funnel needs a demon out.
        -- A full Funnel's health cost is reserved by its PvE guard. The spell's healing and cost modifiers are live.
        health_funnel = {
            id = 755,
            copy = rest(HEALTH_FUNNEL),
            cast = 10,
            channeled = true,
            tick_time = 1,
            cooldown = 0,
            gcd = "spell",

            startsCombat = false,
            known = knows(HEALTH_FUNNEL),
            usable = function()
                local p = pet -- the simulation's; the belief's `now` context has none (the client's answer decides)
                if p and not demonOut(p) then
                    return false, "no demon"
                end
                return not locked_out_shadow, "shadow locked out"
            end,
            start = function()
                warlock_forecast.funneled = true
                local rank = knownRank(HEALTH_FUNNEL)
                warlock_forecast.healthSpent = warlock_forecast.healthSpent + (HEALTH_FUNNEL_COST[rank] or 0)
            end,
        },

        -- shortcut: the mana Drain Mana gains (a tick takes up to its rank's amount, capped by the target's mana, which
        -- is unseen) is unmodelled; the live mana read corrects it. Upgrade if a priority casts it.
        drain_mana = {
            id = 5138,
            copy = rest(DRAIN_MANA),
            cast = 5,
            channeled = true,
            tick_time = 1,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(DRAIN_MANA_COST, DRAIN_MANA),
            spendType = "mana",

            startsCombat = true,
            known = knows(DRAIN_MANA),
            usable = unlocked("shadow"),
        },

        -- 30 s category cooldown; the absorb's size is unmodelled.
        shadow_ward = {
            id = 6229,
            school = "shadow",
            copy = rest(SHADOW_WARD),
            cast = 0,
            cooldown = 30,
            gcd = "spell",

            spend = byRank(SHADOW_WARD_COST, SHADOW_WARD),
            spendType = "mana",

            startsCombat = false,
            known = knows(SHADOW_WARD),
            usable = unlocked("shadow"),

            now = buffed("shadow_ward"),
            handler = buffed("shadow_ward"),
        },

        -- 2 s cast, a 1 h cooldown, 100% of base mana (the pin's CostPct 100; no summon modifier's mask reaches it); an
        -- Infernal Stone is the reagent (not read here); the demon is not modelled.
        inferno = {
            id = 1122,
            school = "fire",
            cast = function()
                return 2 * haste
            end,
            cooldown = 3600,
            gcd = "spell",

            spend = 1,
            spendType = "mana",
            spendBase = true, -- the 1 (100%) a fraction too

            startsCombat = true,
            toggle = "cooldowns",
            known = knows({ 1122 }),
            usable = unlocked("fire"),
        },

        demon_skin = {
            id = 687,
            copy = rest(DEMON_SKIN),
            cast = 0,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(DEMON_SKIN_COST, DEMON_SKIN),
            spendType = "mana",

            startsCombat = false,
            known = knows(DEMON_SKIN),
            usable = unlocked("shadow"),

            now = armored("demon_skin"),
            handler = armored("demon_skin"),
        },

        demon_armor = {
            id = 706,
            copy = rest(DEMON_ARMOR),
            cast = 0,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(DEMON_ARMOR_COST, DEMON_ARMOR),
            spendType = "mana",

            startsCombat = false,
            known = knows(DEMON_ARMOR),
            usable = unlocked("shadow"),

            now = armored("demon_armor"),
            handler = armored("demon_armor"),
        },

        detect_invisibility = {
            id = 132,
            copy = rest(DETECT_INVISIBILITY),
            cast = 0,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(DETECT_INVISIBILITY_COST, DETECT_INVISIBILITY),
            spendType = "mana",

            startsCombat = false,
            known = knows(DETECT_INVISIBILITY),
            usable = unlocked("shadow"),

            now = buffed("detect_invisibility"),
            handler = buffed("detect_invisibility"),
        },

        -- The curse slot's other two (one curse per target: CURSES); Tongues is a plain cast, Exhaustion the Affliction
        -- talent's (18223, 8% of base mana; wowsims leaves it a TODO). Amplify Curse reaches Exhaustion (DB2 18288).
        curse_of_tongues = {
            id = 1714,
            expects = "debuff", -- no damage
            copy = rest(CURSE_OF_TONGUES),
            cast = 0,
            cooldown = 0,
            gcd = "spell",

            spend = byRank(CURSE_OF_TONGUES_COST, CURSE_OF_TONGUES),
            spendType = "mana",

            startsCombat = true,
            known = knows(CURSE_OF_TONGUES),
            usable = unlocked("shadow"),
            missable = true,

            now = lands("curse_of_tongues", CURSES),
            handler = lands("curse_of_tongues", CURSES),
        },

        curse_of_exhaustion = {
            id = 18223,
            expects = "debuff", -- no damage
            cast = 0,
            cooldown = 0,
            gcd = "spell",

            spend = 0.08,
            spendType = "mana",

            startsCombat = true,
            known = knows({ 18223 }),
            usable = unlocked("shadow"),
            missable = true,

            now = lands("curse_of_exhaustion", CURSES, true),
            handler = lands("curse_of_exhaustion", CURSES, true),
        },

        -- The Demonology talent (18708): 300 s, off the GCD (no GCD row), the next summon 5.5 s faster for half the mana
        -- within 15 s (the summons above read the buff).
        fel_domination = {
            id = 18708,
            cast = 0,
            cooldown = 300,
            gcd = "off",

            startsCombat = false,
            toggle = "cooldowns",
            known = knows({ 18708 }),

            now = buffed("fel_domination"),
            handler = buffed("fel_domination"),
        },
    })

    -- Cooldown Manager items whose spells are bag items' uses (Healthstone, Soulstone Resurrection; no pin row): a
    -- passive registration only names each ID for the Cooldown Manager map. No ability is made and nothing is tracked
    -- (Tracked.lua tracks a spellbook rank; an item's use is never in the spellbook): the cooldown is Hekili_Shared's
    -- healthstone's.
    for _, id in ipairs({ 6262, 6263, 5720, 5723, 11732, 20707, 20762, 20763, 20764, 20765 }) do
        spec:RegisterAbility("track_use_" .. id, { id = id, passive = true })
    end

    -- Not registered (one line each): Create Healthstone / Soulstone / Firestone / Spellstone (out of combat, a shard),
    -- Unending Breath (utility), Sense Demons (tracking), Eye of Kilrogg (a channel that moves the camera), Ritual of
    -- Summoning and Ritual of Doom (group rituals), Curse of Idiocy (the pin's row has no learn level: not trained).
end

-- Talents: { talent tree (1 Affliction, 2 Demonology, 3 Destruction: the dominant tree picks the spec), rank 1's spell,
-- max rank }: Forever's live tree, wowsims/forever's (ui/sim/talents/trees/warlock.json: 17, 19 and 16 nodes, each
-- spell in the DB2), keys its field names in snake_case.
spec:RegisterTalents({
    -- Affliction (tree 1)
    improved_life_tap = { 1, 18182, 2 },
    suppression = { 1, 18174, 5 },
    improved_corruption = { 1, 17810, 5 },
    grim_reach = { 1, 18218, 2 },
    soul_harvest = { 1, 437032, 2 },
    improved_drains = { 1, 403511, 3 },
    improved_bane_of_agony = { 1, 18827, 2 },
    fel_concentration = { 1, 17783, 3 },
    amplify_curse = { 1, 18288, 1 },
    pandemic = { 1, 427712, 3 },
    malevolence = { 1, 1310949, 5 },
    nightfall = { 1, 18094, 2 },
    curse_of_exhaustion = { 1, 18223, 1 },
    siphon_life = { 1, 18265, 1 },
    soul_siphon = { 1, 17804, 3 },
    shadow_mastery = { 1, 18271, 5 },
    wrack = { 1, 1316697, 1 },
    -- Demonology (tree 2)
    improved_health_funnel = { 2, 18703, 2 },
    improved_imp = { 2, 18694, 3 },
    demonic_embrace = { 2, 18697, 5 },
    unholy_power = { 2, 18769, 5 },
    demonic_aegis = { 2, 1235316, 2 },
    improved_voidwalker = { 2, 18705, 3 },
    fel_vitality = { 2, 18731, 3 },
    demonic_energies = { 2, 1225214, 2 },
    improved_sayaad = { 2, 18754, 3 },
    demonic_sacrifice = { 2, 18788, 1 },
    master_summoner = { 2, 18709, 2 },
    decimation = { 2, 440870, 2 },
    fel_domination = { 2, 18708, 1 },
    demonic_brand = { 2, 1293695, 3 },
    improved_felhunter = { 2, 1225217, 3 },
    soul_link = { 2, 19028, 1 },
    demonic_knowledge = { 2, 412732, 3 },
    master_demonologist = { 2, 23785, 5 },
    demonic_pact = { 2, 425464, 1 },
    -- Destruction (tree 3)
    destructive_reach = { 3, 17917, 2 },
    improved_shadow_bolt = { 3, 17793, 5 },
    bane = { 3, 17788, 5 },
    molten_skin = { 3, 1225220, 5 },
    cataclysm = { 3, 17778, 3 },
    aftermath = { 3, 18119, 5 },
    ruin = { 3, 17959, 5 },
    shadowburn = { 3, 17877, 1 },
    intensity = { 3, 18135, 3 },
    agonizing_flames = { 3, 17927, 3 },
    conflagrate = { 3, 1293817, 1 },
    pyroclasm = { 3, 18073, 2 },
    bane_of_havoc = { 3, 1225228, 1 },
    fire_and_brimstone = { 3, 412751, 3 },
    shadow_and_flame = { 3, 426316, 5 },
    incinerate = { 3, 412758, 1 },
})

-- Packs from the talents (Engine/Schema/Selectors.lua; after the Hekili classic branch's pack selectors).
-- SM Ruin (31/0/20) stops Affliction at Shadow Mastery and takes Ruin from Destruction; the Affliction build
-- (35/11/5, aff_wrack) goes on to Wrack (an older Affliction build took Ruin too, so Ruin alone does not tell them
-- apart). Shadow Brand and Demonology are both 2/31/18: only Shadow Brand takes Improved Shadow Bolt (the fire brand
-- build spends those points on Aftermath). Any other build runs its tree's default.
spec:RegisterSelector("sm_ruin", { spec = "affliction", pack = "SM Ruin (wowsims.com)" }, function(tab1, tab2, tab3)
    return tab1 > tab2 and tab1 > tab3 and talent.ruin.rank > 0 and talent.wrack.rank == 0
end)
spec:RegisterSelector(
    "shadow_brand",
    { spec = "demonology", pack = "Shadow Brand (wowsims.com)" },
    function(tab1, tab2, tab3)
        return tab2 > tab1 and tab2 > tab3 and talent.improved_shadow_bolt.rank > 0
    end
)

-- A curse's name as the client shows it (localization spec §5): the client's, already in the player's language and as
-- its tooltip words it, read once here (a plain string); `english` when the client has no name for it (not cached).
local function curseName(id, english)
    local info = Facade.C_Spell.GetSpellInfo(id)
    return info and info.name or english
end

-- The assigned curse (tools/wowsims/apl.lua rule 16; the recipes' `select`): wowsims's Curses class option, a choice
-- the packs' curse lines read as `settings.assigned_curse='<key>'`; every build's (and so the harness's) is Elements.
spec:RegisterSetting("assigned_curse", "elements", {
    type = "select",
    name = L["Assigned Curse"],
    desc = L["The curse the wowsims.com priority keeps on the target (wowsims's Curses option). No Curse: none."],
    values = {
        elements = curseName(440892, L["Curse of the Elements"]),
        recklessness = curseName(704, L["Curse of Recklessness"]),
        weakness = curseName(702, L["Curse of Weakness"]),
        nocurse = L["No Curse"],
    },
    width = "full",
    sim = "elements",
})

-- The priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit those and
-- run it, never this block (tests/Forever/warlock_spec.lua checks it matches). Each pack's .simc is generated from its
-- wowsims recipe (`make wowsims-packs`, tools/wowsims/specs/warlock_*.lua).
spec:RegisterPack(
    "Affliction (wowsims.com)",
    20261118006,
    [[Hekili:T3vBpUnUr4Fl7xCS7LZRT3SPjbRdqAlk61MMR4CaY3SwAjABDRKOGi1Uzbw4F7DiLLmLej17EtVUhWDNpjXzEMHKdN3yU1Zx)11RCqm86VSy2I3oF(83nB2BxVI9yiE9QqK9DODWpcq(W)8tB365AZCjbhUD8dKhOU(0P2e)j8V8rpcYHtTnXUESFjy9gLeMgITxV6BF63(8V(x)xFaLrX1R2764GtggMABGBF4WTS94d3E8zxULeHVhhD4wh8wuSh7WTF6)85d3cpg(LmrIDVKZE6LpGI8i23DPti9soCDOxciX6HiqENkEW0FNscM8AGtrOaQhihoWVjCo7spClYXHe8k4h3HFKo9WT)ned9bfiA8)(x(kqK9mwi9dxE5ox2(4nCH4YcF6eGMaWXxJEVTZc0cNT2az)m8kp3GDajiXmhcxIcJ98OWdqbaICId2HjbaqIPGgXdJIc4ifeZKVkedu1gfHthXEmYJT)NrGkagGpkaD42iSnbWWJah)1ih3au0Jh5dOfr3Z5k8vuFKN3HBdI93WfnYwqSjFLZKh276H5GjcTH)dgkAhMbdEhN70ykd5kGLdEt82ThrIaJaFICjrUmxmxp(Bix(NH8HvD8zqppqnDC6o0nqqKVr(2kqZLnYhNcl)IiBbmSEfsmxtNgYLj)ni2YebMYib4xdkjlcmrVZ2z58x74sd9qpATbdCz5vZET72Ljd6JZgDCjIv49ylBsad)D2H)zjQ)tlVKtFykYkKWFNrw8MoWc2ERTXGcWJtI0rM8elkAlw9i9C3ITyOq5bzJcSGVjewaKbH0VtqQr8vft37EZSPV96)K4)Wh9D1mGg77tcSUN468aY7oCuroL8bzm64Yy6ikXJyKKU(LqDYBupkhmFqOiFsjiKkS81EtL(UPoKhmsn6DUb6i2fjdlh9UlaiOmB4eqWLMXBemzBtC90UAjzdw2JWb7G9loJyKD78WaB2IdOU3JPzFXXvqWIqn8mc2Hkwfme8m7rNyJf8VblR70SULUhbkiRnepwUjGKDjXiVs4qOGpomUnBB804q1e3oosSj1cmRyH9W(4agTMS5I0hq3tIywCJKJOygdSaqNIOu3DGnklbhw(QuA)Qrjg(MQKZgwkK99WZUZdtPbWFpeivM(LrR8BRdAFaJUBOqAkTlJY03yaHILFWNU1ncxtWvAVaIOznRnjkkouCiq9iTk5ovOYO10iSpGA6nlpAWr6v2iklZqK0ZXFhBhZvFQb6guGqHH2rcES7ynh5sS2v4nGfFFdZku3W9KtwF6gAKiMbw6chKWDQR78lLsLMNYErUzPSNwXCudbOc8n2J784nZN9KIviItQMCsUsmUlSvxuUetOnf(nEVqT2kKdkQwVp6ImPEuzrBIPZ(OKyV2J1swjY5NJ0iqrGLmsCa7MfN0(pa(dlqF6dKo6CC(X(GBaOfEk)dlC0m4Zp8OG74KCCzTyC4tfNJJdNOr5aYiHvWP22QLAGlQg2koUOwRmJMuE(qNdUxnRchCfXe2NyRVC4PtmRLtQQjhkMrSqmgxr1BeTGc5IY0jBCdriEdwGDnnCUbkiUEl0TMeWwFeM25p4SZxiz)yeiwHnFBj2X06UxUIWW0g8vctwutM0OagAtqyAd9AaXzBdbtzGxdioBAaydqyx5DWS7Y6af0vPqT6nK2MqUkeOvVHfTbCjhftVXT(lCR2dpfO7ChSvx2buRna9wOwVeGvPaS6Ih4k0nv6QyhJHOBbtnOHqDgcCQltwYePVcsIFOcgoWnIV6RmLmfNemu(37YW(0gpsH7XU2wrXLcYQ6b7J(DsKfFTH6OPQMc2ippRK)ty5hL9AEfPxsbDGh2Yp2J5MA9jXDepYox7Aqx5Zl5F(w3D7zwhpC5JkpunocXh9OUG4Jy1HWoHu(3cU3JdW(UyWJ72XGC6cd0)Jvs)YbbioHzSsx8FAmd5bosdM8cJi3dUlkn8P4aEHHpgDaVE3EOJwkhn(Iu)is((7J9cWrOnUE8k7EYuQYxN6eW4JhujZtUFa)KINdqg4VfZ1hpb(RMRfM))HAb1R1SjepUJcIc9mo1BHC7we((804XAF3OXMhyUnK)81tU00EYj3mFYit07cvJMF48KNmarTdQk1w(8gKbm5jIJYzlN6(yo1tL4r29GXIJQdT5wiU5QzJYB57TZQKyzhR3GDqv)1YquXNoYGsuiqGWOsxsOmPKHwX5glvNKc7hTZmDZndizuSgzFy8fJhxJpZyskGfDzlvuNAGKfS9rsguYRSq8RGp1ijbInq1EkrBgzAZKsETaFIPOCMtRxHS2K5UAcP)hDIjl9tTzs5eYoNtiNZnt1q0R7KIAV8wI8db7NpMq3Y(yB8OwDhnA88uthSFrQ7b5Fzeg58OXJBZDs0ngpVFIc4LKum1cvY74sfFqN8g(MRRu5AkBETtXQdCTcBsPdYWUVm)mZLUIrkJ6roBqPX8aBnZdUpU8QjpLWQPKyg11bFTcRhnEL6f6xF8K(5ByzvRMj(d5s8AmnCgxtNFj28f1cCQZXzTwe)(AXanze)u4ysj3w3(KCjapl5aMJNtAk1JqCS2ghLnFMO)o94ClqtAr9JFzUNzVhXREmiQYt8zHOTehhHVdPARw7w7BC9HQLhPR2FN59BTkcn9X1PqvWx1NPE)bqHm)6Fa0izrZDUfJcN2TCU5apZb6CXZ225ntY0IfTujdRgsdhLFXxgjhS9I3pPC02AK61RUhhrb2x4A0WtcdvC3DsUZlWp)I4U8CmjtR)lWRK7rL1F5QzRxzh5YWrUi4xgAwL1RK2uWP7XRvX6vsDAZAgajZC8n9ehDZ6chotVQatZJTJnrJmJt5Nu71WPZB0qN0fvQirlB7go7Uwd7k1go64RP2XHZG3AMbU(ALOKVGtJ)SgAi1CmvPweBik2mnCA)oJ0M3novr6(OTE4i59ArsA66QCDBhAchocMptheYAmNHeczpsrFajGxrtjkMx0xGnzhFYsnU06Xt5LB9kHtx8n8CUw0CsJ4AJAILAMIaXcMmGR8BYeHfcrOOXPHteAq2h0igYFtbXOOTXHtmQrUp0a)03xa66SZk3esnuGu1mscEv0KBJO6W3jsskTS3wqBv0GFFjb5J)ZrNFw5NAZnOcaT4Ph9fql2(ss2Po9McyP45h9fw6CZnDc8PVlpYxu8yNgHCfa)uFpnSn(uLcwNoWQwBeZHWw0ruvVzCrXZ)Y7uaVbQ6UGDUBKQU2jvkBLkH2Q4rT6IGq0(oDwXjyzRczWGPG60jsTQ9ReOv3jHIq9hcOk4Q2WqKD7BG4DXtZ6XLec6x8qiD0xQzVAbxkE8IoUCQpWKzII0iiIAUOPFDunRfXQdrlA2vhrL7ES6q3Iwc1r3snwwDiUEF0vnItMTl0dmjjHXk5pAuQOkPc(QZ6HShrYOPB9IMGLfnbCI4CMxv3M1mzVy61faqVhY5bG62rRMaqDrXe8xV)TA6GRHRfUEo6HlZrDl864k9Ew)IkkjXexP3HFtjDU9vlO377ntn(wV15B1C3Awc85Q23OnrykZfNHU)Ai7HobslEwxksv58xRAUobx0fdqjN20raDPhxJ)x6ittC1TH9PxLnQhaag)ptNoEBGx)sTnEP2ggzWl124LAB06ABuHbsf22kcl1f8GPOIgzhqQUucnIRnkn7nPGhmf1XOeWZx8GHd4nTmhmfvVOe4pv6GHd41TWgSN5AwKPCKYkzJ40zOogmfvQif3fkAqFb9MuadMI6tKzvrUkc9f4kv0cMIQsKIGtzmVVyF3RtbtrTi6iEva3Zw1jykQarN3xvRTvoDTQeSxQ7Wl1DqbFFPUdnG3)XSUdvObvN5aw15cxr48v5xS8nAqiXzzWucq1W53(6s4DwV4qd)T9sv(oQYJ)UnL8SDf86V7G35zAPYaXKILPBtjplxaVZ8gPAi8voLW0xXlfw20AQw(cqjp)y8Qpz8Upz(Yp1UB)uhU(tNP7)KPlaLk7AsA62PUQ)vCsBqQ5Q)ME8vV75K6qnKzH(U5858Io1GB6KHR6KMiTLeFUtlzLCQb7qtUWu51wTCJI5vAQwOvZllLH7gu7U3kQ2XOT)tYM5EMvsvDZJgeTKUdMlfLZ5xUQ3vQsLLHuHqznnB9mRjzKFdRA3Kq)CfRsmqOPdsAG1c9NN3UtzATY(h8dLlF52pVhsxM9T5q60HKl5E1Y97ADOE5pPIBGF5RGVyDntKsG98cB(pW3bNjF42X)9J)pCkXRx)F)d]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261118006,
    [[Hekili:T3vBVnUns4Fl5lETVDRJJZMCBxeVa9UdhUExV2d1fOFZkms02Qws0qIkPbiW)2VHuVykkskQxS3G28H26vsCMNz4qoZWz42vxT6xwT0drXR(X5ZMF7vxD1NMn72vlPpVhVA5EK7o0g4hrOq4F)pWHKisazZZhUF8tKNs8dtM6scNW(YNdiipg1Ei1pG(9rREqjHt2JDxT8x)UF(h(P)()5ZELuC1YT(EE4SHHtCnWTpF4E6w8H7ZF2LRjX4hXXhU3dVgLgqpC)39)(Hd3dp(W9visQ)Lm2NC5tO4aI7Ul92NCjdUEjxYqIZA)ySZdXOiVP8hp93sirt(aWp4zjbG04b)MW4VFYH7rEEKO3b)yh(5KPaZqu0NvGRX)3V)xaISLs3N85lVCJpDB6dmr5sPpDcqta(4BqFRR3C0CV1Uaz)b4vb(rBasqsPEeMCTpniibEaavqUtJ2Gjraqsta9sagfhXqkiSzF1EmqvxumUyeBXOa62VbbkcyaHOi0H7JXUeadpdC8NI98JqXpNZhqxIEKXv4RscrbbhUpkn8bMOrwdIn5xym5PT(bygyIrpW(bffVbtHbVHX9K0ekYNdlp8dPRxNJeogb(e7tI9P(yME8Nr(Spdfc2ES5XGaqnLpPV3pItKFL8Rlbnx5iFEkyegtwdyy1sKl1h0ht3ZKPWhq0fzcCcLeH)aOKCiRx7SX1BXvFWZpzFa6zNhWaxwC9Sp4VEr2G(YSr5gko7Fe74sIO4FNE4FxJ6VFXLm6dtro7jS3zKfFShSGU1zDkOacyKOyKzpXjbTgREKb(RXou0EXb5IICGVzpyaucHIVJtQrmRIPB9VB20BV5VW)dHOFxndssdHLzops89EcfSdhlZPSpOKr5MXjJsGLMgjPFynuN9g1JIVFIdkoKudcfclZ2BQW3n1J8KrQLSZpshXUiByvO3UiGGISHraoxAhVrWKTlXpqR1s2cSYhHJ2aRx8grjB2eGb2SghL4)ioP8lYTGaJqn8mgwHYTcof8S8rhzJd8FHDw3OXUnzlcuqopqcOvMaYwLKIcQHdUcoFyS9SDXtt3RM4UPX8fPoW2ko4aCioIMyjBUO4bjBjXuh2MKJsWukSdqYuusI)gypkhohw8UcA)UrzB8nvjNnyku(9WZ2fGtsIG)5uGur6xhTIV1g0(egT7uH0cAxhLfVXac5MFWNY82Bj4QTwar0zZcoF5ocqs7AON4LRVWuhyNH8LyuuayxKTBHVBEuj4iMVvVcPU6lJXHattUB(0Bk3yseotX)o2nLPq1aDsAqBuk5qW1peX5v6(JSTGunXtxsCC6EUpt7yQkZKcBGsAvQkwKJhHx5IsOL4u45na0hqrC7l0gs0Z9hRvixMZbP3aoidnye7dobzbK2FOuqPAkTYxurLv(0guyTeGkW34awGV3D1SxumDX9Yo5OCLTQH7NrwU4A32c)wByALDzfOOY4B0fLs9O6I2et(TzR56owRTdxLy0egbkg2fMKgrVB(rT)tW(pC0x8ab3(JRo2N8JaTWlvFOuyfSDcPOODmsoUUwmD)lYZXP7NOr5aYiHkfqEx1sTi8AdlfhlR1QZOj1Np0fC(1ZAk4827rYoikoBzNFRHkmpRW3aBoOMCOukXbrPi3DdhrR4i(I6uP5nCVO(6JrMi0Pi)4twwXTnx4tugWdwEVTjB3Hih3ZFMTNV8zFDKfR0MARjUPj2ULqd5WQnZ1mMm3sM0QST6sgSAZB9eIZUM)QYSwpH4STzVEcYzvoUG2jTLRLS2Z)GLXAf3JDyHv7ZxTAYaTtrDgZwTwoQdgs7sUQIXJmyaz4YuT7Wtb6o35P2hdsRShhSSuFl30A5M2NuquOBAmi3EMev)Yd9vA2NNHCo7Z0SirgQ8lbsXgUpfhMuNqMsnSiBbqBgNwl7WMhCi63iXomtd1Pb2mfCrbboz)rW6lH(bw3iSibMccWoHPbu)InFYIJkGSX31c6Ufheuepf7PqIb4iCOpo5llUUizGqYJ8WBhnwXNW56uy3OeFp8ntmMITG)zM7sX9Tx7Vzl1j3P2xu6BnnMhZstCqxmDJhFHYaWoUBL2aZM0qKzJgFrDvZKxK1nnQCmolNp)6rOhNDRY0fx1nguX(Xa9)shPVlHeW8NMKnnKRkRm5MLwnmfP9LVmECfBKV5MjxAYmzYDxnzKj6DHQrZ8tn5ftyuZOEr)AJN8PB9JGP)gN)By1yfY1eTuMHWy7muvLMq1fOfkOJjnWc7891EkK8oeJKd1pepXuMgnQAQE2jJvUEmBEv1ByG7lvKGgzOyKeJ5E137YwzC313iPlUDwJetocGM(8QEMBbsv8Phxeiq2CDfxUazsXh4ssOcNFCdUAwO(azCF2TCNlMjOW2XwCslGX6yl(mJhit5stwy8kpgKSL1dXbQOKxLhNrd8XIdeHT5eedMwser4)4DtSFE796oIQUmZvvvXM9KvgvMAAqH0MjylH0FKN9kp0UUmZDe(NZzTZ5Ysle9bDMtDmvl0E8ugd9rxOkJKFr2XtbERR6K)UBAezINgKblOXQQQMYy3pEKofXTBxShM9LQh9chhKn4VYXvOwcepnOwkd1wb)vZqWyEv5NMzreZnIAnhzypmkAy2wpouF6F9C6vqduMZYcCAmEhQEg7MZvr77mNKJQ53Ier)K58zmKoJEWOpjifQcw67beINZ604NFfOqU6MxdAemS1Fm7Oq)ZNgX8IxrTKCcqNBjuYH4IRAb2RKjyxNsnjtZN3v9)4XfzWn)2zZgjMM6hNpPEEQAK6vlFeSIb2lDrLyhHtc)2rLDRIGF(J8Blv(PjV6VbVsSfww9JxpB1s3yFko2hb)YqVSSAPW6fgDZVYkRwk0ioROaKmZXpoqC0VSjDym9AjMwfB59yJiJl4Nq33WOZh1qNcJkvKOJDLdJD3OHD16shD81u36WyWTMzGFOwjk7ly04VQHgc9ottQf(cc5ETHr7pzK2SM1PjspeD9ddjFRwKuCswnA32JE0HHGRMPdcL9TZPecLpsrBcXHN8wjkMx0xlkUExUfHeShpEuwRwYJqKTGNXv5TtAfxBvpUyzUWCdMsGR8BkfH5CrqEZPtNi0I0S1igIFJKyiV34PtmSijFnWV49sqx3(SI9Oulfiv9QeNxYB52kQwUw26se332usynOW7L0FYUaALmLdplBIjb8u8sPDeK9z0kWC6BVjbRYY3kPoL91musqriNw02thrzLbvfOZL9inuaT3Tf1r4x8ojK3lNvka(XoM602Yunky9YFOvg)9TxQAEbWCDHRFS1R6VGDUBbR(2dwkBclU2s2XRU0I4TVtVvCCwQZHPX8GmSvGnDIuNACloA1MLtfpANaelo7AN7AoE1LrvLOGhE4Y5TS3Zb0yItFzFB6OVqBI1EUCTSJjDCPSdYe5HIdvHtuzFg6iQyZLzdDL3YwhDR13z2qC9jxOAeh3AwQ1FYo9iNS)wZPH6yY5RUtkPOPyerc7DNKwvJJe59QoY3(1LA1drInKQEYUwF0(gAGTtvhSzx15SjI)R1hXFv(QUj2ANDMC9I4aqFu(scEFaG6YtY5V(y07CPag8EIZutX16J3Mv39o3wCwQVlpNEMk(J6oVll3cPX(RJZe9jcOP76ET2EDnMy8hL9ZC0FLQJW0ut51NUYJdfDb4Rk(Xo1UECUOZhKU4(0rhThdV64X0rgDHHQsOBzN)1yR)baGY(RtS8lx9Q3k9ZBL(XidER0pVv6Nox6Ng2GuXEBYWsD9GOkk4tzGfQR0sR4ARQcrBQhevrzEQb8Q1w50b82wfiQII7ud8hRSYPd42w3h6x5s60uCgwWRYvUwFYr9UqpuffYrriLTsmAzTDOkkFtPLMWHf3kmCgkPdvrrBkWTu9tgkO3MA5qvuQMc4DSmcdfY6FXBOkkqtpXRc4E2kzdvrzz6TvTvg19Uun03kgZBfJrbFFRym9i2wRGlN3)XSymgdQW2IVyYFGL)Dfx2zI0uXmuCsjnLYH4fwHRhlp6CbqArEfd1nM8SE3SELCR7uDEtnLXv)M3(QDFjhUlm5RO5UgZwwiHZ(nV9v52sEMxsAHWpmZBu9vTtXgPhNDmxySt7fLtBUAv6jj9qFGVVCQ8TvP2RnJKoEF5uNwIaVzXyuwIofZN6IFi7s3vfQgMU7EfuvzNy5fUZWTPQBxNhvwn6uqhViEFLvsnDHSojAjzlATAPYlN3F20sAlXzltM68lY2Dv9yYsBsJTP(OqVo2KmYU5EDC(zqU6Ez7WQPPtoRUpRoPD3nDZhzD)y2fQwp8O2VoFYuCNIhux7KIU5n2AjHB1q5jPVLvV1)fENFG)H7h)pZ)FbB8xV6))d]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261118006,
    [[Hekili:T31xZnUTr8pl(fDsnxKLL)ttUXYZK2oDAAtt6eLzU3enmjKeJij0qaAFEgp6ZExaksbscasqsj7KZp0wFKe7(BxSyXUyxOU4If)2I5EigEXppDY0BU4Il(UjtUzXC2ZBXlMVf5UbTc(Jiui8F)pWuwCIlZNeT7(HprEI6hsh7schX)0Ndiipo5EiXpG9JrlEqjLPBXUlM)5F4x)PF5V)F(K3bsUy(AFppC64Wuxt87t7UNTgV7(9p78LKy8J44D37HxIscy7U)h(F)0U7HhV7(IujX)CocON)ekoG4U5CVT0Z5i2JEUamKXI)14FNsIg9rGpXOiAaihEWFt481NU7EKNhj6dWFSb)mDmWeed9jf4z4)9h)nGiRzST0pD(5R8zRtEGlcNx6thb0eGn(A0376nfn1BPlq2FcEvGF0kGeKeMhHlpBtccOWdqraI8sIwHjraqsOG(iaJIJ4ifKX0VAlgOQlkgNnI1yuaB93Ia5hgqikcT7(ySlbWWZah)Lyp)iu8Z75dOdrpY5k8v0quqWU7JscFGlAKLGyt(notEATFaMdMy0d8)GHIxHzWGxX5onHYq(cy5HFiz5Y9irGrGpX(KyFMpMRh)vKp)ZqHGzhF(liaut7NS36hjiYNjFEoO5Yh5ZJbZVyYsadlMJet00XB5Yu4di2SubMYir4pckjhYYLoRC9MDXh98PBdqp78ag4YSlN8r)LZsh0DtgS3(Wz7Jyhxsed)f2U)DfQ)nZoNtFykYzlH)oJS4QoWc2ANLjGciGtISrM(ehkAjw9id8xIDyOTYdYff5aFZwWaihczFNGud4wfJx7F7KX3C9Fr8pcrFrndOjHHKiNhj(EpHc2GJlZP0piNr7nJPdOKaIrs6hwb1PVr9O8W8bHIdjvGqMWYT9gl9DJ9ipzKA0n(r6i2zPdRa92ebeuMnCci4ID8gbt2Ue)aTwlPlWYFeoAfSEXBaJSAvagyZsCe1)rmn)l2BbbgHA4zmScvyfCm4z(JoWgh4)f8SUsJDlDncuqopqcyfMasxLKGcQGdHcE)W4(SDXJt2QM4UjXIfPoGBfhCaoehXOnKnNL9a6AsmZH7KCafZyGha6yeL6Vc8r5i4WSpKr7pmi1X3yLC2GPq(3dpBtaMsJG)ZXaPY0VkALFBtq7ty0MJfsZODvuM9gdiuy(bF6s)yCdbxL1ciIgB2hqrcCSg2X0T0(aeycpE)si4F2mwRsVuboUWE(pcUJgYHeSm1JWgxaj3nzKMPls0Ya0Qyi2MgcO9ACFWlmpIiyb2GHvX4lmuayxNTye2R3b4tiEmSQCZSRFPmvIXHW0c92zxQbOzFzlrzo937Xo)fUikl3pE(tXFb7MWT9aDAap(RBV4G2oDgK7ttRsnoozRisGMHwvtYzw250QImi9QcsH0ZZLdZwROvKON7owlqU0T8k9gyB)qtopSvX1i9MaiMuodYNIpR6CSP9kPKKG2J0klJlexK0iqXGNpsse72Phq4tWAkHbA2dK2QDyXX(KFeOdEP4dlTvoKJa8OOnCsoSQomzBLLSjBhPX(hKrcRKZVMPLu4jzW(fGtN8Iik0TU8PLBV(ADCxz4UgSNhwwJAhigvDEuxG0xoPUaPfElFijUP2)QwmA2ZRkZQ7MnvJt3ixiNnl2COZkZ(ksWJgqAPLTAYHsyeheJHC30FeL7ukp4MZQsL63F9mf7XBIqhJ0RpAjvBBQ0hPeO7T0MTjz5(if5tFIXNU0HFBKeCjhEljUj0M6sOMuG1M4BktM2qMyvYATjbyTP9EeXzBt)vzsVhrCABYVhHuE)JrIUVXtVvEtx7mxo1j3wmZm7W6jm12kj02BiTnj22fLwJ0z9uATVNmBLKz7sG(wMNrTHzEetXPBjU(2iD1x3KuFLtnTl2PYePVsdfifF4(mCiTkHmLbzwsf(UoXjvsIS(bhI(DsSdxtPoBX6PGlkiWj9FcldOSpYB3Hzuy6ja7eMeW8ZCEMgUvazLVBdO7ACqqwyx7dAbhHd9X07MDzwodHKhfrbpyOIprW1XG7uQVh(6rgZexAlq(osYB7S0F1AMZ(nAVt52xjWIiGknLdnl0VYI0fMJERw5Z4e1(PiGWhMGkY)zx0oguWeWa9VRE6xmM0Hd3VfE(ErPjkRyhQxoto7UCxLoPpG)f1X7IESRdOkveUesap0dAbWxWqkvago8mTV8LHdlyp(Txp6CtMKJU9IrdmrVZunA(M6JEXeg1mQx0Vo8jF2A)iX2NDBLFbYvhTOyuS4OWqPN5sUQ4WMFzk2QVGhb93u9XSyivQahMFiE0DfMnQv0kECm5GrgL7HJQ3WXJLmuo0OHYBiE51dk6y7Mj1smvzDnuVgvx2wQv0k5(ObkMwkoFjfhHghaL4R8aemEK(GIQZ6QymmwmxO4tpSmTIiLgkdmRPseiGiKZMX1SX7m1NIL7ZU5BcWpYmPj4gC8udpB4Wg8zgpfRCNh8CYuE2rPtU9XPqPKx5Nbun8PbNIe39jSzTwsere)Xhg185TVr3561MzUIQk(SxzLrHPMAui2mb3qi9N5zV8t6SnZChG)PCw7uUSSbIEVoZPo80zOWTG76Nthz1CImgIMUqQmghMPGToll0XIVmgJ8E(W0JIbwyh(BngN4ifWl9u7uluPVtPujYirZWsFhFy8bDiYUBVU25etNsz7Mp0jtNsrkpMkdUdgQQUYktln)dYtjD4zvdjF0lLZn2COF6rV0b12e8x4OevlbYNtRLYqf3XwVQ(m9RLEr)AdEMsTX87Re3bYdZ4zPSVibhGqTtONqxc2G8MGBL5s1(151SawpouxQLoUIvsdKFQhZWjX4nivR6A3YaJtWQMFZm8)oZl90yAmY4sl9hJIcvb3SnGq8CwMe)8BafYfx)wqJGbFYX8kp91NgX8IxzTK6JGXwO2rXSuGoZUyqVDiqVfofOIk8cNh0RUM2ctLch9xBxbzsMMoTTM7dhMDGwtVzYKbYNl5vG35khmPgPEX8hbNga7lDlz5N5ovC3CtVqRWF(ZI7QloIFfl9w83Gxj3gKl(5lNSyUBSpdh7JG)Yq)qUyUK7joD3FRjxmxQzoxWaizMJx1tC0pVrp5m9YsmTi223NMYmoJFsDWjNoxPHozgvQirl7Sto7Uwd7Q0PN64RPo(KZGBmZa)qTsu6xWPXFvdnK6)Y6ulIfeL7xtoT)oJ0M3WN1r6Sf4DPZr5i571IKSsxuRDBh6ZtocUyIoiK37NhtiK)ifTAQaELDLOyErFtmi07LBZuj7XdBlTyUypE(cEoxl7oXkUQQ)r66rdkmyYbUYVjxeMkeHYoNoEIGfN6OgXq(BkjgL9nE8eJgCMNAGF27lbDD(zL7Zvlfiv97QGxLD5AfvvPMAvtTQFZZcF5I5YnGr2AoDE8L6eblLlfj4RQlzRRnzn1NScKxE)KobYJuBYEqFMn0swRL3kYkHqLfu1tSOl9pRS9q2BlkbtlVtwFjbz2UnOVARAWlgujG2P90AKMwastQtJDDBd01L3GSyud8M0T7I1PUzD7A36QSDDfARY7fRZlPOpjTuXzUTmR0xMc80QeomS2XYEfTNAYxHOOnzM8EiZwHrb0Bv3)kGNUuHoCsh2cVoRRf4s3MTfcj(1ayL3lThxQiOF5T50rFPUn2EUCz5TI0XL8grwMhko(fbrlVTHoIk3JYnHUL9LRJUvAF5MqC9PHOAeh24PuxDMEotoP)6UvtdGi4RoxCz97Oms2hrB)3XZcKu2d1b(2TMDUASg8HuCF6l1NxqzrQnD8CxI3)YYUG0nFOUxOTZuPCT4eaqFy7vvnTgaQRMVG)6o8hnj8ytly3UEWMJQR0DEqQ3qvhv0hIBRlHuV3n2MAhBRpNEHwxVBcZnKDdTLYl4GqfRle8g6HR2o7wWeDhXTCRsxy2vBTPoE98TaO683R(Kun1m4DPBWfqrxiPQIUUvTjUGlg8SBysWYkeAzbc7ZkeUOMdS4kDHWQo0ADQrD1cqtGW6iJoF5QMZvqdtTJET9Joaag)3v09)mPS49cW9Eb4mYG3la37fGR1fGRghKk8TvgwQRkhtrz3Y4LM6DzfxTQwq2uvoMIITvb4fRW1Xd42wloMIsSvb8hQV1Xd4nT6BS3lSMLjA)NOcRvnIWob7JvP2ykkN2bL(HkQyf4pbLyJPOiALTZ2xpR(c62uBnMIsN1z1AJ0QDSCAS3ly27fmRWcIoxRK3lywJHxN11cC9EbZQH(9BbZYrD2ptSlQ)qyQuGmtHl0WF9ytpBL6k4KItCPUuxKVaFc9y(zBjbYgKFsF9ZbWj9Ih)g5kLR6CRQlZTUnV9Q9Jbq)9RbWBO5UAZ6wkX1UnV9Q8tbWjEjzde((zEJPVSSkCKQD)g5RxS8KOXlwSXBwS5RwC7UBXD4YfFIUDXT96fB59lwLZwPjT2P57LBqS2KCl0jf6HEpFrIvf3sHcFvpsA5fjwD60s8Mh)yEnOTyTA6TrUiuB5sgZgkQStA4nr2W1mTDx8ovg8ApfV8BO8RSsQURo5rrl10S9pCRL)AtlPTlam4q1Aa2vPZMBQSTnIWB5orq3jQO(ilEdmVO1Cs3HVOSZvA96otYi)Ao3YLi9Y9CoDtonnTNf74Pp602fOtRv2)Hlet5F9NS5N)PtB8L9hSBtWNv9h1S8B7qOQA(DHQz)4wPARQmzOqLBStkAxyUnwse(cyIt2CnVzx(x4n(b(7UF4)C))hHT41l()]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261118007,
    [[Hekili:vVvBVTnos4Fl5lU23LZ2Xon7UfjlWE3Hf3Ux3UhQlq)MKPLOS5AjrbrQ4AGa)B)gszjtrrAjzRK9ou0uf(YZ8mdjhoZquN7C(IZcFeh78PztN9WD3D33pD635SGVpb7Sib5TfTg(igfb)CXVDy5NZiXhwoChDhJeXg7rJgjg3(qkYxG1Qmsi)xIDwzewwc2ZzXx)Pp)XF)F8V)akiiK4Xj0yNfBi((48PHzEwL1hoSKVbFy5X2MeqtXpJtpS0hhGYc5hw(t)NpEyj08HLkqKrMienBYouAi1B7e)e2ebv9ztyrUPWOgl)1X)bJgp6wqkPOywiOb(W3uHujSdlr((043bFSfVNn(WY)jIJ(Gb2m83(LVaGSHZtyFyYK1e(MSvcfyI2qhbycKg)E0p45pdnZpWdG9JqxHK41ae0mUpvOnjzHHmObumWi)S41yAmqKmgyncXO0ybtbLmFujyavpukUygBWOq(M)gcmaWeIqXOdltXEuGd7bj(7P(Kyu6(JYbSGONfsfgflcfgEyzCw0kHQrda1M(fHq2THeIfKjfTs8bhLUgZHjVwiDwgJJisA5JxLfeCKjsocYjLqtjCcwyh)mIiggkc2Tjw9cdbZ0XL6esSeKVs)6cWYvoZ9JHnEP0aGdolqYTrSNYvtgNgJVfmnU0Ga31E(pD3T(ewsiAV7kmG9tZNElj4jybzfI)JthCCBHBYZyxpAmh)n(HF9iM)1NMiqfwoCtOIwolW33zG5BCdYavmumXIXN3IldfGvhFija7YrjQd1df7MKItGf2sXvmojadeR2J3qEC64hE)Fr(lrOVPclllkIg7(mL4VdfUfNQJF(akH)4Ms2agnKAaisungM3J6y9XIHIsJO1exH6i21mwzCJ9P7mGbBlj2ge3Kp4kOSngGrfCbasSBJerWcMhLeADDo)yqzt441WUA)bC661Hya8aCmJ8mMvoIJ7cGTpvKukC6rUs(AiPYMojgx4FbVERRSJJTbbMa3v0q(TbuVmgSJx1uNVNodfwJfst5XPl8M6HhNLOcTxwQ8GKlCm3fhIJWXC2rHmRLc5MIgyBOPCxHZRbmmNdNwzJrmgzn47WvkPNExHmE3GChsJnYGAl5LJc8xUneZyXWFFn5PQCQZv1ETZ1Dy02xBEwiJ6CSONA8tUzdgqajf3skvBNpIwzhQhnnnlr6y(611cfPeZXP4iGZShF6OJeLU8qmEPdgL2XFd7LjmzQ0CfkwAAqRPX77pMwb2CFyA9aEQJQToWijBOh9U0BCrb0AcKaU)fHt1FsRaXARqLDuz9PSvJRoxi9mWUHHIG3E8UPVyyNH8MNrN0QCh4s)X6ALCPSDK)Ipb0QdaviIPD5dUPuNhuxXgv)ongnl8Yzyn)bvIgrzgOuWtfnlM)4Stw8DqmOsox0GYvIdRo3DKyq3FPAJAx5cXzdnfVva5W62USKx0xxZsgnQ6fSukxlKYl120yOIN5G2qDluD4hv32BlqZ5tnhOPs0e9iV6f7PkiOmo1fX5q(Vxlu4Su8wuDuUPomvUUiKs9H0as339PIHBHtfBj78ufJNWXrSoptzmZepiv6AzE18KJq)bn1vSHXCkwnJqJXsoSfrfo8MHTzyNn4r449ldlCwAmKT8Sp6JG)mkRYqVAqoTi4nHRQrk3w1GP3w4X2TPv1vH5xxBQyBBqJ6YkulP0)pz(nfXVD98K8Fln7VLhmAHQFLME1iSvT6bK1B4Uhdl9hF6HPnbKLKSnMbDtyzoyqdXM0qInnQ9wsHyOHKb0fLAFTswMcpFyNYdOrrOgV0qzSljEIayFC(0bvxqFyAJGPfNtheTHHcNqlSBNGn)0YlsIcK0Wa8OGwF4xDw8mepa0PwP4djmotw9)8kNdF(j5RbGJfvZ135VdDPwAtNpnFQZcVui(Gucc(6m140zHYf4cCpwGwNfkfO1Hdu68s8(EsINkERqOZ1eAvUDS2RQcUqEkvLvGZ9wWPy90eexy1AfI79wexTQ3AtUNRkUcb8W5fajYQgLpcbgFNfmuQPAtMfJ1GvG93FwSffXTjO7JQblyYpyLjfvhUX9TxrTBfm4UP2Oqz9CFnPqztgkFSKE6UsmSUypPpJx8PSF8KxoNfYBeeh4fsv3DsNKANQ9zlJ6rUHPK4ghtPkmtQc6oNE9uHoeqLf1qDmAQHUVXxp1OfHZzH(f9RrDB(zvRDDhvit1WwklDxUDc1x)cyRy0k7vZAP7WVV0Gouy7tSSYK0iQ(Th9fr1R6TIFQt9OXf97p6lU0UyHptzLpr(I(QY8z6x70jMBG4Nkx(RB9YBuXUQlSA1bXRTq6nFyCM(9Fvdkqu39RxXERR)(1waEJvGxAT0VQ1wgeYskF1goPiVOugoJRG2uD8lQQ9s2AnJd1aW6FclLT(nJ94IJeF97TSHVYtbCbsr)shBsj)vcufGHcbiru)QdBiE6beAbQZ1DRBf1Y3wOnOQ7t1gQLp7qBav3hNnqvFrI2GBB9gu7XkAd42dhUnV4qF9WeVPfG9pPAJ3PSTMR7HRnRl)P9Qf93Zw8)oRn2tHCU9CJAtT9FtxxEtpw1cLVFwBmNF8C7z81Qh(OE2AIe50KH9K1A9JI0I6fn3EEy90dM0Cm73BpJQE7PuArkP3Bp)NE4HwAk7R7TL4IP4IVOxNrkfBf(3s8S2GPlbX3X3ZPXh0biG4pIWs3ikL()cVLesoSC4pF8)qbYUD(V]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261118006,
    [[Hekili:T3vBVnUns4Fl5lETVDRJJZl32fXlq7D4W1761EOUa9BwMrI2w1YIgIujnab(3(nK6ftrrs9QDcUMp0wVsIZ8mdhoCgod3U4Qf)6I5EigEXpnDY07U6QR(8Kj3Tyo7594fZ3JC3Iwd)ieTd(3Z3G8ipDy53hHc9oSC4tKNO(7OJDj7gX)4NdiipobFi2pG9dHlEqlTP7XUlM)BF3V8J)8F7F)fp8osijGS(5fZ3475HtggM6ANHF5Ws2g8HLPp7YvKi8J4Odl9WRqXbSdl)U)7pEyj84dlvPtS)LCqqV8juuaXD7LE7PxYbTh9soECOIb48a)7hlEX4FNsch9jGPWZObGubeIr4GWNEyjYZJe(b4hBXpthFy5FhXqFrd4g(F(HFfiYggBp9lxE5AF2M4h4YZLkF6iGMGmGVf9TUEtrt9w5cK9hHxf4hUgibjM5r4c3(4Gak8aHO5fhUgtcbGetbLtagffYrkiUjF1EmqvxueoBeBWOa2MVbbQcya7qHOdlJWUeadpdC8NJ88drrpNYhqHIEKZv4RO7qbbhwggV7bUOrwbIn5x5m5Pn(byoyIqpW)bdfTgZGbVMZDAmLH8fWYd)q8QvPirGrGpr(KiFMpMRh)fKp)Zq7aZq(KzqaOMsN537hkiYVr(T5GMlFKppgmgJiRamSyoYL5d6JX75Y0UhqSzjcmLrcXFcusoKvRCw76n7Qp55t3hGE25bmWLzxp5t(RMLmOVozqQPIZ(hXoUKqg(pyh(xLO(hNDjN(WuKZEc)DwzXnDGfSnoRIbfqaNezJm5jou0kS(rg4Vc7Wq7LhKlk0b(M9GbqoeY(obPgWTkgVX)(jJV72)I4pSd9h6zanEhSE25rIV3tOGT4ivoL8b5mk1mMoGc(aSss)DLqDYB0pkHFfhu0osjiKjSCBVXsF3yynVvQr36hAIyxKmSc0BBiqqz2WjGGlnJ3iyY2L4hy0Ajzbw(JWHRH1lEdyK1RdWaBwHdP(pIP5FrQfeyeAGNrWkuHvWPGN5p6iBCG)l4zDTb72mhYKawHjGKvjXOGs4qOGthg3NTlEC8E9e3nosSi1bCR4GdW7WHmAnzZfzpGUHeXC4ojhqXmg4bGogrP(RbFuocom7dz0(ddsC8nwlNTykK)9WZ2gGP0q4FofivM(LrR8BRdAFcJ2EQqAgTlJYS3ybHcZp4tx5hHRj4kTwarmzZcB(k2iaP41WmXZxFHzoGNH0LymuayxK4TW3nnQeCiFVvVmPU4lJW7aMsVF64BZDmjdNX4)a7gZvO91YTumcoPJGqh8CKOqoufaLhDde(ehrX7ZqF6x)yCqigIzWpGVlUWpzo6LPNDW7sIII3l28TEyxN9wMXuoTY1PZsrK0RCruwosLEEfa9buOWqfTMe(C3XAbYLO9uEdSt7olRg8HDt5r22DOKrPskT8xuqLL)0kuyneGAW3WaU539xn5fntxITRhDuUsw(j2WsvUkyBwx43ydZAzxwak6m(gCrUupOSOnYwaausCq7XAjxLfc2tAeOiWDojoKD)0JA)Nahzc0N9aP4hgwCSp5hcAHxk(qL4t4UuzOWTCsoSSwmE)lQZXX7hzq5aYiHPezFB1snioDllfhQQ1kZOrLNpmfL)1tQkk)gV)qTqypRT1toumJ4GymK72(JOkkKlktN64s4cD2LdSrStr2SNSCyBAMRNO8v7TSuBsUP9rgPN)8qpFzF(2iNtLvYRiUX066yOImonMNzctMwtM0OCJAt(MgZY8eIZ2MTP2CmpH4SP5AEcYWunVYMjT5RLo)5x2PLwVUzxwCF6MPXpJ5wwkJYEdPTjZs5016nG0F5v2E4PbDN7Sk7IbzTSh7TCkFptYszs2LmA0OBQmA5oMtw3YA8mKRyx0NYePVYleifF4(m8oAzczlzUS47HTzJIlLpx1dEh63jro85a9jUvnfCrbboj)ryAMY(eVW)ZOWuqa2zxCaZpBvEsKpbK1(U1GUBWbbzraXFkekpoeVZht)6SRZcFFhS1opG0bd18jcUogw2t99W3oYAsXsBeY3xs2b5k)1ByoP7E8vTBIfhjIFOkoykkSHdVqBithDlymuQrvel1GHxuw1m6fvDtLkhRZYPZVEe2Xz3ImD2vTJbfSFSq)V2s67sib8nUOjtdPQYctUjjcdtrgF5ldhwWg5BUD0L2mtgD)vJgyJExOB08neg9InmAyuVyETXt(Sn(HW0FLZ)kEKh2YORZn01gF9r7DTVoZSptfiZtEmCFuZZHKQb(7W83HhnYES7vQdQWJubvAv0YORaDqm1kRLI9xlyCwPuw8WBgQ19scG09goGAidLJazOiAG9U8f63F9Kbf99E3KkjwdouvfwR5thyz2qauaK6MuiuM05sxXwHZ0FepUp7M7zLN0RKnsno7gWR)WA8zwpINCxh8451EWkjUD6JJOrlVYpGKk4tnoIfUZtigrJKiKi(Xhgv)5TpA6qVAZmxrvfF2tvzuyQPcfstMGRjK()5zV8JbSnZChH)5Cw7CUSSgIEVoZPpMVzgpNkRHMzkuQbQVi5CQGqukUZ(93wjYkEYkwSHgQVwDAZVq(GvYYUOpcL3SmKF0w1rcKoMc94)45t1q0xAf8RMHG18(spwZSi6Re1gp(ToAuuXSTz0O7Km7W0RKgipNQz44i8wu5tuWEUugFN9KW0n)MLXWNTNVLL0TmdgZjPPrvWpEHacXZzvC0ZVbuixD7BbncgC9hXpt0)8PrSVSvwlPM5DtbzhfqL9dNDvdGEHm7A7mQnzA602Q(homlbUP3nzYa50oVz6OY5DAqQxm)rWigyVY9vIFctuX9Kk5Mfb)8Ne3BQ0ZgzX3dVsUNyw8txpzXC3iFgoYhb)YsZXSyU0YfoDtVXklMl1zplyaKSZXB6jo6N31pCMETctlIT0M2rMXz8tQDE405gd0jZOshjAzB(Wz3TgyxP2(XeFT1(pCgCNDg4VZOeL8fCA8xnqdPMXPk1IybHAZ7WP9NTsBE3)ufP7J2iIJKV1isYozQkTB7qt)WrWvtmbH8gb6ucH8hPPVJeWt1vIM5fZLktO3v75ij7XJ73SyUi4q(cEoxvDN0iU2OMMPMPclmyYbU2VjxeMkebvNtNorObzzBqmK)gfXq134PtmQro(gGF27vGUj)SYn9udfiDn)KGxQUCBevZxlF267jP1GsVxr)PUfqJKPww1Mu5QL9evDCTOU5tJKQtF)sjzEN)wL5f1nT6ljil21A0hvhrzHbveOtv3ARVaAN7ZQJWp7DkiVt76Pb4hBbRtBpyvPG1PnwRLXFbe2IMZQ6fatnf3)XE5Q7c25UNU6AtDPTRUeAl1DWnLFLOnL6SItWst78AnHklUcQthx1QobtGwJPljVhs)dybVv3JThNCe0xD3ot0xQ9YAbxu3rYexY78mzEO50oej3RU7HjIk3uA1HUQ(2nr3s9RwDiUz)R6gXrxDkTmuYX64K8xSnvuFrbFnFuijnsIms4V7K0IBcKyoHHU1DBLd5GpKI7mCTQJNJm3sJVDQ68T6vVS6ek(1MtVOiF138BnZotTcocayoxafbVlaqFbdf83Cu7T(i679EPZwZ014ZDMxp8w3oD1uFNFa6cvSPZcZW2GNS(Y7nxJ5X1o3y6y6QPd2k7ypbtmN2HL2d7u2TE1X50nQ75Lne9hIQT28Rl95NakM2guxGNTQbafCXu9cmSsXezAsuYnSLbRSNbbaW4)9qw6D9EX7fn69IgzLbVx0O3lAuRlAufoi14Btfw6RKettPIYJ8rFnAAexBu9lAsLKyAkqujGxSQmNoG306hX0uwOsG)ynzoDaVUvmI9kxmi9Xq1iELVY98vIiMMsa19fYTmRHowxiMMc)KBYkDmZnsuodfdIPPCpz4wPYl9f0BsvGyAkYtg8owaI(czDVSpmnL2PJ4vdCpBf7HPPGoD2QUwg1EDTipS3lJZ7LXrdFFVmoQOqq)xNY4uHgSUfUXUlPA)3QCjhzrvfdrZbzuvgbYxcfH2m)0TKGznc7VVUjKN17C1BKBtNUJdQQeI6282R29GS)UiKVHM7QmzwP8b7282RYTG8mVKSgcF)mVXmx1pnospo7yVWAN2laNXmGk0JqMH(j4wWPFpUcvWTA80IBcNUSxK4kF368s8Pz(0uuejxMUIG0Y0D7RaRo7KAEr6SClPA390rNvJjf0Xly3RSsQQBA1jrlPAlBulLFP7(ZMwYyLdBwa2NFjUExbpUO0KCdRQnmmRITjJ8BKxlNE6LRKxIdwd9SYzD3ZItA3FB72Iu3wy1lwToULA3AFklbFkDKEntoA(wX1wgewnmrM6B4vd9FI36h4Fy5W)r6)Nvt86f)V)]]
)

-- Soul Harvest: its buff after our kill of a target that yields XP (the "kill" reaction: the client's grey line) while
-- our Drain Soul is on it, as wowsims (e5a9cd2a2d talents_affliction.go: Drain Soul's kill flag; the talent row states
-- no proc of its own; Fable decision 2, FABLE-FOR-OWNER, until an in-game check). To grant it at any XP kill (the
-- tooltip's reading), drop the `victim_channel` test: one line. shortcut: a Drain Soul stop read an instant before the
-- kill is lost (the belief keeps only a stop at the kill's own instant): the dim side. Under the Map restriction no
-- kill is seen (the GUIDs are secret): nothing opens.
spec:RegisterReaction("soul_harvest", {
    who = "target",
    outcome = "kill",
    now = function()
        if talent.soul_harvest.rank > 0 and victim_channel == "drain_soul" then
            applyBuff("soul_harvest")
        end
    end,
})
