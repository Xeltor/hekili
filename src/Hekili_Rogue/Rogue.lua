-- Hekili_Rogue/Rogue.lua
-- The Forever Rogue (Assassination, Combat and Subtlety, one spec a talent tree: Hekili:NewClass): the Rogue kit with
-- Forever's spell data (ranks, costs, cooldowns and durations from the Forever DB2 at build 1.60.1.70338, wowdb; energy
-- costs are DB2 points), Forever's Shank, Death Mark and Mutilate, energy and combo points as the Druid's cat has them
-- (combo points plain in combat, measured), Adrenaline Rush as a regen multiplier, Stealth and Vanish from IsStealthed
-- (unprobed, so the belief also models them from our casts). The defaults are the "<Spec> (wowsims.com)" packs,
-- generated from wowsims/forever's Rogue APL and this fork's leveling and PvE extensions
-- (tools/wowsims/specs/rogue_*.lua; no in-game check yet). Research: docs/research/2026-10-15-forever-rogue/research.md
-- and the class-completion research §2.
-- Talents: the DB2's Classic nodes and the Forever-only ones this file reads, as the 0.7 re-pin's rework left them
-- (wowsims/forever at 4b0030a44b: Venom, Cutthroat, Thousand Cuts, Murder gone as they were; Shank, Death Mark, Boot
-- Knife, Flash of Steel, Composure, Blood Splatter, Quick Getaway new; Improved Sinister Strike is Efficient Strikes,
-- Improved Eviscerate Coup de Grace). A modifier is the rank curve wowsims/forever's spell store states (the
-- generatedCurves of sim/core/spelldata/spells_auto_gen.go), else rank 1's value x the rank.
-- Credits: Hekili (registration API and pack format; the `stealthed` table and the stealth-breaking runHandler hook
-- follow Hekili's Classic profile, origin/classic:Classic/Rogue.lua). wowsims/forever (MIT,
-- ui/specs/rogue/dps/apls/default.apl.json and sim/rogue/) is the reference for the priorities and the Ghostly Strike
-- and Preparation rules; no code is copied.

local Facade = Hekili.Client
local UnitClassBase = Facade.UnitClassBase
local IsSpellUsable, GetItemCount = Facade.C_Spell.IsSpellUsable, Facade.C_Item.GetItemCount
local L = Hekili:GetLocale("Hekili_Rogue")

if UnitClassBase("player") ~= "ROGUE" then
    return
end

local state = Hekili.State
local max, min, HUGE = math.max, math.min, math.huge

-- The class kit and one spec a talent tree (ids the core's: Assassination 100041, Combat 100042, Subtlety 100043; the
-- client's one pseudo-spec, 1488, only keys the legacy profile the core migrates). Icons: the DB2 talent tabs'.
local spec = Hekili:NewClass("ROGUE", {
    supportsLeveling = true,
    specs = {
        {
            key = "assassination",
            name = L["Assassination"],
            tree = 1,
            icon = 132292,
            role = "attack",
            nameplateRange = 5,
            package = "Assassination (wowsims.com)",
            fillWindow = "energy", -- the forecast window reaches a full energy bar's regen (upstream Hekili's)
        },
        {
            key = "combat",
            name = L["Combat"],
            tree = 2,
            icon = 132090,
            role = "attack",
            nameplateRange = 5,
            package = "Combat (wowsims.com)",
        },
        {
            key = "subtlety",
            name = L["Subtlety"],
            tree = 3,
            icon = 132320,
            role = "attack",
            nameplateRange = 5,
            package = "Subtlety (wowsims.com)",
        },
    },
    gcd = "totem", -- the Rogue's own GCD (a wait, gcd.max of an off-GCD ability): the 1 s of its strikes
})
if not spec then
    return
end

-- Rank IDs, lowest first (the DB2's).
local SINISTER_STRIKE = { 1752, 1757, 1758, 1759, 1760, 8621, 11293, 11294 }
local BACKSTAB = { 53, 2589, 2590, 2591, 8721, 11279, 11280, 11281, 25300 }
local EVISCERATE = { 2098, 6760, 6761, 6762, 8623, 8624, 11299, 11300, 31016 }
local SLICE_AND_DICE = { 5171, 6774 }
local RUPTURE = { 1943, 8639, 8640, 11273, 11274, 11275 }
local EXPOSE_ARMOR = { 8647, 8649, 8650, 11197, 11198 }
local KICK = { 1766, 1767, 1768, 1769 }
local RIPOSTE = { 14251 }
local AMBUSH = { 8676, 8724, 8725, 11267, 11268, 11269 }
local GARROTE = { 703, 8631, 8632, 8633, 11289, 11290 }
local MUTILATE = { 1310707, 399956, 1241582, 1241584 }
local SHANK = { 1329283, 1329549 } -- levels 24, 44
local DEATH_MARK = { 1316709, 1325756, 1325757, 1325758 } -- levels 40, 48, 56, 60
local VANISH = { 1856, 1857, 1285372 } -- 1285372: Forever's "Rank 3" (checkpoint Q12)
local STEALTH = { 1784, 1785, 1786, 1787 }
local HEMORRHAGE = { 16511 }
local GHOSTLY_STRIKE = { 14278 }
local ADRENALINE_RUSH = { 13750 }
local BLADE_FLURRY = { 13877 }
local COLD_BLOOD = { 14177 }
local PREMEDITATION = { 14183 }
local PREPARATION = { 14185 }
local CHEAP_SHOT = { 1833 }
local KIDNEY_SHOT = { 408, 8643 }
local EVASION = { 5277 }
local FEINT = { 1966, 6768, 8637, 11303, 25302 }
-- The poisons' items (ItemSparse), best first.
local INSTANT_POISON = { 8928, 8927, 8926, 6950, 6949, 6947 }
local DEADLY_POISON = { 20844, 8985, 8984, 2893, 2892 }
local POISON_LEVEL = {
    [8928] = 60,
    [8927] = 52,
    [8926] = 44,
    [6950] = 36,
    [6949] = 28,
    [6947] = 20,
    [20844] = 60,
    [8985] = 54,
    [8984] = 46,
    [2893] = 38,
    [2892] = 30,
}

-- Relentless Strikes (14179, rank curve {4, 8, 12, 16, 20} % a combo point to restore 14181's 25 energy; wowsims
-- rogue.go:107-114 ApplyFinisher: chance x points, one proc, only on a landed finisher): the energy only when the chance
-- is 100% (rank 5 at 5 points). A lower chance is a random resource proc, never an expected gain (owner L1397,
-- 2026-11-25): the reads find a proc that came, and the belief's `mayGain` keeps its regen pins from learning one as
-- regen (L1832, cp-fact-4). The belief takes the gain back when the finisher is avoided (its `now`'s gain,
-- Families/Now.lua undo). `talent`, `gain` and `mayGain` are the caller's: the sim's state or the belief's (a
-- `handler` passes no `mayGain`: the sim books nothing).
local RELENTLESS_ENERGY = 25
local function relentless(talent, points, gain, mayGain)
    local chance = talent.relentless_strikes.rank * points -- 4% x rank x points, in integers of 4%
    if chance >= 25 then
        gain(RELENTLESS_ENERGY, "energy")
    elseif chance > 0 and mayGain then
        mayGain(RELENTLESS_ENERGY, "energy")
    end
end

-- Improved Expose Armor (14168): the energy curve {-5, -10} by rank (the old rank x 10 priced rank 2 at 5, not 15).
local IMPROVED_EXPOSE_ARMOR = { [0] = 0, 5, 10 }
-- Efficient Strikes (13732, Sinister Strike and Hemorrhage): the rank curve {-3, -5}, by rank.
local EFFICIENT_STRIKES = { [0] = 0, 3, 5 }
-- Composure (1329265, the rank curve {-5, -10}): joins Poised's own discount, on the abilities the buff names (wowsims
-- poised.go). The -10 is the cost modifier below; this is the talent's part, a cost step the abilities' `spend` takes
-- while the aura is up (`buff` and `talent` are the caller's: the sim's state or the belief's). `mult`: a percent cost
-- talent's factor (Dirty Tricks). wowsims applies the flat modifiers before the percent ones (core/spell.go:1056-1058),
-- while the core's Poised -10 lands after `spend`, so with Poised up `spend` returns (cost - Composure - 10) x mult + 10.
local COMPOSURE = { [0] = 0, 5, 10 }
local function poised(buff, talent, cost, mult)
    mult = mult or 1
    if buff.poised.up then
        return max(0, (cost - COMPOSURE[talent.composure.rank] - 10) * mult + 10)
    end
    return max(0, cost * mult)
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
local knownRank = state.knownRank

local function knows(ids)
    return function()
        return knownRank(ids) > 0
    end
end

local function plain(value)
    if not Facade.issecretvalue(value) then
        return value
    end
end

local function pveInstance(instance)
    return instance == "none" or instance == "party" or instance == "raid" or instance == "scenario"
end

spec:RegisterStateExpr("rogue_pve_context", function()
    local _, instance = Facade.IsInInstance()
    return pveInstance(instance) and plain(Facade.UnitIsDeadOrGhost("player")) == false
end)

spec:RegisterStateExpr("rogue_can_recover", function()
    return state.rogue_pve_context
        and combat == 0
        and plain(Facade.UnitAffectingCombat("player")) == false
        and not moving
        and not stealthed.all
        and not state.rogue_incapacitated
end)

-- Unit tokens keep this scan useful without storing restricted GUIDs. Unknown token equality cannot prove a
-- second enemy; range and engagement must both be positive before a plate adds to the cleave count.
local rogueVictims = {}
for i = 1, 40 do
    local unit = "nameplate" .. i
    rogueVictims[unit] = unit .. "target"
end
local nearby = { at = -1, count = 0, pressure = false, otherPressure = false }
spec:RegisterEvent("NAME_PLATE_UNIT_ADDED", function()
    nearby.at = -1
end)
spec:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function()
    nearby.at = -1
end)
spec:RegisterEvent("PLAYER_TARGET_CHANGED", function()
    nearby.at = -1
end)

local function engagedMelee(unit, victim, probe)
    if
        not probe
        or plain(Facade.UnitExists(unit)) ~= true
        or plain(Facade.UnitCanAttack("player", unit)) ~= true
        or plain(Facade.UnitIsPlayer(unit)) ~= false
        or plain(Facade.UnitIsDeadOrGhost(unit)) ~= false
        or plain(Facade.UnitAffectingCombat(unit)) ~= true
        or plain(Facade.C_Spell.IsSpellInRange(probe, unit)) ~= true
    then
        return false, false
    end
    local onMe = plain(Facade.UnitIsUnit(victim, "player")) == true
    local threat = plain(Facade.UnitThreatSituation("player", unit))
    local onParty = not state.solo
        and (plain(Facade.UnitInParty(victim)) == true or type(plain(Facade.UnitInRaid(victim))) == "number")
    if not onMe and not onParty and type(threat) ~= "number" then
        return false, false
    end
    local pressure = (onMe or type(threat) == "number" and threat >= 2)
        and plain(Facade.UnitCreatureType(unit)) ~= "Elemental"
    -- Cast observations cover the selected target. For other plates, nearby aggro is only a pressure estimate;
    -- the facade's absent cast answer cannot prove they are not casting.
    if unit == "target" then
        pressure = pressure and not Facade.UnitCastingInfo(unit) and not Facade.UnitChannelInfo(unit)
    end
    return true, pressure
end

local function nearbyEnemies()
    if nearby.at == state.now then
        return nearby
    end
    nearby.at, nearby.count, nearby.pressure, nearby.otherPressure = state.now, 0, false, false
    local probe = SINISTER_STRIKE[knownRank(SINISTER_STRIKE)]
    local engaged, pressure = engagedMelee("target", "targettarget", probe)
    if engaged then
        nearby.count = 1
        nearby.pressure = pressure
    end
    -- Existing plates also count after reload or late activation, before any ADDED event is delivered.
    for unit, victim in pairs(rogueVictims) do
        engaged, pressure = engagedMelee(unit, victim, probe)
        if engaged then
            if plain(Facade.UnitIsUnit(unit, "target")) == false then
                nearby.count = nearby.count + 1
                nearby.otherPressure = nearby.otherPressure or pressure
            end
        end
    end
    return nearby
end

spec:RegisterStateExpr("rogue_melee_enemies", function()
    local count = nearbyEnemies().count
    return (state.max_targets == 1 or state.toggle.mode == "single") and min(count, 1) or count
end)

spec:RegisterStateExpr("rogue_pve_target", function()
    local _, instance = Facade.IsInInstance()
    return pveInstance(instance)
        and plain(Facade.UnitExists("target")) == true
        and plain(Facade.UnitCanAttack("player", "target")) == true
        and plain(Facade.UnitIsPlayer("target")) == false
        and plain(Facade.UnitIsDeadOrGhost("target")) == false
        and not target.is_dummy
end)

