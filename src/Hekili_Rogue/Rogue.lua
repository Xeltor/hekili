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
-- rogue.go ApplyFinisher: chance x points, one proc): the expected energy, since energy is secret and the belief cannot
-- see which finisher proc'd. `talent` and `gain` are the caller's: the sim's state or the belief's.
local RELENTLESS_ENERGY = 25
local function relentless(talent, points, gain)
    local energy = RELENTLESS_ENERGY * math.min(1, 0.04 * talent.relentless_strikes.rank * points)
    if energy > 0 then
        gain(energy, "energy")
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
            relentless(talent, combo_points.current, gain)
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
            relentless(talent, combo_points.current, gain)
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
            relentless(talent, combo_points.current, gain)
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
            relentless(talent, combo_points.current, gain)
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
            relentless(talent, combo_points.current, gain)
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
            relentless(talent, combo_points.current, gain)
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

-- The hand-built lists this file shipped before the wowsims.com packs: a saved choice of one falls back to the spec's
-- default.
spec:RetirePacks({ "Combat", "Assassination", "Subtlety" })

-- The three priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit those
-- and run it, never these blocks (tests/Forever/rogue_spec.lua checks they match). Pick one with
-- /hekili priority <name>.
spec:RegisterPack(
    "Combat (wowsims.com)",
    20261125000,
    [[Hekili:T31wtQUns4FlZleO2ZYaZWm5KtDyQAVKSjP2CPYKDZBye2cWlgBklBMmBrXV9TLSSTSSK8fmKzQLxYHJV09x3Tu3TK83jZgp7xN9Sdkcp7hVB0DpoE8DpmA0Ozph96o8SN3HS3Gwb)WhTf(V)TGTlqrhN3)LGxiUBjdTd2oG(uV6fGCOsArSRx035pBHsHs2HTN98V8t)J)1x)jBMSM98AxhhCYlGj2A0XNoopAn(4C(1UDzqiEpo84Ch8suSh84)LF(FECoC5JZZeqS7TufsUnmyvm(wNDKBr78i3YFNHWFz4)He4p4dG0dr(epaXoWVdOAZLCCoYXjW)lGFSb)kz4X5)Due6tkqr)F47(vqiRJI2r(0T3UYnAD8ckWVv6rhaYeGgAXOLJgHNS0(J3dI93c(TJZ)MuH5b)HNR)k4X8b04h4hICHF8Z7)6JZ3f6ge6g5IjuR1Zl4LJZ)o7xpo)FJD9jagEb0nvgOqFSZFgSFppUGEbJ2f4dVgYZBbexPg0VsDQKyseY1NA6jAYbTfc6zk71uvr4rHDU(SNgW9ZGXDConQ7aI7NdCjuveI3667GdjCvJr2aOwd)M6m3fIxIdX(2y612Jzs1fS8GxG39xOblau4OiWjqb5ZryKh1QOHes8QvycloXI2bXrob0FSl2ZJKA)OJZJjOfEGGc2H9XHdHrPHblD9GrXi7i3aFYqahjdcN(IRNNvuGfjoCV7E8hCxoLnMXA3ESLDGFe(3J6DdjbhyNHGhSxYdqIIz(IVVKq)ttVLj2GLwW7ybGLG2G9BGStFf2tfg4PwjWKg0oSfkmYLe1aPVnypEl2pkv69weVC5WcsBOdnIOuRKOaFmaWT1sJ9zY2XLnCKgwS2XgPmmE3Hs3c(ngrWW9gKGPmDzcpRrrr4ql74qs9IFL0l7vbTYvQOanO4q0oxhRq8k6Ome9(FiMGHO(sRv2oth)bQk8qVATadZGM(4OCWzJ8TOscM1NOZYYYKIXihlp8RwqUcSKw(itlrbRw5byhMT5tGH1KEA0lvDRC)VGJrV6GSlriy0ssGtYgbhi2B6pajroo)BHz5uTZNAnQ3njALopeMqBbUvi5tV84tekCfoQ3w4TTOPigsaO80OeOLDvliFb8NjJjtFBgwSOpZ0XQHTd4L8E9nlQVRTO(NwUS9GMkSsyo9IgGm8i6qCngECPGC)syE8HYMrVScmzsj52t)cuCuWxmqxEpwoejdu0G42tszjRKQpPj0DXEowjvxLthrF)ake8JGwEIdH6JrFEsV(9tqXq71q5BlY6GOHB8ZJmS6p00x96FJMN8GdM5TeUo1pni)n2464djsk)kI3G)oKaVGdjbLHUeE4Hg5OPFGgCgCidYOTlIjR5sKFnwJhrOfjxDGW8hheuyp1tTaVgAGaKf)1wHcddIWfmDN4qMHN834prpoYtFbgQ1elx4HCGGIh4SFnpRCw3qPdc9q0k8w0(lshTYcKQfk87Tyh3ivLcobD0HTOCgBm5s2oYBJMqUWTECHB44I0Mr9QE8hAz6XIGT6IZ)HI17AgwVuvLlxbUHdaUuaTRBF4AtdV3BAaIGBCT3KhWEAu5ryjxa7VcctPL13I9Wzc3grOMmnlp91s3Bfli2HddJ3vQkH07T)UPJkcPm38zhzYdBKRS24rrAgQio6YEdxg2bbE0BMCnO9ki6tEAQe45x)qzV24bkNN8uXmqRzgeRkVX6P3pYS3UORrwdSX8bvw0EsRvsElrsTb8GgjM2IcF6bYNoFsv)k6BacVhrm0SBPHIQvcnhrE8F16aseu5Ief6UHpfoPlnP7WgpvnAu5nAe8UPRW3smmkSTZytqHYgOx7UAn0qp0VwK8e7s905UdWO848Lb2XKKahRtTxh6f80uU9YFLH2W)f8ccLMoOQmvY1cXeCiyw0jUsGUGljp9qEyrQIUMkDVrRNjAC8IkIUxLwyF1M4bvxE6KE3eH8GFn013nYfADFpg6VM6dCg00sDIOnP87LaKglIlcP0Q)nBSXd1xb49UeB66FWnsfpnDIOu2gh56zsg85X8htdQlwWyBqy4AycvJWvrHqaFpHUAYK8rNGKO91YFAT7RbmtiI)mfcHEbbowlJdFv3B2W0h9YsEYFwxFB0oKnDFxGuM9lmd4GqguiRkERlg6F4UdzTWNwh01poiMyLi7b9eYcoHVKHCdP0mNfyy16HBab(E3gZmKYv69I9XelpOut07CRu0ukBNXH4nO3Pw4xLAHmJOKTPTEuRnRcgqpfnbz5dDysxErYtAOuuhwGrrvTUZKnzKgR7CMmqcOVnDGDXtJtLgieOYXACyXe5Q2Y8tuDYd2le5CahbDDtGel0ysR1jFMYA3pp9Hr5T)r8CTXw09XXb(Hyd9s3HUJW91mlTWmHIbOccPdhj2nPpuzO8vu)5PJRZ6NP7taKWPdTSIPv4jl4QrA3cAuWt5mTcD6yhaiMvQVZlbOw55wsEVOCRO8sXeEe6QXguvRSTbRM9pDv2g5DLvm7tyqW2A0uA5fh0u0yoDnp97UyFByChTF5xcI9DiPzHRbe12bEtrA1QsrTD11BEO3nsvFPZm4()SdNKJP10PdPlxGdjrTUhrluuEQs)8DlrCNypOs1AE0YJ(tVpBOVUL(f5Uf)eDJ)KSiruVleVdXpankytbqI1Kc1SnFKFz6XH9Qr5AATozkrSokxv91ER0LEiCDWL1Eqycfz2BH7XT6SxlBrq8nK3isk2Xq)(AKspiGSF4yHRp4GasLE4U3igimiSPY0K9ByzHTR(LbLLLyUF)(8mxlccIS247UekOd38PPpCq3DMO9o3R9o3P4ozBXJYzNtVpFXkFE6hhrJYVfaBrqvozOCXQAMCurdS9fuvRBbnRHbX1XMm3q3KMoiJHK1ip3q(28PhANYRD(T40TS7KiTCXPW07R3TKlYc3ltOTjky0JQkY31j)UgpkgpOVyh5CEdynMgDzER4GuQgDc6Tdd4KEk9NOVTLoWw6)A90tfXE(euX7imfv5GLRHGbjZiRNN4mBVnd2NYuV2Ix(h2W4XtmREnBoD2G3K99nzuyEin5QmVsVkWOXWvYQrKVf40Q41Q0WLHkDNFOYRkbVKghSs3TQQutfXwkVVI8WwqJCQ6dsS1TXpKT7Soyu0ARTOWnz9tEqz4q41V7b4zk83ZdlcYljIWxXSW1tgLQE193Rw5INkqLdYR47ywxR9gKyo41jaOR(2Uhek2(X8LaXAzH(9Fq)SAtJqPRfi)uwnVWfyHfzBAs6UqgVR3n9lo(B6JdYgwS0d9IhMqSW)o2oojGu8m6BSDQFFK7BCpCvVZJqYgvgGXbgM2CuLdhpXT30yfRBkFwEv24uHTiTVsitx4PABzs6(hKEo(z1P0nMrH3vFAdWy53JGdPyK6Qro4S9BmBMD6qWKP2sJlZQLCVIz51DOwXJ3Y0EjMfHkU5DsBZxMlys7XK4hzrLOrm5xTYiQ(HUrznunpCF1AxTi0b1tRdIppvBL0K(XK99j)9SpmLAgkk(1PCny0QGr(NQDXpwz1tDEA6hhCinbH03zyA(bHeQF5dTFIMIdTiZtum1x22njuinTJVRdjA(qIUmK1ajPlAPjMxmNXXVF2Z7XH0V7wP)fFWdGeH9pXej)JUa8ZFK9p5e8XRZ(RP8XF2ZsuCB2Z2HUG94IM9CI6QKezCQUnlcqHjLir9TwOjzkWrv59AuzbsS1cDvxQXrXWenyi7R3Ur63eL5AmN5OW7bDWtKYBncILqHDfCPJcJhLGrHVoC42JkdH6YDUzpl0vmDSEMnw(fOq5lndLposqaIuXteHTKbEu1)rj1Nl0KtPV(uS6ePTg4Oy88A2Z5SNtVVSiFXOgYx9wXqURrgsbc6rTJXJ6mdr(eRy2rGssVvWmyeClZkY4Dxtmc5u8xeJqfZ9Ad19AIPxEG4y5kp6EvEEmLohUV5neFaBdbkQIbfMPeOgob2ssb2vScKfI1vPN(v7uoE2mk(uBs5vnDbzyvxhbcbLlgKLhUvBEe2jejSHmjSrujK5QL7UrQw(9JQNJUOxrFcebklYuFfD1m5mOE3m(mYqqfnZ84dv0qQcq1s(jYGJCZn6SeoLbv33zn4gynOgOEUbYqQC3lkCCTeB1H3IgaxL(m6sTKBzj9zyuDSEd60NCP9uEKHn9DI0iso2swoc(a6o0Z8CAxxqIwzOv3QwZZ7vEGqDiYvtyk5LUspZWLROwHrQJffTGgfnTfG8Gc)QcXyQLOREBstmxulZylrmWQB94PnxvjC1SRrvRz5Iv55vspEMwP7NMoHjE5krPIpDhRQu48uqMzRjtvYvzYRpMUFOvQmdsxUYqw9ZI723jOI7LtFRlrLabqlRoIa1pzsvoXRoPM)bLvwOnmDBoZcQdt70XvMkjlt18cL5aQ76aZ)cHFp7aksAuMdqoNU2wjeo(23XUGsmkL5eKlhO1jWokG3HMVc6MYmC5slDMHvWeot0nTfvBROVG7Ll41z(dtEG2Xf1tY6t7ZPGXRRCmJWcDOVGxlQa)vzaqxrAr2C054qEEfdj6kOlDAHDiyAcJxBmLxL48k1eNOFlSprlPRsFPYiRMURcdBl8QfhRpr)koprRVyIVMti2gYiwHvOMOdj7SU93K)bJ1H(c1q2WhAwn(sZywL2dX1W6sAJvOWFtvV2ZVTJtukFSkIjonq9wggB(IgBkmplCYLHDDl7SYLt1utWagKlgMRQZezDRO1Kj1DFst4aBbaR5t)RjC8TRj5lZK0vLvG1VfSJuOvG9V1L(Vun(qDxfT617Mbafup90PgmdGN2cYns422X4wLOu3oGQRrTgrPUAXPUoZ(QGrXnIsXmFtDxqT6DuOLnhOci1UkLrEiBGBVgi3Rb292bCr2mzKVOiUdjKmlOPRSTHfE0iMkFwPQmZcKlE32myQ)UnRMkzAZDOZmoCo4n7jr10AZ1uMdx3Y2nnKPZZhFnA1kEoxBh0Bcds5WV62xQUnqUkINAGdUMjLALSsTANFB9WT1bR2d3InJQXKK(Kyj9)xfIQbxPVygDdHUQrxpw3LePF(BRngdCPMbT6UyOYhlt3rZ62YZ6ZhrRp3mTM56R7(gkqfBPLuuFsyxlwyxFAy3yEyxlAnPXpv3v7vGP2IEkDl5rLY0TIUClTkj3qYBZ0Q(ZiSkYB)(H92vSn6pQ)CbpNm6UENLXJYlaOz7XFZPdEn2LEZ1LRjHWzgNUZeu9w9RNP4nLQ4xmUIFMjloZjQRdYIhiDLJk0ZI8UIg5u0(L6(svv9zHvjolqk0ALPxZtPJbRnIcRnJdRvrI1k7TQXSyn5VxhwMZIu6ijQ6VQURXQtiw1csOxfl0pfAOZc)6ogadNtxMx6SWp9RJzApl1zruDhSELN8ATuHUGPMHeftgb4lI1hDYXJp7kh1BSUUYr9RCuNjGRCup1vCLJ61WqKpetMDeOKE3fmJGRCuV2M(voQN9kDlZ1ExYrDZFXZYRxt7)NPNPJ6sUbTBrzZvkRvnyoW6GWzp)T4nUEUhN3)BccX7t4sy0Sz)V]]
)
spec:RegisterPack(
    "Assassination (wowsims.com)",
    20261125000,
    [[Hekili:T3vBZnUTr4Fl(lkstVklBl7C5MtEM0PjnjtZltCAZ3efKiKeROi1qqkh3XJ(T3fGGKGGaGGuuk2t1xYPJVS7ZUlWUla4ZLP3m93M(Klkgp9NUD0TpCZn3E)OrJM(u8l7WtFAhAXg0k4hbOTW)9RjeeH4fGI9cdomR)ZHpt82sgUiC7a6d)IFiYLkW5jE(XFFW05kLnzhEX0N(1F(F8V(MpHef50Nw756ItFpmzHzn(PdZIxJpmJFTRxggH3JJomZfVeL4hFy2x)l)ZdZGld)ssojExtrb56OWvj4RD3rUgTZNCn)vhc)LH)hsyWGpakjcfq8bZWf(DivPEKdZqUUHbFb8Jn4xidpm7VJIrFsby6)JF)VbczDC8oYNU(6vEXRtMtX)1sp6aqMaMrZhTC0i84Ll(4DGy)9WF)WSVnty(WF47fScESaanbHbrip4h)Y(V5WSDrEHrEXEyc1O99dF(WSVFXlhM9VXEbeadpd6Mkduua29Vc2VVpxqpJr7O(LLiF)5qmNAq)g13ssiXiVaQPNQjx0wyarUYEjtveEWyNxa7PbC)eyChMrhk4cI7xc9iuveH36f4IJiCvJrlaqTg(n1zUlcVehHdwGPxBpMjvpWYdFgE3FLgSaqHJJbNafKpfJr(uRIgsijRwHjS4elOhMe7gs)XUeFFsM9JomlHGM7dckChoahneg6gfU0ZhgHJwqhGqgc4acrZrXtE2Z33jo0HKeT3Bp(dElNWgZ4SBp2zryqm(pI7Dfjfhy3HGhSx6dqIty(IFOIq)ltUMj2WLoW74aGLG2GdAGSZEf2tff6RwjWui0oSdkk2Je3aPVnCpEloiot69MNSC5WssBOlnIOuRK4WamaWTwPX(mz76Xgosdlo7yJugMS71k3c(ngrWW9gKIPCDzcpRrXX4iNfjre7IFv0l7vbTYvQOanO4i0opxNi8k6OmwMNpKqWquFPZQfUtU5duv4JEXzogMbn5HrfGBbkWHkjywFQoRkltkgJCD8XV4a5kWsA5JmTehUALpGDy2wabgwt6PrVu1TY7)cog9QdYUeJGrlPbojBeCGy)j)iKe5WSVdMLt1oFQ1OExLQv68qycTd4wHKp9kIpXOOv44EBH32HMIyibGYJJsHw(vDG8fWFMoMm7TzyXH(mtUrnSDbVK)lVzr9TTf1)8YLTh0uHvbZzx0aKHhrhITy4X5cY9RG5BETQz0lVatUusV9KVaLeh(fd0L3JLdrYafniU9KwwYjT6twcDpSVRtA1v50r03pKcHGyOZNKiO(y8Nh3RF)uumCXAO8TdzDy8Wnbfrgw9hA6RE9VsZt(QlM5TeUo1pnO4n245gajsQ(kI3G)oKq)Wxtdkd9i8WdnYrt)an4m41CiJ2opHSMlr(1ynEeJMNE1bcZFCrqH9mp1C8AObcqw8xBfkkkmgxY0DtIygE6FJ)e94ip7fyOwtSCUpYfck(GZ(LISY5DdLni0hrRW7q7ViB0klqQwOWV3ID9Ivvk4i0rh2IYjSXKZz7iVnAc5m36XzUHJZsBg2v94p1Y03ic26lo)NkwVTzy9CvvUAf4goa4Cb0UU9Hlnn8EVPbicUXBXMIa2JJQocl9c4GvqykRS(wSpox4lqeQjtZYtFTS9wXbID4OOKDvQsi9E7VDYOYqk3nFYrM8Wg5kRnEuKMHkIJUwSHlJfHH(0BMEnO9ki6tECIe45x)1QETBgOCEYJLZaTMzqSQ8gRNE3iZE7YUgznWgZhwBr7XTwjfTej1gW9AKywlk8PhOa68jv9ROVbi8EeXqZUvgkQwj0CefX)vRdjXqLlsCK3g(u40U0KUdB8u9OrL3OrW7QUcFlXWOW2oJnffkBGET3Q1qd9q)AXYtSLdyfthlCdsvq1uz5nA9drJJNe)dldxKqehhkzH9vBIVQ6Ytg37QyKp8RHEbEXEqRY7Xq)SuFG7GMwAreTPL7ohG0yrtriLvTTzJnU3EfG37rwqxVbUrQ4XjJfLY2KypFtYGpVH)yAqD5e0BdJIwdt6AeUklec47j0vVLo))iKeTps(tRDFeGzcX8NPui0pm01zzs0l6EZYDvMETimbhbzHO1zv1Pjlzf)z9cGfMJwq3Ndifv)sZaEviJfKfdV1dd1RV918wMZQ74fKeMqCsL9GES1h(Yq)qisZBrVWqQmZzogwDC0gqGV3TXCdPALv)Kambw69Q1XVZTsrtPQDMeH3GENAHFvMfYmIk2M26rT2Skza9u00Hta0rhTD(0N0qPOoSaJIQADNjBYinw35ezGeqFB6a7INgNknqiqLJ14Os6X3Bb2HU7cUWp6qhA3mliDHbLWy2cX(8KBSzzx0LxcZB6qlR8Sd(yEUAKwKPeYfAIx6o0Dbw5aMsfSxaRt1HvXQZZKPw5fwsrlvCRqi)u1hzbmpAqDDK1uSQCI2K7ZgAzQnSjJpjtUK30pXjBrHHBTOhSQnz2u0yH5xwLvB)UPQ0CcXRAmI02sBtbwZvTIINQtOFFVRKkVrNZYJ45N2ghaRPtuZ6hNdrrTUhrZexDsC)IL)lU1IVQs1AE0QZlZUpBsPU1wf7Tf)iDNSKSiruVlcVdXprikyZaqQ1Kb18DtJFz6578Ir5AAXe5kr8Su5QQV2BL1BVW1bxw7bHjuKBVLUh3QZFT8vzW3HzJiP8Pg3VVgP0dci7hEJW1h8QasLE4U3igimiSPY0K9ByDxTRYQbLLxkOF)(8oZMhgg7SjWBj0QbCZhHsm6UZyT35oT35wf3jFpuuo7CYDfRg4Zt(4iAu(TayldQQjdLlpAzYrKly10DYgY1Z36Q(cQ6(rTS)Q8wzexOy6CdDtA6GmgswJ8Cd5BZNEODkV253It3YVtQ0keNctVVE3sHilDVCH2MOGrpQQiFxN87s8OC8G(IDKZ5nG1yA0L596csPA0jO3omGt6XoFK(2w6aBP)R1tpve75tqfVJWuuLdwUecgKoJ0opXj2EBgSpMPETfV8tQ)MBgBw9A2938bVPBSA6OWIqA6vzELE1GrJHR0vJiFlWPvZRvRHldv6EsrLxDcEjno4KTpA1PMAITuImf7JDGg5u1hKyRB3CF(2F6IrXRD2II2K3p5RkdhcV(T3dptP)EryrqEPre(kMfUE6Ou1RU)o1kxCB3RDqEnFyU6AT3GelaVobaD1329GqXgJwSeiwll0pOb63jAwekBTafhJP5fUalSiFttY2F0KD9UQF5XFtEyq(WIL(ON9XeId(pWlssdiLpe8gBN63H7(g3Dz17jkKSrLbyCGHPTTvZMAEuB8QXkwxv9WYQTXPsBEBFLqMUWt12Y4S9piBx5YRtPBmJcVR(0gGXYVhbhrXi1vJCXK8rTzZSZgcMo1wACzETK7uml32HALp)it7LyEeQ8M3jTnF5UGXThtIBWCTOrm5Nvzev)qxPSgQMhUVATRwe6G6X1bXNNOTsAA)yY(EPTz2Yqr5p)JlbJwfmk(2Jl)13QEQZJt(4GxZsqi9HZLLFqiH6xEF7NOP4qmY9eLt9LVDtcfsZ647YqIMpKOldznqs6IwAI5LZzC4hM(0ECe9djv6Fxd8biry)7Pq6)kca)8Ny)7RaF860)wgbZN(KeNTM(0IipWE8qtFkvD1Ykko3TMgdOWKsK4Yvl0KmNUOQ8onQSeRSAHUSLRxummwdgY)CKBK(nXbSgtcmk8Uxh8e5WvJGyfuSOgYHrHXdsWO0N7mC7rvHGTKbB6tcDfthRNBJvFbku(sZq5JJeeGi3YerylPugv9Fus9fcn97cWEodDK8WcCumIln9Pc6GP3xwMauud5RERyi32idPeJZO2XnJ6mdPbS4QKzWySvUvKtKSMyeYP4plgHkQO1gUO1etV6aXBKR8O7v55Xu6C4(M3qeCRnmuOokkyMJBAi5wlz5wxrZnwiwxLE6xXt14zZ4SI1SmRE(VXWQUoceckNnilpCZAIX1jmJRHuJRrCJJ5QL7UrQw(DJSZrx2ROpbIah8yQVMUAgFcuVxob9yiOMMzE4(AAivbOAjH7yWrU5gDwcNdCQ770cYUzbx30t2ngsL7ErHJRLyZgI4zaC16ZOl1sULLSNHXDp7g0Pp5s75WhdB6wSzrMKQUwB4Euti335U2jZWLBdPgJu3h(Fl(Y)BAr1IGc)QWih65AqhVrTeDvBtBl4SAzgBYGbwDLBZAxPw4QzFyQxZ6wBDXbE0kD)4KXmXlxDjt8z7buTcNpP28xZmtvYLrkQ4KTdJ1QmdsxUQqEfPY7F2XOc5056sIkWzXQQJiWwr22ljNMvNul(eTQk0M(nONNX2gYHPJxm1smM6PYiZbiNlxRdi)BU99SdOmphzoaBxAP4bI(o2fuHeKmNGC5aTob2MR)o08vWqsMHlxAPZmSsMWjIHKTOABn9fCNCbVoZFyYd0o6tEuwFwFoLmEDLJzuaOd9f8ArLOCjdaYfP7mn2vZOsxvytzBPGNS0Rk5(1VV5hP1xEUyZ5JzdjKzH5Y1HKDABNmfFvqDOVqnKn81ezXNte1QgRBbRMAvUPwHocEAjdpz4u3Ix76j5YBYU4KEdu)KHrDh0Q(1f0uyAHdJJfDRuu)IVAkw6cYIYGQ2dQTUvH0ue3amPVG6jIfP1uHFSCroDzFsjNzjaR5BsRjKpTRzFkZK0T2wb6OwYoYGwjAPAlVuzA02Dbv9YgZbGcorE8CwLbqBRXObGgrOaVLSNkOQq596Qzik4Y4sJ4vX1lRi7vNzF1q11gX1vMV54wyElBOrfq0vmQsbtJeK1aPtnW6ud0oTdijRzwYEwrChYuwwqt7(7w(7NRu4RjuO9KYHwMfixmVTzWu)bfwphN0M7qNz86PGqNhfhiTMeKmhUU9620qMopF8LOvRiGR1oO3egKYHF22xQU9HTogrAGCOMzlzT0LSENFB9WT1bR2dRRnzBMGBl7Dpk67()vHiliX7zZOBi0vo6Y2LePF(BRngdK8LbnBxmu1t3O74)BBja8PJbWNAkatD9py75RkWryPLuyp7GTIEW2Zp4gtqyR4BJg)KTR2RefIf9u6wYJkLPBfDfwADsUHSkMPv5LKigLnZQ43p0kUMT()b9h34PKQX2D(lpiVaGMDUenNNYwCYcMRlBjtLzgNUZ2t9XtONcZnLdZNnsmFIzXmZjQRdYYNRBTJk0tV5UIFZm0Q7Jss1POulolXwrRY0R5P0rTYgXTYMrUY6yxzT9w1y6vkD(i1fPKBqllsP(Jt7sS6iIvTGD01rp6JHF00W)xQ7yamCUD5EPtcXPVmMP90NMfr1Ei71DsSwPcDbtndjkNmcWxmRp60tQF6fYt3yDDH80xipntaxipDMR4c5PTWqKpetMDeQK3XLmJWlKN2At)c5PZFLULayVljpTUpKg5MT4dk19)dWz6W2dKx7wu2CLYAvdMdSomA6tFhEJNV3Hz9)2Wi8(uk5fpD6)7p]]
)
spec:RegisterPack(
    "Subtlety (wowsims.com)",
    20261125000,
    [[Hekili:T3vxtQUns7FlZneO2ZYaZato5uhMQ2TEt2KuB(OczFZDyeyb4fJnLLntMTO43(2sw(lzjzzJHZm1YnBy8hD)0Dl1Dlj)C2zdN97ZMAJcXZ(5hg8Wtdh(W4bdgmBA4R7XZMUhTClAn8dp0o4)DA0IqxC4RNM39f)xio7i9x6VRh95E11hztL1Iih3WFWB2cPILShVC20F7x(h)RV9teU0MnDJJTno(vWKLk1ZNonpCd(0C(1UFLFa(ao40CB8kuKB4P5)TF9FEAoC5tZZjIiN7PQLCFG)6i8927j3J27sUN)w9H)O))M4717dG8dqEexa32WV9P6ZHCAoY2237RGFSf)kP)P5)FOq0NKGJU)0p87Gq2egUN8P7VFTt4MOfuOFVWJ2dKjax0IbRgmapA1Yp(ii2)W)pon)7seMl8FCD8wdpMhGgpFVaKd8JF9W3EA((ah)aNqhmHAVUU(VCA(pSeS2)FSJhbWWlGUPYaf4HT)RG976Yf0ly0EFp41qUUlG4l1G(DQBLercroEutpwt2ODqWpvzVMOkcpoS3XJ90aUNcg3P50yVniUF13HqvraENJNnoGWvngTea1g43uN5(a8kCa2BjMETdyMuDal3)f4D)nAWcafomeCcuqoneJCPwfnKqIwVgtyXjw82pk02N(J9rUUKe7hDAEebTWfeK)EShoOpmwnWFLJlmAgTm0X3J0hWbeIwGcN8IJRRvOVfjk4GZb8hCwnHnMXA)bS1sFVq8Fg25osmoW29bpyN4hGegX8f)yjH(xMCptS(RSG3XcalbTf7vdzN8kSNkW3vUsGjoO9yluqOdjSgsFN)b8oSxyI07SiA1Q(fKwFBAerQwjH(EyaG7msJDzY22HnCKgwS2ZgP0pA)Xs3c(ngrWW96fJPuDPdpBqHH4aRLrbeZIFL0l7vbTYvAEbQrXbO9o2wb410rzi69)qebdr9vwRxApz4hOQWf9Q1cmmdAYtdYa3sKNfvsWS(yDwww6umgzB5IF1cYvGf0YhzAj0F9Axa7WSnpcmSM0rHEPQBTZ)bCmQvhKDjebJwIdCc2i4aXUt(jijYP5FpmlNQD(uRbDUlwR05HWeAlWTcjF6KfFcrbRXHD2bVTfnfrFcaLNhedT0RAb5lG)B8yYK3MHfl6ZmzOCyBdEj3xFZI6hAkQ)LvRAoOPcReMtUOgidpIkeBWWJRfK7wcZdpw2m6KwGjvkX3EYxHIc9)QEQY7XYHiyG5niU9exwYkU6tscDhSRTvC1vX0r033NcbVqOPNOaO(y4Nh1PB3yu0F5gO8TfzJFy)TEzrgw9hA6RoDVtXtE0gZ8w5Uo1p1l7n26y7bjsk)k5Vr87q8D97DmfvODlIiB4Ve)ASElcrlIVAVCtrSrqT7eNXc8gOhbqw8xBnkiWpexW6SJcy2w8FXFIoCWL8cmGPiCTWfzd(DxWF(AwI30gEsgN5IOfXTOTqKmGKfRKlu437W2oHYY2Fg6Of7c5c27X1SJJ3g9zCL7U4k3tXvPtcZkq8fTs8W8GT66VFrX6d1dRxRcVLlYwZbaxlG22DiCRVG3b9fabPTol3MftEEq5brXxa7TgIejvU3HDXPcFjIqhtqtKtFTKDiXccp4GGO9Lkei8EhEyYGIqk1tEXrM4idXIN1EGIIrd5haTClxgl99DP3m(Aqhuq0N88ebWZV(XYETH9Kov45Ijz2WmiwHCTLmFCGEVDrxJOgOPH27xzD5rnwjzD9iuPFScjM0fcF6bYJoFswljQ7XbFar00pBPHIYvcnpqw8F9gFsiuCIeg4SLpfoUrmH7WgpvnAK5nQf8URTW3kmmkSPZyJrH0EK34SEd0Zo0swO4eBXaMrldrOQP0QjfNcfN6(dR8xgr0iPUYlmDu2LNmQZDHix4x9D8CcDaeFad9ksZczxrHG8qllbu9mWrFblkMh)8ktxtFBnRxMhTj1RRNVES5Ht8bhYs6IsW1sfppzuEPSlk0XvNm4Z84pMcuxmf)o)GGnW02AHRIcHardcDjEXzqodjrB2K)0k3SbiLti)zkecD99TTwff8QQ3SyRNXxlatWbqEmALAzTJYs3XFwhpy17OL0SqqsUUfgUDmxopipiENdgQ4)WX0(QtQC54f5hrSILDVoSfr(AFxFisZ7JpZqkpmfdlHoyliW372yQHuU2SBKhMaRpF9MW35wzEtPSDgfG3IENAHFtIfYmIs2MYK)n2SkMBxsBlwEqpH0feuzE)wSKJj9s0ytwNrQTUZfYajG(22c2fpnovAGqGkhBWbf2Ioy9BWWQw0twCWdV3MSkF8LBZhQWvF8qfPESXcBjv4gRDOG2Z1KauoGY0GPyI46SeBr3ehB4hTOJSnYJC8ofbGKDMUa4twL8NNm0K1eVew4TfRaARNyvUBpRx5So84TkNlDz5hzjmTUxvni2eSwXiJwAoS4gqMFoDGV)odA1RyMTwatYvP60Of3(g(IWZVU4KlvAbXYAAUjWUHDvxxvPAcNbyqsHC5fxg35oHsT0JAIpSi94b5GDdDwAYAd4ynVwpGOvfkpdUB2MzKFJspkt1kE0YtktUpBgPQbrHo7Wpt3xoblsypk2J4hHffSjai2AsGA6EdYVm9aPEvRC1TWMuLK)WF5QQRYBLSoJCxhCznhe6qrQ9w4ECRo91sxXdVsGwKu8yU72vHu6abKd9hM769oMdPcpC7Be9YniSUYuN9RznGP6tOiAUKAc3rYSuP1l62TlVlXf((HwB9Cwb1MHB(8KXhvDNrkVZJkVZdsUt6o8iD25KhZwzYNN8Xb0O8BbWweuLtgkwd1WKJiBWQP7lpK0NUGdAWjNQgpOtZgfKwim)IwJNBOAstlKXqWAeNBiEB(0dLt5vo)o)0T07elTmXjX07Q2TKjYc3lvOnjkO1JklY32j)UfpkgpOVyl5CEdyn6gDPFF3GuQADcQTdn4KEi6NPVTHoWg6)A80tjXE(e083j3uuPdwUfc6fpJ0mpXf2ERhSpNPEnfV8V7GHdhPx9k2j60bVXBYB8OWSqA8vzELovGrTHR4vJiElWPvXRvPHlcv62wrLxvcEfnoyLSXtvPMkITuYvf6ITGg5K1hu(w3gooDRyZTNFj9tEuA4i3R)Wy4zk83zHLCYloIuEVfJhLkF19pkx55pcGkhKxXr4RQ1EnsS4wVkF3bh109GqYUqNTeiwll0ppd6h2AsekzTa52MfTlCbwyr6MMKSPZr77Cx3IJ)M8uV0HfRCrV4Ijel8FIxgfhqkE6312ovVxXD1UDSY3VnizJmdq7adD7zR0HJN5UUQTI1DLp4UkBCQWo32vkKPl8uUTmkz)dso0(06uQgZiX7QoTbyS87rWbumsD1iBmjDuBYm7KHGXtTfgxMwl5rjZYnDOw5D8v1EjMgHkU5DcBZxQlyuZXu(VOIkrt(KFgLru(dDN0AOkE4UY1UCrOcQNxheFEIYkPX9Jj67J)70Vcfddff3v9BbJgfmY(yPl(TelFQZZt(yVJjjie(matYpKlH6xpU5t0KCAgPEIIP(Q75vCBirDNF28qwnKKQOLIyEXCgN(XztpGdOh)MW)4k4cqIW(3ZH4)Lna(5pZ(33b(41z)9esVpBQajZMnDzGdypoOztJvxL04It2SzHak0PebYN1anjscnQkFuHklqJSgOltjNgfdJuGH0pU6APFDKwR2SwJcVXQGxEsNvliwcflRGnBuy8Kamk8XBd3Eqziyk71MnnxxX0X6P2y5xGcLVwpu(4GCcipz4YJWgYboQ6)OG6ZeA8b1BojNotIJbokgtRMnnJ)AQ9LfzSf1q(M3kgYd1YqkqroQDmCqRziINyfZo8Ls7ScMbJIzPwrkZ3QJriMI)QyeY4oxtipxDm9Ydehkw5r1RYZJj15W9nVHyKxtyFqvCYtbP8AiR8AlA5XcIQQLt)GDkhXQhhBmMvCvZxpgwvvZpNB)QbzXbugtKVwHjF1KkF1IlFmxTy)lcvRFCGzo6IEf1PiYXzqM6ROVLrxa17KsOqgcQODLNgxrlNsavdjiidoITVOYs4FBGY7S0aY5za38utopgsf7prIJRHyZeIdQbCv6ZOlMsSPKKNHX1qZg0Po5sZ5CidBI9AOYEkCIgL92Mq(P4SapiwHVcrP677VbFG)6RbMzRX1tH4d98bOEbkSvvtllLBLMIIgm(s2gbZ0elbEfJi1S)Im3o)QcbjvRqoPzOkTnf7JJ(bounlwCjlpqYbM0iD)8KrmXlw5ir8j7HuLcNNYqpzjzQsSQqw9SKDOSsLPr6IzYtR3vC)3odv8Oy6wvP0YX)YYQlpZlzs10eLzFIxLfAD)y2tRhycr3uXqL6q1nf0YK5amDLzzFZUVNDaf5SjZbiwbqzP)ChO67yxqjcDYCcI1ku6eyBo)7qZxcBpzgUyPLwZWkwcusRMTaBpBqP5kk1(OybVwZFOZd0mQGEwwVSMbFuv5ygfcArFbVwub6JYaG6DEUv0y7rF0mFd)Hf8KQ6hi7R74IzC1IYPuWos9UlFMaRDYJDS1PBAUr2fE1IbXrM2Bu2x)ul67KhV08vtzWNnfZQuDiO6APVjwHIbBQwWzBNJr8mcYNZrd9wzyu1MNwm9Dlcw5yPz8EvcXxzgLQfrQBbqnXGu4tvTsYkxHuDXqn)0tyGtSWxggUquLTI2qgz6EygZa1cawXhExDyyBBtXwMjPQKyoo3wWosGwbU3Ak5BPACSPRyw(ABtbGeIFE(eZLbqtlWOaGAryoYzzoFxLIsvfmYl4I4sH4LrOnJy0wRzFvWN3ArOxMVX0fplF3dsXIuEOykzFzar534JyzvTSawdZA1qTwnCRTfycSEQaFvrClshywqtvjzHpsWcHV6Wt4lkrHzwGyv9MMbt(xnz1e5szUdvMXXlbRvplIEAmtpzoCvlrx3qMwpF8TOvJyzSXoO3egK0HFM2xQQnlUkAFQHbS6PeALCcTANFt9Wn1bl3dRQnztMGBkfLplok))uHidyQ8vZORj0Ln66jtxsK65Vn2y0WKzg0mDXqLpcM2JKZnLLZxoAoFP55mZ1B6zGMJi0clPWCkqBehOnNe01Mf0grQif(jtxTNYVQivl5rMYuTIo5hHG8D6UwuNMPv1NhyvuN(9d3PR4WBEs9zaEj5tTzhkXtIlaOEhkr9jJTbhRG(6YgshBMXP6J0r(ztOMN21LO2xnMAFHPQnZjQQds1NErLe1vy7HBjsCtr7xR6Riv2NawL4SaLmnktVINsf)rRfbsRhdsRIcPv2BvT5qA8FBchVzrkvu0u(biDlwDgXQgqb8Q4a(5qcCw4x1XaO5a8s9sxe2HFBmtZ5iolIQ8O4R6iznsfQcMkgsumzeGVqwF0Xhr(SBmeV266gdXVXqCMaUXq8exXngIBGHiEiMm7Wxk5Qlyg(3yiUXM(ngIN(k1LAxVlziUQpvgX2P4d7u9)3RZ0HPuvOcQnwhLYAgdgLVXpy20VhV1X1508UFNFagQr0JD7z)3p]]
)
