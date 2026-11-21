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
    local _, instance = Facade.IsInInstance()
    if plain(instance) == "party" then
        -- A manual swap can land on our Fear, Howl or Banish. Keep damage off that target while control lasts.
        return state.warlock_defensive_target
    end
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

spec:RegisterStateExpr("warlock_dungeon_trash", function()
    local _, instance = Facade.IsInInstance()
    return combat > 0
        and plain(instance) == "party"
        and plain(Facade.IsInRaid()) == false
        and not (boss or target.is_boss)
        and state.warlock_engaged
end)

do
    local seenGUIDs = {}
    local checkedAt, count, selectedCount

    local function canCorrupt(unit, spell, guid, time)
        return plain(Facade.C_Spell.IsSpellInRange(spell, unit)) == true
            and (not guid or not Facade.DebuffBlocked("corruption", time, guid))
    end

    local function countCorruptionTargets(spell, time)
        if checkedAt == time then
            return
        end
        checkedAt, count = time, 0
        for guid in pairs(seenGUIDs) do
            seenGUIDs[guid] = nil
        end
        local selectedGUID = plain(Facade.UnitGUID("target"))
        selectedCount = canCorrupt("target", spell, selectedGUID, time) and 1 or 0
        local mayIncludeTarget = false
        for i = 1, #plates do
            local unit = plates[i]
            if hostileNPC(unit) and targetEngaged(unit, victims[i]) then
                local guid = plain(Facade.UnitGUID(unit))
                if (not guid or not seenGUIDs[guid]) and canCorrupt(unit, spell, guid, time) then
                    count = count + 1
                    local isTarget
                    if guid and selectedGUID then
                        isTarget = guid == selectedGUID
                    else
                        -- Under Map, each nameplate is one enemy. An unknown comparison cannot add the target twice.
                        isTarget = plain(Facade.UnitIsUnit("target", unit))
                    end
                    mayIncludeTarget = mayIncludeTarget or isTarget ~= false
                    if guid then
                        seenGUIDs[guid] = true
                    end
                end
            end
        end
        if not mayIncludeTarget then
            count = count + selectedCount
        end
    end

    spec:RegisterStateExpr("warlock_dungeon_corruption_targets", function()
        if not state.warlock_dungeon_trash or (moving and action.corruption.cast > 0) then
            return 0
        end
        local rank = knownRank(CORRUPTION)
        if rank == 0 then
            return 0
        end
        countCorruptionTargets(CORRUPTION[rank], now)
        -- A remembered control may belong to a different pull or overlap another. Subtracting each keeps
        -- the count conservative. The selected NPC was checked directly and is never subtracted.
        local dots = state.active_dot
        return max(selectedCount, count - dots.fear - dots.howl_of_terror - dots.banish)
    end)
end

-- A hardcast Bolt is optional even if the player is tabbing manually with nameplates hidden.
-- Other damage spells keep a Corruption in reserve when another engaged mob still needs it.
spec:RegisterStateExpr("warlock_dungeon_dot_budget", function()
    if not state.warlock_dungeon_trash or not action.corruption.known or action.corruption.disabled then
        return true
    end
    if state.this_action ~= "shadow_bolt" or buff.shadow_trance.up then
        local targets = state.warlock_dungeon_corruption_targets
        if targets <= 1 or state.active_dot.corruption >= targets then
            return true
        end
    end
    return mana.lo >= action[state.this_action].cost + action.corruption.cost
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

local function healthReservePercent()
    return state.combat > 0 and 55 or 40
end

local function canSpendHealth(cost, allowUnknown)
    local remaining = readableHealthAfter(cost)
    if remaining == nil then
        return allowUnknown
    end
    return remaining >= healthReservePercent() / 100
end

-- WoW can display this minimum with a curve even when current health is hidden.
local function lifeTapPlayerFloor()
    if state.warlock_forecast.funneled or plain(Facade.C_Spell.IsSpellUsable(LIFE_TAP[1])) ~= true then
        return nil
    end
    local maximum = Facade.PlayerHealthMaximum()
    local _, spirit = Facade.ObservedStat("UnitStat", 5)
    if not maximum or not spirit or spirit < 0 then
        return nil
    end
    local cost = lifeTapCost(state.level, spirit)
    return healthReservePercent() + 100 * (state.warlock_forecast.healthSpent + cost) / maximum
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
    local fraction = Facade.TargetHealthFraction()
    return fraction ~= nil and fraction > 0 and fraction <= 0.25
end)

spec:RegisterStateExpr("warlock_leveling_agony", function()
    return level >= 10
        and level < 60
        and state.warlock_outdoors
        and plain(Facade.UnitIsTrivial("target")) == false
        and mana.lo >= action.bane_of_agony.cost
end)

do
    local drainRanks = {}
    for _, id in ipairs(DRAIN_SOUL) do
        drainRanks[id] = true
    end
    local sentCast, channelCast, targetGUID, endMS, startingShards
    local function clearFinish()
        channelCast, targetGUID, endMS, startingShards = nil, nil, nil, nil
    end
    local function resetTarget()
        sentCast = nil
        clearFinish()
    end

    spec:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", nil, function(_, _, _, guid, spellID)
        sentCast = drainRanks[spellID] and guid or nil
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", nil, function(_, _, guid, spellID)
        local sentTarget = guid and guid == sentCast and plain(state.cast_target)
        resetTarget()
        if drainRanks[spellID] and sentTarget and sentTarget == plain(Facade.UnitGUID("target")) then
            targetGUID, channelCast = sentTarget, guid
            startingShards = GetItemCount(SOUL_SHARD)
            endMS = select(5, Facade.UnitChannelInfo("player"))
        end
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player", nil, function(_, _, guid)
        if guid and guid == channelCast then
            endMS = select(5, Facade.UnitChannelInfo("player"))
        end
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", nil, function(_, _, guid)
        if guid and guid == channelCast and (type(endMS) ~= "number" or Facade.GetTime() * 1000 < endMS) then
            clearFinish()
        end
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", nil, function(_, _, guid)
        if guid and guid == channelCast then
            clearFinish()
        end
    end)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", nil, function(_, _, _, spellID)
        if not drainRanks[spellID] then
            clearFinish()
        end
    end)
    spec:RegisterEvent("BAG_UPDATE_DELAYED", function()
        if targetGUID and GetItemCount(SOUL_SHARD) ~= startingShards then
            clearFinish()
        end
    end)
    spec:RegisterEvent("PLAYER_TARGET_CHANGED", resetTarget)
    spec:RegisterEvent("PLAYER_STARTED_MOVING", clearFinish)
    spec:RegisterEvent("START_AUTOREPEAT_SPELL", clearFinish)
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", resetTarget)
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", resetTarget)

    -- Continue a finishing drain on its original target until a shard arrives or the player changes course.
    spec:RegisterStateExpr("warlock_continue_drain_soul", function()
        return targetGUID ~= nil
            and type(endMS) == "number"
            and targetGUID == plain(Facade.UnitGUID("target"))
            and GetItemCount(SOUL_SHARD) == startingShards
    end)
end

-- Older custom packs use this condition for a shard finish in the normal recommendation queue.
spec:RegisterStateExpr("warlock_shard_window", function()
    return state.warlock_shard_target and (state.warlock_target_low or state.warlock_continue_drain_soul)
end)

spec:RegisterStateExpr("warlock_wanding", function()
    return ranged.wand
        and not state.moving
        and warlock_forecast.shooting == true
        and plain(Facade.C_Spell.IsSpellInRange(SHOOT, "target")) == true
end)

