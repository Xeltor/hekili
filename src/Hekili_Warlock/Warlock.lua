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
-- share to the demon, the demon's own spells, Bane of Havoc's damage share, and future pushback.
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
    supportsLeveling = true,
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
    return instance == "pvp" or pveInstance(instance) and instance ~= "raid" and plain(Facade.IsInRaid()) == false
end

local function hostileTarget(unit)
    return plain(Facade.UnitExists(unit)) == true
        and plain(Facade.UnitCanAttack("player", unit)) == true
        and plain(Facade.UnitIsDeadOrGhost(unit)) == false
end

local function hostileNPC(unit)
    return hostileTarget(unit) and plain(Facade.UnitIsPlayer(unit)) == false
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

spec:RegisterStateExpr("warlock_alive", function()
    return plain(Facade.UnitIsDeadOrGhost("player")) == false
end)

-- Keep the PvE-only expression available to existing custom priorities.
spec:RegisterStateExpr("warlock_pve_context", function()
    local _, instance = Facade.IsInInstance()
    return state.warlock_alive and pveInstance(plain(instance))
end)

spec:RegisterStateExpr("warlock_npc_context", function()
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    return state.warlock_alive and (pveInstance(instance) or instance == "pvp")
end)

spec:RegisterStateExpr("warlock_pve_target", function()
    return state.warlock_npc_context and hostileNPC("target") and not target.is_dummy
end)

spec:RegisterStateExpr("warlock_outdoors", function()
    return plain(Facade.IsInInstance()) == false and plain(Facade.IsInRaid()) == false
end)

spec:RegisterStateExpr("warlock_contextual", function()
    if not contextualInstance() or not state.warlock_pve_target then
        return false
    end
    local _, instance = Facade.IsInInstance()
    return plain(instance) == "pvp" or level < 60 or not (boss or target.is_boss)
end)

-- Player opponents have their own priorities. Restrict damage to a selected opponent already fighting.
spec:RegisterStateExpr("warlock_pvp_instance", function()
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    return instance == "pvp" or instance == "arena"
end)

spec:RegisterStateExpr("warlock_pvp_target", function()
    if combat <= 0 or plain(Facade.UnitIsPlayer("target")) ~= true then
        return false
    end
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    return (instance == "none" or instance == "pvp" or instance == "arena")
        and hostileTarget("target")
        and plain(Facade.UnitIsDeadOrGhost("player")) == false
        and plain(Facade.UnitAffectingCombat("target")) == true
end)

spec:RegisterStateExpr("warlock_pvp_pressure", function()
    return state.warlock_pvp_target and debuff.fear.down and debuff.howl_of_terror.down
end)

-- A healing attack must not start a new fight or break our observed control.
spec:RegisterStateExpr("warlock_defensive_target", function()
    if state.warlock_pvp_target then
        return state.warlock_pvp_pressure
    end
    return state.warlock_pve_target
        and debuff.fear.down
        and debuff.howl_of_terror.down
        and debuff.banish.down
        and (
            targetEngaged("target", "targettarget")
            or plain(Facade.UnitAffectingCombat("target")) == true
                and type(plain(Facade.UnitInRaid("targettarget"))) == "number"
        )
end)

spec:RegisterStateExpr("warlock_damage_display", function()
    return state.display == "Primary" or state.display == "AOE"
end)

spec:RegisterStateExpr("warlock_drain_healing_display", function()
    return state.OnToggleDisplay("defensives")
end)

spec:RegisterStateExpr("warlock_pvp_kiting", function()
    local speed = plain(Facade.GetUnitSpeed("target"))
    return type(speed) == "number" and speed > 0 and target.within5 and not target.outside5
end)

-- The facade resolves the registered spell to its learned rank. Hidden or missing range gives no cast cue.
spec:RegisterStateExpr("warlock_spell_in_range", function()
    return plain(Facade.C_Spell.IsSpellInRange(action[state.this_action].id, "target")) == true
end)

spec:RegisterStateExpr("warlock_sustained", function()
    if not state.warlock_npc_context or not hostileNPC("target") then
        return false
    end
    if target.is_dummy then
        return true
    end
    local _, instance = Facade.IsInInstance()
    instance = plain(instance)
    if instance == "raid" then
        return true
    end
    if instance == "none" then
        return plain(Facade.IsInRaid()) == true or level >= 60 and (boss or target.is_boss)
    end
    return (instance == "party" or instance == "scenario")
        and not state.warlock_contextual
        and targetEngaged("target", "targettarget")
end)

spec:RegisterStateExpr("warlock_short_pull", function()
    local classification = plain(Facade.UnitClassification("target"))
    return state.warlock_contextual
        and not (boss or target.is_boss)
        and (classification == "normal" or classification == "rare")
end)

do
    -- A delayed filler is evidence of pressure for five seconds. The client supplies the cast's time change.
    local fillers = {}
    for _, ranks in ipairs({ SHADOW_BOLT, SEARING_PAIN, INCINERATE }) do
        for _, id in ipairs(ranks) do
            fillers[id] = ranks
        end
    end
    local castGUID, spell, castTarget, originalEnd
    local pushedTarget, pushedUntil, boltDelay

    local function underMeleePressure(guid)
        if
            not guid
            or guid ~= plain(Facade.UnitGUID("target"))
            or not state.warlock_outdoors
            or not state.warlock_short_pull
        then
            return false
        end
        if
            plain(Facade.UnitAffectingCombat("player")) ~= true
            or plain(Facade.UnitAffectingCombat("target")) ~= true
            or plain(Facade.UnitIsUnit("targettarget", "player")) ~= true
        then
            return false
        end
        local _, upper = Facade.RangeLib("target")
        return type(upper) == "number" and upper <= 5
    end

    spec:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", nil, function(_, _, guid, spellID)
        castGUID, spell, castTarget, originalEnd = nil, nil, nil, nil
        if not guid or not fillers[spellID] then
            return
        end
        castGUID, spell, castTarget = guid, spellID, plain(Facade.UnitGUID("target"))
        originalEnd = select(5, Facade.UnitCastingInfo("player"))
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player", nil, function(_, _, guid, spellID)
        if not castGUID or guid ~= castGUID or spellID ~= spell or not underMeleePressure(castTarget) then
            return
        end
        local finish = select(5, Facade.UnitCastingInfo("player"))
        local change
        if type(originalEnd) == "number" and type(finish) == "number" then
            change = (finish - originalEnd) / 1000
            if change <= 0 then
                return
            end
        end
        pushedTarget, pushedUntil = castTarget, Facade.GetTime() + 5
        boltDelay = fillers[spellID] == SHADOW_BOLT and change or 0
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", nil, function(_, _, guid)
        if guid and guid == castGUID then
            castGUID = nil
        end
    end)
    local function reset()
        castGUID, pushedTarget = nil, nil
    end
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", reset)
    spec:RegisterEvent("PLAYER_TARGET_CHANGED", reset)
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", reset)
    spec:RegisterEvent("PLAYER_REGEN_DISABLED", reset)

    spec:RegisterStateExpr("warlock_recent_cast_pushback", function()
        return pushedTarget ~= nil and query_time < pushedUntil and underMeleePressure(pushedTarget)
    end)
    spec:RegisterStateExpr("warlock_recent_bolt_pushback", function()
        return state.warlock_recent_cast_pushback and boltDelay or 0
    end)
end

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

local function canPrepare(sim, allowCorpse)
    if
        sim.combat > 0
        or plain(Facade.UnitIsDeadOrGhost("player")) ~= false
        or plain(Facade.IsMounted()) ~= false
        or plain(Facade.UnitAffectingCombat("player")) ~= false
    then
        return false
    end
    local exists = plain(Facade.UnitExists("target"))
    return exists == false
        or exists == true
            and not sim.target.is_dummy
            and (plain(Facade.UnitIsPlayer("target")) == false or allowCorpse and plain(Facade.UnitIsDead("target")) == true)
end

spec:RegisterStateExpr("warlock_can_prepare", function()
    return canPrepare(state) and (contextualInstance() or plain(Facade.UnitExists("target")) == false)
end)

spec:RegisterStateExpr("warlock_can_recover", function()
    return not state.moving and canPrepare(state, true) and not buff.casting.up and not state.warlock_incapacitated
end)

-- Cannibalize is a self-channel. Its own usability flag alone doesn't identify a body within its 5-yard radius.
spec:RegisterStateExpr("warlock_cannibalize_corpse", function()
    if
        not state.warlock_can_recover
        or plain(Facade.UnitExists("target")) ~= true
        or plain(Facade.UnitIsDead("target")) ~= true
        or plain(Facade.UnitCanAttack("player", "target")) ~= true
        or not (target.creature_type == "humanoid" or target.is_undead)
        or plain(Facade.C_Spell.IsSpellUsable(20577)) ~= true
    then
        return false
    end
    -- Some self-casts give no spell-range answer. Accept a separately observed 5-yard upper bound in that case.
    local inRange = plain(Facade.C_Spell.IsSpellInRange(20577, "target"))
    if inRange ~= nil then
        return inRange == true
    end
    local _, upper = Facade.RangeLib("target")
    return type(upper) == "number" and upper <= 5
end)

-- Project health costs, shards and prep only inside the current recommendation.
spec:RegisterStateTable("warlock_forecast", {
    healthSpent = 0,
    summoned = false,
    funneled = false,
    madeHealthstone = false,
    shooting = false,
    attacking = false,
    shardsSpent = 0,
})

-- The Forever action bar uses these events between repeat shots, when no cast has to be current.
local autoRepeating = false
spec:RegisterEvent("START_AUTOREPEAT_SPELL", function()
    autoRepeating = true
end)
local function stopAutoRepeat()
    autoRepeating = false
end
spec:RegisterEvent("STOP_AUTOREPEAT_SPELL", stopAutoRepeat)
spec:RegisterEvent("PLAYER_ENTERING_WORLD", stopAutoRepeat)

spec:RegisterHook("reset_preauras", function()
    local forecast = warlock_forecast
    forecast.healthSpent, forecast.summoned, forecast.funneled = 0, false, false
    forecast.madeHealthstone = false
    forecast.attacking, forecast.shardsSpent = false, 0
    forecast.shooting = ranged.wand and (autoRepeating or plain(Facade.C_Spell.IsCurrentSpell(SHOOT)))
end)

spec:RegisterHook("runHandler", function(key)
    if warlock_forecast.shooting and action[key].gcd > 0 then
        warlock_forecast.shooting = false
    end
end)

spec:RegisterStateExpr("warlock_pet_on_target", function()
    return Facade.PetAlive() == true
        and (plain(Facade.UnitIsUnit("pettarget", "target")) == true or state.warlock_pet_tanking)
end)

spec:RegisterStateExpr("warlock_needs_healthstone", function()
    return not warlock_forecast.madeHealthstone and not state.has_healthstone
end)

