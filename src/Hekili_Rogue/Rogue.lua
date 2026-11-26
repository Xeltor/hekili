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

spec:RegisterResource(Enum.PowerType.ComboPoints)
-- Adrenaline Rush (13750 aura 110 misc 3 base 100): +100% energy regen while it is up, a rate multiplier (C3b).
-- regen: energy's base rate a second, the belief's from the build until a plain rate read (energy is secret even out
-- of combat): wowsims/forever's 1 energy every 0.1 s (sim/core/energy.go:48-49).
-- refundOnAvoid: the share of the energy an ability flagged `refundOnAvoid = true` gives back when dodged, parried or
-- missed (wowsims/forever's MissRefund, spelldata/attributes.go: 0.8 where the DB2 flags Discount Power On Miss and the
-- spell issues the refund). Not Slice and Dice, Vanish or the poisons; Gouge is flagged in the DB2 but wowsims issues
-- no refund for it, so its registration below leaves `refundOnAvoid` off.
spec:RegisterResource(Enum.PowerType.Energy, {
    adrenaline_rush = { aura = "adrenaline_rush", mult = 2 },
}, nil, { regen = 10, refundOnAvoid = 0.8 })

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
    20261126000,
    [[Hekili:TZ1wtkUnw4Fl9leO2zPH(wMm1qx1EjztsT5sfYU5nmgBb4fJnLLnD6TO43(EKSSTSSKSSXq6UwEzgAFrNVZfDohj7ppB8SFD2ux7y0SF8Ur3904X390OrJMnn(1DOzt3z7SXEf8Ja7TW)(3c3UWo(48(Ve(c2BlEOt42bKR6v)qBxYiTiXZp(7cMTq6GI3HCMn9x(P)X)6R)KdDSMnDTNRlk9gqyhfY4thNhVgDCo7y3UmmcThfDCUlAPDIpC5)LF(FECoC4JZZhGeVBjceFBu4Qe0TU7W3AVZhFl7Egc)XW)domyWhGrpYoa7di2f(DirAE4JZTDDdd(c4hBqVIhEC(F3o2(tsqr)F47(vyqwhhVd)PBVDLx86KfeGFRWLoagtaA2lgTC0i0dlD(49WW(BH)2X5Ft2G5d)NVxWk4Yca0eegez7b)4N3)1hNVlYlmYl2dHjARVF4lhN)DoVEC()g5fGbm8ciBYyyhfGC)ZG(77ZgOxq27cdGBZ23Fb4xjk0VsmQ4eCSTxar1tLKR9wWPNlSxZefM5f25fqVAa3tbL74CIx3fgUFo0dtereARxGlkcZenY2ba1A43eJ5Ui0suekWbro2EeDu9anp8f4E)fIZcafkogmceqongz7t0kIlbNSAfct9tuVDysSBi5h7s89Xz6V9X5jy7f(WafUdfGIgcrPrHl98HOyBNyVWa8qahPbHtEXZ33ko0cNeT3Bp6dElNqJzS2Thz5egeJ(94E3GtXbYDiyb7LEb44eQT47RmO)Pj3sh2WLwW9ybGfBVbf0GXo7wOxvuOVCHatAS3HSSJI9WXny03gUhTffeNn69wKSC5WsJ2qxIhrQuXXHbiaGBnsI9PJTRhnCK4wS2rJugMS7qLtb)gzJrW5gKIPCzPdpRTJJrrwojryZ8FvKl9wbPYek)aQrWr278CTIqRirz2KZ)Hemc86lTw54oz8hiIW3(vRfiyg0KNgvaoh7alYibZ6tLz1XsNGr2Uw(OxTGCfibP8rQuIdxTYhWomBladH14EkKlrCR8(VGHrT4GSlX2q0sQJtqhbdiYFYpajroo)BHz5ePZMAnQ3nPsLmpeMqBbMvi5tVc)tSD0kuCVTWDBrsrmedq55rPql)Owq(c4)tJjZUBkwSixZKXYHTlyL8F9nlQVRTO(NwUS9GMmyvWC2b1az4suHydcpUuqUFfmp(qv1OxEbM8rj90t(c7K4WVyGQ8E0CickiVcX0N0YswPvFYsO7H8DTsRUkMoIC)HeieedT8Keb1hJ)8d963pffdDwdLVTWRdJhUjOWZqR)qsF1R)nkUYdUiQ1I74e70GI7yJNBaKiP6TWFc29Gd9dpK6ug6HzUhINJK(bAWzWHCiBVDrcEnBezhJ24rS9I0JoGB(JRnuypZsTaTgAGagl2TTYokkmgvs1DtIOkE6FXUIEmKNDduuRWxUW32fCk(GX(1ISY5DdLfe6BtQWBr6VilAL6iLpOWV3IC9ILvk4eKrh2IYzSXKlz7iVnAc5c36XfUHJlsBgMv94p0Y0J5bB9fN)dfR31mSEPQkxTcCddaUuaTRBF4AtdV3BAa8GRPwDAnGQEX0tYed7p25e)5j5XiC3Uv6VfhCQXiuEpdMn(fJGerSXZztra3ZJQodj9aOGvqywwBjBr(OCJJJnMimsvkYTLT3qwqShkkkzxLQCc33(7MmQmKYdto7itmSxSZGgplqrOo)SdNnSXWjm0NCY0JbThcrV4NNiaE2Xpu1QnEG055pxodQ6i0Y1SVNwZ(MsXuQT9Lnugh0wwKp0rISODpHwCEurauw7xSP(2bKCfY6ftDZDO92yPtk5soRD8jP(kclwToehdfKXXrEByzMsB(u4m0WmJas9zhy3klTaagoSF4gka51GbkNE01OxMBSCyIPw5B6kZ8semhRT5JsrH0L3S2B1Ay5wq30XIPTQ0XT3oaJIZIxg6KGt940(OFDOF4Zty6l7wg6a)RG)vwtePhlcHrrGArslja6sMKIKFfX9c9BPOpK3ODBWRCSs(8MxPAyF5Q4bzhEYd9Uj22h(1qVaVypyHv7rWQFi2a3bnTreE0M2C0LaKABXIhsz9M1SyJhnxaO9EyhYQtrnsepp5b(rzBsSNVUXGnpMDzkqD5cGBdJIwdtOAeUkpiyW2JjR1pnF0jmsKvDWUAL76emtiMDnLCH(HHUwltIEvBzoZtFuuDNDTEbo27SDi7kgKYSFPzah4YGczvrB9qq3r3DiV8vwLCVGKWeSv6ypOhxwWhylORqrQmZzbkcG7gyaFVRJ5ks1Ev8tcqylFOut87CTKxvQQNjrOn2Vt1WVktdPkrfDtz9OwRwLuGEsAcYka6rMS4P0RutPOoSaJKQADNkRtj1w35mPGyqEB6a9ILgNmAWGavowJIkNix2d04efNyWEjpNlyiiRdegXsnM0AzYMPS27ZtECur7FyFphKfzx2CHFW3qVWzi7xFFfZslntOSdQ0G0HrIDt6dzkkB)c(8KXMS7aKDbbs40HAw50kSKfmXiSxinY5jDMwPoDCcbetl135LaKl8cnPOxuMwuDPyCxcz1ydQRv22Gv92NUkBJ4EMZN9jkmCRbnLwDXbnfn6txZs)UljWbI7i9l)sysGlollSbquzh4nfP1lkj12LxV5XE3iu9LmZGz)ZF0XmmTMmDiB5cmiXl192KcfvNQ0Vy3s43N8dYeTIlTA0F25PH(Qw6xS3w0ZKT1uqJ4r9Ui0oB2J3Ka2maKQnzqnFRvzhM8WkFv74QBTo5cHVoktu9vEQSLEWDCWK1EqOdf56BPZX068BlFrqShxIwKuUJH(9vmk9ahY(HJ5o(GdCiv4I7ELyaxqythtD6VMLf2U6xAewEI5(97ZYCTimm2AtG3sOGoCYNN84bvN5bLN5ELN5ojNjFlEKo7CY9flw5Zt(4iIx(TayldQQjdflwzyYrjnW2NtuTUf08gg4xhB6CdvtA6GmgcAJ4CdXtZMEOCkVY538t3Ypt6OvmCsu9(QnlfdzPZLpOTXlO1IkZZ31j)U6pk7pi3yhzCEdOn6IU0VvCqkvTgb16HgCsEhkorBBlnGT0(16PNs89SjO8NHBkQ0GLRUGbPZinZsCM13Mb7tzQxBXl712y84h0lEfBoDEWB6((Mgfw4stpk1Q0RgmQ1DLUAeXtbgTAUTAvCrOs25hY4v3aVK4hSY2TQ6etn(wcR8I9rwqJCY6dIV1TXpMV7SUi741wBTJ2K3p5bPUdUB)UhHRP0Fx4w4gVupcBfZChpnkv(Q7VxUW5FQa1gKxZBzUQw71mIfGx1aaD1329GqY2pwSeiAllKxeeYl9CMhkBTafpLv9lCbwyr(MMKTlKj76Dt)YXFtEAqEyXsF7x8rySf63rojPoKYpJ(gRNQ3h5(A3dx578iKSrMcOnWq3MJknC8e3EtTvSUP6ZYR2gNkTfP9LczYcpLRlpKT)bzph)86uQIzKyDvN2auw25WOicgjMABxu((nMpZolemDQTqCzETK7Lml30qTYpElD7LyUhQ8M3jSnF5MGhApM4FjlQfn8j)mkJO8l6gP1qvCX9LlD5dHkOEADq85jkRKM2pMOTp9VZFXum0vu(Tt5QZOvoJIxK(YVk5YN688Kpo4qwccH3ZWS8dCju)YhB)enjp0IClr5uF5B3exH0So(Ugs08qIU0L1GrsL3sHpVCoJJF)SP7rrKxaxHVhh(aKW0paiPFsmGF(J0piiS41z)1SVwcZMkqaXztDI8a9XZE20uXvlf)yerCwmGcDcrGyITqsIeuKiY7viYsumSfYYuIlsWWdkWq(7FEJKVocn2ygnsG3JQGhpHeBeeRGcNAy6ibgpjaJsVM4WPhvfcMYSXzt56kMeRNRJvVbcu(s9q5JJ4gaEIsYJWwYpsI4)OG4lg00NsV5eG7ejviyOOSWB20cUnQ2wwMnFef5REROi31ifPe9jj6X4rDMIi(eRO6r2bRJ7K5AroRiBIsiMI)IOeY4vzBiwztu9QbIJfR8O6wz5XKACy2M3qS1SneOOoguONWMkySzlPSzxXztQlwSsVkxmhL54DZ1tOQQ05KkxXQ76KRxo15AUO9ez6jv6QkEtExLQgf3mInzmrlRNcOuSkwHVaR5HIxmilojZyUH2jKdTHSdTr0dLAQRPdM7l1mv74OPzZWiGrSFgbW8WzhmCt7i4rSTeXonFSMw0LaQwY5u6IIeBUqLMWytz12GRNOKgWts1eLKcsXMhAaiRp9MwQQE6CvTgvtS3ajHdQcpn1(Bcrv1GYAT2e1q1kDPCB9uZR2EoUsXMynYcW0iwT2sATc2aYJKHA5uUqWuPsrRQAQfP8Roh0eM71eQXEPBTJQ4IfORrjvrBMwWBMM2ZxHtHDuoFmrteR)LD1PDTEr1mT9atbRy9XmWM1nDTWvX2ewVKfRewKxj75X1kz)8KhO79MyLTSHpBlkRDWzPG0tpxQOuT)LfBaETctZORAJlf2E3treMU8fog)wvCyoU(shvtxCsXBqOI2lmpDBrpBMqTsvKJQw2rvprGPgaXC5kna5Vs4VNnaLzjm1aiMtxzReCpV(3XMGkuiMAeelhO0iqF2pVdvFj8lMQ4Q3k5tuXkPcNj(f3IQT10xW9Q3r6t0EOZc0oYhFsAFwFo8k)dQkhtzOshAly1IkryzkauvKMN(oDooeNxrrIQc6cpE4oemnHIZnMJZcKCMQIInu0zAsxL(sMswp)M5cBlDRcX6QxX5jQ9Lt81Cgq3qkqZTc1uziONM2FtXBiyhAlKdznVzHg8Qfs1kv7uSU1L0gTqI9MiEvRESRtuk(C04tCQHR1um28fn2uyEwiHnf7Qw2zTlNQPQGAm8O6hP7zID210AYJMUdRPKEUeGv8UE2esD31S6MQsQQYYrZ7s6rg0kr3Bt57nvIMUkA5R3nhas4A8PZfCkapTfKRLH1TJI1srPQDavvJAnIdLgrIYot)QHc5nId5uBJPlOw(ok0YMdKbeJRsPL45AiZTg2CRHo3Da5Z1Z(8lkI7qgOtDAQkBRzHhnIA6NvUPt1aXI3TndM8xu365oOYChQuJdNdIsFsCl2yYftm4pPAz76cz688Xx9wTIy7gBGEtOqsd)mTVuvBGCDmnwdPR1Zc5APHC9g)2AHBRbwUfUfBgvJzf)jrl()VYfza54VykDdHU0OltxsK65VTwz0qEEk0mDXqvFSmDhV6BlX6pFmR)CtTEQP309nKJ79clPWCw3BeT7nN39nM49gXJnf2jtxTxjQ5ZBPuTKhzct1k6k006g5gYwFQuv)mcRJT(VFORFnBJ(tQFUGNtk8B2ZY4ln9fev(E83C()BWU0RVUSHFbaOkNQNjO8T6x9NgGM(Tb4I9Xb4m)1bGAev1bz5hiDTrfQ)Sb0vF3aOOv1BQQSxlSAXzjwaBuMEfxLkkl3iol3mslxhRLRT3QgtB50)2KpRaupLkMRk)TQ7QV6e8vT4RoqDF2boLV7au3VsMbR(50LBLolFqcUgZ0(plbupQQhSETp5vJeHkNPIqIYjJa8ft7Jo9XJp76hLGglRRFucU(rjGoax)OeKzkU(rjWafr8Hys1JSdE9JsW1pkbx)OeWUiJjOMIpkbzUu9VXZIRxd0us3kw7siCjLZ7sLHP7IUYTOS5cL2QgmhyDy0SPFlAJNV3X59)MWi0(uUegpB2)7]]
)
spec:RegisterPack(
    "Assassination (wowsims.com)",
    20261126000,
    [[Hekili:T3vBZnUTr4Fl(lkstVklzl7C5MtEM0PjnjtZltCAZ3efKiKeROi1qqkh3rJ(T3fGGKGGaGGu0o2t1xYPJVS7ZUyxSla4ZLzJN9BZE0ffJN9t3m6M7hp(M7hnA0ShJFEpE2J7rl3Iwd)iaTd(VFnHGieVauSxyWP59Fk8jI3oYWLH7gqF4N9drUubUiXZp(7dMTqPSj7XlN94V(Z)J)138jKOiN94gpxxC67HjlnRXpDAE8g8P58RD9QWi8bC0P5U4vOe)4tZ)6F5FEAoCz4xsYjX7AkkixhfUobFT7EY1O9(KR5V6q4Vm8)qcdg8bqjrOaIpygUWVdPk1JCAoY1nm4lGFSf)mz4P5)Dum6tkat)F87)nqiBIJ3t(01xV2lEtYck(Vw6rhaYeWmAXOvJgHNSA5hVfe7Vh(7NM)TzcZh(dFVG1WJfaOjimic5b)4xo8nNMVpYlmYl2dtOgTVF4tNM)9lF(08)n2lGay4jq3uzGIcWU)vW(995c6jmAp1VSc57VagZPg0Vr9TKesmYlGA6PAYfTdciYv2ZzQIWhm27fWEAa3pcg3P50qbxqC)sOhHQIi8oVaxCeHRAmAjaQnWVPoZ9r4v4iCWsm9AhWmP6bwE4tW7(R0blau44yWjqb5JXyKp1QOdjKK1RXe24eBqpmj2nK(J9j((Km7hDAEcbTWheu4ECaoAie6gfUYZhIWrlPbiKHaoGHOfO4Pp5577eh6qsIo4Da)bVvtzXmo7pGDwggeJ)J4ExrsXb2Di4b7L(aK4eMV4hQi0)Y0RzInCLd8ooayjOT4Ggi7SxH9urH(QvcKcH2JDqrXEK4gi9DHhW7WbXzsV3IKvRgwsAdDPJik1kjomadaCNvASpt2UESWr6WIZEwKYWK9hRCl43yebd3BqkMY1Lj8SbfhJJCwMerSB8RIEzVkOvUsffObfhH2756eHxtJYyZ88Hecgg1x5SEP70XFGQcF0ZolWqg007hvaULOahQKGS(uDwvwMumg564JF2bMRalPLpY0sC461(a2HSTacewt6PrVu1T27)cog9QdMDjgbrlPdCs2i4aX(t)rysKtZ)oilNQDEQ1OExLQvAEiKq7aUvyYNEfJpXOO144E7G32HofXqcaLhgLcT8R6aZxa)zAmz2BZWId9zMownSDbVK)ZVzr9nTf1)8QvTh0uHvbZzx0aKHhrhITi841cY9RG5XhRAg9YlWKlL0Bp9lqjXHFXaDZ7XMdrYafniU9KwwYjT6t2e6EyFxN0QRYthrF)qkecIHoFsIG6JXFEsV(9trXWLBGY3oKnHXd3gumYWQ)qN(Qx)R08KhDXmVLW1P(PbfVXwp3ayIKQVI4n4Vdj0p8y6GYqpcF4HoYrN(bAWzWXCiJ2TiHSHlr(1ynEeJwKE1bc5pUiOWEMNAbEd0abil(RTgfffgJlz6Ujrmdp9VXFIECKN9cmuRzSCHpYfgu8bN9ZfZkN3nuwqOpIwH3H2Frw0kBGuTqHFVd76fRQuWzOJoSfLxWgtEnBh5TrtiVYTE8k3WXRsBg2v94p1Y0JfbB9fN)tfR30mS(AvvUAf4gga8Ab0UU9Hlnn8EVPbyeCdZRZQbuDum9MC1W)l7xg)5P5XicVUt6VLfoZzeQUNb7KFHeuOITEl3weW9WOQziPxahSgcZYAlzh2hN7CwIiuLrRsrFTS9gYbI9Wrrj7RuLt69oCZ0rLHuEyYloYKd7L7mOXzbAc1fZowULlJLHH(0BMEnO9qi6L8WujWZV(XQETXduMN)q5zq1hHwUM9TSA2xvkMsVVVSJY6G2YQCshPYI29KAX5onbqzTFXt9rb05ku1lM(M7WhqeLjLctoBu(0P(kclwVjKedfKjXrEB5ZmL28P0DyHzwbK6NDG)Q8PfaWiG9JxXaOOfmqB6rxJEvdJLdtS1lFvx5MxHHCS2oFukkuU8MnER3al3c6MowEAl5qUIjBkIZK6VrtD)3Ov3fnoEj2pSkCzcrmtsYc7R2epQ6YtN07QyKp8RHEbEXEWczoGHvBq9bUdAAHFr0M2mYRbin2sJiKY6fQzXg3zVcWh8ilPRge3iv8W0jIszxsSNVjzWZB4pMguxUGZUWOOnqsxJWvzHqaFpHU2608)Zqs0U85pT2D5bYeI5ptPHq)WqxNvjrpBSSsEp)PxlctWrWSq0UiuToa2Kv8N1lyjApAjDxOGPO6xkd4OWmwWSy4DEyOBKBoMxUiRYPxqsycXjv2d6Xw9(Zd9dHrA(cOkmKkzolWraC3cc89UnMBiv7nWpjatC8HP2JFNBLIMsv7mjcVf9o1c)QmlKzevSnT1JATzvYa6POPdNaONu6IvsFsdLI6WcmkQQ1DMSjJ0yDNxidKa6BBhyx8PXPsdecu5ydoQKE89wIDO79Jl8Jo0H2nzbPlTPegZwM5NNo2Mfvsx8mK30Hww5SdEmpxnslHwc5cnXlDh6E0RmGPub7LWQWDyvS68zYuR8clPOLkUvim)u1hzjKhnOUoYAkwvMOn9USqltTHnDYlsYL8wYkMSffgUZIEWQ2KztrJfMFzvwT97MQsZtiEvJrK2wABkWAUQvu8u9e6317kPYB0Cw(iE(zHYbWgAIAw)4CikQ1di6mXvtI7xS8FXn(9OkvR5rRMxMDFwsPU1wf7Td)aDF6KSiruVpcVhXpVokyZaqQ1Kb189kKFz6PV9Sr5AAXe5kr8KU5QQV2BL1BVW1bxw7bHjuKBVLUh3QZFT8vzW3)FJiP8z63VVgP0dgqomCSW1hCuaPspC3BedeccBQmnz)gw3v7QSAqz5Lc63VpVZSfHHXoBd8wbTAa38bOeJU7mr7DUv7DUrXDY3dfLzNtVTy1aFE6hhrhLFla2YGQ6KHYLhTCYrKly10DMhMRNV1v9fu1DJAz)v5TYiUqX0CdDjnDWmgswJCUH8T5PhAt51MFlMULFNuPviofMEF9ULcrw6E5cTnJcg9OQg576j)UmEuE8G(IDKZ5nG1yk6Y8EDbtPA0jO3omGt6hfWz6BBPdSL(VwNEQySNNGkEhHuuLblxgcgKMrANN4f2EBgSpNuV2Ix(3HW4XtmREn7(BEWB6gRMgfwmKMEvMxPxny04Wv6QrKVf40Q51Q1WLHkDpPOYRobVIoo4KTpA1PMAgBP0ml2h7anYPQpiXw3gFx(2F6IrXBC2HI2M3p5rLdhcV(n3bptP)EXWIG8shr4Ryw46PrPQxD)TQvU42UxBqEnF206AT3GelaVobaD1329GqXgJwSeiwll0VSb6xXB2iu2AbkogtZlCbwyr(MMKT)Oj77Dv)YXFtVFqEyXkF0t(ycXb)h4LjPdiLpe8gBN63H7(g3Dz17jkmzJkdWyGHPTTvZMAEwB8QXkwxv9WYQTXPsBEBFLqMUWt12YKS9piBx5YRtPlMrH3v)0gGXYVhbhrXi1vJCXK8O2Sm7SqW0uBP4Y8Aj3Qil32qTYNFKP9smFeQ8M3jTnF5UGjThtIBWCTOrCYpRMru9dDLYAOAE4(Q1UArOdQNxheFEQ2kPP9Jj77L2Mzlhkk)5FCzWOvdgfFz4L)2OvN68W0po4y2eesF4CzZpimH6xEx7t0uCig5EIYt9LVDtcfsZ647sirZdj6YHSgijDJwAgZlpNXPFy2JhWr0VOuP)vNWhGeH9V2fP)B8a8ZFI9V(f841z)Tm6)p7rjg1n7XLrEG94HM9yQ6QLZACM1nlgqHjLiX0UwOjzg3rv5TAuzjoZ1cDzlt8OyyIgmK)bv3i9BIHEnMIEu4DNo4jYWUgbXkOyznu3JcJ7LGrPV7z42JQcbBPQ3Shf6kMgRNBJvFbku(sZq5JJeeGiZ)erylj8hv9Fus9fcn97cWEgDDMSKdCumALn7XcY6P3xwMEAud5RERyi30idPeFaP2X4rDMHiFIvm7iNDC1qgWCRiNMFnXiKNI)vXiuruW2WuWMy6vdehlx5r3RYNhtPZH7BEdr)W2WqH6OOGzgiQHcITKdIDfjezdXYv61nelWbmXH56ziuv(jY0RC1Dt61lNlynx1EYuxKPDDfVPF7svJIBgtDSM5G1ZPrgwLRWxG18qXxnilNKznzh7e2o2q6o2i(oYC110bZTLAMQDKo0UmmkyK7NrcmtEXbJqAhfpYTLi3P5D10IUcq1ssuYwuKCZf6Seo9aR2gC9m)ZcI)PN5Fmqk38qdaz9tVzK7LNp5lRX0K7nqr4GUWtB9)2W8sdOSwVn1m0Tsxgznp35vBpPnzyt3kGlMeTAuTnKnRjS581UzjMHlxEUgJuhtpAbvpAAxufdk8Rcro0dYIgVrTeDfVt7d8v1Ym2vjdSYL)YaBw)P1cxnB8w9AwUwxrMA2jC1kD)W0jmXlx6kt8zB6xTcNNuB(ZxNTXzYLLkkOMTLY1Qmdsx3(nkTHPNJkSDnFcKuTQ6ic0tLjvBxMrX3KNMc2nG0b5ZyBdBa1reQAzcv9CxL5aSD9ofFK1VNDaLj2kZbipNU2IZcNa(7yxqfwVYCcYLd06eyNMY7qZxbLyzgUCPLoZWkzcVquITfvBRPVGB1Vz1NP)WKhOD8L9SS(S(Ckz86khZ48rh6l41IkXXwkaMOFJPptn2vzuPl6TP0RvWtw6vl7(NOFhTptRVCUyZjGBdzGBH5Y1HKDABNmfFgyDOVqnKn85JzX3pgZQ0E0SgAvUPwHog9AjLEz4u7X32Xj5YNQIysVbU(YWOUTbw)6cAkmTWHXXIUvkQFXxnflDb7Gzqv36eRDvinfXnat6lO(crB4AQWprUiNUzFszJBjaR5JqSjSnURPBm1KUt3ABf4FCj7idAL4HSTerMPrB3)u1lBmhakib75tszgaTTgJgaAeHcevZEU)QeL6Qzik4Y4sJ4vrUpRy3xNzF1WT5grUzMV58wyElBOrfqm8bfvUGPrgrBGLXgOzSbEg3bSI2mTOFvrChsnA2GM293T8hmzPHVMWz6xustZSa5I5TDgm1FbP1tQnTZDOZmo(sWG3ZI0RwZ6vMdx3EDBkKPZNp(YOvRyCT1oO3egKYWpB7lv3(WwhfynWgyZ0JTw(XwVZVTE426Gv6HVxxBY2KGBlDTpl(A))vdrwWA7xnJUHqxz0LTljsF(BRngdS6MbnBxmu1t3O7i8DBz89lhLVFP58nZ1B75RkqkCPLuypDWTIp42ti8gZiCRiyLg)KTR2ReNXf9u6wYJkLPBfDfwADsUH0iNPv5LKiokBMg5VF4rEnB9)96pUXxsULB35VCV8caA25s0CIPBXjlyUUSLutNzC6oBp1hpHEoR3usR)QXA9xyARtDIFPUoilFUU1gvONp7DfH2zOv3hLKQtrPwCwIEQwntVMNshxABezABgBARJoT12BvJ5tR05Ju3iLoMKQ(Jt7Yy1zmw1c6WxhF4phcXZg(1Dmago3UCV0lct5VeZ0E(YZgr1Ei71DsSwPcDdMAcjkpzeGVywF0PNu)SlSLVX66cB5VWwEMaUWw(mxXf2YBHHiFiMm7i7Ixyl)f2YFHT88hYAEEPHT8zdP6(qAKB2IhuQ7)L8Z0XzVfLnxPSw1GCGnHrZE87WB989onV)3ggHpKsjV4zZ(F]]
)
spec:RegisterPack(
    "Subtlety (wowsims.com)",
    20261126000,
    [[Hekili:TZvBZPUn2)pl5nuy27sGes6T35sMz35F722z7dtP7)(omcBb4fJnJLnPzhg(SVhjlBlllzlBC4MmlVPnx)Go)opOZ5ij)J5JN)7ZN5GIWZ)57gD3JJhF3JJgnA(SOx2JNpBpYElAn8h(ODW)Dw8YipC0lNw0)5GNjU7idTd2nG(CV4fGCOJ1YyxVOFWF(sLdlzp2E(SF7x(h)RV9te(OnF2gxhhCYRGj2ALZNoTiAd(0c(1UDvqi(ao80ch8kuSx0Pf)TF9FEAbC5tlegIy3BPILCByW6y8To7j3I27rUL)wdH)XW)njWFWhGXpe5t8aC7a)DavEUKtlqoob(Ff8hBXVqgEAX)hkc9jf4O)p9d)omiBII2t(0T3U2nAt8sk0Vv6rhaJjax0YrRgncpzL9hVhg2)i4poT47shmp4)556VgEmFan(b(Hix4p(1dF7Pf7dDdcDJCXeQ(65f88Pf)GnOT))yxFcGHNbzthduOp25Vc6VNhFGEgJ2h4dVgYZBj4FPk0VtnRKyseY1NQ6jsYbTdC(zc7Lurr4(H9U(SNgW9mq5oTG67DGH7xdCjureI3567GdjCrJr2aO2a)n1yUpeVchI9TX0RDaZgvxqZdEgE3FJ6SaqHJIaJafKZIWipQwrDjK41RXeMFI5VdIJCcO)X(yppsQ(JoTiMGw6bduWESpoCieRggSY1dIMr2rUb(KHaoax0su00ND98SIcSiXHhCpG)G7QPSygR9hWw2b(r4)mQ3nKeCGDgcwWEjpajkMzl(Xsd6Fz6TSHnyLf8owayjOTy)gm2PVc7Pcd8uleyIdAp2cfg5sIAWOVl4aEh2pkD07TmE1QHfgTHoupIsPsIc8Xaa3zKe7ZgBhxw4i1TyTNfPmmE)Xs3c(BmIGH7nibtzYQk8SbffHdTSJdjM5)kjx2RcsLluXbScbhI276yfIxtJYq07)Hycg86RSwB7mD8hOIWd9I1smmdA6JJYbNnY3IosWS(ezwESQsWyKJLh(flixbwskFKjLOG1R9aSdZ28jqynPNg5sf3A3)dyy0loi7secIwsCCs6iyaXEt)jijYPfFpmlNkD(uRr9UjrQ05HWeAlWScjF6L7FIqHRXr92bVTfnfXqcaLNgLaTSRAb5lG)Fsmz6BZWIf9zMownSDaRK3lVzr9DTf1)YQvTh00bReMtVyfqgEeDi2GWJlfK7xcZJpwwn6LvGjBusU90Vcfhf8vd0L3JLdrsbfviU(KuwYkP6tAcDxSNJvs1v50r03pGcb)iOPN4qO(y0NN0RF)eum0Edu(2ISjiA4w)CpdR(dn9vV(3O5jp6GzwlHRtTtdYFJTUo(qIKYVI4nsEhsGxWGJzOcTBzmzd)L4xJ1BreAzYvhimfXbb1UtnglXBGEeGXI)ARrHHbr4cANtCit3s(x8NOhhCPVadyACxl9qoGD3dSNVKN4nRHN04mpeTiUfTfI0asMVs9Gc)9oSJBKQS9NHm6WUqEf794s2XXBJ(mUWDxCH7P4I0jHzfi(IwjESiyRV(7xuSExZW6LQWB5ISnma4sb0UUdHR9f8oOVaWjTHzyzP5l7OsUjxm8)XE7Oppnlmq41Ts(B5bNgFUpqDBbMn(5JGcrS11EBEm1tJkpji5cy)1qKuANh7WE4mJJnIqfgTqe91s3Hhli8chggVVuHmP37WDthveszrcV6itoYwU4FJd01enlobWElFmSdc8O3m5AqhGq0l5PPsGNF9JLTAJhOCQ8tftsQpcTyz57zLLVPqmLEBFrdLXbTff5KosK5D0j1fZdAcGs7WIp1h5tZvOQDl99VHpGikNukK)TYXNMElpSy9MaseuZLef6ULNzkP)sP7WcZmci1NDG)Q80cayeW(XByauudgOD6rxJEvUXIHjMALVPRmZRWWCS2MpkbfkxbZg31BGvubnmhjN2soKZOfjk1tJYA9ftqKuy9dRcSJjvms9v32WrvxE6KE3eH8G)AORVBKlG4dyOtEAowNAktlcT80RntbN8fSLfr8Z7B4sABBy3mIOnTBQMzRFWC3j(GlXMUKrCJeXttNiok7IJC9QAm4Z84pMguxSK1UGWWnW02gHRIdcb8ge6cWtYGCgJeDPa8Nw7wbbPCI4ptbxOxqGJ1Q4WxQSWu2cdsUwiMGdH8y0(quTybw6o(Z66BJ2JSPzHGKC9leUDuiNhKheVZfd9ZC3XScoP1ED9JdIjwjJ9GESL4)YqVaWtZxLvUIuomfhcWDlmGV31XmfPC3fEX(yILhuCi6DUwkQkL1Z4q8w07un8Bs1qMsus30M8V1QvXC7kABXYh6QLUCNAZ73HLCmPxIwRYvPKvw35vsbjG822b6fpnoD0GbbQCSbhkkh6QtHWQo0swm4H3BtELpEF18qfU4tcvuAXEqAddJ2yTdf2DMMuGYbuUemftepxBSfDl2CG)OdnKDrEKJ3OXbKEUbfaF6Ea85PJnzf)2bGIXkG25jwvB2Z7voVdpERYcPll)i2W06b11GyBWAnrgD0Cy5ThwCoDyqWodA1RyMToatQfP(0Of3Ck(QXfxxC6LkTGyvnn3gy3YUQBQO0nHZamOOqU6Ilp07gPsT0dcKhwKD4TCWUHolnDTbCSkk1diAvHYZG7NVzgIBJ9rvIwZJwEsz69zZi1fef5Ud)eDxhL0iP9OypIFaJuWMcGeTjfQz78j)Y0Jl8Lkh3QwytMqepAEUO6R9wPRZq46GjR9GOkuKPVfUhxRZETSv8WReujsk(ri0VVMrPh4qomCSW1hCuaPspC3RedeccB6ywL(xXAaZKNuruHKAs3rXSuL1l63VpVlXLbbrwB9Dxb1MHB(00hoQ7ot0EN71EN7uCNSD4r5SZP3NVYKpp9JJOE53cGTiOkNmuUgQHjhroGwtpNbiPpDbhuNJGOEyuV2ffKviuCrRjZn0nPPdYyiPnYZnKVnF6H2P8ANFloDl7ojJw(WPq17R3SKpKfUx2G2gVqLwuvE(Uo53v)rr)b9f7iJZBaTPQORQ33niLALgb96rf4K(joCM22wAaBP9R1tpv475tqfVJWuuLblxDbdsMrAML4vwFBgSpNPETfV8VQIXJNuT41St0zbVjBYBsuyUln5QmRsVAWyLURKvJiFlWOvZRvRIldv62wrhV6g4vu)Gv6gpvNyQX3sP(wKh2cAKtvFqITUn(HSTIvyp)s7N8Os3HWRF3dWZu4FN7wegVeps59wmjkv9Q7VxTWfpcGAdYR5i811AFfJyXTEv9UdoPT7bHIDHoFjqSwwOFNg0p74upu6Abe2MLkx4cSWISnnjDtNJ337M(fJ)M(4GSWIvEON9WeIf(pX2XjoKIN(DJ1t97vC)k3ow173gKSrLcuzGrv7zRYWXZCxxRSI1nLp4UABCQWo32xjKPl8uTUmjD)dsp0(S6u6IzuyD1N2auw(9i4qkgPMAKdMKf1MoZonemzQTuCzwTK7vml30qTY74RU9smZdvCZ7K2MVmtWK2JjXVOIArJyYpJYiQ(HUrznunpCF1sx9qOdQNxheFEQ2kPj9JjB7t(3zFfkg6kkUR6xDgTYzK)PSx8l9w9uNNM(Xbhttqi9zaMMFqiH6x)q7NOP40mYSeft910ZR4AirtNF2ExwdgjDEln(8I5mo9JZNDahsp(nPF6l8airy)ABK87ob8N)m7xFdE868)E6pjbZNjrbW5ZSdDb9XfnFwI4QLKDCQaopcqrvcrIAGTqsYueKkY71iYcK8RfYYuQdsXWenyi7ZdVrYVkkf2yofsH3d6GNiLaBeelHc7A4AifgpkbJcFf3WThvgcMYTW5Ze6kMgRNPJLFbku(6QHYhhjmaIuvueHTKHIuX)rjXNpOjhuV5uq7mP1hyOy8GB(SC2fQ3wwKpDuf5BEROi31ifPabgP6X4rDMIiFIvm9i9I1XEXmTiJxInrjKtXFrucvmBSnuBSjQE5aXXYvE09Q88yknoCBZBi(s2g2huhJj1qzYwYzYUI0KmNOCTCDorboRj6iRNrtL5tjtUY1VRsUUzCxR5I2vMQLmPRR8m9ZuQCCAZywKXmDSEoyYWQCn8CSMfSDXGS80iJjNzNWoZgspZgXptMPUMEuUVq7sTJKKMndJcg5owKaZKxDWimTJIh5gpK7L8HAAcxbOAjPpzl7rU9bDAc)RLSCJU1ZurdiQOEMkYaPC7bnaK1NERsUIE(KfTgvtU6VIWbDHNMA)nHPOvGYAT2u1q3AzzKl9CZR2EsMYWMP1ilCewLd0nHTBjjaVtUUyndLocD0cgDuDtp56AsduG)HEGquRaf26krMxTPwvrthLFj7BKPAYLKUGEKg2qzUzNFvjNKC9S0NoT73A1nnBCx1boujlx5kppq6jK1kz)00jSDdtUsu6WNUPH1o48ugvZowMO0TJI5BjDTcRIrx3wjkTHRNJimD5gceUTS4ePAlBunnrz(30NM2bAa7fYQhycZg1rjPMWTrn8WLzaKZBR1aK9rA)E2auKKUmdGCfaTL(fob93XMGsm4LzeKRvO1iWonM3HQVc69YuC9BU7zQyflbQOvZoGEVTO0CnLAVx)EeFM2JQSaTJ7VNL2RQzWj6khZ4mshAl41IkWxyga0VNWDIe7o(cNBB4pSKLux)a5FopVAkxJ4ymdSYDw0zaRBYJDSZ5xSqKDHxvYjAAVr5FUBDOTtT)QIptod(o5yALUnWTQw6BJwOjyt3co76CmYhkKyoNk4ZmdJYDdKvYOq67oeSQXs7i6ScMoZukDlISQfa1gfsJnv3kjRDfsnfdn8BnIcUh0FGQVsCJUM2qEW0D)mHYXfaSMV0YMqP6UMt1mvsxjrbswxqpsHwbYwBkBRzs00vmRETTzaqbtFpFMyZaOPfy0aWkrOaB8mNGZkrPUcgIdCrCPz4vXGrJOWyNPF1qG7gXGBMTX0fpRE3dYWIsIhzk7UzarxjRsLvRK23vqL6k4sDfKPUdO(D1C)(II4oK)3mNMUsYsFvOfCFnHy4VQmdNPbYv1BBgm1FMS1ZCpT5o0PghFnOP8zXSxJP2l1G)OULOxvitNNp(Q3Qv0k3yd0Bcfsz4NP9LQBZIRJNVvq55Q5aCTKaUEJFBTWT1aR2cRRnztMGBkN0plsP))uUidOM(ftPBi0vgDz6sI0p)T1ktfuxNbntxmu5JGP7y1EBP1(RhV2FTj2oZ0B6zGkW8DPLuyoN3nI07MZ69gt7DJyrMg7KPR2t7xvKUL8Osy6wrN6Jqq9oD3iUYZKQ(ZdSoUY)(HS81C4npQ)maFnjqVzhkXxB6hVP6dLO5SV3GJvO66YgY)EMYP7J0r9ztONy(nLz(xmQ5)kZnFMruxhK6p9IAzMT02d3rS2NHwDFfPQ(eWQfNf4GRrz618u6imCJymCZOmCDCgU2ERAmPHt(3MqQFMNshVrvFasx9vNHVQfC(Vos)FoS(N5(1Ylx9hGxMv6v5NdGRXmT)hfaMhv7rXx3rYAKi05m1esumzeGViwF0jhr(8R)Ka0yzD9NeGR)KaWgGR)KaKAkU(tcGbkI8HyY0J0lE9NeGR)KaC9NeaJ)jbi1PP7tLrUDkEyNhI2pI1(y6NZMG)Jjdt3N8AO2ytekRzmikFtq48zFpERRN7Pf9)UGqmuJya72Z)V]]
)