spec:RegisterStateExpr("rogue_outdoors", function()
    return Facade.IsInInstance() == false and Facade.IsInRaid() == false
end)

spec:RegisterStateExpr("rogue_engaged", function()
    -- Forecast continuation belongs only to this prediction; live engagement is re-read on the next update.
    if buff.rogue_opening_engagement.up then
        return true
    end
    if plain(Facade.UnitAffectingCombat("target")) ~= true then
        return false
    end
    return (target.is_boss and state.encounter)
        or target.is_targeting_player
        or type(plain(Facade.UnitThreatSituation("player", "target"))) == "number"
        or (solo and state.rogue_outdoors and plain(Facade.C_Spell.IsCurrentSpell(6603)) == true)
        or (
            not solo
            and (
                plain(Facade.UnitInParty("targettarget")) == true
                or type(plain(Facade.UnitInRaid("targettarget"))) == "number"
            )
        )
end)

spec:RegisterStateExpr("rogue_melee", function()
    local inRange = plain(Facade.C_Spell.IsSpellInRange(SINISTER_STRIKE[1], "target"))
    return inRange == true or (inRange == nil and target.within5 and not target.outside5)
end)

spec:RegisterStateExpr("rogue_field", function()
    local _, instance = Facade.IsInInstance()
    return instance ~= "raid"
        and not Facade.IsInRaid()
        and state.rogue_pve_target
        and (state.level < 60 or not target.is_boss)
end)

spec:RegisterStateExpr("rogue_sustained", function()
    local _, instance = Facade.IsInInstance()
    return plain(Facade.UnitExists("target")) == true
        and plain(Facade.UnitCanAttack("player", "target")) == true
        and plain(Facade.UnitIsDeadOrGhost("target")) == false
        and not state.rogue_field
        and (
            instance == "raid"
            or instance == "none"
            or instance == "pvp"
            or instance == "arena"
            or state.rogue_engaged
        )
end)

spec:RegisterStateExpr("rogue_outdoor_opener", function()
    return state.rogue_pve_target and state.rogue_outdoors and not target.is_boss
end)

spec:RegisterStateExpr("rogue_planned_pull", function()
    local _, instance = Facade.IsInInstance()
    return state.rogue_outdoors
        or instance == "raid"
        or (state.rogue_pve_target and target.is_boss)
        or state.rogue_engaged
end)

spec:RegisterStateExpr("rogue_durable", function()
    local kind = plain(Facade.UnitClassification("target"))
    return target.is_boss or kind == "elite" or kind == "rareelite" or kind == "worldboss"
end)

spec:RegisterStateExpr("rogue_stunnable", function()
    local kind = plain(Facade.UnitClassification("target"))
    if state.weapon.size == 0 or target.is_boss or (kind ~= "normal" and kind ~= "rare") then
        return false
    end
    local guid = Facade.UnitGUID("target")
    return not Facade.DebuffImmunity("cheap_shot", guid, now)
        and not Facade.DebuffImmunity("kidney_shot", guid, now)
        and not Facade.DebuffRepeatBlocked("cheap_shot", guid, now)
end)

spec:RegisterStateExpr("rogue_behind", function()
    -- An already-stealthed player chooses their own approach. Unknown facing is not a reason to withhold an
    -- opener; a visibly engaged enemy targeting the player is the exception. The explicit override still wins.
    return settings.behind
        or (stealthed.all and not (state.rogue_engaged and plain(Facade.UnitIsUnit("targettarget", "player")) == true))
        or (
            state.rogue_engaged
            and plain(Facade.UnitIsUnit("targettarget", "player")) == false
            and plain(Facade.UnitExists("targettarget")) == true
        )
end)

spec:RegisterStateExpr("rogue_mutilate", function()
    return action.mutilate.known and state.weapon.dagger and state.off_hand.dagger
end)

spec:RegisterStateExpr("rogue_garrote", function()
    return (state.rogue_behind or talent.dirty_deeds.enabled)
        and not Facade.DebuffImmunity("garrote", Facade.UnitGUID("target"), now)
end)

-- The sustained priority manages its own Vanish windows, including after the forecast's initial opening attack.
spec:RegisterStateExpr("rogue_hold_opening_stealth", function()
    return stealthed.all and combat == 0 and buff.rogue_opening_engagement.down and state.rogue_pve_target
end)

spec:RegisterStateExpr("rogue_opening_attack", function()
    return stealthed.all
        and state.rogue_pve_target
        and state.rogue_melee
        and state.weapon.size > 0
        and (state.rogue_field or combat == 0 and buff.rogue_opening_engagement.down)
end)

spec:RegisterStateExpr("rogue_field_damage", function()
    return state.rogue_field
        and state.rogue_melee
        and state.weapon.size > 0
        and (state.rogue_engaged or state.rogue_outdoors and (combat == 0 or state.false_start > 0))
end)

spec:RegisterStateExpr("rogue_danger", function()
    local enemies = nearbyEnemies()
    return combat > 0
        and (enemies.otherPressure or enemies.pressure and debuff.cheap_shot.down and debuff.kidney_shot.down)
end)

spec:RegisterStateExpr("rogue_high_threat", function()
    local status = plain(Facade.UnitThreatSituation("player", "target"))
    return status == 1 or status == 2 or status == 3
end)

local function shankRefund(talents)
    return (knownRank(SHANK) >= 2 and 25 or 15) + 3 * talents.flash_of_steel.rank
end

spec:RegisterStateExpr("rogue_shank_room", function()
    local refund = shankRefund(talent)
    return energy.hi <= energy.max - (refund - 5) and (not talent.boot_knife.enabled or combo_points.current <= 3)
end)

spec:RegisterStateExpr("rogue_shank_finisher", function()
    if
        combo_points.current ~= 5
        or talent.boot_knife.enabled
        or state.off_hand.size == 0
        or not action.shank.known
        or not state.rogue_shank_room
        or min(energy.lo, energy.actual_lo or energy.lo) < action.shank.cost
    then
        return false
    end
    -- Be conservative about the next finisher: beat even the cheapest learned one. Shank must recover more than
    -- waiting through its own GCD would, and it must be affordable now rather than from a future energy guess.
    local cost = action.eviscerate.known and action.eviscerate.cost or HUGE
    if action.slice_and_dice.known then
        cost = min(cost, action.slice_and_dice.cost)
    end
    if action.rupture.known then
        cost = min(cost, action.rupture.cost)
    end
    if action.death_mark.known then
        cost = min(cost, action.death_mark.cost)
    end
    if cost == HUGE then
        return false
    end
    local wait = energy.timeToLo(cost)
    local recovered = max(0, cost - shankRefund(talent) + action.shank.cost)
    return wait > gcd.execute + 0.1 and energy.timeToLo(recovered) + gcd.execute + 0.1 < wait
end)

spec:RegisterStateExpr("rogue_reserve_kick", function()
    local casting = debuff.casting
    return state.toggle.interrupts
        and action.kick.known
        and casting.up
        and casting.v2 == 0
        and max(cooldown.kick.remains, cooldown.global_cooldown.remains, energy.timeToLo(action.kick.cost)) < casting.remains
        and energy.lo < action.kick.cost
end)

spec:RegisterStateExpr("rogue_start_attack", function()
    return state.rogue_field_damage
        and not stealthed.all
        and buff.rogue_autoattacking.down
        and plain(Facade.C_Spell.IsCurrentSpell(6603)) == false
end)

spec:RegisterSetting("behind", false, {
    type = "toggle",
    name = L["Always Behind"],
    desc = L["Allow attacks that require being behind the target when the addon cannot infer your position."],
    width = "full",
}, "assassination", "combat", "subtlety")

spec:RegisterSetting("pve_continuous_combat", false, {
    type = "toggle",
    name = L["Continuous Combat"],
    desc = L["Keep Slice and Dice on ordinary enemies when you expect to keep fighting between targets. Raid priorities are unchanged."],
    width = "full",
}, "assassination", "combat", "subtlety")

spec:RegisterSetting("stun_spacing", 30, {
    type = "range",
    name = L["Stun Spacing"],
    desc = L["Minimum seconds between our stun attempts on the same target. This conservative spacing is not a full diminishing-returns tracker. Zero disables spacing."],
    min = 0,
    max = 60,
    step = 1,
    width = "full",
}, "assassination", "combat", "subtlety")

spec:RegisterSetting("poison_reminders", true, {
    type = "toggle",
    name = L["Poison Reminders"],
    desc = L["Suggest poisons for uncoated weapons before combat, independently of the Potions toggle. Existing weapon coatings are kept."],
    width = "full",
}, "assassination", "combat", "subtlety")
local poisonChoices = {
    auto = L["Automatic"],
    instant = L["Instant Poison"],
    deadly = L["Deadly Poison"],
    off = L["No Reminder"],
}
spec:RegisterSetting("main_hand_poison", "auto", {
    type = "select",
    name = L["Main Hand Poison"],
    desc = L["Automatic uses Instant Poison. This preference only applies when the weapon is uncoated."],
    values = poisonChoices,
    width = "full",
}, "assassination", "combat", "subtlety")
spec:RegisterSetting("off_hand_poison", "auto", {
    type = "select",
    name = L["Off Hand Poison"],
    desc = L["Automatic prefers Deadly Poison on durable targets and Instant Poison otherwise. This preference only applies when the weapon is uncoated."],
    values = poisonChoices,
    width = "full",
}, "assassination", "combat", "subtlety")

spec:RegisterStateExpr("rogue_poison_main", function()
    if not settings.poison_reminders or settings.main_hand_poison == "off" then
        return 0
    end
    return settings.main_hand_poison == "deadly" and 2 or 1
end)
spec:RegisterStateExpr("rogue_poison_off", function()
    if not settings.poison_reminders or settings.off_hand_poison == "off" then
        return 0
    end
    return (settings.off_hand_poison == "deadly" or settings.off_hand_poison == "auto" and state.rogue_durable) and 2
        or 1
end)

