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
    20261126000,
    [[Hekili:S31wZTUns6Fl6ffQWtKL85iNtsz5QYS7lZUzZm14uvEt0Wuq2CmfPkEX(4Tu5F7tdWBGGaGGxKSKpmvLeBEPVHgn6gO5NxnF1FU621Oi8Q)4YzxE185xE1SzZwDB0R7WRUDhY(j0dWp4H2c)3FBZgxh7ihFV3UZ4f)xcD2go12F7eYt(QRpAnHA3h74g939wDVqchUdBV62)63(x)()4)6)9xr5uC1Tp6SEno51WH2k42V(2DrpIF7U0RDXg)a8Z4G3UBnEdk2n6T7(T)5V)2DWLHFILiXoxqyF4fVGcC9TF6I17cVGiURdVaKeRxca9Dk9ct)3H(Et(eWPaKxOlOhRHF2NWzNW3UdTETV3pa)Wt4xdN(2D)3Oi0VkqIm()(7)jqKhJI2f(RxCXdorpgFprjUG7rNa0eeC09Z2mBg(lBS)6NbY(7WTCD8EaiHFC0AFIgTl21neUaYdKO1XEpG99abjoeSiUyuGhrsb1m5P2HbQAJcWzVXJyKB0J)ecmbWlSf5HE7UaSTpidVcC8FeS2Xdf8AkFaRi6zcxHNkClY19T78I3Epr183aQT)FsyYlp64Ijcta6EYpeHcEahbV8deUhghgHCOI1A89XB2Kkjuze4tGJFGtKdMyh)xihYJH2cEDKrqxxWmLoCVZXJsK)Y)VUfSC5VjrS)NUOxjcfyzVNyhbRriJ5yxaommMOWuoB77ff4d8M4vqPDi2fBthJ93TZ3d7fnf8Pd83ak2QBruhOWP7igkcdwMyfT2edIK7Nw7eUdealWyBDpge5LFE2NC2Sm5HVz24u)T0N3c9mYXLAQ(FQqAZLx8IJRRvKVfiXp78mMqPmcGCHlKtUWOyQjrov83yb6Nf4KfIEc7jNuzpHvMTrinH5LODyluqKtyKCITf8M2c2WmInEu2DEefSo7QU41JjUdtlr1PR9FXtm3dFeffHdSSJdcfyvuZeYye4VrS6jeyA8UK7uISkyFYyEye4E8jW)cSTBSEWE9Y5erj5MtFYdE9XP)Yo7ORxgIJIGzWHtzEDRKFECf)d1kstfRm3swxYrLe0Etaan0ANp5ET10uqHE36iv4kBG(YHYafG25S2ka)a2dhGQvoUAgRVTnYZkn(CI7AvQPWNfEBpN7bH()hZr0SldsFWUqCcTzUoLOJjRpm9rNRNn9Qf)i9x2I(w9SItHw0gElMlRXiiURTVJRfSAp2lmnaz9ozIEtPUAfprYAzJJ8F4bxqWYUEyrqysyflhyucbRf3aPUfEFhFXkzSR)eKXgWIdW4X(SBV75DwzlpprACFWHWcEJ1cfMYl(aVizPN0xkjvI8a9z0r1Qm(XUwqmJNQUcJrgR3Zo7eE5DqYutszs2RRYjoaYhcEOnhCRDofOCmlyykthpkzS4KX5q1cCYZ1AbJuSSP5ArgeaXChFi30b1CQL9CwHOn4MewmmE7wynTny3hJ9G0m4zuY9hZoDWXdsy2Zo1RfEtirp0wiTCvETjS5zFN1VGCFQw(Kwor44qFx)cgrwt5HxRNpoBRyXszaLu3hh4rC0sMXvp5cJTTJVpoucnJqUKmYxJHFXX2cQknAk2JmOUwi)I3Pw49ogmZoaMaLTcts6z14J5HXRdzFHXJsi80Q0Ak(By74ifZEjAkkyRFfpHm2MKwCXZPCvx6O0toEYiwMKYsVKfXyydHaj5vyi953luSuVYW9(ULQgHKqg(BrXi3CBl27byDG1LwiGuAVnToG6IEMuLT1AFiMt8AsvTkIRtwbqtPjp0zAK4XJU3pmC8OK4MtDcTO)EU4LMUjei56lzscnjajelSyyixskCu4itASzwP0XlgBv8Q1QKzXItivA44lxC2O8sM46heeVJMMUEkcVBc4xf(yLRwq2uUhEZ8XjBiY0I7Lm9iFEFX1l0eJu71(QpKnkewcCsJwELrDTF12nBr7WKI3oSQprEG0eG5vmAX11)QNc2T7D99xdzze8A1sERKsuaY2b5Ar4J1loEGWo2i7ESzaV3qddUXOcNz)GilYo1vKrQlg9mKmA(ZKo5eMGmjnf1cjxriFminpHo3uTePoXziN20RzbfckDPAYo)KTxzyx6ExfQP3VabECEnNOWqNh8WRt2BPL)qgT)HChyrCUS4xDXNg5MMZb4Ap5cdfEW)Ei0nw6xv)yV7Hr)EbJE6qPBz0UQELDNEvNORFbeFJtawt1PY0sKpoFHv5ILQ0Qi552wUxmZSiyaZc43S8Y9P5zNMlgYdIi5I2INc2LNwUOzXIB8s2Ig9RUMsaElmseE9sXRyCuxUbTDhud6RPB(DLWYTuNZZd)EKh1Fg9GV3RPzINAqkFlA24vFpOyYTIFn6DK8wpIE23w8RLCRK3RI7fPYJmdcvSuRicVfus16xtx2OKXvXIILOWhEZEpfnl0z3J(PB3v7nzPYjdX61qUoqT)Kt5T7sygLQe9i)gLIDKF1QLQiqL4dQuIMnnKsd1zr(XUKdO(65Z2liui1)sy2AvmvLsExGfPxvBff8Sf9nRYx7snnoICigXpqMuzuE0SOaOCBIecLaH9WBDWa)kIXrZ2vCjslpuvowRftpRHkJrv3GEwhAKZW9yiIFWtabp3k1PqY)qxfx6WmZo9LeyP)wGwuCnUdPYnTpCsOR4yAFxTMUOJnj)ifeyqR4VPXzeLVTGcm2fhaZNNLFamLspKCwnB8ds2oZXJaH)zI7)05tZK9ccd(2r(KZsheNnoUU4GCsv6CFuTHO8P30nRr(nOhFz(b2PHrID)qfy4Q4rNyFOMqx)BYYvPqNGaSq2kgYnv7PV7oBc9VEXI9JmsPrs30LKfqZckN7Dv(4gNpBwdNsNiHW)lkSWOx47SywDhE3J((6EYcI4PHHOGlcTq8MrbrhlI92nNlzHuZx4LrUYPYlKk0jDHc9fMmzpFKKKKBeqcjjvqFIoyBhzWkA0udgS2LMQPr9djVyBsCQ5h92WG4bAqKvQA3qzNIYjz)QIJ8TqrrKj5Ty3QQBJ699EigxAVEzZsvI6NxWbyKi5nhVR6(WNqyfPuN)O4V9ikoK8anvmyF2NCOL1WlhfeN7aZRiPLs5tOE0Sdpxhfq4PO3K9swhMuD6mZC3ITsEwtQzvh(kRQubYJgfJQQy2gTFznq0RSjzcK9gw)ud4E1IC0REj9QGP39L5pKKAJSvjCPqUObzekYfFTezVvV)Xgy2HpXaZE7dlW8D4ZjW894JiW8u6thqPWC4(Gbmp9(mbQtKAr7zRpNpUFsaMh6peaZdy7)BEg10)YK1w4lDSeM(UhU1Sb)npcT1V5HQz(npDBH)3Nb9QlV0FTRV5HPj9npKTMV5bTH8n7J2W38i089Mh(wU38DOr7n7H2R38KQP65khzJVDS(9)RWndO2OzYBfnZpUnsV5hZ2N3S02TK49OBJtW7q0GUh)9P9bmv2bjhnLNinNrToV5hXgM38JqdwKtBrTjVPSMJVz(5I6oQ35MK3uwRXFa1SGJwlYBkQX4pGA2HVb5nFxAlEZZJMHVllaROvwTpzAfEZHgG)9Qb4n5pvOU7EDEy07uSk2dXR7gS(V53nzA)7Et(oPB992RXI8GptA8D1fRiQD3BMPrKZWi(bXZO2EVllKQYuu1fON1anCe(41Q7FiQ)kDivEdU3XfGff9AO92fnb578MA3COv27Lwz389Tb2n7CdDo0dUuvJ1Io0S6hgBCJ6Z5g1S6MdTO(j0qxlAr9UhhR0Uh1tTJU57wtOBEE365YNpQJyl8mMRFxA1H0vNsYm)tuBMBEM1C5Mh9wkVsflTJNhPgjVBEM60(4IcLPDtJxtL75IvwFJxnpAhpB0oO83i6FfdyOlHyor4THAq2sLjK2OobXI6N5QsuLRyXsbwkVf9VHYBilAkTpHvkz2iySj5xbF1WOpr(dxXYqWC4IT2g7g5K55KeUY1)bh7APkBbQKh2yJZdpgzLUlN3iSm24KgXnBJSs3ORBMpPQ1qBfiv0jRZMl4LP)Y5TH8LmmkO(n1q9Q9qeDtkmeg9EVr6HE5SDxaKcYAl2Kek1(xK)cz4M0xZWQLgJYIjL88ph7sA757DCj)TGaiSQBNTZ0gssmXuW1brg4VvKZw8KjtQzausFu9DLnqSxMTVVljYlnHjdE)29gCrXl2NiiHBfBIKr5zJ)0IjxOAc5KRNREtPgj6TJ3bkTkru2lP2qv0QUuBYibg(uLSLdv3uY2iqAksIV82ZitsKTFzgSf685zJlhH8QzQyDXYczuuqP3Kg0LKJJfHzgBCHcLmU6NU6hTFerBC4uwDrQGxuRO5SPZMp5MLxYKil3z1KpMZCdYG3(oYhrBvkV7vY9aU1oNY2kIfmRO3Msyv20u27KEuXsEfq0BYSzrQs(bgoFH4Wl1UgTKu4u8SzfluSVALZKRQJQOse4(4hYVEJ6VdzZQ0x0AyRVlARU1zI5yfXOs341RffQYpmI5l3SM8XwkULZu0QLA0lzgJmm04XQumlBlNbt4YDSf32wjE49rdGjKx5ntvn8rJ2XIUIM2djMY6wU2mOu2kqgy41Zsw9A01Mm2PPiDMoWK3OFTzqPqYoMdihZjtAO66oOiUGPL10IAktJv2k8ktlWqXYSJkwiV8kTKLYvT(CPu3UwzU0teiE6LSt5egUErTg3k7PeBbMTYWkt4ALSP3NeGHWenhlC7ey3IWSnti9qgyQiF5NNSpHvt9JJcDwJxii6r39u1BuTSIm)Y6LeLdRshHAfFe3ypAnK8lAXaj98xrT6m7HQSr9s7ZA2WEnf7pwEY8JsSFfxUuefMJZzF5RLwkbOQSEt5vWVuwB3utL6Yd6O8fvvXWxBElMuBX8Y3ca(kDUbQ0XqEDLclRSfTsd9TY3dagxKsvuv2)As(qALxGOhvgme0VWL7k4SA9AP4psor3xSwv57Mw3PsoQKWgsiC2uRFskJt2WKRxAiuJYEFZ5tPfSoPQZnJmo2qUiYTCRmbo9(MkLgQCuoSs(UUL3ZzfRL0AJA5nCRJI81YKqrAJXL)O0h)0rJujLc1QpFwOvkKYS)rWouO5XrvS4IP6pvWJ)smZxmSgZWAmYNMnSgJGTm(eEDgbszDR1i6voD0S6K06wZ5ex7Qrs751ECzpvR2UwJQLtU8YwVWGr2ESp)RZs7d40JC7YFHV67RMj0KO6q3wD7Z4GqqUw9hxo7YRMp)YRMnB2QBjNHB4Q)C1TRXBqXUrWp(hZj)E6juV6Vb3IhOFw9hFgE1e9C1TLqfOv3Ah4eHdCqWpvhSfUkcKgoMLrvoymKLUzKtiCgsO5Nvrt)YWBy9eMhMdjC4ls4qjakSEs3z4pKillKilHS4wOCzrnlBcSiseMR4egMC8iowConuy4Hv0Qh236oGjseZFwIloJ7DHq1jObuptaisFTbwoNCKnS5gpNUcZIeH9xuB)(YXY(XyiaPA(m1I1vZennqxmxuUKu9fOsdFC0ShNbpeLipAbJIIpkykN5dQYBhw07cdLTYI7kc26AMJ7XbShPkbFODbU26QxhkCGKkN8H9vmgxNC2Fsw(3FOymIKk48lrWSEf4jrb7rLcxBbpskZ5d8NZ8m4Gu(cLfOkP2WkjLL8b2vnqL)bTDGgEYPGkeNKk11eH)9X9IMWOSG8mPNUyH2PNQaNkPCtwq8SuRLTIslaWsk)KLpmpIwkJVngzlPCvwK7kqDPMSTEiVKYwzPrxGbM1WVKYPQIfMuQlnX4YGJznSO5iyjL5sJYvc1mpm8wwqUQqGPUEVTdwnPcdF4VIOg5qwzDsrsLiCqCjL48rPktCc(zwhTZ0JUdeNsqItAbP8XSeitY)(3yxnRdOWzLvAj9V3QBPhNnjDwICklAxbWr2qz)9hklhZkLCO3jvNLLSCABaKUKYLvwM(S0Aq1y(O9nsh4DWAaWww98mOZPeC(hcWhLgdqkmX9YFLC39lPgczR)W(cL65hAzF5K4Oz4iY1XhrqBUfNyt5x1vwrZf73RYCf1gCxAp6U0e4DHdVqPASU75vYjREoPT1bMOu1NpBJgnPqekt112pTK4QnCXWm7xev5ICWNvZHtPBqVW2Bkolv5uC(mUoCkUg9UBVPWzuSSY(f(02YEpw4kTHMGwcBPuXrw2zfF0lDvyy(myK99Uu3h8II1g(cFQwnsyf58uD9TSJIRBOzAZx6R2Kn(cFwxYwMO0rP2d2iLN2BBX3R2cWxhsOqTnyHkDKHpnWVFm5Di2zjXNZvNphWoBqf0IsDn2pdT4KE(856lP)4GHQneprlmizVaN1OtP3jAUro(QESay1(2IiBhTux1yfezLwbzlRLuKx2iEVJtgWzv(QPu7zNsPuLHOQZtFl)16cjlBGf8PwkTm5CaI5CQWroyDLQX8zV(XSm5uxLkFd1utqNY)vuSu(tBTZW96h)Ktwi7SUuDIEDd)(0aquzgFEFWkwQPr2(Hk(CP7hJt(nodarwEmFSzWil1extBBmF2m98i1iqH(imlvYK3xg((c7LXgkcnbBnRyOfe8D)Pf8A2a81KAULDiT0hShm3DdCt)ypaOhaN2eWPLoKkRWGsN36Wa7jZalpKBvZWRSMnONcqs4Xv6wwadO32mot5I0otn)Kpsa6vrKwhKZmRAl9WbxQijRVNYFJcSRTTsf7Z2taKRAeYLQysBTk1bf0rHe2yiuMkTXQuEsb6WZQHlycnWGPUuXqwhyvANsALyiREEbINoLXRAFaOAI0KJy3fXoPk6adVurrwIdC180jHPA5F6vkPML2r1JwUAPoAHcK7LY6ghjVoi9Lq1Fw3y3I3sNCvrZpXnkl1DpvYHdyLCKss(aXYijlo)QwpQCLsyemLP6E2yvar461N6pCNINViafhmNM8HYzra7uYCEL42fLRYI8XU)iSYspJ7Wuzq(5yuMcIqw4Mzksnc5iMdL9Yp4aEfO1SxmMnr5U8g0qcE9E4aS3JpI9kjyk72G9ZY319V7nq0EH9RY7zxd(5p7Bneh37yCSkqoUPq3QyuowZ5M5F41uJP0glo)BhPKbEKGb1mdwl9d6D8sMQxYkBr0w31VaPmL98RBYILYadBjccl7Cz3lfnLBlwfR8OiAhEkRaqLBRuwWoEqyRNGu5MoXmVbcKHPYASDILYv4RQlyuAY4LjIIVeDbvDQpcilQwt9aN56AwnQylR2orZH1xO18d(6RYkNt1M)Rt8HXQcIwhGoVI0WH3UJ8zrt03vdOcXaQqmGkehlunyaviQLB6AiIgqfIbuHGkZA0vgItUGQedOcrhKSbuHyavioGUx0eghqfIbuHyavigqfIOZyuHGBnVw0Vqc35(Ad7l8RnCali(BFpIfe5rfu2IgA0ztTaMdoYFKgrcqaIJLQse2ZbeDqS)a)h3u0aUpOqJpV)GwYjED4(qUNIy4tOrZSe99T9oblercq7HkQAzat4WPQhEWGisagpurDlGlHdNQE4G)HObKDiByOrhwMk7P023TTPriYxP6AFVxO9q0aEouBtEE6GNd5PEuxhY(rDKODXiLUtjQ755gAeL1(ZTtMLTblfFk)9LaFAIMdrcqSHoAde54FYJHdr9mon0ilMiVMr8J2NROZqNxzxLXPQRsFRtkCygWKHpOLWM6miSdoRGjd9rYcIczoavdvMVnGedz(cdiXG)asmmGedYcuFW(EXPM7bKy49BaOzFW(diXWh0bw(pMNbKyyajggqIb9mIcs0kCajg6GQmGed93eJtdKyqtfI9RzlQ(VZFbFuuvdFx(mW16VLiACq3qkfgA8ykppCYFJ3Z)WdfFgYjPd0hNgTyMLFsU1Winoly6x4mzWV2LV4oR(UnKu2eqgwQSmfRnVg9SrJCAktNidls7Zmb9uq3gskKQJ6WXrDIu9k))P9UwsTHHbIEwYgJudne7qkjGDxw6POuOjqnTqGwNT9S3iljB9z(iBVOUGZsBlnZinspPrAEHVlPbN(oaMzBWNUDmThKyYD7Nw85fGJQDKdwnburyi0E)dNWlP3CZ(9aXCucV4kpgeNxeURbjsgqRtXsommCTrgrUSVs3m2)CVuT3zZD9N6Nzd56CP)MZKuISGmhZxb92XnedWtl(mi4ywd0xYWjhqbi3EkVhgrW15zFdCs7iKTaEuXwacckAaYhfqN5pjH2I1X2go(AAvg0rv27AevcLTe1NaDFp8Vvh6Yc0JLOfScVwVPSD83G)RnxYeAzsx1cKQ2os9EurRjOKYkb8wamLFD(MwYFqc4P7OMzcCL0FALsmn28(1KQJwr8NNQQRcTNgNDwQj1W6tyotuRlX0rqdsuCh63pNmkk9e2W29pXWi0t7VSO9ZLav6LkT3bF91)lqIY3VafTafL0yWfOOkiIAAwdhbONSqsqLzozCC6kl00S3az01jbrnKRlZ4bKOGCkkgp2HWY5u5h2AU8dMZ(S4y4M(Fylytu0tCjdVgu6aDa7XCarZ4ucuohn(mvVqpAqqhHcmGSpWFIuifZXBKzSdEqA8xjq5EUG0mUMp0q7el(XeAhBrOVqWqbFmPqbf)joaoHRLQANuLaokXU5Y1MVRpDEVjmDnThY87QmI)5ZFu)z9pVkE6IIJv)s)bV87p]]
)
spec:RegisterPack(
    "Demonology (wowsims.com)",
    20261126000,
    [[Hekili:T3ZAZnoUr(BXFrJ0XjYYEg5DUTSMQsURU62C7Tjv8w1(nrtrbzXyksv8H94RC5F7xdqcqqqaqWhs2sHFiz9Wh9B2OrJUBT8QL)(Y7w7KGw(Bxp76BU6QRVz2SzlVl5L9OL3T3X9rNhG)iWzh8))FI2fge6h(WlVD)4NdFo2Bx8u3WDtWp5l(HoRXqBvQNFYVeSCLuahVh5U8U)4p)p(1)2)X)ZpVMbXL3T1B9Au2RHID1GTF(T7t2IE7(8RD5MWi0tOO3UFnAJtQFYB3)N)7)6B3dx(T7lbKuVlXOp(YNDI8dDF8Y17JVetURJVetj2B8Iq2RICcwpLC5P)Z4WGjFgWhCTyFGBwd)Dig)EXVDVZ61HbFc(JhrVepfqMtIZplHUg))(l)oaKTjj7J)5lV8bVKTPRWSYLcp6eaMa57SA2MzZqFDJ73(ca2FfULVxWdaicttwhI5R9P((XWfasf470GhqHbaHKgdYfFKtuaMsbMn7P2JaO66eHOVXwKJFY2)KdiiGxyNtGZB3hHCdbA4faJ)TO1EborVKJhqw68egRWtfVZX3)T7ds3TcZAHBa2o83Xi55TE(imXe5Sc)hjorpGsGx(bm2JtJtC8iK1A0Q0nBYPecnc4jYlmYlXdHLJ)dhp8J5SdS9W6rFFqmLR037fqaYFe(h3bso2BIj7)UVZlyIcKSRWYrqAeZjo2hHIJtXmmbZUHbjrHaUddYHDmYh5s0XH73hgGcsMcw2rHBagB5DoUjEGqE6ESGcJGfzsr7nPaj5)51EX7bcWge22RqajV4lZ(S3Mfzp83Nnk3Ql)5TDEYXZNiQ(RvaT1IlF2Z33oj0gO4N8EcHHefao(WfyGlojLisudLWn2a)zdgzXopIcudk6tytLnsHj81PZEKTtuIxCIAGTdSM2bYqkWgDb9oBDIwtVQpA9iS5W0sqD66WNdKJ94TojjOiB30Oyjsf9ibRJa7nSupdatt3NDNsGvd6Z05XjG5XNb7lq2UX(b31lUctkz3C6JbWRpk)FS3n52fXOKe4l44PCVUD2FpQI9HEgPPKf1SK3K8IseAVraahAVpeFV2kAkGqVlDusCLfqF9qjGIC27T2oc9akaf5ulDCZmEBBxNa7C)ZzMRvHMgBw4Td8wbe9)hsaO0lduF0(yugS5UobOJWRpmDR3TZMEZ8)nY)yNZpQhvcm082GB5yznYb876g65BdR5JcIZDqwVrMS3uPPwXtKTw2OKWhEWhim61JlCcJDRy7bAjhyT4gq1TW674twz6U(JqgngwCa0hVsV9(N2BtxEEIs)(GbHn8gRLsmLx8bEr8sp5VuwOemh9u4OBvMWuFBWNXJvxHzmf1VY)1j8Y7HGPMKJe6RRZiocIhcEOnhCPndcemsDgMJ0rxKPl(WyCOBbo1XAnNJkw00yTWkbGm3l6YnxPYGg95SJD2GAIBX40DW(qS3G83MgaHziIOS7pI)ZbVaiG5a3CRw4nHa9C2bHLRZQndnpf6T(zh)hRfp5BNiEumSfPceHxt5HxQhpE7QiXYrabuRsJcWgAzFXvp4ItDDtxLgRaMjo(4iYjBz0Z1g2BAYuuawPUwk(s3RN4dogiZnc(aIUctw4z1yJfGqRJ5FHrxKb4PvH1u0pqUPjA(6fZPor7cRyjqrBwyXfpN2vDjAPh9cubmkLYdVSfX4qdgazXvmw5Z)QuYs)kdRc9lTBeCazOFKK64ZKTOGhG1bwxAHa8w7Dj7dOjUJYCLIDZBikz(hZD3o6IvHXXJUiZ54uVyBY)Mrd5XucElU9AUinZ8cco8kK1mkPWAqam5oG5PsVGuKDXRwltsD4MbQCFUxp)KH5LZGR8ddxdRre9s1nSuzbTihxphFWEpoX(zVaW2z0yEh204xEDSbsKXxuqLHrj248SuepHpY5jiuc2ZKl1boFsEagfuUMpyra18OZPgRLr1zEiyWMCnBimELoAX7BNMPdKpjZdXgAEkHGhX2XGtCS3dbO1zzgyXNOW(tJYYJ1uPyUm5BIhfgyGR9OpiVdG)3HGb4HFvMG)UDGjEg584HIbOWUkXtVtZjCIFeac4maBinxDhiHi9bthJCIiPHWryju1iH9vi8ncSwinu6YrNKLXAA4j5cLY3mcTdqA8TxpDoZ5jp5W5(CCop8QShd7IyXSjns2s2mudeS5KVR3USeBalnZizkO0rVSNPveljQaC0DgsTvmdk8Ov4eLBfTVV46xZ1F5rGa6h7n(o7qtb66XfZBgb7ggfLUhFDdjyzFRr)qIblMbZcAWNf3clwlckT46QvjcVCt1jo72d786L8u(wz5SwYZSOpx5eq8E48qyWl5XFMlqkFlsmOvFpylu7K)AK7O4T268uOR8xl7wzVxfZlC82ubcHS0ZisVfSrI1VKVCBjHRMGjkbHZEXEtmp9GDmIpBWoiuYPekKQ81h7gL(2JDv1F5v6fB63DnKXKPS9XND5Txn7vj(likbPHcwrEqwp)yX2CEuDFbcynNWIbVn7C(HD5RDTHchzAD232jrWUXWKYtiCYx25Haax8fpjM5r53FDycNqCXvs8DxsA1sh01kAmJTLW1A039mp0iT(ke4)l6raGNAByQGYpR3lyUAMlBpzEq6VLRKySsZxHeB2ZVfYKLgCwkI15)IEpdY5)fAKOfju)lZyjuVuGp4CVVjmklZvJUai(NWMYtVAkL2lamyNMeIpBuGC2457JIyGQuE81L7lYPZ0Bsd2nihhf7aymqiXN6ljcogFLxPq5YhIi0p870Oik4jWzzCs7SnkF4pxnBwd)4ktva)NK4crwHMF(S6okLTHHMMNxz4CSev34lgt9UWVz3SuxRDZ2uGvA)5tELWc7DXANBNp)vjo4kCF2nBQXQCloQN5j2LFgVFvCLiqq2Rst3ax20ldLjQYHF7tncVY9IX8ujjkHb1DR4P(sDpr(D0ts9FkOA8renyDDAyDvXuHJ0BNLsNwErrcSstcTDssCCFSnPVQUt8im4HuuPuTZhOUc2NTNlqiH36aiLRCGgzawxLLrFu0p26KgJFGMsg8p7JEKD2jshfax4CJRqPLchwkF0SZq2egq6Hj3KKlBcsQ(rp3x4f5wEwt22Uj4v1gZLqpgSFCD7NxHeZB)2WQXH3asNdckP9gUfYgG9QBa0S9sA2U7AwSuMq20DEi1HBlo3j1UoKEQqnHeREmr9(N2IsJAD0xz1dPyPEWit2u0bf1MS2leZFkF1Tubm9EFmy1HUxWQ36zbR3HovW69O)eS(i1vcAjMdxViy9XRdeQJKArLFBoMpUDBG1HUhdSoGDwG1ju)eOIwBHT0XIy67Yd3WEhW6i0XawhQ(eW6JB3b8(O0RU8s)1jawhM6)36qw1)wh0A93QpQWFRJqD9BD4RMFR3HA43QhQCFRpu1RVW2W2e6MgBA2VAx16BD(wJ(wNNvMV15y94BDou5fmylRk8Tuv79zFK3L6J6yud(wQQ8(di5h1VvGVLS6U)as(9u93BD4Q6ElHKG2mHb7BUoM7ZJCn3BXN3WwSc7rSI7TonQZERsNCsZmI0uLVFCQYERHAR)9Q26TepFPUBEDAi0R3KKDsgDxK8HPU6BpBjtrFIuv9wnUw6BMOrMgN9n9h5AQVllSiHN1OR7zoWan(5xD0FwShUCvQ6QNVJlijXS8CV25vK44UvcEgum4CYX35kM3AOo5fSdEhQoERox0IdLXAl5j2L7yzSQmXfTxLouRY9fp1xk53TkH3AO(3pFTP6H6FV7lGukHs9uTUB9UvH7wN211U6p3nHSLEyR1N4wtaD1pC5(kvwnSBDIv56wh96vVYM2AhopsvPUMOBmHypO1MU1HTI072hLMuh6Y8IBC1NdVm2xTxcAxSAV2vlDCR8QmbKPrPYQ94kV6OkxXMhc8qENZ)e24kE1FL10RwkZ1bKHz)t4ZP4KpJ)vSyrmii9r27s9t8Og3zEu9dFWZTwOUf0muJe8vlsV43x8f6EuPvuEwefcpcbNtHivI9wJ4pfkzOJpDg8PKzJ3dBtSZZN93LM7J0Ss1vp8vDoPJhFHIGrKhKc3HDoP(t7SQyzYRIYLAemA1U5611HjfA1YOCXvTb8LSA0a9V3kO7gg6JDkfNPaeC2wKQRrJ1LhSXJlzB8NMp5sDMhtU9k95v7czVD6Ei4Zx1rJkERxv)fXZEjB9cMpPonFnFbwcy1y8l78YhBM5PSdnV8hLSTmu64XTQCvimRNq(2jE7qt0DU71iwkklxcxi9BWsNBzL9s(9s0Ve0XUIqM5uIkv5kDm)E6(YCbb3nZ0H7IfoOq0KamKR)LVKSMNLg3BrU5kVYCvYvw0Ucf0o76nQ6fujBnN0Ay5mllz3MOEk8UuzF1VMN61BL8a4uVY1HJ1SU9c5fHM4HoYTcNbvxg4jySbpwL9LXxeAmFE87RRunEL5VSpQwmP4Ivuw1GhdkRlSx)rxOwKees(JpnXC9MLQ6VRnAUYIkS2tuyus1uJaPjkydjPZzThR0dBJMRG8pMATJ5NLgW69QMtEOQluEgVAJPuvmGJeVrwgeGqHkhb1TZRLYS4QqgnwqJL1BZs3murzUq3iKzb2Plml10UMcDrg1ZLhjv0pFMRAihu5733nZaTBtnpDt0nIulvBjViQ6GjHwDTAQqEX70rLlh)Z2i4cvfEI(naQ8E635OmTlDF9FR5fFr(EevtmQ3zPKGwRCw)EbUo7DC9si)SCwv2zPVFso6sWRMFskc1uoxdIqJeHIBj9yZ(cRfV4kTE94P8sBzVTABDC01x3wvZ4X0ToI)HfEeF(e(6xMunHcnnJclV7jWYhOlHF)IXzRlM8JMC2p2WWF(BKFeLZpQHL)f4wI9K8YF7lZO)aYU8UsnW8Y7CJ8sqrEoWFv3ewzzcqnciJcvHjUcpCPGt6KxbdZVOdMHLNel1dyXjYcgdFvbgknlvQh0DEsTGPL5kOLy(rSIAArpkBYeCbtm3iqmCozXgwcgnKogMN0QFcv09z7cMm)jfM4CM3fevNMIjMjcas6BnqY5Xgclnx4511jcdMy)31l)(6Xs(XjiaQ6Qz6jRBMj7ZathpmQPKQVaHAe9JsFCUr3Ic6XOj(I8mCsWSOtvr5W8ENyiOvLFxztyJMz4ECMlneMq01UetBt5Rd1iRHqNIU91OJRJo7pkJnnBKpoBieU4seCRxToFU0OL4A7CUHGCrh)mKtNCnQxOSya4y8eWHGsrh76uuSk1(aPEyqq3WXHq114H)9X8IeWOkN8CHNoFUXHNQzK6qWMkN40qRvTIslM1oe8PkEyXHVJk824HWdbRQ8CxzQ8yiARF68qqRQWOlgxp1GVSTtvDS9qGUYaJlphFQbfnFy7qqUsVCLgWphgCRYjx1P1JPwVTBcarigr3FfEnytxN6OISDIimnEiax0lvzGJh1p1bBkF09zgKIHgezdPI(SKqt1modeRHvvEifxofF2ZlVJKwxCmRyIrLlTIzCtdjW3)PUZiEQuyqdr4zvreNNn881nUUYAXNKsdchl6sx1MxksQS21SnUtqBFRG2KEbvyafr4yXvtuXXzhcXPe3w30lIW(Il31iJwz9EExpt6sKRk3usFvMdRRjCM4APhooRbNcEZ4o(xvG7exT(WXDgC08nJROVMahPAjF(5Jud5tDZjjcofJeOrqN9PDhlb)2mIKArRWXTip3lvwj81UhYrlMGsnDekjSb8mdd(Gv(QQGvkQFXgYATzWlvxTlQI7WmGyKhnIyL95D1JCVFg7snEmzW5qG9kcgHMgesPjlupiJ0oqgA7ezOTJKHd5mBQndTjIMrmyP)1rKxNXCjAuWEU3JXsSsE6(eDQHt3Oc(M(ccSCNc(sMDcBApDSg3t9Terz6v48cwQO5iU6QmFOWGRaWntUkZu6dWOIs9siebNyCHnILLWXASs6B6VwBfLlbkgyQY9HZQmPtPDMkmKPWC8CXippp3hEUPsLEaHiceJATRw6TD2tDMSU7CvNkIUtHPBZoddMotCkH3Nbxfr0O8q3LEwI9JWHDJp0t0kI4PMJZ)QzZmZAYGVxnFyxrOm11TvyO0AhRHKWrzy2ionBKooBoBMNnnEG2qu0kpkWsjVPZ673PXz0GfWbCmz1MKdIn5uwMl8hk4Gf3zQfxvZhJNIweRhv5VVNwzIGdt3we383QzygJLBe3kcB3AStDkBMtjd0MmjBO720SrYfHKuwvO03OymA1wQI)z7Pz1L(H1fHXuw5s695ycdjTciiivzHlP94bmbNvDQW5aHB8EridvfYuPuc1kYqv(mKqEMKgdD5bHWjkJkTyoE1rwXKjcgHuuf3KWgf7eXuDJXMTjBd30lHpuUyCnX)zcBCigIyeIw5AafNtx3O4QhXibVQQOREWlIMXogg1)KQfluUSxDZJmcuf93RAHo2altgMyT0fbKIEAvbs(jrMwOoQYvknfZii10JYRYyoRE(P(ZIQ45lCTkmZPY6LnB8KNc7Ts7CEGGvvE6OZJjE6aFVdWKrJqhQpGLUmu0Q6Ue)cLtR2pPU0t0mV0oudmntMCbQCEwIRuFmdLXQSzMwZSVYTSy9spb9QRefbMU9Ox(yBaJ9VPUSpADlm37JGnDZGTg37T4PrslNcBgkTzTqmraRk(DdDBuIQK7r4BQlzefdZTpMtZnPbnWxCpFR(ggReZl1Ts56G4ime4iuUQa(LLc5(D6WrqVYO0RjKYY2z10jwQI1Qmq0NQjXDGz(0Ct2(Ue61m21Bw1AriBvX3ktbAorByx(8nvr5Q7eimX4yKMztxTdNUL4ch)U94EHfZVlhgfadJcGHrbWXQv2hgfa1IntfejdJcGHrbaHMnOSoKhCbHjggfaDGYggfadJcGdO5fjGXHrbWWOayyuammkasoHhfacR51IsZr6PJRXT5Waa4Vmmaak4ZHbaWhFUTvdaaMVE5TyFJSPBuFM3dZhGejT9Ff(PCt1F44NEAQaKiPz)RWtfTu)HJF64Cai5dsl(Zw5S71rDxlBMJvJ)NiPX(lTV1wi3LCuHhME9p5CSD(zFaRTs)A4xUvl6V3Rw8pzOj(RTi)(40e)Sq6QRcjpx1eASIvfDurtE3zXuoH9o2m)jsAy)oYOYmh(W3c)j9CB63ijMmtJtVMZVZlSjrkOXMOV5jDwgM27jdTK)hFUT1TKFFSwPet8Z4o1pzOr8hAe)HgXVXKWqtX2A2ID5U2uSef9qJ4)VWwadnI)GfNrSvpAXn0i(dnIp9zhAe)wIZQov4CGm0i(TNvgAeFdJ)Ze2yOr8BoMvSK0rQr8nsqQVX7PGqwQ1L9R4TmOMuF3QlPrSQU(z5A7OsETLnOznOaoGygv)70VH15rrh6YVSwPYMilyT(OamKJmwDnudImOYiWTPmeYPsqees(JpLTNtLhxSIAyPB6TYYjSURsWe8kMAegns9AinDkP7ufstf42z9wbPFu1zh1pjnG57h9wHd1CxPfdibjosl0o6NbcQgzbv(r9olaMk9BV8WCOtmbLXuXpyl0mwaKTyJu8xC0RuulzrjjRRv633L6PdUOAvrj8bsxvmOyCAJx9NnngKOnn)CTQzGxO8M1mQmKzLqldGV1ItYHoumutp94V3)YmYAwvd)oivVA(PGy10AOs(ropiwviwv21qk2r3XxEqRLd2mhsXyGs129LoqrAT9Goo86RBTQB8y6SL46BMLFuB5Pf(RFzs1bEsJN4jjkN5rh1L0lRlVDE7w3U6QRMf(yhwLFKHZnifgNkJewBPuPLhAxecgZheBMeswR3I7QS)B0JE(EVD)4)RWi0tOOShy5))]]
)
spec:RegisterPack(
    "Destruction (wowsims.com)",
    20261126000,
    [[Hekili:S3ZYYnoos(TOlQKwwJSSRsvxDhwveZS7Lz3E7zI2De9nPcMIYMJPivWh2L3WH)23eGVWBcqsjBPHhMPDrsKVqIejsKzQvxU6pwDZguQ3QF7Q5x9LlV8QVmF(8v3K(8EVv3Sh5(a6o4pcr7G)))lVK04m3u)OWx)(KNIEkXFxYm3ODtXF6ZbrOnyWDBMFq6FpC1TsHCYEp3v38N)1F)x)h)N)p)YMAqU6M793SXlFCEjU6W3V863tV371Vx8Sl2gf79Ox8RFFJ3wuwq6RF)V(p)1x)o84x)oluY8Vatbjx8ekoiY9Hl2Sp5cmfVj5ccXenJ8VM9VsIcN(rapXOWKaGp2a)DegV(jV(D0MnrHFa(Jh8EozgGeuk6xKqpt(F)7)baK7tt3N8lxCXD(P3NDlMfUG7tNcWeiB0TZ3oFU3N36(1pbG9xHxf4hEhaIOS0nry(zFwqqc8auiqrBYcVZlkeiKSeqEe4HIdXukWJ5F1EpaQUOyVYrCVhki9()cc4Fya7qHOx)ESNBeqdpdy8FeVXpef)CbEazi6rmwHVkzhki41VhMT7wmRfTfy7O)aJKNU3pWdtmXOBX)rkk(oVuyW3HXEswskYNqwB8UnB72ckHqJaEI9JI9t99WYXFh5J)m0oqTdp)feaIPIj79(HeG8Nr)5nGKRAKyY(FgGEgtuGK9wSCeKgjuIJ9XEjjzygMGz3OqyIgWnwLGa7eVapxYCC0(9rHEHPZaD64OTaJT6ger7jz2ESGcJGL5sX1BZask4JB8t2deWAqyV(wpGKx(P5F0F7Y8p(BZhxOSv89RrpI8diIQ)Bbq7S8IN8dcwNgTgO4h9F0ddPsaGcGhubUK0mIirnuI2Ug4V1Gswc6bVq1GQ8lwxkBKctyzjAV3AuCQFsQAGTd0M2bYWsGnEu5BUhfVP8PbEBgJvhMXa1zBIEkuo2tUhLM6fV2nlorIurpsWZrG(gwQNdGzz7ZFddy1G(858Kuq94JG(fiB3U(o3nlVetk5VC2dHWWhx8p27ME9YeV0uyfCYmQHVo)VhlOFONrSLSkvlPvjhXqO9gbaC469r431wrtne6DPJsIJva95dLakgT3FZ6yV78c9IrnshFzoTUTlkCDH95C1vrOPrNfgDO)Tar))5Xb0YhduF8(eVCyt9CcqhJ3Fy29(xpF2xw8Fq(h7q)OzuXXqlAdULJLnEiWURBKFWAyVEVWKcdKnRKjBKkv1Q)I89YgNgD3DbaHv(8KAJWyZkR9HzjeSxSfuDl0(o(Kv(Cx)riJNaBoaZhVu(69pUFD52ZtvA3huiwdJyJuIHDZhyG4TEkguURevg6lHJUDzIYcwd2mEqChMjLO(f6vNWG3dotnTajLdxNsCm4pe8rBp4s7kiqWyPXWcKoEu(CX7gLdDBWP2xRfuuXsB91cpjaK5EEtUftQvqR87wNG26zJzXKSD7G9026fCFwi4MbpIYF)y6Ld(HGdZHUfATWibh9q7a3Y1P1MJMhJ838ek4HgXtXXjsgNefevJi8Ek39CZ4XFNGeRabeqDBwCiwrlFfxZGljZ1n72SefWmffG9iFJh8p8DxdhlnDMxiEsDJu8LTxpXhEmqMBmSaQChMC3ZAqhl0ZBtc9agpkhWZeH1mVF45MLQz1lMtrX7Ie0ekrBUBX1FN2DDjZsp4hQcyLukn8Y3eJcnyaK7xXeLF)lsjl97mCBuaZPrWoK59J0muqLS1l8oyFGnmBeGpAVl5Ca2yok3uk2mVHOSY(yH52XJUnkjz8OCJJZ8twt(3v0qHpLG1IRVIYtZCRGGbVAzDfLuRnWbMcdW0uPFyM366H2itwAWnhuf2CVAXjdZlNbVnikAdShr8ZIhyrydTyKRpka03tsx)KFiO7mEcTb7s)xEzIbsKjJQPYO40144Su7prGh6rWvIQVPqQdC(0chmQPCnly9aQ5b0PgRLt15wiQGn5zRb34vAOfFU9YiD4fqI8qIHQNsi4XvNyaLK4FxO3M8idS8dLW(dJZJJ1mPyML8nXIsfyGN9qaiVdH)3HGbOHVitq)2oWep5HE4qXaLWwK4lFJ9eoXocaHT(XEgsZINajYtVZ03IcjK59OhJC5wwgbApXfRgYxLAajitSjqw5l5gpAcMKa3X3eLoJHs(2CfBScyEBa6UyWRddjOjf(nvS3kkeSrfG25nde9pSCXltkSB7dozHdNEH3bfZJvpn2BhmFKC9YpnT2Kdfpk14Hnt3LyYq2sj9XZoylOvBov906TMgzi3agrloHSmmSCUDCB(Sb2Jvd5xbDOAsBmfhuTl93wE1l6N5TJGDJIJZ2JFUHeSSfcLghQGLW0g1RyM4OEE9uh)mc3GTDobTBpCAYNlcJTWw0TKNR8OUCbo6UOWNl8PUqGW(kIF1IJdow4o5dJ8gfJIyor(WYFv(4enrbNHOuGqil9mI0xbhoAZZfUqWiC14Gedeo7f72OEsTc09zyhKclajG25o0pwZ(SR6GORsxingorsXwuEHE789aaZVjg1wy1u4YlLSwN4bqhxq3OOXm2wcxlX932Xdb47g(6lN)sXbRuBCQz21kfKB9GLwXpGVw6tSZxut5N1hDQyAMk4ifoBv5EsORp5YJk8cRV9DqVdb2PS1c70sw1vg8bjl(o)SGllM2vX7vNH4Y3zqa8hPrIwhD8pnVk64m74JdK(2O48WqnEeq8pIxOn7YzL0EnGHvrPr4l6eiNT(bbEXvGIjO86cKf5Qw6nPr1li3Tu1TPyGqIoowseCv8vrA)uiFiIWGOVv68AnpbMYbNxNOwu9czS7DXW)6flEzu(2gGx7ZT8CtvkvSxb0LZNB5QYCcd(pPj1Y6AvMfZB6cvUpkY0O9kdNYoh2eA5cVmtIr3At6DttYAl1vG6jSvvCsbqg1ufoSup8oiWQp5kgPeFpolfHso6D9qBJJs2F7edIFAXpnqBN8VtwkuC69S0O1O0uK7dT5S7nfc7OW7Y8yIDkTRKky)QdqacjSZTz7fJqDoG1LQqLFQ3pUhLLG)aBjd6V9bFYXu4PJAGZDrGcukJlrs5d7UuqtyaP3oOnEhBcsexnsT0RoWAZTkYSgGyZJhQbaRY3g(aKMFYvj8O6yJAZHTnH0uDCAjeLbhnw3PWvOA4V)(irNoTG0PGGsA3YZlzb2fpTJzhCYSJYyJNkMq0LkIgBbVd2hAbU42cskwAgm4KkJ)cQQZR(gxypIFvkDopiaMEp72D6qoT70BzYUZBq(R78wK16oVNYvDTeZHld1DE)Lx6nrsTiFGnhZh3Cq35qN55ohW8n35eklZvrRTqx6yrm9DsdBygL7CeYJCNdv2J78(nNXFBM0f3EP)YpCNdtwH7CiZfCNdAgG70h59TZriBVDo854TZBqMD70d5ZTZ7QS4M7yyBJCZsmneATlhUDoFZCBNZZ8125CmlTDohsWGkyll3SDuLr25lY7sgdDmYmBhv5J9bK8J738Y2rw2yFaj)EkRSDoC5ITZjrgy7CML31oubH0o1VtVSU2Pl5lLibDOY1AhM7vXUjfzk8V7Y0ANH8R(Tk)QD4V9PUREDAi0BwL0YCQU7cUk9G3Z5wDxmgjHNLDhLTIdoMzwTZ5y(uFwCiNIPuZZSP(XxGUL70D0gSKvvN7zoTIO92TSIZGubMso(gNV0odzjDxYsAN32CJ2PZ554zA(KYCm0H8G2CbxFKh0odz)Cxf6Ti7N7UTaMZr3tz6SZBw(n7CANvZQxezczl9wYA2hvtaT4kkQLpYYGz1r20a0jnEI2bIds2k7CILJYoh9mtw40iTdNhP8rwPFcMqQMKzWDB9SXyOTzCmmySzE)uVDjQn4lMUWofzwGV764mz5BQWqhl8K10qGgY7q)l4Cp4D0vMhNAPmxeidZ)NGsBs6hXTY(LjGGmWB9USGu)svOCJXbr3572iuVhMzkVJk8tRdU23w(PYJ4uMfXJNi5tYVoDW7Je)nE0XTxg6Opnm9j636F39PRlI4(3KE05S80Z0m4NF3yI3ggpdCP(l0QbUr7usXKba26PcwSV8Y2aEMPAnq)BnbD2TXMy41RLTF6lJO3rUkWo1PyudIn5BxBHiWnkkaBXlHHWfJbZ4j6cqZKjmAD)LftVqNI30RVuFaFgjB0GWyk4KUgAuXOEr9ATN8tV3pCX0MupByTndWAygZdfJJpXEuEgxnr1PcQVKw2dA5i(yWto4CoRt935n9BmZenWw1jPjdPqtJS3beZBWutJOR6jCH8rjQOPp6GWnH(eCFAXyw7CFzUoCxVLsjeL6)iLv0jQNxuDp0YNUKqwthlzQLDox8WJnGv(dgAsOo0yrrWzePFl90tDKPy9irCYWY8JvwGynzgU2aJGW8LIWckv4fbcVk8pRbNcwkpRM4VppkfldsxPjJMmXGpt48I0z1uLzp6ZBYK0q5Qv9r6hjfxvz5td4XG8ecB4hCUqjicJi)XhMA(8MJQe6QnZCSIk8ShVWGzQPbbIntWgssNZZEv5YwBM5Qj)J5S2XCzPbSEVoZj3L6LnK(nADUuLZGA9GuNBIJkD6L9L5z0YlAgiJlhxR1d3Psip6BcLNPYFNuUIoIf8dl)D4HHhuTxPxVOX5eH4Wi17hBMpuXthtwQYxonMdMiRYNLES56qcwEK5jJepmX0x4p5Uo3Uvt7AsiizupvC9ur)0rs0soqWyS1RPhPELK8ukJ8k8j8AJY3)MymGEyAJ0trCrRjHgNqpIgeSHYnHULEcU2Vkx7Yx1uH88wRJRxP4)Qy1SuvIu12fbANELn7wQ2)v7tCNIW4OzfPYrj5qLc5jcCux0EKRFkkLEwRs25OVaIo6sWlxCskc1KEIdIqJeHYJ6KT8rhLbC(yT8YX9wCVE7d8fR4MjeyV5YzTBXqt3mHaTTlT0XrxDvBxhmzszC0W)mopMo(SF(NNkgGwBJq7QBEemZa0f3Vw04BViH8BuD(pSZWF(BKFZQlQw7v)n4v8v8)QF7tZl)r7D1nmThGv34g7N6f7JG)QP(x0QuGA4qwju56Nr0WTeCs7Rryy(jDWmITph1mG573rym8zfyGPtf1mO7CFqctlluqlj0nWi10IEuAt)rctmFHJyO2rdRyXP0qQhFAsR5()s37CsyY8NuOItPExtuDQhbzMiaiPVAHKZVQfhzVWZVR9BjmX(Z6LFF(yj)OeeavD5C9K1xMlBzGPnFj1uI4aiudVD0YpNQXiPGEmQFkj)6EiyM3OkVCyrVtme0QYURS(xJDkUhNU(eHj4nTlr12u(6q1qOi0jVzFnZXnrN9hLv1ROK3SOieo)weu7xTPORpPL4ABxKIGCEd)viVSVqPEJY62lLX9xkck5nSRBIQQKkoqtpvqqxRNIq1nyH)Tr9I4WOkJ8uUNUyHXUNQPHvrWMkJ4LUwRAhLw0jRi4tL)W8T2kv416wCfbRQSCl0ZRmeTn37RiOvLB01ndRgWx(XPeBkweOR0Xy2UKvdOW(wzfb5kTYX0(Som4wLroXEHLPAVTR)ArigEZF1wnQ6Dvnrf5NeHRxxraoVvkwGJBKwnb7s(O7DKlfTKlYbs5TzjHMuxgj07M1u74sy7uCWCwDdjUyyFwXeJktA1DqkljW3(EA1yAQKRnEr4zvEexC1df7BCLWEXNKsdchZBsx1HxQJGV29SnUmYBFDKBtHKZ1(ViCm)UjQ448B85uIBBQ3GryF(T7SsPvwpUORjOdd5QYmL0HwzW6kcNXVx6HJZSiLGSJ7Ohkh3XVB9HJ7mipLSJRkhghhPAlF6UpML8PUUqgbN8Ecyf0LjfBvRgtJzw6VC1n01asX(YFM3jHkXDDjryjF1uVlRnnVSU29YiSkVliwXvkPoEMP)BEzw29YQNdlha7kLpR80Ev1IILYM20YZAzppJWa8EzyfXkBzNy2B0pn8mR7Gq0R)khc3SNPoCWKDx9GmsBMm12gdtB7mmhYULwBAxAKzME3xOtgrEtkZm0iN(SQywqVaGjBkjA5cnynm4QbC3L9Vd61AQTEqeCDYfojCSSQVUv0FvNwZIwT2HWsPPxUzDUqDkD8mU20gHJ59h988WOfQkIzAKQmFclBwOYr3U71tRAUBeAQtEKkzjCBBRBNj7LSqLNT6U3KU1RGmOXNrnj820t4iIgLxtU0B)RFeovV4eOzXX3FPmQDXrKSnC39xoFUzkIgSu38ojhHYuNKwrrstumljHMBAxcsvjw4F59xF7Ii9u5yAnu6bryB6eANOcvzr0W0wqhzcrzAuqFPtdZiDAgHpBSBykrvqx7jlmeCyQtTuD2o7WmglFrzCqRUQG8U5MmqBsJEQ8KuM1S7iKKYu5RCe1nOU2sv0FBp1f803g8imM(aqQCHSjmK0RTMGuLzBIw))nbNIl2Pwyt148iKHQSpPH4TBaDqaVQT8RdfCRGDF2Q9i0Prr9PvuQQqwiHgnj6d6c1bHtuURuDp1RJSIjDNpcPOYAm3rM6eXiEerZoUPHh)JWhQsWg9EEzctOPD7HX8pPpibDYYutOwL1ELBL2ulaKavEtTQ28SQhbkdtv12dbKMMJh0n)pTqDSWtyACGeKA6TEi0zbBMFAoS91FFTDkUMXwErnTg3s2Wl9129tiyvLbWYgvgnDGF3bOzesOd1rrUl9HqrBp4bWgTMFI3CvnQ5zh7BnHIeG67a)NuFn(S0HSMuODQefkdvfDog9FvDE6jigAl6L3YkiyxPxMYDiXMEJyBAoIeAQD3qnlmuFjXTUgM792KOU(KO11dkrIR2qGUoLOHArvL1kraRYtwdTGXqvk0dugalQMoiZmRQJa)YHQzmsitv2YRRrbPePKU04rSnnsOCvoVkloL9B)BKGEn7aOzQuvQ4iFg2UYyVpRJDzN(IEdWV2o)Cz09(5w6XklqSPEt61(ejb7T5wBmrfR20RWK5ln2bjxHtO5B2JRrtm)UAOe1hkr9Hsu)yvI1dLOEJyZubr6qjQpuI65Eg2CYluTPXqjQlBJ6wtzdLO(qjQFavViomouI6dLO(qjQpuI6PNWLOo3EETiLEKMaaAmBouy6)THctVMphkm93)CBRkm9kB9Yl9BR0PTQ(N7H6wpvs5OlWpSf79HJF6PQvpvsrOlWt1L69HJF6y9PNou65YnK241U)VZLEEjRQlT80WNkPxE27TVy0tphl48AnvDzROLlaftCX3QIqpDOmZBmrfF)uM58wCvMLNNRZeA0InknJnS4Y7SaTUGrpvkP8oBNtIuqw2c3kE64uM5Pdfs(z7Hhluget1hv5Eew2Csui59XEcsw7EgxF5PdLp(q5Jpu(4dLpU57gubQHYh)iiuhkF8tGze(KGEO8XhkF8HYh3mHOehusgkF8HYhV1c9cwzO8XnYZltyIMQH7wMol9bQpoLpEfuXPZPQR1uF5IRZKISFXNLb10MRXAj1RJ4EYSPaGqCGL1orn4E(bN7MyWNPnDaQlMt6TkzUD9CNZ6J7PxoYQU(7gqKbxGoUIwbpJvcIWiYF8H8JoPsPtvQo0T5nw5eEUtWbf6jMgegwn9AinDkn3P8Ms5HBNN3Qj9J6C2rDjPbmF)mVLQUdfiXqQ13f8KrQRLDfxek5DKQGVn1pV(OkRRY6hvwK7SVm)EzFr3p0Ym1d91sJCDzFbyQecKjE588v(lLYymJtBp7OWNRAIqMXwQjT2j5vr6JTH2u68jZp5hQjDzosif)1NePe1sC4qIplmnA6MPdk3)vrj0N4qumOOjxJ9SRQPmyXkvX7TR1ly0RMitlPCjYxBXL)u2Bm0Saw5WeNzB439FzRpSlXHFdKQn9dC)7dXQX5JT0RuFqSQqSQXu0XN1ltHL6UNu)1upE)2vpugcnPrF4DWSIIUAJQqSjT1W06fK64WRUQ1RDMmPS)EC1xMxChNf3VYN)5PITUgR7DnPk7PwwSlSA)LBNRxTEw4KZPxMWbYpU8xkQQF9IJShV9hzBJ7W))dpd0gr1JBkOXZQPHIyEaKPjOLEniReXzriokYb3tUb(wTM41pqEn8MO9hGljayzbjwAjzaA)A6rQzNzozwxcA4w(fLAzPweefehG]]
)
spec:RegisterPack(
    "SM Ruin (wowsims.com)",
    20261126000,
    [[Hekili:L3vBVnoUr4Fl5l(CA364KDDY2fXlW1wu0R9EdxoG9BwMwI2MNLffeLs2ue4F7Di1Bu8fjkBLSB2IIENJK4mpZWHdh(YdUfxU43xCxakfV4NVA6vxF5LxD90PtxCx6JX4f3fJ83H2a)icTh(N39thw(BzKOdlh)a9bgzpBIpD)58V7XqkkGlRvzKW0FiAXkJILfJ9xC3N((F7h)L)()5dO1Rdj(PeA0I72sccW5ndZ8TQRpCyz6w8HLfp7I10e894KdldWRrzHPhw(9)6pEyj84dlLerg5cUQzx8akjK6V7IGy2fCOgWUGT3lb(QjI)CYFWOrN)gqljOiwiybbWVPCTsyhwIccOrFh8JD4hztoS8FGsrFWaAg)t)WVdczBAAm7dxCXgs62SvCd4cLp9CqMaOrRMUE6u87w7)(3cI9hHxfsI2aIGMLgq5wtCwyidEakcquqw0gmncasgd8gHyusehPGrM)vXyqQ(OeCzl2IrHPB)liWbanypkcDyzc2Ncy4rqJ)ssajcL8yHEapi6EUwHVIThfgEyzu2(vCtJUgmB6VZvYdBjHyoysqR4)ifLSbNcnEdx7SmwkIiGvaEv261firGrqpjeAcjLG5(XFdr4FgApeTX79cdb3urxDmjsiKpr)0DGNRQLCy)RHOh5Gc8SR4(rWBWKChXjyglJBWcn7tJstOGUPrfYMHdX(I(yACmnchLobIMtORbdBXDirSjBEUVZBDgaKW3eqyXGA9axS3kma05VD6BiRNNJHpoDurmwX37HUhrcfoO)DHa)ZZV4bsyOxk1dq39K7X82x2mui8GkHWsZeMVABPR9alWdcJyOD4i7cO8l8kTEjjbJ0qXypuskHLAxe7HOK9GVPueJoR8nBrjbLpnehmI3npPHuNeqFiswNSTO0uCINFwcZGD3UO5(Ei6H7nZfWKS4830qSAknVhKLcDXVbIraV3AVn(bZVKdG8xozxe0Orf)rSF6TZz40uyuiBIuZ9Y)9iTE72HVBGPm0soS6SgW7evlynEXu(tow3qTegipHvi10z8UH1zKGIjbEj4n4iCcQtTF9u5ivFuKxrUZ8GpDPPfbcTjISca4)fRiQYhdinjMHZLO0ZfIAepJ9KTKBNo56z)jXFSh9zBkqb8Zognkl7amcY)5tjHEW8S4iwrkRUdzm1sRbo1Fr(mjJsPB2ecWP85S60I80aEeOFabZe2jwpIyPxkWK37mCQF0yiDn47FQ81X3h7vor45kzIHoAp47cmcHMtcab88PakAu(u1vPElLJE2EAwOhmgFNEM(XLk8j5XvasJHsuoVq0LnxpKmbQTaE16ND)zLeeASmLvHshDwU3(lCNU(0l2RwzMKUN7w1kC3maPy1KGfDwvYO878yO14UtzXY2VhMhznoCBwem5TQ4ZF)i5azseuuzKFrKh0sOaj0EO0v9iVCHFpLe8akCxNsVOqB2ignKwlEEg9npAt6K9A(KcXkeWQSKiEWs(ieBcHL57NTkJzrsPOqEDPby4pi(EWAYsNGJ4Drbg1swSjGg98Pc)eiGVmREEznDeNeHXbm5gm6SCXnrxwtWFg7NLQngJBvOK9uT(1sLLxWy93zywnH3FhjYMikrLSuYNUqs4CbKph9yRF)tgbJPSXROHPVzn1pJLxvwfSGYyWFondfw5fXrBGCWbnscZx2QVOQ4UtuKNqJNI1rfvLVQiP3OZwrzSrNLNSAcH5j(7knxu)fm2(2RKQklp)eKkQ2)wHK6EBfXuKqugLKOmSxDtTyALjaZfqroWRM9QXKLnRvHuAaKPo5r9Y31Mmjb5tqHq8ml17bseeDmASCQ0YAcEASd(HXNvJnAsQhFxcQN3gwW99Wu2vFtHVgS3ZlMiVg5AddXag2HETzq5OoFCFLSfpZdk(vjbjFnPLRyhhkwlnRyq(vogiAaUJQQYgXyKnr4G8v)o)7k1X3nkFNxMyebnbV98evngkbCxi4JJG))Zj8L1JUji)2EBcpGr7EUHFPo0HE5BCf2ICeq7wtsWoIu9Q4PytfPMpFbFE9JvW1JjQhgkL)7JZV6PI6kkMBcfbzacr7XW6LJ2nF25o4bGvOMKfZ)RbOhRS7OsMtsW7bxm725LLFu)kEAM6YsQFED26XfU1Nm345tDXar7JHQMFSy7W0scEKwAvLiRqrIip0gA0Jf1Iu4gA(kr9i6TdkjEV5MjEJLwTfDp13CZYFvE70cP41Ev6qeWQDdX4RGcidESijDdNR2epnA3aeE96WP3DijJeVLwS26t3RuafjH6A2pcS2e(jWmCGOuIAJ7RErJr9vp1(y(gn0Tr8hPzzkGlKFor3E50NmKNseiySegnVHO)451OLYJ7)iuEvbC4lYzp6ZEnF2v901yQhVk3sAcSkboqUhZxm)EcgeCDghrLEJkEFanvYfo)sdZy0WxDKtlmitWzWMBPVEGTah6XxHHCUj74NI5RSs7Rr(3GRvPOlvA3gYZumutmAiSSCLZgIo)wzkttBqA1gk2w2PY35Wo)Ewl(X6TA9TtR2Q1gLvX3v210K89lz0zq8398W3jxoPe71cgIntP8ZXcGZAsyioPsun2Hx9DCruZWG5dQEH4WgQ2YDhCnYB4Ib3vL1uCplk8kchxi9JLvfuBtqkqOUGX2DqpjABSpx(3oB2tNnUyTpIRwsXEPEEVcLAEIbxoDAphbMdm4FLYQ911bkZMAEp53sPPNGMgBONESzVHQpZqcS60JNwKKTSEvT4b(It5hOR4LNBDNzpEhZzJL1LyA2VnCvNRvVGCBDVGHtmYRXIQZsPEO0uK)UJzj1M37oA0MmCJtqrEIClgyv9xGBGxqrwS(wYLly9Bmq5hG)8wugtuIypvU83UJiQTtv71cx5mm0WxJPjnIExg14cSnEGgDV5vUiA9bosJsQ37QPwkrVNAZwX3gqHd1C3wn72w)(XbyTfRBaX2ly840PEzEUvXOB1WnqrMLfA0r(hTuzgLTLgBBngvqQ8EvQx2djYhfdR8ivCVvL7GA5GJoj52YI8of5YfgjfVN5GyBufAXjyNKz6I(PJiTN4jlbzjVh9hq1Z8PHTEb6AfzDEgqJD40CGQdC5ZA9qFYIHsfuZX34mvYNUFioDgJ6Q6qq6qpoCmkG8pxUO6wD82o9k7E0Mwk35Rn3OSNTd7Pp9pocPxpoFtN7MDRSw7VKo9xYbfoy6NKJxE3pK95RjB2M6vS93FC(1tBxmwUukglqRJibJ7Z54EFKCDy3wo7IXgkSrvrYVZbnzAB8h3RZzOdfiVNsJLx)3BNoQz341tnikdZTvkrhkgQLOHYYUR3tHM1ePJatfBRCNvREEVoazBUl3HwpVXIM2Npx841LTQTU6Nk21PBn8b8DDcmYf3bR2MbVuHnvHewktqGRCYpb)8Nfe6QyBdw83GxPE)px8ZVDAj1wwCxJll6I78tGQUsii4xDXMLfPaAuuwPuvy3ISClfNrwUWL5BBtM0MSEPBbRY(fUgENfn0G3kDl6tMvmCSmZcwyY0zXowAxL9HTmCWCTcyKQWLhyPe0iUDMYqRB2aC68OHdZBSeIlfExdQtIXiU5cai9(E45iveEP)opYPY(goy)RT7)E3lL)tYraO6YPTdRRNAAyGRuXXos0BGanQ5rl)CjAYybpoXUgZt1i0SAsvv)WSbhmc1AlVRj2m0Va3xgoajmc1u7gcTD1UEUOhKaNQP9BPpUlCoCiRI5qMPoKa4QtrinFvqbhGAfChlNIekxnXFLYlzjK9jkRjBKZSnsOs1e7T1rvDAHptDpvsOnIijqDhz4)YeEjky0wsEPYtNnZ5YtBH(scTzljEzz52Mr5i41KqF2QhwLOt20BVj8KqR2YCRXakhvB3mHsOwBLrxtnQo0x(E1RtrkH0TwyCtot1Hk6pXMek3AwUgKP65r32sYPZmkxJEpo2wjaJA6V6SgvmzQluKVsefMpjeUAwQMcNtRQUK9WXplle0sSGu1CwgWK9tQUJTkRzgs1Pt5BcWI7eBWeVMvoySLsRMpr9eGF5z40izuQqQlHnBRI4I9vQyEJR0Ml(vP3qyXQP0TT4L6Z1R15SD(2iE8xhX(CFevidMWIvNnXMfNF6OVMS2UykMW8vNURxbTMU)ZN6jI0aU2stzSPvjSUsyzQZL(8zz94my6N1j3ufRtD26NpRZHdgQFwvzZuSiBt5lZfTEANTXjnHoTvjq9boCQAu(gKu71BCwdDDydTSSM3DsLiykmO3NlMJ3O)EFL(LcCQAsZiM3PwsITu3nyJ1a4JA9YJFS3E8J96J)CYZTJHOBIEg1cN()hxExbZnWOs8SAXxNSxZ2TQRlqk1afiQwT0qbr3o4AN4kwpjlwTvx2aft(KQqYuOCf55EPyp3q7rSTlfYjQBqSor2yn62XfxTG7NF1uO0xbmVZ(SCch3jv0MblULOKHg)DgRyDwAxpIY6R05RPfzPWzpHfRwv53MlPSiur7ELWDbZoP6snePFSu57BKsdMDmhOWPrhhhi7MuNWxgEakCn2o7dZhl2W4CQEXRaccQsHREsrqHpwTYuLZ17YPtDlK0Hb9UZEqbYSEyqCMqmaqOpCLtZtBir6tFXOlNWD1Y1(QEF)pzN2Pr5WVUDJNRxTeZzAhk6dSFvggKqwHouR006wJutyX(PzHwSTLD1BpBoj9mjAxy9uzTSUXHrbKSTJEvTOM3HhlQK)2bICJTZUrUHDTAfvooY1fdY4rfkuQTYoAF)rDrN6JPLg)kXhsbmSnfFJfCEuWW2QLmapxwKuBRYsyjwVYeY74YjzkUqHsbuSnZPszONeygcUv2sj1c74iNsZfROfwxkuDVZK3fDmfs11C36lFSYmCK5Jc1586ZnEKVhLkDDbYM3sGJrL3OM(0MkRiaARAuisxp(bzMD2UDO9KgScvOu1uH2uQgTr72ESV9ZUW9ZHIIOVO0H7lcpfnvNK1JX(g774URK18fKkJdhbs)APNX(rWFJ9dgWfww(I2R8IoKYbJFi6zmFncUX(1(WbkOQxfeFJ)u0G9DX3yH0TPfRx3UBuNvwk4Q3hrF7(tl7B)nQtsRJGtKuRwQ(vgeV3((iFYuETw9MpMR33N9CDy5jRq9wVt3TxxBJ50FV11ByCbCUtFvtlBZnM121TDraBBRnXKR3Dq74TP)92wrrB7SPlDRTrg3ozJ7IuX)JVJnB5x(5)fEhjKCy54)zX)b9t86f)Vd]]
)
spec:RegisterPack(
    "Shadow Brand (wowsims.com)",
    20261126000,
    [[Hekili:T3ZAZnoUr(BXFrJ0XjYYEgn7CtznvL9sD1Tj7Tjv8w1(nrdrbjXyksv8H94RC5F7xdWxGGaGaKupSI(qY6rKOFHgnA0O7MZVz(Vp)(LOy88F72j3(LBU52VmzYK53h)Yo8873HCEeTg(dF0w4))(nOLbp)2d)CiYF5Bpm85GNJC3gn2jy7iYl)IxaAjbGlsC9I)f)5lec7ODyN53)h)5)5V(3)V(BFBjEBGFGxW6xMF)g3LlXPddh5OgHF7ThI3GF7HSF76vbH4NWHV9Ws8kuIx8Bp8N)h)6Bpa)8BpWdNe3Rjer01pJc9cCE86L7IUMq0lJUMqp2r0byVG8(JPpy8)kkWF0hbKc)wKhWvaGIdieHB0BpGwUmW)dWF8i(LOXV9WFbfJ(MaIB4)7V87aq2ehVl6BxF9A34njli8Z1CV6iaMapGwmz1Kj4pVY5RFca7VcpYZ1FnaIGK4LbeMBxINxe8duwBzI)ACGpqijrGWXdJc9jukWUPV1omavhuioFeBWiV4n)jeikGbSf5JE7HqStaqdVay8VhU01hf(sgEabk6jcwH3kAlYZ7Th8t2UGWAbRa2o43ji55nUEycXeIwq(Jyu4ACmm41eShLefJCPK1s8IKvRYOeknc4j0ni0n2ftKJ)tKl51qBb1qYKPNhiMYM5356tbYFe8h3dsUIrsi7)Hh6fcrbs2fe5iinIyeh7cXrrjegMIzNa)4Waa3b(zWoc7HDOZXb72f4J9JhdA4HbRagB(9iNyxqipEhrqrqWSuPO9QeGK8(4s3ODabydcB7fyGKN9PjF0D1S0x(7tgKP3L9(2ONqUEur1FTgOTMD9ZUEE2XGwzs4tUpHjqkhaip4hkaxuCcvKihkbRSb(ZguYIqpI9LdQ83Wox2ieMWQu0oSnkm2nkwoW2cAtBbzyoWgCv(t2GcxM)RE4LdiQdJRa1XWcrFXyhwLghJdTDscJeivuJeYCeOVrK6PayCYU0NubSkqF6CEumOE8rq)cKTRSx7SC2nesj9HJF0hg(GS)XoN47MfHJJHvWrJzgUD6FpOM(HAgXuYkxTKvL8QkeAVraahAVlG8S2kAkHqVlDKsCvfqFEFjGcr7CxAhIxJ9XHOgPJVmHv32b5BNzFovDTo0uOZcJ23Dbq0)FyoGM)Za1hUlcNcBMFNc0bK9hgVX9UjJ)Y0)d6)yl6hnJkogAABWTySSeJa7UobUE2Wg)y)OmdKnRKjAKsv1kFJ09YgehSEThqy5)EuPryIzfBxywcb7fBav3cTVdpzLo31FeYGHWMdW8XR5pE3t7SZ3EEKu7(eVZGrSuiXuDZhyGKTEYguQRefg6ZHJQDzcs8SbBgpwFhMH5O(v2vNWG3botnkdj5dxLsCi4pe8sR27s7ciqXyUXWmKo4Q05ItgLdvBWj3xRPmuXmt91ImjaK5oEtUztQfql)9SJqRWMywmkzlCGh7vyVnj(GBg8ik95dyxo46dom77KP1cJeC0dTfClxLwBkAEkWD5ZiVhBepzhNiAqeCwSser2tz9lnJh3T1KyziGcQfjH(efT0vCndUOehNKfjrsGzmYJ4ro9OJUo2WXuJhJ9jtQlfIVKDQjE)dbYCcHfq57WK6Ewd6y(y8Yi2bm4QuapUoSgJ)b2jjwXQxcNIc3guttihTPUfx(Ek31Lol9ORVmGLtPSWlDtmg0qaqQFfdL((VkKSuVZWIaVkNgH4qg(hXjiVczl2FnSpWYkBeqoAVd9CaMyok1ukXmVMOSW(yM52bxTiikAWvPghh7gzt)3f0qMpLG1I7ULXtZuRGGbVszDbLuQnWbMmdWSuPRFc2UCOnYK5gCtbvMn3BN(UH5fZGl8ccwc7re(s9dSuBdTqKJlYd03JITF21h0DgmK1GDU)lVoudjYWRkPYGWyBsCwk9NWdJEcCLO4DYK6aNpkZbJskxXcwmqnpIEVXAPuDQfIcyt)nBWnEPgAjNBppshypAKhI0u9uabpO4edOOi31(4LPrgy2hYH9hgKghRXcXCvYxhlkfGb(Th9a5Tp8)2hmal8RZeSpTdmXZy0J7lgih21j(8NyoHtTJaqyLBiwtAU(jqcWQDMocJcPHHaXTfQCKuSkewJa7fM7kDvVtsJyDU7jzcLQpmeVfqA0D3oEAHXtwYHX85WmE4vrVgXeXSjJms2A((Zz8h4FzyWtWepdeQ6fgjQ5EPH)a2apJZZE7Ns8iXgzHRhj6WunIcoNfEYzCM3Q98nXrrnz7AAuLghlThZS543ND7RzIQmAfMQTx5H2Ihd01JZMAgb7eegMSJ87AsWIw2MVMSawf6EZY9JT8reXAP)TL)U8jfUbB6CcA7o4qCVKf94A7m2sEUWr2fiFQHi06a)xYCLntGu9ru3zRpo40yBfpm6tKmQnONcCepS0hLoUAQxex3ZfiuYsnJi8rWzsw(s2o3veUk8lPceo7f7MOE6ch(KCnJDqOKrj5qQ2QVIhuzTxXVkFLxLbA66odzmrt2EeB93DZKxfyVGoji0RYAYJkBeSVzBglQoVa((MryrG1MTOFyx93UvtHJOz9I12XHWb7iKYtysCC26IbaxUIN6(9GSNVmiMrio7gb2URiTAPb6gfn6X2c4AfZ39mpy0S(cmy)l8raGV3o7vjLFwFSYSPzwh8Owq6VTReOSMh6db6SNFBKjkI6frBwL9R8NPX1hCLcjAzS5)0KIyZxXXhsy8xfeMgeSbxbe)tev5X3moN2lbmONghqUMvGCw565HdlavLReqvy0Ox0tVjnkEa9MTkUlhnesSrrtGGRGVYs6Om5dve6f89CVik5jWyj4hXq5IQxPJDNdb(3nD6RxnuJJ3nQLQBvVAQBMmXW1RPKm8FIJkNfkvMMoPPl6ztqGUNYveohkqByOEsmE5SatHLgA7M2Nm7NfJ4zYbrjzRa9HJ6Ta3lsKD1qwSs3o)8uioApeHIoPTk5i2jXb2O4yKZJT5a2nfE3a)1j4kXvK1vcjSFHxHGqI4CtzWI4bSQ0Oj)vX)ydkjI31vDid239rxQVN80rjW5UKSAuALnSfYhMTUthgq4nNzs4V0bj1x0XScRm6xtm5Gf6GxzhDqa9OXjguDIdjsm3DBcQ7PGbKodeKs7g6KRbyVUlQ65TRE(FAwm11HSZ9nQymDmi7YnD0HvC8ezJ2FRzuxiw0amcj5Y84wJfFxvFff79Sxdu9EgvB1H8O2Q3YEARJqotBDmYuARtP8JwjXS)YkARtVCHUjsQf5GQ(y(WM3Zw77SD2ApMJZwVJYSzz0Al0LouetFNOQAMfZwhGCx2AFLXYwNU5P8XzsV(2l9xojBTFYezR9z(hBTxZ6yR(ixJToazyS1(pVITocztSvpKdXwNuzom3jBwf4KePBOPAxEdBD(MTWwNN5iS15yMbBDoCXTfWwu(aBjllGtxK3L0R4qKnWwYYb49i5h2V5cSLOmaEps(9uMaBT)Y)xlUiuAMWOynxhdm5bo7F70ESAClDNM5(R17Jm(1QsqAntFur(gE6KVVwxYY3Jvw(AXFpsDx969HqVzvYIeGT7IKtMm8T9SLOj63j53RLXz1RzIgrZ4fRPpLZU3USXIaEwXCDpZbAmJF(LrVNfhhmBkTwku1xBijqT8CplELed6ULQBAKwQmYXJCU7ADjJD3pzSR1XnpDT6C(oEUMyPYo4E7fuxYjxJJCqN0mRC43Ek)BToAzDR177CTv(QiDiBH3XuZbzshqxFHdZQer5vR17SSP16GNdT1CWSD48aL5S8rJ2qIDVMVSDBvJozjRiZSANBSWGjgtDJXBJKBwTEkTALD73athMikNiRn0b1(fBwiWc5TO)f4fmz7rP5AOskZbbYW0)jOVhf)rsl)Eweii9W2Bt8IDZ1(sn55fS21PrOUbMzYVhfYVwgRIVp7t5o8MNPRdgk4vsVYxyR8i3Ly2qAlcDSNnI98DRCxVj2ol4yFx4bPsstHq1Wx293mC4vc1Qt29AtxcZOMVfM6ILrVYlxAqWOC2nBEDzqC5SAvuo7M2a(kAnkG(3Bf0Dcc8iwnIsNa4SgwEU5bdvDO6HdROB8NMo6AvQhJU7g1hs)krJozh4D4RQOrjJ6v5RiE2nEJR)0rnnZZzivhVSfDNAfk4cVvTs9CHpoxDpxaW7xSLGFh83bWVDS7w8OrQVXUgKanydQI4SLl)frEz6xTKL)Ef1Yg4WYCFSk1WAqPYn6u7MCBeDLNtQAmlKIkzrrAi7j4(0Kbvnn)LjQWD5UG5qudxguSQi3X5YOgu1ZH6uGi3L5se4IF3ORQvM4sFsZW0avuK90rIpqHYEwCMUtKoFqumtzB1GFfZeN8o83WcZsqnYkhyJ0HA8A1oyhBY7uytM9GHvYnMu759rw2iexfjZsd4rJ0HHSR0GRKls8dO)XhgP)8MLS8wQnZCvfvKzpEHrLPMgeiMmbRjjDop7vKYwTzMRK8pKZAhYLLAW696mNyxPNj9cTu6ZRmFuhW)G0qqaE)v1TP7M2iLzP8MXR46u9ydbiu4b2ydFu(X16(PJKZbfj0Go0FrUdiJ6lZkbdP9ARFpAQbkpgDw8QYpOuJuTLSCeOJQekNRLtlIYELom5YW)fhuDMSBzx9buL(m1NSv0SB(bX(Q530C2zyLtmYp5RaNwRDXMU(oODih3y6hwT6Yol15H)bxcEZ03LIqf5UYfrOwIq(4Pykh0rUNBR4z3O0ChlHx5q4TDYwfhD7TTDMz4W8tos(croGncbF(2r1drGPXiy(9pbk(aDX9HOKemXi6haZ0pzKWF(B0piMzbcB(pdpIVuoN)BFAs(xaW53xPUpNFVtOBmo0fb)vtnMI5Xa1WHSCOY1OkyHBo4e2WkiW8tQGzq1gyrZaMVrwqWWNLGHkTGIMbDNBWfeAzQeAjITZuiNwuJstA8feI5lCedJnwIIfNsdTqlzjTMlS)U3smiK5pjrfNr9UKO6uZFqpraqsF1ajNBrVRWCHNBxBKgeI9)uT87Zhk5hJGaOQBMOMS(Yerld0TRAiNsQpak1WBhn)1z64fsOhTAugIdWjfZ8gv5Ldt7DIHIwz2Df1ycmtX9W0opOmbVPDbQ26Yx7Ro9bLo5n7RyoUj6S)OSIMaI4UacLW53IGz)kIBLWaxQK4AB7bHICEd)fipVHFiFJYY(gI2noekk5nSRAIQiRu3ttpfqqvpfHs1nyH)4OErDyuMrEg3tNovB3tv0jsOytMr8CxRLTJslArju8jZFy(EwIm8ACVlHIvzwUR1mt0eTn3utOOvMB0LD5KgWx6XPQ3TtOqxQJXvB)jnGcZ7rjuKl1kxL(IY(b3YmYvVjNOR2B7ACkuIH38xPvJIMsstur6jr4AIjuGZBLQkWjDiLMGDoF09wTIKETc9aP82SeqtYZWz2DZAQpRuB7usuAMFpnIUeFwjeJmtALTgedjWJFZkzalvY1FwO8SmpIZcdE2(g3wBV43LsdkhZBsx2HxkJPSY9S1UQ3AFzVzsDVX1xxOCm)UjY4407G49e32utFHY(8B3zKsRO6STRxjDfYvMzkHdTWG1TuoJFV09hNzWLGBg3XouoUJF369h3PXnZBgxLpmoos2w(STvgd5tvTxgko59eWiOxS0UJPWFB6SmTO1YWSjpZGQoj85o5Yrltr2mHIWmGLQzPmjwfit0U6X0WVNplZVNYmH0qPuB6xnnLfKY4pcdW7eJreRilf1tHG(PB1yC3fGX2sXq40N11FMknKLEqgPSo2BBHS32kzFF2QBAtVUHoZW731)(iYBszUcnYPp37URXNhoDVr4yytHPKVZhahl3j)4ePNu0KCouDjN(wIinsnmwbRK6DutD1ARoeWvcyZKRIuLob6WoY3cHk44DX0iwwahRqlPVP)g1vKUfiVpUspsFroo9E6qUC9MhchpL3j2ZZJ0NPQuRAsOIaEVw7QMEBBzpNj77ov2fSO6cD6wB0qJMAdZKWXPF)qfnsV)EHxlz)iCkEW7GgbeFRxPJTciQmVH0n4Mjt0tfvdJa63LGOuM88kliqyUTzij0LEGtTzcbgAF9O1gCOIVgsZH04t0zHy)2AHoTfRJ6uaIiZjsZ(J(rLMIdDZJpMgtKzyMIfzx8zz40tBgpIaToDqKCFF1RxfriPVW7RwnsQS)c1wQI9D7PMyK6UyeLXuh3qPRK1HHeE1UuKknpqugSsDWz910mRFz67ruYqMlbvoGARidzNUsa5PZHQuDQmkNinxtkBWrDKv0Pvjrjfz7SY52ANiM6UPRNl)A6coLpKUfxLBLODSX(O7krjA57b05vZkA7suul7EXKU9tt9Jjku1nQafnSjryQOMriG8N09y3SDIjLqDqTFPsxCIIuEZSYqAT28uZ8tZxCs57xAIJRN7KwSm2KoVdXQHY6iNIvz2oZ7glS0b5z7HodfLoKhF(U0uOQB2ImGQh2(NKhKBf9lQ9vdJsNAIwMrSkCL84yxfRI6zuMPFLPzvuLUu0lpHb4y62JEXfeof7YJ8ARlrYEVfuPQhuzCX9r62bTSluPP0UOgfPcyzU2lzdkDozxRANvNy9ZkIS5RYoJHMMuRmJjbfYJ3QI2(Z(RjxPJbPVk7WcLzMVy(OE3X6a2ESOuUS9iffQR(TVzrrV0dfO2zWQAmkkatbhvt)2zLOdOPxN2QPKmHs2Y8ExKOxFIwZ6C4RYCdxvmo1zADGQvPn1DUMtsD273L)f8F(LIH(sXqFPyOpufZ7LIHUrSPRGi(sXqFPyOP0Sg3gTyNlOmXLIHUdu2LIH(sXqVhvVOomEPyOVum0xkg6lfdD874IHMBpVwKzmcVgDfMnVuc0)8LsGUKpVuc0N(CBRkb6cB9IlYyJ0PnQsB7HkKowqHpxJFQwwX7p(PNQl6ybL7CnEQSOI3F8thRe64tKICUyNZgs4gnsJXUMFnhQsFowqPn3DhiA5DOQ6gsP6pkVKZUMoRNFf0CHTaLzxOHgbQNOHhRICo(szm3yIfE6ugZfEh2uwzEUotOqlwMJwLL5ANftze2rSCMJfuYYDKrfPoCYxeZX9CHkBKetKQX7VYtUZBSjqkOqNOV5jvAg6M(Xxkk5tFUT1fLCFSxPav8Z4Avo(sPiFPuKVukYxkfzJurLzuUyexkf5dIy9sPiFPuKlF3lLIClXz910mRFVukYTNvUukY5I0lLISOTgoqLISMmK6Ipw96CXFPufb54MRAxb17r9DZQEfY1I5LO2WNg3tCF9Pz)G(rG(e5Z7nrTr6vjj5QY7282r7dZE)9Lz)eAUt6o78WTZZBhLpl7h4LKAW89Z8wS8YuxGH0Yzh11c((9BYTupCyRNw5TlI()dZT493Q0o9BMAAXhNBrxLfdwj7txuv6cMn1pM3nu4)sFydTmarAjA(T9wXNv5w(17T2SAdFxLfPKzwYjEeKQn95A(0qSQB(vi(6OUiwLiwnSq5p8IdD(QGtdxLb35stnTe5sFvCi5JeElN52VFLWtn7lP1VCq3rV6C5DtB322I2yvp)h7428d6q)hsH7Wm5CIzCH5UhOnhq1zIPHqEdP2v(FWp665(2dd)VdiPkzy6lm)))p]]
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
