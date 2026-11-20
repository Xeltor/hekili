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
-- the in-combat calibration replace: wowsims's logs at 60 (re-pin ab0f00e4fc: the five Orc builds on their own gear,
-- Spirit 170, 1.2 a 0.1 s tick inside the rule, the spirit part 6.25 + 170 / 8 = 27.5; Shadow Brand's Spirit 179 gives
-- 28.6). UNMEASURED in game.
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
        fsr = { spirit = 27.5, mp5 = 12 },
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
    -- the channel's debuff: while it runs, our Corruption, Siphon Life and Bane of Agony on the target also tick on the
    -- half points of their own grid (wowsims wrack.go); no pack reads a tick, so nothing here models them
    wrack = { id = 1316697, duration = 6, max_stack = 1 },
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
        gcd = "spell", -- wowsims e4ef929e54: the spell row's GCD 1500, category 133 (ledger OD2: confirm in game)

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
    20261120001,
    [[Hekili:T31EVTnos8pl5F8AVT1X2PPxBrCb6DhoC7E96EyDb6)zfAjABTrw0qKkPbiWF2psQhMIIp0tNS35cS76kroZVHpMHZdQD50LFB5cpabU8RZMm7DtNoBYKjtxUG84E4Yf7bU3b2q)riyh9F)51Rd8Dj(OWd3o8b0dy)D4XUODJyT8XaeWJrTvX(bKFjC5kLegVh6UCX3)8V)LF7V9V(iiNIlxS13ZdM0ni21a3(4HBjBHhUn9zxUgfbVhgD4wp4AqCa5WTF()8Ld3sFm9xIej2)sg7Xx(aika5E3LE7XxYGRh(sksCEiIkVJ5py8FGrHJEnLtrGqCavo8O)gX4Sp(WTappu4pr)XDWhXJpC7FhqaFubIg(V)LVrjYwczp(JxE5gFY24vmH4sPMoIstkWbRMSEYe4Bx7((ROK9l0xf4hUHscumXdXKO9Xbby6daHue5fhUbIcPajgthrcGGOqgsPIzsR2dPu1febZ6XwiiGS9na6qaTd7aHGd3gbDrum8iLJ)wKNFii6Xu(qhfb3Z4kTv4DGGGd3ggVBft0qRPIn6BmM8Ww)aidmrGvSFqarBGeAN3W4oogta(Cy5bxfVEDks4yKYNiFuKpXhYgh)DGpRzGD0vDSzWGa6Wu609E)qor(o67lOJC598XX0LFrO1umSCbGpxJhVNjt7wbiZteymbfcFnDqYbrNO346nF6R98X7dap6Scs5Y8RM8A)1Zt60NMmiDjIZ(7HoUOqc8hKd)AjQ)Q5xYOpDkYzpI9oJS4TTGfKToRJPdabmsK1ZKN4GbRHQ7zG)AOdbSxStUGqhAB2txaKdHS2Xj1a2QIXB9VzY43D9pZ)l7a)qndWX72HcDUh579ai4oyKmNsAqoJsxgJhGrbiJK0FxjuN8g19YdY6eiAhQeeYew2AVXcTBSh6bJudFNFOoIDrs3kqV7cPeuKnmcW5YGHAB)tkH1iD4cqxi4I8d0UskzZx(JGHBO7L8gqqB2eaP8znme7FpeN3I0vx0fOA4zeD3lFfsFWZ8hDKno0)lvR7gnRPXBb0riNvOasHjNKDqXGGs4GpcN2nM(Cx4449QjUBCeFdSdvLJdmaUdgsWvKnxK9a8wueXHPaDagsiuTd4Xam2Fdv)LdNdZ)PmA)tdsukowjNnSenV90NDxaeJdP)tFGur6xgTIVTkO9bi4U(cPz0UmkZEJbeYx(rB6A)iyfbxP9caKM1SUOOO49CdevJ0QK7mHkNwJJG7OOgFZ8uLlcVYfGj5kPeEo8hq3y2WNAGUceYhWaBqHp2ESwGCsAcZEh1EWUuvHs9I)gdAdX(73IoQAQDqvGygwL4tTaXony75xgLknjM)IctH5p1YeynbOc8nmGDQZBMo5jflF4ZtJokxjA(5kYLLl(SDDHFT3OuP9jfGIQnddUixQhuw00zmMRYaJIdAowlPcPWbKe6biIQMdfhsUz2Xr)hOhKMJ(ShiyxDyX((GFiDu4PIpuYUn1zb6JcVJrYHAM7vm6gV)j5z5cnn)PX7hPBN8weIiD25MoMwJtcByJ7q5X4YmAu5zpDNJ(Qjwohn31ZUeBD1zNAfZA4KQAYbIjihaHWgO6mIknGCrz6K3V(WtYEZ)X661yp5RyN5HyD8lSl8g8LLpGNop)Ez4VN0gZ1i3yCv3NBXBpT(4LWKzvKj1YVKM4RNwp86rC2up9u6FxpIZ66Nxp4DxXJQ2EzTN8TRKhDDgs7Cp7K8NRZaQw)6eDwQZ4w35vxZHNc0DQ9PRnBpQ0UJoZJUZ(X1s)4AZb9vmsA9ePT0vL25ZwV6P2jW)S2mzjsKUYxmM9ji12DeBTAzkzYDmAxzT3Na3HRDp5h1231jkUKVC278oWFGICyRnu70MDk4cccCs(R0LFyYRz5xFoMogeaD2fhq8Z0vLCYMa0gF3kqxrZRSMpCT)MTeNuBrFsPr44iaR7dyuHE0EyiCNpe)PPcgeAGqKcFpe5i4lYH5tBgdkm8yG(FYk9l7Ib3e1qLoq80qciGEmDQwW9rO7PhgvO7JHHSmFN67blH(bGuvQ0tfLDqKK2FFCqimcSYpGL6AkHn96StrKPfxKNSds8kfpNczk)Di(7GJO)P(Jct))Wrb1R1CrOa2jn4zRAO863NYWt5Z7oyOPddpS4(Y3C9OlnT1C0n0nJMO3fQ6nZi9itquxNSnuvmse54sCWpvmB401Nkm6yfpINsyi3I9ExMwHBUAYGI6)E3eRel36En21yV1IqurthyyqKlquHr1yjctec9QfZhZvh2d3hDZvxZ26lOiScXZy4fdhwHMzmSh01C5lvuhSHK1RDryluYR8GgyHpviSd8nDvEkrBmEAYKsXrb2eJSCwyu3ISwN5UkcP)KoXKhqRMmPCezNYjKt5MPki6vDsr9j7Md2TNQ)8Xe6w(O2gT0QZYOrZPdny08ISJeu8LrqG3JgT2wWs0ngn3psb8scZMAHk5DmPQ4juU5ARdUMIpyZgy1bUgHnHyizy3x(zllelJbk99rmeszE(q3AweCFA(vJEkHvJrXeSVh8AfApA)k1QnRwuqMoZosmoTQDgQr8rDy(Q0uYhQed0eu4JouieFxDZ6fIbC20Ufpse2dgGqEoRJJYNQsg)o(4cAusQI80ww4zUBbSmVsfvXvt5ozmhghbVduLfovuBLXoQAhCM(P3BwdzJ83qVxkdK3)rDT6i0LJC5tQwAzrLP29w5JEIlrk4FuX1xJYNsl1bMCuAYqeePVQGwI0UQyMQAW)c9e9PJ2Qk(2eJvMhWms4HAiC2wR3OLXjE0DZ8HkLOS()QPJVM50(OYlUfWyEOTvarjZT6aC67FLr0WXrr1k5bgyCYwwrBjnEqTymbAjKVrhcvjndN9ZAB(lhjYekvkvx9NcPYakZ(JcBfml852FEjyXy61NnzC2KH(DnNnzK744XZn(c2SHcuAZ0HQU8YrYSHuBMqEHlDwqQztjbIHqVPMomzDy2SgRNFyweWN((jtgigF)zFq2343nrx6lwU4EyeMYEPRJmlxpy(DGo5Udt)5x53j60CzT8VsFLyr4U8Rxnz5c3iFcmYhq)LHQXD5cbdZm6ME9uxUqOuIxsOqYmhFBhXr)8YmMX0RKyArSLwLWImoJFc1pmJoVvdDYwuPIenSUIzS7AnSRuDgRJVMQ3ygdENzg4VtReL0cgn(lAOHqj(AByHVHqUKGz0(9gPnRCJTr6Sn4TVUL1u4Ymy(bTWml9Hwxu3IYmMHGPt0bH8spUpHq(JuuPZC4jRNrXKM(6(rm0v5PNxyX6X8eUCbpSzmTbmUkRRPwCTwLPBftzbFDDoWv2MCrygxeK1C1FIqnYgIgXqSnsIHSIZ(tmQqUy0a)S3lbDDkHflZ6AkqQk3AoVK1hxlQ2)1ATWGw(BLgTKTg0vsG0PbrwQbB9fH9rzOajLedzdpDLyixH2cAXo(gjSiBDPRWsRRF7JGp7Dfr(mzJs1c5ka(Xs7UFRTBRcwRmNvPTPfqydk6B7BvNjBDS4rgy1iE7fStDTI3xflEnQwC(yRSzBDUQWRq5wpmZzzJ8nXGIJQuS1nQcZ5OvNvvE2d7dOY5Qw)DepczpXBzlJD4sco9LnzPJ(c1ZEd4ISXiDC5yPUlYefXRG7EUSHcDunVk4RcrLvsRJOIfiFvORSEtD0TuTZxfIR)8(Q6XrL8s10Bs0ECs(w2zPcW48vN2dXdqjIMoVC75OqwRWr(vKgQlO(6nCix)fCaO)a4YcrlaG6AaIZF9hFwtrQ3FvP(ZrzQB2PE(XwUs)rZppeLe3JR07Xq5c7VXv2FNxA)MQT)UQ4(R4o08egWgoFR2yRPm8E5Iy5cCVpVMaCKkBYldPQodyJU)aCUOZXHsNDthb0foEnhdthzQZjER5vrW6DrGcac7BXz6NxLLNZLY5CPyKbNZLY5CPujiK)OQMlflApvO4tgwQtWcrrguYTEQo1f1IR1kS(1jblef5nPeWlMSI(d41nTkefzlPe4pMQI(d4vnrkKN5CKKp4ieNZAXPtqEtikYmsgULsdrxb9UlHjef5djxNJywl6kOxkjjefzbjdbhJqFxX(2NxeIICF0s8QaUNSSHquKXJwVRRsB68ABwqiNZZHMLgNZZrncG)58CuDE))M55WYiO6quqSh7DfXnW2zSfVDOCjop8OcaQchKUR(GgCsVe29)nNxvGvS59q7MsE2(Cg0DFpdontlwDQtWVO2nL8S8Xm4eVrQccV1PeI(0PPqZMwv1I3daX5hZ37N6CpYvTRwGpv)IIR1XTcjPYoNmFBXvFaBrwOVIkFoVU414(IB4cJRX)sbXNz8nphn1yLwY1o08sSI54s7lTKDmv(tN5qPLRCUHlqytVzjSEv4geA8ke2K7qyxEjcBXTiSfxJWgEpcB1fj08fN6eEvcFXCxc7O7FUTb2U9kPz6gO3Hxb9tRqz7sO3H3c9tSGvH7HUQZlOTw3YT29CByX2nt)SLLZwwoBzPKLLAFn1Tn42T6RSDr174BQ(Pv4SHvRwAEXlGv86QBkahbQQFRgBFXKfe2TxVPMc6IRVEIVDAQq2A4OxncPqvkbrZwvB(xrXt0NrX68Du0sKsA2Wx1)uj2O4RK1LczJSsraSsXJPCtemtiFci2huXYFrf5RRj8SsSLvex)t4D(b(hUD4)i9)POZF9Y)7]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261120001,
    [[Hekili:T3vBVTnos4Fl5lU2x7A7yN0RxrCb27oC4EPx3dRlq)MvOLOT5AjrdjQKgGa)B)iPEXuuKuuVy3GDZh2DDLOM5zgoKZmCg2D11R(6QLEacC1xMnD27V(6ztNo96vljpDaUA5bG7EWw6pcbb0)9FhgGdX(4TpD8(HpIFmgfep2fhmInYN8Xapg1wNG8j)RWvRvs44dq3vl)2p)RF(x(B)Np6vqXvl3H88GPFgm21a3(4X7j7GhVp7zt2GJGpaJoEVhCdiXNC8(F()95J3tF8X7lrKe0eg7JN8iiYh7UFI3H4jm46fpHHeNnOiOZ6iqO3y(Jh)BX4WrVJYp6ZI9PsJh93yg)rXhVh45HdFd9h7HpfpMYmab8rf4A4)9F9vkr2rihI)4KjBrKDjRzIYePHoIstk8bRNUz6u4nBC)WCkz)m9v(OWTusGtiEyMCDiX3pM(akuPYDs4wioKcKKyQEXhcIcziLkSPJ6aKsvxqem)l2bb(KD)eGQiOFqaieC8(iOlMIHNOC8xI8qHGONY4dvxcEGXv6OIda((hVpmjynt0WBOIn(RmM84oKpKbMiWA2piGOTqc9J3Y4ECsmbG4WYdUozZMmKWXiLpriCeIGGm94VcqSHbcO2ES5rFFQAkBs)akKtKVH)2sQMR4lFAm1imcVHIHvlbUeevFm(atMcwdilsf4ycoe(oQsYbVzJZwxVfx)opu8bFWtoRHuUSy(03H2Si9J(00bzgkohEa64IdjWVto(VRq93UycJ(0PiNdy27mYIB6ali7C2Kqva(msK)LPpXjgSbQ(l9rBGoeWbXpYfe6qhZbQbqbeYhhNudywfJ3HUB643F7FI)hcaFxndItcOlZCEaJ8Ee4VhgjZP0buWOmZ44bX0LMgjjkOcQtFJ6VIVFIdikaxbc5clZ2BSW4g7HF0i1I3Jc1rSRs)Ss0BFiLGISHraoxgmu74FwjSgPdxaQHGlg5R1skDXxXJGHBPRL8gqWB36dP8zdmmg9amUyezwxudun8mIU6LBHCo4zXJoXgh6)LUR7wn20X7aunKZASpP0Kt6kOeGFfCW1WzFgB)Cx44KdQjUBseFbSdDlhhOpmagsITKnxL)G4D4iIdBd0bXqcHU7q8yqCmAlD)lhohw8MCA)MbPBkowjNnyIwmE6Z27dJJdP)Z5aPI0VkAfFRnO9riy)5cP50UkkZFJbeYn)OdLfjGLGRYAbawNnl1Xm3jbqAhf9eVy9fK4q3AiBjgb4tTls3Ua5MfXcmK531lxQl)YiyaLPX3nB8TfBAjcNXWVdDtykunqhN43eLsgeCrbaoVsoCIT5KQoE6IJIsoW9NAhtvzMKBduqRcvXIm8i8kxqmPaNcpVgGUgeYTVaBXHp1DSwICsooYFh19zqMNdPVI)gdopquVNSiz7ooZPufnAXlkPplEAnAZgcqf4BOplI57UE6ZkMl5kTrNKR0LuCNqYYfx13u43yRwRmAlbfvwMdUQqQhuv00fibF7o2cY2J1kB)vk4oHVaer3IgNesUB2jT)J0nN4Op)bcXemS83(ikKQfEU8dLI5GTnjbeUNrYHAM7vODto8S8SCPHw80KdJ0OkPAemrkU)2QtBqu8gw4ouwhxLrJQo7PlhG5tRlhGM7CZoiko3ANlW(kIrRWxpBoOMCGec2bqia399hrl5t)QQuP(TNVQ66JbMi05in8ZwY3nnL7ZuI29w61njP6(iv6xwjqF5sB(LrYYsB4Tb7MeB72f1KQS2eKtzYmlzsJsQRnjkRn94ZioBBAYkto(mIZMMK8zi1y5ygAM0wSwY6Oc6TeJl56SflSAEAXLtROzkQlysXvsfU3qAVNsSyGm9gk7VeIBp8uGUlD6WDXA1kJ1Elz4xtbUJPa3LmDuOjRnw6oMRw3s39fAsUxGuB7Y0Sir6R0yPKI95icmiUkHmLbAEsjuTzusLKqR)Jda)goYHzAOoBZ6PGlW33j9psT(IjVJ1BflIPtb(qNGeFckFRQ0qY8XBrUwq3DqF)8qZypLMJbmegGGXFAX888kcWpWJuoDNbPHW56y6ExXip4TJmMjVGREM3vXD53G2UJ4K5c8tkDfNeXd)PooOl8WHdVszSC09WQlgVr1eKhnSIQQMrplRBQv5yCwoB(1dton7wMPlUUDmOK9Jb6)PwsFxm2N59noDAitvwncSbdnfE2WHLSr(PBhnXKzYO7UEKXW9Us1xZ8tn6ztyuZx9S(1gpIi7qH0P)AN)Rz1yjYvhTuMSXq7muvLXr5fO5kOt5FWcs9TvEkjcqJOYHGcGJmL0sTQMYhdZqLRhtNxv9gg4(ujjOwgkgjXqUx9dUSvg3n)wjDX7NwlXKJaOUHx2ZCdqQIHEArGazZ0vC5IktkgGloMiCm114QzH6Z2X9j3IDUyMGcBhBXH2qnwhAXWmE2oflnzb0Q8evsxw3hNnJsEvCYi1WhloBf2Mt0yW0sIqm)hVzK9ZBVv3PD1MzUYQk2SNSYO0utnkKMmbBjK(98SxX5)1MzUtW)soRDjxwAHO3RZCQJPAH2t6YyOp6cvzG8lspPlQ36Yo5V72ArM4zhzWcAOQI3Pm29thauEC72f7HzFP6rVWHhzd(lDigQLaXZoQHYqLvW)WmemMxv2bJMhXCTOwZbm2bJIAMT1Jd1NvyhNEf0af5SSaMeb3dQMXU5Cv0(oZj5OA(npr0pyoFgdPZOhm6tcsHQGL(Upg75Sjj6PxakKRV9LGgbs36pIDWP)XtJyEXROwsobOlTek5qCX1na7LYeSTtPMKPzZAR(F4W8m4M9(PthiMM6nZhvnpvns9QLpqTIPSx6AxXocNy(D9k9osr)5x439RSttE1FL(kXoLz1xMpD1s3iebgHa0FzOLzwTuy9cJUzxaNvlf63NvekKmZXB6joIk6figtNlX0YylRvEezCo)eAYhgDUrdDYnQurIw28pm2DRg2vPzG0XxtnfeJbV3mdqbALO0rWOXFwdne6dN6ul8feY9TdJ2FWiTz9euDKU)AUinDxedM)fTWm)yUQ1OUd9cedbxpvhek6pOZjekEKI2rIdp59zumPPVqvCfVCRijySE6CUwTKh(iB3agxL3RPrCTr9sJLjkZTRlaUYXuicZ4IG8oxNprOb5GRrmehJKyiVX55tmS4ea0a)83lbDDBcl2lunuGu1tuCEjVFCJOAXAzRRFCxBhkH1GcVxs)j7FOrYug8SSzPeWt(lL2rq2HsJaZ5VnQeSklERK6u2xtFjb5XJAz7vPV)QojdLizzXyMS)Q(sm6C)xDc(5Vtc5DYvMcGFQ1SoV9MvTcwN8wA1sJU20w1V8yMUi9p1JxDxWU09615QzVAq3EX1TYoX1L)fVpH6SAMZsDoFnMWLHnoSPLNAvhIXrR20Pk5D8mGyrBb7C9ZXRUu3kfrD)dxoVL9e3JgtC6l7Nuh9f6hTMZL5YUX0XLIwvtKhko9gorL9WOJOIDXMn0vEdED0TsdUzdX1NOIQV40g5s9yu6Xu5K(x2q1uWuoF1DKm5DFJisyV7S0tCCKiVx1j(2T2HRAavSpPSFV56ZCWqNYDUAvo7kdOnzpmxF2dL5R6ULRz2zYfMIda9zmij4DbaQRdkN)6J3V11CO3B(otDFxJphDwb(BD)3zP(UOGamv8n6o7ml3cP2g5JZe9PnOPn(EP2hF1MK9nY(zo5Vs1XHAQ7)6s7)XHIU0buf)yR6lqox05dsxCF6OJ2Z7xD8y6iJUWqvj0nSfdRThdPaGW(BHTSll(QxRX0R1yYidETgtVwJjRGqXJSTgt1S7PIn(KHL6cpruuzPIOouxsNgX1gvUJMu4jII6jvb4LlIZ5d4nTCtefvrQc4pvcNZhWTTatKFW1oQUGqSGxfRCT(yL6CfLikQyKI4nBKy0WIiruuNOclnHZDUry4cu7iIIQdLJBPsX0xqV)kAerrnHYb)P6v0x4U7vjIOOsqDeVkG7fR2qef1)PZ28wzY35AcrETQpAmnETQpnOOeVw1N2hNSvWLZ7FFw1hJbOyBvEm59WY)s2l9WxQRQjkosM6sFr8k4W1JfNrVaiTihL(6oGErVTzVqUhHQoyRkZBszV1T5TFy3a0(7kG(cAUR2mVfsETBZB)qU)Nx4LKwi89Z8grF5bvSr6PzhZvG78E1)0M3xPwLsp075BaOkFBLkYB9iPL3aq1jXiWBwmgf1cuX8PU4hsVgHLHQHP72xQwv2jwEfcnC)WA3fusLvJof0PRw4pyLuDxXSZIws2IwRwQ46g(hnTK2AP2WKPU8ISDx(qMS0K0yRRHn0RJnjJS7IylNF6LlJy6oSA6ULlQ7ZYtA3DB78rw1pMDHQ1bpQDRfRmf3P4X61mPODEJTws4wneEs67yf29Fc3J8rhVF4)i7)f5XF9Q))]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261120003,
    [[Hekili:T31xZnUTr8pl(fDunxKLLTVMCJLNjTD600MM0jkZK3enmjKeJij0qaAhpJg9zVaG)rGKaGaKuYo58dT1hjXU)2DbwSl2fQlVA5VSCHpGax(JZMo7txD1SPtNE9YfKx2bxUyhWBlyn9pIbr0)7)betss9ibO4dp48m6zCqeEIhkAm7tFjeb8zK7X0GqY3hV8rPugVd6TCXV(D)8p8t)9)ZN9psYLl2e47dZghe7PJFF(WdKnWdpK)SlxHsGpbto8GpCfinKC4HV7)9dhEG(4dpuLkPbxYqa(YNbjHiVTx6VdFjdX(4l5GbnH)VM8Byu84ps5tcighsLdF6FJy8naF4bGVpk(d0)yl8f8ektaeWNLGhN)73)luISHq2H)8LxUoGSj9rMiCzTpDmLMuydEC6QPtH3SY7BUMs2FG(QWG41usGsj(iM8SlnmetFaiMIi)041qumfiPyQ(iecsIziLkJzF1oiLQEGeyXi2abHKnFnGk)0bebIbhEib6HOy4fkh)Pe)GyqYl58HQdbpX4k9RWrGWWdpeNg9it0qROIn6xym55nbHqgysapY(dciznKqh8Ag3XPyciGdlF4JPRwLJeogP8jjaLeqcGm94pdcyFgiIoTJz)cdPQPCJ9UGyor(v0VUGQ5kh5ltOt)sqROyy5ca3qJNSJjtrpciZZeymbfd)ivj5IwTYDTN)8R(OFaExi4f3hHuUm)6PFmy18SbD)0r5ZpC39e01dftG)o5W)Ub1)Q5xYOp1e5UdXENwwCtpybzJ7QuQciKrIIrM9exmyfu(iddwbDjGDIdYde7s)MD0jaLqO474KAeBwXKnb3nDYNU9VW)hrGFxodWPrrOy3Nqb(pdc3ctQZPSpOKr5tJXJWOqKwsge1a1zVr(O8HSbbsIqnGqHWYM7nr47M4JEwl1WBdIvrSlYgwf6TnMsqr2WiaNlJCu(97LcRXQWfGorWdfeQCMu2IVYhbJxtxl5pIGwVoes5Zkymo4jiU8lYNDrNGQGNj0vV8ziNcEw(OJSXL()s96UwXCA8gavd5(ikKuX4KTckfe2ahCnC(Wy(Z9Gts3jN4EPj8fWUuxoUWqyemMGnKnxu8a8gucXL5aDegsiuVd4jamoyn1)LlNdZ)qbT)WOmNItKYzntrl)E6Z2gcX4y6)5uGur63eTIV1e0(meS9uH0cA3eLfVrdc5t)OF6QGeOHGRXAbasXC2hbXCCSHUBQxT9iqudEs(si6)0mwltV0aoE04bEI6QYHbj6YuFezsfKC)uf(zOCEviyDcnUhdbuU7TaQhAw0s5(clD7v957DYnqLpoD3iNMI0EciKUmOyTlnSbxkSIGtOlI3o)291PscmIAfX3n)6XJvizfFRHILsouxU8ayYOgsl83HEPSjRuJqilyU7U6O5jZKZCcQ0kKKKUJhwHzOv2SIILcL0QHmi8QksHWZlLd9tVbRrXV0FSwHC12)S4D0OiIYNmvBu83OzpuR1QgPu5OuNMBuP9)IMta0TZlgLg2DK2WPqLiWegbiH6hfLgtUB2re(mDjhF2BXde242P6yFoiMQd2x9H1cmGMnc9rXBzK0PPUkZNrtDB6U9YDV00lIQL9uncIuZXRz6ujULgLVwE2098OJ35XmI3D7TQ4U0WW1S0WPU(3oqmUPvxva(xpTTa85UEFmnX0vlYwxR3nUSjH3pFMc)3XE0CjTyJPERmhQOqpzaPJZSLtoqkb5cieG32HJOmxyLbwDrtQ0(w1xijGbDe6uK2)jlzFBtX)eLy)GLoVnjXpePU)2kH9ZxA6VnsoVMZWviVuSPUlAj1CLjKNXKzgYeRsISljMRmD8tio7AA5stg)eItBtk)eKk(Fmsa)pBPDlUdUDZVo3jDxnPq7W6zmL7gjApyiDWt4UpAuJuOdu62VNKDptYUpjGyz(pTg(7jm1R(Lq9BJ0OFDtE(voL5(mpvKidv6XusXgEabgHBsiDz2wKStGNBsAJKBBFWrGFdL4Y0uYZITDk4bcdDZ(N0LbyYhzThYCm18ecDJsdjbfUAZc1leToWZa6UbggweYxEatWyyuaeF)8RlYxjc9epc8ros(eoxNqD(Id8H3ow7jeiSBkBdmXnPwfSEdXnFp77LUBxkDreLkMYHSWoBgOzDH4k9Xk2QeP10KBuOe(OjPk)NFv3yqfJUg6FF70VAeWoogVN0(leZLS05OB2dyFrB8UQp62aQufHhcfYcnbxb8ndHAKJU4RCCQmd8RVD8L6Meo(URgRnETlKnA224J3RdJkg1E1R8EoGSjiMVHz)wRxHCTrlmeKWpuoq2P)Cm7NYT7kuSnFbl87VQ5Jjj0e3cDjbrWX3xXA0QOv9WFkbJikZHJS3WWJLmumyihXTaV(2rvDL9PPTsmzPS5OwJQkvn5kAPCF8ijMLQ2lHihu4aOgFfhaNXJvhguBZUQg1If2cjF6XLPnePSGxOwnzIaIkcLSzslB1ox(zM59Ix5MaSdOtWaBWHH5CHJJbFM2ZmR05blJePNuvMXDioZlP8Q8eNAHpgCMvm3N0nRvsIye)p(WyZTBFLQtrSlwUQQkM1RUYOIPPffIngydH0FMTELNRAxSChH)50QDoxwAGOpOwo5HNoheTJ6U(LSr2mliTHOPkKkTXHPlyRlkcDS6ltGa)xoAEKmWk7WFN24ehlbEzh5NCHk7DsLkEgjkgw27ydJnOJr2D3TTAt0DeNDZEOsMoNIuzmvACh4iRc3steT8dktc15IMHKpEF9SH1h6NA0lCqUMG)khPOCjq8CCTugA4o26v1xOET0E1Rnyzk1LPFFH4oqCyAp9K8kmCecTAqpJUeSb5MGBP5s1915TSawnoKxkMEUIvqduEQhZHPjWTazR662YaTgyz23Ij(FJ(LEkMAmw7sl1hJIevbBABic57Ukn5L3akKRU9TGgbs9jNWQm1xEAe9lEf1sYpcgBHApfZAb6m)Qrd2Ha9w4uGQQWRCEqV6AAlMQu5O)66kiDY0SzDD6UJtXbAn7ttNos8CjV5Bh38Gjvi1lx8e1PbL91UhXSZChZV9Yzx5x6F(J8BZmmMDju9x(3OVsSHmx(JxpD5cVKacmjaq)lnDM5YfcUNy0n)ELUCHqBLUKqHKEoEZaXXGYwoLX0RRX0QylVJrfzCb)e6LugDUrbDkMujJeDShtzS7wfSRrpNQIV669ugd(KEgeePuIY(cgn(RkOHq7E2MAHVGOE7HYO93OL2SwpTnsxSaV)9WQIMyLbZVvjmlQRrRtQ7rlNYqWvtvbHY2q9ucHYhjPRx5WRUFgjgn190axXxVJxfMSECpRLl4baW8gW4ADFnwXvzTtsFp3q(86sGl9BkfHzCrOUNRtNiyXrsQqme)MAIrDhNNoXWGdevb8lEFnORYjSyl3APajR1B58QU)yROQm1uN6Vw17Sw5lxUqS7mkwZPA7aH2uWs5QiixZAyxJ7y32Azx99SlxwRV9KvILsYxxU6xl7E0cum0AZVRV5LvcHS5CnpaK(0lVIZGkEBvjyw99(gkjOy2UH94R6M8T5ciojRjg9ApsJSdCrqNYwBlaBGLO(gUvJcH1XW9xSo3Do8PQ1HTO3H5626rcOYhnVPnTunRVhrB0KOC80PCH0So0YgxDG64yUOOmpRY2BZwHrc07uRiZHNQS0oEim2cVERR54s1w9vci)1ay13xEaxQWPF9TmvrFHwF2EUCD9T1uXLYUIwKhsoziorRVjJkIk2W0Mq36E(vr3g9sTjexDsqYgXXTPQ1WPzhbMB2pnFT0BkC(QYfxrRykIK84Ph(2VMJK6EOoY3(151nJmHnKQ7QFT6SsQlsDPzSTj7IRR7YrL(xEBzB3uJ6LfKda1H83uv0zaiVXc48x1rnPi9kB6g8U1o4muDJQtFs(gOQOI6aG7C1Sg8gdxxNHBDjd4AD1Uf03B4goxQS2hCvSQa0n0JwRnzoNjQoTDXU2UI1vzzYoDTFohOQ8Vl)CBlHPK(sVpnMohkQcbvw00DQJ15CrJNCngbllwPL1QCilw5YwoSJBufYQ8qPvPgvvwcfb(QImQ8LlZMlHg66m(wBnEkaiSFeyZ)TJz571c89AbQLbVxlW3RfOrqO8rMwlWw8EkXXxDyjVaHejvaSGxkk9MvC1QYsztbcjsQ7xdGxTyBNoGBBzbjsQ2xdWFSuBNoGBAHajVxJV3RXN514RzaMwjONRQ(rKuzVJMPJLVXkWFgQ2hrs98QpZmV4zdf0hUY8rKufVER0nsN3Zk7rEV2Dn1DVx7otHq)lBZ71UZy41BDnhxVx7UwO)Ww7Usux8Z67Y2pFOg1QtxOhg(R9B2X(0wTVKCyqTL4K41CKRhlp2nbqAq2rd1pAcN1RN9BKlEVSJuRHDRwEJ9ZU9Q9tMWW9BMWBiBxR58lK2C)SBVk)GjCMxsAGWpm2nI6kglXrQY9BeVe2IgrTx)AT3)A9xa7UDdS7XvW(mDhS76LW2YBHTmNTcgTUP5hK7zTYeMR0uhQH(aFDRLf3sLAY1os641TwEY3c8Mf)yz5XTyTA2D2Uku74sg9tuKnpXW7RTMlJB3UEIYMWR8melVh3VYkP2UGPNeTKPz7F8UD)LMwszdkOXHQ1aSVsNn3NBB7rI3YnjHQtur(rw8gWUOC6KQdFrAt1051D6Kr2LbVJlrgKBdE2MCk6Nql2XtD0PDlqNoRS)dxiMI)gzzZpswN34lhoy3LGpB6pYS8B7rOQJK)RNLz)eGjBRQczOsDEStk6wyUgljCFbe(jBUH1ho)l42GWGdp48pZ))q15VE5))d]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261120001,
    [[Hekili:vVvBpUTns4Fl7xCSB3ZwR9MTTb7wGCxrXLEPPhIdq(MKPLOSzTKOGi16yGf(3(nKwsMIs0sYwE7veKnA5lpZZmKC4mdrSVZ(l2Z9qCS9NMAn9H7UBQLL1D2Z57IX2ZJrUBqRGpIqHWpN)77x85us0(fd3s3YiHSXU0WrIXTlGI8eyTmLeW)qK9YAHLfJDTN)13)5p(h)R)Z7q((bexoHgzpFnXZdFyAyMRrz9U9l4RX7xK12eFAc(zCY(fEyFuAaF)I3)F)4(fqZ7xOarkzIq0SjBrjbu3nt8Izteu1JnHf6KaJAS8xh)NmA0OBbPKGIybGg4bFtfsLW2Va55rJEd8Xg8o249l(feh9UAyZWF)dFbaznNhZE3KjRi81PlfkWeTHocWeinAPLVLf(EF3FCga7hHUcirRaiOPCpQqBItdcyqdOiGrEPrRW0iGiPmWAeGrjrcMck5HrfJbuDrj48zSgJc4R)hiWaatiefH2Vib7sboSdK4FK4rIqj7YKdybrplKkmkwikiy)IO0WLcvJ6dQn9lcHSDnjalitcAP4dokzfMdtELq6SughrK0YdVm13pJjsocYjHqtiCcwyh)mIiggke2Tjw9ccaZu2sDmjscYxPFDoy5kM5UXWgVeQpWb75i52i2thutgNgHVfmnouFFNvUEpD3TEewCaANZsmG9tZSUL4)eSGSeX)zRbzBlCIFg74sJ44VX3)Bzy(9pnrGkSC4etfTCsGVVZaZx74NcQyGyI5J)qlomKpwD8beFSdhfRouxuKtCcogwylex(4KamqSApEn5rRXp82Vt(lHOVPcllnmKg58mL4TffSbNOJ)HbuaF2Ms2agnGwdqKWkm8qpQJ1dlgkkjKwrC5QJyxZyLXn2JUTgmyBirMG4MddUekBIayubxaGe7bdno(xQLmJkZgeSy6sjbg3dC4isrt4OvWoEVbC6QvbyaDFCeJ8mMvmISDiWwRsskbozjxLVgsQOPJIXb(xWJ4Qs7gzRrGnWzjnGFRp1nLbNguxgoSFpffuHfsBz20fEADXJtJvH2nnrEiZbCb4GdWH4ioltitBPqUjVb2AAc3r4yBadZ5Wjz2yeJrwb(vCKs6P3KlJ3m4GZQX1YGkBalgf4lDtaMXIG)En5PQCQYv1EnZ1Ty0MRnpZLrvoM3tf(j3SbdWNKGBjLQSZhrlTd1LMKKglDAF56AUIuG54eCiWz2JpL50qPlxeJx48rPD83WUPctMknxIIKMg0kA0U(JPLGvZ)wEFGF8WmhCAZs2tfFCms8AAMRNEJOkGwzxbbU3qehw)jTCeRS8v0rPfVIwRDP7mPxnSByGiQVhVZ6LA22ixHgDuRo4Dx6SwxRKRZTJ8N9XJwD6OerQ7iWGBk05bvvSrvVWJrtdoFgwXzrPWyuMbkbCJrtJ4po9OfFle8QKZ5nOCF5WYZDljc09xk3O29Xqa6qtrBeqo0W6Dn2004x0xzln0IwtJhv(C7AkLRf565AjBmI0tCSCOU9Sk8JQUszkE2zw1hpRsGj9iV6f7PkiOuo1bX5qA2xku40e8guvuUPkmLU5jGs9GSns219PIHl0teBG78ufJNWXHSoptz83exiJ9kj418Kdr)jnXrSHP(m5AgHgdlDylcWC4ndBZWozCOWX7xkCBuB0FhCl0hXrwRSkIIRb50I4afUQgPC3wdMEtrAB2MwwxfMFDTPKTTbnQlRqTKs)DY8xxYdM1ZJY)10S)AEWOfQ(fA6vdix1Q7twTM7Kfe7p)0dwnbKH81Rnz8MWQ(qhh25CKAu7nKWXWAsDqxuQ91kzvxW8d7uwdnkc14LgkJDj2veU7JZSguEb9bRgbtloNoi6Ag6XCdvGnl1qjrbswZaCPGwV)3SN)mepa0Pwf)dimot(idhkqp85NKp6aosu0yp7)j0LAfuT)0ml75Ujq8bjee81jkLQ9CLlWf4Mvhy75k1b2Mdu60s8(EsIhRrSqOZ0eAzULvIxvbNlpLI)kW5Ed4KVEwheNzrHfI7TgexLIeBsUNQyXcb8WPfaj0OgDyecm(bdyOuF2Mml1wpxb2)4jXwuR4MGU)k6SHQolO5pzKM5vHUXn1xqnIfm4oltuOOUXxtku0unLPwspD)m1SOzoJWAVvuzZ6rxG2ZLxxi8giKQUVMoj1ovJ1wgsKCFDbXRDmfQWuPkO7566PcDiAldQH6y0udDhNxp1OfX6zG(59RrDtoHvRrEhvO6QvUuw6(J7eQx)cLRy0k6vZAPFBqFPbDSa6MRG(rDOeKAQH(fp9LAOxEDfVyh7rJl63U0xCPDHrFI6xFK859vM5t1VuQtmVgIFSU8x3cZ3OIDrxN1QJPxAf7B(O6u9BhlhYGOa)xUI9AxO)RvL(7qP(L2w9RTnLQIS21xSzwkYZk3Kt44OnLH)SEEajBnMAJAWC9pHLYw)w2ECXrIV(DGMWx5nhodPOFfLjPC45iufqnvCqIO(fnMq84lv0cuNPFjGrulEeJ2GQUhytOw8(gTbuDpIMav9PpAdUT1BqLxfPnGBo06280g91lG8QwP3)IkcFNYCBMUhU2SU8x2ZJ0FVpY))S2yoD0zMZZQnpIWR66YR6XQwO89ZAt95ApZC2JT6fwQMBNiVpnzyo1Uw)6lTO2tZmN1wp9YmnhH)9MZ)Q3EZMwKa79MZwQhErNMYv7EtP5uxCXN1ZajLIPxyWq8SMGPlbX3XhoQXxociG4pIWsxlQz))gVHeq2Vy4VM9Fqcz32)V]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261120001,
    [[Hekili:T3vBVnoUr4Fl5lET7TNJJtY2TlIxGRTOOx719koVa73SmJeTToljAirLSbiW)27qQxmffj17ob9YhU78kjoZZmC4mC4mCVvxT6RRw6GO4vFz(S5F4QRMpB2SRwTK(0b8QLhq27rBHFeG8H)9YDihYJhx)xdrbohxp(rYJrU(rtTj(tyF8tEeKdJG3h76r)5Gv3RK2rhW2Rw(TF63(LF9V9V)Kd2Neq8iBFA1YDUoo4KHHJSnZWpDCnDh(460ND5gsi(bC4X1o4nOyp6X1)0)9xoUgE8X1Y0j29sgiIU8ruOhXE)LohIUKbANOlz4XkIpaR7zF)u(lM(7rKGjVhyk8SipqQacrjmq4gDCnYXHe8o4h7Xpfn946)oII(KcWn()8ZFfiYok9q0NU8YTU0DX3ZKNlL(0janbzaD)SnZMHVzJ9hVgi7VaVYZnylqcsm1HWeUdXEErWd4IMtCWwmjaasCeOC8WOWagsbXn5RoGbQAJcXzJyhg5r39JiqvadWhfGoUoeBtam8eWXFn0Xnaf(ukFafk6bgxHVkYh55DCDqS)9mrJSbeBYxzm5XDUEygycr3Z(bffUftHbVLX9O4ikYLdlh89XB2KIeogb(e6scDPUyME83qUSpd5dMHSjtppqnLoZFWnGtKVr(2sqZLpYNMcgJHKnagwTeztDb9X0dmzY)EeDrIahrjb43dkjlYMnwBTDwC17DCJo4HEY6EmWLfxp79UBwKmOppBuQPI1HhWw2Kak(70J)Rsu)hwCjJ(WuK1bc7DgzXnDGf0DwBIbfGhJezJm5jwrOny1J0ZDd2IIoioiBuGf8nhadGCiK9DCsnIzvmDN7DZM(HB)t8)Gp67QzquSpSE26bIRZJiV94qzoL8b5mk1moAue4dWijD9lH6K3OEuC)kwOqFsjiKjSmBVPcF3uynVrQfT3nqhXUizyfO3(aGGISHraoxgnw73)SsynrhUqGHGnX1tRLuYIV8hHd2cRLCgrjB36Hb(Sbhe5(aok)lsTUadun8mew9YTqgcEM)OtSXc(VGx3TASPZCwt8OfMCswbfJ8kHdUgoDym)524PXhutC74q(cylWLJf2d7JdOr1KnxK9GODKqQfZb6OimLcEhIMIIIC3c(VS4CyX7YO97gL4uCQsoBWen)7HNT3dhffa)ZqGur6xgTIVToO9rmA)qH0mAxgLzVXac5MFWNUXnextWvATaIOZMfcmZdsGK8OON45RVWulW1q6smkYdSlsCx4ANUJfCalURtMux8LHyFGPr3nF6T5oTeHZu83X2XmfAFTClfJGd8qyBfowcuihQCGY25dS1kgIIpKH(0V(HyVamSFcxpweEUp0C0lspZG3MeggFGhyUEyxL9wMXuoTY1PlsrKWRSrr0CKk88ka69OaUHkAlj4PUJ1cKtkcu27G4W(PHGKgf)ngIc5cHHzBjU74mJsL0O5VOG(m)PvOnBiavGVXEmBZ7UA2ZkMl5kTjNKRK1M8OzYYvbd36c)gB1wlJ2cqrLL5OlYL6rLfnD7iH73mIe71ESwYpAHDjkmcui4RNehqVB(jT)JGxoo6ZEGWMlgxCSp6gaAHNl(qPnVW83srb7zKCSM5EfA34dplplx4tZFA8HjAuLGgHqLsGOT60gKoGHfUJL1XLz0KYZE6sM46zvLmrJd1ule2ZAB1KdftjwikfzVV)iQKc5IY0PooqUqL16iteBisAEWsvUPjipqPf3Bjd3KuG7JeFFDLU75lj3xhP2kTkFdXooQUonQiXwTPZMWK51KjnkfS2KwR2KzhqC22KAvMk7aIZMMs7aKiRC6RntAZxlD(tJTtlTEztITym8MPXpJPWwkX1EdP9EcSIzf2BOS)sFT9Wtb6o3jV2fR1AzS2BPU(wcRDmH1UK4KcnzLBkVJP(1TKtpdPK2f9Pir6R0pbsXgUlf7hvMqMYzmlnciIDyCP0gREW(OFNeAXMduNFy1uWg55zL8hHP5i67zTXWIiykWdB5h7rDZ8jKSjkpYwx7Aq3DypVSntXEkKvaoa77IJ(8IRZYeWh2LaBVTjlbL(eoxNcojICDW3oXyU3cXuzHXeDNUXD7oQvASMpRmMxCiFRivXbDBOB84luU7lWzrv7kBsfBldIFxw1m5zzDtLkhJZYPZVoe6Pz3ImDXvTJbfSFmq)p3s6BtiESWCrjtdPQYYB1z0yt7dA84c2i)4TtU0KzYK7UAIX9vDHQrZcim5ztyuZOEw)AJhDP7CdGP)kN)L8ipULBup3qx5w1pzVR81zM9zQarEY2X3pO45q(5a)TOU(4jtmNgqL6Gk8ivqLwfT06kqfetTYAPy)5cgNvkLfphOXkDVKaivVHbOgYqXDGmMVBGd2Sf63D9Srf99(HzvsSgC2TsSwXNoYWSbhOaivnPqIOch)DfHcxO(0ISFYo3Zkl)zbBKACmqGx)X14ZmEAr5Uoy7Sv5z0K42PpoThL8k)SwQGp140AyopH9iQLebe(pE3K6pV9d6o)S2mZvuvXM9KvgfMAQqH0Kj4AcP)FE2l)efBZm3j4FoN1oNllRHO3RZCQ3Z3cTh5LXTMPBRuJKFrYrEbBrPyK97UTsKv8CymydnwDjbvMFH4XWKLDrFSvE9Yq(bHvhjq4ykuJ)tNMvdrFPvWVygcgZ7l9esZ2rFLOw7H11rJIkMT1JgvN7zhMEf0a55uTahhI3JkFIcMZLs77mNeMQ53Smg(O58TmKULEWOpjnfQc2Xl4riowBIdF6vGc5QBFnOrWGR)q2jO(hpnI5LTIAj5mVBki7OakfpCXvna6fYSRTZOMKP5ZBR6F84Se4M)HzZgjM25nZNuoVtns9QLpagXa7LU9vStykIFRVsUNuWp)c)wGLE2iR(RWReB9MvF56zRwAh6sXHUi4xg6bNvlfwUWOB69Vz1sHgiAffGKzoEtpXr38MlIX0RLyArSL2BqImoJFcDneJo3OHozgvQirl7Mig7Uvd7k1Dr64RPUmIXGpyMbU(ALOKVGrJ)SgAi0ypvPw4liKBeigT)OrAZAYOQiD)1TsAAxjgm)lAHz2XwvPrDhAUigcUAMoiK3WrdjeYFKI(BIdpz)mkM00xhnUIxU3MemwpfmA1s(ohzEdyCv2xtJ4AJAoNAMNm3Uoh4k)MCryoxeK9CnCIqdsbxJyi(nsIHSJZHtmQXbaOb(zVxc66Ccl2CvnuGu1KvCEj7pUrunFT8zR)Qewdk8Ej9NC8HgjtTSKoPYvl79Q64AroYuJKQHVVSemVZFR08ICqR(scY2yBn7xl9nS1jzOajlkgZLd81xIrNBORtWp7DsiVtXeva8t961W2SxvkyDkSBTwAuaHTOlWQE5XCDPmCQPX6UGDUBESHQ7XAq7JX1TY7gqxIC8(HQZQzol1ff3yMBgCCuNw7QvTCghTAZltmEu)dyoVLJx3JtoC6lh5uh9f6JTwWf5OB64sElUjYdfhRc)ueKJ1OJOID)wDORCKaD0TuJXvhIR3BSQrCYXOuVjLC(rwj)9buffYKZx9N5sshRiIe27gKEPJJe9jF0T2OR8guydPyCKRLD8CI5g6WUHQf7QxH5QZ26VwFQkf5R6USRz2zYLkIda95vij4DbaQRmjN)6ZaO11cO3BAptDTxJpGBwH3BDF7vt9D(j1ZvX6oxnnHbhSga8vxhaY0o3O7i)QPd2kBnqot0NKIH(qBiBlW64C6g5yEzdr9bYAQFc7sdfYHIUWGQ24zR60qox0vycnRu0rMMSl5g2BIv2CIaaOS)6Bl9URV6TQt9w1PmYG3Qo1BvNQwqi)r1T6uv49uHJpzyPUKvuf1KkJxAkguJ4AJkustkzfvrLOkb8IL)z4aEtlufvr9Nkb(tf)z4aEDlnf9fUQtQ3GvJ4v(k3ZxTOOkQ1u3xi3Yuk6ybOOkQWuUjRWjw3ir5mu1jQI6kLHBPI40xqV)k3evr1KYa)PkD0x4U71xIQOgsDeVkG7zRQsufvoQZ281YK3PRvtI(w9I0yA8w9IAq5xERErsOGt)xM6fvHgSUviYSdSA)xhFjNnsvvDrXjMuv2fIxRgU2m)y0eGznsHOVUBNN1Br2RK7hOQZDQ08MuYvDBE7f7MD2FxTZxrZDvMySqULDBE7f5EDEMxswdHVFM3O6lVOchPNMDmxbVH9k9PnBQcTUKEOpa3Rp1X4kuQ4QXtlUBFQY1rGRSO151suX8PUDrKC9alcsdt3TVuVQStQ5vd0W9(QD38ivwn6uqNUYGVWkPQU7ydIws2wwRwk)Ae(hnTK2su2SnyF(L46DPczIstYnSQ(9qVk2KmYUJHTC6PxUKHjoy10CmN1ONfN0U722fIuviS6TxTogsTB9PLHnFkCaGntoAEO4AldCRgkpt9DSYU(pX7D9CpUE8)i9)Z3XF9Q)h]]
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