-- The finishers' durations by combo points (DB2 durations and per-point steps): Slice and Dice 6 + 3 a point,
-- Improved Slice and Dice +15% a rank (14165 aura 108 base 15); Rupture 6 + 2 a point. Blood Splatter (1329256: duration
-- +6000 ms on Rupture's class mask, +9000 ms on Garrote's) adds 6 s to Rupture and 9 s to Garrote. Read at the
-- cast, so `now` and `handler` pass them (the auras' registered durations are the 5-point ones).
local function sndDuration(cp, rank)
    return (6 + 3 * cp) * (1 + 0.15 * rank)
end

-- Combo points: a count the game binds to the target (only the current target's is usable), not a pool.
spec:RegisterResource(Enum.PowerType.ComboPoints, nil, nil, { onTarget = true, points = true })
-- Adrenaline Rush (13750 aura 110 misc 3 base 100): +100% energy regen while it is up, a rate multiplier (C3b).
-- regen: energy's base rate a second, the belief's from the build until a plain rate read (energy is secret even out
-- of combat): wowsims/forever's 1 energy every 0.1 s (sim/core/energy.go:48-49).
-- refundOnAvoid: the share of the energy an ability flagged `refundOnAvoid = true` gives back when dodged, parried or
-- missed (wowsims/forever's MissRefund, spelldata/attributes.go: 0.8 where the DB2 flags Discount Power On Miss and the
-- spell issues the refund). Not Slice and Dice, Vanish or the poisons; Gouge is flagged in the DB2 but wowsims issues
-- no refund for it, so its registration below leaves `refundOnAvoid` off.
spec:RegisterResource(Enum.PowerType.Energy, {
    adrenaline_rush = { aura = "adrenaline_rush", mult = 2 },
}, nil, { regen = 10, rest = "max", refundOnAvoid = 0.8 }) -- rest: energy rests full out of combat

-- Talents: { talent tree (1 Assassination, 2 Combat, 3 Subtlety: the dominant tree picks the spec), rank 1's spell,
-- max rank }: Forever's tree as wowsims/forever's ui/sim/talents/trees/rogue.json lists it (tools/wowsims/talents.lua
-- writes it; tests/Forever/talent_trees_spec.lua checks it and the spec detection over it). A key is Classic's where the
-- talent exists there (code reads `talent.<key>.rank`; Setup is setup_talent), else the snake_case of the node's name.
spec:RegisterTalents({
    -- Assassination (tree 1)
    improved_gouge = { 1, 13741, 3 },
    remorseless_attacks = { 1, 14144, 2 },
    malice = { 1, 14138, 5 },
    ruthlessness = { 1, 14156, 3 },
    improved_expose_armor = { 1, 14168, 2 },
    improved_slice_and_dice = { 1, 14165, 3 },
    vigor = { 1, 14983, 2 },
    blood_splatter = { 1, 1329256, 1 },
    lethality = { 1, 14128, 2 },
    vile_poisons = { 1, 16513, 5 },
    cold_blood = { 1, 14177, 1 },
    improved_poisons = { 1, 14113, 5 },
    relentless_strikes = { 1, 14179, 5 },
    venom = { 1, 1329328, 1 }, -- Shank's 6 s poison bonus
    improved_kidney_shot = { 1, 14174, 2 },
    seal_fate = { 1, 14186, 3 },
    mutilate = { 1, 399956, 1 },
    -- Combat (tree 2)
    coup_de_grace = { 2, 14162, 3 },
    efficient_strikes = { 2, 13732, 2 },
    lightning_reflexes = { 2, 13712, 5 },
    puncturing_wounds = { 2, 1224716, 3 },
    deflection = { 2, 13713, 3 },
    precision = { 2, 13705, 3 },
    improved_sprint = { 2, 13743, 2 },
    endurance = { 2, 13742, 2 },
    riposte = { 2, 14251, 1 },
    composure = { 2, 1329265, 2 },
    improved_kick = { 2, 13754, 2 },
    flawless_execution = { 2, 1310711, 1 },
    weapon_expertise = { 2, 30919, 2 },
    aggression = { 2, 18427, 3 },
    dual_wield_specialization = { 2, 13715, 2 },
    blade_flurry = { 2, 13877, 1 },
    hack_and_slash_3 = { 2, 13960, 5 },
    flash_of_steel = { 2, 1329284, 5 }, -- Shank: +3 energy and -0.4 s cooldown a rank
    adrenaline_rush = { 2, 13750, 1 },
    -- Subtlety (tree 3)
    setup_talent = { 3, 13983, 3 },
    master_of_deception = { 3, 13958, 3 },
    opportunity = { 3, 14057, 5 },
    dirty_deeds = { 3, 14082, 2 },
    camouflage = { 3, 13975, 3 },
    improved_ambush = { 3, 14079, 3 },
    dirty_tricks = { 3, 1224782, 2 },
    initiative = { 3, 13976, 3 },
    premeditation = { 3, 14183, 1 },
    serrated_blades = { 3, 14171, 3 },
    elusiveness = { 3, 13981, 2 },
    ghostly_strike = { 3, 14278, 1 },
    quick_getaway = { 3, 1310728, 2 },
    heightened_senses = { 3, 30894, 2 },
    preparation = { 3, 14185, 1 },
    hemorrhage = { 3, 16511, 1 },
    boot_knife = { 3, 1329286, 5 }, -- Shank's chance of 2 combo points (20% a rank): the certain 5/5 part only
    death_mark = { 3, 1316709, 1 },
})

spec:RegisterAuras({
    -- The poisons (id-less): up while either weapon carries one of the ranks' enchant IDs (DB2 70707, Effect 360's misc
    -- value, lowest rank first), read from the client; 30 minutes (the effect's 1800 s; in-game check L37).
    instant_poison = { enchants = { 323, 324, 325, 623, 624, 625 }, duration = 1800, max_stack = 1 },
    deadly_poison = { enchants = { 7, 8, 626, 627, 2630 }, duration = 1800, max_stack = 1 },
    crippling_poison = { enchants = { 22, 603 }, duration = 1800, max_stack = 1 },
    mind_numbing_poison = { enchants = { 35, 23, 643 }, duration = 1800, max_stack = 1 },
    wound_poison = { enchants = { 703, 704, 705, 706 }, duration = 1800, max_stack = 1 },
    adrenaline_rush = {
        id = 13750,
        duration = 15,
        max_stack = 1,
    },
    -- Remorseless (14143, the talent 14144's buff: 20 s, one charge, +40% crit on the strikes the pin's mask names): a
    -- kill opens it and no event here ties a death to our kill, so only a client or Cooldown Manager read shows it.
    remorseless = {
        id = 14143,
        copy = { 14144 }, -- the Cooldown Manager's entry links the talent's id
        duration = 20,
        max_stack = 1,
    },
    -- Slice and Dice (5171) and Blade Flurry (13877) each give +20% melee haste (A_MOD_MELEE_HASTE_3, pin spell rows):
    -- unmodelled: the core's aura field `swingHaste` (C5) would rescale the swing clock, not set here yet (attack speed
    -- is secret in combat).
    blade_flurry = {
        id = 13877,
        duration = 15,
        max_stack = 1,
    },
    -- One charge: the next Sinister Strike, Backstab, Ambush, Eviscerate or Mutilate crits (its cast takes it).
    cold_blood = {
        id = 14177,
        duration = 3600,
        max_stack = 1,
    },
    cheap_shot = {
        id = 1833,
        duration = 4,
        max_stack = 1,
        debuffRepeatGroup = "controlled_stun",
        debuffRepeatDelay = 30,
        debuffRepeatSetting = "stun_spacing",
        debuffRetryDelay = 30,
    },
    kidney_shot = {
        id = 1324474,
        copy = { 1324475, 408, 8643 },
        duration = 6,
        max_stack = 1,
        debuffRepeatGroup = "controlled_stun",
        debuffRepeatDelay = 30,
        debuffRepeatSetting = "stun_spacing",
        debuffRetryDelay = 30,
    },
    rogue_autoattacking = { duration = 3600, max_stack = 1 },
    rogue_opening_engagement = { duration = 3600, max_stack = 1 },
    -- Death Mark (rank 4 1325758, 6 s): the mark's payout lands when it ends.
    death_mark = {
        id = 1325758,
        copy = { 1316709, 1325756, 1325757 },
        duration = 6,
        max_stack = 1,
    },
    expose_armor = {
        id = 8647,
        copy = rest(EXPOSE_ARMOR),
        duration = 30,
        max_stack = 1,
    },
    garrote = {
        id = 703,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in Forever.
        copy = rest(GARROTE),
        duration = 18,
        tick_time = 3,
        max_stack = 1,
    },
    ghostly_strike = {
        id = 14278,
        duration = 7,
        max_stack = 1,
    },
    -- The next Ambush or Garrote needs no Stealth (1329326, 7 s, one charge): Ghostly Strike's landing gives it, either
    -- cast takes it (wowsims talents_subtlety.go). From our cast's `now`, as the strike's own buff.
    ghostly_strike_next = {
        id = 1329326,
        duration = 7,
        max_stack = 1,
    },
    hemorrhage = {
        id = 16511,
        duration = 15,
        max_stack = 1,
    },
    rupture = {
        id = 1943,
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in Forever.
        copy = rest(RUPTURE),
        duration = 16,
        tick_time = 2,
        max_stack = 1,
    },
    slice_and_dice = {
        id = 5171,
        copy = { 6774 },
        duration = 21,
        max_stack = 1,
    },
    -- Until cancelled (DB2 -1); the IsStealthed read puts it up or down (Sources/Forms.lua, C5).
    stealth = {
        id = 1784,
        copy = rest(STEALTH),
        duration = 3600,
        max_stack = 1,
        isStealthed = true,
    },
    vanish = {
        id = 11327,
        copy = { 11329, 1856, 1857 }, -- the Cooldown Manager's Vanish entries link the spell ids 1856 and 1857
        duration = 10,
        max_stack = 1,
        isStealthed = true,
    },
    -- Poised (passive 1328825, buff 1328826; wowsims poised.go): out of combat at full energy the next Ambush, Backstab,
    -- Blade Flurry, Eviscerate, Expose Armor, Garrote, Ghostly Strike, Hemorrhage, Kick, Mutilate, Riposte, Rupture,
    -- Sinister Strike or Slice and Dice costs 10 less (the cost modifier below; Composure adds to it in `spend`). One
    -- charge. Read from the client out of combat (the player aura walk), carried by the belief in combat. Not yet
    -- checked in game (the Druid's Poised is the same shape).
    poised = {
        id = 1328826,
        duration = 3600,
        max_stack = 1,
    },
    -- Sprint (2983, ranks 8696 and 11305; the buff is the spell) and Evasion (5277): 15 s, off the GCD.
    sprint = {
        id = 2983,
        copy = { 8696, 11305 },
        duration = 15,
        max_stack = 1,
    },
    evasion = {
        id = 5277,
        duration = 15,
        max_stack = 1,
    },
    -- Auras the Cooldown Manager's buff entries link (cdm fixture, the owner's export): the abilities' own ids and
    -- Forever's debuff ids, every rank. Effects on the target or no stated effect: durations are the DB2's, nothing reads them.
    distract = { id = 1725, duration = 10, max_stack = 1 },
    feint = { id = 1966, copy = { 6768, 8637, 11303, 25302 }, duration = 1, max_stack = 1 },
    blind = { id = 1324477, copy = { 2094 }, duration = 10, max_stack = 1 },
    gouge = { id = 1324481, copy = { 1776, 1777, 8629, 11285, 11286 }, duration = 4, max_stack = 1 },
    sap = { id = 1324482, copy = { 1324483, 1324484 }, duration = 45, max_stack = 1 },
    silenced_kick = { id = 1324485, duration = 3, max_stack = 1 },
    -- Venom (talent 1329328): Shank gives +30% poison damage for 6 s.
    venom = {
        id = 1310703,
        duration = 6,
        max_stack = 1,
    },
})

-- Poised's discount: aura 107 misc 14 -10 flat Energy on the class mask {255727518, 2099456, 67108864} against
-- SpellClassSet 8, read off the pin's class flags (the kit's rank-1 IDs, the ranks through each ability's `copy`;
-- Shank, Death Mark, Vanish and Premeditation are not in it); one charge.
spec:RegisterCostMod({
    aura = "poised",
    flat = -10,
    charges = 1,
    -- ... and Feint, Gouge, Kidney Shot, Cheap Shot, Sap, Blind and Distract (mask bits 27, 3, 21, 10, 7, 24, 12)
    spells = {
        8676,
        53,
        13877,
        2098,
        8647,
        703,
        14278,
        16511,
        1766,
        1310707,
        14251,
        1943,
        1752,
        5171,
        1966,
        1776,
        408,
        1833,
        6770,
        2094,
        1725,
    },
})

-- Stealth by kind (Hekili's Classic table, Forever's two auras): the APLs and Hekili's keybinding order read `.all`.
spec:RegisterStateTable(
    "stealthed",
    setmetatable({}, {
        __index = function(_, k)
            if k == "all" or k == "rogue" then
                return buff.stealth.up or buff.vanish.up
            elseif k == "remains" or k == "all_remains" or k == "rogue_remains" then
                return max(buff.stealth.remains, buff.vanish.remains)
            end
            return false
        end,
    })
)

