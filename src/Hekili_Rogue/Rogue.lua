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
    20261120000,
    [[Hekili:T31wtQUns4FlZleO2ZYaZWm5KtDyQAVKSjP2CPYKDZBym2cWlgBklBMmBrXV9TLSSTKSK8fmKzQL8qchFP7VUBPUBj5VtMnE2Vo7zx7y0SF8Ur3944X3nc(Nzph)6o0SN3z7SXEf8Ja7TW)(VfUDHD8X59Fj8fS3w8qNWTdip1R(H2UejTiXZp(7cMTqPqX7qoZE(x(P)X)6R)KdvwZEETNRlk9fqyhn64thNhVgDCo7A3UmmcThfDCUlAPDIp84)LF(FECoC5JZZfqI3TefIVnkCvc6w3D4BT35JVL9odH)WW)domyWhaPhzhG9be7c)oKOnp8X52UUHbFb8JnOxXdpo)VBhB)jfOO)p8D)kiK1XX7WF62Bx5fVozbb43k9OdazcqZEXOLJgHMS05J3dI93c)TJZ)MmH5d)hFVGvWJfaOjimiY2d(XpV)RpoFxKxyKxShctSwF)Wxoo)7CE948)nYlady4fq3ezyhfGC)ZG977Ze0li7DHbWRz77VaIRed6xjovCco22lGy6PAY1Ele0Zv2RzQcZIc78cOpnG7NbJ74Csu3fe3ph6HjQicT1lWffHzQgz7aGAn8BIZCxeAjkcf4GixBpIkvpWYdFbE3FHeSaqHIJbNabKphJS9jwfjKGtwTcHPXjA0omj2nK8JDj((4m73(48eS9cFqqH7qbOOHWO0OWLE(WOyBNyVWa8qahPdcN(INVVvCOfojAV3E0h8woLoMXA3EKLtyqm63J7Ddofhi3HGhSx6dGJtO(IVVKq)ttVLk2WLwW7ybGfBVbf0azN9k0Nkk0xTsGjn27qw2rXE44gi9TH7rBrbXzsV3IKLlhkiTHUKiIsTIJddqaa3wln2NkBxp6WrsyXAhDKYWKDhkDl43iBmcU3GumLRlt4zTDCmkYYjjcxV4xj9sFvqRmLYlqdkoYENNRveAfzuMn5(FibJGO(sRvoUth)bIk8TF1AbcMbn9XrfGZXoWIijywFQollltkgz7A5JE1cYvGK0YhPAjoC1kFa7WSTammSg3tJEjQBL3)fCm6vhKDj2ggTKg4KSrWbI8N(dqsKJZ)wywor7SPwJ6DtQwjZdHj0wGBfs(0Ri(eBhTcf3Bl82wKuedXauEAuk0YVQfKVa(VPJjZEBkwSipZ0XQHTl4L8F9nlQVRTO(NwUS9GMiSsyo7IgGm8i6qCngECPGC)syE8HYMrV8cm5sj92t)c7K4WVyGU8E0CisgiVbXSN0YswPvFYsO7H8DTsRUkNoI8(HeieedT8Keb1hJ)8KE97NIIHoRHY3w41HXd3euezO1FiPV61)gnp5bxe1BXDDIFAqXBSXZnasKu(v4Vb7DWH(Hhsdkd9WSWdjYrs)an4m4qoKT3UibVMjr21OnEeBVi9Qd4M)4Adf2Z8ulqRHgiazXETv2rrHXibt3njIA4P)j2t0JH8SxGIAnXYf(2UqqXhC2VwKvoVBOSbH(2Kk8wK(lYgTsdKQfk87TixVyvLcobD0HTOCgBm5s2oYBJMqUWTECHB44I0Mr9QE8hAz6X8GT6IZ)HI17AgwVuvLlxbUHdaUuaTRBF4AtdV3BAaIGB8C2ueWEAu5ryPxafScctzL13I8r5c3XgtmzswEPOO0dS)UPJe1DU)S7GG8ab5ALnECHMGp)4fNnmz4eg6tUz61GgMG4j(PPsOKD9dLDpJhOCK)tI5uwtniADBJviVFKz3QORrwd0rXHvwgEsRvsrtosf2FqJeZA6GnG3oGmdrvhi6BPbT3gBO91sJ5uReYS(I4)Q1H4yOweooYBdBszAFxs3HoEQA0OYB0i4DtxHVLiyuyBNAMIcLTeV2B1AOfDOdSy5zWL6sZBhGr5X5ldDsWPboAVxVo0p8PPm7L9kdDG)n4f4k2CqvHN0RfHWOiWSitCLaTGlPi9qryrQgTMAxVrRqXBCSYe8UxLwyF1M4bvxE6KE3eB7d)AOxGxSh0m(Ee0XmXh4oOPfV4rBAb1lbinwwMhsz1ZB2yJhQVcq79WoKv0GAKkEA6eEPSnj2Z3KmyZJzpMgulwWyByu0AycvJWLOqWGVhtwFyA(OtqsKovzpT2DQaMjeZEgHqOFyOR1YKOx19Mnm9rV8KNSN1law6VTdzNuGuM9fMbCGldkKvfT1db9pC3H8MYZQd6fKeMGTsL9GECzbNWweqHHuAMZceS(7OnGaFVBJ5gs5k9(jbimS4(vRJFNBL8Msz7mjcTX(DQf(vzwi1ikzBARh1AZsWa6POjiRaOdZI1ryOuuhwGrrvTUZKnzKgR7CMmqmOVnDGDXsJtKgieOYXAuKyICvBc(jQo5b7croxWrqw3eirHgtATozZuw795PpmQO9pSVNdYISZmUWp4BOx6oK94TVMzPcZeedqccPdhj2nPpuzOSvu)5PJRZ6NJs2fdjC6qltmTclzbtns7wqJcEkNPj0PJtiGyAP(oVeGALxyjf9IYSIYlfJ7riRgBqvTY2gSA2)0vzBK3Nv(SprHHBRrtPLxCqtrJ501S0V7scCGXDK(LFjmjWfNLfUgquBh4nfPvRkf12vxV5HE3iv9LmZG5)ZpUrgMwtMoKTCbgK416EBsHIYtv6xSBj87T6bvQwZJwE0F29Pd91T0VyVTONiB8NKfXJ6DrOD2SJeJa2maKAnzqnFZhzxMCaxVAuUMwRtUs4RJYuvFT3kBPhCxhCzTheMqrU9kCpMvN)A5lcITf7grIyhd97Rrk9GaY(HJ5U(GdCiv6H7EJya3GWMktt2VHLf2U6xguwEI5(97ZYCTimm2AtG3sOGoCZNM(WbD3zI27CV27CNI7KVfpkNDo9(IfR85PFCejk)waSIGQCYq5Iv1m5OIgy7ZPQw3cAEdd8RJnDUHUjnDqgdjRrEUH8Tztp0oLx78B(PB53jvAfItHP3xVBPqKc3lxOTjky0JQkY31j)UgpeJhKxSJCoVbSgtJUmVvCqkvJob92HbCso39t032shyl9FTE6PIypBck)D4MIQCWY1qWG0zK1ZtCMT3Mb7tzQxBXl7dBy84jMvVMnNoFWB6((MokSiKMEvQxPxfy0y4kD1iY3cCAv8AvA4YqLSZpe5vLGxsIdwz7wvvQPIylHjxX(ilOrov9bX3624hY3DwxKD8ART2rBY7N8GYWb3RF3dWZi8NlclCYlnIWwXm31thLQE193Rw58NkqLdYR4ltwxR9gKyb41jaOR(2Uhek2(XILarBzH89Fq(qzZIqzRfO4uwnVWfyHf5BAs2Uqs(6S6lo(B6JdYhwS03(fFegBH(DKtsAar8m6BSDQFFK7BCpCvVZJqYgvgGXbgM2CuLdhpXT30yfRBkFwEv24KWwK2xjKjl8uTTmjB)dYoh)86u6gZOW7QpTbySS7HrremsC12UO89BmFMD2qW0P2sJlZRLCVIz51DOM4XBzAVeZJqIBEN028L7cM0EmX)rwujA4t(vRmIQFOBuwdvZd3xT2vlcDq906G4Zt1wjnTFmzFF6Fo)dtPMHcXVoLRbJwfmk(4Rf)8Jvp15PPFCWHSeesFNHz5h4sO(Lp0(jAko0ICpHyQV8TBIRqAwhFxhs08HeDziRbssx0stmxmNXXVF2Z7rrKV7wP)oCWhGeM(xAeP)1Oa8ZFK(xIeSXRZ(RzmSF2ZsKwB2ZorEG94zp75u1vjTWyKxBwmGctkrImBTqtYKAJOY71OsbAP1cDvxYUrWWenyi)R3Ur63ej4Aml4iW7bDWJNeBncILqHtfSJJaJhLGHWxhoC7rLHqDzd3SN56kMmwp3gl)ceO8LMHYhhXjaEY1XJWwYPoI6)OK6leA6P0xFstDIerdCuuMBn75c(WP3xkYamIH8vVvmK7AKHiq5oIDmEuNziYNyf1ocvsJnbZGszTCRiNjDnXiKtXFrmcvCXRnKXRjME5bIJLR8O7vz5Xu6Cy(M3qm8RneOOkguyMKFAy5xlP5xxXZpAiwxLEYxTt54zZO4tBiaifu6k9Z597ESjpaQ2mdStOgyd5gyJihi1Nk3VIu157hvppQOxrFkbosisvFf9Pm5mOEVCgksrqfTN84dv0IPcq1sghsHJC7k6Segjav3jzny7xni7NE2(rrQC)ikCCTeB1HjIgaxL(mYINKBcj7zOKxSEd60NfP9KyKIn99w0iAl2sElc(aYEUt9CA70pvRu0QBDOf59kpqOouZQjCF8sx7MA4Y1iRWi1XlIwqmIMwuViOWUkxmMyj6kSM2wYf1Ym2KdfS6wHDw7svcxn7du1AwUyvrELSdCPv6(PPtOIxUsuM4Z2dQkfolfKz(xsvLCvMI6Jz7WzLkZG0LRmKx)uC)7obvCVC6BDjQ4O0zz1H5iZjvQYjE1j1IprSYcTHPBl4kqD4oNo2Vuj9xQMPNuhqDxzxX3877zhGinqPoa5C6ABLG7azFh7ckXruQtqUCGwNaDZ9FhA(kiqk1WLlT0zgMGjCMiqAlQ2wrFb3lxWRZ8hM8aTJDPNK1N1NJGXRRCmLccDOVGvlsGrQuaORinp)m6CCipVIIeDf0Lo)VoemnHdRnMeRsSyLyIt0VP0NOL0vPVuzKvtGvUHTcVQ4y9j6xX5jA9Ij(AofxBihx5wHAQoKSZ62FtXNawh6ludzdF6y14BhJAvApwwdRlPnwHc)nr9Apr2oorP8bLWN40azAPyS5lASPW8SWYwk21TSZkxovtnbdyqUyyHQot0VTIwtMu39jnLvRcawZhZxtyTBxtBxQjPRklhpEfSJmOjWN36sOxIgFOURIw96DZbGcYKE6K9LcWtBb5gPqB74qRsuQBhq11OwJijxTyjxNzFvWr4grsyQVPUlOw9ok0YMdubKAxLYiZInWwxd011aFD7a2fBMEXxue3HumMg00v22WcpAe3JpRKpMAbYfVBBgm1FjMvtomT5o0zghohmH9KipATzpk1HRBz7MgY055JVgTAfZLRTd6nHbPC4xD7lv3gixfvsnWQwZ0mTsEMwTZVTE426Gv7HBXMr1yApFs8E()Rcr1G9ZxmJUHqx1ORhR7sI0p)T1gJb2rtHwDxmu5JLP7ioDBzo95J60NBUttD91DFd5ixT0skQpTQRfVQRpXQBmZQRfrL04NQ7Q9e4EnVNs3sEuPmDRORWsRsYnKo2uTQ)mcRIo2VF4JDfBJ(J6pxWZjhTR3zz8O8caA2E83CcExJDP3CD5AsXBQXP7mbvVv)65(Dtj)9fJ93Nz6FtDI66Gu8aPRCuHEEH3vedNG2Vu3xQQQplSkXPanpRvMEnpLooP2isP2mwPwfTuRS3QgZl10)CD4nonsPJ2NQ)Q6UgRoHyvlOvEv8k)uiwon8R7yamCoD5EPZcJZVoMP98oNgr1DW6vEYR1sf6cMAgsiMmcWxmTp60JhF2vwN3yDDL15xzDovaxzDEMR4kRZRHHiFiMu7iujHTfmJWRSoV2M(vwNN)kDlZ1ExY6CZFXZYRxt7)3JNQJ6sUbTBrzZvkTvnyoW6WOzp)TOnE(EhN3)BcJq7t5sy8Sz)Vd]]
)
spec:RegisterPack(
    "Assassination (wowsims.com)",
    20261120000,
    [[Hekili:T31wZnUTv4Fl(ffPPBLLSLD2SZkpt60KMKP5YeN28MOGeHKyffPgcs54oA0V9EaiijiiaiifTJ9uLhs0YlNZ35cW5aa(Tz24z)2ShDrX4z)0nJU5(XJVze8pZEm(594zpUhTClAn8Ja0o4F)1ecIq8cqXEHbNM3)PWNiE7idxgUBa9HF2pe5sf4Iep)4Vpy2cLYMShVC2J)6p)p(xFZNqIIC2JB8CDXPVhMS0Sg)0P5XBWNMZV21RcJWhWrNM7IxHs8Jpn)R)L)5P5WLHFjjNeVRPOGCDu46e81U7jxJ27tUM)QdH)WW)djmyWhaLeHci(Gz4c)oKQupYP5ix3WGVa(Xw8ZKHNM)3rXOpPam9)XV)3aHSjoEp5txF9AV4njlO4)APhDaitaZOfJwnAeEYQLF8wqS)E4VFA(3MjmF4)47fSgESaanbHbrip4h)YHV5089rEHrEXEyc1O99dF608VF5ZNM)VXEbeadpb6Mkduua29Vc2VVpxqpHr7P(LviF)fqmNAq)g13ssiXiVaQPNQjx0oiHixzpNPkcpyS3lG90aUFemUtZPPcUG4(Lqpcvfr4DEbU4icx1y0sauBGFtDM7JWRWr4GLy61oGzs1dS8WNG39xPblau44yWjqb5JXyKp1QOHesY61ycloXc6HjXUH0FSpX3NKz)OtZtiOf(GGc3JdWrdHu3OWvE(qgoAjnbHmeWbeIwGIN(KNVVtCOdjj6G3b8h8wnLLZ4S)a2zzyqm(pI7Dfjfhy3HGhSx6dqIty(IFOIq)ltVMj2WvoW74aGLG2IdAGSZEf2tff6RwjWqi0ESdkk2Je3aPVl8aEhoiot69wKSA1WssBOlnIOuRK4WamaWDwPX(mz76XshPHfN9SmLHj7pw5wWVXicgU3GumLRlt4zdkogh5SmjIyx8RIEzVkOvUsffObfhH2756eHxtZYyZ88HecgI6RCwV0D64pqvHp6zNfyye007hvaULOahQKGr9P6SQSmPymY1Xh)SdmxbwslFKPL4W1R9bSdJ2ciqAnPNg9sv3AV)l4y0Roy2LyeKTKg4KSrWbI9N(JWKiNM)DWOCQ25dTg17QuTshhcdODa3km5tVI4tmkAnoU3o4TDOtrmKaq5HrPql)QoW8fW)nnNm7TzyXH(mthRg2UGxY)53SO(M2I6FE1Q2dAQWQG5SlAaYWJOdXwKE8Ab5(vW84JvnJE5fyYLs6TN(fOK4WVyGU59yZHizGIge3Esll5Kw9jBcDpSVRtA1v5PJOVFifcbXqNpjrq9X4ppPx)(POy4Ynq5BhYMW4HBdkImS6p0PV61)knp5rxmZBjCDQFAqXBS1ZnaMiP6RiEd(7qc9dpMgug6r4HhAKJo9d0GZGJ5qgTBrczdxI8RXA8igTi9Qdeg)4IGc7zEQf4nqdeGS4V2AuuuymUKP7MeXm80)e)j6XrE2lWqTMy5cFKleu8bN9ZfZkN3nuwsOpIwH3H2Frw2klqQwOWV3HD9Ivvk4m0rh2IYlyJjVMTJ82OjKx5wpELB44vPnd7QE8NAz6XIGT(IZ)PI1BAgwFTQkxTcCdtaETaAx3(WLMgEV30aeb36TCBra7HrvZWsVaoyneMYkRVd7JZf(seHAY0z5LIIspWHBMoQSUZ9NDheKteKRv248cnbFX8LLB5YyzyOp9MPxdAycINKhMkHs(1pw19mEGYm)hkpNYgMbXQBBSc5TJm7wl7AK1alloS2YWtATskAYrQW(DAKywth8eEuaDeIQoq03sd(aIyO91k5CQvcDuFr8F9MqsmulIeh5TLpOmTVlP7WYNQhnQ8gncEx1v4BfgYcB7qZuuOSL4nER3aTOdDGflpcwoGvmCSWnivtutTI3Oveeno(0YFyv4YeIyEOKf2xTjEu1LNoP3vXiF4xd9c8I9GMFpGHouP(a3bnTyHiAtlG9AasJLbfHuw9ZMLBCN9kaFWJSKUccCJuXdtNikLDjXE(MKbFCd)X0G6YtqVlmkAdmORr4QSqiGVNqxpw64)Zqs0od5pT2DgagjeZFMsHq)WqxNvjrpR7nl3Ny61IWeCemleToRQEhztwXFwVayP2OL0DUaMIQFPrahfMXcMfdVZdd1RV5yEtWz1D8csctioPYEqp2k(EEOFieP5nDxyivg5SadR3nAliW372yUHuTYQFsaMalME9M435wPOPu1otIWBrVtTWVkZczgrfBtB9OwBwLmGEkA6Wja6OROVDdLI6WcmkQQ1DMSjJ0yDNxidKa6BBhyx8PXPsdecu5ydoQKE89wIDO7xGl8Jo0H2nJcsxyqjmMTqSppDSnl7kkzFmmUPdTSYJo458C1iTitjKl0eV0DO7RRYeMsfSxcRt1HvXQZNjtTYlSKIwQ4wHW8tvFKLW4Ob11rwtXQYbAtVll1YuBytN8Im4sEB8ehSffgUZIEWQ2KztrJfMFzvwT97MQsZtiEvJrK2wABkWAUQvu8u9e6317kPYB0XS8iE(5NXbWg6a1S(X5quuRhq0zIRoiUFXY)f3SWJQuTMhT64YS7ZguQBTvXE7Wpq3jljlse17JW7r8Z4Hc2maKAnzqnF304xMEInpBuUMwmrUsepDuUQ6R9wz92lCDWL1Eqycf52BP7XT68xlFvg89m2iskFoW97Rrk9GaYHHJfU(GJciv6H7EJyGqsytLPj73W6UAxLvdklVuq)(95DMTimm2zBG3kOvd4MpaLy0DNjAVZTAVZnkUt(EOOC050BlwnWNN(Xr0O8BbWwguvNmuU8OLtoICbRMUt2WC98TUQVGQUBul7VkVvgXfkMo2q3GMoygdjRrESH8T5dp0oKx74BXHB53jvAfItHP3xVBPqKLUxUqBtuWOhvvKVRN87s8OC8G(IDKZ5nG1yk7Y8EDbtPA0jO3omGt6bjFM(2w6aBP)R1dpve75dqfVJWquLjlxcbdshrANN4f2EBgSpNHETfV8tQF84jMvVMD)np5nDJvtZclcPPxL5v6vdgngUsxnI8TaNwnVwTgUmuP7jfvE1j4v04Gt2(OvNAQj2sPMuSp2bAKtvFqITUn(U8T)0fJI34SdfTnVFYJkdhcV(n3bptP)CryrqEPre(kMfUEAwQ6v3FRALlUT71MKxZNARUw7niXcWRtaqx9TDpiuSXOflbI1Yc9dAG(LFMfHYwlqXXyAEHlWclY30KS9hL(5g1VC(307hKNwSYh9KpMqCW)bEzsAaP8HG3y7u)oC334UlREprHjBuzagtmmTTTA2uZZAJxnwX6QQhwwTnovAZB7ReY0fEQ2wMKT)bz7kxEDkD5mk8U6N2amw(9i4ikgPUAKlMKN1MnYolfmDOTuEzETKBvmk32uTYNFKP9smpcvEZ7K2MVCxWK2JjXnyUw0io5NvZiQ(HUsznunpCF1AxTi0b1ZRdIppvBL00(XK99sBZSLHIYF(hxcgTkyu81ex(7Pv9qNhM(XbhZMGq6dNlB(bHju)Y7A)anfhIrUNO8uF5B3KqH0So(UKs08uIUmK1ajPlAPjMxEoJt)WShpGJOFiPs)nvGpajc7VHes)7fa4N)e7VXe45RZ(BzugF2JsSWA2JlJ8a7Xdn7Xu1vlpN4SXAwmGctkrIDwTqtYS0IQYB1OYs8SQf6Yw2BrXWenyi)ZrUr63eRUAmTUOW7oDWtKvwncIvqXYAO7ffg3lbJsFUZWThvfc2sVRzpk0vmnxp3gR(cuO8LMHYhhjiar2IjIWwssmQ6)OK6leA63fG9Sa6mzwf4OyurA2Jfe8sVVSmLMOgYx9wXqUPrgsjoKrTJXJ6mdPb8YQKzW4GvUvKtnSMyeYtX)QyeQixwByxwtm9QjIJLR8O7v5ZJP05W9nVHOSwByOqDuuWmR10qBTwYBTUI4ASqSUk90VINQXZMXzL2WOngO0v6xW739ytobYAQU1jCDRHKDRrSDJ5tL7xrQ68TJSZJw2ROFkbbw1XuFn9Pm5fq9E5uUJHGAAp5(7QPftfGQLuOJbh52v0zjCwTPUtslOVMfSxtp91yivUFefoUwInBOwNbWvRpJU4j5MqYEggB8SlPt)SiTNvEmSPB5JfZKu11AdBIAcD9ETRgYmC5glQXi19P83IVL)MwMSiOWVkK5qpPcA(g1s0v)mTq)RQLzSTbgy1vxnRbKAHRMDwPEnRB1YfhHrR09dtNWeVC1LmXNTRo1kC(GAZFFYmvjxgPOIt2EgwRYmiD5Qc5vKkVJyNJkKNox3KOcSqSQ6ic8pKTHrYtZQtQfF0vvfAt)QYZNX2g6EPJPl1s1L6jNiZbipxUwhq(xr77zhqzMlYCa2UyrXJ48DSlOcTgzob5YbADcSTl)DO5RGZJmdxU0sNzyLmHxiop2IQT10xWTYf86m)Hjpq7ie5zz9z95uY41voM9r93H(cETOsKOKba5I0DMg7QruPRkSP8NuWtw6vLC)63j8Z06lpwS5mSSHuSSWC56qYoTTtMIVZNo0xOgYg((GS4deIAvt0TGvtTk3uRqhLnTKZMmCQBXRD9GC5TnxCqVbYCYWOUJov)6cAkmTWHXXIUvkQFXxnflDb9pzqv7rVw3QqAkIBaM0xq9fIxO1uHFICroDZ(Ks3YsawZxzwtOtAxZNuMjPBTTcemTKDKbTsen1wMMY0OT7cQ6LnMdafSC88zHkdG2wJrdanIqbMizp5ovHY70vZquWLXLgXRI9wwrFRoZ(QH8QnI9QmFZ5TW8w2qJkGORyuLcMgP8QbAKAGhPgisAhq7vZ8E9vfXDi3xzbnT7VB5ViUsHVMqk2xuwXYSa5I5TDgm1FIG1ZAjTZDOZmo(sqrZZIvJwtRrMdx3EDBkLPZNp(s0QvuQ1Ah0Bcdsz6NT9LQBFyRJJJgO7Pz(pwlbiR353wpCBDWQ9W6At2Mb42Yh3ZIqU)FviYcA5(Qz0ne6kZUSDjr6h)2AJXaTDzqZ2fdv90n6og92wk9(YXP3xAs9sD93B75RkW6xPLuypFFTIWV2Z43gt5xRyqJg)KTR2RePGf9u6wYJkLPBfDfwADsUH8eMPv5LKigLnZt43pefUMT()E9h34lj5HT78xUxEban7CjAoZJT4Kfmxx2sUhZmoDNTN6JNqpPKBkRKF1OL8lmVKzorDDqw(CDRnRqpHL7kglZqRUpkjvNIsT4Se)dTAMEnpLoYs2i2s2m6swhFjRT3QgtysPZhPUiLCdAzrk1FCAxIvNrSQf8DUocpFomEMg()sDhdGHZTl3l9Iqf6l5mTNq0SiQ2dzVUtI1kvOlyQjLO8Kra(Iz9rNEs9ZUqh6gRRl0H(cDOzc4cDOZCfxOdTfgI8HyYSJqLmjUKzeEHo0wB6xOdD(R0Tea7DjDO19H0i3SfpPu3)F6MPdBpqETBrzZvkRvnymWMWOzp(D4TE(ENM3)BdJWhsPKx8Sz)Vp]]
)
spec:RegisterPack(
    "Subtlety (wowsims.com)",
    20261120000,
    [[Hekili:T312YnUns7NfFJIuTZklzl7mzQrUQDR)Knj1Mdvu2)CNOGeHK4AksveGYXBPsp7BdqWtGaGGu0ESRv5Ien8q3FD3aD3aGFtMpE(VpFMlIIN)Z3m6M7hp(MrW)mFg95945Z2Jw9iAd8Ja0o4FplEj1htF(0I(pf(eXBhz4QWDdyp3Z(HixMSwg75t)HG5lvkwYE8Q5Z(TF5F8V(2presB(STEUU4KxbtwPvpF60c6w8PfIRD96Wi8bC0PfU41OyF6Pf)TF9FEAbC5tlkiIyVRzQLCDu4My81U7jxJ27tUw8wdH)WW)njmyWha5hHci(aUDHFhY0Nh50cKRByWxb)4r8ZKHNw8)HOOpPah9)PF43bHSLs3t(01xVXJUnEjd6xl9OdazcWfTC06rJWtwV6J3cI9pc)Jtl(UuH5d)hFVGnWJfaOjimic5b)4xp8TNwSpYlmYJ6Hjm713p8Ptl(HvG1()J9ciagEc0ntgOOaS7FfSFFFHGEcJ2hgaVgY3FjeFzg0VZCRKycf5fWm9en5I2bb)mL9CQQiI4WEVa(td4EgyCNwWI9UG4(1qpctfr4DEbU4iIq1y0kauBHFZCM7JWRXr4Gvy21oG5s1dS8WNG393yblauykfCcmqoJIr(mRIfsiXB2Gj84epEhgtDdz)yFSVpj1(rNwetql9bbfUhhGJgcJvJcx75dJMrROEHbKHaoGq0seD6tE((o0qhsC0bVd4p4TEkFmJZ(dyNvHbu8Fs7Dfjbhy3HGhSxYdqOXCFXpwrO)LPxZfB4Ah4DCaWsqpIdAGStFf(tff6RwjWeh0ESdkI6rOnq67cpG3HdOPsV3Y41RhwsAdDzreLALqddWaa3zLg7ZLTRhF4ilS4SNpszy8(JvUf8BmIGH7nibtz6YeE2IOuCKZQ4iIDXVk6L)QGwfkTOanO4i0EpxNi8g2Ome7(FiMGHO(ANnRCNo(dmv4JE2zjgMbn9(r5GBfkWHjjywFIoRkltkgJCD8Xp7a5kWsA5JCTqd3SXhWomBlGadRj90OxM6249FahJE1bzxOiy0ssGtYgbhi2F6pbjroT47Hz5mTlMAnQ3vjALnpeMq7aUvi5tV84dffTbt7TdEBhwkIHeakpmkbAzx1bYxa)3KXKPVnhloSNz6y1W2f8s(p)Mf130wu)lRx3EqZewfmNErdqgEeDi2IHhVwqUFfmp(yvZOxwbMmPKC7PFfkMg(vd0L3JNdrYalAqc7jPSKts1N0e6EyFxNKQRYPJyVFidcbuOPN4iO(i9Zt61VFckgUAlu(2HSnKo8XG8idV(dl9vV(xP5jp6I5ERcxN5NgK)gp65gajsQ(kfVrY7qc9dhCmdvODlJjBfVK4A8ElOOLjxDqHPiUiO2DQZyjEl0JailXRTbfffsXLSo34iUTL8Neprpb4sFboW0eUw6JCb)Up4pFopXBwdpPJZ8rSI4oSwishqYJvQfk87DyxpQQS9NHo6WUqEb7941SJJ3g9z8k3DXRCpfVkDsyxbIVOvIhxeS1x)9lkwVPzy91QWB1ISnCaWRfq76oeU0xW7G(cGG0JEREmpM8WOQdIsUaoydejsRCVd7JZe(keHnMGLixkqj9ahUz6OY6oZL1DqqowlxoSXHEnX3Idjw9OqgRcd9z3m5Aqprq8K8WujukU(XQUNXduo4(HYPn2YniEPzJfbVDKz3AzxJSgyjw2hwBL2jTwj59Xiv7(onsmTVcXaEuaBgIQMm031c(aIyOd1kJ5uRe2m784)MTHekuUHqJ8EumPmP1kP7WhpvpAu5nAe8UQRW3AmmkSTtntqHYUE36Tzl0fo0KfvEgSCaZQfwivhuz9HYtHssg)H1HRIjgKuF1LAoQ6YtN07kkYh(1qVapQhG4dyO7pwwi3AsTxeA5jGAMbo5lyzUI4xuR51032WkGfrBAf4M5RVZ(Wj(GhzfBzg4gPIhMoPOu2ft98njdXmpXJPb1LtXVlmkAlmTTr4QSqiq0GWw0wsgKZqsS2hfpT2Tpas5qfptPqOFyORZ64ON19MLBMm5ArycocYJXQuRQbtE6oXZ6faRhhTILfcsY1V0WTJfY5b5bX78Wqf)BoM1PCALlVG4WyItISh0JVSWNh6hcrArN55gs1HPyyrXrpcc89UnMzivRn7hhGjWkU3SL(o3klAkvTZ4i8JO3Pw43KAHCJOITPn5FRnRY52v02Ita0tyEN)gY73HLCSPxIwBYMmsJ1DEHmqcOVh7a7sKgNjnqiqLJT4OsB6w8EkmSQd9KLh8i6TjVYNyb0IHkc1NmurPh7oPnzIU1zhkQ7CnPavaOCnylMi(ERWoSTLXf(rh6i7I8ihVstaiDVMlb(0vj)5PJTznXRGfE7WlG25jwv72Z7voVdprRYfsxw9rwbtRhuxdITbR1mYOJMdlVLIfNthfgUZIw9kNzRdWKAvQpnA5TVrSi8IRlo9svwqSQMMBdSBzx1nvv6MWzbguuixDXL76DLuPw2HhjgwKDGFcWULnlnDTbcSwuRhqSQcvNb3pFZmkU1NhvPAnpA1jLP3NpJu3GiQ3o8dS9LtYIK2JI9iXHsXaBkasSMuOMT3GIlZoIPNnkxtlSjtjfpoxHQ6R9wPRZOW1bxw7bHjuKzVLUNWQZETSv8iQeyejLp46(91iLEqa5WWXfU(GJfqQ0d39gXGcdcBQmnz)gwdyM(KkIwiPM0Dumlvz9I(97l6sCzyi15XaV1qTz4Mpm9UJ6UZeT35wT35gf3jBhEuo7C6T5Rm5Zt)4iwu(TayldQQjdLRHAzYrKly1S9Lhs6ZwWbl4uqv3nQx7gfKviS4IwtMBOBsthKXqYAKNBiFBX0dTt51o)U40TS7KiTCXPW07R3TKlYs3ltOTjky0JQkY31j)UepkhpyVyh5CEdynMgDzEF3GuQgDc6Tdd4KDS4NPVTLoWw6)A90tfXEXe0I3PWuuLdwUecgKmJ0opXlS92myFot9AlEfF3bJhpXS61St0zdEt2K3KrH5H0KRY9k9QbJgdxjRgr(wGtRMxRwdxgQSTTIjV6e8AwCWjDJNQtn1eBz0LI6JDGg5u1huXw3gFx2wXwyp)s7N8OYWrHx)M7GNP0FopSuqEjrKQ7TyYOu1RU)w1kV4rau7G8AocFDT2BqIL36v17o4K2Uhek2f68LaXBzH95zW(uvtJqPRfOW2SyCHlWclY20K0nDM9Xt1V84VP3piByXAF0t(ycXb)N4vXjbKYN(DJTt97vCFJBhR69Bds2OYamoWW0E2QC44zURRgRyDv1dUR2gNkTZT9vcz2cpvBlts3)G0dTpRoLUXmk8U6tBagR4EeCedJmxnYftYg1MoZoDiyYuBPXLz1sUvXSCBhQvDhF1TxIzrOYBEN028L5cM0Emv8lQOw0um5Nvzev)qxPSgQMhUVATRwe6G651bXNNQTsAs)yY((K)C2xHILHIY7Q(LGrRcg5F(ZL)6Gvp15HPFCWX0eesFgGP5hkKq9RVR9t0uCAgzEIYP(A65vCzirtNF2(qwdKKUOLMyE5CgN(X5ZoGJyh)M0FDj4dqIW)BOHK)Uka(5pZ)BSbX415)9uASpFMeTXMpBvKhypEO5ZsuxTeZsqFS5uafMuIeDYAHMKPvgtL3QrLLigwl0LT0nJHHjAWq2hxDJ0VjAO1yEOXG3D6GxrAK1iiwbfRQHFAmyCVemk9XBd3EuviylF0MpRqxXSX6z2y1xGbLV2mu(4OccOi92kIWwYQnM6)OK6ZfAYb1BpTLotQGboko3PMplNrA69LL5GfZq(M3kgYnnYqkr6nMDmEuNziYNyf3ocvsKSsMbN0yzwrgx2AIriNI)vXiuXgU2qhUMy6vhiowUYJUxvKhtPZr4BEdXXU2W(G6yzNgA21sE21veTJhe1vlN9b7unI1mo20gg4XbLUI7f8VDp2KhIyn186eU51qY51i25X9PYDKiv)92r25rl7v0pPVala5QVMorM8cOEVmkcYrqnnGC)D10ePcq1sk)XHJCdj6SeXx7N6EfTGUDwW2o90TJJu5oou44Aj2SHkGgaxT(m2YJKBZi9z4Sh0UbD6ZI0EweYXMC3d6SNsNrrvVTn0zkjlWnY1SRru6(I9BXNSV5QA52Asfsi(W2XFMxGbBDvPYt5wRPOPLHVKngWnn5ADVIrKg2XqUBxCvPGKU18M2EtT2MMDMX8ahMMLlUKNhi9iqALUFy6eU4LRCKk(0DfQwHlszyM(JCvjxviVEw6EowRYmiD5m5z17kVJANHkUvoDRUuAfyuzv1vKlLCPABIY8pARQcTPFE6z1dSH6A64CstiVMgIwYDa2UwR8Vc33ZoGYSWK7aKRaOT0FHJi9DSlOcfn5ob5AfADc8TB)DO5RG)MCdxU0sNzyLlbQOvZoG)MTO0CnLAVvUGxN5pm5bAh5oplRxvZG3QRCmNuaDOVqulQeHq5aq)Ej3jAS7ieAUVr8WsEsD9dK)9A8IzCnIePmWor)(fFMaRBYJDSZjqAHr2LE1YbXj22Bu(3Zuh67uhVm8DqzXhcf3Q0DSMMAPVnwHMbB6wWzxNJrEx)lMZXaHv5yu3UKwo9Dhcw1yPDmzvbvw5gLUfrAAbqTXG04t1TsYAxHutXqd)ys4GtUWxogEHi)AnTHmX29WmHtPLaSMpLUMWz2UM0SCtsxjXcSOTKDKcTsSP1w60Y04D2UIz1RTndakOY55t1woaTTaJgaAeHfOBL9myvjk1vWOOGlJlnIxff1SIJADM9vddDBefD5(gBx8S6DpidlkzwIT03LdeTF1oYLvnYRxdCL1azznWw2oGBVMj37RkI7qc(YdA6kjl9z)vk81eM)(Is9xUfixvVTzWu)Dqwp1S0M7qNzC8LGhQNf1nTM7MChUULOBAitNNp(s0Qv8g2Ah0Bcds5WpB7lv3MfxhronWPvZK8SwwEwVZVTE426Gv7H11MSntWTL0XNfRJ)FQqKfCp(vZOBi0vn66EBxsK(5VT2ymWnzo0SDXqvpcMUJ2YTL3YVCex(LM5YCxVTNbAbQnlTKc7j1SvSA2EAn3yEnBfnH04NSD1EA)QI0TKhvkt3k6uFecQ3P7grgAUw1FEG1rg63pSHUMdV5E9Nb4ljdPT7qjUxEban7qjAo9QT4yfmxx2scwZnoDFKoQpBc9mVUPuV(vJ71VWKVM7e11bP(tVOwQ3kT9WDeTSzO9R19vKQ6taRwCwIKLwLPxZtPJrOnIsOnJtO1rk0A7TQXScn5pBdRT5rkDKUu9biDjwDgXQwqQ76y195qRBE4x3Xay4a8Y8sVi89(YyM2Z6BEev7rXx3rYALk0fm1mKOCYiaFuEF0jhr(8lC(UX66cNVVW5BUaUW57uxXfoFBHHiFiMC7iujDPlzgHx48T1M(foFN9knLAxVl58TUpvg52Ped709)F056WwQkud1gBIs5nJbJY3ggnF23JF0Z370I(FxyegQrmGF75)3d]]
)
