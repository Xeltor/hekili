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

spec:RegisterHook("CanAcceptCycleTarget", function(key)
    if key == "bane_of_havoc" then
        return target.is_dummy or state.warlock_defensive_target
    end
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
        rest = "max", -- mana rests full out of combat
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

-- The summons' cost cuts: Master Summoner's -20% a rank and Fel Domination's -50% while its buff is up, each a cost
-- modifier on the whole price, multiplied as wowsims does (spell_mod.go:505; L1793 item 1). Imp, Voidwalker, Succubus,
-- Incubus and Felhunter.
spec:RegisterCostMod({ talent = "master_summoner", pct = { -0.2, -0.4 }, spells = { 688, 697, 712, 713, 691 } })
spec:RegisterCostMod({ aura = "fel_domination", pct = -0.5, spells = { 688, 697, 712, 713, 691 } })

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

        -- Master Summoner's and Fel Domination's cuts are the cost modifiers below, on the rounded whole
        spend = cost,
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

    -- 120 s category cooldown. The wowsims lines cast it for damage; its heal is `death_coil_defensive`'s (below).
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

        handler = function()
            setCooldown("death_coil_defensive", 120)
        end,
    },

    -- Death Coil as a defensive (L1808): the same spell under its own key on the Defensives toggle (`variantOf`: the
    -- spell's IDs and the belief's record stay death_coil's), so the toggle routes this use alone.
    death_coil_defensive = {
        id = 6789,
        variantOf = "death_coil",
        copy = rest(DEATH_COIL), -- its ranks (a variant's copy maps no IDs: Spec/Abilities.lua)
        cast = 0,
        cooldown = 120,
        gcd = "spell",

        spend = byRank(DEATH_COIL_COST, DEATH_COIL),
        spendType = "mana",

        startsCombat = true,
        known = knows(DEATH_COIL),
        usable = unlocked("shadow"),
        toggle = "defensives",

        handler = function()
            setCooldown("death_coil", 120)
        end,
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
        -- the time-to-die hint's execute line (lane B8): Decimation's damage below 35% (wowsims pin e5a9cd2a2d
        -- sim/warlock/talents_demonology.go, IsExecutePhase35)
        ttdBelow = { pct = 35, talent = "decimation" },
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
        texture = 135274, -- INV_Sword_04: the same Attack artwork with every equipped weapon.
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
                if not sim or Facade.PetAlive() ~= true or not demonOut(sim.pet) then
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
                return castUsable(sim, ability, sim.locked_out_shadow, "shadow locked out")
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

            spend = byRank(SHADOW_WARD_COST, SHADOW_WARD),
            spendType = "mana",

            startsCombat = false,
            known = knows(SHADOW_WARD),
            toggle = "defensives",
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

-- (L1808, owner "Setting per line") the health threshold of the packs' Death Coil defensive key (35%) lines (the recipes'
-- `extra`, the def-int-beyond-wowsims review's defaults): a 1-100 slider on every spec
spec:RegisterSetting("death_coil_defensive_health", 35, spec:HealthOption("death_coil_defensive"))

-- The priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit those and
-- run it, never this block (tests/Forever/warlock_spec.lua checks it matches). Each pack's .simc is generated from its
-- wowsims recipe (`make wowsims-packs`, tools/wowsims/specs/warlock_*.lua).
spec:RegisterPack(
    "Affliction (wowsims.com)",
    20261128001,
    [[Hekili:S3Z2YTUns(TOxuKIsKLKp27jPSCvz39Lz3mzMACQkVjAkrkBoMIufVyF8wQ83(2aKeee35nzzF0u1mJpIeOVGg9fGMDVA(Q)C1Do2jUR(JfZwC985l(6SzZxDxYR7DxD3E7npz)a8hb27G)3FB7wFVnjEHbVD)OxcFj2Bx80nH7gJEZx9dTDqZ26up)K)wWQ1cN449UBwD3F9B)RF)F8F9)(R2KzC1Dp6544Mnm34nkG2V(29jp6(295)2fBdJCF2n6T7DC3AN6N829)2)83F7E4NH)IEss9Uab(4lEXoYpCZtx4Sp(ce66eFbGjwVeb07u8pm9Fhhgm(Naifzhe7d0Hd83Hii7f)292ooHb)a8hp5(A803U))2oX(xfGrJ(7)T)eMKhts2h)RxCXdEjpMUgrexW8QJH5eqC71Z2oBM7x2U5Rxct7VdpY3l4bykcttCcru0(uF)y4hSdamYjn4b3WaarsJboIVRDuactbYm7T27cZ6g7i3Ir8ORTFYJ)SnWcGbSZoW(T7JC3ec4WRae)hroEb2rVMdhGlA)mcQWBfVZ23)T7ds3TgrAHBbYo8pra5Lh98DritK9A0FKyh9GBcm4hqqponoX2dJwoURt3UnhtW4iaNiVWiVepxeF8Fz7HEn7DGuhAf03hyt5l379cWtYFf(x3bCoYirO9)03(vesbC21i(iWnIPyh7JCJJtremgYBcdsIcbyJKkWZDSRV7g8AC4(9HbUbjtbz6OWTaHT6oBSau809igfcalZ4IwBtbuY)NC8I3diGfWSTw7cO8YlN9tEBxM9Y3oByU8w(7Bz)STNpMv9)Wn1twEXlE((wjHwag)S3ZUOzQycS9HFGmDXjPywI8zjCRfqFwGqwS9tUbYNQI3WQG3iCoH9L27DTSJs8ItKpz7aPPDapSyYgoO4jpAh5u8R(UodrIdtRmRtDcFjqm0JF0ojXnYAtAuSaUIAGGwJa5nexpBcMMUp7jvMwfGpBnpobep(jq(c4TBTEyJZY5iuj7HtFkag(W8)X(nj3Sm2njb2bhpLA4wz)9qo5d1esDrRcXsArYbvq0odbak0AFi6znL1uodDo3rkYvLb9L(IbfzV3ZXkY9b3a3iBT4X1ZOLT3yhyLRFotCLF2uiZcJoWBnG0)FUmtAXpdyF0(y3S5M63Xt6qK9HPp6DZSPxF1pI)h7S)MEqXqqx1eylgkoU2GE3nHE(wG1E3G4CfK6fYensPIALVrMTSHjHp8GpGyf)ECPsyKAflpyvYgSfxdSUbsFhF0kBTR7qKHJaJdW6XHIhV)59wfMNhlvVpiqybJWriYu14dmqKPN8bL5kbrrFX8OYktyQVfOZ4jElmJka9b6DNWG3dotnohifdxLqCe4pe8sB7DUnzgWqSqzyoqhoiBT4Kr4qLbo5(ADffwSSU(AHwea0CpRk38fvYSv8EwX2BDRJAX40D7aBABD9FmnaCZGfqzpFi92bVaWH5Gn5sTWibh9S3bULRsQndmph658IT)tAHtE4eXdJd9dlbeYMYdVQhoE744y5aapvRtJcqcAz740pDXPB2KUonwYCMy7J8i3Xf(hEBSGOstM6gGwuDecV09Qr(GJbW2ebBGkSWK5EMgzSaxxNy6bmCq2epLFUM6(n3nPjk29IOu7ODHCscfGnZT4Y3tPvx8Q0tEbYMScmLE(YmIrbg0eK5xXiPV)bHOLeldBGisTYEaSdfcjbDofljVH1wpxFhEpsjea44M73ssT9RyoktRLsBrRd9Re)tzmU8JkdlwkzKL4aroWn4bWMLtfJwOJHydoMfDA6ZoralNqq)yQJycjdLiwIq2SmeNik7ZTDmCW6W44HdY4zt9ITW)BcsM7GmO67MfuUnNPsh0Exk4qWKsrBMPj3Acnw6fK6Avoudj1cBiztyUzKfx9HHfOImbxQJs3JEQHKdRGdiPf)i3VwoT54q8TZhMDCotlFw2MBIwRYFVKEgLZ1oW)sBSJbd4Jn35are9Mx34x44rSST7DjtaHvGRoW(nkA5g9d90H7T2pm0b8xk6vEvLCo3fzVXZ23cbnRx8cauE4iALNf(YFyKbS9rdkfVdJsSqN5yPV1(U2pdUvtEN8TRWwMX5oBxI5YmErisxaNEY(JgbMH1zcgK5g)BwqGTcD9OCtb68SkobqxF8jYfB4(bbO9qsK02XXEpa26YoXSL)qXC)derArqUkrWBMQbcUe4ap5jFyzja(V9bfsp)8uj9t7tQ8fx7N6lkSyU5PUIN0dug2EhaITErUgsuCBxTdDjgILJCQWImpSqE13uCOCFBPQckZ(3UCXH8OkY9MZoa0A5d(Qof4rpT8QMO1U2g6fjpWBdkYDhSQeFZsXwyEhmpzVBpe99R5h7VboZBeLtIazTDawo3(HWGxZJbjNTu9r44q4hheg9oXdd)ejJ6r7Nd3iEyzpkBCCIAOyUkyiy0snHi8rqWKoVMBGPcZvRr0kZZNEMFNQRl2B)JH5h6xZzC5yl1K1dQL92TleDJ3ThplMjoTkKhurNc5x5d)raHXQSPYC2mvn1KYfjz7JUY(BMp7GafLyjoH(7XXWQekGa(spq8kcIAN93SQ(BlmKfjs4ya7IAw0weDDjrqq9i8ecRYnWDNNlaVsnGyVMfh21Y(kMud5BMXtuXs4fj6ykPbcgRDbBdrpbt7hTWNkXCTM2(4hFy(so15mMPWPRnOlsRhZL65NN3szZRynEFh6dGOlBICrmcyRCYEgCZAKdLualV8ARUCg5ARQ4Aj6gU2ggLDKQdhaKWZOTctNpTa3lNyqopjeLbca6S1Z33nImvvUTm9hklRtrTJNqEa(QFjx2PbSk6ZKva7Jt6oJlHzK(H3w4BtjnbQFbVBgjNHDap29BqZ)nxD1HbJYNJSmrmZFHMOYMiPv9cBNpBwn3KNHNW)xsCjRVuo6QzQU(tQqSddn9wpeb5rJeP0ri3ILLkq3zPM52jOjtHlXenfErMLxqX(JYMh8agp(aRgMmNHemfkDcb)ETGdpyencIDL4mpVYMpdIajBGn3rR6FfHNxk7PLsASQnlOTsVNYtflnj0YojbTTVbNjMrh4CsyWdPUvoVzApCLWqibUaSnKN3P75VxGSjwRt5Kb4(ThTtJrVwDrg639jpCqsSyt5KZKCcC4Bf3ffsnkvslz)TjKHWCbqpSypvBtaf)wEQ93LhQ9S6htSjqxwuVcWkdc2vvWYn406QbbWDeDcOGgfzwnWb(WNmlsmZInsV0xJK0zVmhd1hYPQviSeoz4POs(5SnCtQ5jpGW9M62DP6oQQgD0NWSZrab(5jNCeOdmtEY0ZmLvePgjJY70zgAWriF0ybiC6Ju(4qu4)5llC(8C2QK5wyU3W74mDg3upj)AL1ghPmVHJ(OZ4L(K(IoE5DdhnsY2MEK(oczDtbD9EKRnQJfPoqM2B1sgCNMHnT2S9hJ8RHC(bNZQM3NSQrCaETxu7JbRVd0KrhBE7zB9qg1uGOKSjPZWYt78PPL0Tiz6pkztJbbajkhAQhd6txU00AtUQyi8IdDmDySqXNW8N5ZtKD5lVkYAMUWGTiDBNZzg5Bz(EptzQEaPNZpM2LFmCsvVhzfJ0lQOMW78L5hw5YNk4RNZaM(HtxR0MOEzaJMBl88c4XFbSj59shPztWzu1v54c)b0FCZSfo4)rmFw0SB1eKx4nLB65fBca432sThvyURiig0AcZ3Jmwr0zH1m0UE5PI4yHAgKpwzNshi3AuoPivnOXzIsNxwrN0IIj6KoReIo5DOWHo59OCHo5uQiHQez6Vsd6KtVccQouQbfIrZH8XT4FoPVl5Nt6Xc95KpqL3tz4AdKLowitxxTgnSuEo5iuapN0xLTZjNUfRZ3NfDEZlDxH5Cs)uooN0NfHZj9AP3CsxuWnNCekZMt6)IR5K3HsQ5KoOqAo5KQ8zorwrZeh9IjNYIQsL5e1x2jrLsr1YK)kgaXhBqQWlb3XnOMx0K5L4Ul2GPLJ3dIArPI8iNhJ4(fl6zGEM3z)VdJSqQBK6PRsmt86qmWoGyo2L6N4vegC2jZ4h(G3gTZk994HE5rzZX0eVDUO4aD8CVv4v(LM5pzrYaKNSa3oFmplXyQih)rN3ib7Ro)lN3KPVc3rXSFRMzN)B(aFHUJeEovhgLR9c0fhbUK7yrFyPv0IHAPl(zUNdHnoAqXzTK9(pN6J8EFTNpQ5LatSQhxKPpfhAn7b0orWVdOmaFl0s(4XJ1SaYZdM)DhpqSu2MWqFK2tSXSrSYThkWg(7uF4ivx4(ibBj)5RgFHQDLJVzU6BXFGOrNUhOCv4PSbPMBv62jMXmqa3pNsB461T8mibOuPZSvViBzOJm)mhrF1pxoB4wVhEmXkxM72RNPc0LwjkMrAOKFLKiporNLRfcyJ26do)n66F(6FCZJ2ypHZb1f5iE5DOnz20zZhF7YfuhHpt(Vrw4PEaAf8qlHJOemHvgl7za0AMKztrXsGv(DNKbQInS0pjpTCLmea1RZ(ArKcjvmNFLyfnAnzl5GPv8UfxnszUhu98P5fufDHimrZt(9ALx9Y2vzoQvZy5efIOjBmhQqrvEkQCJi9vHXjuxMGg3Zwk(tasXhdNbFBpJgmAKbVg314r)jabB4ic2I)aAYKW7IpfhHWI8bTObog8jXGnRz8sYezF3snzrPkxaTWWsNv46AO16S2zik9bDHH8Xw1KfLsm7yUGCm3mzaPB6II4qNwQ5ZbsPdTYSWR0TGrkmZoO0qEvlTit5QSpZ734nk9QESaC0mpEQ61WnxPLdprrce3mURmKRr4MzF52Je6TPa2(TcskIIdyipbSOIsF5LJpKphHPjXEoUxjqps7LznBPva1mFHE0r5cS01QMdmXF0eMVc9lgbfjFSvLHZtL(ikLeQKNjfIcAouGHYD1Fqg7S8NROVHk93ou93Yd0aOxAjmsK(lL9bnOjIE5QKuoqvXt816N2(AJ3x(PeWgh0TqCqJKh1PWGoBWNNaEuKJjGsePs8wvfYgtws5gaIo4wme8LBw97ZSisWgI(dKpPhkTKv9P5rLQeIkN4rsM4ITw)SuaJLUgFZYrcPOIXpz(uC4SJ5fUPWXHJKJIvphLBKHW5pFIsSbJhvpxgYPZr(AEkTV0yMAfq8ZTeLVrggkIAgT4hL(6NouKkSuivD5hcQsbww8FeC(fgE3vLgxMOUiVC8nXm)QZ2yoBJr(2SZ2yeCGYNW2zeGL6S1iAiNouMomvNnNtCQtdM2X2E8PVZRMARrL5KflASHHrfNa)8Vol)lPm)c5w8lJ5VrU6ELCRU7z3OyaVw9hlMT465ZxaGz(Q7q31B8Q)C1De(e8p(J5OFj)USx9FU6okl1OhExgjcVc2xbyWrEjUrEWFPKT2CB4TjorfgXB6IfNvCLMXBID8U0qElSK3ct5n0wERmMRw51r0C(jJ98okOrDm2U1SGQWg7W4gpUeLUih7WqhpYewFe84QeWqLHwHk9C492sKUWjpBk6SPOZMIAFSL6yUDRcoDrx2XHxECjoD4QwttN8eyFfJjYe1LmMOkmj5Nh4v3yqsxiNn12rVgZjWEswDhtBkquWLf8mQCoJMTvabfLsJmtnmjQTSS8JKZSCLcer(CuGCLvb)AIBV)1L)H0yjtdjqKmSO(qaWyU6tbZarWFrYACPtr1KSyfPQrT6N3Fmh8UwEh4euygRDLzer9xXq9hlkn3r1JCxjO(SiXId0zeesfgWiVUvHN086dzZlqK1PcrY0sdqe8)HHem)PcEQtS6A0biQ)RY0AG8gbzzLobjR52kr1122MIMvigJleLik9x0rP0PNzFsP1ijrBo1oFMoYTirs7ts1G0yTfKOmxUOBjc1K6AyRraJoYCYQ8t7OTit5wCPFvh6(SouXpL52FJ9GqKScVDVcF(BxNtO(MerKmRttYu(xjiToGl0Gd2bTrPbNdNKHrxSTuvZFBBlvOj9ub8kdRdDe)oONOVNwjAMosw35ikLkpPYoGjk4CrBHEDwpYkW5IQ3F3HWhN(Uqn7(ayEGm)YAipqKGpPhmCSAcdnHpi1RnvHXChxpzaDei1JJjsQza7Q9jttzqU1p8X)i1zWMAzxfZHxuPRPjfcmlmnjpkRNjFKcPJPXnGPytVqXp2bWMlmW9n(IzbY8CTnolisLzHKzXZADVD4dVdglKDSJIURGIPPD1zBdAObuS)3No(aM1iZf2Ykpx3ZCip4dqtGGT2SxV2abMfZ6EBLIKh6uqMzMePb6bmV3qGXmzoXIRIWDakuNAGphJwGk3dNwLb)Auh8XSBz(lJFXoGD3UMqWN7faZAeb1PvsGxsL56FZVr1ZlS95clB1Gs9Y7LYIjPJuqIHHPbdq1qkQhKXqr2b)wEdgznEbrtTjvP(IOOmR7uGrjPhLBXik7LenfROF3oQHvCqfDH1ZFPm3n1OuWecsy(wGbQmh5uFY(MatE1fuQgO6Rfy0q2z5PokEtqdzXPla9mj8CvX3JPePohP(ujRbPys7VaJkYCCqBOJ1az4JUZSifnmYnmD0qRLMqfk6sgiq)LARjxxJZyfojRa7F2Pawli5Q4Qj1y7jeaxPawR8apyRz1yhpK5kz1oUHictyN3aV8OAodR2jo0pXSDKd8QGeiuPxAOFQBDN6aHlk0xw2InKJlQbzD6GhiKX0eAHQIrtJA67qbTV3EGqtwvImrYIeVlrQw1flmJfKWNBiQgMhPjCuFMNxB7iiiKLv)hd)7lhl(hfJirqAyWGwxptO)Mg2EqKJj8daJnYYycQw3He8XOo(H4I8igYSkvz5dx15idgSY07kQdlupb3JtFjbteSQ2fiABkD1xTSemEYQ2xXASo8S7Wm(dTVs7mbJ4sVK8mFNGb6Oe5AAFobdCP(cx05sKBOSSbOyChqbdswf7QwOeEw1D4Ydzgu1CuWyTgn8VpIxyhgLPKNY90RUYy3tv0svWqtMsCLNVDZ61ky4jnV2yA(kYGBTBclyOktZnxxzXqWQV7SGbR0ZxG0Uw0aVSG04BBl4zxQJXv7JlAar9B2kyGlvlxLg8s)aBzk547wlMk92SoadgzKfYpv3vrhwKfjct3ybp5YIdVSvVOBUjF9hTUNXiPPXGdivAkHW0Ye49Xua2toF0dc6ImzLJdluRxy1DzFVuj14SzfNOgeTX15ZAZ0mLG0tAucr8uYQMs2us3SzuthC)sLgvdgOMM1QCDYg90J(VJMY3xHmd1kUMQfngQYunrNEd04sF08BWicREQsqwDge1EBQh)iNtqQjRyWZQzsg4f1)Bme8IRuWyOZQ6IIFl8SXp0FDnMJFBJHZR)StmfxBCrNjyIGd68mdIWGWF7yFHvNofdID)JYpVxDFuX8B)BDJ2rvN2PUToKuHTAhd3GwwYQqCuPF5UKiCQWLhiyLTGR1qHH(PP9GjUA9DM3PDZhm4znJs3qFqFy7nRn2ilzQpiTL(00gMJYelSzn1hfD1NMILLGJTwF3r91N6U7KKR)YASpLcIsZEOkEn8f13pS07ER6KO(qOyVKzZBdpIUAzZ6qq6(wYWOTSi7eTh2CK2WZM4lYcLt1zHyI(HHQ0KQRRcTQAnIy15lW88fyE(cmpwxa35lWul0mLrKC(cmpFbMyCUv3pY5lWSny25lW88fy2JIxyhgpFbMNVaZZxG55lWm58fyQ7cmzl9JjcUktgZVMC(pj6VOmffzszvRlUcJa56mOqhdkjxDvNk(O2Dv7)wIRQdBrwzfRDljVB9P4URrfFCww0(bqrv(ZA3sY7sxk(iVrYaIx7ssI8R(Ug9MfPfIln1k962wyfT1Mcy1SVVwI)mFwr0xVmRiRaWv5MJe38xPe1P(SWQCn26HZ7v3FTgT)vf9)vkdW0Fpzu8GeP5br)ikAYnSP(E5AEB1(y2xTRtJ1wZoSMXdnV3z3OTKI2AzM5dZ3cZ)EuDpa2gJbQdBZ3ITZKWLwAYv5)lj8KUUkKl2Py6Sh5Crk)7VIuETibwPRAuMUfSPcR5SWlQoUqKP1gSSZrP(kw6x(wU6Mt(YBEI5xt65cx(jpX2KcxET2riabBDyzvWwZRHA6odhATgYtq3UMMRreIDgDx9GsOPBUlHU)iCdcOTZi4YJGOcXEUSMVP2PIMc7cCxHETqwrcp822EVkH5A9Z4Cbox04ojlW5Djl))VDoJsHbHbcIEw6F9Ku8ui9NckvqW0V7zVKyjL6UBcXDfJYCdItMSmBCZRULCf1ot0RoziiulOC3XLYA)sxifDkkSA1xNiopki)4z(FQHQ0DCNnQEyNNtrSee6RSpsox2LLUJJks0lsjsjeuZJ1R)SwiP0aao6N0MK)AvyFLvKbrsRthuqV8Wjat6rZcWK(iWKoWKUuj7ndMZb5gysF)2akJM2at6N0nw3I3FpWKE8hFamPhsZdmPljImbTCat6k(uaM0T7GX(Gj9xHYYD(x8rZJN9d9VVF92ONMqtZZbw7Np]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261128001,
    [[Hekili:S3vwZnoos6Fl(f1sR6rw2vPA7TdlhXS7(YmBVZmX4oI(nrtlbzZXuKk4HD5nC4F7BcqsqqIeh8qYYU4dZ0U4rEHejYmb4NwDXQFF1nBCtiR(Bxo)YVDXfx(lZNFXQBsEzpz1n7Dx)O79WFe4Ud())Vj7cdc9dV)L3UD8ZHph7TlE26WDtOp5l(HUBOu7Uup)K)sWQ7qjC8EY6v38h)5)5V93)V(F(1nCkU6Mh82SHK9AK41A42V(2TjpqE728RD(2WiYtKO3UDdzRBQFYB3(N)h)2B3cx(TBRqKuVZPSp(8NDJ8dx)45B2hFovC3eFovsC26frCUlYnyZm2LN9VIddM8Za)GRf7dAZg4VdP83l(TBD3Sjm4NG)4rYlXZaM5M4(RiY14)3)YVde5HKK9X)65NFVxYdP3rvLZR9OtaAcIV7DZ3oFo5RBx)lFbi7Vb3Y3l4EGeHPjBcP61(uF)y4cGOc6DAW9KWaqqsJb7IpXnkGkPGYM9u7javx7grkEJhiU(jp8NCbdb8c7CdCF72iY6qqgEb44FpAJxGB0l58bSLUpr5k8uX7C99F72G0D3rvTWTGAh(7uM88dE(eQWe5Eh9psCJUNKaV89uUhNgN46XeRnK7s3UnxsyYiWNiVWiVepc1o(pD9OpM7oW3Joo67dMP8b99EbmI8hH)XnGLJ)MuX(F47(cvOal7Du7iynIfmh7JiXXPufMX51HbjrHaVddYPDmXNSMnghUFFyajizg4zhfUfuSv34UoXdmYZ2tnuugSmZk6Snfej)FEJx8EqaCaJTZDeqKx(L5)S32Lzp81ZhL71L)8oUp565Zmv)vjspD55p7577Ke6as8tEprOuQGaU(Wf4KlojLzsutLWToG(5aozXUpscutQINWPW2Gsty2P7EIJBuIxCIAITd8M2b2WcIn6SI78GB0MIR6t2mI6omRcvNTj85aCUh)GBscjYzDAumIvrptOJrG)g1QNrGzP7ZUtfYQH9zJ5XjG7Xpd(xGTDRZ9R3S8cQOKDZzpgaV(O8)X(1jxTmMKKaZGJNj86oz)9ij)d9kstfRc3srxYZQiO9MaaAOZ(q69ARPPKc9U1rPWv1a91dLbkYDV3gNiY9KasKRr54BZf9Tx7g4KhFoZDvMAA8zH3oW7oqO))i1iAXLbPpAFmjJ2cxNr0r01hM9G3vZN9Tf)BS)Xo3VBMv1uOfTH34CzdXfI7Uo0Z3bwZNeeNhG0Stg2BQ0vR8jYwlBus4937dcwX1JldctdR44bJsUWAXnqQBH33XxSYg76pbz0yyXby841IBV)P9oflpprzCFWHWbEJnOct1fFGxKU0t(lLLkbpqFbD0TktyQVdeZ4r5vygxW6xfNDcV8EizQj5mP4115ehb5dbp02dU1MtbghlcgMZ0rNLnwCY4COBbo15ATqqkw20CTOdcGyUVEi38bvo1kEoNy3TKMewmoDhuhIZwI)dPbqAg1zu29hjoDWlasyoyDUxl8MqIEU7G0Y151MXMNc928SR)Jg5tE5eXJIHsKkzeDnL7FXmF82jzXYzaJu3LgfqD0YMXzMCXPRxNExAScAM46tZiNvYO3AhO20KzKa6G6gu(LUxVWhCmy26iycuXkmzPNzWhlGq2el(cJolJWZKP1mY3jRtt0m7LQPUr7cL8ekyBwAXLpN2vDzJsp6fOIyfsQi9YwetGnucKLxXyLp)ROILIvgwdvK6KDdygkuscTBfl5pbuvpXFJCgPCfasCJ89Kux)klhLf1sZQd0MfqPtUoWV2SeVDeNyW)ICT89ICHI5DOpsz4pEPXOmZdCiPTEGLzqwTZZkUgT8fBitMnyz(AF3f6NGBb4eJeCpSI5MklzsBcY6QS0uG7m(YxSJAhSKX81tYxEA0z3fghp6SSHLzEXoS)nxsYZbhIUE1LczMNTQbSarPVjxskN9uJm5lyjkLEbPeNYx1svTyzQmcMVs1Ll(Wyc0PM35hgUbwFn6f5Pwsjde5U2Z1hIveN48Sxa4nnAS4KTIC)EDSf2LXNvkRHrjo0EuvMlMpbMHnPu)ZT9G(pjp5SsjxvWoUssaz6r3pAkyMuNfJLtB21CGcHqxQIRXS(Fu0XiIpRdoXw6WIi2J4vE5gh7DpeDkRdll)PcA)tJYJPHY5QkH9XB4edUZJ(GTpa(Fhc1qK(YQI4D7SQ8mX9XdLAuqBzvO4oTv8zXAa6uSCPfsU0Sl3qIMYu4SkM4gXAZJBTuuuZk(CuygeK(qrPkvZ(lBhbks)l3av9MrKDatJV6Yzl4HzffhHaTJZ1KxXEmAaKLZN0c7CLCsSqZZvI1E7YAFeSS(zsPROrQ5pthezwEf0mPTuMLCmkJ9vgUvyDWRxE5R5JL55WaJvoB9H8dNbs3Jlx0gXEDyuu6E6DTuSXMjwmnJtlUlurcLc3IAIlldO86QhEQ9YTB8XD3EOI3xYB1UfjqBLMZZ6)o3aweg37ddEjpV)CZs1BXY9x(9Gsx3H)AS7O4TEW9PW14Vw2TYEpjxnADofgeMyPxrqVfua3MxYxKUIX1yIivOZNEJFZDvflsQLMM6LwvF(i)gvMnYVQ65IvEX2ntSHQh2aVpDxKV6I5VIehHnGGMsPKvHLfWXv5fI3U(fi93CXlgIcTZ97ovV2LwAIW8a4Z5tIGQ9Oc0teAZW25racxgjGLb(O87VjmrWuU8cKi7vSzTm8TLgi7uEeDxZyFpRjTWd4oceJm6rGSF0kfRuYngI)JFTM5d5cDzklYsFVWgI7Brhsq8I)SUKh2MwWBOVUOBf3ZIDO5mn21YT)4lZ5B)rL0LO7uY2WOS(Mn6mqfEI6wp7IzfYEjHbF2Kq6ozdIZwpFFseNuv21fZDEJTJA9MnHFd2wiY30mlmvInEdX8X1U8t3vUvIzi9dVUiRJsDccLgN0f)KQBB3fZN3WPBzdlW)jjU0Wv6fSyUUnbtOOVWqB7(mgNhJmmo(SXfXEelMoBRh0wmFbXQu))KxzkY(10rQRwS4vKWFLbx7M)1yvbnh1Z6e)YptRbMEssym7v02zi0J)QuzI2er6qdyehIpBSOSYYQyyqVv6uFnOpb)o6fPdvJUA8Myn4J9XWhtYHrq07I)sNwWrBdYstcDCtsCx)yBApMvD9pjm4(usLM(lMKVcdcV2nWSrl(aS7sBZsgHnwxc)fiF)b30y6J1uHr8zF0JvNyDPPK41oBasYBLuPr1g9RrHh(Wg1aDZWnZR6n42gwjhyqikqz)TN382cyd3vv4pIuzr9(66xGwRN3(hcLZNVbkGafuQbTQ40gidYLwAxvQ2v3yBYgZgHVOAg0G1Ty)XmfKbD3RAIGkVDwMNy2QGa1TmwUuH0QqO8cLymsu5S7SnCDASTRY0YZWt1IQ)eEYDquWppNxhEeSpFNsNpp9lLtB0ZMJCMGINiNSqaDz3ookNmhjLis884CavIOE(C5iPi8tJZbuj6RtLtHWFWoloOPC0mddFgzhZ04yFsCKZGPfRoFmpho6loPjUcIPVw6w3RN(gKAzAMB1hJZEdVHcdN4M3NtCdEfFD3v7JHP3w3t(XqP7gMtNtBthvoSb9pkN1gKOR2CcBAMb6J7jTPZl(GO5NqNZgEmVpFNUMpp1iMp8Q5m10hlDH4O(P)e1uy3(r)C0uTpy)yF6zK8jEpoZmkBzCd53WgA3oDIF5oUH2gAps7hyho7c9Lo1xd1VFNpgd7O1GN1hEpR(4uX0tlPG0WQ(6eWiVBhh3Z9Ie))iEAxmemWgHhDZITT5X2Wa5j3cZKrpzliLH3qE(ECEw4wQJ8PybVCW2X5J1zxXu(r2iYh2tSI8U80sXtE7E61PVwD6uuUAG1NjLEh6tN2bapDAVbZPtFha30SX7JmKMo9ucit1kmho4lD6PhOLAsKAbyrApNpUau60dnSKo9acgPt)abbPQK1w4lDSeM(grjTeUrlx595dgiJwKcrVdTOtpDbu03NbD5Lx6pWdD6HbYqPohhmGcTK4hc4bTK6DauqljYHdkqfe0dfaGo9Da2pN2dG950tki(CQkG9Kv9InnBshCEcuNsbVeYUy10sgsnlSrGlrukwMZsV6iPR4isbrkVZ9Ffg5qdlOmJuTsgU9kg8tGAd2L6N4vu1EwJK8dV3BTrQ(aevveRtlpPgxV8lfHJlQhkRbR1EegpNbrtI92qep0FyStChGf3f7CQWaxvOkXnEKRr3Z40SSn1ZevNt1XJptrdAXBCRWHnDI5tBQSTzYR1nogSoAhIZhC3eMuo0wLLlVOnKVIRJgQFDRO(6WqF6u)4SbGCJO8rey0yDNFGXJLDq(tlMCUoFKjxDH(dLWzyVD6(jtM8QobvXB9Q65gp7L8GxWIjMg(nmxScXmmda74kp2oFuSZSmY0t(gQu5ikpv6QcyI8eDN9zd2MYCmzQc6SXkNuuP9B7AzLaHNLPMw9qnOKFQsBCS42E9LfJ26D)djo5HuU(BZ1X7YftkOOYWBMIVROBJAE2I2(xEGgQ20rzXfRz)1krJF9gDaYvzBTx0Ayc6y59BZWtzCgPTE818tTYvipa9uRi0OCdRLVe)BfQ(z6uybpl(iGGycJT4XK2IkXVviE0pXT4QYhHtwKZ(4Z5bLx8Vxgd8XIV4gA8)rNP2KeeY(JFAI9JBtv9bs1MrUQMk6OxDJrLHgdgKMmaBPi9zE0J)vH1MrUsX)yoQDmNwAHQ3RJC4zUUu5rLvBkMQYgCu9BKTDPqsrvZL6QfgLSPcFgcA8GgJ97aH6cKk)GckkoYU880LWLAfqZhtaMkiSl6AvcXnVVHQH0m53nhcZfXMVv7fvOyu0NI)HR0vpeTd9Qff8VuI(ySwWsWlyCjKCOxmK9e1Wr2)aevlY13zF4ZKi5wNOV6rL3tFzNyEafnf4Ifn)iVNxCPAPrDjPigOPQ)cio6wJF5OAmqs4x6iM7fS2DV7AVe2VRVOwpDWNWr3cEK9N6ltOMVUObtOvMW6LZFSv)A5XS8cTRoik5vA3rBhT1PrxEzBhAgpUOS7l)288VjJ8EX81VmrUzmnTBmRU5jWZhKRA)aOtB8zm93jDUDc(h)n2Vd757V0Q)Zv3imvHEZ8F8PxDJMv8akg5LqI8CxDJotD7Nz1jFlnZTA3i4QeWYAPzlBvW3zlKHva7DduJJ(qTOFXslA5kJVZw1JUFxRmRF1wZkF1YbZQfM1f1mRfMrXvmRyiBSk1v7HnRDs1KVPqtkwqXETOllL2YHUd7APG5jz1n1GupSfn5J(Lnqx0SvWbtGXt9V(bfBzb26pfsqjIT1qb49hd5gjkL1appSfiWWmpWWS4tHXOrHUrxrS9inq7HAGMG1a1GzpSGQ2Nu1PUYAc890figTd6n0Hgdku6Ap8ROmYrO(3nPoInP)qQonyRcmOs)IjvQyldoKQJfByHb14)qHAicsFnud0bwFuwEX8gMVKf8KpDUJFVvTb3(AXxonZmOmXHIdDsdTb5QtJXWVMcIFmHxvohLNnJgk9Tbx)mDUm0Pa1ZGGp)L31)gQaytClMv23y8xJXBjMkBBoevGOUEWkivOGis90wO6PTy1JoW6PRG)xBq)p2iJQkiRqOFKgj04fRk1OIDpShmt5cwpclGneC8ykQQKMAPII5oWHiWJfgb2g7GYmTeJulUh)SGzsqgiTo5MzXWCnobWmq1b)zMlvz016f2qScA8j6BDsJNXL1tKSz9Z8uVoXA4kitJTDhA(yxvCUZG0zuLzcuL5zxwReXfVTip4hJvrVuv6VyD6TGmDd0JSaU9eSXVp4riZ0upn5ctt5x2A)BC434KgIczMN65Qw5dOLwD)C78MSy6O94witYuLzidHr6br4OGcz1HHmuCi7tdqKH)bTPbjYyd0QYmUhAG0jao0n4bCar5Ww2SUlvves73LVbpUpoECYUpwd)HmVhv1K1tRmX2ruBlgsaSeBgNzCrvtRl3wOmqbeJ02aDyfvrAhYjYejvfeWFJsCoSTsL4Z2tGP4R60l2YCFrvo6gI5yJcHEedymvv2V6BSVn8uoOIqaebmxKjgQ6iQ(UyyJyOQpfiINnTNqx)nyAIYSslbuXoQk2anJmrrvEtglDUbcJCDV2vdTL10Y0dLlgBi)pBuJdbcoYeALRbOB7(AIelV)Fu((vL72A3JIObNhzSw9rJsXYEMG(XvSdHfKsHBki1ih(kjuvITWiNXvGGjTDhRoQlXwgxH6udZiXumuSJK5wOJMHvXssZeUoMsYgfuWHkObPzs3zSMKklkpPKIGePAzrplBcgusfM6bMvLWKaMhjkAMXyVUJoLuXSEq7A9BH6ExkuDchgTZeKiF2x09AECyKS5gpVUIPLuHTEC3A2VVESSFcgIeKdbtnX6BZrto3saUuTKi)cmPrzA9LGpPc5XkmRehrlyCUEq162Hf9UWWyRQ4UyyeyZCCpoiRjtjQhAhX12w96qb6Mm50qlJfhJnjN9NKXXJtCa5Kj4Q7Omhzn1kCTfPozmxzxolWEt1luwcHNwJHNmwwpWUUbk0DdPhhE4uqh8EYKAdr4FFCVyjmQkiVq6PlwyD6PAafug3ufex7UW0o0cLXpLNbWAWhQk(2yyeLXvLDfPoUIAjBnJVOm2QSViCah1a)YQOvg4rzuxzIXvrIudSO5WfkJ5kJYvbIspm8w5jdxcVrT17TDyyktyu1xbb8b1Kuu2bab8eLrCv1)xcwPMOn)dhPZOEQcypLvqQQ(fuh3eLZXer65nt(veCqn7Zq2HI)IRUj77PkbPfZQsLLdDQyCUYN1MulIvrsrmrvlvhjDLk4PkJP2(rSkb4QM1N6bJ098Agafm)gqxkgxvfKQapifLd69oay0ktoQhVQKR5eO9WZAPsj(cG3jfhzODakbPnQL8xdYTIVRtDh6wTbVKecPxPdPv0Q6b)unwIHERnZjl39Idzpm2xp8OsxP2ZECWIIYDPMKkoKMpQG8XOA6tGv2DSZGbRo0GTXF0Tu0qRL4bRLM8s4Lirt)GTmasfPcp2WxRhPVYCtRM)C6GRS1k5lZcLpN9cM2AUlgvSaObyQ(PlCSGJwM4RkNA0p38EfNAzSVPF3(4ECg6rGQ9xPkruwRp6UUApUYITxR16cc)6n7BRIj2QsygBa0EH2Y6p)QQmQ1vVRnohLbGLoJkVAeMCxvfNawnSjvdBs1WMuDS2KLHnPYi3S1qKmSjvdBsftM7upWh2KQUizdBs1WMuDaDVyjmoSjvdBs1WMunSjvjdBsLPnPQo8)LO5lIa9C9MRScThK2wTyW7LCT89kBDOC3ky8wvWnmiIadl(XOAI5ndsdQhQcGYKWNb(EpiiIwGcz91Vdqh1FXror(TKzLM2dHk8DEC7D7xbO(7NbOtOXoLqwvD625XT3LFdGoYtjTq57NXTe1B8jsG0Yrh97U4r4N9LspSAFGqI7BSMnCR))1FbBfUkBITzHPl)6VimLt4ZqtqasuUjZh1rAkXEs8x8PwnsIKmHvrv664ExoOd6IsQfUO0QiDWNXALjZ7rjQsRlTvUDOvaiD9(fLTHLIBZ8a(spGV084hd4l9PUY2g8LUrESy4IxxtaSI0Qkcf6RwDrm1NnV(wXAqcNnt5QwbMOYP(i613kNf5a3mLQS0erf6ua9PBe15tR74xf(XcNPlxCx5b)uABvBKbjx3o8GonwF1ets5ZhIu3iHfB2TCwPVxOpTP6MgWMA037KeBQ)XXKBYzwtT0sBkFNTA1Rw(4Jj1g69I0rbOrQmMFYjp6uBYI0NixnwdkSWUI5kXdL8HbdRBKkJOXA8s6B53OVIQLahqZ6pP1GN7QiDwYzMa1Tp3cXeXt)tmSvBZ6Ud4ADXTgW1Awi9bCT2SimGXSTwT4xURymlBGEaxR)b2dyaxRh84SsT6rpUbCTEaxRlE23nCT()FeBzoeJhcRR8bWw6ONR1i3tqcpmg4BCqa7tg9CTMO6Knr2PxW(JrpxRXMlgZPyeK9o87CTUeW1HLbOTVHhPMDM5KzDjOHB5dS7)PweKvhwCao]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261128001,
    [[Hekili:S31wZToUr6Fl(fnsRMil7ZrNDYuwUQS7(s2D2KuXtvZBIgwcYMXuKQ4f7J3sL)TVnajbajUqaskjBD0dzIpIK9n0Or3na)4IRw87lUBfkfV4VD90R)2vxD9VmD6vlUl9TT4f3TfT8z0JWFeI2a)3)lCsAC2Yu)OW3VF4RrVM4VjzYYOnJi36BbrOveY9qMFq6FnCXdkPCYw8Yf39h)L)5V93)p)F(1vCsU4UN8xTcN)C4KLM43V((9PpHF)(IF7Y1rX4xWXVF)k8Auwq673)x(h)273d)873xLkz(xsKGKlFffheT85lxTn5sIeVk5sQWenH(VM8VsIch9ZaFIrHjbGESc(7icF9tE)E0QvrH)e8hpJFlzcWeuk6xvipd)F)R)oqKNst3M8RxE5J(PpL9arfUS2TocOji2OhMUE6u8xxV8x(cq2FdUuGF4JajIYsxfr0NTzbbjWpGcbjAvw4J4OqqqYsa7ragfhsKuqhZVRTyGQlrX4YN4jmki9P)ec0F4b2GcrVFFmEzeidVbC8VhVYpef)wbFaBi6fcxH7kzdki497dZ28ar1IwdQD0VtyYRp5hGjctm6bYFKIIFeNcp8JeUNKLKI8PI1k8dzRxxijuze4tSFuSFQpMyh)NiFYTH2aUDKXVGaWmvmyV1pKsK)i6pUdSCSNKi2)Ja0BeHcSSpqSJG1irWCSngNKKruykNxgfcd0aVjUeuANGdWlPJXrB3gfIdtNa(0XrRbfBXDiQ3tYKTedfHbZZTIERZark4Nx5NSfeapWy79age55Fz6p7VEE(nF70bfoBf3Vh6fKFa1u9Flr6XZV8v)GaV0ipqIFX)fmHsLeafa)aJCjPzutIEQeT2d0ppWjlb9moupPkVdVsBJsActlrBXEO4u)Ku9eBd4nTbSHLeBWfLx5ju8QYFnaVAaXDysfQozv0RHQ5EYtO0uCS3YS4efwfZmHmgb(BeREobMKTn)kviRb2NpMNKcUh)m4Fb221EpUC18RiIs(fN8Ci84dk(hBxMEZ8eCAkmdozIWJ7L)3dK8pmRiUkwLULIUKxurq7nba0qVTrKR1wtdNc9U1rRWv1a919LbkgT1FLxm(rCiog1OC8TPI(2lrHEfXNZDxLPMbFw4Pd9Fae6)pCnIw(ZG0hVnbNtBHFNs0bK1hM8K)ntN8Tz)B0)Xg03BMv1uOzTH3Q5YkmcI7UmYpWdwRhhMueGSzNmvpPwxn(DKVw2G0OhFmaeSYFpHheMewXZhgLqWAXoi1TW77Wlw5JD9NGmyiS4amESR8YBFzRx5YZJ0g3hCi8GNyLsHP6IpWdsw6P4HYtLGfOVKoMwLjklWdIz8S8kmdlz9oXzNWdVfsMAubtkFCtoXXq(qWnTEVBTzuGYXYGHfmDWf5JfFyComTaN(CTMjifZDnxlYGaiMBRhYTyqLrTY7ZlbTg7syXKSnBG10wJdEklesZOoJYV(aXPd(HqcZHll8AHNes0dTbsl3KxBoBEjYF1ROGNBKpfLtKmijkiIZiYAkp(wZ8XFJKfRGbus9qwCiXrlFgxZKljB5YShYs0qZuuajJ8vy4F4V0dklnDcoKmOUsj)Y2Aw4dpemBzmmbQCfM80ZAWhleJxLi(adUiNWtKP1e83XlZsnm7LOPO4nrsEcLSnpTy(9zCvx6O0Z(H6iwPKksV8fXeydHa55vmu79VtPyPzLHLqfPE5xaMHcLKqAuXC2D4T2hhSsoJuMcajUH)EAgkOYYr5rTmS6WA)y6GzHoW(TjP(BWEjG)f(w5RfJGI59i3cp8hR0yLmZhCijTEGMzqETZtk)ns5l2qMCBW8I1(EikivTfGrmC4JWkMRQSKjPjilRYYMcCNZx2IDe7GLmMTEsXYtdU4HOKKbxKpSmXpXJ(Vzssro4q01BUwiZ88vnGfi4(MmjHp7PgzkwWsuk9dZWE8h1svTCzQCcwSs11Z(0ycmPMpeefTcwFn(n5PwsjdeJw6JcGyfjPEV6hcEtdgkozRm3VDdTWUm8cUSgfN6r6rfpxSammdBex)lS9G(pQi5mUKRlyhtjXGm9m6ZMcMl15Xyz0M(BEqHqkxQIPX0(Fu2XiCaTdojw6WQqShWQ8cLK4)ieDkVdlZ)PsA)tdkIPPKZvvc7J3WigCLNdaBFi8)2hQHi9LvfXR2zv5vm659LAusBzvO8kTv8PXAa6uUCPfsU0Slue2qzk8qsOqQi)e6LOL1M0gbEvXfZv0T(VvMqjHlFc5GlgsemOCNvrPtQij3ovvIl8X3OW1bOhJlwI3cXAyr2PfRlJcHOzbqoptGbJNNpB3WI48SSeYZbREUdX4nWytYnZ)YiEyjbnvzag3DaeZFXcLtRuwxPiXAzlPX(v(cAxyPobHBl6gHkomFAB058rgsncwQ1sEvCbCGGEWwH)25xVZSxqBe7LrXXzBjx1sXw1eKYaimAjnekCPkdIc)oFyS(OtThUDJpOnBHA5FRyteSO0aR0Cw9mLt)rpgf(wrfnfMLQxIwvJ8ZbfLVr9JrVIMNIgSr9JLFP8NtoagubxPbHkwMveLxcknD1BfPFuX42ykwvOZjVX3DxvH5KlFdwRPiYqc4PUb9DVQ)21DWaY8lsJHADkwmdhI34JbcxF5oHf74s48Rum7NM3qhNIBPbYoLxHURiz62PjbK9Q)MRMUROKn9bTAwPBHZYdyykx8ZKdlWNSAw4sEJrm(8xuwXqUq7yksrJLot4sF6g7vK72(jxdZjq0g3VwelxXSXY2DOys5PAuEv7abR78McwxEnl2ULlmyx57LXxMY2lJkziq22J1rX5nbBWfGk8czQ3KRMuk7CcdZRsJiBlnioR9dcWXmsvzluAUnA0ThR3SjSlq3pq2oGzHPsSlAkmFmTR4OAvyLOgYGOBlt8LRtq4EiX3H6ny7Op72Le6FZSz7UiFPfiV)PTQkmMdw1nV7QPtDCEAU4b)FPjClo39z2utBfMqqROiB7bTkoRQ2UHI2O62pfbM5H97MxLZrZzK6vsmxYH6G(uJmMMdNiDWSXRjMWAAglNKgsff1ZF02NEL77FY5bbXbbrI2LrHof7WyFbYsJ8qPPOLp3MUcyvBCtJcFmdxPlUIjJQXGWkhbmBKKKZ2k338Cc3y(ZSha)9NqzjKBZvHr8EF2Nw6tDPHt8AB2RK8wjDkLAJXaJAMuAJAOC3nBMx1Z12gwjpJvy6jVTEtBrNITG9U2FwlijlhP6nSnVkzf6R(E16E592iG6kGxHOzrX4MQ73OlJ)2NIKtK1bfqGcA1GwvvMdYGCnv2vEMDfm5EEp2i6LoOoUgqhIN0AowBbnL8sjXOKOY56yD0YSeBxWQLNVJQ1ODcEQouOGNoNLdwCHtVtWXPtlcz0w552qoPsXtRrEiGUSxahKtTHKselEwn2JkrCpFMnKue2j1ypQe91j2Ou43BNtJ6PH8r(0z0qM2Fsptgsz67MB5NWtKH561CXL(aComuuPJBdqFoofgSESC(SxCCo7fQRhS7UAFom926E645TO7MpMpXh6ZDrNdsPqZ)CEQlytJo9oRfNoLpvm8A)Uy0N5o0XZvrFeNwXSTt(tvrPD7h9Zsr1MxD(eu0QtqHKZ0X4CtOTbXoYVtZ9xwrbUNpJe2B(6LZirdBAYztVLM(2CYi6POdkQqVVofeYTP(WE2hK4)NXt8qdtXSr4vUlF2MXRnmqEwNWumLNUHg60Qfm1q)nDJq7NtYGIcMDuSogNFbMRWb(ulOUMN2X5d1zvWCwh2iWwDEb6H5)oYN2EAe6DarCChGbXX9g4ho(ia5HJpgaD44psWBOrHz)bQHJ)4bLHnjsTac5SNZhwylC8(gSchVhHOWXFIaMqDYAl8LouctFJZCwccHJpaqp449fGdo(JlmdECg0LxEP)GuWX7hGeC8(e(ahVxbnWX9bubo(aaqGJ3)Wc44JayaoUhGaWXFOa(VX6G7pA1l20TktG8hqDcf8tXBs0tlzG2R0gbUeXzQYCw6rhi9lEIuqKYBq)ROypsybTzKAuYuBVsa)eO2GnzbP(LvfN3jQGOh9x2ivFcIQkIaI8ZSWTZ)sz44Y6HgmuXTq55eiAsI)kS4XKsf7e3grXTcTGkuixeQsCLp(wLB8ywE2M2XK8tOO8zsSUwCL5JvydQKXXLIreGS8XJQCF(vTH8vgVnq9BBI6vBB3qlpEJzBhT7cXCHyBoopIzdMn1nP0btWYOOasqLKkcU8oypyOPT3E4qzxV)0SrxAY7B0nxzEpZVq1tdwKrJ2zsq18u70pR7v)0N8dNnQjF0gMLxHynmSHrX0kyr5RImu3MMWpPSv3nQXY)SayQo6w5HJg0nE2NvKhrbT6PURYviIKD8KN0A19mxl)0Lq5qXT66lZgS2)XNs9kowN3(TPM4nFzMskkYfvhm4H6hH0DGGvpWPqSgnqXGC1rF5DzRbUwFh0gvjPb19O1qagP(SQ8EfhE4BQF1MTkpy4y2)QkQWMryEOgjJ5UIZvHsJxey8y8Fsdjkmx9RGs9JoPGJLfVBjdVy4qlUnPnqt8vqHfauCd4Q8UDK7w1hVLik5f71WOb(yXlYbzjaixdTKimI(h)0i7h3gR79UPnJCvnvKrV6gJkdnnyqCza2sr6uE0J9Yg1MroU4Fih1oKtlTq171ro1zypVH36bJ5AQlTqJ5sAkHXlkZbU6fZFrc2z4bLt45gJj8osHmkE2sRRz5xtPQjU7S1FS8RrEmYdXts9MznoWm2W5STDdk60PdPkXsOZqmHHQ(ycOVEA(PIOSw6HxixGXOD1RR3uw46vadVfgQubHd1GrLq8Su4OAifB25P4xOFIL6xSh6LiL(1g3WFKIni(yn3rOIZfcxoACO9agKWzX3gHxz9DDC6VX516ff1V)q9XezblbRfpZ19MS02zhghTvnyxwL6V4(BlrrJFmmvv7tPO4tPdKpusmAlAPFkkvCOJz7gBgHio4wWRM9P0eA4Te7Sj0ktO6Ut5QE0rBqT0WMF1GER)yh)gKv1CxPvzhD7SX1zeL7kTkTTtTmPrxFDBNhmCyz)2U(BtlERFk6J7x)ZJKBKRRDYDXDVaHza5Q2NzDYMEKq(ASZStW)4Vr)CVxSR1l(pwCNqCjYfl(qxd3cDTt4HJ9tXX(WFzYQ2(iwDzDtdHSA5yLRXSwKcgDlTO81tpYw1MMC(XWS(fBnRS1ypBwTWS(1AMvbt2Hx1DzD197cR95kRCFZYNzXD0SxiXkGHGz1gcy3ntOQoS4QHT3hvuykj6X30OhLlnzVw0LfLB5CN97QYG5jDXD1a7rvl)wAZe8IenBLCWWl1hvbR)6DXfTkhasvlxvkbCSe0rb44JUHdeLYAW6OQLsuHMJGHz2jHXqvqE3sjP9a9r7r6dxG6JAaaPQqQ2Nv7hDLTjyH0uGyLBcNJo0kK)oVnGvug5iu)7nPoI7Z3(uDCy3gBqL(LMuPYDDCFQowSNNnOg)znQHi8r6Ogi)(uWHrsclVAQ2ewTG6QSpYWWMfOePHyOI35I7ep4OK7J8F0TOVW5O0r9QjaNSniozxHCsQQQl7cEMWoPNAL36Qx)J(Koc)KuTVEIgvZUJCSvDu)L8v5IQwePSLqsjvbQN4a3tTChxCubunbSm6tFJoLodRBuv22uhQSbV9GvW4(y2wC3QTaVLjK3soEPBWwzBWTs6iJU0AQqOFKgjm4fRnNjXjUINLcQVTeMwskpS7guow4D0a1s9XcOMlT5J124CkScQGDIwPtmaU0beUSDXcRNFNB9C9JEPu1q(sAZqQND5PzHJfodY92ux3wP2gZ9QQlzZ0kmYKkt6YVSlRjOyUBBHlZphRwCTU8uv152sY0n4tZcmIuWgFCartQPrxgW83K((34WUWNaC1SoK7zfYAsTS1t0UY76pPq)P25iAXmz7HBtQKPlrtkyi1dIqZ4yOKvvrC9DF8GYqQ1txQNQ3oRwAcBd4q(j1OQQhe2InN0beDj32(9y68is9rK676Bddj6ACApfHHUjx2MkRaaF6gNPCrBVmzD6philvrABqRUYkKSdTpPIKUCczpbhBoBRujEV9eaGUZKErJS(fZTtu7ezBuiL7AmLP6saYCw)2Wt5j7ctSfWjuQyO7qs0qpZTqoOKx3s(M6tTf0UprtuQCAvFDALKQRvekKrB6QGPwyq1eTRkXHk0oQk2a6Ourrx04glI0bHrUcq7QM0YQ7i6XxRhX3UmVSrjmGzOuo3YJXsFWADr71UuAtiy6c6z1bsFaLbsTIZOJe4GrxSLX4kijMXoevh8WOPgOrDQb9PQumLqGk1b3enJQcjQnt46qJkDuqdhQaQPnt6odzQezr3kfjIyDQEzXmlDbkvjct91v0LeMa0DjkAndvKDhKvjIz9LvQvloX9MluDcorTZeKkFejm9y(m0q1DJNFxHMvIWwFfKA2VVEOSFcgIufNvIAI13MQmHFlXPv9sI8dqLgTLkWXqvnYJvqVQAStHY56bvRBhM17cdLT6I7QcQlDZX9WaqSuLOEODfU22Qx7lSJLkNn0orXX4MKZ(tYyWkRACLLk4672in3j4bxzu4AlGZszUU6jyqiR(fk5irR1qrlLL1dSBAGszt27XHhgfmHsTuPUHi8hh3lAcJ6cYlKE6SzwNEQbSTLYnDbXn2H(2b6Tu(Pn9(AOGRo(6mA4s5Q2oTuhECTKTndtUu2QTxlmCZTb(LxEOm(5sPU2eJRcOUnWc3r9wkZ1gLRcs7UF4T2MMibBU2692oO4Lkm667Ham32KuKxjsnyXLsCDDYGJ5UnrB27xqNbVxnO3lTGuDDQOoiDkNJPcPN1G6DkGZ3837vpcyFU4U8x7MufTTwxQSmeawfNR82pj12zDKueAFns1bs)sfybMYuBFRiLWn4M1h9VzGY3VHbqbZFd4ygLR6csvc(OIYb5A7bOgMkh1JxX5AbbApkdZvkXhO67eOuJE58VUo5oWdlla6pS6s9PvN5xfee7MFrHhbdGyOSVEenTJ(TN9QXDkc312rvn76GliFCBG(yQm1UJHvvAupwLcvq(uj1W7c9EbeKnHcYo)AIsn76djychKT0vIdTceRSUSiTmwwfPsJZG2mgfas4kdV62S7D7vOwMkR6cTZRxsPKQadMp0GWmv8D61BUxrNzk7nSGq)9sYlleFqEh5)QU0MnV3wvDa1FQlmUlvviYmDljOYnGFwZ6buGMY92u(TnUy8GWsdM7AeFOxu9TBFX59m78EMDEpZou75Z59mRrUzRHi98EMDEpZYZmSlTK)8EM1fj78EMDEpZ2JUx0egpVNzN3ZSZ7z259ml98EM10EMvh06sn8sFqx5svNnjDnO8A5nNlb8EX3kFnERfL7wbL3UGOmQq1EvunT59MYaw9PdwTKGxbwdTeerlWoR(6dG1b9tTZhKpIslm0EiLcFNh3oAF(R6VV)vFGg70LuHeD7842r5JF1bEkPfkF)mULQFtDDaZX1cXsg)65y8ZNJ5VFoT7dOth(c6Ci)e602VHoT5JOJQWUcdFTBmO)(m5WDXQ9kEv5iyOx(7)VwoQYJPY(F1SW0LVwocbwfErcfeGuThtIEz(C7Ci(bBszLxfqh(eXDyNm2FIDBMKkplYU0c66u6bQ)WXzZhapvtVvnB0rfPdHdSwzYdmOfmZnv3jZo0kClVEdFZ36(c7XvMs6)tmsEpqukpdR5NH18tu0PJr8gG1CN8yviGDUcUksRUiukF0QlIP)OD13kMdvm6MYvTfkIkN(ZpCFRCwueRBkfV3cIk0zqp)mON7gON7KwPv6QRmhFioVHAwp9G)CNewvt7KZ5(yb15nvW)zGqx5Z9Hei0)XXK3KZSHof0RqIUQkVBPTN5f9PbC0DsLvOXQW9Qwj)hgGqV5iLNHj9tZcrlCvKF9w09(2qTnT79ZZMSE6pys3j(Ryk8jmEOBZAjNbm9YlDgW0PRvDgW01eYRxGZ4txKKMA9ody69Rr9mGP)jyeP(Ra8zatNTpbhtat))Fy3jn6bMogEiSoD1GT0rpW0h9athn3iXm6d4BOoa7tg9atNO6Ujr29pq(JrpW0jQQsjQdm9saxVygG2ioEKA2zMtM1LGgULpWEvMArqwMqXb4d]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261128001,
    [[Hekili:D31EVnoUr8pl5F8z3BRJt2KTxxeVaxBrrFCVWLd4(pRqlrBZZYIcIsjBkc8N9oK6ffFirjRKSzrrVlrsCMFZWHdNhm8wDXQFB1TbOu8QF6Yfx(HlU4YVBXIlwDB6JX4v3gJ83J2c)qe6a8pV9hpE3VMrIoE30hOpWihyZ9PhMX)UhdPOaoTwNrct)3rRwBKSSyS)QB)9V)x)HF(V)F)iAZMqIFkHgT62DKGaC(WWmFR86JhVlDh(4Dfp78n0e894KJ3fG3GYctpE33)l)WX7GhF8ojsKroNZA25pGscP(7ppiMDohQbSZzh8sGVAU4xN)hmA0S3bCjbfXcbjia(zkNRe2X7qbb0OVb(H94hzZpE3)aLI(Ob0m9h)3)gqKDPPXSpE(5BjP7YwZfGZv(0zanbqJwVyZIf4R24)DVhi7paVkKeTfibnlnGYLM4SWqg8aueGOGSOTyAeaKmgOncXOKiosbHm)RIXav9rj4YrSdJct39NrGcagWbue64DjyFkGHhbo(ZjbKiuYJf8b0GO75Cf(k2buy4X7IYoSMlA0nGyt)notEyhjeZbtcAn)hsrjBXPWG3Y5olJLIicyfGxNTztbseye4tcHMqsjyUE8xre(NHoawB8zVWqqnvmvhtIee53P)(TGMRAKCy)lHOh5Gc0SR56rqBWKuhXjyglJlWco7tJstOaVPrf0MHdX(I5yACmnchLohSMtOBabB1TiHTjB(gcomyjBhkG(G3AAy672q9ZylV4DKnllSO84eh)50mu4KYhHJ2cYtWeUWpVy4C7kF88S4QVsOp8irEWBaP))0GRF7YZdsaTOhJMf6i7YvgFAXKZoqVhSIMC2AkJn5S8PN5eMN43R4)ousaqVSO0BUCYzLpo3GXdMiMCwoKMxJK54pJ9Zs5eVjzY5XezusIYWE1dTvbmGWIHP0cY4TgdSF5Lx)MrW1fU1HuAG3MSKhFhyC6r3SXBRFqUPtfEljvcYNGc98rSuVhirG9YKPLVl((yVs75NM6G2y6z1iKMK6Xxy)u14G1i3JNvl1fACqQNnl3GTg5ZbGePlAyaj7rV1eRCulePAAlEMhdNMfRlN(zjcr0dCz4bomoaUjyfUaU0rttdGEcWoUHeBoIXiBbhwEcoT8Bk5X3mj3X5CJiOPi0LxKksao93hc67i4))CkeY8rxqKF7afKhWO9p3crjp0fGY30pWl8JaJEdb2z2n8QTAcrXLo40zq(UmRZsIgk5RxXuVivYt5NwE5tPOq(oLf7ObBT6TjecqCoi07xE9mN1g(0KKSy(ZgH5WYjOkAopbFau3SBww4fx6vCxrvE3LEET39PfQ4Nmp4LlCxmrhIdjBEm3Ms3D5aL3PLWFnksyrI2sJEC((iWE8PcLrZxXTuNPpoi8YdMhM4nwg1oi(qFZdl)v5JtZ8Yhf5vQqeWQDbX4RsWOGhlCN3q5AzJQgJEem1EBO6D18KrI3rJ8aTiEe0nfasIO9Zdj5WbkpTRXdkLuuZFq1lA4nO6P29f0yG9XtWafotMGH8ueV5IfpzWlMW0WyqqA6eXCZlHOl5R3)rimTcqXtI6a6ZEnF2L9ubzA2VYZtAcK)bho3dXofHpazCU8YA)rIigNu8(aAQKIC5fg2vPHgBGBDmIBfAqYBzEFKLdNN9xJbVZj75L04nw6c1i)R2SGkMELQVrUhKXDJudgQLzPBWE9RRTy5BdcsxSSQQOWEmtkgnBNa8gCeJ7HQOalP0TBdb33LpNvxZddAtE5(MVJCZI5VFXFs8lGp3gHKbGZBdnjVontodSfVNBkp)I5LyVMWGDAknbjCyUHegItQiv5h7XqBSwklrKgJMMO6fIIh6vubjxuqYf6XGsRsMkkgBHUrO(cPFQmkIAzcCqcXrm1UA6jXyJ950)MRV(PZMwKjLO(Z4iEvudMnaZQYYMLxVSlwSONRjZHh8Vsz1A8AJMRRnAmLXjLMEc8BQHz9PM1mQ6pdU3QDEEAwv28jwnIh4P9YREU4LZmSLUC9IhU65SPYCuST8xhkSzAXxip2(gGXjAfAiP9SuQhknf5VFiPS3wvePrBZWmz6iV9VfrUkcoqXWdgjlwV4G5e2sCkvFg(Z7qzmrOM9ecYF7EIigrvmut88ylQ2zvdLn2C1Om4(AkxaVXMW4Ab0CHb6lUKwjvx)SfTg8Fp5PTW6nGfhIMVTSbAVUbdd2AfjWaU7ki0HXz9qhDlku3IlCuTBldBXjVwAUbnYbtKyzr0qBYIIW1nIlUQlCVFHXSAY)Ep09isOOlWLeeqZdaFGv0EaZVh2QqgxOq4b1ICAMOhVQJLM3XdiWugApoYobk)cVYw8krjmZhfJ9qjPewQDsaQzrFvkjHuCI5lEfpnSSDUnOAtxU5Z3PPGkoVKVA8SDsZ19GjaxBwuwtWzFP7RAYQX08zqiOZidvzo)Lf7jx8lqGb3SSQ3hsdVi0yd9EOv47gyAgSAUz1znG3jYwES6XuH70bQgQPWiPjScPMkJRgxLrckMea5HSfhH5jI0b3)qZ0gGScloGi5gF6utZcegteznaW)hwHuLpgqAsmRy3yPNN7dUoLJpCTEkhkmqb8xpeokt7amc8)5tjH1r36MjJPrA1WXHu5nVtqNyDa2sVuGjF2z8y)KPfbZyAFUzkEI578cFxGri0CtaWGNVfqXGYlPqJih50r3BpnleIIjAVUN(PLm8j51vasJraqliD5W1njRRxYZS(SIccow6YQSykQTB(1zsxF7f7rRCTeVx6w0kMksN0KvfnAuJRUDzXYoCa2hzdoChe(porL85VFISHmjILYtqj38agjeGe6ajcPB5Lt87PKGhqH77K6v54ZOH0AYZ9OV9rBuNCqtNuq28aGHCL4gl5RqSrewMVF26mMfkvu9Iam8leFVyy8LvXWixKsDtcOrpFSWpbm4l9QNhwth2jryCatEa15xPrld5zjwJXLkuYbQ28AjZYdyS(7mSRMq7VNezJevhYnjQKVDHeX5eqjJETV)jJGzwZ9VH1Z5)kSocchNFWIxkYEXLQS0WDVYjU7BT3kMk3jLNiv9AbdMoiWIGKkoXVs0STZV3jr3w6i2PqxoXiP4dmhiRMDcSSijZu2d6is7jEYuqMYhq)bnXJ7A0Au5TISop(DtD4G0n9SPU8zTEE7YIN900YLWgpiB5lBgJJeNrEvDMZ6GpoCQ1a6ptUtdTQ4TDKbTRrBkPCLVQS0qZ2H80N5hhH0BhLVPJ5ODPSM7VKk9xYffoi6NKIxU9WY68IdrEk5aMxtRac(tqgZTtll)jdySu0Dyoy88HmT3h6XoeElNfSPgkyRkJKFNdCY0rHAAVoXwDWa5W5Nk3hS3VyYgY2DPEfu)tFyHbszydUskABgURnYA2AH6(S2S(U6iWudfuYgU6596G6AtD5o06zUqMsXYfnEDqNA9x8PI(XFJHpG3pEqixD79qWwWlv(JrJhakt83)w(F7yWp(tI)E4kYky1FdELAMLR(P3VO8VmOv32in0v36NaHELqqWp1vDYxLcOrHzLuvPU5Y0TKCgRFoNMVVnAQup9UjSAD15C4klCOrfX7M0NC925y5AlyPrHYTJLXRo8CW8bfWifMl3WsXOrK3Nm06UoJNEf65W8VyXexY8UguNuTODtfaq676HMRUu69x5DY11Nd2)A76VREP0FskcavxSODy9HfMwg4Ar(TJe9biqJQF0YpxQa8wWJt1T38wncoR6uvvpC9OdgbBT531uDs7NH7lt3fecHQRDdM2UkxpxnEqGtv3(Tmh3fohpKv1tcZnLqaC1TiK2VQS7cTcUH2TcbZvD8xX8Y(pyFJY62y4CFmeSu1XEBtuv964zA6PIcT1IdbQ7Wd)RJ5LiGrBo5Lcp96RDo80wAmIGB2CIxgwUTDugqhte8Zw8WQTqXgF7DRueC1MNBTER4iB7Uhlc2Alm66MU0b)S18fb1TgyCZUX0bl6Fltem3QxUgTP55H32CYP3ZfxTEhwFCeGr19xTxJQEK0fkm2tfbXv9s1K48g20fThVo)yP1pIesv9zvh9vZEbPhJPb0x3kid9ckpLEV8lRgrtLeaq1nMTqzZBFKj26AJyeSt1lMn2v3zPtMLQUWSYYQMoDYSu19Lnww1pQw5OGKQ(SSrs5gn1UCO9KgnPsWuxtAxRlwDlpQUIQ)ExAf1y1XQx0QZ)Q02ejxkM0cGRaEjM5LBJpRO6t2LzLxT2znE9Z6lLzgzGPmZOUHMlZmVk976fEjLdc)ymZuoMMZkxPU9D9SIRDetA)hPERPWg1nPRzJJDltlzAElaQyYfcMOU1SKf2y0jnjLA13QiMQ7uRJGtShBsQH6pwbeQ7DRdIb3bUA2x(Lk82wIjMYPCCBBNG9DuaMCBMo2y)kRfsPQbFRmvcGo7M2WB0xxD6taBBzJys17oODm5(RSLUsBftWLP126nyNnheqwAzQcg6(xBjGubPHCl)5GZkBfdP(UORN4RAk9v72XBImkvUwafraSYC1TkwxuuGRl1kA4BsLHyrHJjFyovrTAl68nmXWVIj6ZDmHYfiixGDnfp9uX)sxy76AfKl9QB(0llwda8KdMTbAT5HYHKQSNP7yly9i45(jC2ZlXEcJJTW5q889tOmhsVTDILVCc7PyQ3OQ6lPqol16oD7Hmneok)NTBTsVxrjztXMAOH29cSMSc6DchoEzn17BRPUZArRN62CB34Y4Be0rTElan0RbOHEpa9CEnhoK75qXmJ98j)AxL3LXCdmQypBpb4bQ1mK7UtEQTMJU2rCySGOBz270vcypVta7Q0aAhoIEjYMmLRUJeFPUKehBnI1Mzk5OUXnNOWBS29PiNC1eUF6vtMsvE7E9UAfTVlNqXDsXSzqIBXkzSXFN2kw3LwnUU(1fWV0tWs5IyuuIe1Ok)6mDYctfTYBjubNuCPgS0h6DY4xjHgy9mi1wzkpTBonhUPcLMeEDUkhfQgRhXvJNCVXr5u9I3a3UJQ32E98(DuOJ74e4EXIfUzs6WIE3V0hfiZ(FQfuQXEM0ti0NR1qnnTbhPp9QDZgkuxdSrt9uPDA3oKFzRgNPhTuJ(30E4sPTCwahjtwbpC9pDfP7tY(XzbxSvYU6AZMFVjAI0UCjZvglRBxUKIE1y9y9voI6RcYHIk5VDKUVjB)cNuiy2o1ZDSY1fbYylcfm16rFU16J6cp1xtlT(v6APuadBBX3iHZbbdBzlzaEUKKuBzzjKeRhVA5kUCsIIl3ELcOyBNtLWqpjWmgxOLTesTqog4wAUifTCjxkyDV9K319E5QuX)J7wEh)qy)VW7jHKJ3n9Fw8FxgfVE1))p]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261128001,
    [[Hekili:T31wZTooY5Fl(fnsrZkl7ZXNmzklx1ojvQSjt2DR1tvZBIgscsIRPivXl2hNsL)TNgGKGGenabVi5lJEy3XhEPVHgn6gn4NMF18FB(9RiX05)1RNE93U6QR)PPtVA(9XVSNo)(9KLps2a)Hpzh8)F)wYQGNF9HFjK4V61hg(CWZrU7IMSmy3i2d)IxazfJGlsC9I)l(ZxGs7O90LZV)3)Z)JF9V9V))8ZRO7c8d8c28Y8736UAfn91OrlnZWF(1hI3sF9HSRD56Gq6t0WxFyfDnjXl(1h(Z)9F91hGl)6dvPtI7LmHi6YNjHEblF8Yv7JUKj0RIUKjpor8xWzb75NWVXK)zuG)OFeykCTipqRacfhWec3OxFGSAvG)pa)XJ0xIM86d)hKyYpJiCd)F)l)gqKTXX7J(5lVCJB82Kfm95Ykp6iGMGoqwmD90P0VUE5p9fGS)kClpx)najcsIxfWuU9jEErWf4Q2Qe)n0aFqqsIaJJhLe6ZKuqDtFQ9uGQljH083ylL4fV9pratb8c7i(KxFiKUmaKHxao(3cx56tcFjJpGbL8eJRWtfTJ4596d(j7wWuTG1GAh8BmM88wxpktycjly)rmjCdngE5nmUhLeftC5I1k6IK1RZKeUmc8j0ni0n2LYSJ)dIl7Xi7a3q2GPNhyMYg5376ZjYVh873dwoXBYe7)Uh5fMqbw2fm7iynIKmh7dPrrjmfMZ5Lb(XHbaVd8ZODe1JUKpghSFFGp1pEc4HhgSguS53twg7cg5j7zgkgdMLAfDwNaIK3pUYnApiaoGX2zbfe5zFz6p6UEw6dF30bz(DzpVd5jIRh3u9FRq6XZU8zxppNyWRmj8j3NOmkLtaIhCbb5IIt4Me9ujyTdOFoGtwe5rQVEsL)eo52guAcZsj7PoKWy3Oy9eBh4nTdSH5eBWf53zljCv(v9ORgWChMuIQtGjI(4ChMLghtdDwMegHyvmZe2ye4VXS6PeysY(07uISgyF6yEum4E8JG)fyBx7Sz5QzxXeL0Bo5rF41hK9p2Vm(2zr04yygC0ePx3j9VhO4FywrAQyL7wk7sErjbT3eaqdD2hWUxBnnfuO3ToAfUYgOVESmqHK9URCcPBO(0qsTYX3Mk7BVK47KfFo1DvLAg8zH323Dbi0)F0ken)YG0hUpIMsBPRZj6a26dt26E70jF7M)f()yh571ZQkk0nTH34CzfLaXDxg465al8t9JYcqwVtg2BQ1vR4jsxlBqCWMnEGGLF9OIGWSWkoUWOebwlUbsDl8(o9Iv6yx)jidgcloaJhhYV9(N27KV88iTX9zzNbVXkuHP8IpWlYw6j7LstLqeOpNoMwLjiXZbIz8O6kmdZz9b5zNWlVhsMAugtYFDtoXHq(qWdT(OBTfuGZX8GHzmDWfPJfVBComTaN(CTUrskM10CTydcGyUVAi3Sbvb1YFoNiYAAtclgLSdk4Xzn1BBIpKMrvgLE)bYthC9HeM9xM51cVjKOhzhKwUjV2u28uG7QNjEpwlFYkNiAqeulwbJyRPS5L65J7oflwgd4KArsOpZrlDgx9Klkz5YKfjrAOzmXJLroV0r3LoqzQXtO(Sb1vO8lzVzH3)uWSLHWeO8vystpRgFmFkDvK8lm4IucprLwtOFNUmj2WSxMMsc3fO4jKZ200IlEoJR6YhLE01xhXYLuz6LUiMeByeinVIHAF(dOILMvgwcvK6KEdygkuscBJlMjEcN1UuVvQzKkuaiXn63JtiELwoknQLX1Iwe4XR)jtlKU6Ky3DuNiWhJEh2Ddjqj9oShQiiOOazCLmimmzppTrwgcP1qpP4QSczSHuPwJzv0avBHGyu)nWANRkT4jB7qwslXY6cHNYxXYESfiTKXIvwYwOAWflcIIgCr6a0e3ih()wijzzJdXzV9APC0tx)awQOWlvijfZJQqMSLUKLsx)eQtXRAPQMVGvkbZwZ66B(WycmPMl8ccwbR0g(I6KmL0ccjlDjEquJOyNND9bVPbdLN2LNf4HHwyxgErHSgeg7W2TQISY8OWSSrf6FMTh0)rzPPvi56c7juskitps(OPGPsDA0wbT5xZbkjcDrlHgZ3jK89oI6X3lNilDyre7bIAWirrUBGOtP71YSFiN2)WG8OAyCUSsyF8gbXG78Ohy79H)3XqnKPVQQiF3oRkptjpESuJCARQc53PTIppwdqN1UHulLCLzxKaQHcweSkIsc5B4dPsYk6zLyokmdcsKiVOLY5bM2BG8ebZmqLVziDhW0OBVEYnIWSYIJuG2HzAYbShJfaz20rTWo3812Z0siF(WGNaxb5CvkL1lRlfEK88nY0)SN(Pep2ErTW1JTB8CFKlqY9XG6l9uDv7zPNBPYR4JvegTiYT0sQ3n76dzgSmjgg2Dw7bjDobKUhNDtBe7Y53zHyJnPwnRWCVX8CuLUfZexuBrX11pav5LB34dz3EOm6xY2)ElYk3knxukXcIppyfztG)lzftKzwkFlEbfQVhup8o8xJFhnV1wYtblXFT0BL(EkUASINYniCXYSIGElOQWvVKTEFjJBT50uIoF6n(n3v1D3UawtF7GPjtEYPKY8rXnknBuCv9Zfl9ITBMydvpSbEp26b3E10diXr4diOzNQyvkTyXPr5LI3U8fit6mXlcIcTJ8DNYx7AlnryEaI58XHqHJmb6jkBh225sbcxejGNm)GS7VkiwYuo7kKi7LSzTm8TLgi7uEeD3WyFpRjTWdybfIrg(iq2pAv1vi51gI)JFzRzd5YjhYJS03lSH4(MVzliEXFwxYdRtiIUeyk6w(9SOTpxyWUw0tLVmv0tLsPlXA)Y6GW0TGBWfGk8eZTEYvtYL9ccd(SXbS2JdIZAxppAOGuLALt9BIhVnD9MnrCdEFjfDIZctL8E4Hy(eAx2rglZkXnKEb3LN1rHobHsH8ogQ3GDG)U7xYO)T3CZHlgArXIJ6KRx52lE10PnCgCQGd)N4OIXIchRBMAQzDs1rgeyB9ZyCEiINXq7SEvT5ibklcd3nprDrxfVXZSIBzN7e(nhzmLHMVXdygUlgkZB(Y)FonLJoA7asN8Cnw8EsCGdjoMS8X2u6UvBUzCG)MeAP92uobengerELGzJLyuX2tvLW1MZK4fOFFljjQAkW2imYp7JU8CyRknfeVsZqvK3slZJQnTzwPnQbAp)QNxv38nByL6etPzHf7920MxYInCxxrjisLf1IyQwgJwp39BduZ1ObkGef0QbTkX5gidQP9Axg02LtBB21FBe(8mTeVthBdqDbz6WSYQIQLXUvwwaLxOeJtIsNzG1bltISnSFlp7aLZa)t4jgarb)8CobeHu(8D6a(8S5kcAJEMautnt(KaKgcOlBn6j5ebOOeHYNdGJOse2ZNhaffrCkaoIkrFDAaYf(J2zaanhGMzyeZi74s)N6taawkfnB9zlQK(DA))nx4rt8QobD9hPoLM5H(XON)Inl4CN(FB60pE1CD3v7JHP3w3tr7V7UH59tx(7OYHnO)rPh)irxTPZ(nZa9XTd)DEXhen)Du)9fX8(81v)ppLBMn8AOx(9XsxioQF67KFUD7p69VV8wQDUR99Cx7vCZEl6vV2n0UH87tABLnVXaT3CDUV8TCNj6Kxksz19vp4v3E3tBN3v4)hX(TxZCmBeE0UJz7wCzdduNCjntcT36ifl0qE(w0rDHL6e3hD8KwBhNpvDphD)YBOiFC7zEpmZYQoLRnqT19hV3bcUXDa(3g3BG(243aOElD8(edWBJFpbRBgfMJhyUn(9heUvNi1cOZYEoFAHRTXhBqAB8reA2g)bcq20jRTWx6ujm9n(Azj4RvSY7ZhnixJXJJcqRn(9l8Q92mORU8s)bLAJpoaO24zhrytRG4hdWsRG6DaI0kiYXdy0Ke0JfCOn(nae0g3dqF243vaE2yDWCgV6fB2hitGBgqDgfCJP7I0tlvyfl3gbUeHjyzoR8QduUIJmfKP8oY)mi0HfwqBgPgLmC7ve4Na1gSlXl2nVG6094XlyJ7YAP6wiQA(HxJD1Iw9E3SVKhooVEObdrEeopNartICxrLp1qyStUfsYTblJkCyMdQsCLl9o0MoLKMTPzMO7mZnC4fO1PNS)qDh8Tr1FY3uTnJou14uJ1X4qC2G7QG4IH2YSC2vTH8LCDmq97Af1xge4XM6hLoaKzev7X4GHMAa5WHQoi)PBgDPjFKr3EL5UAEb2BNSF0OrhmjOAERd6NB8SB8wx)Bgv3WFLDgYMgpGDmgfE5OhKXcND0BN7ZNBaQ2QGXixxc(hhnY8HKSglqnrJkzoBzmamXlZjRLQ8DQ(M1OMfjmxwKKdTu6CZPCoATJNf5zxUfVA5NUCGhk3ERVmDWA3nBJDY8vU7BtnX7IvgZPObFElMFK3XGI2RwEtrvLaS(euPesX1B0jKvN5YErRHfqGvxInw8bgC7ZAl)TyE)brXs7XEn5Amd)7QO6HwtAYOfFWeW6QdT4Xu6UL83vHi6SC3Xk9blKgzVp(0hq5L4BlOg(yXxNaB9PbxO3K4hW)JFyK9JBJ19XK0MrUYMk2OxvJrPHMAminza2sr6Z8ON4lOPnJCfI)PCu7uoT0cvVxh5WZSEM2ZcOXuG1LT6GQ3iTtRqEGLtG62BQvYgB8Wgxkjk12HdmuFrCYTnpVeUUxXKE1qCCXTrjeNmBJQqXb)UHkGYm53mhI6lYoRl95vqvROpw35VUp8qmo0RxGW(ub66yTKLquq7mi5q3ii7jMHJUFlevlK45Sp4zAO6w7yU6wT3ZCzXyEa5fWD1nn)m9Mv8REPrFjZigOX6pI3NCRXpDsngij8RCgAD9xs2tw6gZ)vye16z6tn)KBbpX(t9Lj0WNpXztOvMWQ7kvt1GoQ9vsJz2vgxwqwWlTbgTDW2KgD91TDKz4W8QUV(BtZoG4z7UYxVEK62R009xz(9pbo(GCv5xTw2(YgX(XTvyNG)XFL)7NB2gko)xMFV0mf2nZ(LcD(9gwWdOyOBmn0Lm)EtM62pXQt(wgMA1UrW5XGL1sZw6IGVXwOAwaS3nqno4dZI(flTOflm(gBvp5(DTYS(vBnRIflpBwTWSEtfZAUzuAbZs2XgRrD1CyZsNmf5BAuK81tSxl6YkPTCK74UukyEIz)Mzxc8XWwZSMb)Coy4JLHRGv)Sj00WcSLFYLGcSTQHcWBpABnqwkRaZyyRpGHUyGH5MpfgJgf5gDbX2)Hu3(VK6M8PuxbqYWIPAFovV3v26GPmtbIr3)8g6qJH0dDDh8lPmQrO(xRtDK3I(JP60GgfuJk9t1Ps5nm4yQow0UIAuJ)nnQHmCM1qnWeSMXy5vt1TIP0PqOH8umDUJFOwTbHZAbeNXnd9FIdT8ycLzjqpfqC3hHLa7G8GyiQCSzQXoOl9LId5rdndTbb0Q7aEysbQMmIiuGOtgnubWIbKpbVVrdTgJmnCv220rkbMx9GvqPMdzmnPTGAsBr1etWAsxHjT2GtA8rgD1IwIq)rAKWGxSUSSY76xpyMYeSEea1AimIXvuD5F1sffZDqaMANk0uRn2bTjTjhPw(GcWdMPaUASsUBMfdZ14Da6QPp4p3CPl5WwVWgIvWGprFRtg8mUUAoPnBNrFVxYzfeyJRX22RNp2fyN5mOCyx5MaDzE2L1krCXBlgT9Xyv0R1L(l2MgNtMUb8rwamzs243gKBJBAQMMCUPP4t4T)noIB8bam3QcwwDeo3428Qjax6ZpMT7dtTZf1I542JXBCjtx6MC8zPheHUGAzkJeiHxp8MbCzCZNUKyB)(LGze7xWG79TzDux37MR1LqDp5sZ5r1Sq1UxdfWhxZ4mVHs62uYI97ofM0WiTni2uEoT2HLCCrs3gekEJcKFRTsL8Z2tWl3bt6fFM8xmVJFANjBJcH27uot1LMI5Tz0gEQoNwA(Rek0XfdDPeyUMkBedDvnHiE2uSKPQT4AI2t9qbeZ1rvXgWQJlk6wzT2e5BGWOMfUDz0Bzg2C9q7sC10zeBuJJbM2XfA9Rb05zZgG5ooR1TbfAx(PoKVBo)uEaRSssaPg50DOaQm8LoemUec0ySM5QGodFPonQtfiZdtXqHopUnYendkdLE1t4QqQhJd6IOvcm8QN0DgQ9yYIHtIvbg5PxwmZYMabFmHPAujDjUib5lYIw9qmw3bNpMywnOtLcMyU3fcvNGHo7mbXQnx30R5kqrVMB8C7kK(Xe2QbHQy)(6PY(jziIr6YEfX6Btrts2s89tVKO(cCPrBUSfyVNg5Xki7d)dMNZ5QbvRAhUP3fgoB1f3fdI0AMJ7Pbyb5kr1q7iU22QxhlmhKlN1SNpYJX1jN9NKjGJqC8iKl463siEUtWlUYOW1wGkKZCTzBMd9G6xOSabdTgcd5SSAGDtduO7rApo8iOGj0nKl11eH)TX9INWOUG8sPNEZnwNEQbmrKZnDbXnUnQTdSe58t7(eub9e1X3gJIICUQDJcQcRIwY26HxroB1LgDbElwd)sRSuf3f5uxBIXLbIXAyrZrlroZ1gLRecnEC4T2JEQcClAR3B7GWrUWORuzj4rSoPOOsCj4uKtCDfdxGvJ1rBXjtVZG(OguFKxqQ2DATcSXPMJjI0l2u3diWaz6N5Odd(5MFF6hSrmY(QQlvwbYrIX5sF3mk7OPoskdjKgP6aLRucoj5m12psof8MSE9PAWitpVHbqjZFnGxdNR6csLdgCYYb7EhbiQKlhvJxvW1mc0E0PSqPKFbW7KbrfSDakgzBal4VbGR8qDhO5wICL2aelsH0lTtLL0QQb)0nwIbELnZjlZ9sGfiC2xn8OwxP2ZECuOHX9VwnON8qA2OcYx7wDFJDQUJDglmnbgMn(R6Jb2sTeomT0Kx85RZSYn8i1BtpCBfUAEW09p9aRj32OlzAldUwAetdlQUGKKLgtKZDJBPDWoKV0MqtFv750runhUYOctNNAC6Kl(6w3e9Z2TxbWto7Rztm01aOY(oMpDhvBpR94QjwtzTdYpR7tcHl26YOhZ0BVqBzbYFvxk)Mki3MH1bMMVwhmHoV8xk98ZDr7Cx0o3fTtvxGo3fTA5MTgI4ZDr7Cx04YCN2K(ZDrRls25UODUlAhr3lEcJN7I25UODUlAN7Iw85UOvxx0QcaAXg(of0S)pzQBPT1JTPyrGhm9oS7wSPFQ7zbxc0fId)q1JJi5yuoU((wzab40bwtkFG5I9IusiTarM6RFruoP)2l8o5xvJ5g2OiuHVZJBVz)EO0F)GO8oAStlM7uLUDEC7n5xdLt8uslu((zClwFpArcKwm6yUrONGFamk8WQ8nfj3hPQbuKK)JZVcg4R0vQR71lsT9xcJcMxaJmsSowB)WpPJ0mIv63(MwnsIMqHvXv6Jr(UCYmmeRuc9FAMQ0spgRvJuVhTiSRPeyfwGwbMU4PUMzlUYKJXhy4LDGSuEgRDpJ1UFsHcibXRbRDBKhlgWE11ealjT6IqH(QLxet)XiSVvSgKWzZuUYvGjRC6pnH9TYzroWntPkknrwHEpGeVnI6IP1D8dj)uH5UflUR9GGP0G1gzqA5Pj00zfK7yz84(1jiCP(8D(8HoVnsyXcuOMN(Bfs8wB1FNXPxS37Djo9(hhtEDoZgklxPt)D2QvTw1tp(8AExuupFbnsLX8tE3JuV1zr6tu8fBFoSWUI5kjcL8HbpFBKkJOXg8s6B5VwFfDlbEgzF)KwoFMRIYbuNBc0Vt8wiMiE6FIHWxBw39mg)MFRZy8lpK(zm(9mg)A2fvx4zXBCgJFpjM1Zy87zm(T4zpJXVTKNQZPLM)EgJFBVQCgJFZnPNX4xSLgosy8BmFTKTStk()f9rxp3xFy4)zaRXmHPh)K5)))]]
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