-- An ability that starts combat breaks Stealth and Vanish in the sim (Hekili's Classic hook); Stealth's 10 s cooldown
-- starts then. Our casts' `now` write the same in the belief.
spec:RegisterHook("runHandler", function(key)
    local a = class.abilities[key]
    if (not a or a.startsCombat) and (buff.stealth.up or buff.vanish.up) then
        if a and a.startsCombat and state.rogue_opening_attack then
            applyBuff("rogue_opening_engagement")
        end
        if buff.stealth.up then
            setCooldown("stealth", 10 - 2 * talent.camouflage.rank)
        end
        removeBuff("stealth")
        removeBuff("vanish")
    end
end)

-- Riposte's window (L138; the Forever client answers Riposte as usable only inside the 5 s a parry opens): the client's
-- usability flip is the evaluator, its false->true edge opens the window, the flip back (Riposte cast, or the 5 s)
-- closes it. The belief owns the span, so it forecasts and survives a rebuild. (Runs in the belief's `now` context.)
local function riposteUsable()
    local r = knownRank(RIPOSTE)
    if r == 0 then
        return false
    end
    local usable, noMana = IsSpellUsable(RIPOSTE[r])
    return usable == true or noMana == true
end
spec:RegisterWindow("riposte", {
    evaluator = riposteUsable,
    duration = 5,
    close_on_false = true,
})

-- A finisher needs a combo point (its `usable`; with `ladder = false` its short answers are no energy rungs, C9).
local function finisherUsable()
    return combo_points.current > 0, "requires combo points"
end

-- A poison reminder (C4): the best of `items` in the bags, offered while one is there; its use (a 3 s cast, DB2) puts
-- its own aura `key` and the slot's pseudo-aura up for 30 minutes in the sim. The belief reads enchants from the
-- client. The priority only offers these before combat with Poison Reminders enabled and labels the hand.
local function poison(name, items, kind, key)
    local function best(playerLevel)
        for i = 1, #items do
            local item = items[i]
            if (playerLevel or 0) >= POISON_LEVEL[item] and GetItemCount(item) > 0 then
                return item, true
            end
        end
        return items[#items], false
    end
    return {
        name = name,
        cast = 3,
        cooldown = 0,
        gcd = "off",

        item = function()
            return best(level)
        end,
        items = items,
        bagItem = true,

        startsCombat = false,
        usable = function()
            local _, have = best(level)
            return settings.poison_reminders and have, "requires enabled poison reminders and usable poison in the bags"
        end,

        handler = function()
            applyBuff(key, 1800)
            local mainKind = settings.main_hand_poison == "off" and 0
                or settings.main_hand_poison == "deadly" and 2
                or 1
            local slot = state.main_hand.size > 0
                    and mainKind == kind
                    and not buff.main_hand_enchant.up
                    and "main_hand_enchant"
                or "off_hand_enchant"
            applyBuff(slot, 1800)
        end,
    }
end

-- Preparation's reset set (owner, ledger L854: Forever's Preparation finishes the cooldown of every other Rogue
-- ability, as the Classic tooltip says; wowsims's list is narrower): every Rogue ability this file registers with a
-- cooldown, from the two Rogue tables below (not the poisons, racials or items, registered elsewhere). Load time only.
local PREPARATION_RESETS = {}
local function rogue(abilities)
    for key, a in pairs(abilities) do
        if key ~= "preparation" and a.cooldown ~= 0 then
            PREPARATION_RESETS[#PREPARATION_RESETS + 1] = key
        end
    end
    table.sort(PREPARATION_RESETS)
    return abilities
end

spec:RegisterAbilities(rogue({
    auto_attack = {
        id = 6603,
        texture = 135274, -- INV_Sword_04: the same Attack artwork with every equipped weapon.
        cooldown = 0,
        gcd = "off",
        startsCombat = true,
        known = knows({ 6603 }),
        usable = function()
            return state.rogue_start_attack, "requires an eligible melee target with autoattack off and Stealth down"
        end,
        handler = function()
            applyBuff("rogue_autoattacking")
        end,
    },

    adrenaline_rush = {
        id = 13750,
        cast = 0,
        cooldown = 300,
        gcd = "totem",

        startsCombat = false,
        known = knows(ADRENALINE_RUSH),
        toggle = "cooldowns",

        now = function()
            applyBuff("adrenaline_rush")
        end,

        handler = function()
            applyBuff("adrenaline_rush")
        end,
    },

    ambush = {
        id = 8676,
        copy = rest(AMBUSH),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 60)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims ambush.go; DB2 Discount Power On Miss
        known = knows(AMBUSH),

        -- In Stealth or Vanish, or after a Ghostly Strike; a dagger and being behind are the player's (settings).
        usable = function()
            return buff.stealth.up or buff.vanish.up or buff.ghostly_strike_next.up, "requires stealth"
        end,

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
            removeBuff("ghostly_strike_next")
            removeBuff("cold_blood")
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("ghostly_strike_next")
            removeBuff("cold_blood")
            gain(talent.initiative.rank >= 3 and 2 or 1, "combo_points")
        end,
    },

    backstab = {
        id = 53,
        copy = rest(BACKSTAB),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 60)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims backstab.go; DB2 Discount Power On Miss
        known = knows(BACKSTAB),

        now = function()
            removeBuff("cold_blood")
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("cold_blood")
            gain(1, "combo_points")
        end,
    },

    blade_flurry = {
        id = 13877,
        cast = 0,
        cooldown = 120,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 25)
        end,
        spendType = "energy",

        startsCombat = false,
        known = knows(BLADE_FLURRY),
        toggle = "cooldowns",

        now = function()
            applyBuff("blade_flurry")
        end,

        handler = function()
            applyBuff("blade_flurry")
        end,
    },

    cold_blood = {
        id = 14177,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        startsCombat = false,
        known = knows(COLD_BLOOD),
        toggle = "cooldowns",

        now = function()
            applyBuff("cold_blood")
        end,

        handler = function()
            applyBuff("cold_blood")
        end,
    },

    eviscerate = {
        id = 2098,
        copy = rest(EVISCERATE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, max(0, 35 - 15 * talent.flawless_execution.rank)) -- 1310711's -15 (4b0030a44b; the log's 20)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims eviscerate.go; DB2 Discount Power On Miss
        known = knows(EVISCERATE),
        ladder = false, -- a finisher: an answer short of energy may be short of combo points (C9)
        usable = finisherUsable,

        now = function()
            removeBuff("cold_blood")
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            removeBuff("cold_blood")
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
        end,
    },

    expose_armor = {
        id = 8647,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(EXPOSE_ARMOR),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, max(0, 25 - IMPROVED_EXPOSE_ARMOR[talent.improved_expose_armor.rank])) -- the curve {-5, -10}
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims expose_armor.go; DB2 Discount Power On Miss
        known = knows(EXPOSE_ARMOR),
        ladder = false,
        usable = finisherUsable,

        now = function()
            applyDebuff("target", "expose_armor")
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            applyDebuff("target", "expose_armor")
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
        end,
    },

    garrote = {
        id = 703,
        debuffApplication = "garrote",
        copy = rest(GARROTE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function() -- Dirty Deeds (14082: aura 107 misc 14 -20, the talent's whole)
            return poised(buff, talent, max(0, 50 - 10 * talent.dirty_deeds.rank))
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims garrote.go; DB2 Discount Power On Miss
        known = knows(GARROTE),
        missable = true,

        usable = function()
            return buff.stealth.up or buff.vanish.up or buff.ghostly_strike_next.up, "requires stealth"
        end,

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
            removeBuff("ghostly_strike_next")
            applyDebuff("target", "garrote", 18 + 9 * talent.blood_splatter.rank)
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("ghostly_strike_next")
            applyDebuff("target", "garrote", 18 + 9 * talent.blood_splatter.rank)
            gain(talent.initiative.rank >= 3 and 2 or 1, "combo_points")
        end,
    },

    ghostly_strike = {
        id = 14278,
        cast = 0,
        cooldown = 20,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 40)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_subtlety.go; DB2 Discount Power On Miss
        known = knows(GHOSTLY_STRIKE),

        now = function()
            applyBuff("ghostly_strike")
            applyBuff("ghostly_strike_next")
            gain(1, "combo_points")
        end,
        onAvoid = function() -- the next-Garrote buff is the landing's: a dodge, parry or miss gives none
            removeBuff("ghostly_strike_next")
        end,

        handler = function()
            applyBuff("ghostly_strike")
            applyBuff("ghostly_strike_next")
            gain(1, "combo_points")
        end,
    },

    hemorrhage = {
        id = 16511,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, max(0, 35 - EFFICIENT_STRIKES[talent.efficient_strikes.rank])) -- the log's 30 at rank 2
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_subtlety.go; DB2 Discount Power On Miss
        known = knows(HEMORRHAGE),
        missable = true,

        now = function()
            applyDebuff("target", "hemorrhage")
            gain(1, "combo_points")
        end,

        handler = function()
            applyDebuff("target", "hemorrhage")
            gain(1, "combo_points")
        end,
    },

    kick = {
        id = 1766,
        copy = rest(KICK),
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 25)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims kick.go; DB2 Discount Power On Miss
        known = knows(KICK),
        toggle = "interrupts",
        debuff = "casting",
        priorityInterruptRange = { 0, 5 },
        readyTime = function()
            if state.rogue_field and debuff.casting.up and debuff.casting.v2 == 0 then
                return cooldown.global_cooldown.remains
            end
            return max(cooldown.global_cooldown.remains, state.timeToInterrupt())
        end,

        handler = function()
            interrupt()
        end,
    },

    -- Combat talent (DB2 14251: 10 energy, 6 s cooldown, off the global cooldown, 5 yd, a strike that also disarms for
    -- 6 s). Usable only in the 5 s window after a parry (window.riposte, from the client's usability answer). On the
    -- Combat priority, in the window (owner R70).
    riposte = {
        id = 14251,
        cast = 0,
        cooldown = 6,
        gcd = "off",

        spend = function()
            return poised(buff, talent, 10)
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(RIPOSTE),
        usable = function()
            return window.riposte.up, "needs a parry in the last 5 s"
        end,

        now = function()
            closeWindow("riposte")
        end,

        handler = function()
            closeWindow("riposte")
        end,
    },

    -- Both hands; +2 combo points (one effect).
    mutilate = {
        id = 1310707,
        copy = rest(MUTILATE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 60)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_assassination.go; DB2 Discount Power On Miss
        known = knows(MUTILATE),

        now = function()
            removeBuff("cold_blood")
            gain(2, "combo_points")
        end,

        handler = function()
            removeBuff("cold_blood")
            gain(2, "combo_points")
        end,
    },

    -- +2 combo points (14183 effect 30 base 2); its 20 s hold of them is unmodelled. Whether it needs Stealth on
    -- Forever is checkpoint Q14 (wowsims casts it in and out of stealth).
    premeditation = {
        id = 14183,
        cast = 0,
        cooldown = 120,
        gcd = "off",

        startsCombat = false,
        known = knows(PREMEDITATION),
        toggle = "cooldowns",

        handler = function()
            gain(2, "combo_points")
        end,
    },

    -- Finishes the cooldowns of every other Rogue ability (PREPARATION_RESETS, above; owner, ledger L854). `resets`
    -- names the set for the harness world.
    preparation = {
        id = 14185,
        cast = 0,
        cooldown = 600,
        gcd = "totem",

        startsCombat = false,
        known = knows(PREPARATION),
        toggle = "cooldowns",
        resets = PREPARATION_RESETS,

        now = function()
            for i = 1, #PREPARATION_RESETS do
                setCooldown(PREPARATION_RESETS[i], 0)
            end
        end,

        handler = function()
            for i = 1, #PREPARATION_RESETS do
                setCooldown(PREPARATION_RESETS[i], 0)
            end
        end,
    },

    rupture = {
        id = 1943,
        debuffApplication = "rupture",
        copy = rest(RUPTURE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 25)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims rupture.go; DB2 Discount Power On Miss
        known = knows(RUPTURE),
        missable = true,
        ladder = false,
        usable = finisherUsable,

        now = function()
            applyDebuff("target", "rupture", 6 + 2 * combo_points.current + 6 * talent.blood_splatter.rank)
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            applyDebuff("target", "rupture", 6 + 2 * combo_points.current + 6 * talent.blood_splatter.rank)
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
        end,
    },

    sinister_strike = {
        id = 1752,
        copy = rest(SINISTER_STRIKE),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, max(0, 45 - EFFICIENT_STRIKES[talent.efficient_strikes.rank]))
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims sinister_strike.go; DB2 Discount Power On Miss
        known = knows(SINISTER_STRIKE),

        now = function()
            removeBuff("cold_blood")
            gain(1, "combo_points")
        end,

        handler = function()
            removeBuff("cold_blood")
            gain(1, "combo_points")
        end,
    },

    slice_and_dice = {
        id = 5171,
        copy = { 6774 },
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 25)
        end,
        spendType = "energy",

        startsCombat = false,
        known = knows(SLICE_AND_DICE),
        ladder = false,
        usable = finisherUsable,

        -- Replaces the running one (checkpoint Q8).
        now = function()
            applyBuff("slice_and_dice", sndDuration(combo_points.current, talent.improved_slice_and_dice.rank))
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            applyBuff("slice_and_dice", sndDuration(combo_points.current, talent.improved_slice_and_dice.rank))
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
        end,
    },

    stealth = {
        id = 1784,
        copy = rest(STEALTH),
        cast = 0,
        cooldown = function()
            return 10 - 2 * talent.camouflage.rank -- Camouflage 13975's second effect: -2 / -4 / -6 s on Stealth's mask
        end,
        gcd = "off",

        startsCombat = false,
        known = knows(STEALTH),
        nobuff = "stealth",

        usable = function()
            return combat == 0, "cannot be in combat"
        end,

        now = function()
            applyBuff("stealth")
        end,

        handler = function()
            applyBuff("stealth")
        end,
    },

    vanish = {
        id = 1856,
        copy = rest(VANISH),
        cast = 0,
        cooldown = function()
            return 300 - 45 * talent.elusiveness.rank -- Elusiveness 13981: -45 / -90 s, on Vanish and Blind
        end,
        gcd = "off",

        startsCombat = false,
        known = knows(VANISH),
        toggle = "cooldowns",

        now = function()
            applyBuff("vanish")
        end,

        handler = function()
            applyBuff("vanish")
        end,
    },

    -- Forever-only (levels 24 and 44, 5 energy, 10 s): an off-hand strike that gives 15 (rank 1) or 25 (rank 2) energy
    -- and 3 more a Flash of Steel rank, which also shortens its cooldown 0.4 s a rank; with Venom it gives the poison
    -- bonus. No combo point of its own (wowsims's Shank is no builder); Boot Knife at 5/5 gives 2 for certain (the log:
    -- 17 of 17 Shanks), ranks 1-4 are a chance that is not modelled.
    shank = {
        id = 1329283,
        copy = { 1329549 },
        cast = 0,
        cooldown = function()
            return 10 - 0.4 * talent.flash_of_steel.rank
        end,
        gcd = "totem",

        spend = 5,
        spendType = "energy",

        startsCombat = true,
        known = knows(SHANK),

        now = function()
            gain((knownRank(SHANK) >= 2 and 25 or 15) + 3 * talent.flash_of_steel.rank, "energy")
            if talent.venom.enabled then
                applyBuff("venom")
            end
            if talent.boot_knife.rank >= 5 then
                gain(2, "combo_points")
            end
        end,

        handler = function()
            gain((knownRank(SHANK) >= 2 and 25 or 15) + 3 * talent.flash_of_steel.rank, "energy")
            if talent.venom.enabled then
                applyBuff("venom")
            end
            if talent.boot_knife.rank >= 5 then
                gain(2, "combo_points")
            end
        end,
    },

    -- Subtlety's finisher (talent, levels 40/48/56/60: 25 energy, 1 combo point at least, 10 s): a 6 s mark that deals a
    -- share of what the rogue deals the target when it ends (the payout is not modelled).
    death_mark = {
        id = 1316709,
        copy = rest(DEATH_MARK),
        cast = 0,
        debuffApplication = "death_mark",
        cooldown = 10,
        gcd = "totem",

        spend = 25,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims death_mark.go IssueRefund on a miss
        known = knows(DEATH_MARK),
        missable = true,
        ladder = false,
        usable = finisherUsable,

        now = function()
            applyDebuff("target", "death_mark")
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            applyDebuff("target", "death_mark")
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
        end,
    },
}))