-- Leave time for a scheduled debuff refresh when the filler would overlap it. Shoot uses one wand interval.
-- The direct fallback checks the same window so stopping the wand cannot replace the refresh with a Bolt.
spec:RegisterStateExpr("warlock_filler_fits", function()
    if not state.selection or not ranged.wand or state.delay + state.execute_time <= state.selection_time then
        return true
    end
    local spell = state.selected_action
    local aura = spell == "searing_pain" and "demonic_brand" or spell
    return not spec.auras[aura]
        or not debuff[aura].up
        or not action.shoot.known
        or action.shoot.disabled
        or mana.lo < action[spell].cost
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

-- Shadow Bolt and Searing Pain can proc Decimation below 35%. When target health is hidden,
-- the Soul Fire glow is the signal for the proc.
local function targetInDecimationRange()
    local fraction = Facade.TargetHealthFraction()
    return fraction ~= nil and fraction > 0 and fraction < 0.35
end

-- Shadow Bolt's: Shadow Trance spent by an instant cast (wowsims talents_affliction.go), and Revelation's charge by
-- any cast (wowsims enchants.go: the next cast the crit modifier reaches).
-- The belief's `instant` and the simulation's `hardcast` distinguish the next instant Bolt from a hardcast
-- already in progress when Shadow Trance appeared.
-- The simulated cast also applies Shadow Vulnerability for Revelation's guaranteed crit.
-- Live crits apply the vulnerability through `onCrit`.
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
            if talent.decimation.rank > 0 and targetInDecimationRange() then
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
            if talent.decimation.rank > 0 and targetInDecimationRange() then
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

local function drainInterruptAction()
    if combat > 0 and state.toggle.defensives and state.warlock_outdoors and action.health_funnel.known then
        return "health_funnel"
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
        interruptAction = drainInterruptAction,
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
        interruptAction = drainInterruptAction,
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
        displayPlayerFloor = lifeTapPlayerFloor,
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

    -- A rescue can be stopped after a tick. Between pulls, budget for the whole channel.
    local function funnelPlayerFloor()
        if state.combat > 0 then
            return 0
        end
        local maximum = Facade.PlayerHealthMaximum()
        local cost = HEALTH_FUNNEL_COST[knownRank(HEALTH_FUNNEL)]
        if not maximum or not cost then
            return 101
        end
        local spent = state.warlock_forecast.healthSpent
        return state.max(80 + 100 * spent / maximum, 60 + 100 * (spent + cost) / maximum)
    end

    spec:RegisterStateExpr("warlock_funnel_available", function()
        if state.moving or warlock_forecast.funneled or Facade.PetAlive() ~= true then
            return false
        end
        if buff.casting.up and state.channel_interrupt ~= "health_funnel" then
            return false
        end
        local rank = knownRank(HEALTH_FUNNEL)
        if rank == 0 or plain(Facade.C_Spell.IsSpellInRange(HEALTH_FUNNEL[rank], "pet")) ~= true then
            return false
        end
        if combat <= 0 then
            return canPrepare(state)
        end
        if not state.warlock_outdoors or not state.warlock_alive then
            return false
        end
        if state.warlock_pve_target then
            return targetEngaged("target", "targettarget")
        end
        -- With our pet or nothing selected, its opponent can still confirm an outdoor PvE fight.
        return (plain(Facade.UnitExists("target")) == false or plain(Facade.UnitIsUnit("target", "pet")) == true)
            and plain(Facade.UnitAffectingCombat("pet")) == true
            and hostileNPC("pettarget")
    end)

    -- Saved custom packs may still use the original, readable-health condition.
    spec:RegisterStateExpr("warlock_funnel_safe", function()
        if not state.warlock_funnel_available then
            return false
        end
        local petHealth = Facade.PetHealthFraction()
        if not petHealth or petHealth <= 0 or petHealth > (combat > 0 and 0.30 or 0.55) then
            return false
        end
        local playerFloor = funnelPlayerFloor()
        if playerFloor == 0 then
            return true
        end
        local playerHealth = Facade.PlayerHealthFraction()
        return playerHealth ~= nil and playerHealth >= playerFloor / 100
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
        -- The recovery guard reserves a full Funnel between pulls. In combat the client decides if it can start.
        health_funnel = {
            id = 755,
            toggle = "defensives",
            displayPlayerFloor = funnelPlayerFloor,
            copy = rest(HEALTH_FUNNEL),
            cast = 10,
            channeled = true,
            tick_time = 1,
            cooldown = 0,
            gcd = "spell",

            startsCombat = false,
            known = knows(HEALTH_FUNNEL),
            usable = function(sim, ability)
                if Facade.PetAlive() ~= true then
                    return false, "requires a living pet"
                end
                if plain(Facade.C_Spell.IsSpellUsable(HEALTH_FUNNEL[1])) ~= true then
                    return false, "Health Funnel is unavailable"
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
    20261121017,
    [[Hekili:S3ZAZnoUr(BXFrRu4ezjpJMz2TSMQ2C3xYD7Tjv8w1(nrdrczXyksv8H94Ru5F7Pb4lqqaqWhswYdtvjXJir)cnA0nq3nxnF1FS6oBueE1VFZSB(8853mF28VS6UOx2JxD3EK1JOhG)WdTd(F)1nBCDSIC89E9(Xp7)COZUWPw(7MqEZxC9r2eOTo2Xn6V7TATqahUhBT6U)8x)x)2)4)6)9xq5qC1DBDSTXjddhAPaB)YR3hTf)69P)21B8dWpHdE9EB8guSB0R3)R)ZF717HFg(lwGe7Cnb9Hx)mkW136XRT3hEnHCTdVgOeZNda(Dk9hM(Vd99M8batbiVqxGpSH)2NGzNWxVhzB779tWF8i(LWPVE))nkc9lcOOX)F)9)aaY2OO9H)Y1x)Gt0241eM4AUxDcatGWrRNTz2m8N2y91pcG93Gh5649aac)4iBFchTp21ne(bKhqr2XEpG99acjoeKiUyuGhHsb2m5T2JbOAHcWzJylg5gT9VIaramGDip0R3hGT8bA4faJ)JaBhpuWlP4bKIONiyfERWDix3xV3lE3AcR5VbyB))GGKN364IjetaAn5pIqbpGJGb)ab7HXHrihkzzJxhVztkLqPrapbo(boroyIC8FHCiVgAhO1rMbDDbXu609Ehpkq(t))8oqYLpscz)pDrVqikqYUMihbPriJ4yFaommMWWumB57ff4d4MOvqHDi2fBrNJ93V33d7fnf0Pd83am2Q7qufOWP7jckccwMifn3edKK7hSDc3deGjiSnxJbsE5hN9bNnltE5VnBuQ(w67BIEc54sfv)pvaTXYRF2X11mY3eO4NCEctGugaqUWpKdUWOyQirou83yc8NjOKfIEe7jhuzVHzMSrimH1LO9ytuqKtyKCGTd0M2bYWmGn6QSNSffyN9RUy7re1HPLG6uB)N9eJ9WTOOiCGPvCqOaPIAKqMJa9nIupbatJ3N8KsGvb6tMZdJa1Jpa6xGSDJ5dw2lNNp)RCUxnrkhLWYFZ9(KNPeRFQ)WAaAVJTza(bShoavlM)8m25clKNzQ9KeXBvOPqgdJ2Zznq0))yoGM9Za1hSpeNaBMFNc0re7zt36C7SPFEXFH(p2H(E9OIJHw0gClgl2yeyNWY3XvV5lylmSximNzMyeDuK)dp4cyi73dlw9t0NnDaXnc2eOHOpHh7p0pAmSOhuvpK949pT3mZS7ePRNbbNjmcBf6Uz)lyGetkPdkzlI8fWzWrL1d)yxty10JvTCmod1hy1IHbVh2KCsksYgUQj7ayFo4L2iwJQhL25qGIXmZePiD0vjZfVXQeQSIkFNZfmuXYMUZjr0dK5EEdsPtL5ql79mdrBWnXOry8UD(EMBWUBJ9Gnn4ruYZhXUiWXdC)XZkvxfgjSTnAh4KLkD1e08KVJ9Zi3hRfpPohgok031VarelUp8s94XzxfjwkcOGADCGhr9kzDw9Glm2YkEDCOeygHCj(xzJH)HJLjeJr0uShzs1wi(I3RM49ofiZkaw2Gnz9bOgDmpm2oKDaJUkbWtRcRP4VJTIJuSMLWPOGD(v0eYqBItofVNY9KOZsp64jdyzukl8E0JSbldAiaizx3XsF)dcjl17hS23TKVLe3vWFpkg5MlBXEpaw)Tlz(NeOMf1RU6SzMeZKPTpyZj2MeJIcR5e7(Asn5MotT)o6Q1(HHJUkXU5uNqt6)oN8sDgdmKC7nmUOLyGeSfwmnKtjfkkCGj12mlv64fJnlgATmzMT4eqLAo(MfxmmVKfU(bbX7PoXQhJWRMa6vHBR8RfGnf7HFB(OKWBNw8SKLh5R7l(9cozCQ86q1xYcfcBboPrBVYWUwVy5MTPDi41(rN9j0d4MaSUIHlUT(HEoi3w767BdEze8cxSoICjkaz5GCnj4X8zhpGyhno7zS(9EySgc8XxvOm7hezso3Lc)qDXONaxqZFN0fNWcKjPoMwq5km5JbQ5r0LgRLq1jkd5WM(BMH4iPBvtIJp7KpWU0tIiutTFbe8iavenUWPOWqNh8W2jNuWYFkd2)uUcSimxM8RU5tJutZXa8Bp6ctfEW)9yWBSWVk)X(0Jd)9mg94XI3YGDv(k7j9kpr3)ca(gNaSMStLLLiFC(gRYjlvUvr8ZTTyVyLzHXaMnW)2YBoK6NDQVyipWIKlAhEkixEC5IMzlUXBzlA2V6Ekb4DWmr4TlfVJXjD7g0U9qmOVKEuMvml3sEo3p81ipQ(m6bFVxs9epvGu(ruVXRooiyYDIhg9jsg1w0t(wIhwYJsgxf1lsKhzcekzPMre(iiKk7xs32OKWvXMILGW7EXEpznl0z)w)0d5Q9ISu6Kby9Qjxhi2FYD21DkmdsvSEK)Gs2oY)1QHQiGL4nQucMn1Ksd5zr6XUKRB825ZoiWuiv)sO3AvevLCExGePxzBfb8Sd9DZY)2nAkCePqCf)ezsKr5wZIcGWTjuiece2dVZbd4RWgh1BxXHiT8yf5yTsm9KgQegvvd6zEOrkdRXGf)Ghj3y(fwOofu(76O4sNMzoPVedl93g0ISRXD1uUPzvrcCfBt7hQ90fDTj5xPGabAf9nnUJO8JfuGWU4cy(4S8lGPK7HK7QzJFqYXzo6kG4FIO(pD(0mAVaWGUDKp5MMbYzJJRloihuLU3hvhikV7nDtAK)a6LwMFnDAiKyppubcUkA0jYhQi01)Bz(QuWtGbwWBLXYfvhOJDVfb(3UyXHRgNcJKCJkXlGMzuox7Q81noF2SgUKoHcH)VOWcHEHUZIz1D5DB9919MfeHZXJfzCrOeIxmkW6yHT3UPCjZKA(gVm0vouEMeHojhnOdyYKd8wssCUraiK4ub9n6GS9QXSKg11GbPDPLAAe)qYaBJJtn)Q3gMepstISuv7Mk7KvojNxvCKVjkkISiVfNwvDhuVV3dX4sN1lRxQsy)8aoaHeXV549vph(eaRWL68xf)9TO4qYl0uYG9DF0HgwdpDuaCUlmVcLwYLpH8rZU8CDyaH3IEtolzDqs1LZmRDlok5znjMvDWRSOsfqpAemQQGzB05L1asVYHKjG2By8tna7vdYrV4L0lcMExxM)ssQ1YwfZLcXIgGrijxK77zJQ3tDCJoKW4g9wAIB8gKC4gVfPeUXPkrWnoHP)TXPoPVno2P6TXrmbVnElsRBviTVZCxntMBJtqkCBCSsCBJZ301(uovx1Uw)LA2ghNeY24yMg2gh1KV2Ops5AJtqIwBC8tVAJ3GKQ2OhsLAJZQeOMZ1Zn(wX6NRNcd8RwByYt7iJ3VjnTX7ZuL2OuO1jAp6Ej58kenitHFBUQydLzlWjJ5juZfuAsB8Em5OnEpCz65WwukrBilrOBMEEJsS2ttcrBilnOpICwWjlDOneLe0hro74Nm0gVjPaTXLrIp3LnGvK2IwNnP9SXqYo)wLSZg83aq3vVUme6DYwf7f20Dbw)NOZgmP6BVrFN1P5C75yrAWxij5S6GveLAZnt0isz4k(jXlOuCUlBKQsuuvfON5anueE)LwZVlI)kDkvEYm3XnGfz9AivMfTa5h8ey2yiTL7L0w24TnzLn6CY7nKVLLtrzJHet(yjJBuoT2Oet2yiDKpJM6Ar6i3D7yLo9OEk1JnEZs4yJl70mw(6rDiBH3XC9NsRoGU6ssM1FIsPyJlSej24KN(WvIyPD48eL0WDtZuNufwKPmTtq4AICpNSYYr4Q(r74zH2dH)gr7)4mWLamNi8UqnaBPWestuNG4k5UQqkQYVyYcbwiVd9VHWBiBAkoDvRJYSqWCtY)e0vdJ(aPLZVmeehUyZDXUrozAojMRC9FWXQwOYgGk5LhVX5HTrMPNY53eggBCscRMDqwPh013MpPQ0qBgiL0j7ZMt4LH)Y5Tb8LemkG(3Qb6vZHi6HumwO17dJtV0lND7daxqSnzDsOu6Fr6T9Uj5)lSB54RYSjL8(pf7ssp41oUKU4oayvpo7KPhlXXedb)oqYa(nJC2HNmzsntGsYJQFOKbI1YS89DjwEPomnMxV9WyoR4fNte4WTIdrAC5vJ)1ftUw1cYj3ox9HsDLOrhVhyAvKOSbPwqXKGUezYvce8PmzlNQ(wjzJaQPWj(YhpJmkr25LnMnqNpoBuzlKFEMkuxSTqgevg6DTl707DZ8vS4yvkVrEv6uKhICz8E(V3OR3xMqvFsRHz(SOt6uN5Lrkurtp3TBfPP6hgXuKw1SD8sXzCKImTtJujccpFSgVwLyzyZ4iy9C(crXzTtITG(i)FeIR8CPPg8Or24qnOP9uIHSKLQntkLLcKjgE(SKuVgETjZDAssxOtm555vBMukOSt5eYPCXKgSUUtkI9xEznzOKsVyK51HsxvgRWHKRYC3Q8dts6hvEYuAN7Bv6k1ebKh71cYZujpJWvKbv493TlQv4w5ifyJVOvcwzexROn9Yi8CV2zoVgaHcJMK9eIYILm9mMzciB5hNCibvt9JJcDSXley9O7AQ6nRwMrMFt9uIYPvPZqTcpIZRdTMs(zTqGKu(QiunMJqt2SEPJzlBAVMy9ywdwKN6PtvjYVIFUKffMtZ)q5FZAlIunEaRYQnLha3szzDrnbQj3OJYbkAfCM9PV28mmO2y5Khb4i(1FqyRfKoFkGDqKQvnMmLU2kx6XQIuk2ZY6xtYNsRmacFuzYqq6IwoPqtgQGzk9i)RKd0df7vv(PPzOQsmQeWJLa4SLw)vPiojE5BxowihLnEJ5txqooKjvvUzOXrJLtICB3kJGtFUHsQHshLnRKFOl5PCuXEjTwOw(8w6ijFRmkue3m(M)I0x)8HJurLc5QpErWvkOYS)JGtOqZBJOyZfd1vk2PFlM5lg2Jzypg5lZg2JjpstM6K88DFgbuzD71iAiNpCwDuAD75CMZD1qP98EpUSxQrB3Rr12j3CtR3yyC2zSp)RZstd00BC5MFMp67pptOir1DUS6UNWbHaDX9XwNCfEH0VW7jFz0H)83PFX3tVGYv)n4r895Lv)(hNL9nVE1DLAkmRUZkWjch4GG)QUou2QiGA4qwgu56yzSWndCc7Czey(rvW0VCNmREaZ3rZiy4tsWqPErw9GUZD6mcTSqcTeY2IYKtlQrzt6aAeI5Zs0Dy0BuOGOMIwDhJhJe1uovqApDHqeFrnr8PJhr4K3l2i0XxvthFEMOzfD7uAYjKQdGqm)Se1eMMyMeYrREFM4lMKG45ZQrmSO3jgkALzgJrlidTf3vVsndnQbeXxEmLE4T0PqmCSPN8QesC)BJsUYmIMEsLWaT1yzu2)s)g7gf5YSVM3Q2KBpROJVPDlFJIsEZOQMEYl7KJ00toeu1n4OuDn2BpLkvu6rMPxgFhwSqBFhu0d5OyJ3aBgyZ87rM91w0C5O4tMnu(UnNm824Uoh1djE7NCyTOn0PjARVD0rrlV9to06StQ4TM(uhf6Y87JRX1vdkAE3LJICP22k1r7oo4wMPTQTNoD1EBxlVJsmY8DKPDYvhvK4Mix7NJcCEBtLboP32vhSZ4JU3K8K0L8O0jVnlb0K8AtHDpSo0H8QS)kj5QwDh9Ugjo3rOtzw7kAQBnK2F7BZCJyPsUoRhLN5T4kQV6r1JFpinOXUYBTVr8aVcwdA6CvpSz6AkbhoTGExqJBEbm29YhsU6(nubHS9FyhqPeYGgeuoiozcocDD67wFnxItKP876kleYIdJtPVIA34fAFNxOjTEbUE5hLJ53QxghNCTxxsCBDn6pk7Z7TrJwuiQdW01CdSe5QDRCGz1ViOYz5G3RMJht3GevS3yCwOYX48ECD8yCnsSYEJHZGihZY72w24yBLGnue0YwkiLCK5Dwrfj0vIHPgfKvmc1vncQ2BG3vRgrSIuEQU)w29K0TonyZ36RwNn(eVxxY2MO09C1dYiLxfxB79oTT57CmBtHTPpfsNz4Dd8hhrEhSDwI85u159bSZcub5psxT9ZaloQN3FU(I6pn93Wg2R)keizdGtA0j37eT2iV3hEQA(H9Ter2jAPoQXkDlrAeKTmwsrAzxXRDC204eLVBkvE2jxkvjiQQ8030FTQqs9gG31sPHjN38gUKcCKRLls5yEVxFFgMCQQsLcCLkc6K)VISLYFhRDUvm((35KfYURlv3Ox36TwA0SczMFEB6JJurJSZdv8Tr3pcN8hCb0Gh57hBnRfpsfX1KIgZNntpnsnmuOF3FKszYZgdFFHjAwdjHM037QiOfy89W5vRVRb9(oQ4w2L0sFXEqC3Tgp477ja9A(GnPXrsNsvKMK25336We7zZelF7WPMPxzjBqpzGKIdDdlGPHu2mmtXISdsU4MpsAcJIaToD1USOT0RhvsjjP5oA2ik6RKTLQyF3EQ5vQU7vsySpln1QuBuqhgsyIHqrQ0eRs5nfOdoRAUGX0at)UKsgYYaRsNusRidzXZlG80jmEvNdaLtK6Ce7Pi2jwrNwKjLuK54axmpDIyQg(NEHsQzODu(OL7wQdxOORAsrDJTKxx72KcvDTDl(iDYzfnR)ikk19mvYBvNkXifK8gILbs2EWPA(OYVuQ)Dsq6x09UXQ0GpRLF(s9xUtX7xyGIRfeMuftMKgriznVYMQefRYS8XE(iS0sp3tqP0G87XOmee11pBMOiviK3otOOx(fhWZaTg9IBOouSlpbnK0lnpEntZtF30uIXu2Jb7lYp19F4fq0CH9lYZz3X8RFo062pAV3)rv1as7NoqQMRnZRkwQWuAIflSIrYzWkroE48PxMs5lzHTi6O763MCkb9FvwWfspePs7q8v1Hji1fSYarAzwimwd9BkPIIWqV(LADPOeLSL5rVOzo9jAnlZNVkZjEvh5RoAfJuT0PUES6ksAMD3EsPHs43vdfQ9qHApuO2TLiCgku7Hc1U6Uwu6zOqThkuBnNEYHWqHA)ScFhgku7Hc1Uvfl9qHApuO22(YkuBUD6AXv4l8W0Q1yVWcaAO8S)B)iwE25wfuERPAKSbTOYJpX5nDKGIY(uXQeI9sOiRfRpWxVbrdLITco(YohZZbEDLIDUMI4kAUrRSevYjVrvQDKGcWUcRwUgMpES6XV(SJeu21vy3Iky(4XQhVkYoAOyRZMgA0nzOsEk9q(ARBekkTrR3(cWoAOeRRnVRoFkX6CxpQlP1EVot0kBKvkS6CJsQtdXgkeLLrITJMLDalfvxBFrWNNfyDKGIOUJYark(N9LvDupx60nsIjsR5k(z7l1cMUZ7SRs4uvvPV5jvkmDlNAp3dQBOmPfLuvvkt6(WzbrMmhQE6k140qXrNPlmuC0(dfh9qXrlZq9rReoPI7HIJ(TBcOz1q7qXr)oDILp)6hko6HIJEO4O1tikWrRWHIJUdSYqXr3FlmopkoAnzi2snkQ(sVvqfRu18D57axR27Vgx0n4sXynEnL3ho5BIBEbUj(oKtChOpUnAXil)MCRbrACxW0IoKm5l1sNK7QVBtjLfbKPLkBtXkZRHpB0mNM00zY0ImZ2IYPGUnLuqvN0PJt6cjny(ANsIKxr9cSS14B3w9hg7kvoCYdjFASlxPQZVr4QAg8idscaKSDOl1h(Rhtm(Mubn)8eXoxvQFSwpkk)XlFKWg2qj)uY6xd1u(7mokuKrBztjjIXIFV0hQCMG7kU1V0aY3Ii1ibOmnzIehYyyFYwV5LRDd00QEhe1vS7sFynLjVOdip7wE)AloC96li(g9j2x53y)28r2Vp)k73HpZ(D47SFl)q73PV0(Q)YIFc)w7F28X2x(xB)SBJtRV0(1jy73Vz7YOrHme7NVE(3)CIPurNIzSpEHWykOZw)11xKdgnl91Fl2jA(IHTIg2ksR1GdBfLTv0)zO0U3b1vhHf3jbRscB6zWKNJqUvcw10GEpibCRuuvuKYHie5xHe(QYXiJi)6o0a2bcKHwya0f)a05(0ilrVt)MzawdIWqeKpFQkbNNqFKqFmjHrZifI4yqd)1pJVybe1gGwebOkdWBCaQfKInhgsPgjqEhCpinO2saBmLqdsd5f8HZH2btRNCgAhyAb)liySn4Je1qbHPsqQch0BlLTgRjOnGdiRvV8lTKIZmLunf6W0vc4jzodq7iEpsn7mZjZ6sqd3Yh0XEyrquqCa(d]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261121013,
    [[Hekili:T3ZAVnoos(BjFXJ9PEDCsA3tFdIBG9boSZUZn7IndW8nRqlthRnYsg6rsNdb53(vKsIIIIKI6HTt8Qpmt7Oh1lwSyXIvvA5vl)TL3TgfJx(Rxp76VC1vxF1SRUz5DXVShV8U9iNhrpa)WhTd())f8Ua)aVGhE5T7h)CWZrU7IM6eSBc5jFXlaTMaTvjUEX)S)YvsbC0ESZY7(9)4)6x(h)5)(pTMbXL3T1D9AC6RHJC0GTF6T7J3IF7(SRD5MGq8t4W3UFnEdkXl(T7)J)ZF5T7Hl)29LasI7Le0hD5ZOqVaNhVC9(OljK76OljuI9g3qS9QqK)6P0lp9Fhf4p5ta(GRf5bCZA43be87g929O1Rd8)b4hpIFjAkGmum6NKqxJ)F)5FdaY2449r)0Lx(GB82Kvew5sHhDcatG8rRMTz2m8N3481BaW(lWT8C9Faarqs86acFTpXZlcUaqQaFN4)aoWhiKKiqU4HrH(ekfy20NApgGQdkeN)gBXiV4T)beiiGxyhYh929HyNaGgEbW4)iCTRpk8Lm8aYs0teScpv0oKN3B37NSBfH1c2aSDWVrqYZBD9WeIjeTI8Jyu4d4y4LFGG9OKOyKlLSwJxLSztgLqPrapHUbHUXUyIC8FHCjpgAhO7rgh98aXu2G(ExFkq(9GF)oqYXEtcz)p9qVqikqYUIihbPreN4yFiokkHWWum7e4hhga4oWpd2rypSdDmoy)(aFSF8uqZomydWylVd5e7cc5P7jckccwKkfT3KaKK3Nw7gThiaBqyBVcdK8IBM9j3nlsF4VnBuMwx2ZBJEc56rfv)TkG2AXLp765zhhydu8tUpHjqkhaip4cmWffNqfjQHsWgBG)SbLSi0JyF1Gk)jSZLnsHjm7eThBJcJDJIvdSDG20oqgMdSrxKFNTOW15x1dVEerDyAjOoDDWZ(YXE0wuCmo02jjmsIurpsiJrG(grQNcGPj7tVtjWQb9PJ5rXG6XNa9lq2UX(bN1lUIn(RDSxprQgLW0F79bK7PfRFU)WAiAV7A7q8dyFCiQwm)Lz8JfoiF7m7jPI3QqtJmgEBF3var))HfaA(LbQpCFeof2CxNc0re7zt36E7SPFz()f9p2H(E9OsGHM3gClhlRXiWoHtGRNzJxWczy)iymZo1i6O4GhEWdWq(1JkM9t0NTDbXncweOHOpLh7p0pAmmPhuvFn)27FAVDUz3jkNpdcoB4nwRr3n)VGxKysj7LsxIGnboho6SEeK4zdZMESQLJX5O(vETy4L3dlsojdj5VUUb7qyDo4H2ixJQhL2miqXyUzImKo6I0XItSkHoROQx5CohvSOPRCse9azUx0Gu2qjdA5pNDeAdUjgnIs2bEvAVb7TnXhw0qerP3Fe)KaxFW9hFNmDv4nHLTr7aNS0PRMIMNcCx)mY7XAXtMZHrJIahElqeXI7dVupEC3vrILHakOwLe6tuVsNNvp4IsCCswLePaMXipI)v0na46yd70iEk2NmOUwk(s2RN49pgiZjeM2GT59bOgDmFmEDe)lm6IuapTkSMI)o2jjwZCwcNIc3furtihTPo5u8CAxtIok9ORVkGLtP8W7rFYcSCOHaG0vDhR85FvkzPF9GvbEL8TK4Uc(7XjipMSf7)ay9FDjZ)KnQ5q9QRjMJsnGsmUBikz2hZmYo6IvbrrJUi144u3iB6FZOHmpUaRf3EnNFyPwbbdEfYAgLuOniaMmdW8uPRFc2U4vRLjZn4McQmBUxp)ddZlNbx5feSgwJi8fbpvLTGwiYXf5b67rX2p76d6oJgZBWo3RLxhBGez8ffuzqySnzxZfEraBa9jWbc2ZKj1boFsMBffuUMjSyGAEe9rJ1sP6ulemytVMDeowPHwYUWY33kSRCY(iJmu9ucbpcqfrzkAkkkY9by3YP7ZBXpKd7FyuAujMkfZLjFtSOWadCTh9a5Tp8FhcgGh(vzc(72bM4zm6XdfdKd7QeF(DAoHtTJaqGeppdP5Q77iaR3f6imkKUTCKWsOQrcBwimhbwlm3v6YENKg)XC3tYekLVziEhG0OBVE6CMXtEYHZ854mE4vzpgXeXIztAKSLUfOgiyZiFh3DPB7hwAMrY5Gsh9YEMwrSuVciE3zi1wrnOWIwHruUv0(2IRFnB8lZdey8XEJhAhEkqxpUyEZiyNGWWK9KRBiblBUw(ejgSykmlYD(S4weXAHtPfxx9qIWl30Xe0U9WoVEjlaEvwoRL8mZ7ZviFQ1d0db(VK5)zMaP8TO(Gw99GTqTt(RrVJI3Al6Pah5Vw6TsFVkQxe)TZfiuYspJi9wWgjw)s2YTLeUACMOeeo7f7nr90f2Xi5KE6GqjJsYHuLzFSBuAUh7QQN5v6fB68UgYyYgS9iNe1Txn7vj2lOdcsDfSI8GUE(XIT5SO68c4WAgHfbwB2H(UD5RDTHchzJ6S52XHWUXiKYtysWx25IbaxmJN6Z8OS7VoiMtiU4kj2UljTAPb6AfnMX2s4AnJ39mp0Or9vyW(x4Jaa)OTHPck)SEVGzdZCr7j1cs)TCLeL184virN98BHmzHbNfIyD2VYVNbX8)cns0IaQFZmwa1l54dj27BcctJC1OlaI)jIQ80RMMt7fag0tJdiNCiqoBC98WHmqvko(6I9f9mz6nPb7g0dHIDSlgiK4d9LebhJVYY7Jm5dve6f8TCVik4jWyzuC70nkF4pxnBwdNCLoua)tCuHiRyKF(S6okLTbbMgNxz4CSKHUXxmo36c)MDtdDT2nBNdSs7pFYRuwyVdz0525ZFvIbUcZNDtNASkZIJ6zEID5Nj7xLCo9uK9Q0WnWfn9YqzIQy43(qJWp4EXyEQK6LWWWDR4P(A4EI87ONK6)qq14JiAq76JH2vfvfosVDAkDA5ffbWkjoWgfhJCESnHVQUt8iW)HeCPqTZ7OUc2NTNlqir26aiLRCGgPawxExL)O4VVfLerEGMsg8p7JU0D2jshfax4CJRqPLChwkF0SZq2egq6Hj3KGlBcsQoPNBgErSLN1KTTBcEvTXCj0Jb7hx3(5viXC3VnOQF4nG05GGsAVHBHSbyV6ganBVKMT7UM5lLjKD(opKAWTfN7KAthspvOMqIvpMOEFQTO0Owd9vw9qkwQhmYKnf5dFTbR9cX4NYNDlvatVNv6wDix0T6Tmq36eK35wNISn36yLJ5whXml36yNp5wh6Si36aM74wNImgxhs77Kc2W8e36iKD4whQCc369BMGFmhQRAxR)Y6BRdtUEBDiZWBRdAEDB1hzZT1rihUTo8zUT1jiFTT6HS026DvUzl4Y9MaNKitJ0r7YmBRZ38X268mlSTohZ9ARZHtzNbBzzCTLQ8SoDsExYfMJr(wBPklRpGKFy)MT1wYYX6di53t5AT1HldRTec4vZegS5CDmoxh58R2IpgrTyf2Jy2vB9XiNQTkfL8MPe9HiJQTgYJ6tvEuBjEwcDx96JHqVEvswuR7Ui5Dtou3E2s2a9hKmO2QX5nDZenFyZF6USWIeE(9t2tBDoMZ0Nf7HlBivDMs3XfKKOwEUNN0kcCC3s3kds8xo54jo7OTgYjAb9GtqMqB15euBiLfBjpXUChtzrLbUO9dPd5LAFXt91G8jlRNTgY15ZxDQEixN7(ciLcOupLxZwNSSz26JDomRE6UjKT0dBT(a3AcORoXLBwQS8v26dwwkBD0Zn5kBARD48iLrYA8UXeI9GMhYwh2SpUBtknjNJLzf34mngEzITA3y8Ui1wTRMMWwzzzcitdtQKNPYE1rvUInpe4H8o0)g24kz1F5PwADuMdcKHP)jmDkk(tK(p)Iiqq6HT3L4f7MRCNAr1l4bxNAH6wyKjxjHC1IWl(Tf3KVh18Sho1JcHhHIZPGNkrURX8NcLm0Xhod(qYSX9HTX2zXZ(BsJ9rsAkTQh(QoN0XJVqHZiYDsH7WoNu)PDwvSm5vr5sncgTJUzJRRdIlgvlJYfx1gWxsRrd0)wRGUtqGhXOuu6aGGX2IqDnASU4GnECjDJ)W8jxQt9yYTxPpUAxi7Tt2doF(QoAuXB9Q6zep7gV11F(K6g5RzgyjGvJYVSZlFSzQNYo08YtkzBzO0XJBv5QGBwpH9SJD3HNO7C3RrSWLmUeUq6CWsNBzL9s(Ts0Ve0XUIqK5uIkvXkDm)E6UzUGG7lZ0H7IfoYHOjoyiF8x(sYAE2C)ElInx5vMRsUY82vin2zxVrzVGkzR5KwdtNzzb72KHNcRlv2x9RzHE9wjpaj0RCvZwnRBVqEsOjEOJCRWzq2LbwcgBWJvzFz8jHgZMh)(6kLJxP2l7JSftkUyjLvn4XG06Iy1F0fQfj(b0F8dtmFCZsv(31MrUYIkYONOWO0qtncKMmaBijDop6Xs9W2mYvq(hZrTJ50sdy9EDKtURQluEgVA9PuLpGJeVrAeeaxHk7b1TZRLYS4YqgnAqJLvhRs3murAUKVriZCStNBwQPDnj6ImQNlosQOF(ix1qoOY83tMAG2TPMfUP8nIulvBjpjQ6GkH2XA1uH8K3PJdUC8pBJGluL4j63aOY7PFNJYgDZ3x)xBEYxKThr1eJ6DwkXP1kN1VRVdApYXnM(b1RQSZsF9KC0LGxn)dPiut6CnicnsekUL0Jn7lSw8IR0A1JNYlTL92oARJJU(62o0mEC(whV(lZYsrMS4j85BMunGcnnIclV7jqZhOlHV8OKO1fr)CNM(zcf(5Vs)8NMDudl)tWTeRj5L)6nZY)0pU8UsfW8Y7CcDJXHUi4x11nnwgduJaYYHQq31GhU5GtAx2GaZB0bZGYDDJ6bSy33GGHpRadL6Bg1d6o3voi0YCf0seF70qnTOhLnPBDqiMVOq3HtVrJcIEkA5DCMSjQPcQG06pMqe)OEI4ZhoIWL13qi0Xx1thFzMSrft7QhQjKQVaHy(VvOMW1Wnuqog1NoKhVncIVAwnIH59oXqrRkZyCAb5OTiwZA1mmi7wzwJkftuk9iAPtJy4qtpSwnI8EncLCvzeLRPHyW0O8)Y8Mqcf5QSVYARiQTNv0DsmU9KqrPOzuDdpSeQ9an8WGGUoxcLQRXE7XuPIspQm9Y57W85g77GM(DcfBIgyZbBUFpQSV2IgHcfFQSHk2zuuH3g3HuOEijA)uaRfTmfdrB9TofkAfTFkGw3DkfV10tvOqxLFFcnzLAqrZ7ekuKR02wPUVYHb3QmTvTvQyQ2B7ApluIrLVJCT(K6OIu3efAvkuGlABQmWj9HL6GDoF09g6IIo6cLofTzjHMQPwZftWqvwifxeLCWGlVJgZnIhCeIrLjTIgqsdjWtFlrzepvk0fyO8SOzvz9agQY65G0GUbvrt6QCLViIFAxZ24Y0R91PxtkupHUhdLJfxnrfhNgH4psCBDTwgk7lUCxJuALvyWD9adlrUQmtj9vzgSUMYzIRLE44SgCeLnJ74FvbUtC16dh3zW5M2mUk)1e4ivl5Z38AAiFQRj2qXPONanc6SP2Dm)OBt)RPf1Pe3I8CVKWGq3D5OfT3MM2FBe22DQIbVZk3OYzLIKlRHSwB6ko1LyzQ4ocdi65rJiwnDOJEVN404EyaNbb2Ruwj8ZM6esP2(spiJ0wT8TTC5BB9YFiBOoTPJ6qhzeDw6)Ce51PmxIgf0N7DFSetZIU3UDAyRNPGVZFbbwUtoFjtpH1kEow9IN(wIOm8kCwblLrtutDvAEpeWva4MjxLPk9oOp(OEjeQGt0VWgXYs4ynAj9n9xRUIYLafDmv5(WzPnYhPDMk0bGOCSONNNN7dptvPsc6tfbIET2vn922yGoxw3v1PIO7uy6wJnWGwNd3GWPPRcrenZvD0nYpbX(r4WUX762nev8uZr0F1SzMPnzW8vZ7erukt5XtrQj5EGeokDAeXwnI0EnYztZgPXDBe6aTYJcSuWB6849jQxZmObCa7HrTj4GevoLj3c)HcoOXDMQXvv9X4wCev7rD6E2lRmrXHPBlIR5i1mmtXI4wry7wJDQtPneizG2K2ms(UnnRFjrjjvb0M9gf94O2sv8pBp1iL03jLOmMYmxsVnhtyiPzabbPFrzIlP94bmbNvnQWzaHR3lrjdvjYuPqc1kYqv8mKqEMegdDXbHYjk9kTOjl1rwXK21eLuu53KWgf7eXuDJXMTjBd30lLpuUyCn()zcBCi6WtuIw5AafNtx3O4QhXifVQYOREWkIMEcff1QwSq5YE11SOOqv0EVQf6yDtkzyIvVnuqkAPvfi5BtuAH6OkxPulMIG0F00JYRspOQw(5hR)SOkE(ctRcneO0cnYM0wGiwR0we(uSQYsxEZYHNoi37a02QO0H6dyPlDSQQMljVq5WQ9JQt9ennZQdv3SYKYkxLXZsCL6JzOmwL1qRAM(vMMfRqNPOxDMOiW0Th9YRPEk2vN2hTU(s79(JLUgKvJlmssRIOLTildL2S67KkGv5)UHMnkrvkSiOoLru0PTEF2QTK60aFY98vLXUwADKORbDDe7qxukxLd)YcHC)26UOOxPx614szj9SVwt9xPYxRYarFOMe3bM5TAlz77YSUawDzRfLSv5FRSbqZjAdRYNVQYlxDNaHjkhJ004WQTZHTKK443TNuzOe(D5qDApuN2d1PDBjc3H60EOoTRUQfLEgQt7H602WHhgegQt7N147WqDAVBOoTBtTspuN2d1Pn7OAQuN2cR01I8Mq6rxQXS5q1z)NgQo7c(CO6SF)ZTTQ6Sz26Lx)ZnsNUrfbCpu82XsQj7k8t5kE(WXp9ujBhlPsSRWtf178HJF6yrAh)oP(RzRC29KCTR50WXQQSJLu11L2TAlK7sohNdtHyhFowR1SjWAtdRgoZTAgzDQQ)64HkSU2mW69tfwZCPRU0x7CDKqJwSkVJkQa3olMYiStyLwhlPAQ7iJktD4DF9vh3Z1qDJKyNhvoDNxytIu4Dq1uhpuV0NT7motzOsEjqfbQ88SlRvkrf)mUmQJhQs6HQKEOkPBmjmuXITMTyxURvSiDGEOkP)pynGHQKEqJZi2Qh14gQs6HQKo)zhQs6wIZQgv4mGmuL0TNvgQsAd9)Ze2yOkPBoMvSK0rQkPnsqQVQOZbHSqRl77FRmOgxFPelPkzQU(z5C7OsCTL1fqnibo6Rp2(h1pR3Vt(GTtuzQnNCeYHLUnUDY(u73FFR9Fhn2vB(hXLRoDBC7K8H2)ipL0aMVFg3kmOMzkTO61LyiTy0rFbQFy)kRR0Nk(UoG6odE)(Xwx26AL(UpupDW5vBt(yRl3FDoCtw9NvQ8sgnn)CTQPBeO8M10hdKPLy4xRDvFPONWnvvc90JFPSLPK1SSg(eivR77V97dXQ4CMMDKZdIvfI1MUJUJV8WKVZ70O2OGtK2ThAT(GooK8zFVLdDh2V77P29v0qAoQlPxES825TBD7QRUAM7JDyv(rg2uxuOCQ0tyTPsLwEODEiymFq1zIPrTElPQY(R4hD9CF7(X)pbH4NWHPpWY))d]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261121013,
    [[Hekili:T3txZnoUr(BrVOv64ezz7rZozRrtvj3vxD5UCBsfVvTVjAykijgtrQIFyp(kx(3(1a8lqqaqaskzlf(qY6rKO)gnA0OrZvxV63wD3AumE1VEZ8B(Y1xFZ1ZV(2v3f)Yb8Q7oGCEeTf(dF0E4)))ahfhM4e7g4)29tEo45i39rZCc2pL8QV4fGwta3djUEX)f)vpieYrhWoRU73)t)J)6F7F))5xwxcYv3TZD9AC64WroQW3V829X7WVDF2VD1MGq8t4W3UFnEdkXl(T7)t)9)6B3d)8B3xfkjUxrOGOREgf6f484vRpeDfHIxhDfLycMr)xZ(Nrb(t)eGNqKFKhWhRH)oGGx3O3UhTEDG)pb)XJ4xIMbibfJ(fb0ZK)3)YVbazxC8HOF5QR26gVl5bclCf3RofGjq2OhMVz(C8N3481BbW(xHh556Vfarqs86ac)CiXZlc(bKpqrRt83Id8bcjjcKhEyuOpHsbEm9ToGbO6GcX5Jyhg5fV7pGa(hgWEKp6T7dXoban8cGX)w4AxFu4lz4bKHONiyfERO9ipV3U3pz)dewlydW2b)gbjpVZ1dtiMq0dK)igfUfhddElb7rjrXixkzTg)qYMnzucLgb8e6ge6g7IjYX)bYL8AO9Gzhr)55bIPmL9bxFkq(9GF)oqYvmscz)39qVqikqY(arocsJigXXHqCuucHHPy2jWhu0aUjMeuyhH9WouDCWHdb(y)4zGnDyWgGXwDhIA9en7arqrqWYuPO9MeGK8(0A3OdabydcB7hWajV825FYDZY0x(7ZhNzSL9(2ONqUEur1)DnqBT8QND98SJdSbk(j3NWeiLdaKh8dfGlkoHksKdLGn2a)zdgzrOhX(Ybv(ByNlBectyAj6a2gfg7gflhy7bRP9GmmhyJhL)KDOW15)QhE9yI5WSkqD26GN9fJ9ODO4yCOTtsyKaPIAKq0rG9grQNcGzjhsFsfWQa9P68OyW84tG9fiB3yV1z9YRl0)k19Qjs5OeM(BFiG8mLy9Z9hwdrhCxBhI3I9XHOgX8xMZQlCq(2z(tsfV1HMczmmAF3haI()dZb08FgO(Wdr4uyZ87uGoM4pB2o3VnF2xw8Vr)h7r)OzuXXqlAdUfJL1ye4NWjW1tp9fSag2pc0z2PorhhhSDRhGH8FpQC2pXE22fe3iyradrFkp2FOF8eyspyQ(A(Jp80b7C3UtLoFgeC2WiwRW2n)FbdK4sjBqPlrumbohoQ8EeK4zdZMESUNJj5O(vwRyyWhGfjNMHK8HRszhcRZbV0gXwu9O0UacumM7MidPJhLQlENnju5fv(kNlyOILMUYjr0dK5bEhszQYcOL)E2rOnytCAeLSFFGV9gS3UeFyrdEeL(8XStcC9HWF8DYSvHrclBJ2dbzPYwnfnpf4U(zK3JnINSGdJghf4fuIiIh3TV0mEC3xtILHakOEij0NyELopRzWfL44K8qsKeygJ8iXxTgd)dxhBytgXZW(eL6AH4l5GAI3)uGmNqyAd2MngGgSX8X41rSdy8OuapRoSMH)b2jjwXCwcNIc3huZsihTPb5u(EkxtIQLE01xgWYPuw49Opzbwg0qaq6QUtK((VkKSuVEWdbEvITKeUc(hXjiVczl2Fl49FDf3)KnQ5qJQZe3rPoqjo31eLf(hZCYoE0dbrrJhL6CCMBKn9FxqdzrCbEl(2nmXHL6feC4vkRlOKsRboWK5aMLkD9tW2LdTrMm3HBkOY85EZIZgMxmd(GxqWAynIWx4Iuv0cAHihxKhyVhfB)SRpy7mEcRd78OwEDIgsKjJkPYGWyBYUMlJIa2a6tqaefVtMuh48PzHvus5kMWIbQ5r05gRLs1PEikGn93SJWXsD0s2fw((wHDLt2hzKMMNci4XaQigtrZqrrUBHDlNUpVL)uoS)PXPzLyMqmxL81XJsbyGF7rpqE7d)VJbdWc)6mb7t7at8mg94XIbYHDDIp)jMt4u)iae24gI1KMRVVJaS6qOFa5tjZDONcC4MwgawpHzZgsNLQbjisSvJSsNYnE0ecjbHJVoiEwfk57ZLSWkG5nEOTWUV1vMmjlUPS1wr(Gpkp0EmSBE)hxU41jz(TDHGSijhnl6Gm9yXVgI3d6JOVT82PLUCy4rHopmrDNJjnzlP0hp7q8GwS4uXVwU00in5gWjA2(IfHHLZnJBt1gKiw1KFRzdvsAJz4GIvP)(YBEvTM3mc2jimm5a531KGfnri35qbSQP2yEuffhZVxQ641iCd2uDcA)by3KVKLuYAlr3sEUiI68j4OTb(VKftDMaP6JOXvxFCW2c3lEy0Nizuu3jIhw6JshxDxuWEiYfiuYsnJi8rWMJw)swieveUkcqQceU4f7MyEYmd05fyfKmparG15E0pSR(B30brxHTqCiSJKSLOW(49UyaW8lIXSewjfU8AbZ1Pra0Xj0nkA0JTfW1cc)TD8Gh5K((21ZFnBJvYDo1m7AKbYdyyQv4JKdz8mB)fLu(f9wNYuZmjhjlyRIWt8DCPhTswuy9DSdQdiWmJTw4NwWSU8KpiyY3LNhCr50UiFVQCeN)mnsG)ifs0YSJF78ISJxzfFsI03eeMMgQXJaI)jYeTzxplN2lbmmlkoGCmGa5SX1ZdhwaQkjLxvISOhWsVjnkEa9eLkodfnesS5XsGGRGVYkIJm5dve6f898Gxl5jWvoe86e5IQxPJ9Gdb(FBXIxhLUSbe1(Cd33uHrv1Ja665ZnCwzkHb)N4OszDPjZI5nDGk7cc0nBVIWPO9HnHvUWlZe40T0LE3SKm2tDbOEM4vLCK50rnvsalLdVdcSYDUsqkn2JlsrOGTExo02eOK5NoXG4Nv8Zc02j)7KNcj7EpjoWgfhJCESn7DVPuyh4Vnbxj3PSHskH9l2abiKib3MCOEgQtbSQcPj)vX)yhkjI8cMsgSV7JU0TPWthLaN7GaRrPvcjsiFy2HcQddi80bnj6yDqs9zJmt9ktS2CJYmRgiw)8HQbWkITHpbPP7Cvapkp3OMSzBDinzBNwarPXwJvTlCjMgUh2fupOtdiDgiiL2nC)sgG9672rVnoP3wzmjsfDi6CdrT9G3b)dTaxClbjelndgsPKXFavLvjDJtShXplLTMhQbMEVwLT6qfkB1B1LS17q1iB9EudYwNQkp26ewVXwN6Qm26yxBXwhXkk269OoIvH0(Uur1S6HTob1mS1XQsHT(4wFWNsvDD)A9xTaBDCQayRJzD)ADuR2xR(OgFTobv2R1XVEETEhQIxREO2DT(qvXUCHCVjWjjs30L0U6116YTkDTUmRnxRlXkY16s4WKlGTO6W1sw13MojVlvhYPOkCTKv7ThrYpSFRbxlrvE7rK87PkW164v3TwNfvBR1fwn2AXKWjZm)o)QWwRUuBm1jOJvD1Avjh6MPuolQQwRHAP99QwAT4pPHUBEDEi0B2K0W6NT7cUc7GpY1rBxCgjGNplRIwRlXAN9IytozQu9RIL(jwGUvNSD0hSGzvx6vjRKS92TkGsJY(Kro(oxBSwdveBxQiwR336G1QZ102fATdwzBOd18Q(cU(OMxTgQ01Uk0BrLU2DFbv2hDpvvRwVB1YQ15DfSkFsKoKTWtjR5yu1b01NrXm9ru1QkpZMAGoH5t0mqCuQmvRZS6r16KxfQ12ns7W5jQ2tLgNGoKQovbA3MpRngAB1LcdM4M3ngVpsUd)6LgQvwLf46yhMuR2cfn0X1(fBwiWc59O)jSVhYk6IlNWMOmheidt)NGrBu8NinH6LrGG0dBVpXl2n3ek1zSxWwxNgH6oqZKFgvKFTm5AFF5T5BXjVIrhprWRKEC6q0hrURXS5Txe6y3nm7o634UDxSDwg3)UWToNKwgJ6b)0ZgR(PHXZaxR(aTAGBuQsYugaylvfvX(YRBd4ROQva9V3e0RUm2enpETKdtFDe7kYfj2PSeJAqSjE5AdebobbEepErvi865Gz8evjOzYKkwD)HftVsLH30VDT6e(ms0ObHXuiiDf0OKr9Q85Ap7gVZ1FX0MmpByUDfG1GgdJcj5N4akTIRMiBxbLhsB1nAzv)NHi5G95yh7Uhp97v0enWwmLMjlPWsJvpdOkpHqnnIUIFHlLpsrfl9XMeUjS7G72fJR6N7lZvH7YLuYHOW4hz8IorUEr25qlwDjGSMowGQTQoV(MhBaR8BmuNuDOWJsTGre(USQNYmtvnIK6kddRpwrjIvhnCPdMAcZxZslOqHxai8kW)SgckyP4QAI)88ymS0OCLMmAYenETA7xKTQMkC7XUFZkfnuQzvFu(rcXvrv(0aE0OoHio(HGlKcc)a6F8tt1xVzjRGUAJMRQOIO94fgvunniqmrbRjjDjR9kQLT2O5kj)tPw7uoTudwVx1CIdPEzdLFJYGlLfmOYiivfM4O8GER(W0kA5vfdSsihFtzeUtfqESNekptL(mHCfBgl4hw6ZidJmOYOs)2Ig1j1YdJWOFmrFiJNoLSurSCkChmr0TCv42Mltjy(wMNmQ(MjM(k)o3vf2TCAxrbbjI6zYRNm6NntIgYb1CgB8C6rYNjjUKYOpISdV2y89ViodyhMYm9KLx0ssOrf6j0HGjuUo0TWDW1(z5kN(kNkex3ADC(kd)xKRMLYkKQ2ojqP6vK2n3S)RMx4ozPXrXmsPJsWMkRvNiWwDrhqoUXOywTwHSZs9fi6KlbVEXzPiur5joic1sekoRtMYhDugWfJ1YRh3B5969pXxvf3vsb27UCw5smS0DLuG22PwQ4OBUPTZdMmjppA38L5zLKww(z)8FCA9e0AAgAxD3tGBgGU4(oVso9Ii6xx20pjRWF(R0V2Sz3w7v)z4r834)v)6TZZ)CBU6UkThGv35e6gJdDrWF1uVQzvmqnCilhQC9Ugw4MdoH9WgcmVvfmdQ2tBAgW892gcg(SemuPR00mO7CpVHqllKqlrSnRg50IAuAsVWHqmFrITdJDJcde1u0Q7ywFKyMYzcsVD)eI4NvteF(4reUfDLhcD8v10XxMlsROBpZroHuFaeI5pkXmHPD2iHC0Ql4i(Whii(65nigw07edfTYCJXyfKJ2YZUtPLHgLHEH3Ok1wcLE490PqmCSPNIg5J4o5dLCL5enQSL8OX0O8)L(T4hkYL5FTOP9i3FwzV)r7M)dfL8UrvPEkQ89JK6PacQ6lquQUb)TNsJkk9iZ1ltSdlwODSdk6MquSX7GnhS5X9iZ)AlAZqu8jZhkFFhsgEnU)drJqI3)jhwlBirAI2MBmru0Y7)KdTU7LkEBOJfrHUS4(4AHrnGcZ7ZquKl13wLEB0Xb3YCTvVrfPR1B7A(ruIrwSJmnwOMOI0We5AeruGZ7BQkWjD5OMGDoF092LKK(LeLo59zjGMKxJ)SRH1uVsQ2IOKDAV6oAslirWrigzU0kBVpgsGV)nCOXSujxpwIYZ8Uvf1HLOgRxcsd6gu5DPllu(Y0RQCnBTVJVT)s(AYT8LR3mr5y(vtKXXPPJ)CIBBQXnrzF(L7mYOvudiORvprfYvMBkHdTWH1nuoJFT0JhNzq9Ayg3XouoUJF16Jh3PrrKygxLpmoos2s(STgkd5tvTikko5JeWiORS9BuDEQ6YMxHBw23C1DSfOF26Y3YhKqH4USE1nKVAQXs1MolvxBTuuwLpeeJ4kPuhpZ0)DwkdBTuL6W8bWntr6U9kUOagkBAt)OQLnKkcd8z(OmmIyfnTR(rR3pDJkJBVlSZ)YhsvT3N1nGJkLEtpiJuwMjTTRD0222XXSvw1MEzfvZ07XcD2iYBYyUcnYzpllNfStaQuQBuR8AD)kc4kbC3L9FaAewY9EqfCDkeobCSORgBRO)I2GLb9bRJHNs(icLgLurHQCoT9mUEOfLJ5Jh9YCZOzMk1ldezLLcv2ilq3Uh1tR68wuAQtrKkykCB75wxkRLilYwvNBs3AKlA0vQyucVpnSlIOzHSdBr8z(1pcNIhCg0jV4B(pA1lVOs2gop(RNpxpdrnMQRFB(IszsplksREOhiHM7Os1KQc8W)6hVMQev6jlW0sO0dIW20MQotfQIYOHU9hmQcrAXtWEOtdAKoPr4lv2gujYRrVEXddfh6gultBhZmmtXI08GwCubPTAlrGwNUWt(oP0RtKrjjzhzAXik7EyTLQyF3EQfLPUhLrzm1jGu6ezDyiHhBnbPFrA1MOm(FDWz9j7mtSz6QzuYqw1N0q(21GoOGx2s(LPcUvWUp7dAu6uRS(0kkvwkleqJ6K9bvP6GYjsxvQSHN1rwrNwNgLuK5nMBltDIyQVfr92UPMB)JYhYkWg1rEPdtOOxOrXS6Ke0jptnHAzE7LUuAt9Nnku5D1kBXZIg4MimvCXliG8N1Tgpy7mBkH64A)sLU6gfP6EQh1A7BnZpnN2(Y3V0pfxNYk9gNyt6xwKP(kBnfuSkZbyExKILoip7i0P4O0H8Si3LMexDFpKbunBn)mV7QsuZZoM334QtaYpd8Fw(X4xLoe1b5mZKiZyO4gbtrV860RMyOTOxC)eGIDPrzkoGetACDTPZ1rPP2Dc1vGXxLFiXT(cM279WovnXoJVSEujUChbQAJDAAfvCNdPcyzrYQPhSkuLy7GVknbwmDeUkAwzBb(1JvNYJsMY8Ll(MjuqKcAHENWEOhLYLf8QO8u2Vnxpk6vScGcvPSsXrSg2S7yCFEjJfT7l2fa)A7IZTQTxlJyTkqm5(M0RnXpk2BZP2OJjwPR3AkZxBS9(TIuqZ3DGCJfj87QH7p8W9hE4(d3wIWD4(dpC)HPEJgU)Wd3F4wREkGWW9h(zfXomC)HhU)WT6o8oC)HhU)WfhdtT7pm3kDTOEleE6SkCBoCRH)Zd3A4s(C4wd)XNBB1TgUWxV47LRr20gD5u7HlvCSG7kCn(P6nX94Xp90vjowWneUgpvEpCpE8thV8WXd3lyXosB8mr)x57fCoRQQMPuWNsPxE279)MchFjEBGlTuvvkzgobSEvL9EDdHJhUdWnwfzFCUdW8ECLwcExQAcfwXAvdOAEZF7Sa987((2z)CcKcNz3b44HB57f7MhZmgQxhgYkmeQS5C4w(2hRjiyU7f8L)nE4U9oC3EhUBVd3Tx9xnOaud3T3tGqD4U9EgOr4Rq1H727WD7D4U9QNquqakrd3T3H72BRf6zSYWD7vRiV0HjA6c22YYzPpq9P5U9wavsrCk7ynvFxEv5sr03kvrqnU5laRGltr91KRwca1YdSOE9OgNZp5J4UgVMYYbO8M2XUu5r8t0(hKp((etMglDdUsDOB6TQYPt4hGFfFv8pF1DnwMkmL0r30BLK(jvNDsNsQbZ3p6Ty5xFCbosn(SGv(ryx5xHD1Fg2B33H9o8Hy)e9LyVTFk2n8BXUiNTmkT2j57LV26sd(SsxMxoP3RF01ffZsLEcAZ0bt4)M8rxx8gByWnjYUIBmVbZuRFUDTEcJAZerwjA(vBxXhm7w(LcUMMTHVy2IMFywHd)oivB6td9hdXk)CxZos9bXQeXQcxrNEw3KVQ7M2Xf(42YfKLffXzF4dGwrslhrwwue23oA9esvCi5tcFlN7CC)MWNUWRKgEKbRclpE52f6vR1cNDb9wjDG8Jl9H1n1)2ItCeV9hz3MWHR7MsVDC3HGNhpzu9Ud1usPxtqzzJItIlhTk)qZ4H2f4T28b1ta4laLeVJCFn)VWp665(29t(pdcXpHdtFHv))]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261121013,
    [[Hekili:L3vBVnoUr4Fl5l(CA364KSoz7I1lW1wu0R9EdNpG9BwMwI2MNLefeLswxe4F7Di1BuuKsu2kz3Sff9UyjXzEMHdho8LhClVE5VVCHhkbV8NVz6n3D913C90RVD5IKdr4LlIqU7rBH)iefa)Zf)0Xv)wkj84QXpsFKrcytCPbxY)Ud(uKhxwRtj(j)q4Y1Afllc7UCXN((F7h)L)()59OnB8jUjeA4Yf7iEE4SMHzUg117pUkzh(4Q8ND1gAm(bC8XvE4nOu)KJR((F9hpUcE8XvsIiLCfx1SREef7tD3FLxe7kou9yxXcCIHVAI4Nt(dgn8Y3aAjgfY8blWd(BkxRe2XvippA43b)XE8b2KJR(hOe071GMX)0p87Gq2LKeXE)vxTLKSlDn3aUs5tVeKjaA06PBMof)2nUV7wqS)i8kFs4wqe00epk3AIs99zWdqHaI8sd3IPHaqszG3WhJId5ifmYSVkcds1ffJlAXomYpz3FbboaObbOq0XvXyxkGHdGg)Lypsik(qUEapi6bUwHVIfG89pUkmnyn30OBaZM(7CL84oIpMdMy0A(FKGI3ItGgVLRDwklbreWYdVoDZMCKiWiONycnMKqWC)4VHi8pdfarB8EpFFWnL3vhrcfc5t0pTa8CLTKd7F1hDGdkWZUM7hbVbtYDefJzSuUbl0SlnmjMc6MgMlBg2h7k6JPrr0qCyYeiAoMUbmSLlqIyt28mFNZMuai(VXJWIa16aUyN1yaOZVD6BiBMNHHpoDuEmw(37GEar8foO)DUa)ZZV6rIVVtc1bq3dKhW82x0mKp8GsHWssfMVABPBCalWbcJyO94qZcO4lCkSEjjbJ0qryhuCcHLywebqusa4BkeXOlkEZouSxXt9XEJ4DZtQj1jE0hdL1jBhkjbh74MgZ0y3TlAUVhIE4EZmbmjnk7n1eBdLM1dYsGU43aXiG3BJZwxV5xx2B2Apz7qtvrWaxNik)jTQR3EU6kgfr8CIXBXH4yuN67UPYEBxuOt(4)mhytP1WlcTjKSga4)fRiQIhdinoIHZKO0ZfIAepRZKDKpmDYDZ(tIFeG(SjfOa(zNIgLLThgbJHDPeF76hGjuWHmOVWjlT2Oe62T(GClEoRAmkpM0HaoueKw2kLMzpdNshnggKcbEpv86OhICks)DPY4pW14aFNxlXFf)ccr4d8ZBuwc6YbCfYP5yCAQVdmoyFZX3Jlu4tYrIasJGjMUmx0fnVzNymmJc8Qn6Jpgq)zPeeASyyDUshDrM3(lsxDZ8AMNzAMKUNB3mtCNlaPi1Kf5DrLYO47CyOn4UhAZsdcOHoBW(7sdHe1QIp79JKdFjHqbeHU5XBqlHjdrbqzknJ3Ye(duI3Ji)9Dk98IQyJyuFAL45z(2EWK0jbn8j5IviG1PXH8qKSXfMecl11nDDkZGKsq(8Aq8WWpiUoq93jtWH8UipTAjnshqdF(uHBmeMJDKNpTJ4Kqm2Jj3GrxKjUjnL1e8NXUPjngzXTkuCaTr)AHYYkoO670K9x493tcnjIcujlL9H8PTKeoxazZLn243)KwWOlh8AQFYB2qDtzWK1YWcMUh)5KuKFPxehUfY86vl1lFjkUIkG6orrwAmEIvlvuz(Q8uDJUynLXgDrwYQjeMJ43LAoVofyS9hUrQ6LS8tqQOk)BjsQ6TvetEcrzusctXovn1GPvKamta55aVz2Rgtw2Sw7tPEqM64dkv1PBYKyKlb5dXZSeNhjHq0XOXYPslQe4PXw4hgFrf2OXjo8vewnBnS4QhGjQl)MCFnyVxMp9DfYBmmedyyp61MbLH6SX9LYw8mhgorjbjF9hfRodwDjFDtS8b53yzGOg4ocuepSHnbXyKTWkcZwPZ8VRqhF3OSvzprlcQdEZ5jkBmu43EFWhhc))Nt4lRNMMG8B7Tj8igT)5g(f6Oj0lEJTWwKJaA3gsm2sK2S2DkwxPPzZxWNx)ufC1yIQHHs5)(48BEkVUI85MqHqgaFuagwxz4(5ZU0cpaSsU40i(VgGESIUJszojghaUy2hMxu(r1R4PzQklP65vzRhN7wFsFJNp1gdefebvnFiFRpAKe8eT0YkrwJcfrEOT0Wd51IK7gQ)kr9inBhusCG(MjEJHwTd9a1vFZYEvw7AesXR9QWHiGv7gI2xbfq6DipjDnNBJjEQ1Ubi861HtV7qsgjAhnFf1NVxjhksc12SFeyTj8DBF4arHeBmUV8f1g1x(uZJ5R1q7gXFIMLUaoF(zc8HRN(KM8uIabTLW0WBi6pEEnAP84UhGYRYHdFrobOp7u)z30txJUE8YCljXWQe4a5bmFX8bemi4QmoIk9gL)EpAIKlC(1AMXOMV6eNwyqMGtJn3sF9aBbw0JVgd5CJ3ZpXQxzL2xH8VbxRsExQ0UnKLPyOMyutyzXkN1eD(TYuM62G0YnuSTStfVZID(9Iw8JvB16Ttl3Q1ALvX3v2n04S9lz0fq83d8W3jxpPa7vcgIntO8Z7bGZgIVpoUuu12H3M74IOMHbZhu(cXrmuUr7w4AK3WfnURsRj)m1Z9kchNp9JfvfuztqkqOUGXMDqpjABKlx(Fy2SNUyC(AFexJG89s9YEfkv)edUE60EocmdyW)kHv5RRcuMnv)EYVJstodnnwtp9y9EdvFMMeyvPhpVijtz9kBXJ8fNYp4tXlV04oZE6oMlglRlX0SFB4QUSr9cYT1(cgoZiVAlQonH6GssqU7pLLuRFV7OHBtX1obf5jYnyGL1FbUbEbfPrn3sUmb38K1l(a8N3HszIse7PYL)29erTDQAVs4kNHrd8vBAsTO3Mrn2aBThOr3BELnIU5ahPrjv7D1udLO3tTzQ4BnOWIAUBRMDtRF)0aCJfRRbXMly800zZY8SRIr7QHBGImlk0OJ8pnsLPv2gASP1yucPI7qxZYEiHUOiyLhjI7OOChulhC0zj3wwK35ixUWij4aMfITwvO5NGDCAJl1Lwe14joYsqwYbO)aQEMpnS(7XvxiRZZaASfNMduDGnFwRh6tAeuQGAo(ANPs209dXPZOvxLhcsh6XIJrbK)LYfv3QJ30Pxz2Jw3s5o)gZnk7z7WE6t)JLq61JZx35Uz2kR0(lPt)LCqHfM(z54L39dzF(gY2Djo5B)9hNF302fJHlLI2c06isq7(CoU3hjxh2THZUySMcBuvK87Sqt62g)X96Cg6qbY7P0y51)D70r17gVBQgrPzUTcjArXqTenuu2D1EkuVMOMiqxX2k3u1YN3Rdq2K7YEO1ZBSOU95ZgpEvzRnwx9t5760h08b8DDcmYLlGvBZGxQWCgFclHjiRtgrxG)8NfK3jFBdw(3GxPE)px(Z3oTGgdlxu7YIUCHBmu1vmbb)vxmxyzcGgfLvivfMmil3cXPLrdCzEBBYKwNHdDlyvMoW1WBnOHACuOBrF2mGGJLzgWctM6cMXs7QSpmJGdM7me7if30sas7iA5cP6L5HPkHGI76jhe33oiE7ZhiiLC0GJJ31ooUBQUEfBzqHzG0SbCW8xneMirUbdWXkorOpXhxXxpTd3WSbhmc1AknMuuqHARUK9TgzyXjSOFYjbEuZ01IB45gpL06qpVoeW1usuwfbnSyyuXVSNWhcLBk)AjfomNpRIjiwtfeHkvtJ2w3t5H68m19ukH2yjIa1DKV9LmOsGhtPELQDy2mRRDOfULi0MAc2cXwuZKP8RNaPte6ZuouvwOysV9MnkIkKuZFQO1k6PyPA7MMkc1QM)urTKaJU3o4VIq6MQ7tHqlDOI(Z6eHYnMBRgtxEE0TPuBnPTITrVNgvyeGXuTJs0mPluKvMOcTuecxn3uDHZ58sxYE4ipJb2ZiWPAolnyY8Xi2X(yupdP6KO8vOTCHy1)8k44GXukTkYE0ta(LN(jJKrPcJBe2SAAvD8TreS(TG3qSav1u6MkLV6qxADoBRVQyN(DfRpxwmfM6iSy1ztmzXzhD1RjRTlA8imF1P76vqRUlN65UD11GRP0uABAzcRBewM6CPpFwwp2G8(zDYnvX6uNT(5Z6Syx77Nvv0mflY0u(YefQN2zBegsOttvcuTBWNRgTGjrDTtWTSSMBpRseAHnb2FOfwEDR799TwkWPSjkrmQLKyk1DnQYma(OwVzVN6v79uVBVpNKq6uyHKONrTWP))XL3vWCnmwpE(TQfFD2Entx5PUaPuduGOA1sdfeT7ufTIip9KjpvwDrdum5ZQcjDHYLmB6LIAtdThX0UuiNOUgRNezJBWfkU4QeC)8R6cL(kGwuMNLt44oRI20yXTeLm04VZyftZs)w166mUKYY7B3RPfzPqOkHfRwv53MlPmpuPXH(lCbNvDPAI0pvEw9TsPbNYbkCECLWcMi9fNKwcxJPZ(q)HHnmoNYx8kG9wQ8RPN83I7JN1XjLF90P2fsAXGE7P2Lazgpmi(1uFaGqFiYudpTMePp9fJltc3LXt3sEF)pBN25XhSVUDJx2SAjM1Cct0hy(cmmiHScDOwPPXTgPInz9tZcTyAl7Q2E2mguPt02qjLIAzTJGzcizAh9kBrfPWovuj)TdeZZAN6zcdtTIklh5AJbP9Ocfk1uzhTV)O2OZMJPLg)krwnbmmEfXKxW5jbdtRwsd8SzrsTTklULCNXRmH8oUCwMIn8BtaftZCQug6zbMHG4BTusTWooXP0SXkAHsCcv37m5DXvoHuTn3DZLpwAgwslnH6SE95ApY3tsL2Uaz9BjWjPs10NMuzj78AvJcrA7Xpit7U2TJgpPgL9ekvnvOjL2GtFDAp3BE7NTHyEdf)9Er5Q0xesKPRojJhJ99M3XDBzs3lipZgo2991spJ5JG)EZhmGnuG7fTx5fDiLfg)q0ZO)AeCV5R9Hf8dSzvq8n(trdM3fFTfs3MwmED7UxDwzPGREFe9T7pnSV93RojDteCMmo0q1V1aH59r(S5JyL61Fmx33N9CDyjXOq9gVt3TxxBT50FNX1BODbC2ZTWtN2JDDBxeW20At056Th0wEB6FNPvu02oBAt3ABmLStQsUmr8)47yZo(LF(FH3t8jhxn(FM)FzTeVE5)7p]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261121013,
    [[Hekili:T3ZAZnoUr(BXFrR0XjYY2JMDUTSMQYEPU62K92KkERA)MOHiHKymfPk(WE8vU8V9Rb4lqqaqWh6Hv4hswpIe9l0OrJgD3C5nl)9LpyJIWl)TBND7xU5MBVz2n3T8HOx3Jx(WEK1tOnWF4H2b))pSfz7)Y7p(Zbip73FC8l(Ve6SlCQL)UjKx(vxFKnbGRIDCJ(fVLRec7W9yRLp8h)5)5V(3)V(B)KnENVNVR)Mxx(WwhBBCYWWHwQr4p9(JrBXV)y6VD9A)a8Z4G3F0gVgf7g9(J)5)XV((JWp)(J8Wj25AcreE9lOaxFRNU2EF41eI2o8Ac9ygshG5kY7pL(GP)RqFVjFcqk8BHUaxbakYNqeoHV)iY2237hG)4j8RHtF)X)ckc9tciUX)V)YVdazBu0(WF66R34eTnEfHFUM7vNaWe4b0QzRNnd)51wF9oaS)k8ixhVnai8JJS9jm3(yx3q4hOSMDS3gSVhqiXHGWXfJc8iukWUjV1EmavluaoBeBXi3OT)jeikGbSd5HE)XaSLpqdVcy8Vhy74HcEnfpGaf9mbRWBfUd56((JEX7wryn)1aB7)7eK8YwhxmHycqRi)rekydocg8gc2dJdJqouYYgVkE96ukHsJaEcC8dCICWe54)e5qEn0oqnKmz66cIP0z(9oEuG8h()XdGKlFKeY(F4IELquGKDfrocsJqgXX(aCyymHHPy2Y3lkWhWTVxkSdXUyl6CS)(9(EyVOPGgEG)AGXw(aYkYbeYt3teueeSirkAUogij3pz7eUhiatqyBUcdK8I7M9jN1lsE5VnBuQEx67BIEg54sfv)1kG2yX1V446AgbALXbp78mMaPmaGCHFihCHrXurICO4V2e4ptqjle9e2toOYEdZmzJqycRsr7XMOGiNWi5aBhOnTdKHzaB0vzpzlkWo7xDX2JiQdtlb1PWcrpXyhwLgfHdmTIdcfivuJeYCeOVrK6jayA8(KNucSkqFYCEyeOE8jq)cKTRn3yzV4M85FLZ9Qjs5Oew(BU3N8mLy9Z9hwdq7DSndWBWE4auTy(lZyNlSqEMP2tseVvHMczmmApNvar))H5aA2pduFW(qCcSz(DkqhrSNnDRZ9ZM(L5)h0)Xo03RhvCm082GBXyXgJa7ew(oU6nFb7MH9cH5mZeJOJI83SXfWq2VhwS6NOpB6aIBeSjqdrFcp2FOF0yyrpOQ(w2J3)8EZmZUtKUEMSRlmcBf6Uz)lyGetkPdkzlI8fWzWrL1d)yxty10tvTCmod1VXQfddEpSj5KuKKnCvt2bW(CWlTwSgvpkTZHafJzMjsr6ORsMloXQeQSIkFNZ5muXIMUZjr0dK5EEdsPtL5ql79mdrRXnXOry8oW9vZ1y3TXEWMg8ik55Jyxe44bU)4zLQRcJe22gTdCYsLUAcAE23X(fK7t1INuNddhfcEwxGiIf3nVwpEC2vrILIakOwfh4ruVswNvp4cJTSIxfhkbMrixI)v0dc4yzch6iAk2JmPAleFX7vt8EhdKzfalBWMS(auJoMhgBhYoGrxLa4PvH1u83XwXrkwZs4uuWo)kAczOnXjNI3t5Es0zPNC8KbSmkLfEp5r2GLbneaKSR7yPV)Bcjl17hSY3TKVLe3vWFpkg5MlBXEBaR)2Lm)toOMf1RUMyokXakX4UMOm3(yQr2rxTYpmC0vjghN6eAs)350qQhxG1I7VLXpSeRGGbVczDoLuOnWbMudWSuPJxm2SyO1YKzgCtavQn3BN)HH5fZGRC99TH9icELZtvrBOfGSCqUG(EyK5loEGUZOXSgSZ8A5TXAirgFvbv6hezso1CHxeWbqFgCGi)DsL6aNpj1TIckxXcwmqnpH(OXAjuDIfICyt)nZqCKudTKtHLDUv4u5KZrgQP6PacEeGkIYu4uuyOZg40YjNZBXpKb7FyusujMkeZLjFDSOKdg43EYfK3EW)7qWaSWVktW(0oWeVGrpDOyGmyxL4ZEsZjCQDeacRDcWAsZvp3HpwTl0Hyua9y5iUTqLJK8vHWAeyVWmxPl7Dss8hZCpjvOu(Hb4DasdV)2PZZnEYsomMphNYdVj61iMiwmBsJKTnF)5u(d8VmW)zyINbcL9cJedu3KGdaBGNY5PV9ZXUKihSYXLeRpQgroNZcp5moZB1E(M4OOMSDfnQcJJf2Jz2C8BlU9TurvkTct1MRDr7Wtb66PfZBgbB5heeVN87AsWIw2MTMmhw56ElY8JT4reXAH)Tf)U8jfUb305e0U9WH4EnnwGv2zSL8CUJSRqEudrOn(EVM6kBQaP8JOUZwDCWPX2jEy0NizuBrp7BjEyjpkzCvuViUUNjqOKLAgr4JGZKy)A6o3LeUk8lPeeU4f7nr90bo8j5sJ6GqjLsYGuLvF5pO0AV8Fv(kVsdSPR7AiJjAY2LyR)(BM9Ma7f0jbHEvwrEuAJGdnBZyr16vW33ucleS2Sd9DZY)2TAkCenRNV2okaoyhHuEgtIJZohma4Iv8u3VhL(CB)igH4IBey7UK0QLgORv0OhBlGRvmF3Z8qJM1xHb7Fbpba8J2zVkO8l6JvMonZ6Gh1cs)TDLaL1SqFiqN9YBJmrruppAZQSFL9mnU(GRuirlIn)DZYJnFjhFiHXFTFqsqWgDfq8ptuLNEZ0mAVaWGEAKp5sibYzTJRloihuLUsavHrJE9o9M0i)b07Zk)gC0qiXgfnbcUC(knfssLpurOR)3Y8IOGNaJLGFeJLlQEJo29we4F)85VD1ynoE3KwQUv(QPUz2SgUEnHKH)tuyXSqHY08z1DrpB9919uUIW5ybAdJ1tIXlNfykSWqB30(Kz)mFeVqoik5U8PpCsVf4ErISRgZIv625xMcXjhGiu0jTvjhXooY3effHSEQnhWUUW767TjgxkUISUsiH9Z9keeseNBkcwepGvLKjzVk(7BrXH8UUQdzW(Up5q99KNokao3LKvHslTHTq(OzR70HbeEZznj8x6GKQl6ywHve9Rzn5Gf6GxzhDqa9OXjguDIdjsmN9B9R6PqdiDgiiL2BOtUna7vDrvpVD1Z)ZMftDDi7mFJYhthdYUCthDyfhprwR93kg1fIfnaJqsUiRC1yX3vvxrXEp7vavVNFSgDiRyn6TCH14eKbSgNI8E14yLTRghXCC14yNzRgh68z14aMfRgNICxvfs770tuZmw14iKNQghQSt148nNupMt1vTR1F5FQXHjRtnoK5AQXbndtn6J8k14iKnPgh(Ci14eK5Og9q(IACwLLOCEXU23kou3Wq0UCe14YnZqnUmZhuJlXSa14s4s6YHTOC)0qwgFMSiVlxL(XiZpnKLVNhqYpOFZ7tdrz75bK87PS(04WLRNgCrJQzcJ81CDmiuh5m9St7XQXnYCEMNNgFmYUtJsbKRz6JFiYTtJHm68uLrNg83zq3vV(yi0RxLmpzh7Ui5SjBoBpBjAI(dsUCA04m4SzIMpSzYzx2yrapF(KhNgxIzV5fXXbtNsRKUm91gsculV0ZytjXGUBP1KgPGiJC8eNNMgdzN5Hj7mnoT5KPrNZTTl1Kiu2b3BVGAi)lBCKd6KMzPd)2t5APXjldln(yNxLYxfPdzl8oMQpit6a6QlCywLikhkn(GL5Kgh98LSIdMTdNhPSKKpA0nKypO5gz3w1OtgrkYmR25bjmyIXuNi8Uq5MvRM(IgP3(nW0bXvY)nrdDuLFXKfcSqEh6FbEbt2EuCkVvhLzHazyY)e03dJ(ePz9UieeKUyZDXUrozAFjM8C934yvlu3cZmz3Jc5xlIvX3wCxMdVzz14OXcELKR8f2kp0XgZgsBrOJ9SrSNVBTZMTrMPbh7BcpivCsQ2Pg(YU)MXJVsOwD8(3Q7syMu)TWuvSm5nE5sncgLZUPZR2(rfZQLr5IBAd4lP1Oa6FRvq3Y33Ly1imzcGZAyX5Mhnw1HQhpUKUXFA(KRvPEm5(BuFi9Ren649G3HVPIgLmQ3KVI4fNOToEZNu3mpNHuD8Yw0DQLRGl8w1k0Zf(4m19mbaVFXgc(DWFha)Mro7WtMO(g7QrcuJnOsIZwU8xe5LQF1sw(BLulRHdzY4XsudRbLs3OtLBYTw0vCoPYXSqkQKffPXSNG7UzJkBA(lZuH7IDbZGOgUmOyvrMJZfrnOSNdvParUlZL(V5)EJUQwzIl9jTgMgOIISNos8rku2tJZ09I059dJykrNA8RyH4K3H)gwywcQrw5aBKowJxRYb7ytENCBYShmSuUXKypVpYYgH4kpzwQbpAKomKDLgDLCrINp9p(Hj6pVzilVLAZmxzrfz2JxyuAQPgbstMG1KKUKN9YtzR2mZvq(hZzTJ5Ysny9EDMtSR0lKEHwk95vMpQJ4FqsiiaV)k7209ZRLYmuEZ4LCDQASHaek8aBSHpk74AD)0rY5G8eAqh6pp3bKr9fzLqdP9kRFpzQbkpgDA8QYoOuTuTHSCeOJQekNRLtlIYELom5YW)5huDHSBzx9buL(m1NSv0SB2bX(AZVP50ZWkNyKFYxboTw5InD8Sq7rwor0pjsvLDgQZd)JUe8M5FifHkYDLbrOwIq(4P0uoOJCp3wXlUrP5owcV0HWB7KTko62BB7mZ4XzNC82Vml9U7tJqWNVDs1qe00yeS8HNbfFGU4(eYrcMyi9txxYh7n4p)n6NYU0aHT8NHhXxkNl)T7ML9T7A5dLQ7ZLpyf4eHdCqWFvxtiyzeqnCildQCnLaw4MboHnNacmVtfm9l3ScQhW8nTacg(SemuQDdupO7CZmGqlZLqlHSDHa50IAu2KMCaHy(IeDhg9gfkiQPOLpWyXMOMYPcslBtcr8JQjIpF4icN82TaHo(QA64lZenROBZqqoHuDaeI5)uIActFkqc5Ov7nqC42ii(Mz1igM37edfTYmJXOfKH2IOhRuZqJm5l3AuPqIsPhElDkedhA6jVdniUfnqjxzgrt39hgOTglJY(x637gOixM918UXGC7zfn1bT7QduuYBgv10tEYdEGMEYHGQg(aLQRXE7XuPIspYm9Y47W85A77GI2ebfB8gyZaBMFpYSV2I(hbfFYSHY3qjKH3g3yjOEiXB)KdRfDAcnrB9DCckA5TFYHwNDsfV10kkOqxMFFC9MIAqrZBGeuKl12wPMwXHb3YmTvTduOR2B76QfuIrMVJmDmI6OIe3e56WeuGZBBQmWjTVI6GDgF09(GHKgHbLo5TzjGMKN(PS7HvxtWOYMOKJqV8bA42iEWrigzM0k6BdnKap9DsIrSujxZZGYZ8Mvf16mOkRxcsd6bu5nPlZv(Ia(PCpBTljP2xtsnPOK4A6guoMF3ezCCsaI)iXT11roOSp)2DnsPvurq217lSe5kZmLWHMBW6wkNXVx6HJZAWnu2mUJDOCCh)U1hoUtJRnTzCv2W44izB5Z2ZpAiFQQ3FqXjVNanc65lT7y(v3M2(rl67hmBYZmiUjHo5YrlZFXuHIW0tKQzPmddfit0U0E0WVN7K53trAQ1qPuBAMi1LIAY4pcdW7etJiwfn2GEVvI04s)MX2s(qkRp)zD9NPu3YOhKrklY42wLXTTmJpK9HK20isOZm8(D9VpI86uMlrJC6Z9U7A8jjr37sjnSJDuW3zdGJL7KFCI0tY7GjhRwysFlrKgPggRGLYlkQPUk98ec4kaCZKRIuLodA)jY3cHk44DXSrSSaowHwsFt)1QRiDlqEFCLEK(8eq5J0HC5ACkuoM3j2lZJ0NQQujv)PIaEVw7QMEB7Nkxk77k7cwuDHoDRhhOrhhHzs400mwiIM5YUfiXxgz)iCYFWhGU0cFFXOJ9PfQmVMui4MzZ0tfvdJa63cxOuM0RpJus39aj0LgusLzcbgAF7K1JsOIVAsUHK4t0zHy)23xoVfRt6uaIiZjsZ5J(rLMIdEptLgNIIUgtZWmflYU4ZIWPN0PuebADAVdz((QxJKHss8(QvHKkA(lTLQyF3EQdZOUfZqzm1Xnu6kzDyiHxTlfPsZdeLbRuhCwDnnZ6xMMsdHm(ImxckDa1wrgYoDLaYtNdvP6uzuorAUMu09z6iROtFSHskY2zLZT1ormvDtxpx(10fCkFiDlUs3kr7yJdrRVHs0Y3dOZRMv0tCOOwEAulz7N6AwouOQBubY7MoIWuEc9tbPUh7MTn5OeQJQ8lLAXouKYBMvgsR0dEQNFQ)ItkE)ctCCneLKkzWK0wuiwnuwKVeS(JYSDM1QmyPdYZoaTThkDip(8DPJ9u1SfzaLpS9pkpi3kAMphQU5JofSQmJyL4k5XXUmwf1qFAM(vQMvEjusrV8egGJPBp6fxTUuSlpYRTU(169(dKQgeuJR8ksPO3YweKMs78ciJkGL5AVKnO05KDTQxdDM1SHOYgzNXqttQLMXKGc5XBvrpz5W1bI0YGKSdlioF8v16IoI9UicL)vz7rkkux9BtnIIEPhkqTZGL0y(Q8aLj6OA63RHeDan9Ads1LKjuYwM37Ie96t0AwNdFvMB4QIXPotRJuTkTUwN0ssQZ(W(SpL2lhQu1HkvDOsvBlr4muPQdvQA1DTO0ZqLQouPQAo9KdHHkv9ff(omuPQdvQARQw0HkvDOsvT9LvPQC701I0wq4DCQWS5q9P(Zd1NAbFouFQN)CBRQp1CB9IRa0gPt3OYGShkF1ibvLAf(PCnFE44NEQOvJeulQv4PIk(8WXpDSmvJotQa18DoRjBi0ihZ6AYpCSQl1ib1DA3DGOLxWLQRVIQ)O8gO6AUgE5vTP52cuM6xn0iq1Sa7uvbQrd1yATz915tnMM7DyDPm3L6mHcTyzoAvudIDwmLsyNWAnnsq9K2rgvK6WzFfMg1ZvrAJKyxg1oAN3ytGu4mOEsJgQy0l2dzNQmujfhOIazEE2L9kfOIFbxiPrd1j6qDIouNOd1jAJurLzuoFed1j6rrSouNOd1jAX7ouNOTeNvxtZS(DOorBpRmuNOzI0H6ev0wdhP6evtgsDLHQEDU4VXGIGCu9LuPGKXV6UzLVc5kX8supstJ7jUV(OgFu)8PEM8HXLO2u7v)ZDv5DBE7K9jnU)(MgFgn3vBAoWKsaDBE7K8bn(iVKudMVFM3IKxdXcmKwm7OUqDpSFnBL6HdBXoQOKY79pPTI3FRuB2UEQPfFwBfDvwmyLSpDEjdly2u)yExtvzl9H1up3I0s08RIRIpiPT87EzLz1A(IKksjRzjN4jqQw3h60ZdXk)QLMDDudIvjI1gEuLJV4qNVNU0Oz0G7CPUokHCPVkoK851TLZCh2VVUjM9L0xooQ7OxEU8(5TBBBrBSQN)JDCB(rDO5WOWDyMCoPzCrZDpqBoGQZerdH8wsTR8)GFYX159hh)F7tsvYGKxy5))p]]
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