spec:RegisterStateExpr("warlock_can_summon", function()
    return state.warlock_can_prepare
        and not warlock_forecast.summoned
        and Facade.PetAlive() == false
        and (buff.demonic_sacrifice.down or talent.demonic_pact.enabled)
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

local function canSpendHealth(cost, allowUnknown)
    local remaining = readableHealthAfter(cost)
    if remaining == nil then
        return allowUnknown
    end
    return remaining >= (state.combat > 0 and 0.55 or 0.40)
end

local function safeLifeTap(allowUnknown)
    local _, spirit = state.stat("UnitStat", 5)
    return not state.warlock_forecast.funneled and canSpendHealth(lifeTapCost(state.level, spirit), allowUnknown)
end

spec:RegisterStateExpr("warlock_life_tap_safe", function()
    return safeLifeTap(false)
end)

-- The pinned stationary rotation needs its normal mana recovery when live health is hidden.
spec:RegisterStateExpr("warlock_sustained_life_tap", function()
    return safeLifeTap(not moving)
end)

-- Forever effect 16666 inflicts 800 self-damage with variance 0.5, a 600–1000 roll before mitigation.
local DEMONIC_RUNE_MAX_DAMAGE = 1000
spec:RegisterStateExpr("warlock_sustained_demonic_rune", function()
    return canSpendHealth(DEMONIC_RUNE_MAX_DAMAGE, not moving)
end)

spec:RegisterHook("runHandler", function(key)
    if key == "demonic_rune" then
        warlock_forecast.healthSpent = warlock_forecast.healthSpent + DEMONIC_RUNE_MAX_DAMAGE
    end
end)

spec:RegisterStateExpr("warlock_health_low", function()
    local fraction = Facade.PlayerHealthFraction()
    return fraction ~= nil and fraction > 0 and fraction <= 0.65
end)

spec:RegisterStateExpr("warlock_restorative_filler", function()
    local remaining = readableHealthAfter(0)
    return state.warlock_recent_cast_pushback or remaining ~= nil and remaining > 0 and remaining <= 0.85
end)

local function spellInRange(ids, unit)
    local id = ids[knownRank(ids)]
    return id ~= nil and plain(Facade.C_Spell.IsSpellInRange(id, unit)) == true
end

-- The character sheet's min/max already include the ranged damage modifiers.
-- All three come from the same complete, plain observation of this loadout.
local function wandDPS()
    if state.ranged.wand and state.action.shoot.known then
        local speed, low, high = Facade.ObservedStat("UnitRangedDamage")
        if speed and speed > 0 and low > 0 and high >= low then
            return (low + high) / (2 * speed)
        end
    end
end

local function shadowBonusDamage()
    local power = Facade.ObservedStat("GetSpellBonusDamage", 6)
    if power and power >= 0 then
        return power
    end
end

local improvedDrainDamage = { 1.07, 1.13, 1.20 }
local function drainTicksWith(aura)
    return math.min(5, floor(aura.remains))
end

spec:RegisterStateExpr("warlock_leveling_drain", function()
    local rank = knownRank(DRAIN_LIFE)
    if rank == 0 or action.drain_life.disabled then
        return false
    elseif rank >= 3 then
        return true
    elseif not (ranged.wand and action.shoot.known and not action.shoot.disabled) then
        return state.warlock_restorative_filler
    end
    local wand, power = wandDPS(), shadowBonusDamage()
    if not wand or not power then
        return false
    end
    -- Forever spell effects 689 and 699: 10/14 damage per second, plus
    -- 10% of Shadow power per tick. The pin's Soul Siphon counts our three DoTs.
    local tick = ((rank == 1 and 10 or 14) + 0.1 * power)
        * (improvedDrainDamage[talent.improved_drains.rank] or 1)
        * (1 + 0.02 * talent.shadow_mastery.rank)
    local siphon = talent.soul_siphon.rank
    if siphon > 0 then
        local effectTicks = drainTicksWith(debuff.corruption)
            + drainTicksWith(debuff.bane_of_agony)
            + drainTicksWith(debuff.siphon_life)
        tick = tick * (1 + 0.04 * siphon * effectTicks / 5)
    end
    return tick > wand
end)

spec:RegisterStateExpr("warlock_can_tap_for_drain", function()
    return knownRank(DRAIN_LIFE) >= 3
        and warlock_forecast.healthSpent == 0
        and not action.drain_life.disabled
        and spellInRange(DRAIN_LIFE, "target")
end)

spec:RegisterStateExpr("warlock_drain_life_in_range", function()
    return spellInRange(DRAIN_LIFE, "target")
end)

spec:RegisterStateExpr("warlock_can_amplify_agony", function()
    return spellInRange(BANE_OF_AGONY, "target") and mana.lo >= action.bane_of_agony.cost
end)

do
    -- Forever SpellEffect: mean base hit, level learned, last scaling level, points per level and Shadow coefficient.
    local bolts = {
        { 13, 1, 5, 0.2, 0.486 },
        { 23, 6, 11, 0.3, 0.629 },
        { 40, 12, 17, 0.6, 0.800 },
        { 58, 20, 25, 0.8, 0.857 },
        { 78, 28, 33, 1.2, 0.857 },
        { 101, 36, 41, 1.2, 0.857 },
        { 141, 44, 49, 1.4, 0.857 },
        { 191, 52, 57, 1.6, 0.857 },
        { 251, 60, 65, 1.8, 0.857 },
        { 268, 60, 65, 1.9, 0.857 },
    }
    spec:RegisterStateExpr("warlock_wand_over_bolt", function()
        local delay = state.warlock_recent_bolt_pushback
        if delay <= 0 then
            return false
        end
        -- Preserve procs and damage windows that an out-of-combat weapon/stat snapshot cannot price.
        if
            buff.shadow_trance.up
            or buff.revelation.up
            or buff.burning_shadow.up
            or buff.master_demonologist.up
            or buff.shadow_and_flame_shadow.up
            or buff.blood_fury.up
            or buff.berserking.up
            or buff.eureka.up
            or debuff.shadow_vulnerability.up
            or debuff.curse_of_the_elements.up
        then
            return false
        end
        local wand, power = wandDPS(), shadowBonusDamage()
        local critChance = Facade.ObservedStat("GetSpellCritChance")
        local row = bolts[knownRank(SHADOW_BOLT)]
        if not wand or not power or not critChance or critChance < 0 or critChance > 100 or not row then
            return false
        end
        local base, learned, cap, perLevel, coefficient = unpack(row)
        local damage = base + max(0, min(level, cap) - learned) * perLevel + power * coefficient
        damage = damage * (1 + 0.02 * talent.shadow_mastery.rank)
        damage = damage * (1 + critChance / 100 * (0.5 + 0.1 * talent.ruin.rank))
        -- Compare nominal throughput if the next Bolt loses as much time as the last one. Resists are unknown.
        return wand * max(gcd.max, action.shadow_bolt.cast + delay) > damage
    end)
end

-- Damage racials are self-casts. Require a learned filler we can actually cast on this target.
spec:RegisterStateExpr("warlock_racial_cast_window", function()
    return not state.moving
        and not state.warlock_incapacitated
        and not state.warlock_wanding
        and (state.warlock_pvp_target or targetEngaged("target", "targettarget"))
        and spellInRange(SHADOW_BOLT, "target")
        and mana.lo >= 2 * action.shadow_bolt.cost
end)

spec:RegisterStateExpr("warlock_eureka_setup", function()
    if action.rain_of_fire.known and state.warlock_aoe and mana.lo >= action.rain_of_fire.cost then
        return true
    end
    return state.spec.destruction
        and action.incinerate.known
        and action.immolate.known
        and not action.immolate.executing
        and debuff.immolate.remains <= action.immolate.cast
        and mana.lo >= action.immolate.cost
        and spellInRange(IMMOLATE, "target")
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
    if not state.warlock_shard_target then
        return false
    end
    local fraction, measured = Facade.TargetHealthUpperFraction()
    if fraction > 0 and fraction <= 0.25 then
        return true
    end
    return not measured
        and solo
        and state.warlock_outdoors
        and state.warlock_short_pull
        and not state.warlock_wanding
        and state.warlock_pet_tanking
        and (debuff.corruption.up or debuff.immolate.up)
end)

spec:RegisterStateExpr("warlock_wanding", function()
    return ranged.wand
        and not state.moving
        and warlock_forecast.shooting == true
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

-- IsUsable passes the simulation and its ability. The belief calls without them when checking the mana cost ladder.
-- An effective cast time of zero permits a mobile instant. Channels always require the player to stand still.
local function castUsable(sim, ability, locked, reason)
    if locked then
        return false, reason
    end
    if ability and sim.warlock_incapacitated then
        return false, "unable to cast under loss of control"
    end
    if ability and sim.moving and (ability.channeled or ability.cast > 0) then
        return false, "requires standing still"
    end
    return true
end

local function unlocked(school)
    if school == "fire" then
        return function(sim, ability)
            return castUsable(sim, ability, locked_out_fire, "fire locked out")
        end
    end
    return function(sim, ability)
        return castUsable(sim, ability, locked_out_shadow, "shadow locked out")
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
    return function(sim, ability)
        if remainingShards(sim and sim.warlock_forecast) < 1 and not (waived and buff[waived].up) then
            return false, "no soul shard"
        end
        if fire then
            return castUsable(sim, ability, locked_out_fire, "fire locked out")
        end
        return castUsable(sim, ability, locked_out_shadow, "shadow locked out")
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
-- pin's spell rows at the top rank. The target's Fear and Howl of Terror use observed aura evidence in live decisions.
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
-- The belief's `instant` and the simulation's `hardcast` distinguish the next instant Bolt from a hardcast
-- already in progress when Shadow Trance appeared.
-- `sim`: the simulation's handler, which also reads the target's health for Decimation: a landed Shadow Bolt (or Searing
-- Pain) at a target under 35% (wowsims talents_demonology.go), and applies Shadow Vulnerability for Revelation's
-- guaranteed crit. The belief's `now` has no target to read (its health is secret on Forever: the glow read of
-- `decimation` carries it in game; the crit's own `onCrit` carries the vulnerability).
local function bolted(sim)
    if sim then
        return function()
            if not state.hardcast and buff.shadow_trance.up then
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
        if buff.soul_link.up then
            removeBuff("soul_link")
        end
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
        if buff.soul_link.up then
            removeBuff("soul_link")
        end
        for i = 1, #SACRIFICES do
            removeBuff(SACRIFICES[i])
        end
        if key then
            applyBuff(SACRIFICE[key])
        end
        dismissPet(key or "demon")
    end
end

-- Approximate the first shot with one wand interval. The wind-up and the remaining weapon timer aren't observed.
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
        usable = function(sim, ability)
            return not (ability and sim.warlock_hard_controlled), "unable to act under loss of control"
        end,
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
        defensives = true,
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
        toggle = "defensives",
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
        usable = function(sim, ability)
            if not debuff.immolate.up then
                return false, "no immolate"
            end
            return castUsable(sim, ability, locked_out_fire, "fire locked out")
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
                state.warlock_hard_controlled
                or not state.warlock_contextual
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
                state.moving
                or state.warlock_hard_controlled
                or buff.casting.up
                or warlock_forecast.shooting ~= false
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
        usable = unlocked("shadow"),

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
        usable = function(sim, ability)
            local p = pet -- the simulation's; the belief's `now` context has none (the client's answer decides)
            if p and not demonOut(p) then
                return false, "no demon"
            end
            return castUsable(sim, ability, locked_out_shadow, "shadow locked out")
        end,

        now = sacrifices(),
        handler = sacrifices(),
    },
})

