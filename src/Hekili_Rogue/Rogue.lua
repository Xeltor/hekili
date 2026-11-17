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
    specs = {
        {
            key = "assassination",
            name = L["Assassination"],
            tree = 1,
            icon = 132292,
            role = "attack",
            nameplateRange = 5,
            package = "Assassination (wowsims.com)",
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

-- Loss-of-control rows are plain on Forever, but reading each row creates a client table. Read them only when the
-- client announces a change (or when this class loads), and keep finite scalar expiries for prediction.
local lossOfControl = Facade.C_LossOfControl
local control = { stun = 0, forsaken = 0, movement = 0, incapacitated = 0 }
local controlGroup = {
    STUN = "stun",
    STUN_MECHANIC = "stun",
    FEAR = "forsaken",
    FEAR_MECHANIC = "forsaken",
    CHARM = "forsaken",
    SLEEP = "forsaken",
    ROOT = "movement",
    SNARE = "movement",
    CONFUSE = "incapacitated",
    PACIFY = "incapacitated",
    PACIFYSILENCE = "incapacitated",
    DISARM = "incapacitated",
    POSSESS = "incapacitated",
}
local function refreshRogueControl()
    control.stun, control.forsaken, control.movement, control.incapacitated = 0, 0, 0, 0
    if not lossOfControl then
        return
    end
    local count = plain(lossOfControl.GetActiveLossOfControlDataCount())
    local time = plain(Facade.GetTime())
    if type(count) ~= "number" or type(time) ~= "number" or count < 0 or count >= HUGE or time >= HUGE then
        return
    end
    for i = 1, min(32, count) do
        local row = plain(lossOfControl.GetActiveLossOfControlData(i))
        if type(row) == "table" then
            local kind = plain(row.locType)
            local group = type(kind) == "string" and controlGroup[kind]
            if group then
                local start, duration, remains = plain(row.startTime), plain(row.duration), plain(row.timeRemaining)
                local expires
                if type(start) == "number" and type(duration) == "number" and duration > 0 then
                    expires = start + duration
                elseif type(remains) == "number" and remains > 0 then
                    expires = time + remains
                end
                if expires and expires > time and expires < HUGE then
                    control[group] = max(control[group], expires)
                end
            end
        end
    end
end
spec:RegisterEvent("LOSS_OF_CONTROL_ADDED", refreshRogueControl)
spec:RegisterEvent("LOSS_OF_CONTROL_UPDATE", refreshRogueControl)
spec:RegisterEvent("PLAYER_ENTERING_WORLD", refreshRogueControl)
refreshRogueControl()

spec:RegisterStateExpr("rogue_stunned", function()
    return control.stun > query_time
end)
spec:RegisterStateExpr("rogue_forsaken_control", function()
    return control.forsaken > query_time
end)
spec:RegisterStateExpr("rogue_movement_control", function()
    return control.movement > query_time
end)
spec:RegisterStateExpr("rogue_incapacitated", function()
    return max(control.stun, control.forsaken, control.incapacitated) > query_time
end)

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
    20261114016,
    [[Hekili:T3vBZnUTr4Fl(lkstVkBzl7C5MtEM(sstY08YeN28nrrtcjXkksneKYXD0OF7DbiijaiaibfTJ9u9LC64l7(S7cS7ca(Cz(K5)68h8DtrZ)XRV667MmzY0RMC38hsFEhA(d7C924Uc(rK7w4)(3I3(OB6XfdFk(jCWw8yV4TJip1ZHXU(ej9ywqy63fn)rLcfVd5n)HF5N(h)RV(tEuzn)H1b((O8xaH90OJpDCr6A0XfSRD5Y4e0EuYXf(OLUzHWJ)x(5)5XfWLpUOuazbxsui(YK4vzOl93HV0Dxi(s27mg(lJ)p44OrFaKEIBeoeqSp87yI2cWhx467hh9fWp2GEgp(4I)UBQ7NuGIH)W39RGqwNMUd)PlVCvq66Shja)sPhDeitaAOBD)kp)RDV2FPhi2Fl(3oU4Bkewi8hHbrRGhncqtuCuIBa8JFE)xFCXUKG4KG0aeMyTHHXpDCX3598Xf)BuqegWWtGUjYWnjc5)Nb7pmKjONqU7IJGxZnm8riUsmOFL4uXz4u3GiIPNRjF3TqqVuzpxOkmlkSliI(0aUFamUJlirDFqC)CCaMOIe02GiFucMPAKRhaQ1WVjoZDjOLOeuKhICT9iQudalp(j4D)fsWcafknfCceq(qkYnKyvKqcoB1keMgNOr74Su)yYp2LfgIlSF3JlYWUpgcckEhkcLmggLMeVmiegf76LgehHhd4iFq4SNccdDsJDWzj7d2J(qWYz0Xmo72JC8IJsr)E6GlW54a5pg8GdYFaCAg1x891e6FA2LuXgV0bEhhaSy3nOilKDXRqFQK4q1kbM04Ud54MKgGtTq6BJ3J2IIslK(GhZwUCSG0g7tIik1konocbaCBR04qQS9dOdhjHfND0rkJZ2DO2TGFJCXi4EJYXuPUmHN1UPPOehVSeC7IF10l9vbTYukVanO4e3Db(ojOvKrzUK7)HmmcI6lDw55pBYhiQi09zNhrWmOz3Dvf48CJCiscM1NRZ6YYKIrU(oHONDGCfijT8rQwsJxTkeWomBlcddRXd0OxI6wf8FbhJE1bzxsDHrl5bojBeCGOWz)aKe54IVfMLt0oBQ1vdUixRK5HWeAhWTcjFgufFsDtwHshSfEBhskIXyak3Fvo0kVQdKVa(Z8XKfVnfloKNz2e1W2h8sHp)Mf1x3vu)tlx2DqtewnmxCrdqgEeDiUfdpETG8WAyEYH6MXGYcmLsj)2Z(c3S04VyKU8E0CisgiVbXSN8Yso5vFksOhGc9DYRUkNoI8(XeieLcT8KLa1ht)80bdhMJIXERHY3o41XPJ3evfzO1FiPVgm8cnp5bFe1BXDDIFAu1BSjWpcsKu)v4Vb7DWXHXhYdkJdWSWdjYrs)an4m6qjKD3(ygEntISRrB8i19X8RoIB(JVluyVWt9iAn0abil2RTYnjjofjy6(zjudp)VXEIbmKx8cuuRjw(yORpeucbN9ZvzLl7gQyqyOlPcVdP)IIrR0aPAHc)ElYpivvPGtqh9ylkVGnM8A2oYBJMqELB94vUHJxL2mAx1J)qltpHhSnxC(puSETDy91QQC9kWwoa41cO9D7dNBA49EtdqeCtG3MQa29xvFew(fqrRGWurz9TOquPW9CXetMKLxkkk9a7VE2vI6U0F2FqqEGGCTsRhxOj4ZpEXBdtgEXXHKBMFnOHjiEIVFMekzx)qD3ZKrkh5FVyoL1udIw32yfYBUYSBv01iRb6O44gldpTZkPQjhPc73QrIfnDWgW7grMHOQde9T0G27In0(ATXCQvczwFv8F16yCkulcNMeSHnPmVVlP7qhp1mAu5nScEx0x4Bjcgf21PM5OqzlXRdwTgArh6alvEgCTU0c2byuEC(YyVmCEGJ271ZJdJVFgZEzVYyp4)cEbUInhuv4j)AjimkbmlYexjql4sQspufwKQrRP21B0ku8ghRmbV7vPfouTjEq1LNnDWfPUHWVghefKganJVhbDmt8b(JST4fpAZlO(AasJLL5Hur9C7gBCB7vaAFa2JSIgKvQ4(zt5LY2S0GqtYGnpM9yAqTybJTXjjRHjuwHlrHGbFpMS(W88rNGKiDQYEAT7ubmtiL9mcHWW4yFNLzjpR7nTm9XGYKNSNnicw6VRhzNuGuMdfMbCGldkKvfTnab9pC9HYMYlQdgeLfNHDYL9ObCzbNYweqLHuBMZJiy93jBab(E3glnK6v6dZIqyyX9RwN(o3k5nL62zwcAJ77ul8RkSqQruZ20wpQZMLGbmqrtqorqhMvRJWqPOESaJIQA9NjBYinw35fYaXG(20d2flnorAGqGkhRrjIjYvTj4NO6KhSle58bhbzDtGefAmPZ6KntzDWNND7vvT)Hdd8qoKDMXh(bFd9s3HShVd1mlvyMGyasqi94iX(j9HkdLTI6ppBsBw)Cs2UuiHtpAzIPvyjlyQrA3cSk4PCMMqNoEXaIPL679saQvELLu1lkZkQVumUhHSASrn1kBxWQz)tFLTrEFw5Z(KehVTfnLwFXb2IgZPRzPF3Lf5bJ7i9l)uCwKpUilClGO2oWTfPnRkf12vxV52bxiv9LmZG5)lpUrgMwtMouSCbgK416ExsHI6tvgwTBj87T6bvQwZJwF0FX9Pd91T0V0GTO7jB8NKfXJ6DjODUSJeJa2caKBnfqTCZhzxMCaxpBuUMwRtPs4RJYu1qT3QyPhCxhCzDheMqrP9kCpMvx(ALlcITf7grIyhddhQrkdGaY(Xt4U(OdCiv6H7FJye3GqBLPj73WYc7w9ldkRmX8WHdzzUEmoo1ztuWsOGoCZ7ND7bD3zQ27CJ27CTI7uUfpkNDo7MQfR85zF8ksu(Tayfbv9KHYfRAzYrfnWoKtvDUf0Ygg4xhB(CdDtA6HmgswJ8Cd5BZMEODkV2538t3kVtU0QeNctFOE3sLifUxPq7suWOhvvKVVt(DoEigpiVyp5CEdynMgDzER4GuQgDc6Tdd4KCU7NOVTJoWo6)680tfXE2eu(7Wnfv5GLZHGr5ZiBNN4f2ETd2NYuVUIx2h2WKjtnREnBoD5G3899nFuyvin)QuVYGgWOXWv(QrKVf40A41A0WLHkzNFiYRjbVKehCk2TQMutdXwctUsdroqJCQ6dIV1Tj3wU7S(i301oBDt2u2p5bLHdUx)6BHNr4Vxfw4KxEeHTIzURNpkv9Q7VrTY5pvGghK3WxMSUw7niXkWRtaqx9DDpiuS9JvlbI2Yc57)G8HYweHkwlq1PSAEHlWclk30KIDHK81znuC83S7gvoSyzO7tHim2b97iVS8aI4z0BTDQFFKhACpCvVZJqYgvgGXbgM2CuLdhpXT30yfRlQFwEn24KWwKoujKjl8uTTmTy)dkoh)Y6u6gqBFbi(iHo5EZafrndPJ664nXZ4Y0gkwANI7GN0E9vI3PkwIDlXe)xArJOHpdyRslQ(HUqzHunp8q1AxTi0b1tRnIpptB508MYK995)9YVoLwgke)evohm6uWO6lWw8Bqw9uN7N9XrhkMPl9XgwmBVZtTuCwfL2UygVYDzIR(zrJENhey)GG(mKzHK0fT0eZfZsC87N)WEuc5ZTv6F6gcbiHP)Bfr()6ja)8hP)BhbBe68)AbX6N)Gex1M)GxsaypbUZFixDnYgmgN1MNcOWKsK4Wwh0Kmx2iQ8gnQuGnADqxTLJBemmvdgk)OTTs)M4(M1KFJaVB1bpEURzfeRHcVgifhbg3jbdHpkC42xvhcTLeCZFGRzyYy9sBS(lqGYxAgkF8kobWZPoEe2rQ0ru)hLuFLqZpC(2ZvQtK)zGJIsyR5purdo9(srIFrmKV6TIHCTvgIat7i2XKR6ndr(GQO2rSs2RjyguMQvAfLeOZgJqof)RIrOIcEDHdE2y61hiorUYJUxLLhtPZH5BEdrSVUWBIMioHzU9PHCFDKDF9f9(OHyDv6jFSo1JN2XSNUW7pkO0v6NZ73)ytEauRjeyVWiqlPeOvCcK6tL7xrQ68nx1opQOxrFkboUhsvFd9Pm9fq9bLetKIGgAp5UBBOftfGQJenKch52v0zjmU)PUtYwqYVwWXp9K8JIu5(ru446i2AdbenaUg9zKfpj3esXZq5Sy7g0Ppls35UifB67TWk2k2r6kc(aYwTt9CA70pxRu0QBDOv59QpqOnmYYgkp(Ax7MA4Y1iBWi1rhIoWhcBlQxfuyxLlgtSeDfwZBl5v1Ym2KdfS6wHDr7sncxn7duZAwUyvvELIZzPt6((ztPIxUsuH4l2dQgfolfKzAxsvLCvMQ6Jf7WzJkZG0LRmuw)uC)7obvCJC6BDjQ4yYzD1H54WjvQYjE1j1QVmS6c1Y0TvueOnuMthPxAK1lntWtQdOTRSR6t999SdqK9NuhGCoDTTsWDoSVJDb1Ogk1jixoqRtGU5(VdnFf8gLA4YLw6ndtWeEH4nAhQ22qFb3ixWR38hM8aDJuPNK1x0NJGXRRCmL5b9OVGvlsGiQuaORinpTm6DCipVIIeDf0Lo)VEem2qDvR5UQe5vjM4u9Bk9jAj9v6lvgzZ8wLByRWRkowFQ(vCEIwVyIp7z2QLuBLBfQ56qYoBB)nvF5x9OVqnKn8fJ1IpzmQvP9yznSUKUyfk83e1R9ez75eLYhucFItdCOLIr7x0OTW8fHCTuSRBzNnUCkBnbdyqUyyLQEHyDBdTMmTT7tAozwfaSMpFpBiRBFZwxQjPRklh9DfSJcOjqJ32YJxIgVTTRIw96DlbGcoKE6C8LcWtBb5gzoB3OoRsuQBhq11OMvCJRvKJR3SVgOgSvCdM6BA7cQvVJcDS5avaP1vPmsOydK01alDnqt3EGuXMzv8RkI7rMftdA6kBByHhwr54xuohtTa5I3DndM6VeZM5eM2Ch6mJdVeeG9K4mARjnk1HRBz7MgY075JphT6eHLBTd6nHbPC4xB7lv3gi3edsnqMwZSlTr6L2SZVRE4U6Gv7H7WMrznBNpj6o))vHOwq65xnJ2sORA01DTDjr6N)2zJXaPOPqRTlgQ(XY0F8LUReM(LJX0V0uMM66B7(gYXPAPLu0E2u3k6u3E(uBnHQBfrL04NA7Q9eOCnVNs3sEuPmDRORYsBsYwYcBQw1FgHnXc73p0WUHTr)o9Nl4lj1SB3zzCN8caSBp(TNx3Tyx6nxxULm7MAC6otq1B1VEkFBlNV7kPVBM13)rq7BQRuxFKIhlDJJn0Zh8(Iq4e0(L6(Evv9XH1iofi7zRY3R5P0XmvROMQDCtTjYP2yhwwZo18)EB4lonsPJ8NQ)26ohRoHyvhOtEVYNCA8w3U)B445kDlVien)8GKUt3CAev35P34bU2kvOlyQziHy2haFP02NZpv85NjBU166mzZpt2CQaot28cxXzYM3cdr(SlP2rSsEAlygXNjBERn9ZKnV8v6xcR9UKS5M)qNLxGM2)FfpvhTLtdA3zs7vkTvnyoW64K5p8TOnbHbhxm8BItq7ZPqy685)V)]]
)
spec:RegisterPack(
    "Assassination (wowsims.com)",
    20261114016,
    [[Hekili:T31wZnUTv4Fl(ffPPBLTSLD2SZkpt60KMKP5YeL28MOGeHKyffPgcs54oA0V9Ea4nqqaqakAh7P6LSA5LZ57Cb4Caa)2mB0SFB2uxumE2pD7n3(WOrJgFZOhMnn(594zt3JwUfTg(raAh8F)AcbriEbOyVWGtZ7)u4teVDKHld3nG(Wp7hICPcCrINF83hmBHuzt2JxoB6V(Z)J)138jeViNnDJNRlo99WKL614NonpEd(08SRD9QWi8bC0P5U4vOe)4tZ)6F5FEAoCz4xcYjX7AkkixhfUobFT7EY1O9(KRZE1HWFz4)Hegm4dGsIqbeFWmCHFhsvQh50CKRByWxa)yl(zYWtZ)7Oy0NKaM()43)BGq2ehVN8PRVETx8MKfu8FTWJoaKjGz89OVAP7TOBDxTee7Vh(7NM)T5cZh(dFVG1WJgaOjimic5b)4xo8nNMVpYlmYl2dtOgTVF4tNM)9lF(08)n2lGay4jq3uzGIcWU)vW(99Ze0ty0EQFzfY3FbeZPg0Vr9TKesmYlGA6PAYfTdsiku2Z5QIKfm27fWEAa3tbJ70CAQGliUFj0JqvreENxGloIKPAmAjaQnWVPoZ9r4v4iCWsm9AhWmP6bwE4tW7(R0GfakCCm4eOGCAmg5tTkAiHKSEnMWItSGEysSBi9h7t89j52p608ecAHpiOW94aC0qi1nkCLNpKHJwstqidbCaHOfO4jp5577eh6qsIo4Da)bVvty5mo7pGDwggeJ)J4ExrsXb2Di4b7L(aK4eMV4hQj0)YKRzInCLd8ooayjOT4alKD(RWEQOqF5kbgcH2JDqrXEKylK(UWd4D4G4CP3BrYQvdRiTHU0iIuTsIddWaa3zKg7ZKTRhlDKgwC2ZYugMS)yTBb)gJiy4EdsXuHU0HNnO4yCKZYKiIzXVA6L9QGwZukVa1O4i0EpxNi8AAwgBMNpKqWquFLZ6LUtg9bQk8rp7SadJGM8WnLGBjkWHkjyuFQoRllDkgJCD8Xp7aZvGf0YhzAjoC9AFa7WOTacKwt6PqVu1T27)cog1QdMDjgbzlPbobBeCGy)j)imjYP5FhmkNQ9SHw307QuTshhcdODa3km5tVY4tmkAnoU3o4TDOtrmKaq5XBsHwXvDG5lG)mnNm)TzyXH(mtgjh2UGxY)53SO(22I6FE1Q2dAQWQH58lQbYWJOcXgKE8Ab5(1W8OJ1nJEffykKs6TN8fOK4WVyGQ59yZHiyG8guM9KwwYjT6t(e6EyFxN0QRIthrF)qkecIHoFsIG6JXFECV(9trXWLBGY3oKnHXd3gugzy1FOtF1R)vkEYJUyM3I76u)0GY3yRNBamrs9xH)gzVdj0p8yAqzOhjl8qJC0PFGgCgCSaYODlsiBYKy21ynEeJwKE1bCJFCrqH9Cp1c8gObcqwzV2AuuuymUIP7MeXm80)w2t0ld55Vad1kILl8rUqqXhC2pxoRCr3q5jH(iAfEhA)f5zRSaPCHc)Eh21lwwPGZqhDylkVGnM8A2oYBJMqELB94vUHJxL2mmR6XFQLPhXd2Mlo)NkwV1oS(AvvUEfyltaETaAx3(WLMgEV30aeb36TCBza7XBQNHLEbCWAimLxwFh2hxi8Lic1KPZYleffEGd3o5MQ6UWF2DqqmrqSwP15fkc(85ll3MjJLHH(0BMEnOHjiEsECIakZU(X6UNrdKM5)y15u2WmiwDBTviV7g9U1QUgrnWYIdBSm84wRKYMCekSFVcjM30rwcpkGocrwhiQBPbFar00(ATCo5kHoQVm(VEtijgQfrIJ82MnOmTVlH7WYNAgnY8gwbVR6k8TcdzHTDOzkkK2s8gV1BGw0HoWIfhblgWkhow6geQjQOwXB0kc8gx20YFyv4YecFEOGf2xUjEu2LNmU3vXiF4xd9c8I9GMFpGHouP(a3b2wSGhTPfWEnaP2YG8qkV(PD5g3BUcWh8ilPRGaBLkECYyEPSlj2ZxNmYg3K9ykqD1jO3fgfTbg0zfUQkec47j01JLo()mKeTZWSNw5odaJeIZEMkHq)WqxNvjrpR6nR2Ny61IWeCemleToRSEhztwL9SEbWsTrlP7Cbmfv)kJaoYnJfmlgENhgQxF7XIMGZR74fKeMqCsL9GESv898q)qisN10DPHuBKZcmSE3OTGaFVBJfgs9kR(jbycSy61BIFNBL8MsD7mjcVf9o1c)QClKze1SnL1JATzvXa6jPPdNaOJUY(21ukQdlWiPQw3zY6msT1DEHmqcOVTDGDLnnovAGqGkhBWrv0JV3sSdD)cCHF0Ho0Uzuq6cdQGX8fI95jJmzzxrj7JHXnDOLvD0rwoFMAewKPaY5AIx4o091vActLc2lH1P6WQy15ZKjx5Lwszlvzwb38t1FKLW4Obn1rMTyv6aTj3NNAPRnSjJFrgCjUnE8d2Icd3zqpy1BY0w0yG5xvL1B)2wvQFcXRSgrkBP1wGzVQLu8u(e6337kHYB0XSzr8IZpldaBOduZ7hpdI8A9aIotC9bX9lx(p)MfEuMQv8O1hxMFF2GsvRTk2Bh(r6ozjyr8OEFeEpk7mEOGnhaPwtoul2nTSltpXMN1kxDlMOqj8NoAMQ6R8w592ZDDWL1EqOdff2BL7Lz1fVwXQmY2ZyTiP65a3VVcP0dcihgoI76doYHuHhU7nIbCjH2ktD2VM1D1UkRAuwrPG(97N1z2IWWyNTbERGwnGB(iuIr1DgR8o3P8o3k5of7HI0rNtURC1aFEYhVHgLFla2QGQ(KHILhnCYrKly10DYgMRpBRR6ZPQ7VPL9xv0kd)cfthBOAqthmJHG1io2q82zdpuoKx54B(HBf3jvALItIP3xTBPuKvUxHqBtuqRhvwKVRN87s8OA8G(IDKZ5nG1Ol7s)EDbtPQ1jO2o0Gt6bjFM(2w6aBP)R1dpLe7ZgGYFhUHOstwUecgKoI0mpXlS9AhSpNHETfVzNu)OrJ1REf7(BrYB6gRMMfwgstVkZR0RbmQnCLUAeXBboTgETgnCrOs3tkQ8AsWROXbN89rRj10qSLsnPyFSd0iNS(G4BDB09fB)PlgfVXzhkABr)KhLgo4E9BVhEMk)9YWcN8sJizRyM76PzPYxD)DYvo)2U3ysEdFQTQATxJelbVkbaD1329GqYgJwUeiwll0pOb6x(zEekFTaLhJP(fUalSOyttY3Fu6NBu)Q5FtEyqrAXkF0t(ycXb)h4LjPbKQhcU12P6D4UV2Dxw(EIct2iZa0MyOBBBvSPMN1gVQTI1v1pSSgBCQYM32xkKPl8uUTmoF)dY3vUI6uQsOTVaeFKqLCVRNKOMMPJAB(w1drs3gkwyNv3bpH96RaVJLSeBdXe)Um3iA4Nb0OPfL)qxjTqQIhUVCTlxeQG651gXNNOSCAAtzI(EH9A2Wqr1VbKlbJwfmk)KIR(r1kFOZJt(4GJ5J0f(65YhT36Hwso7IcBV6mEf7Yex9Z8g9UKeyFsqxgYSqsQIwkI5vNL40pmB6bCe97hv4FGc8biry)dJq6)Caa)8Ny)dLqwg6S)wotXNnvG8vZMUmYdShp0SPPQRr6nLrcRzXak0Pebsz1cnjsolQkVtHkRqVQwOltjTffdJvGHIVczR0VoYCznBUOW7EvWJNmwwbXAOyzdS8IcJheGrLVYz423uhcMYQRzt5AgMMRxyJ1Fbku(s9q5J3WjaEsIXJWwYnmQ6)OG6lfA6NdG5K)5mjuf4OymqA20sEDP2xwLjtud5RERyi3ALHuH6yu7y0nDMHybDSQygmQxvyffmcZgJqCk(xfJqgNYAdPYSX0RNiosSYJQxnBEmPoNmFZBiMQ1gIj0eZe0twnfSvRL0vRR4RgleRQsp9J3PE80oQQ0gISXaLQs)CE)UhBIjqgZWToHIBwYXnRi5gZNk2VIq157UXmpAvVI6Pe4itht9n0NY4xa17vW0ogcAO9KhUVHwmLaQwYCogCeBxrLLKrMn5DsAaR1mG0AQzTgdPI9JiXX1sSzcJ60aUg9z0fpj2es(ZWiHNzjDQNfP9KXJHnvlFSCMK6UwtirKnS071UAiZWfBSObJu1xWFl(e(TTmzzqj7QqMd9akO5Bulrv9Z0c9VQwM22gyGvvD18gqAeUk2zLM1SQvlxEYfTs3pozmt8IvxYfF(U60OWZguR)ZsMPkXYiLvCY3ZWgvMgPlwvOOIu1De7CuH405QMeLJ8H1vhHJ2HSnmsCAwvsT8BTQUqT9JjVygBty5LkcU0idxAMtImhG4C5kDafF8SVNDavjSiZby6If5pzZ3XUGASzK5eelhO0jW2U83HMVeQoYmCXslDMHvXeEHO6ylQ22qFb3jwWRZ8h68aTJhKNL1N3NtfJxv5y23YFh6lYQfvH7KmaiwKUZ0yxnIkDvH2sBsopzLxvW9RENWptRV6yr7jwPLmRS0CZ0HGDAANmLFEpDOVqoK18zbzW3fe1QgRAbR6Av2wRqftnnKQMmCQAXRD9GCXTnNFqVgoCYWOQJov96cSfMg4WYWIQvkQEXx2ILUG1NmOQ8OxBAvi2IylWK6cQVq0bTHk8JflYPA2NuwwwbWk(UYSHfPDnnszMKQ12YXR0k2ro0QWVutjyktJMUlOYx2ybaKqUXZN8PmaAAngfaulc5iGK5C6ugkVxvndEbxfxkeVmsBzeRT6m7RboRAfPvz(MZBH5TSHgzarvXOAfm1Y0vnShvd9r1WF0oGTR6P76RkI7qkVYcAk3F3QFrCvcF2Wf2xuYWYSaXI5TDgm5FIGntwjLZDOYmo(sWmZZImJgZMrMdx1EDRlLPZNp(s0QvmP1yh0BcdsA6NP9LQAFyBIAJAy5PEAp2iVhB253wpCBDWY9WQAt2Kb4Msd3ZIhU)FviYa24(Qz0wcDPzxMUKi1JFBTXOHTUmOz6IHQF6gDhrEBltEF5OY7lnxEPU(hm98v5i7RWskmNMVgXZxZj6R1m91ig0OWpz6Q9QWfyEpLQL8itzQwrxPL2KKTKEWmTkUKe(OSE6b)(HFWnS1)pO(4gFj5mSzN)YdIlaWUZLWEchBWjlOVUSHuoMzCQoBp5hpHAUiBlzKBlBKBMoY)zWhzMRuvFKvpD3gZnutu5UIPYm0Q6tts2zP0ioRWcrJMVxXtPIYKwXzs7inztSMSXoSSM2KcNsstrkX20YJuY)e1UeRoJyvl45CNs0zA8(lvT7)AoUUc3YlcdOVKK0EEqZIOkpB9MoawJuHQGPIuIQZ(a4lM1(C6b0p7clOTwxxyb9fwqZeWfwqN7kUWcAdmeXZUKzhHsjqCfZi8clOn20VWc6IxPB5917swqR67NrSzRSKsv)FLBMom9C4vUZK2RuwRAWyGnHrZM(D4TE(ENM3)BdJWhszIx8Sz)Vp]]
)
spec:RegisterPack(
    "Subtlety (wowsims.com)",
    20261114016,
    [[Hekili:T3vxZTUTr7Fl(gfPPNkBzl7CYzoYZ0oVjnjtZhtu6BUtuqKqsSMIudbPDChn63Exacscccacsr7J9uDtJm)y3NDxGDxaWNtxmzXVVyUhkbV4NV(QRVBYKjtVAYDlMN88E8I57rUpG2a)ieTd(FNNUkjaN88XLdFk6jI)oYy3ODJOp3ZbripQSwL6hK8dHlwPuSK9y3fZ)TF5F8V(2pr4sBX8T(EE4SxbtC1QNpDCzYw8XL8RD56Oy8J44Jl9WRrPbjhx(3(1)5XLWLpUuqeP(xsvl5Y4OnP4l92tUeTpGCj)Tgd)X4)njkC0ha5hJcjbaU9GFhr1Np54sKNxu4xb)4b8ZKXhx()HsqFsbog(t)WVdczBsYEYNU8Yn(jBtxrH(Lsp6iqMaCX3I(gxVRrx7T2fe7Fe9hhx(D5cla(pb(HBGhneqtyuymYh(XV(43EC5(y)Oy)eFmHAVbbrpDC5p4cw7)p2pKay4jq3uzGIdXE)vW(dc4c6jmAFui8AOGGvq8LAq)o1Tssjji)qQPNPjp0oi4xOSNZvfHhh27hYEAa3ZbJ74sAS3de3Vg5tOQigVZp0dht4QgJCbqTf(n1zUpgVghJdDX0R9iMjvFWYJEcE3FJgSaqHtsaNafKZtWOaQvrdjK0nBWewCIfVJst8IO)yFAqaj3(rhxMsqRcabfThhIJhdJvJJw7haJMrUj(rHKXaoGq0kuYSN8dcCsICiPXp6)i(d(RNXgZ4S)rSJBuyc(ptgCbjdhyVXGhCq2dqssz(IFSMq)lZUKj2O1oW74aGLGEah2czN)kSNkokqTsGjoO9yhuCIpjPfsFx0J4D4WKCPpyv661JRiTXE0iIsTssIcXaa3zLghYKTNpB4inS4SNnszC6(d1Uf8BmIGH7nkdtf6YeE2IssWXoUPXe7IF10l7vbTYvQOanO4y0EFpNy8g6Ome9(FiLGHO(ANnUEZM8bQkcqp7ScdZGMD3vLGZff6qLemRptN1LLjfJrEob4NDGCfyjT8rMwsI2SjaWomBlKadRjd0OxQ624)FahJE1bzxsqWOLSaNKncoqCWSFcsICC53dZYPANp16QbxKPv68qycTd4wHKpdkJpjO4n4Kb7G32HMIymbGY9xLbTIR6a5lG)B2yY83MHfh6ZmBIAy7bEPGNFZI6R7kQ)L1R7oOPcRgMZVObidpIoeBXWJxlipSgMNCOUzmOOatHuYU9SVcLMe9vJ0L3JLdrYafniU9KvwYjR6tEcDFCGNtw1v50r03pIcHWeOPN0yO(yYNNoy4Wmum2Dlu(2HSnkz8dHLrgw9hA6RbdVqZtEWdZ8wcxN6Ngv(gp47fcjsQ)kI3i7DirbrJouGk0UvPKT8xIFnwVfjOvzxDKWuepeu7o3zScVf6raKf)12GIJJsWvSoV0yMTL9x8NyahC5VadyAcxRcqEGFpa8NpxM4TOHN8XzbiArChAle5dizXk1cf(9oSNFIQS9NGo6XUqEb7941SJJ3g9z8k3DXRCpfVkDsyxbIVOvINic2MR)(ffRx3oS(Av4TEr2woa41cO9DhcN7l4DqFbqq6bF3hkJj3Fv9brzxahUbIe5vU3HdWfc3frOJjOjYLcuspWJxp7QQ6UWL1FqqowlxoS1HEnXxXHeUpWLHBuua9Mzxd6jcINK7NjHs(1pu39mzKYb33xnTXwMbXknBSi4nxz2Tw11iRbAIL9rnwPDANvszFms1UVvJeZ7RGpGhfsNHOQjd9DTGFerm0HATXCQvcDMDz8FZ2iscuUHKe7)aFszwRvs3HnEQz0OYB0k4DrFHV1yyuyxNAMHcLD9U1FZwOlCOjRe5zWYbmRwyHuDqL1hQofklz8hwh5MsmiPHQl1Cq1LNnDWfjOa4xJ9d9t8be)ig6(JMfYRHu7IqRmbu7mWPFblZjIFETMxtFBlRakI28kWTZxFR9Ht8J(ex6YmWTsf3pBQOu2LM4hysg8zE8htdQRMIFxuC8wyABRWvvHqGObHUOTSmiNGKOTpYFATBFaKYjH)mvcHbrrEoRtJFw3BwTzYSRfJj4yipgTsTQgmzP74pRFiSECKlnleKKByLHBheY5b5bX78Xqf)Rpu0PCELl)W0OuItMShnGTSWNhhebrAEN5Lgs9HPyyrXXpac89Unwyi1RnhKgIjWkU3Sn5DUvkAk1TZ0y8dO3Pw43KBHmJOMTPn5FNnRQ52v02Iti0tyzN)gY73JLCSPxIoBYMmsJ1DEHmqcOVh6b7INgNknqiqLJT44kB6w6(eyyvp6jRo4H3BtzLp(cO5dv4QpBOIsp2TsBYuYwNDO4(Z1KduoGk1GTyIe47IDOBlJh8JE0r2h5roCHMaq(Enxb85Rs(ZZMyZAIDHfE7WkG27jwv72l7vUSdpERYcPlR)iUW06rn1GyxWAdJm6P5WYBPO4C64OODw0Qx1mB9aMuRs9PrRU9n8fHlUU48lvBbXQAAUlWUJDv3wvPBcNfyqrHC1fxUDWfsLAPhEeFyrXb(Xb7w6S081gWXQOwFerRkuFg8WYnZqCRppOs1AE06tkZVpBgPUbrj(7W3t3xojlsApk2J4hkffS5aiZAYHAXEdYVm9iME2OCnTWMcLiECUCvnu7TYxNHW1bxw3bHjuuyVvUh3QlETIv8WReyejvp46Hd1iLbqa5XXteU(Odciv6H7FJyKWGW2ktt2VH1awOpPIOcj1KUJIzPkRxmC4qExIRIIsCEi0FnuBgU59ZU9GU7mv7DUr7DUwXDk2HhLZoNDt5kt(8SpEfnk)waSvbv9KHY1qTm5iYdSA6(Ydj9Pl4GgCeu1TxnOBJckkekUO1S5g6M00dzmKSg55gY3Mp9q7uETZVfNUvCNmPvkofM(q9ULsrw5EfcTlrbJEuvr((o5354r14b9f7jNZBaRX0OlZ77gKs1OtqVDyaN0Jf)e9TD0b2r)xNNEQi2ZNGkEhHPOkhSCoemkBgPDEIxy7TDW(uM61v8Y)UdMmzQz1RzNOlg8MTjVzJcldPzxL5vg0agngUYwnI8TaNwdVwJgUmuPBBfvEnj4104Gt(gp1KAAi2sPlvsa2bAKtvFqITUn52ITIvyp)Y7N8GYWHWRF9TWZu5VldlcYllIuFVfZgLQE193Ow5IhbqJdYB4i811AVbjwDRxvV7Gt76EqOyxOlxceRLf6NNb9tvnpcLVwaHTzX4cxGfwuSPj5B6m9JNAy1XFZUBuXWI1bONcWeId(pXUPzbKQN(DRTt97v8qJBhR69Bds2OYamoWW0E2QC44jURRgRyDr9dURXgNQSZTdvcz6cpvBltZ3)G8dTVOoLUb0TVaKyKqNCVzGIOMH0rDD8w9T9v3gkwyNv3bpP96RaVtvSeBlXK4NvrJOrmdOvPfv)qxOSqQMhEOATRwe6G6P1gXNNPTCAwtzY((S)U4trXYqr1Tw)CWOtbJYVb6QFIWQN6C)Spo6q(mDPVfW8z7DEQLIdXOW2RMXRThtX5bbTDgz3dzTqs6IwAI5vZsC8hxm)rCm9u3K(xjHaase2)WmK9prbWp)z2)qnWhHU4VNZE9fZLyl2I5UX(G94JwmptDnYhloRXwKaOWKsKyrwh0KmBYOQ8gnQScFW6GUSLLzummvdgk(MQBL(nX(Swt)mk8Uvh8ezpwRGynu42aT0OW4ojyu5B2gU9v1HGT0qBXCHMHPJ1lSX6VafkFTzO8XReeGiR2eryhjZgv9Fus9Lcn785TNTsNidWahfJYulMxsen9(YQuVIAiFZBfd56wziv46g1oMCvVziYhufZoIuYFSkMbJRyfwrbf2AJriNI)vXiurcUUWcU2y61hiorUYJUxLNhtPZH7BEdrTUUq6GMixNg211r611x8RJfe1vlN(D6upI1oQ10fI3XaLUI7c(3(hBYdrSMrE9cL8AjN8AfP8y(u5osKQ)EZv25rR6v0pPxG8Fm13qNitFbuVFbZaziOHgqU72gAIubO6it)yWrUHeDwc)J8tDVIwWYolizNEw2XqQChhkCCDeB2WaqdGRrFgD5rYTzK)mmsdA3Go9zr6o5bzytU7bD2tLJMOU32gwmLLf4A5A2nikDFO(D4l13CvTsBnRcjeFOB0p1lqHTUQuLPCB0u00YWxYgdyMMCTUxXisl7yO0TZVQuqs3AEZBVPrBtZoZyEGdvZYfxkZdKFYhDs33pBkt8YvoYfF(Uc1OW5PmmZ6rMQKRkuwplFphBuzgKUCM8I6Dv3rTtqf3iNUvxknbIuwxDIuOKjvBtuw(TAvxOT9RsVOEGnmwthvtAdN10WVsMdW21Av(X3(E2buL8LmhGCfaTL(foz03XUGAmZK5eKRvO1jW2U93HMVcABYmC5sl9MHvTeOIwn7bAB2HsZnuQ9g5cE9M)WKhOBC68KSEvndEJUYXmUa0J(cETOk8aLba97LCVOX(JhOL(g(dl5j11pq5NtXlMX1kUJsb7u97x8jcS(jp2HEN3OcJSR8QvdItTT3OYpJPE03PoEz4ZFYIV)jMvP7ynn1sFxScnd20TGZ(ohJ8U(lMZXapvzyu3UKwn9Dpcw1yPBeyvbdwzgLUfrAAbqDXG04t1TsYgxHuBXql)ysyGtUWxjgEH48AdTHm129WmJkPvaSMpEU2qv2(MRSmtsxjrbYZwXoYHwfs0AllAPA8wBxXS612waafm480zyldG2wGrdanIqbwwzpXvvIsDfmefCvCPr8QyMMvutR3SVgiMBRyMlZ3y7INvV7bfyr53ZRTS2LbeTF1oYLvnsNxduK1ahznqs2EGsVM507RkI7rE9YcA6kjl9z)vj81gc)(IY4xMfixvVRzWu)Dq2mJS0M7qNzC4LG(PNeJnTMYMmhUULOBAitVNp(C0Qt0f2Ah0Bcds5WpB7lv3Mf3e)nnqLvZC7SrYD2SZVRE4U6Gv7H11MSntWTLRXNezJ)FQqKfuo(vZOBj0vn66oBxsK(5VD2ymqjzg0SDXq1pcM(JTYDLUYVC8v(LMWYmxVTNbQaJMLwsH9Cz2kYmBpBMBnDMTIMqA8t2UApTFvr6wYJkLPBfDQpcb170DR4antR6ppWM4a97hsq3WH3CN(Za8LKy02DOe3jVaG2DOeTNv1wCScMRlBjVQzgNUpsh1NnHEcx3wgx3vkx3mNR)sq6AMRuxFK6pdJgPCR0Me3t0XMI2Vw33sQQpeSgXzfQwAv(EnpLoEH2kIH2oMH2e1qBSdRwZn0S)2g2AZIu6OEP6Jr6CS6eIvDGm39kBUzXBD7(VHZTRWT8IqZ7Zds6ozVzruTNaFtNeRvQqxWuZqIQzFa8LWAFo7KXxCMQ3TwxNP69zQEZeWzQEN7kot1Blme5ZUKzhrkzjDfZi6mvVT20pt17IxPTm66DjvV19fYi3ofFyNU)FdDMoSLHcnWOX2OuwZyWO8TrXlM)94h8d8pUC43ffJHAeJy3EX)n]]
)