-- Utility abilities. Costs, cooldowns and GCDs come from the pin's spells_auto_gen.go.
local GOUGE = { 1776, 1777, 8629, 11285, 11286 }
local SAP = { 6770, 2070, 11297 }
local BLIND = { 2094 }
local SPRINT = { 2983, 8696, 11305 }
local DISTRACT = { 1725 }
local REDIRECT = { 438040 } -- unverified on Forever: `known` hides it where the spellbook has no such spell

spec:RegisterAbilities(rogue({
    -- 20 energy, 10 s; wowsims refunds a dodged or parried one (feint.go).
    feint = {
        id = 1966,
        copy = rest(FEINT),
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 20)
        end,
        spendType = "energy",

        startsCombat = true,
        refundOnAvoid = true,
        known = knows(FEINT),
        toggle = "defensives",
        readyTime = function()
            return cooldown.global_cooldown.remains
        end,

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
        end,
    },

    -- 45 energy, 10 s, +1 combo point (the pin's Energize effect).
    gouge = {
        id = 1776,
        copy = rest(GOUGE),
        cast = 0,
        cooldown = 10,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 45)
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(GOUGE),

        -- (L1832 review M7) its point is the handler's only: no `now` gain, so no point fact (the rows decide its
        -- avoid; it refunds nothing); wowsims has no cast for it, so no parity gap
        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
        end,

        handler = function()
            gain(1, "combo_points")
        end,
    },

    -- A finisher: 25 energy and every combo point, 20 s; in Relentless Strikes's mask.
    kidney_shot = {
        id = 408,
        copy = rest(KIDNEY_SHOT),
        cast = 0,
        cooldown = 20,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 25)
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(KIDNEY_SHOT),
        ladder = false,
        refundOnAvoid = true,
        expects = "debuff",
        toggle = "interrupts",
        priorityInterruptRange = { 0, 5 },
        priorityInterruptStun = true,
        priorityInterruptTargetOnly = true, -- combo points and stun eligibility are only checked on the selected enemy
        readyTime = function()
            return cooldown.global_cooldown.remains
        end,
        usable = finisherUsable,

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
            applyDebuff("target", "kidney_shot", combo_points.current + knownRank(KIDNEY_SHOT) - 1)
            relentless(talent, combo_points.current, gain, mayGain)
        end,

        handler = function()
            applyDebuff("target", "kidney_shot", combo_points.current + knownRank(KIDNEY_SHOT) - 1)
            relentless(talent, combo_points.current, gain)
            spend(combo_points.current, "combo_points")
            interrupt()
        end,
    },

    -- The Stealth opener: 60 energy (Dirty Deeds -10 a rank), +2 combo points.
    cheap_shot = {
        id = 1833,
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, max(0, 60 - 10 * talent.dirty_deeds.rank))
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(CHEAP_SHOT),
        ladder = false,
        refundOnAvoid = true,
        expects = "debuff",

        usable = function()
            return buff.stealth.up or buff.vanish.up, "requires stealth"
        end,

        -- (L1832 review M7) as Gouge: its points are the handler's only, no point fact; wowsims has no cast for it
        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
            applyDebuff("target", "cheap_shot")
        end,

        handler = function()
            applyDebuff("target", "cheap_shot")
            gain(talent.initiative.rank >= 3 and 3 or 2, "combo_points")
            interrupt()
        end,
    },

    -- 65 energy (Dirty Tricks -25% a rank), from Stealth.
    sap = {
        id = 6770,
        copy = rest(SAP),
        cast = 0,
        cooldown = 0,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 65, 1 - 0.25 * talent.dirty_tricks.rank)
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(SAP),

        usable = function()
            return buff.stealth.up or buff.vanish.up, "requires stealth"
        end,

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
        end,
    },

    -- 30 energy (Dirty Tricks -25% a rank), 300 s (Elusiveness -45 s a rank); a Blinding Powder is the client's to check.
    blind = {
        id = 2094,
        cast = 0,
        cooldown = function()
            return 300 - 45 * talent.elusiveness.rank
        end,
        gcd = "totem",

        spend = function()
            return poised(buff, talent, 30, 1 - 0.25 * talent.dirty_tricks.rank)
        end,
        spendType = "energy",

        startsCombat = true,
        known = knows(BLIND),

        now = function()
            removeBuff("stealth")
            removeBuff("vanish")
        end,
    },

    -- 15 s, 300 s (Endurance -30% a rank), off the GCD; no energy.
    evasion = {
        id = 5277,
        cast = 0,
        cooldown = function()
            return 300 * (1 - 0.3 * talent.endurance.rank)
        end,
        gcd = "off",

        startsCombat = false,
        known = knows(EVASION),
        toggle = "defensives",
        nobuff = "evasion",

        now = function()
            applyBuff("evasion")
        end,

        handler = function()
            applyBuff("evasion")
        end,
    },

    sprint = {
        id = 2983,
        copy = rest(SPRINT),
        cast = 0,
        cooldown = function()
            return 300 * (1 - 0.3 * talent.endurance.rank)
        end,
        gcd = "off",

        startsCombat = false,
        known = knows(SPRINT),

        now = function()
            applyBuff("sprint")
        end,

        handler = function()
            applyBuff("sprint")
        end,
    },

    -- 30 energy, 30 s, a 1.5 s GCD; keeps Stealth.
    distract = {
        id = 1725,
        cast = 0,
        cooldown = 30,
        gcd = "spell",

        spend = function()
            return poised(buff, talent, 30)
        end,
        spendType = "energy",

        startsCombat = false,
        known = knows(DISTRACT),
    },

    -- 10 s, off the GCD, no energy; the points move to a new target, so the player's own count is unchanged.
    redirect = {
        id = 438040,
        cast = 0,
        cooldown = 10,
        gcd = "off",

        startsCombat = false,
        known = knows(REDIRECT),
    },
}))

-- Both Instant Poison reminders use the same bag item. The priority supplies the destination in the label.
spec:RegisterAbilities({
    instant_poison = poison("Instant Poison", INSTANT_POISON, 1, "instant_poison"),
    deadly_poison = poison("Deadly Poison", DEADLY_POISON, 2, "deadly_poison"),
})

-- (L1808, owner "Setting per line") the health threshold of the packs' Evasion line (the
-- def-int-beyond-wowsims review's default, 50%): a 1-100 slider on every spec
spec:RegisterSetting("evasion_health", 50, spec:HealthOption("evasion"))

-- The hand-built lists this file shipped before the wowsims.com packs: a saved choice of one falls back to the spec's
-- default.
spec:RetirePacks({ "Combat", "Assassination", "Subtlety" })