-- The kit's utility casts. Ranks, costs, and cooldowns come from the
-- pin's spell rows; `CostPct` ones as fractions of base mana.
do
    local FEAR = { 5782, 6213, 6215 }
    local FEAR_DURATION = { 10, 15, 20 }
    local HOWL_OF_TERROR = { 5484, 17928 }
    local HOWL_OF_TERROR_COST = { 150, 200 }
    local BANISH = { 710, 18647 }
    local BANISH_COST = { 100, 200 }
    local SUBJUGATE_DEMON = { 1098, 11725, 11726 }
    local SUBJUGATE_DEMON_COST = { 300, 500, 700 }
    local CREATE_HEALTHSTONE = { 6201, 6202, 5699, 11729, 11730 }
    local CREATE_HEALTHSTONE_COST = { 95, 240, 475, 750, 1120 }
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

    -- UNIT_COMBAT identifies the victim and school mask, but carries no attacker.
    -- Dark/Demonic Rune deal Shadow damage to the user. Also exclude the health
    -- paid by Life Tap and Health Funnel, regardless of the order of their events.
    local selfDamageWindow = { [16666] = 0.5, [27869] = 0.5 }
    for _, id in ipairs(LIFE_TAP) do
        selfDamageWindow[id] = 0.5
    end
    for _, id in ipairs(HEALTH_FUNNEL) do
        selfDamageWindow[id] = 10.5
    end
    local shadowDamageAt, selfDamageUntil
    local function excludeSelfDamage(event, _, _, spellID)
        local window = selfDamageWindow[spellID]
        if not window then
            return
        end
        local at = Facade.GetTime()
        if shadowDamageAt and at - shadowDamageAt <= 0.5 then
            shadowDamageAt = nil
        end
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            selfDamageUntil = at + 0.5
        else
            local duration = event == "UNIT_SPELLCAST_CHANNEL_START" and window or 0.5
            selfDamageUntil = math.max(selfDamageUntil or 0, at + duration)
        end
    end
    spec:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", nil, excludeSelfDamage)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", nil, excludeSelfDamage)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", nil, excludeSelfDamage)

    spec:RegisterEvent("UNIT_COMBAT", function(_, unit, kind, _, amount, schoolMask)
        -- EventFacade replaces secret fields with nil. WOUND is the damage signal
        -- when the amount is hidden. Ignore zero damage when the amount is readable.
        if unit == "player" and kind == "WOUND" and schoolMask == 32 and (amount == nil or amount > 0) then
            local at = Facade.GetTime()
            if not selfDamageUntil or at > selfDamageUntil then
                shadowDamageAt = at
            end
        end
    end)
    local function clearShadowDamage()
        shadowDamageAt = nil
    end
    spec:RegisterEvent("PLAYER_REGEN_DISABLED", clearShadowDamage)
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", clearShadowDamage)
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        shadowDamageAt, selfDamageUntil = nil, nil
    end)
    spec:RegisterStateExpr("warlock_recent_shadow_damage", function()
        return shadowDamageAt ~= nil and query_time < shadowDamageAt + 5
    end)

    spec:RegisterStateExpr("warlock_funnel_safe", function()
        if state.moving or buff.casting.up or warlock_forecast.funneled or Facade.PetAlive() ~= true then
            return false
        end
        local inCombat = combat > 0
        if inCombat then
            if
                not (solo and state.warlock_outdoors and state.warlock_defensive_target and state.warlock_pet_tanking)
            then
                return false
            end
        elseif not canPrepare(state) then
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
            and petHealth <= (inCombat and 0.30 or 0.55)
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
    -- A debuff on the target (Banish, Subjugate Demon).
    local function debuffed(aura)
        return function()
            applyDebuff("target", aura)
        end
    end

    spec:RegisterAbilities({
        soul_link = {
            id = 19028,
            cast = 0,
            cooldown = 0,
            gcd = "spell",
            spend = 0.20,
            spendBase = true,
            spendType = "mana",
            startsCombat = false,
            toggle = "defensives",
            known = knows({ 19028 }),
            usable = function(sim, ability)
                if Facade.PetAlive() ~= true or not demonOut(pet) then
                    return false, "requires an active demon"
                end
                local range = plain(Facade.C_Spell.IsSpellInRange(19028, "pet"))
                if range == nil then
                    local _, upper = Facade.RangeLib("pet")
                    range = type(upper) == "number" and upper <= 100
                end
                if not range then
                    return false, "demon must be in Soul Link range"
                end
                return castUsable(sim, ability, locked_out_shadow, "shadow locked out")
            end,
            now = buffed("soul_link"),
            handler = buffed("soul_link"),
        },

        create_healthstone = {
            id = CREATE_HEALTHSTONE[1],
            copy = rest(CREATE_HEALTHSTONE),
            cast = 3,
            cooldown = 0,
            gcd = "spell",
            spend = byRank(CREATE_HEALTHSTONE_COST, CREATE_HEALTHSTONE),
            spendType = "mana",
            startsCombat = false,
            toggle = "defensives",
            known = knows(CREATE_HEALTHSTONE),
            usable = sharded(false),
            handler = function()
                spendShard(warlock_forecast)
                warlock_forecast.madeHealthstone = true
            end,
        },

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

            -- Predict the selected target for custom lists. The live target aura comes from observation, since
            -- a cast can be resisted and PvP effects can end early.
            handler = function()
                applyDebuff("target", "fear", FEAR_DURATION[knownRank(FEAR)] or FEAR_DURATION[1])
            end,
        },

        -- 2 s cast, 40 s category cooldown. Only an observed target aura establishes who this caster-centered area hit.
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
            toggle = "defensives",
            copy = rest(HEALTH_FUNNEL),
            cast = 10,
            channeled = true,
            tick_time = 1,
            cooldown = 0,
            gcd = "spell",

            startsCombat = false,
            known = knows(HEALTH_FUNNEL),
            usable = function(sim, ability)
                local p = pet -- the simulation's; the belief's `now` context has none (the client's answer decides)
                if p and not demonOut(p) then
                    return false, "no demon"
                end
                return castUsable(sim, ability, locked_out_shadow, "shadow locked out")
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
            toggle = "defensives",

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
            usable = unlocked("shadow"),

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

    -- Not registered (one line each): Create Soulstone / Firestone / Spellstone (out of combat, a shard),
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
    20261121006,
    [[Hekili:T3ZAVnoos(BjFXJ9QECSt6KU7bXnWS7Hd3U7C7UyZamFZkYw0XAJSKHEKm5qq(TFfPeLOO4l9WoozudmdILeRxSuvKfRQ0Y5l)1L366KGw(pUy2fxpF(fZNn76L3M88E0YB37S(bN7H)iWzh8))5nB89wN4fg86DJFk8PyVDXtxhUBc(jF2p0XfdTvPE(j)1GLRec449O1lV93(5)9V8p)l)9FYPaIlVDRNRlkByO41kW2p96DjBrVEx(1oFtye6ru0R35I24K6N86D)8)6xE9o4YWFXcKuVZXOp(8NCI8dx)W5U7JphtUUXNduI9tra)oLCHP)N4WGjFcWuKtqSpWhUWFhIXSx8R3546gg8dWF8a654PVE3)LtIZpjGIg))(x)vaiBts2h)tNF(9EjBtxHzIZ5E0jambc3z1SnZMH(8M1F9saS)cClFVG7bqeMM4gI5O9P((XWfCcakYnn4EuyaqiPXGeXh5efGPuGnZEQ9iaQRDIq0rSf54NS9hDaramGDoboVExeADiqdpdy8Fg56f4e9CoEaPOZJyScpv8ohF)xVliD3kmRfUby7WFfJKN265JWetKZk8FK4eDpkbg89yShNgN44rilx0Q0nBYPecnc4jYlmYlXdHLJ)Bhp8J5Sd06WZG((GykF6EVxabi)w4VDli5kgjMS)x(opJjkqYUclhbPrmJ4yFekoofZWemVomijkeWnwRGa7yKpAnzooC)(WauqYuqNokCdWylV1HOafpDpwqHrWIN889TtcTbG(O3JOp5TzrUoLTJpCHr0FfNKsO6)wnyyT4Ccuc3ydKGnOhe78akqoOOpHnL8fct4vhN9iBNOeV4e5aBhmHVdytkWgDg9oBDICPx1h5ocpJnTcuN6g(uGyShV1jjbfzVonkwGurnsC9iQeyDOmamnDF2DQawfOpt5oobMb)eOcaY2n23V2DX8pHHnOJyVcbAulUCgM2Yg23NnYmIuokH3qT3hIVNsS(5(dRro79CTJq3JcqroAX81ZyNlw7eyN)kFM4To0uiJHrh4Tci6)pehqPxgO(O9XOmyZCDcqhHn5mDR3nZME9v)jYp25876rfhdDvBWTyS4ICs2cJZZ3S5lWldkigMZSZSZnkj8(79bmqVEC5B)y9zBpqC7a2PBi6Z4X(d9JgdV0dQQVqV9(h3BtTmor67ZGGZggHRcDx6VGbInPKpOmR4fVatHJkRhHP(2WBtpu3YXykQFHvlgg8EWp2KCKqhUQj7iWve8qBeRr1Js7ciqWi1mroshDw2CXBSkHkRO2BWEU8zNkYUIDSZgjJelxbAypV1M85PcQG(Ceq1elcXP72fgyVb5Vnna8iWJOS7pIvd3law(rW6CfXny6pXzhSihvkIzO5Xqp3NC8FqlEYxCw8O4q)WseHnNE)Z6XJ3UAsSCeqa1Q0OaSUt2lr6bxC661PRsJLaZehF86BCrWp8wBdRXpzkka711vi(s3RM4dogiBDe8obYM1bVgDSaeYnMDaJoldWtRdRPOFhTonrXlKyo1jAxynnbkAZwbt5ZP0Hdzw6bVazaJsPSW7HaS3tg0GbqMl1XsF(xeswQn2Vk0VYchXRfb97jPo(fYwuW9GPD3k22XBuAnzjBnXwtM1rSLBdrzHXVClOJoBvyC8OZYS8n1l2M87cAiF5uG1IBUGzrwzM4aBQCp5tEbaZiMwx5hg6cgbJEMBXwISjdBL0ZXhMvJtYb6OXSMLOoEFzSbm94ZkPYWOeB8EZkDecBZ5rWhyXZKjkWm3KCpJLuUc1seqnp48EJ1YO6S3dkGn5A2XOePMtWBKGU1lyVF4TcfBOgOacEeGkS1J4PoXXE3dB4lBRkl(bkS)Hrz79DQqmxL8n59McWax7bFqEha)3HGbyHFDMG9UDGjEc58WHIbOWUoXtVtZjCIrlacB8IqgsZ1x6Cis9QaZSRI9p2wuu(2s5lOmge)(IlEj3)CUnCNaWkHVZoeSLWGhwC1KgjvGTEfLUhFDdjyrZJ0jPcynncTde3X3SG6(U8wytqLU1lVEH7CW8s(MEep4fZAgl6SBpS21NZJVrntLTKNl8FVYjGOz6CFyWZ5EWZfivVfXlE9XblcDN4HrUJKrT15XW1Ihw2TYgxn1l8kwOceczPMreElyPyUpNBkVIWvHJQkq4dVyVjQNXE73gMV922lxYjggG1ClKEWQ)XrnV7Kbfs1SduCJkwbkUQCBavgytTa0qgtKANpoQ(3mF2lcSCruheUGNAYdYCYXITzSTV(zyzz5ewmy3d2SUD1RDHHchrZ6fwzsIsr2ys5reEJ078qaGlT9qwz4O877gMWiexmxGxKksRw6QqROXm2waxRy(UN5HgnRVcbwIJEaFcuVZ2wqjL)HEhp5tZm7CpZcs)54uGYkDJ3c0z)45svuinlc3Nk7x07zqWzptHeTm4OxoRi4OvwcgooQBcJYc08OZaI)rSQ805tP0EjGb90Kq8r8aKZgpFFuubOQetwvbRHF1fDtAuCdYPfueFCdesmXWrKGRGVYpd9C5dre6h(D6Qik5jWyjSoIXYfvVqg7(1y4FZvx9YzJZHrwEdK56UzAxGOkmPv7JySaP9yHuepzlWYsPDRUnzkZCuHtlg6QakpH31j(WijdaeGNnwKom(N5lbKLekM(QFYlDJx(WPykz5lcpZgfRzBm78gznhFy1efSNxzNCfJXzXIzc(gKXcKX8RznBuTz5Qn)am(JTKMfETtE3wVxdM4pMM4DstcTDssWwGAXSLUJqjm4(uuLy3ZUNijAufBVf07W7slDF9tijdWQYfj6JI(9ToPX4hOPKb7Z(Ghzt080rjW5oU1AuALDEiKpA2rVAcdi8myBYjkycsuOJZEGcZAsesmbVYIbIa6XGqFOk0jnkGQnG0Rffvb0Ed3TEdWE99AB222nBJ09UUSMZdtP3gw43icRm)KPJQ9P3RvVLuVwVbPYR1Brc8ADSsBxRJyY6ADStrxRdDI5ADathxR3IKWvfs778S0WuV16iKWTwhQ0S160n5ApMt11TRzyI0klumDm9zToKjnR1bnvzT6JeK16iKwSwh(KH16nifyT6HeF16KkDx5we4MW1PXMUl42LSRwN8P4Q1hXeB16JWH7waBrPZQLSKyntPUlPGXXizwTKLcRhqYpQFtLvlrjW6bK87Pez16WL(QwVpsAvRkrKQ7ZyNCPSQ1qIQ(wLOQw8XTR7QxVpe66vjzJLA3LkTmjvTyYGZEJiE7tr12ZwIu4ENKGQwnoTuBMOr0mEHTLt50tTlo4eWZkMR7zoWGz8pEPK6hI9QKpLkpru7OJrbQLF0tdvjbeSBP8Gb52aJC8no5tTgs5uJs7dd0KAFQ68XnHOgYcPdJ64eDMWgsiV(i9sTgsQu5s2oLuPwdPsAtLVTivs7KxPbt3hEt39vAJA9MLSOwVVtru52HmHSfEEL6JvVjGwHgR40b16DwsGAD0t9ZA7pUD48iLWNDtZu45g18K7ut0Gkqon)oRBf2lyTZEN1EjK(7ldCXaZlbTl2aWwz7Q5P2ruATuzuifv7k2SqGfY7C(pW2SXgXfN9I6OS1oWmq2pbnY4KpHBPZlIbXHpYExQFIhv)iZOKF49ER1cv2OHGF4XB8UFBIn1hSWyMKML)I0GJMh80VpFsDPHXmqoP7gMus4vH)I5Tb8vemkG(31a96zDcjWxJfAJ(LX5hWP3U9rWQUCTzxDvLegc37O9ZshuWN44ZOwEYE(ht9Xzl6kpFCxsgaSQBtp7c66c4xrNLGRdKmGF7eVDOjtMOzcusM38hkzGyTS1HH(y7RKLfnMxV9LXC2Qldk5OXQIy54QVn(Jxn5CvVqo5M5QJa6zIgD6EGPvrIYgKAbft(AILjNjqWNZKTCQ67vKncOgzlUxgLilOhJzx49LZgv1c51ZuH6s3cuiQC3)AFTZSNLUIWI9)K72uoDkADGCjaDX1BuQCitOAoP1WCLvu4QmzEzKcv08DTDJinvyxBmLrJg3XleNXx8N8jJdgdsLRXNnESbpwTDSWMXxW7ZfVikoHQYSf0hPMLqCvKbuAWJb5qfXGMXtjwYYJT2mPuvkGNy45ZksDn8AtM7mKKENoXuKDETzsPKYoMtihZxMmG1nDsr86LxOjB0uUkgzR6q5svgRybjNrxUv1BMLGxQwjtfp33OCPuteqESNbnptLDpmxHhu5Q)U5kTc3AboGD)fTsWkJ4AfTPidDyj0ZQhKhaHc3njBCGO7LmpS6mBiBXLtEjdvtdttI9CrxjW6r31unBwTkJm)c9uIYPvPZqTcpIZviJMs(MriqsM)vUvnMaLjBwVsW0Ot7A2RhZ7GL1jq(uvM8R8YvSOWet8xQET1BDWLUfWQSAtfBGBHSm5rZg1KB0r5af9gm1(0xBE6SODVCY3b4i(3)GTTws685p4lIuT0yYu67wfspwvKk79SQ(1KIP0AdaZh1MmeKAWvta4SHkyMYmY)m5a9LsFvvVBE2iReJkb8yjaM(Q1pkfXz7x(MfJfYr0XBnF6v4WHmPUYndnoASCsKZDRmco)(wkPgcDu1SsrqxksJTsFjTwOwnElDKKVrgfkIBgFXFs6JF6WrQOsHC1LVl4kfuj9FcIqHHNgrPZfl1vQ3X3fZ8Rg8Xm4Jr(Rzd(yk2PjtDQE66NravQZxJOHC6Wz6OuD(CoX5onuAp77XN9qnARVgvUtU4Iw7yymng7Z)6SzJypXLl(g)UVVEMqrIQZCz5TpIIIb6I7Jzm(i8IjFbLZ(Ydd)5)G8fvo)akx(NPF8yxElxpLA5TRJ8sqrEoWTYrTWEl1YeaPQGzy1EnLEaZ3ZPWy4sjyOs3IspO7CVOctlFwcTeZ2ePKtlQrzt6rvyI5koIPs3JbKBZyjKg2UOwElZI4WAofSktJ5atexRMi(8HJi8k6wwy64lQPJRNjAwX0EzLCcP(aWeZxLOMW0MPKqog1DQeFwHye)nnsHR6DAbJ15Z0ReqrB5PNRuXWGQds8X5sOhEdDkedhA6PO)AjUbBrixz2qZJDimqxdElI(lZ78weKlZ8ArV0sU5SYwYLX9Klck5TIQA6PinIpqtpfqqv76Iq1Am3EmvQi0dVL3QgOZBKxIM8yAXxeaXB6Kci6ImKz5Sf9(lc(KzDKVzGjdVnUPGrWkVProSw2LWmeT67wyKLhXBAKdTE7KkE10gXiqx2k646RyAqrZB(xeKl1SvLgo2Hb3YSAvV7HzQ2B76izeIr2Qcz62x6OISfaY1DWiaN3StvGJB9y6GnLp6EpmtstmJqN8MJeqt9tdmRM)rC6kT8wYP3HxBgMyKzsRSHN1qc8O04ZiKoV1rzR8SCB1k9XyCz53(6YVjfMpxxrJWX8wMLXXzbW(9e3QRLPr2ElVhIgPxkQrG01S8Pc5k7DpHdT4TWliCgV3PdhN1G8kQzCh7q54oE3FhoUZGKDQzCfDyCCKmNQSnLTgYNQAoBeCQiIkUz57BxXiBTfvk1RKQV6Y1xfld)sE)ZnIyfPgu)WHOrHSB9STg3BByuCkgcNgdVtFzMURef5EqgPmq3TTnQ02(OYHSHV1Mo(gzMHFfq)XrKRtzUcnYPpZV4Rol1eCeSgzQMzaCKi)QL6lsSh7uCnSRPvY10buLL)CNwHKiv5IUi3XQnY13sez77N1qDLCALynUwFNddUsa3m5QivPtGwqNCVCebxNw0MaowHwsFt)A1vK5L(Z8RRt6wklkz53tBYIR51r4y(vv(XClL5Qk1kRlIiOtRlvGMEB7PDFqwAWNLfUDvrjVBTWfd6vlmtcVnnepIOrD024p8M(r4uCJ3b93g(gCtZ6vEerSPrfK0SkA4l7nOzqvJteyO6LtQ(b1q7y6qPUMTGkzhRMYdp8a1QYE)PD2U(ShwWFLSdwKG2bPUAPETLBBst4Ji2LEIRSNf1GWVrcF(gKHMPa(9W1N(ch8wCi9wCLP7eLP)(1SjqcwKDMcLNzvwpTteOnPjHr3GVzT8pcjj7u8lgrzB6RTuf7Z2t9cq1ndqcJjBBrAShAcdjmPaiiv2gouFOrMGtfVZWEMrZiKH008KnkCTImKfcjbKNjrosvONiCI0KJInm0DIvmPJdIjLRLTUgU9M3jIPESimlUgggNbcF0YfkycxWC(Px3zNHSiKartTrloAHfKSHf0bbLMgUUIEFOsmsajVbxzGKTPgQMpQDLknercsn94qR1Xe1Zp6ppVYNV0qexpDlRSqSXD2n872k7sneSkZchBq5yPLEUjlsOb5h4vviiQnk2mrrUqOO)qGr)xKF4t8mqRrV4oucb7YtHgjnNWdx3j843EcLy0KnSSFr(b68hEbejvi)cV5Cgbe)7pV06(5yV3qhv1rh7Nw6OHVBwuMHeHP8m9vuc)xWG12X8lNonhscFjB7jIIIx)21ijOx2MiKglRkEi(I6TdiDPwvbI0Qsq4EkmVlpkANeM1ak1LvAeYUjXF1CI2Ws54RYwSUQO)AIwXivV6ORPvcugmFVhxyFy(D5qLVou5R9vrNou5RuczOYxtgQ81HkFDOYxpQkve6zOYxlFFAOYxfc9HkFDOYxFRQ8voNyTiLaeg5kfwehQ31Y1aCALUUd17Q26DTWaM4kkTrQTIkkHdz5WMiOkxRXpvRH0dh)0tfbBIGABTgpvwbPho(PJL9AYqfT2pv0AXKVY0AOHZ61ZWH3QQCnzOow1MrdNo1XAXYb0LoiFuNjuOflD7LQZINgkPKLqpkimz7aTS6g7lQ6nSkwteuPQDKrfPNEYx7Qj9C9P2ijMivJ3FvLAN94kqkOqNOV5jvAgDl7Yo13a0qTOkk9cQvlQ9HtCbQ4FGlr1KHkqDOcup4fPHkTptJtxBQ6Mp0f80qnfDOuxhQa1URDoubQVns9Hkq9us4ZNfUdvGk9gFW8wmubQsjPHkqTgdj8C4jiDOcuz3BT(icnubQvjM6HAWSWwyyyei8rlxOGjCXXTcunKWzRNJe913OIYcqwQiulI1I6DIgKVb4px)g8yktlb8xYXJ6hJ)6iR4y41GidoiFsLDHN81M5bCztr3MsQkcWtl1ChXkZ1WNnAMZqA6ezArAwhkiHq62usjvDuNooQVizaZRDkjrEzllWYwJtOb1FoxRvEMz3e)bDT235FrVvZGhzqsaGK5jUs)rwpMywdsn08TjIxevLwbPEuu9tU7iHvfFL1JqlkEn1ymZccktSq6usMyS86v(86YSvOYtoopMdBDWPfpOmnzIKfEXW(yxVf1eBd00QF8w6QOyP3utTil6uzOPdWxBXj6OVQJB0hgALFzOBZNg6(8BdDh(4q3HVo0T8ZdDN((qR(7H7r8le9jZNiA5FJO5(0X3nbB)(LgwXN3(6mKQpY)NsmLk6umJP478)jfJPGoP)BuT9ZzqleY0nHkUkcEl8en)QbxrdUIm6DWbxrlu91KVBc3(1aNMV69QDj18VP)hxMthTQ110jpdQHw7KlkzHqXxqEk0EhsQC5CXfT33XyAxxz(xNnBe7jUDX3430)1ZekIQDf2MauI02Gwd2JzdIMHRb9Ak1(Nvnlu6nGBIa7mq5CqvdPIimgTrnV7ipinvxjWnxPlinTt8jn0o1rFBcTdDiQtQCrbF0Oqbv)ryC4WVwQfxobxZvy0onmnj2ZfDvEy6sihM8wCLq))GEWZ3717g)FhI7TCrzpWY)))]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261121006,
    [[Hekili:T3txZnooY9BXVOvkCozz7XENSL1u1MKk1DjBU7QZBv7BIMIcsINPivXpShNYL)TNgGKGGGaGaKuYYk8HDRXKe9xOrJgn6U1IRw87lEyLtcAXF96zxF3vxD9vZMD3IhsEDpAXd7DCFYzd8pcC2b)))d0UWGq)WnV((JJFj8LyVDXtDd3nb)LV6h6ScdTLPE(j)LGflfc449i3fp8h)6)43(B)7)3)Ykkex8WwVvRqzddf7QaB)Y7pMSf9(J5p7Y1HrONrrV)4k0ANu)K3F8x)7)27pcp(9hRaKuVlXOp(YxCI8dDF6Yv7JVetURIVetj2R9Iq2lJCcwnL84P)Z4WGjFbWh8SyFGBwb)7qm(9IF)rNvRcd(j4F8e614PaYCsC(fb014)N)YVdazBsY(4F5Yl34LSnDjMvUK7tNaWeiFNLZwpBg6RRD)2nay)n4v(EbBaqeMMSkeZx7t99JHhaKkW3PbBqHbaHKgdYfFKtuaMsbMn7R2JaO66eHkgXwKJFY2)KdiiGbSZjW59hJqUHan8kGX)w0kVaNOxZXdilDEgJv4RI3547)(JbP7wIzTW1aBh(7yK8YwpFeMyICwI)hjorBqjWG3GXECACIJhHSwHwMUEDoLqOraprEHrEjEiSC8F44H)mNDGUhEE03het5t679cia5pc)JhajhDKyY(V778kMOaj7sSCeKgXmIJ9rO44umdtWSByqsuiG7WGCyhJ8rUK54W97ddqbjtbn7OW1aJT4bh3epqipDpwqHrW8x889TtcTbG(S3ZOV4TEEUMLTJp8Grf)vCskHQ)VQbdR5xsGs4ABGeSb9GyNNqbYbvXxyxq(cHjSaYzpY2jkXloroW2bt47a2SayJUO4nBDIwv8uF0Qr4zSPvG60vHVeig7XBDssqr2UPrXcKkQrYkpIkbwhkdatt3N9MkGvb6ZuUJtGzWVaQaGSDT9g3vZV6lyyd6i2lrGg18BMHPTSH99zJ0JiLJsyfQ9(q87uI1V2FynYzV3k7i0guakYPrmF3m25cxNa78L8zI36qtHmggDG3sGO)FrCaT4Xa1hTpgLbBMNta6iSjNPB9UF207U9FH8h7C(rZOIJHUTn4wmwwHCs2cJZZxV5lyVguqmmNzNzNBus4Mn(agkEEC5QFS(SThiUDa70gI(mES)q)OXWIEqv9TIxV)592fwgNiD9mi4SHrSsHUBXFbdeBsjFqzwXPlGlGJkRhHP(2WQPNQB5yCbQFJvlgg8EyFSj5iPy4QMSJGTIGpATynQEuAtHabJfMjYr6OlYMl(Gvjuzf1EnENlF2PISNyh7SwYiXYvGg2ZBTjFEIsffFhbuMyrioDh4vN9AK)20ayhbEeL9(rSA4EbG7hbU5kIRX0FIZoWjhvkIzO55qVvV44)uJ4j35S4rXGdNLicBoDZRnJhVD1Ky5iGaQLPrbyDNSfrndU4ux30LPXsGzIJp2)gId4EU2GN(jtrb4DDxjeFP7vt8bhdK5gbRjq2SBW3GowacTkMDaJUidWtRdRPOFGCttuSGeZPor7cRPjuG2mpyk)oLB4qMLEYlqgWkOuw49uaE3tg0Gbq2wQJL(9VjKSuBSFzOFfhhX(IG(rsQJpv2Ic2aM2xvX2o(GsUex2mXwtM1rSLBnrj14xUf0rxSmmoE0fzw(M6fBt(BknK7ofyT4(RzCYkZehytL7lFXlaygX06s)WWvGrWOx5C2sKn5ihxphFywnojhOJgZAwQyJ33gRbtp(IsQmmkXgF2SYncHJ58mShi9BYefyMBs(oJLuUc1seqnp58zJ1YO6S1buytEMDmkrQ5e8bjko6fC2p8rHI1uduabpcqf26r8uN4yVnWb(YoQY8FQa2)0OSZ(oviMRs(6SUHcg4zp5dY7a4)oemal8RZeSVTdmXliNNoumqbSRt8fVXCcNy0cGaoQrAsZ1DDoeP2lWyKte5KLoCBuihj0vHWAeWIFH3Gv3dolkxfBcNluQ(Yi0oaPX3F90BP7fXsoL7xcRFZpvHOpdBIy(SjgjBjEXBGGnN8D92LDYvydikjxakv0l9BAfXs27d7dJMuBn1GslALgrz2067ZV(T85V89zH5h71(o7qWX2dEA(TMrWWXJJs3JFUMeSO1AflKOWIQWmVWfRYxHfRLUEv(C5tjCd205eND7HZx8AEmOQTDwl5zQpwlDciwpC2eg8AUxw5cKQVI4Pv9XbhuyN4HrEJKrT155qxXdl7vzJRM6f2RYcbcHSuZicFf4U8QxZ3UTIWvHZevGWzVy3e1tp4Cr47tOdcLCkPas1w9rFrL1E0NkFLxLbA66odzmrt2(4774(RM9Ma7fKjbHUcwtEq2p)yX2mwuDFfCynNWIbRn7C(HD1NDTMchrZ6012jrPiBmP8mchIHDEiaWLR4j(mpk)9RctyeIZVsGT7ksRwAGUrrJESTaUwX8DpZdgnRVeb2)IEcF3CFYoWujLFwFwW8PzMyAKzbP)2UsGYArijeOZE(TrMOG9sdeQk7xfVtJWwFHcjAzyJVzgnSXvC8bhH51HrzHGF0faX)mwvE6vtlO9sad6PjH4l)ciN1E((OikOQeTAvHXICTc9M0G(cY9OqV5anesmr3sKGJYx5zxqU8Hic9d)EHxeL8eySmoXiDdGrdtALV3JfiRgFX4ILZSNUmlIOkpDl1ue7bIN8gHv37Ifh3F7TVjWIsP9QUnjowMDOr9mprF8l4diIVBxcYEt457zcsBvOawsVySO1j4)m3ntw2LQIu)EV6MC7et5xIdocVVlfE1nMDsI4vYG2ER4P(sBxWjMLD3KmBY0BXRBqHOV4P(tHq4Buts9Fmqn(M4g0K6lEQ)0KQPwWq6TtROTovnSNU(7P7KMeA7KK44(uBK1nDFJHbBsrvUOl2JjlrFGgXdqRbFWDqTR21jMbyvjUxXNI(XwN0y8hykzW(Tp5rIRcpDucCUCtOgLw5WOc5dZYtbDyacU4tybtUAhDqIcnu2B2zMjbnth8klSycOhnIgMQOPjrI5TFBy9tbBaPZabP0UHbWXaSxp8l6fjh9ITIzonQdzxyMKog99yr4MzYnDi8oznHeRFjT9(sB13LU6TozHVbsGYkBOXle5c(7OGnpPQbM2xFbw9wvfy9bulbwFevqG1XQUbSoIvlG1XUgbSo0vgG1bSEaS(iQcaviTVt0BnZ9FRJqg)BDOYZFRt3S7)yovx3UMMzYV1Hj)9ToKzTV1bnx9T6Jm036iKx(wh(SX36dih8T6HmV36KkF75CXDDOBASUrwODzBV1jFo2BDoMz9wNd5qbf2IYNElzzrFMsDxY0PJr20Bjlh6pGKFu)Ml9wIYG(di53tzsV1Hl)5T4cOIzcd6AUoghLJC2ZBXgDIwSJYrm35T(CKX8wvIcRzkrkYx3tN8L3Ail5)OYsEl(yv3D1Rphc9MvjPXlT7IKtMmKV9SLOj6pj5hVLXzfVzIgrZ4010NYzhFx2yrapRyUUN5anMXp)Yi(ZIZWLpLkpp474gsculp3ZcEjbkTBjhJgzbdJC8do33TgY49ItZ02uYAi98AhprFChtpVHCItKk)KMmYnKcQFI0X7y2TZhnTb1GpRQbcFZHpN2TgYK9Zd9NEit27KZsd7v30E19vwRB9HLR6wFUZqD5260HSjyqAEPl9At0b0k03eNn6wFYYbDRJEMNxlKjTdNhP8nxHBC6qSh0Sm36WMB5DBrPOBxUf5romm8a8sq7ILp06jbUvEMlbsUO0AjMSOHoQ2tSzHalK358pdJSX7WioxKBIYCDajv2FclAIt(c(3jI5XG4YhzVl1pXRqfoZUPF4gp3gH6wq(xOkGFAzi8)(8Bk2OTiDZZCKI7ti4CkSpFS3ke7n9kcDSHmKnSNR92SnXUW1cHXxmnlhOvdFz5IW4XxiXhmX(MXKqbtAoJcQlwM8gVCPbbJYz3851vHjLZQvr58RAd4RO1Oa6FVvq3nm0hB6joBcGZKAz4KhnwvSMhpUIUXF62jxQs9yY9xPo21xiA0P7bFUFtfnkzuVjFfXlEjB9cUDstZ8nScScWAq5xuoPmwp1trjMs1fL0tkvjfuSQ9uWzkWNA7eVDOjQYTLgelmzVnMleUgSsUbu74YFVc9laDYoEHuujluDJzpk7n3Yj4UBMkCxUXrbe1XncXZ)I34vX3w4Dl9KyCEEuNCf5tlxDpqFUrziKmzR(KMHPiVOyTQZ0tP1LAHt4T8ZpEVGpGR(NByF75It0t(l2NzhonYGtWsWyn(SAN(InrpP28yp9wL8OmZEzFKrMcXfnXhBapAK6KyR(JUqUijiK8p(Pj6pVzjlhxBZmxvrfE2JxyuzQPbbIjtWAssNZZE007TnZCLK)XCw7yUSudwVxN5e7Q6CP5rHsFkL5d4i(xKfNaWvOQEqD)TnszwmzHMcnOXIQszHhgQmvYkoiKEo2PYnl50UIKjte1ZeTiz0pB8PmKdQT(9dtnq5XuZdQuXbrAKQTeNOIDqLq5CTCQqCcY1Xjxg(NEqW5YsUl1hau67uFYrrZUfNR)BMNGt5NruoXi)KLcCAT2fw4f46S3X1lH8dFzDzNL6A26OlbV62pLIqfPm5Giulri)rsp2Sp3EXZVsPvpwkVYr2B7STko66RB7uZ4XfhD867MnBeB8e(6ntQhqbtJOWIhEg08b6I7xiyC06Ij)SeN9Z5l8p)RKFMIZVqHf)Bf)wSU4bUoKYIhCJ8sqrEoWRYrTWoLYIeaPQGzy1oNsZaMVdQGXWnsWqLEFsZGUZDwfmT8vj0sLwIICArnknPJRGjMB5iMk9cbqUnJLqmS5NS4bgROynhkRYuM5yI4o1eXxpCeHhT3VGPJFwnDC3mrZk62zwKti1haMy(Me1eMMMIeYrRETI4qGHr8)AdsHB7DAbJ1RM1SsqbAlJ(RsfdnYPBQXOkrPKqp8g6uigo00dTBXiUDXqixz2qz67lASkQ4V0VpYqqUmZR0odJCZzLnygT7WmeuYBfv10dnpDoqtpuiOQ5ZqO6gm3EmvQi0dVL3QgOZBlnIM8yAyneaXB6SaqfoziZYzl6Kne8jZ6iFRTrgEnUf3qWkVProSw2ZB0eTn37BiUhXBAKdTE7KkEBOP4qGUmp646sonGcZBLneKl1SvL2NZHb3YSAvVx4OR2B76VoeIrMxHm9UMMOImha561neGZB2PkWXnsNMGDbF09oYJKwYdHo5nhjGMAO5jOz74P2(J4BHBXdKaCH9ndtmYmPv2(EmKapkTXhcPZBDuMNNLXms5EmAxmLTVAknPCk56XpeoM3YSmoolgJFM42MAaqKJ3YVdHr6LIkF7UELtvixzR9eou6QWRjCg)UthooZGl5YmUJDOCCh)2FhoUtJBEZmUQyyCCKSnvzBXqgYNQA1qeCYV3PrqNU0UJ5rBB6YqTOyEy25IzqCtc873BKajN3mUjezAxiI7yIzkgS7aFJStNuMEsgYATP3f1uQjP44v3W7cHreROL31VrT(PZfzCNMGXGaDiCkH66esLMZtpiJu2tdABtnOTD1GdzBpQn99iYmdVZs))hrEtkZvOXQ6ZFT39XI)I67EtrYWgeujFxmaowUtoFjspH2WKowDmP(wIilEfSwbRKtmetD1AXsyWvcyZKRIuLob62sY3cHi449l0iwwahRqlPVP)g1vKTf4x5Dmv65WPjEWNPtMY1NMiCmVNNNNNdpxvPwkEtebDkiwc00BB7B6CzF32C1cDRWY1OcYzMe(y69terJSBbr8nE1pch6lonQ6Efh)6R6guqsvKA4c1JstWGVlyiSnyC20hmmUrym0hkeTIG4V1TYUZqLxi7jxxGzybWbOHsr0pKERVvIQ4GoYzGoIW3Oz3MQnrOgRE1q6iLDDRdAxNbAx1vv0Uzur0u4dmqF6K2G)bs9pq3qtW0iRmt4tWISepP8MFZAEtIaToTeMIi(OxVTIqsYUuj6ik7hvTLQy)2EQPxPURxrymzNtUbtU6WqeuZNAneKknp8uEfD6Gtf67S3q3mczilX8Qew2wrgYIPOaYtNqjQkwKyo5oP56xzdXQJSIoTwlcPiZfrUG10jIPEWP0lqxAg4jcFi1xKgC1vh24q0nUieTYuQwwsuycfx)A(j4vr1P0vRimPSXD6gNyP76ZIqce5TRldI0E)LiOsRokci5TOkdKSn1lLqDuTNuPHGrqQUxBETogwZ8tZ37B53xAcLR9nLvwy24M4e2QKYwMagR)SmlAfT2iw6a)UdqtgJqhYVmZU0FXQBwepGQHW(NLNMxkA9yhQEpMonbazgjRWvYVsVQyvu7hZm9RCnlAzPtqV8S(IJPBp6f3beiyxEkw16QbU37MzQANzgxgR4g7rlBOzAkTPvJlralV0u0YSrfQsIfb5PNLK(I2PzJrtOZbSjs3pl9EIewJrQANAhX(PgHYL5yVOWy3VnAnm6)MuVXBW1Xk6zFtASwv7tvvGOoIA8N0s)gJMOZxPxpBRPmJKq2Y8Jv0eO(eTMLj23K5nRQBbrhLJrkAZBn2N3akdMV3JlAym)UyOQ6hQQ((QG2hQQ(cczOQ6tgQQ(HQQFOQ6pQkve6zOQ6lxpnuv9cH(qv1puv9Fuvvp3MyTixmeEFGkSioul9L(aCALv7d1sFJ1sp1aM4Qv3i1wr1UZHSu7teub914NQ1N(HJF6PcSprqDZxJNkRo9dh)0XsQp5ePA5PBh0(m)KUKUJ3(9XQg6teuJ8voDvlK7cUjGdtzZNCowz80fWktyhdx5wp3D(OQw(KH6HVXC150PE4PU01uIoDUotixlUwvWxiRkRx6olMYjSpW6IprqTV3rgvK6WjF1WN0Zv8UrsmrQgF(QZ9oVXMaPGcDI(MNuPzOBkKpuD7N(CBRRU9(yVsbQ4NXf9EYqnTput7d10(qb1jamd10U4ved10ElNh)8TayOM2h0rAwhr4BgQPDTMgg0UAs7AOM2BAwL(Itj)d0nGed10U5uf73out7TeNk03JhQP9oWkd10UMU6QdBmut7gJzcA0n6WTVM21sGPUg2laHORXs0VT0IGAsZf(TIAAswEuv7oKe1FK1izPW)O6RXNPmNQkl2v2TVoG)K5xhz0CiQbePrwiP)pP(yvMgZTkU8fRBZBvLt45UAonWoX0GWWOPxnPPptZDsV9rE4255Tss)OoNDuxsQbZ3pZBLguZnLw2RbeyiTC2rD7eqw1)x7NA6mhvK9Z3pN7mfnFaP(oX2Jiu04leTzJq8xMMdfOwWMsc2xRYpgjnthmEVkJsyDyUUyqsxGhVtpTXgiy2u)7qUHEhH0x2qxNqKwsrk38TwCRPf9xc50tp(RqViLmZYq)paPAt)22FAiw1niwItVJbXQeXQPPF9XxEuK3u023JKoQKSaHjS3C0A9bvC41x36PUXJlAtdxF3SzJyJi(xVzs9EhIXnpKePTpOJ6w6vNlV)22TVD9Dx1Z9XoSl)inBbpsuo1kp8mJhANhcAZheDMes0P3IllX)m6jpFV3FC8)zye6zuu2hS4)l]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261121006,
    [[Hekili:T3txVnoos(BXV4w(uVooP7KPNbXnWE3Hd3U3C7UyZamVzfgBABTrwYqFK05qq(TFfP(IIIKIus2j2JEyg0rsS(Mflswv5fxU43wC3kumEXF7QzxDZLxE1LZMDZI7IFzpEXD7rlFeTb(h(ODW)))ehfhMSm2nW)T7TEo45i3DrtxgSBc5tFXlaTIaUhsC9I)l(lEqiKJ2JxU4UF)p)p)1)()X)ZVSQeKlUBR7Qv40XHJwQcF)YB3hVf)29zp7I1bH4NWHVD)k8AuIx8B3)N)h)6B3dp(T7RcLe3liuq0fpJc9cw(4fR2hDbHIxfDbLycMs)RP)ROa)jFgWtiYpYd4JvW)oGGx3O3UhTAvG)NG)XJ4xIMcibfJ(fb0J1)7F53aGSnoEF0VCXfBCJ3M8aHfUG7tNaWeiB0dZwpBg(RRx(TVaG9xHx556Vbarqs8Qac)SpXZlcEaYhOOvj(BWb(aHKebYdpmk0NqPapM(v7XauxIcX5Jylg5fV9pHa(hgWoKp6T7dXldaA4faJ)9WvU(OWxYWdidrprWk8vr7qEEVDVFYUhiSwWAGTd(ncsEERRhMqmHOhi)Jyu4gCmm4neShLefJCPK1k8djRxNrjuAeWtOBqOBSlMih)NixYNH2bMDe9NNhiMYu27D9Pa53d(97ajxXijK9)Wd9cHOaj7de5iinIyeh7dXrrjegMI5Lb(GIgWnXKGc7iShEjvhhSFFGp2pEkythgSgySf3HOwprt3teueem)zxppN4ahaOp5(e(ZURNNzq5G8Ghmo)VIItOu9FTgmSNFbfkbRDasWbSdIqpI9LdQ8VWjN8fctyMdAp2bfg7gflhy7af(oGnZb24r5VzlkCv(t9WRgt0ytRa1PRcE2xm2J2IIJXHoltcJeivuJKvUutcInukaMMSp9nvaRc0NAChfdAWpdMaGSDTZMLRMF5NjWgSrCEadwuZ)YmcTLoSVpBSEePCucZqD2hqENsS(1(dRHO9URCcXBW(4quJy(MzS6ILiFNSP8PI36qtHmggTV7dar))H5aA(JbQpCFeof2mpNc0Xexot36E7SP3C9)g9p2H(rZOIJHUUn4wmwwHrXBHX56PN(cwJb7hb6mNu)CJJd2SXdWq(ZJkN9tSNDCbXnc8tBi6t5X(d9JTGj9GP6R5VE)t7DY9mor68zqW5aJyLcB38)cgiXLs2Gs9IxmbohoQ8EeK45aZMESUNdRCu)kRvmm49W6ytYqs(WvPSdHLIGpATylQEuAxabkgZDtKH0XJs1fVZMeQ8I6SMSYLhRQi9jorO1sgjrUc0WEEVnz6PcQi)7OGYepcrj72f47Sg7TnXhwrGhrPVFmRfURpe(H)YmdX1e6pgTdcYrLHykAEkWD1ZiVhBepzbNfnokWlOere3PBEPz84URMeldbuq9qsOpX2jDsuZGlkz5YKhsIKaZyKhj(Mvy4pCx6ab5hpf7tw1DLq8LSxnX7Fmq2Yqyob2HDb(gSX8X4vrSdy8OuapToSMI)bEzsSIjKeoffUlOMLqoAtJGP87uUGdvl9ORVmGLtPSW7rFYQNmOHaG0LuTK(9VkKSu7S)HaVkbosIfb)J4eKxHSf7VbCTVQIVDYgLwsdzZeFnPEhjEU1eLfo)Y8GoE0dbrrJhL65BQBKd9VlOHSWPaVf3EftqwPU4aFQCF5ZU(aZiMwFWliyf4em8fUGTe5toeT0f5bA1O4mGo2I1Tu(cVVAPbtBnQKkdcJDi7nRCHqyBopbRbw8nPIccZnjBLXskxHzjgOMhrNASwkvNopOa20N5eHJL6oHSrI8TEb79JSvOinTafqWJbur8Eenfff5Ub2Wx6wvM)PCy)PXP79DQqmxL81zEtbyGN9OhiV9H)7qWaSWVotW(2oWepJrpEOyGCyxN4ZFJ5eo1PfaH1UHynP56HohGvhf4diFkzUf9uWsUPLbG1ty2SH0zPAqcIeB1iR0PCJhzrijiIYvbXtRqjFFMKLpamV2dTb2aPUYeRSOdYwbb5d(O8q7WWgs9FC(1VALTSMlekb5i4Ywdmtpw80q8oqFeD78VmP0Lddpk05HjQ7CmPjBjL(4zhIh0I16lEArSiGsqpUbCIMT1oryy(mZ42uTbjUmn53A2qLK2ygoOyH4Vp)QxvR5nJGHT8hMSN8CnjyrteYDouaRAQnMxvrXX88svhVgHBWMQtq72d7z6LSZvR2s0TKNlIBmFcoAtG)lzroMjqQ(kA0J1hhS5NDIhg9nsgf1DI4HL(Q0Xv3ffePCUaHswQzeHVc2cWQxYcHOIWvrasvGWzVy3eZtMzGlFbwbjZdqeyDcBL3P6ZUQdIUcBH4WeSt2suW2S35IbaZVigZsyLu48lfmxNgbqhNq3OOrp2waxli832XdEK7t62lN9A2ENK7CQz21idKhWWuRWhjxL1j2(lkP8Z6ToLPMzocGSGTkcpXFPl92bYIcRVJDqDabMzS1c)0cM1LF(ccM8D(5bx0j3wCQMQCeN)onod6rkKOLNb8xMvCgWvwXNCCXRdctpp9XJaI)jYeTPxonN2lbmmlkoGCtwa5S21ZdhwaQkh9SQZKIEhb9M0O4f0lfP4Aa0qiXCuvIeCf8vwQcKjFOIqVGVNh8AjpbUYHGxTKlQELo29ljW)2RV(1rPlBarTpZW9nbsOG4wfTQOn(yXsi8ePaVCL(q7MQZyxJfG6zIBmY1Sshfi8gzjYSL8NzB2GLok0y1VtPUXqNl2IsI4s4LqPimtlw1fnmPZsJpbBKs21WX4cwYbIuG0bHmNqU2rXuo02e4S53jZFCf1SaTDY62UC1GF9JGFDusCGdkogT8X2OKA6IGc83KGRCdeSBitIHuX2WbZnYwet2x)EEsbSQmQk)tX)ylkjI8bMsgSF7JU0n7ZthLaN7sJRrPv2yHq(WSlqwhgq4njBYEm1bjkmTzpE6zgD)gAGy9VvbnawXSx(Rzi98FeWJYVHbtoYkDinzhkLaIsJdys1zzjX0WD)2G6BDZasNbcsPDdp1bdWE9ZmqVJFqVdeWKy50HOvE7LDWxqdWv5I0SWxcaizji)f3wMJ6novDe)8o2mEPgyAFMIB3B5hU97qwHB)EKl42hRma3(iM332h7S92(qNJ32hWm72(9iFUvH0(oLD1mlUTpc5UT9HkJTT)4MN2htvDD)AAMt22hMmX2(qM)12h0SU2UpY1A7JqgwBF4ZRA73HSP2UhYHA7puzonxiURdwMeP7rr0U8M2(dF2sBFoMJ02NdxVFbSfLz02YYh6uJ6UKVohJ8I2ww2qFaj)W(nROTfLl0hqYVNYjA7dxMqBFsK)Z2Nzz9SnZrDyM53PxopB3LSvQobDOY0z7kNhRzkfrg8F4YZz7HSB(9k7MT5p16UBEDAi0B2K0WmAU7cUc7GpYz2CxCgjGNfD3gTIdoM51S95y2mFwSjNmvQ(5ws)elq3YC5o6dwWSQZ98wwYPB2TCNrJKKHro(oNTY2d5OCxYrz7gVfzvoSeiAp9tMUHmyRxTaN0KZkL5siRsY9mo)nRHntYhz7HSqwHOT7zHS9qUhBIaUf5ECNwgAWF9bZFDFLNX2VBzxS9PDofl31JoKTW7wT5D6PdOvyOko)HLF)aAGoHNkVzG4GKRW2NyziS9rpVGRTN(2HZJu2alnskDivb3BxhM7keAMNVVWWidWngVls(qRNSU2zzyI7sNWKAjqQOHoU2tCyHalK3H(xbHoKvHeNZOnrzlrGKk9pbZWO4ptAk7ZJaXLh2zxIxSBUrrQ7vVGnUlBeQBb5F(D3sEA5Ho)95FjFH880cESLGpHIZPqCerURWS3NLi0XEkrSN01A3nBJDYdDr4rkLKMRQ6b)07mU(TeZZaxQ(IEBGBuQsYugaylvfvX(8lBd4ROQva9V3e0RUWKLMx7CY(jVoIDn2Id80PivZAqSjEbydebldc8i(WIQq41pBYXwQo4slRkwD)PRNCHkdVj3EP6dcDKOrdcJjWgyuqJsg1RYNR9SB8wx)RN0K5zdZTRaSg0yyuijk89O0mVZs2oMktEHQB40U(JHyZG4VDID3HN89kAIgylM8VLLuyPXQ3nAL3qOMgrNSn2ifvYoVhl2DD8LRhx1p3nZuH7YLuYHOWicz8IAjxVil)meRUeqwtglq1wvNxFJ1nGv(nnprJGsu4rPwihc)ww1tXoCZctwUYWW8Kw0z(PJgU0btnH5RzB(vOWd28lt5D1qqbZfNTF83ZnJHLgPXN1illn(SA7aKnB)kC7XUdYkjtxQzvFKwEcXvr2V1aE0i)5io(HGlKcc)a6)4tt0xVzllrhBJMRQOIO94fgvunniqmrbRjjDoR9kYXZ2O5kj)JPw7yoTudwVx1CIdPEEdPLMYGlLfmOYiivfM4O8GER(Y0m96vfdSsih3Qmc3jcip2meGNPsFNqUI9mi4hw67idJmOYOsV96g1j1ozfHr)yI(qgpDmzPIy5u4oWsuDhlCBZLhYx(wMTgvFZetELFN7Qc7woTRir5er9mNuNm6N9SbnKdQ5m2450JKptsCQwsFfzhETX47piodyhMYt6j7KoljHgvOhrhcMq56q3c3bx7NLRC6RCQqC(C2X5Rm8FXz1mxwcg22jbkvVI0U5M9FZ8eAl7yCumJu6OeSPYA3gkSvx0E0s3yumRwRq2zRUW6o6sWlV(KueQiTDheHAjcfFQtMYhDugWfJ18lh3BN717)bFvvCx5iWE3LZkxIHLURCeOTDQLko6QRA78alR8Zr7QBMnBm75Z(1FEs9dO10tODXDpbUza6I739yYTxer)1wo9NOy4F(3O)6lNv1(l(3Z)DMDXDC9mOf3Tm0ngh6IGxLHAH9oOfXasvbZGQ9sOMbmFpfIGHVibdv6gqnd6o3RHi0YxLqlrSnji50IAuAspiIqmxZrmv6oiGCBglHyy7aAXDmlzrSCkyvMgVaHiUrnr81dhr4w0nKi0XpPMoUzMiTIU9Qi5es9bqiMVjXmHPncjHC0Q7dj((aii(NBqkCDVtleSE5SMncYrB5TPP0WqJcMOWzuLC6Gsp8o6uigo00tr)tsCduIsUY8Hgv2jK0ywu(FPFNvIICzUxl6vsYDNv2YL0UNlrrjVxuvQNImU8aPEkGGQ2XeLQBWD7X0OIsp8EER6GoRrnjs5X0cNOaI31zoGYdYqMNZw0BNO4tM3r(M9Km8ACtFIIvExJCyTSlqPjABUBqrdpI31ihAD3jv82qBIIcDzr0X13OAafM3CNOixQBRknuQddUL51QE3HsxR321XPOeJSOcz6MtnrfPbaY19NOaN3TtvGtATunb7C(O79OkjnPkkDY7osanjV8cyxEQPguvT1hjBRDXD0tiGeBgHyK5sRSHwzibEuASvusN37OSiplpGoLRXOD1t3(YN2K6NMRRxr5yEpZY440d09uIBBQLyr3El)kegzxkQ1o017FVc5kBUNWHwml8kkNXV60HJZm4g)nJ7yhkh3XV83HJ70inemJRYhghhjBrv2MULH8PQMVffN8RDAe0fjfBvh2sHBw2VCXDSP4D2InFr2k0mz8SH8vtTSR20ZU6At7IYQDArEPuhpZ0)9SldBAxL6W8bWntrw8fLPAUHYM20PVAzR(IYa8rzyeXkAAx9lNTF6Zxg34CyN)LpeoTNUbCuj5n6bzKYevOT9dL22quoKnjS20LWiAMV27XcDYiYBYyUcnw1E(RYofa2javswkQvET(kgbCLaU7Y(paTym5EpOcUofcNaowu5s2k6VObJzqhg7a4P8R8reknkPIuD4uA7zCDNmkhZhp655MrZmvQNibYsSbQSrwGUDpQNw1tZO0uNIivWu422nZoxwlPnxgq3AQhA09oyucVpTcnQOr29wi(oQ6hHtXlob64j8T8eT6sAujRUbKtloFdNJ3ChbQgDlWh6RF8Akqd9KNE2cLgt41YUWoL3gA)2IQorniBxhwJk0LTdMsCpi2Ll2RFmx62(1Oc)gs)K0RxBq6RT0NpBBBq8R7ESAZIFdlrCiwIq39iY0z3mtVrXI0RvO4M3s7MzIaTon)O8dMqVM9gLKKLYrfJOSbT1wQI9B7PUaN62ahLXuFE(sDbQddjm1gOivAEqPC706GtftvyVdHzuYqwIr1W1xPbDqa)nYINQ8MvAfS7ZwnhLo16quBfLk7eafqJ6CyEQo5qkNiD98YEkxhzfD6oDusr2nkZDceDIyQFIl6D6nAEAku(qwgEPo(uDycM7c)g1NVwN8cXIgEV4ghWblcPqK39Pmiw0L8eb1IQBHcsDtdk22FNsOoU2tQ068Oiv3ZHOwV1Rr(5NA(MTk)(sFpCTJS0Y6XH0uYitNv2)pOyvMtT8w1flDqE3t9F74JshYVOLU0j(Q7pHmGQhO5pX7cQe18SJ5nNV6eG80e5NKNPlvPdrTPpZmjYmgkk7Ak65DUivX3E0lUPnqXU0ihfhKHjDhW20EaP0u7sIJQWqEEu06Q4T3BuGQ6uGgxrKujUChbQ6vGAAfvuyNubSSOt10dwfQsSDW3KMI(mTDVkAwPv)7HQDesjtz(YfxSjfePG(u4rSrfsPCzbKk6iv73oyif9kwbqHQuw2QjwdBwHC3NvYTODuXUa43AxSRvT9AzKPvbIS1aezg0RDkrk2BZfBQJjwPR3AkZxBShkcugi42tQbvc)UyOiThks7(Q(Ohks7CczOiTJhks7HI0EOiTpQgvu6zOiTlNpnuK2cH(qrApuK2VxfPn3IyTivpeE9Mk8iouA2LXa8Xk)Whkn7gln7chyIl(zJmBfvXmhYk3owqbzxJFQwUZho(PNQx7ybLHDnEQSyNpC8thRq74HIVwSJ0gVvT)ix815SQQmPrbFkLE5zV3)YXo(CSKRlTuvLGrgobSEUg9Evg2XdfADJ5w0hNcTM3JR0eZ6Cvti3kUxlV6olqp9kQ6o7NtGuquc(1kE64uO1XdLs9z7MhZmg0VusOYMtHsPUpwtqWC3Z4kSoEOaQhkG6dvThPYOt3aTBtnKD2w6EdvhxpBHoua1DZGCOaQFNe7dfq9hkPpFsUoua15V4mzjcD3z4qbuBovX(TdfqDlXPIPkrdfq9qbu3AHEgRmua1AfFQomXzzbuxabsE5k7M)vxW0QCti6x9xrqnU5QmwrfRillzQDvjI65SAKkmq4VY)D3xZmMPSCgzx(RscOKg(AFKklIrwrgI0aI0ihti10jeYQuq4hq)hFknmSgZCgUSbQB6TQYjIURwqhSkMgeggPE1KMoL0DstTwE42z9wjPFu1zh1PKAW89JElwEn6lWrQXPlH1i5vZTKCfG(oADG3Mkix9fVOQ2YhLxM3vFzAQl8QQFSDRurW3k8YDk)b9VHRus2p((nnot(T5xSZwgLw7K8YiDX)O5lH2KgqzLFVeKt6IcKqi(l3DroQfeWHGywQ0BIBMoycPxgLWUlI6IbjDcDsuCfTLadMPw)QTB9eg1MjISsYNI8TwC)O5DhcftGLoS6A2g(TFx08dZYT(3bPAt)iN)XqSQ7zJkoRtgeRseRkCfD8z9A)U5pU)ARfFC7RfY2RV4tu4dGwrsFDXKUIrt9ni52)Q4WRUQ1ZDSSY7WfxDZSzJzp6)V(ZtQ38wmU7TelTRszWQWYJxUDHE1ATWjxqVvoIp(XL(Y6M63E9roI3(JSBt4W1DtP3oU7qWZJTgvVfCnHuDceuw2n(K4Yr2HXQoHMvYdTlWBT5dQNaWxakjElPoD)VXp665(29w)xbH4NWHPFWI))d]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261121006,
    [[Hekili:T3vBVnUnY)pl5nEDUBphNN3BrYc0)3Hd)7DBFa1fOVZY0s02SwsuqukzZHa)z)gs9effPeLTC2M0ffTiwsCMFZWHdNzih05Np)xNpZdLGN)Jxm9IBo)8loF60BMpl5Pi88zri3TO1WFeIcG)7SFy3IFjLeUBX4hPpYibSjU0Gt5F3t(uKhNwltj(jFF48LAjllc7oF2V9D)YN)P)X)5JOvR8jUjeA48zBiEE4SHHzUg51h3TizdE3I8ND2kAm(bC8UfE4vOu)KDl(UF(Z7wapE3cjsKsoJZA2zpII9PUBpZlIDghQESZyboXWxnr8Zj)oJgE67bUeJcz(Ge4b)nLZvcB3cKNhn8DWFSf)eBYUf)tuc6JAqZ4F47)vGiBssIyF8SZwts2KUKlaNP8PNc0eanA50vtNIVAL7hUei7NHx5tcxdKGMM4r5stuQVpdEakeqKxA4Amneaskd0g(yuCihPGqM9vryGQUOyCXi2Gr(jB(BiqbadiafI2Tig7sbm8eWXFk2JeIIFkNpGge9aNRWxXcq((7weMgSKlA0vGyt)votECdXhZbtmAj)psqXRXjWGxZ5olLLGicy5HxMUAvoseye4tmHgtsiyUE8xqe(NHcaRn(SNVpOMYNQJiHcI8B0FBgO5khjh2)Sp6joOan7sUEe0gmj1rumMXs5cSGZU0WKykWBAyoTzyFSRyoMgfrdXHjtaR5y6kqWMpdjSnz3)iX33jH6aK6bYd43twDFUDKdYhEWOIFXssfy9FNpY)69NjglDLdWohyoNH2IdntGIVWPaQsucwwGIWoO4eclXmjcGP0aqqkiXOtkEZguSxXt9XEJ4ZjtQr1jE0hdL5jBdkjbh74MgZ0i3TtApIyQMBBKrGjPrzVPgzBW0mtvwcmF8Eycf0ERCw76D)5VNtryg3zjgSpU)YPCeLn1)PPJSdAQmcwL5er5pPvED1HYRyueXZjgVghIJrDYVBMkRTDrHo5lwZuGnPwdTimMqYsaG)xScPkEmG04igoJIspxqQrCxet2qUB6KBU(Vi(ra6lMyGc4VEF4OmT9WOKnWxt8TBEa8(JdzWCHtMpOrj01R9b6w8Cw1AuUnPdbuOiWhQvmntEgoMoAmSifm8EU41rpe5u4R6uL1FGQXb(oVwS)k(fyIWx4NpOmVPLl4kOtZ140uFhyDW2MRVhxWWNLTebKgb7ICAoPlgEZjXyW9p8Qv6Tpgq9zjfeCSyzDothDsM2(RYuDt)AoR47r4lRSZEIddTQ23Z1Ca)Iu9eKR)l5yX3jiq3RBzPbb0qNvy)nPHGxyvYN9(rY2MKqyR8q3CJPvCSMGcGagAAmLr8hOeVhr(B7K65H3WgXO(0kYZDRT(jtuNe0qNKtwbbwMghYN)Zm6nrewQRB6YuMbkLG85rd4HHFqCDGiHtMGd57L5PLlPr6aA4XJfUXGnm2rEZYoStcXypM8agDsg5M0KwtWFb7MM0yzdxQqXb0gZRfmlBN)QVtJRDH2Flj0ejkqLmv2gY3tsI4CcKTr1yJF)ZAbJohSlP(jVFf1nLb7eldlyVC8xssr(LArC4AWTQxn)Q8KfCfH30TxGmFuCVMwYOsNr5(XgDYskJn6KmprtimhXVl5CEqiWA77Uqk0KmNpGpoLV8rsiicYiCPpL6boLIFsjefDEgJrUeKpm)XsYj1OXYUok2w75XwiQJpPcB04ehEUivB9aH1)aSRt53KPa4I0P57fvH8gMDyadBrV2eOmuNzNxsBXZCy4efhc8GPls1aYRHNeal3O(clT10a3raJ4(bytqmgznKEtwy73)UcE8Urz53nrlcQdEZRlkhmefZwFqhhc)7Xe(Y8PPii)2ElcpIrBp2WVGhnHEXBSf2chsW4wrIXwI0MbIsX6IZkZ)iFFS9LWvRjQwgk5I7t3FXZ57JM7lgY03zLpkadjjfU9(Rp1cnaKwsCAe)xdWmwX0rjnNeJdavm7U7l2UT6vC3mvBdx98YTFbxi5jlOFW3p1gbefebrj(uEE8nCcUNsA5oVlrHclp0AA4t579MRgQ)kX(VnhhecyG(HjEJHrTb9a1v)WYEv24AysXJ1OqHiGv7cI2xbbm59uUt6Ak3gB8uBCdG51RdLE3MKms0gAE6HhUwjhkse1wVFeiwCEDEhoquqXgR7lFrTv9Lp18A(Ad0Uv87PyPZGZNxn67oF6ZA8tjme0gctdTHy(44k0s(XDFccVkho8G6HKGDQ)Sl6PQr3mEPVLK4uSdhipG5jVgqWaHR84iI0Bu(79OjsQW7pxZog10v752cdYgCAK5wMRhyjWIz8LyWNB8w(zL8kl0(kK)gmxL8PuPSRZ8umuBmQXSSi5ynwNVv2YuxbbllGwBENkENfLX8Kw0JvLw8YPLLwSwyv8QqUIgNvi2rNa2FpWnFNC(KcSxryW2mHYp8caoRi((44ssvRIMnlEIiMHbthu(cr9YlRASfQgPAQOtDvkn5NMBUwrO48PFQiQGkzcCbcXfm2Sc6zXyJC50)URV(5tgNN7J4aSZRD4P2ykbAiAYELiWynk5X6bIkC147OYZ0HnjAYHt5iEKNxi)a0eVe0rNmwN1j)N5HTjZUYPOMN5WHH73EgFN2LhR2cXAS80LiiH3gwBAYc10P2i5A1uHQ)tVYun0r5XAFSJ7VpWV574fW3bknH6GssqUB3Njj9LgNgUofx7a5KJt2Grtz6nGPfpE90OMv8oJWnVfgfFa(lBqPmrgy9K5YF7wIi1jvUxrCLJeRb(QffQw0B84X6jS1E(yDxByBiDlMSYLgEQHmG7j3mLBRguyrkTTLsSPYJTFaUrTW0GyZ5JTF8Szwu2LqMDPinqwMApNIw3kqMQ2KOEjJlUcKnDbtcDrrq67jIRyQ80qlN(6br3wQuYHqxoXij4aMfKTwQC5x7H40gxZpTiQXtCKPGmLdq)oKckFhh93SVUqwNhK6ylosuiUkB(Swp500iiilvp51oyYSaLgIJ4ulVkpjXo4JfNfjq)tLZmTvfVPJa2SgTUKYv(n2buwZ2H80N5hlH0RhLVUdV2SuwX9xsL(l5Icle9dsXlxcrzD(kY6njofjuC)ntBNmgUjtAddRdlbThwW4EFU2Di3goaWXAcFrLrYVZcoP7SWg3RdRRdgixMJXYP6C50r1NgVzQgsPzVTckAripTynueCDzUK57QBgb6cPw5Ulx(8EDlmmPUShA98AUQR0t2OXRcoTrfjEopd4708b8mGbHC(ShG4SGxQ04t(ewct0Rvz9Pe8N)OO3RYZ9D()xr7MmFMs7MmFMBmeGvmbbVkh2AB7K5jatBJM06THs3ewTDu4C4sdCOwJK0nPp42uHJLRmGfMC)LyglTZY(0(kCWCTcyQDXYb92uzG0Zojz(mPqy5woLIQ0D2LdIBAhexD8abPSrA44422XXnt1nRyBBUyginhahmFWGzIuhOyaow14k69fXz8FVdTW1dow4C98PDBeuW2QgHOvddlo4q9BxiWJQJUwudhB8u26n679gbCn5dvQjASyvuXVSVPCem3K71Y2SXS7SQU1X621rWsvVOTn9uwY3J00tjfARtEeOUd3TVKgvc8O65TUd68E8r3KNu3)iiKQRZccveGIjpN7rBbj4NjVJQ9jKj(27(fsWvvxJkCTQbISKTD3irIWJuDnQWwsGr1BhDyKG6MIOtPLJ6Gf9VVGem3OBRA9I0XH3M8A1SXIS16D)AwjbymfvOuJa1fkYcauPXHeex1TtDIZ7kPUO9W1Etg6VjbovDhPbtdtVn1y)rE6qZNjs1MhBghmMCPv1lu9eGVi9eLa6QEhnf5zvz7BDpgRVXE7)v2Rp3zpLgMsiXQEMnjXzh(XRjPTRUPsKER6oe9YUu3De(ql4zn4AATN2HwUk8cHKPU70XtY6rjw7N0jpufPtD7VJN0zrDF7NuvmmfjY0MQY9RvpLZ26BlbpBPIkEz1t8q5O8XaxP1RvkXUQLylHHFP6(Z9cS6md6DzVT8wV37R9UKHt5quSyu303KR7ADS0aOJA9cwVV3W699kwFm7fS9PzWeZmQra9NhvExgZ1WOI9SAWxhSwZ0vJPlqknafiQgT0qbr7oxkR6NQE2qvvsDXaQlYxDqriPZuUSbZEP6WSHwJykVFzh11A(mH34gTKgNCveUF6vDMs)bO70mVlNqXDqbTPrIBXkzOXFN2kM2L(k146mMsz5n261uswk91MqIvJQ8TzkL5Mkno2yHk4GIlvJL((2UBVrcn4ktLBVTQKFyx3ElUx9stcFD6voHQP9QTPE4ndJYP8fVc6fb1MrONTrNqhBBzbfxS4EUAVpTPtdzrJRQN)Q1PoFRrzoAgNzXpz6u0A9ScpwTm2FSTf3VwWJRLV24HgkFGhFtr3S986F)5j03QPtnKox)MhPJQhPRvZOZyjiR6UV(ndk4IXZBU8yqY6OnDK2MweQiNr7A4pbKmv58Yru1KE7lQK)2bQtaBVvafcMPt8UdVF2iqApNzbtnfEF7NdHn8SLfnYhdXubmmfkDTc7SxWWuvj0apBkgrBvZqijgVLpYv28GefB63qbumf0Is6EheygIgrSLux5YXn7zyb2ifshj3nh8UHYmuqrB9r3SCmLW1YgfuWoRR3L2RqXEXsBl4K(sSTxSu1nPjww2VKTYrbjT948KBeY2LJgpPwtukyQQlptmTrxw2T8y(4CSPvjhQoQ8fT7X(Q0wF6IhY41c5gZNGLT924lyN)nC9B5FuMzmFLwU18bTzttj(IoR8IUKYcHFiMz0FTCU181OYIo2Sz0o8cPRWbZNkM2aMBJlgVtM3QURSKXvVVYlTRpnCoy3QUjDteCG9aQHOCRbcZNlZb3HOvSx)XgFBFodJHTTsfS3uYnDe)AT90V1yEfAtuZ(U9ux6z21iQDD7XeWUpfo1EqBzlx8btzo0wzBTzATTExTZMxfqg)F4vMzd)gY))J3s8j7wm(FL))Q6eVE()7d]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261121006,
    [[Hekili:T3ZAVnoos(BjFXJ9PEDCs3jBFdA3a7ChoC7EZT7IndW8nRqBrBRnYsgsujDoeKF7xrQxuuKuup8J4vFyg0XsSEXIfRISQslUzXVT4bhebV4VE7SBV)MBU9MzZUFXdKx3Jx8WE0QNqBG)HpAh8)FylYj4L3F8xcr(oV)44xcEjYDx00vb7MqF5x9cqouaUm21J8N9xSukSJ2JxT4HF)p9p(1)2)X)Zp7G3f4h4fS51fpS11XbNmmC0k9i8NF)rYw87pM(BxVoie)mo89hDWRrXEK3F8p93)13Fe(53FueoXUxtjIORFbf6fS6PRD2hDnLODIUMsp2rSbyVK((tzpy6)mkWFYNaKc)wKhWvaGibuIWn69hroob()e8pEc)A003F8)erq)SeIB8)7F(3aGSLq2h9ZxF9gxY24Lu(5AHxDcatGhqlNTE2m8xwV6RFga7VcpYZ1FdaIGyItaL52h75fb)aJ1CI93Gd8bcjoceoEyuOpLsb2n5T2JbOUcfIZgXwmYJS9pGarbmGDiF07pgIxfa0WRag)BHoU(OWxtXdiqrptXk8wr7qEEV)OF8ULuwlynW2b)gfjVS11dtjMq0s6)GGc3GjWG3qXEuCeb5Yilh8Y41RtPegnc4j0ni0L4IPYX)bYL(AODGAiDY0ZdetPZ87D9za53d(9hajx(iPK9F3d9kLOaj7sQCeKgrCIJ9H4OOykdZW8QaFsyaG7a)uyhH9WRyZXb73h4J9jtbn8WG1aJT4b0kIliKNUNkOOiy(lUEE2eqXjo8z3NXFYD98uDlBKh8dJY(RismJQ)lvGH18RzqjyTnqc2GEqe6jSVAqL9g2zKVuyclKq7X2OqIBernW2bt47a2mdyJUk7jBrHoz)Qh2zeDgBAjOofwR4lh7WcjcbhAVkomsIurpsCCzQeuDOeamnEFYtkbwnOpr5oIaZGFcubaz7A7nRCMFZNOWg0rSxIbnQ5FEgL2sg23NnYmIunkHvO27dOptlw)s)H1q0Exh7q8gSpoevlMVFg)CXkKVD6s(eXBvOPrgdJ23Djq0)FybGM9Za1hUpcNaBUFNb0rutot36(TztV)U)n2FSd9J6rLadDxBWTCS4GrKTW4C9mB(c2Wb7hbZz2j25grc2SXdWq2VhvS6NQpB7cIBeyNUHOpHh7p0pAmSOhuvFl7X7FEVDMLXjkxpt3yegHJgD3S)cgi1Ks6GsSINVaodo6SEee7zdRMEQQLJXzO(nETyyW7H9XMKIKSHRBYoe2kcEP1Y1O6rPDoeyymZmrkshDvYCXjwLqNvu710DU84Nks(f7i0AfJKkxbAyVO1M05PCQi79yGQjweII3bUpAVg7Tn2h2rqerjpFeVgURp4(H)QufX1u6NG2bo5Otrmbnph468cY7PAXtQZzrJIapBlqe1C6MxRhpU7QiXsradulJd9P6ojlIQhCrXRwfVmosbmjipQ)nmhXDxzdo9tMI9P766ifFX71t8(hdKTkewtGT53GVgDmFm2jIFaJUkbWtRcRP4FGxft0SGKYPOWDbv0eYqBIhmfVN2nCyZsp56Rcyzukp8EYNU7jhAOaizl1XkF)3Ksw6n2VmWRKJJuFrW)GeJ8YLTy)nGPDNs22PbkTI5YwtS1KyDKA52quMB8l1c6ORwgefn6QelFtDJSz)DonK6ofyT4B3Y5KvIjoWMQWB(IRpn0rP06sVGahWiy4RcoBjZMCiALlYdMvJiPaD0yEZszB8(2ydy6XxvqLbHeBASzfBecH58mShy(7KikOm3K0DglOCnQLyGAEc9rJ1sO6K1b5WM9B2ryIsZj0ajYc9cI9JgkuKHAGsi4raQOwpIMIIIC3ab8LeQY8Fkd2)0OKyFNkfZLjFtw3Kdg43EYdK3(W)DiyaE4xLj4FAhyIxWONoumqgSRs8zpP5eoZOfaH1UHydP5QUohG17fyegfYISejSrHAKKVkewJaw8Z8gS8EWjNYv2MWPcLYpmeVdqA03UD6D57fXtof7xcRFtJQq2RrnrmF2KgjBB(UqP8h4fvietRJnhek7Rb9K28sIVf2MkLZtF7NJ9Ob)U01JEIsmnICoNhEQzCU3Q98n1Didz7kAufghlShZT)33NF7BPIQuAfMQTx7H2HNc01tZVRzemePDy8E6VBiblBzB2AYCyLR7npZBTIhrfRfEXv87QNuegCtNtq72dHQ8A6XzvzNXwYZ5URTe5ZmeH2e4)AQdBPcKYpI50w1XbXCSt(WyprXO2IEoyL8HL8OKXvr9I6GAMaHrw6zePpc882510DUljC14xsjiCXl2BI6PleIf9Qj6GqjLsYGuLvF5pO0AV8Fv9kVsdSPR7AiJjBY2JAR)B3m7nj2lytcs9QSI8O0gbhA2MZI6QxbFFtjSiWAZo0pSl)B3AOWr2SE(ABsym2MskpJPNwXoxma4Iv8m3VhL(CNacNqC(nsSDxsA1sd01kAmJTLW1AMV7zEOrZ6lXG9VWNOxZ3hSyVkO8l6WktNM5DWJzbP)2UsIYA2PBirN9YBJmzNBC(zQQZ(v2Zm4eWVsJeT4eO)8S8tGUKJp0dREDqyYP5p6kG4FMQkp9MPz0EbGb9usa9E0aYzTRNhomhuLo4BDNig7gk6nPr(dyxjt(LqyGqI7GYKj4Y5R0eviv(WeHEbFpZlIcEcmwc(rmwTO6n2y3VIc)VD3DVD1ydcVBsZu3azxaPvUZpwI4FSzKOiJjX2tHLTUnDRYGv(iEHg5h9(FzpeKExnwMgn9ptDiKhD5tMvVSRUr3x(QPk8Ur69MPXLUX8tKmxsUm1lLefQQRoKZWDFDUs)lKyU)pmR2AHDWs0j1sekMeyJie0QNAZ0xD32sG)MyCPJ5N3ZEfQy5bPbkI0ynko7wraRlTLYEv8p2IIJeJK0eYG)DFYLfkOiDuaCHBMTcLwY)zP8rZULwtyaPxxBtonAtqIgLE(dJEwtIZ3e8QksEj0JbbWR7aauiXC3VnOQJ7nG05GGsAVHXC2aSxnIrZc(0SWbB2vCzczNz5nFmD8oVuB6OdR40FbF63KKh(nIWks4AdwIDv11n8PWrfq1(uF2Q3s4zRtqAoBDksUzRJvknBDetKzRJD6lBDOtAzRdyQkBDksqzDiTVZbvdtlzRJqYiBDOsbzRZ3ep(yovx1UMHjzSQJiPJPwS1HmHIToOPrSvFK8WwhHug26WNOWwNG0d2QhskyRZQubwWFY1bRIJmnS)2LiWwN9P)R1Lys)ADjCNS5WwwQ(APkbFtuQ7sMtCms0xlvP37bK8d73081swY9Eaj)EkjFToCP2RLWPD0mHr(AUoEihh5e7Tt7PyWXyFEMwVwFmsMxRshfuZ0h1KkHNpPYR1qc8EQsGxlXZKU7QxFme61RsMNBRDxKC2K8UTNTKnr)bj1DTACc72mrJSz8810NZjUBx2yrcpRzUUN5adMXV8sw3lIWbtNsRKYl91gssulV0tqxfN5A3YRgdsGgo54joTCTgsg32LBrgOA1(ee7cnh8gs8TJKY5K6SWnKrODoXBTgs32dD622jBOd2Aob2A6RuR16KLqTwFStJw1wLmHSLEfN1FMVMaAnQWrstzwRpyjkR1rp9yReVx7W5rkPyfVCOgsSh0uHTBRAKDnyTiTxHHrhGlbVls9qRMTQwPPybWAHXvYGszdDuLFXMhc8qEh6FcHEs3zqEstwhLTcbsQK)e0QJiFI22TNhbIlpS9UypIBMowIHnVGnURQfQBb5F2Lxs)1Idi87Z)C2MRz5f7OXsELKuPa2BpY1bZFpsYqh)bsWFOkRD3SLyN5oH0tViojzn1dFvxA64Xxjv3nE)B1DZNtQ)QpRkwM8MOCPgbJ2z305vNasXSAzuo)M2a(sAnAG(3Bf0xfe4rTneLmbiyZR4WQgnw3jznECjDJ)WDtUwN6XKVDJ(tg7kzJoEp491B6OrfJ6n1RiEXLS11)Uj1nZlyU0exfLDr25k4sVk7c9CPpotDptaigHHLKFh8QbWVnXDhEYe9xtEnsGASbvsC2YL)YiVu9RwYYFVKAznCixoZwIA4nOu6AuRK(e1IovXhPevQoyJX8bV85zJkBA((z6WDXUGzq0ahd0SQiZ948OdfCDPkfiZPyHeip)3Bu(rOsCzoP1WCnw2HnzIeFKgL90yA)MmDEiMwU6UQg)kMlpJ5eVwtULGgKkCWgPJn41Qe(gFgZLBtMp8VsjKwI98(i12KIR8miRg8yqoOr3vA0vQfj(bS)XpnX85nlvjlyBM5klQOZEIcJstn1iqAYeSHK0L8SxEEs2MzUcY)yoRDmxwAaR3RZCYDLEUYBrwRpVQ8rDK4dsoObW7VYUn9T7QLYS0MokLCDQ6jabiuAaB8hsuw4ADp6i1CqEwezc9NNWoQO(IubQH0EL1VNm1aTHrNEQuzbkvlvBPkXC6OkH25A10ISugRdtUC8FEGQZvLAl6dqv5Z0hzRSz3SaX(AZtVJ0yyvtmQJ8vItRvUefx)vO9OvUe2h3SQYol9f)YrxcEZDFifHAsySbrOrIqXZtPPCqh5EHTINFJwZD8eEPGWB7KToo62BB7mZ4XzroE79ZMnI)ec(YTtQEebn9mcw8WZGIpqxcFmiPhMye7JqzYNTr4F(xzFuktpiSf)s2NBVfpi0Pjw8WQqxco0fbpkf1s74elias1bZGYDGI6bSyNOGIHpRadL6He1d6o3HkO0Yxuqlr8Twc10IEu2KoxbLyUtGykvt5GCBgpH0WMiXIh4mIs1CYzvUY1Lse3RNi(YHJiCZ7Hgu64pQNoUFMSzft7WfQjKQdGsmFvHAcxZNqb5yupRq(jGrr8)EnsH76DAHI1BMvVsqgAlopxTkggKqR5gJkDiLm6r0qNgXWHMEY76gYB7gmYvLn009JHb6yWQOS)Y8(Xbd5QmVM3HnuBoROrDyCN6GHsrRO6MEYtDOd00toe01epyuDnMBpMkvm6r0YBzd0PT3dztECn(dgGenDMbOmNmuz5SfDeeg(uzDuSfHOcVnUvHWWQOPrbSw07qmeT13dryUhjAAuaTU7ukERP5IWGUkp6e62i1GIM3sqyixPzRsTHKddUvz1QApfXuT321NsyeJkVc56bi1rfjoak0Zqyax0StzGtBij1b7m(O7D2efT2egDkAoscn1pT1Kk7psJxDXdSZ2I6BgLyuzsROnO0qc8O0ouyKUO1rvEEwCKrA3JX4kjR9LswtQLmHELcJJfTmRIJtoIXpsCBDnsfw4TI7q0i9sz1UAxVXPsKRQ1EshA(QWBzCM4UthooRb3XvZ4o(HkWDIB)D44odU4TMXvzdtGJuTPkFRAPH8PUw2cdNI7D2iONV0UJ5HBB6wlTODTWTZf3GeMee3VVrcKwMbCPcfPj4gtZsBoQjrMiKrygjsuTz(NvfOtrIo1qPuB6bm1LKtAIu7ZIEJ0iIvMLIQ3qy)0byACf7ZzBjFic6ZM6ptPMCspiJ0wB4TT4WBB1HFiBFmTP)XWMze976FDe51PmxIglRp)LE3DnXRzV7nxMg2Ovk47SbiWYDYpoz6j5nEMJvNNPVLiQo6dERGLYSgMPUkTQgk4kaCZKRYuLod6AnQ3cHj4eDXSrSSeowJwsFt)1QROAlWVi6JRYq6ZtHHpsb5k0VByCSOtSxMH0NQQujzXzIGoDEys00BBBW5szF32ClfDRS5nO(45Meon9qhMOr1fQi)YZ6hHt(d(a0tbeBQaM2vb0et3xm9qlzfHBdx93L2XrfEvIPS3ozDKJHgIXrt5L5V1DQU(rT3T7XQ1XCERR2UwZdtQR8Az5pJRbbVsbFxoqrQ8xm8S(048GfSJRfmXigvE(HfD9NMnJYWIQRWV4AUs60nYaTjTNJSysnRraXijvx8F(ikAEpTLQ4F3EQdbPVfbXym9NNVsRJMWqsZJagsvf(G(lrWeCQzre)DimJrgkZmu(doQvKHQt9qc5zYHDO70syCIY8PQO7b1rwXK(qeLuUxLtocHt2jIPA4ZMfkUHHgZ4dLUnu62cBhBCiADrmIUMKxTlRM5UN47nDBaLBPZJqgen9u5Y7hsYGAEjzWaPPh7fFJosluhv5xk1KKyiv0CQkKwPlkvp)u)fxw8(fMYeAPnj1IInTX2qToOTmTzyvLnYSMDcpDqF2bOXlXOd13pwx65svnprhq5d76pQ(sM00oMou9Jjtk5yvgRkXvQVhPYyvwlzQz6xPAw5fbld9QtyhbMU9OxE9wZWU6B(O1vGyV3HN01INACTZrBMaTSjpzO0oVeazcyn1MLSnImjgKw1TOoZAxumzJQyjm0KAPzmfOq99DOPR6C46HugzqszAclT(n018PoIDFkgLRApszNRx)2wQyOxPZ)6D6RKgZxvwAesdjZ8UfLSaXmRrwvxsEXiBvEPlt0BorByXZ8vvUBR7aDnzADKUvP118RakdMV3N9TVFXqTgpuRX9vz(ouRXzeYqTgtgQ14HAnEOwJpQkvm6zOwJlwpnuRXsH(qTgpuRXNQAnwytSwKFfsV4qnwehQW4cFaoVsq3HkmU2kmo3aM8A4TrQTYkdHdzbitKuxXv4NYvT7HJF6PYoMiPAIRWtf1S7HJF6yHgtotQH48TdQ5EZnib8761KFSQSyIKkhU77k2YRir3fGW0FoCLtm5sSEHZTfOnjHAOrGQ5l0PQgIjdvjCT5h05tvcN7DyDjx1L6mHAT4k1gCMSQOks7SykLWoHvlmrsfb3rgvM6WzFnct656aUrsmzQgF8Q(3oVXMePGgDI(MN0PzyA2fouZVN)CBRR53(yVsjQ4xWLcmzOsFhQ03JFPgPtD00dpSnft2LBr8nuNChnL3Hk9TJ6Qdv67jtW3XZ6BOsFVGSGzAjEnuPVnNQ4F3Hk9TL4uZIOOHk9TdSYqL(MjshQ03JqL(AiHRV2E1VEw(35tzqMuFrXQPCkuLchvoZzzDzsdYtJ(6dl(r9ty8zYhNAQAtTP1HqQQ0T5Tt2Nv8(77k(z0CNYBRqeUDEE7K8rf)iVK0aMVFM3iQRcCjgslMD0xQ1h2VO0k9KHVCvvx)69)NvA57VvQXUxp10IpT0YUkzoSs3NoVOVLmBA(DovtD1R8H1ur(Y0sm8ltTMpkWT8BpBLz1A(QaltjRzjh8jqQw3hB4ZdXQPo1k)6GheRkeRn0Z(JV4WKVP1SGSBWP3xxpbrT0xhhs)ex3YzUd7346eZ(k6Skh1D0lpx(T7A322Y2y1m)h7428J6q79rJ7WC58vZ4IM7EGXCatNHWoQ4T0cI6)g)KRN77po()kGMQYHjVWI))p]]
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