-- The three priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit those
-- and run it, never these blocks (tests/Forever/rogue_spec.lua checks they match). Pick one with
-- /hekili priority <name>.
spec:RegisterPack(
    "Combat (wowsims.com)",
    20261128000,
    [[Hekili:T3vAtoQX5)plZBKLQSrJ0CS7AxRMQs(h7yN6VpkpoXVtie0sIieOIgMXtkv6ZEE6dGMMUBoeJ2rB4n7QHJNJ(5SBA(X8PZ)T5p6AhJM)t3m5M3pD6nFCYKjZFm(L9O5pU32zR9A4hb27G)9)lC3s74Jlg(C4ZyVD4XoH7grUQx8dTDjuAzINF8pemFPsII3JCM)4V(Z)9)53(nouAn)XnEUUi2nGWoA4X3CCr8g0Xf8JD9QWi0tOOJlCrRSt8Hl)V8l))hxah(4ImcK4DnHH4RJcxNGU2Dp(A79(4R53Zy4pg)VXHbJEhq9i7aSpiXUWVdjCZdFCHTRByWxb)yl6f84Jl(B2X2FJcPy4p(d)gqKnXX7XFZ1xV2lEtYsIGFT0LocOjiA2lNSAYe0DRC(4Taz)9WF)4IVlLy(W)57fSgUSaqAccdIS9GF8lp9ThxSpYlmYl2dHjARVF4Zhx8doVCCX)c5fGbz4zG3eAyhfGC)ZG(77Zj0Zi79HbWTz77VeSRef63idQ4eCSTxar1zCY1Ehy0Zy2lPScZTc79cOxni3pck3XfeRUlqUFj0dtyreANxGlkcZznY2beQnWVjdM7JqRqrOahe5ypHOu1d08WNH79xjglqOqXXWGariFmgz7t0kIjbNSEnctTtuRDysSBi5h7t89XP6V9Xfjy7L(aHc3JcqrJbV0OWvE(GxSTtSxyaEmihmNWzp757BfhAHtIEY7j078wnJ6ZyT)jKLtyqm6pIhCfMjhi3XWi4a2fGJtOJf)Jse9pn7Akzdxzb3JfiSy7TOGgq70BHEvrH(Qzce0yVhzzhf7HJBa13f(eAhkioL6dwMSA14cuBSlXIOKR44WaeiG7QfhhsPTRh1DKywS2t9ugNS)qPtb)gzJrW5gXKPmEzsE2yhhJISCsIW1Z(vIV0Bf4kNPIe0aJJS375AfHwt8YSjN)Djyey1xzT2XD203ryHV9lwlrqe0S3pjx4CSdSiucI6z8SmTmXyKTRLp6flixbsIlFKYL4W1R9bzhI2cWGBnEGg(sy3AV)dmWONDq2LyBWBHz4K0ryae5p7hHKihx89quoH78qRjdUIXvsCieqBbdRqYNb52Ny7O1O4b7G72IKIymgeLhMWeTSJAb5lG)N5tME3uzXICnZMQwSDHrj)xEZk130wP(NxTQ9cnHyLK50dAqKHlrNexd3JZLipSKmp9qz1yqwbMmQWo9SVYojo8RgPlVhnhIKckQqC9HvwYIv9jnHUhY31IvDvoDe5(djIqqm0YtseuFm(t3ny4qMum2zdu(2cVjmE82GCldT(dj91GHxP5kp4IOJwchNmonk)o265gajskFlINGFp4q)WdmJYypm38qSCK0pqdoJoKjY27wMG3WPi)y0gpITxYo6iH4hxBOWE6i1s0gObcGw8BBTDuuymQGQ7MervC2FXVIbCjp9gOsTgB5sFBxWO4dd2VKNvoRBOuNqFBsfEls)fPERudPAIc)EhY1lwvPGtGhDylkVInMCoBh5TrtiN5wpoZnCCwAZOEvp(SwMEQOWwDX5pRY6nntwpxvLlxbUHoaNlbTRBFOVPHl9Mgal4g6OoTgqzRi7KC2W)J9oXFAwMpIWTBX(TmXPdgHQ7zOE0pNckyXwpNT5oCpmPCec7aOG1GBwABj7q(OSbhhBmHzKQuKBlDTHSaFpuuuY(sv5KUVNUz2KIIuMBYRUKj72l3zqJJc04QlgD4SLtdNWqFYjzhdApe8EXpmts45h)q5rTPJugN)qXmO69qlwZ(wAn7Rk4tPFSV4avTDAlYY76iwM3UNulo3RXbkT9lEOVDajxHQEX03Ch6jBSYGsHKZgPpj1xUBX6nH4yOGmooYBlpZeR5tPZqDZQLGuD2b(TYtlacJGSF4kQakQbJ0gE01sVkZyr3K6okFvxnmVcbXyTnFetkuo9MnER3at3c6MowoTvPoU92dYOCu8QqNemZIt7J(LX(HpmJRV8BzSd8Vs2xvnrWowecJIa1IKwssOlmKKN8l3VxQFln9H8gTBdrLJxYxC4vPgouTkEq1HND3GRIT9HFn2lWl2dMy1tiy2pKXa3rnTrerPL1C05qin2ILOiL2BwZ8nUV(ma9Kh2Hm7uuJyXdZUtKk7sI98nrdECm)Y0i1flaUlmkAdeq1i5QirWWypMmxFw(OtGsKzDWVATR6eejeZVMcMq)WqxRvjrVySmx9tFKxDNFTEbo27TDiRkgKYCyHiGdczqHSQODEiO7OBoKv(kTsUxqsyc2Ir7rdeYcEhFcD5ksPiNLOiqC3ce8sxhZuKY9Q4NeGWw(qPM4lCTuuvkRNjrOT2xOA4xNQHuLOKUPTEuRvRckWafnbzfa9itM8e7knukQdlWOOQw3PYMusJ1DELuqmWVTDGEXtJtOgqeOYXguuXe5QEGgNi7KD2ly5CHbcY8abkwOXKwZtEKYgVpn7(j5T)H99CqwKvzZf(Hyd9sNHSE9d1eLwisOObQar6qpXUj9HkfLVEbFA206S6aKvbbs40HAwX0k8KfC2iTwinY4PmsRqNooHGetl135LauZ8CnjVxuUwuEQycxcz2yJQQv22iRMhF6QSnYRzUy2NOWWD1OP0YtoOPsJ50180V7tcCa)os)YphMe4ItZcxdruBh4nvsRMvkQTRUEZ9dUsQ6ljYGp(N9OJ5Y0gs4q60f4IKixFYMuOOCOYW8vlrCDYpOI1AU0YE)PNN66RBQFXE7qpqwwtjnsuQ3hH2BZF8MeHnvayAtQOMT0Q8dtEyLVyKUMMRtgteRJYz1qTNkDQhchhgYAVqyskY03cNJR1z3w2KG4pUeJssXoggoudvgagKNgpv44JoiiPsxC3ReJeCcBknnP)gMwy7QF1Ob7UGdJgOZmOSOWWHd5znxgggBTnWBf0mbCYhMD)bDN5oTN5wTN5gfNjB5LuMzy2T5tu6tZ(4eIh2BbHTOqvorSCHsdjMbN40im(ea5bmxP4O5E18JY9NZUyP2VLsvP8SSSvYNcCRoOwUmsRm5t(0PpKlzfG0UiHEJgvHuUImXFR0ECRIpJgPr8lEmxpmZIEOW8XhvXmAgky)B9CsYSVIlSbti1f(w2rR355TTZt9QRREG3GyYSBA8sgOTkSyrXSZWOwo5u4pouVVQGtL45YiABcn6DZV0CZvLJSR7BSpiPyqc5g7ObN3aAtFi)fwiV5hTuU1t9qVENldopK9e4j6W3sV6w6u37vFP5vBQqMISK8szINrOyMY0Q9XfJy1UQ3iXRS(2mXUpC(clCUQIuT1jIVHDNo9UEFIloFc6LQWBqf5vAFELnpDTLORne9E8xyE8eKlj2hzfJu52puC1mNEF2oyXfzhVXAND02S19wTajC73CpCnf(7CdRa9y2u(tvu44SISQFcO3QM5I7CQ(A0xIENv86rR75c1BMVSmZ5H56SQpm7UMSJg6T4VXT4k2Hz5pPz6sRsExFiVx7PfysFKR5BKEZpF4hG8axjTrZs2pG8iIPVQhKTvcbHeC9qFA27hLvABLV9Z(im2c9hiNeMEv8DXO3d8lbpq9BIZHg3aLQ32FW89axRIkd4v13XXLMBHPTlQYMppXn8PXLx7kwhSINO)5HCb6uvCN8ouPFezpkP2b7UuoM(6MXKJrQVCsDp1L4gzy6BG5NFomkIiOKGaBxu2EJnBOiTwkBSqQaB2QFDRQzB1xU8Y1fU47hJPnJCMvO4U)vAFcNvK8UEhLVOCueF1zR0fPGXsPaiTgoQVORuBN1yrANRsrr90E6aFAME76ivzoz)D2RBCF8XLB8rXxe8(iKwfHKJzvfrTj1fzEy2hhDiT)gji9iT9gbd2hUVVK0xuHCkEPTYgUl2tD2URwyvMshw6JtBECAFC0x4XrnX8QjestGOulp9(gVf9nM)4tOicuDj9L7Wh8tW0pviSpEgWp)j6NoeE525)10VRcZFucQIN)OtKh4K5zp)rMpqLGbmhYINhdsHjMibHXTGtYqzmHL3QHLfaJ4wWR6cXXez4onYqgs11i(Bc6JBm2hteV71jEIqxCJeXssHtfyImrmEVKyuaq5GtpPSiuxmqE(JcRwmXxpthlFder5dMfLporGaibivwucBjskty)hLyForzVp)1hQCj5rob4hggOO4178hZrbz9JLEfW9xII81VvuKBAKIuaOLj6X0jDMIi)(Ls1J0dwfklNPfz4NCtuc5u8NfLqfcm3giyUjQEzhXPYvE0DR88ykhC4JnVHW152a1IvH1IMH2zny7Clb35dQxNa2fLchnS)Yi6otnXYv61zIfaxxrZC1qVAzGFMYx5Q7M4Rxgi72Cw7jJj0uURR4nbvtk7f3miqT2qYC1GfnvwLRWNlRzUINnrwoiR2OiDNaJ05ZbQw4iDJasA6qDfDWCBHMPAhAoxVimIWi3pJKWC3RUWie2rKh52sK708(kArxHq1s0PMoPi5Ml0PjCCxUCBWvdPY1arL1dPYuHuU5HgiKvNEZiOwF6OADfQMCVbkCh05Ew3X)6aP1gKYkhTjQHUz6srb7tnVA7rdBQSjxJmxykVhCmG)1TeaSHXaY(hJoYPDIGmUsLwD1uZt5xogSoy8Btar7ZDRDufxUaDfkPoa28GMnkthcK25gf(rfSXenrU(x6vZ6A9SQzg7bMkSY1htf20UPRuC1S2TvZz5kH55vs3suTI3pm7o6AVjxzlL8PRBCLeNNcYmqEtzLU1Vm)rfvjZmqDDlCP0AUFkSOUtFraBWlZoSaQGtPADNCsoGzOP9I6NUnVNT6acZ6Gr1kXrvHchAGmC6aGCUCTdazGh3L8aqr8eNoaiNtxBRec7J1l4HGsGnoDqqUCG2bb6Ju5cu9vGe5ufx)sjFIkwbvyGIwx7aKiVfvBROVGB1VI0N44HPraJ1HFD0(0(Cev(70voMINKD4ybVwubOnNka6kslcMMDUCihxrLeDf0LEuSDOWWdwRfyO3y0qxco0PQOCdfDMM0vPVuPKzBCfTiHUGBBHBvYxx)moprTVyIVMJv6neS0fMHkJhs6zD7Vj)nNPdhlulYcB7d534MA8k3q1kDRuSP5L0gTqX4nH96M9yxNOu(5OjM40aQStLXMpPXMkMMlB1s4ANk76M2zLtNQPQGEz4E9ps3xjCCVIwtUVURWkdE0liW5lSyHxQJMa)7Dn(VtvjDvzfae(c6rQOvay4RlYWt5yDNfT657MjakqL8SNvzRrnEQaEAti3iwSN)qLAcySRuk1TcO6AuRrqgATWm0ot)QaS5ntuvJn1Dc1QxrHw2CGkbrxvk9gPoH36XOEQuPRUuPANgbVEdacVbeH3aKW3bayVzeS)SkXfLSZik23YnVBB39UN7TVBNV)DB2g4vAh8sJN01RKHzQ2iqU)nek337CDMDUEFD36bv1nIgdJbLGzy14hnqBhcfQx3vy8TGFxZHf7xjCXUpw4ChlOBXjnLOTZB7TpqQvWLFThGEtOq9zgUSYmu3npUUhHAvaMTbSd3myAxjAAxDCrBD(BRVFVZ)fMZVUTvyDklwxC3)KaE))Nk6PgWV)ztPBOO3h4Fzf4x3vQwFvVw7NXFBioDq6V3R5C71u3NhnJyf8xuXAL2VxDZxxBPQIYn2q1hvCzfvu3NzKaE)l9Osews3kq6F1sRW9tG6)6J1)ngS)vZFXDNyF7axGUW1Dl0w4JcGOtSUNYwVFWfLFGUNVBE(HQm6VQFTa6Dio3oe63s1v9nd4l6pAa9oINthrZ7s2pyyZ(zCxiFo)Cc07W8zXHX0Ui)d1DpzQE3v38Vib1y)rBErhFv(Me07zEo9mj(D624SQ3)76)Kf00VzbN3pAbzJtVf(Qf07KFUDY19KLk(w0vzcv9Fud(88vnO3r6C7iPdFnvbZav6cv0wQu2KwllnxLoWIwJbRLotsI7j(mxAmGrZ(7U)tFqL6DFquhheP7v(qnaA0hgDcHrT47JqvFGeoFFHeQCOSpYSJJm19YWA4TLmZy8Q8buOpCUIQI9bBxSbBAF1VR6vtUEwFnXzAIwL6UQ315nSRtm9rFYE1(N3)bvOX8Q)dQq)hubkbq9Fqf4dfE9FqfQwrKFvNP6r6b7)Gk0)bvO)dQa)IsXSk2F18pOcPMuZO1M8AdcAkPBfR9jeCWwW6s5rD3K5A3vznNP0w1GyGnHrZF87rB989oUy43fgHEIHdYXZN)Fp]]
)
spec:RegisterPack(
    "Assassination (wowsims.com)",
    20261128000,
    [[Hekili:T3vBZnUTr4Fl(lkstVklBlF5YnN8mPtBAsNMxM40MVjkyrijwtrQHG0oUJg9BVlabjbabaFr06SUYVKiZxW(Sy3f7Ix4Zn)Q5)287DrX45)01tU(9xD11FyYKjZVp(LD453VdT8r0A4hbOTW)9BjeeH4fGI9cdoSy4ZHpt82sgVmC7i6d)IFiYL2GpK45h)dbZFqBBt2Hxo)(F9N)7)R)2hrIn5873456ItFpmzPDj(XdlI3GpSGFTlxfgHFchDyHlEfkXp(WIV9x(Nhwaxg(Ls7K4DjffKlJcxNGV0Dh5s0oFYL8xDm8hJ)pKWGrVdesekG4dQHl87qQq9ihwGCDdd(k4hpIFHm(WI)kkg9rnGz4p(d)g0iBIJ3r(4LxU2lEtYdu8FPYJocAtaZOhMSAYe80vl)WnqZ(7H)(HfFxwJ5d)pFVG1WJfaOjimic5b)4xE6VDyXUiVWiVypmHQ0((HpFyXpS8Ldl(3yVacGHNbztBduua29pd6VVpVHEgJ2r7xwH89FaS5uf63O9TKesmYlGQ6PsYfTfCiYf2lzIIWng78cypnG77bL7WcQRGl0C)sOhHkIi8wVaxCeHlAmAjaQnWVPDM7IWRWr4GLy61EcZAvpqZdFgE3FLASaqHJJHobkiVpgJ8PAf1KqswVgty2jMrpmj2nK(JDj((Km9hDyrcb9Gp0qH7Wb4OXGRBu4kpFWdhTK6Gqgd4amrpGIN9SNVVtCOdjj6jVNWVZB1mMpJZUNWolddIX)r8GliP4a7og6bhK(aK4ewFX)OuJ(NMDjRzdx5aVJdawc6rCqdA7SxH9urH(6fcecH2HDqrXEK4g06BdFcVfheN16dEiz1QXsT2yxQfrRujXHbyaGBRLehYABxpM7i1S4SJ5Pmoz3(s3c(ngrWW9gLIPCzzdpBqXX4iNLjrK6z)kjx2RcsLluXg0IGJq78CDIWRPEzSrEExcbdw9voRx6o7Q3rfHp6fNhWqe0S3pPaClrbo0wcI6tLz52YMGXixhF8loWyfyfP8bMuIdxV2hWoeTfqa3AYadYLkU1E)xOJXS4GrxIrG3sQHtrhHoqS)SFege5WIVhIYPsNhAnzWfPsLghcb0oq3km4ZGc7tmkAnoEWw4TDOdrmMaq5UjPql)QoW4fW)p1Nm7TzyXH(mZUspSDHEj)xEZI6RBlQ)5vRApOPnwjmNDrlqgEetiUgUhNkipSeMVAFz1yqEcM8wj92Z(kusC4xnY04ESXquuqrfIRpPPLCsZ(KnGUh231jn7Q6Wr03pKcHGyOYNKii)y8NMoy4WuumE5gi9Tdzty84hdkSmS8p0HVgm8cdp5ExmR3s460(PrfVXJEUbWajLFfXBWFhsOF4(uJYypc38qTC0HFGcCgTphYOTpKq2WBr(1yfEeJEi9QJeIFCrqI9SEQhWBGciG2I)ARrrrHXyjv3njIP4P)f)jgWrE2lWqTbB5d(ixWO4dD2VumQCE1qzoH(iAgEhA9fzERmdP(gf(9wSRxSUubhHm6WsuEflm5uwoYBJIqoXLECIl44KuMr9YE8znn9vIGT6KZFwX61ndRNQSYLZa3qhGtfq76Yh6lA4CVObWcUH1RZYbu2kMEtUy4)XULXFAwUpIWR7K(B1gN1zeQVMH61(fTGgr8O3YhlC4UBs5iK0lGdwdUzzLLSf7JZ7CwIiuHrZsrFTS1gYb89Wrrj7kLLt59E66ztKHuUBYRoYuD7vRmOXrbgC1fJow(iVnwgg6tVz61GYdbVxYDZuap)67l3RD1iTX53jpcQzpu5C23WYzFHKpL5(E5oQA70klYPDKilk3tPeNBn4aLv(fp0hfqhRqxTyMlUd)eIOnOuyWzRTpDOVc3I1BcjXqczsCK3J8rMsl(u5om3SAbKQhDG)Q8HfaWiG99xWaOOgmYy4rxJEDMrz3K62lFrx1nVcdXyTD8OuuOD6nB8wVbMUfunDS6WwQUCfd2u4NPuFJH8(VrZUlQC8uSVBv4YeIyKKIgouVkUx3LNnDWfXiF4xJ9c8I9GjY8egMTbTpWDutt8lI20IrofG0AjnIqkRwOM5BCB9fa(jpYs6SbXnse3nBQyRSnj2Z3wBWJB4pMbulNWzByu0giORr4sUriqFpHo3604)JOLOv5ZFAJRYdejeZFgjtOFyORZQKOxSMwjVM)0RfHj4iyuiAve6MhaBWk(Z6fSeTdTKUkuWqudLIa2lmIfmkgERhgQg5695PlYYC6fKeMqCsB7rdyZE)LX(HGLMpbQcfPuKZd4iaUpcn45UoMRiLRnWpjatC8HH2JpZ1srvPSEMeHFeDMQHFtMgYuIs6MX8rTwTKuGbAk6WjaQjLozL0N0sQOombJMSADNkBtjTM35vsbjG8ESd0l(W40wdAeiZXgCKKC89wIDOR9Jl8JoSdTBIcsNAJegZMM5NMDvDMujDYZqCthQzYrhCFEUyuMcTcYfkIx5o01OxRdJuc7LWSWDyzS68rY0l8cnPOKkUwim(u5hzjehnQQkYAkw1gOn72mxlBLHnB6RsWL6sYkgSffgUTg1GvUiZMIMAO(YISC53nvK2hq8IgJiJL02uG1CrRj5P(b0VDWfkP3OXSClE(EHYbWgAGAw94Cikk1Nq0rIlhepSy6)Il87EDI2WJwoUm7(SGstZTk2Bl(o660POrIOExeEhIVFDuWMbGuTjdQ5Rvi)Y0DF7fRTRTjtKleXD6MlQHgVvwT9cxh6YApiSHIC9v6ECTo)1YNLbF9)TIe590F4qdTYaWG804ReU(O9civ5H7ELyKGtytBtB6VL5D1UmRwewEQGHdhYRm7HWWyNhd8wbLAa38oifJP7m14DUX4DUwZDYxdfTrNZUPy2aFA2hMqTYVfaRmOkpyOA6rldocoszE58z5WDAVqZvl8S4xL7tL)WixOFJU2(q2IIDIBOT7MoIH6TaNN96XL12khFQ3oBNtuvaAXK02B0Okq5k6SBDYQaUk5mAKb4lFnxpsQfDV0KoLNWLSeyrmc2)BN0YIEZTVIZEpfKMgjRSJwVZZBBNN6LBvFhVfyMA3mMVZK)JyIP87K2AfnNg)XHM9vfCQeVxEJ2MqJE38Zn3CDJr211U1hKihKqFXoQZ5nG20hYFMfYBF)tkSE676n7CzX5HEqZosh(w6v3sN6EV6ZnVABjY0mkjpvM4DesMPDy1(4IrP5UQxpXRS(2my3hoFMfoxvsQ26eXpfOxD10EFIZoFc2JQXBqxZR1(8kBE6AlrxBi694pZ84P0HrSp2jgRZTFO4QzE1T5htdxmkEJZwu0J5R7TEaj86xFl8ms)DHHvO9sTP8D2t46Pjz1VlK3Ox4IhpO(C0NJENv8n3AAFH6nZNxM5IWCtw17MnTjNQGEl(BClUMZFwXonZwAv6hqc9JLolbt2wUwCAXTV)W3bJdCHYXqlz3a6weZ(EgOhTd6NDVRh(tZE)O8uBR8rp7Jjeh8FGxMKQxYFWb9EGFj4bA(iEo06XRu)HceMVh4AjRmGxvFfhNBUf2omPgoQLcgVMFCqTU8AxKwbR4n63pKZqNk5Z57qT(r0ZOKEhSPzsm7aCMIJr6FCAEp9P4gzz6BG5NFpcoIcuAqaYftYt)M1vKLlnTVqjbB(QFDJUzB1NU881fw(JaX2bco3kiFcCvoRU5jjN27O8fLJI4r3VsxejJLwaOSgo6FOl0BNnyrANRImupUDh4tZmBxhPBKtLdWFF8X5B8H8x7CFesRIqkicjzQasFsM7M9Hr7ZQVrHNiYkVrWG9132Ns6lQqonFiv5D3Y1uNF6QfwLPSUL(40MhN2hh9fECutmVgcHmeiQuYtVVXBrFJ53)eoIY)tk)BeHp4Nqy)Btr6)Ima)8Ny)BvbpD78)sgz9p)Ef(VD(9lJ8aNmp087t9bQKHz58G78yaf2eIcV42cjPYpUurEJbrkXWTTqw1L3CPyyQbmKt)zns(24t3gtOUu4DRj4jYhUncILqXYkiAxkmEVcmKyPm42tkdH6sSUZVxy1IP(656y5xGcLV2ou(WeHgalWtVIiSL0Zlv8Fqr8fnA6xXF95Fv64ihbN2cDumsGD(9fuRR5(spjYKLQiFZBff56gPisS3lvpUAsNPiQFFPm9iNlBRG6EZ1ICs5TjkH6q8NeLqhT(2gE9TjQEzhXRuZ8y6v5JJPTZH338gISGBdFcwfHcANVGnqyWTKXG3RFDcsFOAZCGJgXmXQz6nzIfySvrZC185zz2eMjx1S72KRxoZT2Cr7Ps0WmPBk5nLPrk7f3mE1S288B1mqmdRQz4lWAUR4jdYQbz1MAI7eUjUyoq1ICIBe7eZ6QROcMBKkMQDueC9IWOGrTEgfWm9vhmcHDu8OwwIALM3wrj6AavlP8y2KIulUWKMWjZ3YLbxnp9wdA61mp9YaPAXdnaKvp8MvMs(4Pk5kun1Ad04oyY9SU9)1HNKTGYk7TPQHPz6YOw5JDC12tXYmSzAgWfdIw2RUoudBt4E5tDXsmfxn9CfkPjEzCVHJEshY)Yfgf(vbph6PUJ6Vr1etjVtRd8KQzwRQKbw10FzGnR(0kHRHvdTAjRMRRisn7qg1kzF3SPSMxn1vwZNTsSv248GA7KnhBHZutlvKqnBZxQuywADtR3OYQyFmIOUZ5tGsPlloIazsZA16onJckOWqc7gqrG5JyxhU71eTLwjVLkS8XgyAAwhqDNVtbLODo3bitd1Soa1X0nMCw4KHEg3fuIJQzDcQPdm2jW2KIZq1xdbwZuC1ulDMIjPcd0umyhqG1TiBBf1fCJ5fR(i7pS1dynp8RJ2NvNJKYBkDmJHg7W(cEUijgXMcGPMxy6JuIDvev6KEBkzyl0tk9QYD)tnVI2hP2lhl2C6YUH8LDH6YLHIEw3kzk(8i6W(c9qwyV9v)SkQX3vbtRmU1SwkvUPAHj(3UMeWndNg3(2ooixDxved6TWm3mmAAzGnpVGMcZA0HXXIPzkAEYxnfl2h(x9WPybQMMNyLZcPPiUbyYCc1xjs(UIm8tvtYzA0NuUZwcWfR4L0xBqt4g8UMCWPQ0TMMBRaBHlPhzqtI1WRlTHZKyDx)u9tBmhaAOS68nrR1ukodG1nhJbaAfH59tnHPU1Ist5meByzCzO51XLL1Iml7m9RcMi3EJQRV54MyEllOrhqSCGIKtyAL)YTWj4wifClScEhWH52jX8tkILr2jKiZB553SThGZt9j4SZpcNn7mCQCiozXtgx6DzHkfzj4EujpN)gIOZ7DUo1oxQLa328(gmmwuIudRXmUM8WKYm2v08SGFxZzg5xjQrUpw4uhlyAZ7SnqBNxGzFGuRym9A3b9MqH6hz48AKH6UgiM2ZVQ4mzl0hTD(uUscvU64I2683wF)EN)ZlN)3BA1YQtAX6s96hf3R))vrp1Gb2pzkDdHEFG)5vGFDx0AZz9ATFg)aXF880EVxZP2RPU7KqAJj5VOt0ATFV6MVU2svvl3ydvFuX5vurDp3Ocu(UYwLiSKUvq276rRW7tz796t37nMV31lFXJtxF5aNHUW1DdgL4fErNyt7YwVFWzLFGP93Ty8HQm6VQegFVdXP2HqDdkftBzN24)IM347DepLoI2pdTV3852)TdJY37W8zXHX2zm)9Q7jyZo71nNu6RXPN2(Io(Qql99EMNsptQFNPpTe9NoEZSwFtPT(tlV1N3p9wG467DYpXo5FTPDws(Z(QYbunZR9FEi2(EhPtTJKPpNCDF)lv6cjBl1InL1YYWtzIVGnyWAPZKcCpY9CPXCgSYx2sFq0zBqKj6zvpJp0hgDeHrTGI8RIJ8pDKKFLDL9rMDCKPPp7jlFNI5gJxfo0VpCUISI9bBNTbBg)EVR6JcUEwFdXzgIwvQUQ315nSRtmBRpt)E(N3ZP(nww9CQFpN6ZAaCpN6Z7k865u)Qve1p1zMEKDXEo1VNt975uF(dvB2G1aN6Nzsnr3gQ1bZDk9r0QvC2LuWeomRltgh9PkR5cLvQgedSjmA(9Fp(rpFVdlg(DHr4NsjU345Z)Fp]]
)
spec:RegisterPack(
    "Subtlety (wowsims.com)",
    20261128000,
    [[Hekili:T312skoUz4NL(gwOYeAOB6zNDQHUQKk7MDtL9qTSj7Dyeyb40gBkl7U3offp75xYY2sYs(egMMj(MzO9b9F(GKL)88XZ)T5ZSrH45)0DJU79JhF3hgnA08zHVUhpF2E0QNqBGF4H2b)7SOLHU4WxpUO)l(VqC2rgUYF3a619QRpYMowlJCCd)bV5l1oSK94vZN9R)8F)F9TFKWhT5Z26yBJJVfmzLr68XJlc3IpUGFSBx7hGFghCCHnEnkYn84I)YV8ppUao8XfcdrKZTuYsUnWFte(w79KBr7Dj3YVRHWFm8)q89g8oy8dqEexGVTHF7tPNd54cKTTV3xb)4j8RKHhx83qHOpQHp6)J)WVbdY2WW9KpE7TBCc3gTKY63QCPdGXeyx0YrRhncpz9QpCpmS)U)VFCX3LmyUW)564TbUmpGB889cqoWp(LN)2Jl2h44h4e6Gju5111)LJl(HvG0(VXoEeGhEbOnDmqbEy7)mi)UU8b6fmAVVhCBix3LG9Lkq)gvTsIiHihpQOhtjB0oW4NsSxtifHBh274XUAGVNbc3XfuBVnmC)IVdHsIa8ohpBCaHtAmAfWuBHFtvM7dWRXbyVvy6XEgZgvhqY9FbU3FLASaMchgckbktoleJCPsf1KqI2Sbty2jM92pk02N(J9rUUKe5hDCrebT0fgi)9ypCWqWxnWFTJl4nJwf647rgc8byIwIcN(IJRRvOVfjk4zNNXVZz9uMpJ1(NXwR89cX)ryVBiX8b2EiOb7fFbKWiMU4FKBq)ttVLnS(RTG7Xcywc6jSxng7KBHDvb(U6jce4G2JTqbHoKWAm678FgVd7fMm69wgTE9qPrBOn1IOLQKqFpmWG7Qef7ZgBBhM7i1SyTN5PmmA)HCNc(ngrWW5geZtP0Qi(zlkmehyTkkGun7xo6YUvGQCIkoGfq4a0EhBRa8gQxgIE(3frWGvFT1Mv2th)okjCrVATedrqtF)OmMBfYZIosquFmnZpwfrymY2Yf)QfKRaRqLpWOsO)MnUaVdrBEeWTM0ZaDPKBJZ)fumMjhKDjebElXgofzeuGy3P)iKe54IVhIYPuNhAnQ3nXuLghcb0wGAfs(0lZ(eIc2Gd7TdUBlAkIHeGvECumRLEuliFb8)X(Kj3nJxSOxZ0X6zBBql5(6BwU(UMY1)861nNPPdwoEo5GfWYWLyIJRG7XLIL7NJNhFiVy0lTat6OeF6PFfkk0)RgykVhlhIIakkqC5jUSKvC1NKe6oyxBR4QRQPJO3VpLf8cHMEIcG6JHFAsV(9J5IHR2cLVTiB9dh(KxMLHv)HM(Qx)BmCLhSXmTLWXP6Pbz3Xto2EqIK83I4jIVhIVR)GdPCfA3YiYw(nXpgR3Iq0Y4JoqieXgb1UtuglXBHEeGXIFBBqbb(HyjPZokGjBX)f)k6XzUKBGXygmxlDr2GE3f0NVML4nTHNe)mxeTiUfTfIehsMTs)Gc)Eh22jux2(tGgTyxiNXEpUKDC82OpJlC3fx4EkUiDsuTceFwRepwKzlV(7NvE9U6XRxQcV5lYwthGlfJ22Di01xWvqFbGrAltXYsZN3qfFsoz4)X(vHFAAQBGWTBf)B1bN6FU3xFBbvB8ZgbnK4jNvpL5t94O8bbXha7Tb8Ks68yh2fNQCwHiuIrlerVTKv4XcCVWbbr7Zvit5(E(UPJKzPupHZoNP6zRw8V2o6g8Mfdaw9eFmw577spz8XGoabVxYJtvyE(XpKxRnEG2q5hLtsA2dvUS89SYY3i5tzw3lROQStRmjN0sKmRJoLUyEWGdushw8qFKhnxHU2Tm3)g(zerBqPq(3chFA6Tm3InB9jHqnxsyGZt8mtX9xQCgMBwLyKYZoWVvEAbGze49d3WyqrjyGXWJ2M71zgLDtQQw(M2snVgdXynnFumxODgmBD2SfMrf0WCOAAlvxUknjrLEA0wRxobrCH13T2FvePGrQV(2goO7WtN07MqKl8RHoEoHoah)mg6KNMJ1UKY0ISww616jGt(m2YIi)Z7B4sQBRz3mICBs3u1tx)q1nN4NDiROtzexls840jIJYUOqh3IgdEKh)YmW1YLS25heSfcBRfFjpieWAqOtapodYjms0PcWVAJlfeKYjKFnsMqxFFBR1rbVwyHP0jgeFSambha5XO9HOBYcS0D8R1XBfApAfnleKKRVK72bHCEqEq8ohm0pZDhsl4Ku71XlYpIyfp2d6XMI)RdD9blnFwwzcsE3uCaWUpbd41UmMki57UWnYdtSCHIdHx5sPOOKxoJcWpHUsLWVjrczcrozZyY)glwY52102ILh0vlD6oLM3Vfl5uLEjASixKqwyDNZKasa69ulix8040rdgeOYXwCGiDOZofCRArnPSZdV3MSkF8(Q5UkCYh7QOvJ9GYcggU1AhkO9unjmkNHYOqv5jIRZkSfDj2SHF0IkY2ipYHBmyasEUbsmFYAa8PPJRYm(x5dcgRaARNyvVApRx5So84TklKUm)LSccRhuwdInHxlXZOLIHvxEyXy6aF)DvOvp5mBTapPNKMtJkV4u8zJloV4KdLBcX6AAUjSDd7QUUKYuaxf4bnfY1xC5HE3OuQL(Ga5UfPp8woZULgLMm3aoVks1Nr0Qc5JG7NTygIlJ9bDK2WLMpOm58SistorHo7Wpsx1rfjsznk2J4pGrkZMWaXstcRMUYN8dtFCHVw44w0eBsjI4JMNtQ(gpvY8meooOYAotuexKkVsNJl1P3w6mE4vckKtK3ec97Byu6bgKNhow44doiWPkxC7ledeCcR7ywK8xWCatPNsruHKAkNrtuQ26f973N3L4sF)qRN8Cwd1MHt(40hoy6mtmEM7nEM70CM0v4rB0507ZMzYNM(HruR8BbMvMPYNmuTgAbjhbhPeVC(mU4oT3O5OzEw8JY9PsVyKnO3OpPcOSr2ZvSFrNnoJH6PaNNd65RchRu(t90jphivbG2VjD8gmOeUCnDM2wjTmwgDgmWa7lFmBhsSf9G0eGLN8Nmfyrmc2)hg1RzHMP2xXvsiMjnLjlVJwNZZBBNNQvBvVIVa2m2UzSENj)hXctPNjE0Ygon(J9n7Rk4ujEU0bTjHgDU5xBU56Yr229U1fKihKqVXws58gqA6c5VYc5l(z5Kz90R6n7CvGZdDBZDIo8n0RUHo1DE1xBE1fvittwsEPmXZiumtBA1U4IbX1UQMM4mlV1JT7cNVYcNlRivtDI47P1XJN05tC15tWUunEd6gET2NZS5PTTeTTHOZJ)kZJNcrhHUyRqSo3((IRM54hs3Yic7nbmFDV1Zqc3(DpaxJ0FNzyfgVyBA(9arCrw9pfY71tCXTQuxn6RrVZs2)3MEUqDM5RlZS8MPs)(9zsD2vbDw834wCnB2VSN0mBPvPVom03U7KcmjpYvHDZcUONp8JqEGBu2BFr77rFeX0xDLH0T2bfNaSDWFA67hKwABTl6fxmHyH)d8QOy5s(nnOZd8lbpqZBwY(fUFe1VHZG57bUwYcd4v11XX1MBrr7KuTnFEI7f0cxETBI7Gv8eDppKRqNk5n5BFT(r09OKEhSjjum597kMpgO)YP190xIBqbtFdm)8ZrWbugLgeGSXK0YVjQIKAPX6cLcSPR(196MTvx5YRxx48BBBtBi4uRG8oWvzV6MwKCsNJYxuokIVRQL6IizS0YakRHJ(l6g92zdwKM5QiZQN2th4ttnBxhOlZz8FN((92fFC9gFi)sK0fH0OiKmKBsgyJ0xK5XPFyWHK(Buq9IK2BemyF9dDLK(IkKtZBuvQ6wUN66(ot1fNw3kzDXrFrfhvhZRHqidbIkT805B8w03y(SNXb0xwwLpufUGFcH9TXi(Reb8ZFI9TYGxUD(Fn5diW8zka278zRcCaNmh08zX(aLcjUCG7DEiWffrefG8TbusfqFPK8EdKucsEBaTQkq)s5Hjg4HuWCRw0ViaaU2iamL9EWe7jcGV1IfZXfRkbzGPSX7vydjmxdo9O8Sqvrc45ZewTyQVEQmM)gOSYxxmR8HrcdawayHf5WgINWuY)bfYNnOXVw9vhWyP5robq4fuumuRD(SmSa2SU0rc9BPcY38wrqURwcIeCdtLJXJAnbr99lLjhjhSmSgovksrr46ieQP4VicHoCiUjarCDe98oIJvR8y6w55X0QC46M3qOBCtWkWYW3ydaCCdr44d6xjG4lkbsDI)RcH4yMruTwUjJOacZkAilh)rZJ(Xm6Qw)Ui66KI0S1N0oQaJmJ6MkptbvK8(P1dhqRmUexoIjZ4v1A4z8AQZ2fJLvdJQmuk3kyPC2SCQeykxl0uMPQlPhL7LAxQzqAC1IWOmJAhlkmZKZoZie2r5h1gpu7L8HsAcxdt1qiAMnTh12hmjjCSnkFJULJRWvawHnJRWmMuT9GAWKLNERqKD(0H25sen1Q)AChm5Ewv9FvW15c4Ys12uXW0Czzqb9PMxT5qcnJ3QAnsP9mCEh9QGnTXjaVtTUyjdLj4x8GHD1rJXl6mznUbkW(q39AuTaLTnvImRAtPIIHok)C23it0uljDbTi1SHYm1o)Okgj16zjxDs3VLkBgwn1IDCOuwTYvwEGKnPuJO9JtNWwnm1krjdFYk5w6GZtzumwwZiLPvum7H3ukXky0nTuIkRc(PqIQoDdb4Xop5ebgB2Ow1eLzqyHH2bQbwdMwpOk4qSjaeToirSbuZMPauZBBubKcPAxZkazi1MPauRayS0VWol9kwfKdVTzkb1AfgvcShYXvO4RbmUzcU5f39efm5sGAA1SfaJ7guAUKsT3BEnIpr9rrAGcRdFEKEDndoXu5ygcp2I6cETij09MXaMxt4wHIjEJ8Ukpb09ot3WVyfnPP(bY2m1NnHRwicoJzv7SO1yS2jp2HwhnWf8SLUvfJyv7nk71aPf1D6Txc7Hb1xFKk8(JWKktlGBrT03ePWGZMPjC225yuFOqI5Cka9Xz8OA3aPLmKsF3ImREEXCnd515vgwY1Gl5mHY0KilAcqnrGmOtnntYsNHuD5HAUR8Om3dMFGQNjKmVK2qEOQR(zmaHlXWzl6N0RurDaa92gb0zIKPsIcqIUKCKWAsqJEvXgDgfR6mM1p32ugqdUCN(CeBmUPZyWQwGXadwihMQNQdCKRLlnvWqCGL5lddVoa7Ssi2zRjFLa36fpO60nvDYZ6x9GuErl6HvvSyNXiMkzLRSAHG0EbaFEbiFEbqFElau7fJu7xuowMZUGO1Ed3KQnDxQEP3MQT((uTEBuvLDQklEYu3skevkYsW9OuWC)neAU35CDPDUu7fUP19nyykqiInSgR4AYdtQYyBHL1c(D1h(Npt4)CxSWfow49MwZXIs026ny2fi1iyHVYkO3ecuxMHRRmdvDnqm9GjldyOlaJSlg0Olf1OlpUOPo)n13VZ5)kZ530QLvLYIvfF5pjaM))RIEQamZFXe6AY6Db(xxb(vDrRnx1RX(z83jGthm678AU0Env9jjepys(l6iTw73z3812wQYg5ABO6IkUUIkQ6E7uax7vEujclPBjiAVEUv4(PqAF1X0(AdQ96PV4E(RRDGRqx4Q(agn(ISy6PS15hCv5hy657QFdfQFFVDgrf)ohIlTdH5nUDzyJ)x0GJFNJ4L0rS4Db97nVz6F7aB(DomFwCykAJx)1v9fux)gVU(iVFf260fVOJNfS3VZZ8s6zs97m9oIQFRXBgA(Rl28FzbN)u90Bb05VZj)s7KB6jlz(LBOuCNwz3J)zb9(7CKU0osMW)dDV8(L6cjBl1YBkRLLHRYeOiBWG1qNjf29eFMl1gyKJ)72hI)lvU7cIA5GitGXQ(3kRUWOtimQbFhak7dbWL7lbqPQYUiZwoY0ioeB(fwm1yCw(qb0foxsvXUGTR2GnJVv4L92bxnRVH4mdrRkDx1568g21jK9OpJFr6N39HdO20Q7dhq3hoa2aG7(WbWvfoDF4akxquFvNzYrYb7(Wb09HdO7dhqL)WbKy0mbOgQD6YD7Cr0(rS2hrb9gb7hJgvDdbxcaixhIYAgd8Y36hmF23JFYX154I(FNFagQre3R28)h]]
)
