-- Hekili_Warrior/Warrior.lua
-- The Forever Warrior (Arms, Fury and Protection, one spec a talent tree: Hekili:NewClass): the Classic Warrior kit
-- with Forever's spell data (ranks, costs, cooldowns, cast times and durations from the Forever DB2 at build
-- 1.60.1.70338, wowdb, a cost of 100 there being 10 rage; the client is 1.60.1.70374, and its export wins where they
-- differ), Forever's Victory Rush and Spearing Strike, rage per hit for both hands, Bloodrage's and Anger Management's
-- rage over time, stances from the belief's Forms source, and the default priorities.
-- Talents: the 52 live nodes (a ForeverProbe export of the client, 1.60.1.70374, 2026-10-15; confirmed by the trait
-- walk of 2026-10-16, docs/research/2026-10-16-warrior-talent-dump.md: no Improved Shield Block, Improved Taunt or
-- Toughness, Defiance max 3, so Shield Block stays 7 s and Taunt 8 s). Only rank 1 of each
-- talent is in the Forever DB2, so a cost modifier is rank 1's value x the rank (Classic's own convention), floored
-- at 0; no cooldown or duration modifier is modelled but Improved Slam's (Slam). The in-game checkpoint compares the
-- costs (Snapshot cost= / read=).
-- Credits: Hekili (registration API and pack format); the abilities, auras and stance swap are ported
-- from Hekili's Classic profile (origin/classic:Classic/Warrior.lua); call shapes from
-- archive/TheWarWithin/WarriorArms.lua; the priorities are translated from wowsims/forever's APLs (MIT,
-- https://github.com/wowsims/forever; tools/wowsims/specs/warrior_*.lua).
-- The one- and two-hander rage rates as in Taco Dog Forever's Warrior pack
-- (src/TacoDogForever_Warrior/Warrior.lua:21-24).

local Facade = Hekili.Client
local C_SpellBook, C_Spell, UnitClassBase = Facade.C_SpellBook, Facade.C_Spell, Facade.UnitClassBase
local CombatLogGetCurrentEventInfo, GetTime = Facade.CombatLogGetCurrentEventInfo, Facade.GetTime
local GetShapeshiftForm, GetShapeshiftFormInfo = Facade.GetShapeshiftForm, Facade.GetShapeshiftFormInfo
local issecretvalue = Facade.issecretvalue
local L = Hekili:GetLocale("Hekili_Warrior")

if UnitClassBase("player") ~= "WARRIOR" then
    return
end

local state = Hekili.State
local IsSpellKnown, IsCurrentSpell, IsSpellUsable =
    C_SpellBook.IsSpellKnown, C_Spell.IsCurrentSpell, C_Spell.IsSpellUsable
local floor, max, min = math.floor, math.max, math.min

-- The class kit and one spec a talent tree (ids the core's: Arms 100011, Fury 100012, Protection 100013; the client's
-- one pseudo-spec, 1491, only keys the legacy profile the core migrates). Icons are the DB2 talent tabs' (wowdb
-- TalentTab.SpellIconID), numeric: Options formats them with %d.
local spec = Hekili:NewClass("WARRIOR", {
    specs = {
        { key = "arms", name = L["Arms"], tree = 1, icon = 132292, role = "attack", package = "Arms (wowsims.com)" },
        { key = "fury", name = L["Fury"], tree = 2, icon = 132347, role = "attack", package = "Fury (wowsims.com)" },
        {
            key = "protection",
            name = L["Protection"],
            tree = 3,
            icon = 134952,
            role = "tank",
            package = "Protection (wowsims.com)",
        },
    },
})
if not spec then
    return
end

-- Rank IDs, lowest first (the DB2's).
local BATTLE_SHOUT = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 }
local REND = { 772, 6546, 6547, 6548, 11572, 11573, 11574 }
local REND_DURATION = { 9, 12, 15, 18, 21, 21, 21 }
local HEROIC_STRIKE = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }
local BLOODTHIRST = { 23881, 23892, 23893, 23894 }
-- Each Charge rank is followed by its Vanguard override. The higher rank still wins if both forms are known.
local CHARGE = { 100, 1240287, 6178, 1240288, 11578, 1240289 }
local CHARGE_RAGE = { 9, 12, 15 }
local CLEAVE = { 845, 7369, 11608, 11609, 20569 }
local DEMORALIZING_SHOUT = { 1160, 6190, 11554, 11555, 11556 }
local EXECUTE = { 5308, 20658, 20660, 20661, 20662 }
local HAMSTRING = { 1715, 7372, 7373 }
local INTERCEPT = { 20252, 20616, 20617 }
local MOCKING_BLOW = { 694, 7400, 7402, 20559, 20560 }
local MORTAL_STRIKE = { 12294, 21551, 21552, 21553 }
local OVERPOWER = { 7384, 7887, 11584, 11585 }
local PUMMEL = { 6552, 6554 }
local REVENGE = { 6572, 6574, 7379, 11600, 11601, 25288 }
local SHIELD_BASH = { 72, 1671, 1672 }
local SHIELD_SLAM = { 23922, 23923, 23924, 23925 }
-- Slam: Forever's rank 1 (1240193), then Improved Slam's replacements of each rank (1310196-1310200, the talent's
-- override effects), so a cast of either is ours.
local SLAM = { 1240193, 1464, 8820, 11604, 11605, 1310196, 1310197, 1310198, 1310199, 1310200 }
local SUNDER_ARMOR = { 7386, 7405, 8380, 11596, 11597 }
local THUNDER_CLAP = { 6343, 8198, 8204, 8205, 11580, 11581 }
local THUNDER_CLAP_DURATION = { 10, 14, 18, 22, 26, 30 }
local VICTORY_RUSH = { 402927 }
local WHIRLWIND = { 1680 }
local TACTICAL_MASTERY = 1310185 -- Forever's level 14 passive: rage kept on a stance swap

local function rest(ids)
    local out = {}
    for i = 2, #ids do
        out[#out + 1] = ids[i]
    end
    return out
end

-- The highest known rank of a rank list, from the belief's spellbook (the plain IsSpellKnown reads it keeps): the
-- same answer in the sim's `state` environment and in a `now` handler's (event-facade spec §12a). An upvalue, as this
-- file's plain helpers run in the file's own environment.
local knownRank = state.knownRank

-- Tactical Mastery is a passive, not an ability: declared so the belief's spellbook knows it.
local TACTICAL_MASTERY_IDS = { TACTICAL_MASTERY }
spec:RegisterAbility("tactical_mastery", { id = TACTICAL_MASTERY, passive = true })

-- Launch tuning caps Improved Tactical Mastery at three ranks. Older replay builds had five.
local function stanceKeep(improvedRank)
    return (knownRank(TACTICAL_MASTERY_IDS) > 0 and 10 or 0) + 5 * min(improvedRank, 3)
end

local function knows(ids)
    return function()
        return knownRank(ids) > 0
    end
end

local function chargeRage()
    return CHARGE_RAGE[floor((knownRank(CHARGE) + 1) / 2)] or 9
end

local function hasMeleeWeapon()
    return weapon.size > 0, "requires a melee weapon"
end

-- A reactive ability's window (Execute, Revenge, Victory Rush) from the plain usability read:
-- usable, or unusable only for lack of rage. The client's answer now, not at the simulated time (as Classic's
-- reset_precast read it).
local function reactive(ids)
    local r = knownRank(ids)
    if r == 0 then
        return false
    end
    local usable, noMana = IsSpellUsable(ids[r])
    return usable == true or noMana == true
end

-- Usable now by the plain read, not merely short of a cost. Overpower needs the 5 s window a dodge opens (1282733,
-- from Offensive State 1282735); the DB2 prices that as a second cost row, 1 point of power type 4, which the window
-- spell energizes: no resource a Warrior sees. Whether the client reads "short" or unusable outside the window is
-- unprobed; `== true` holds either way. reset_precast's fallback when no dodge row timed the window (event-facade §6).
local function usableNow(ids)
    local r = knownRank(ids)
    return r > 0 and IsSpellUsable(ids[r]) == true
end

-- The client's own stance is Battle Stance, by spell (its bar slot is unproved). The belief's buff turns at our press,
-- a moment before the client's form does.
local function clientInBattle()
    local form = GetShapeshiftForm()
    if issecretvalue(form) or form == 0 then
        return false
    end
    local _, _, _, spell = GetShapeshiftFormInfo(form)
    return not issecretvalue(spell) and spell == 2457
end

-- Rage per white swing, as measured on Forever (build 1.60.1; https://github.com/magey/forever-warrior/issues/3 and
-- the warrior compendium v3.1.0, 2026-10-01, https://ppach-warriorcompendium.share.connect.posit.cloud/rage.html):
-- the weapon's unhasted speed x a rate by hand, independent of damage, level and haste: 3.46 main hand with a
-- one-hander, 4.5 with a two-hander, 1.73 off hand. Misses, dodges and parries give none, glancing blows full rage, a
-- white crit doubles the swing's rage, the two-hand rate too (owner ruling W1 2026-11-02, wowsims 7c28cfa731 from
-- Forever combat logs; supersedes the compendium's 3.46 for two-handers; yellow crits none): the swing entries' `crit`. Dual Wield Specialization: the tooltip's +10% off-hand rage a rank (unverified on
-- Forever). Unbridled Wrath: 1 rage a proc (2 with a two-hander) at a measured ~7.5% a rank (36% at 5/5; the tooltip
-- says 60%). The two-hander flag is Hekili's gear scan (main_hand.size from C_Item.GetItemInfo's equip location on
-- PLAYER_EQUIPMENT_CHANGED, and the belief's own read of the same answers; the Forever API data marks neither it nor
-- GetInventoryItemID secret). The helpers below run in the file's environment: the entry functions, which run in the sim's
-- `state` and the belief's context both, read those names and pass them in.
local function wrathRage(rank, twoHand)
    return 0.075 * rank * (twoHand and 2 or 1)
end

-- Rage from damage taken: wowsims/forever's rule (MIT, sim/core/rage.go:11-49 and 91-103; owner ruling 2026-10-25,
-- "stick with wowsims": armor does not change it): 2.5 x (1 - A) x the hit before every mitigation / c, A and c by the
-- attacker's level only (our health, level and armor play no part), x 2 under Berserker Rage
-- (sim/warrior/berserker_rage.go). A blocked hit lands, so it gives the rage of its unblocked amount. The client
-- reports the hit after armor, so the pre-armor amount is rebuilt as post / (1 - armor / (armor + 400 + 85 x attacker
-- level)), the armor the belief's out-of-combat cached armor times the armor buffs it sees on us (ARMOR_BUFFS), the
-- block value the cached one. Defensive Stance's 10% and Shield Wall's reduction stay off: rage is from the hit after
-- the defender's multipliers (owner ruling W2 2026-11-02, wowsims b3784e45b6; supersedes 2026-10-16). Shield
-- Specialization (a 20% chance a rank to gain 5 on a block) and Master of Defense (50% a rank on a dodge or parry with a shield) as their
-- expected values, the band carrying the spread (tooltips read in game 2026-10-16).
local TAKEN_RAGE_FACTOR = 2.5
-- A by the attacker's level: wowsims's measured rows (20% up to 42, 40% from 63), interpolated between two rows.
local ASSUMED_LEVEL = { 42, 44, 46, 50, 63 }
local ASSUMED_REDUCTION = { 0.20, 0.30, 0.36, 0.38, 0.40 }
local BERSERKER_RAGE_TAKEN = 2
local TAKEN_SPREAD = 0.15 -- a stale cached armor or block value, and an unseen armor buff or debuff
-- The armor buffs on us the rebuild multiplies the cached armor by (aura key, multiplier): Inspiration (14893, the
-- priest's talent 14892: 8% a rank, DB2 base points 8; 25% at 3/3, as wowsims's healing model applies it).
-- shortcut: the belief cannot see the priest's rank, so it is taken as 3/3; read the aura's points if a lower rank
-- shows in game.
local ARMOR_BUFFS = { "inspiration" }
local ARMOR_BUFF_MULTIPLIER = { 1.25 }
local PROC_RAGE = 5
local SHIELD_SPECIALIZATION_CHANCE, MASTER_OF_DEFENSE_CHANCE = 0.2, 0.5 -- a rank
local unblockedAvg, UNBLOCKED_WEIGHT = 0, 0.2 -- an EMA of the unblocked post-armor amounts (a full block's estimate)
-- Each fight learns its own mobs' hits: a full block before the fight's first unblocked hit estimates 0.
spec:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    unblockedAvg = 0
end)

-- wowsims's A at an attacker's level (damageTakenRageArmorReduction).
local function assumedReduction(level)
    local n = #ASSUMED_LEVEL
    for i = 1, n do
        if level <= ASSUMED_LEVEL[i] then
            if i == 1 then
                return ASSUMED_REDUCTION[1]
            end
            local lo, a = ASSUMED_LEVEL[i - 1], ASSUMED_REDUCTION[i - 1]
            return a + (ASSUMED_REDUCTION[i] - a) * (level - lo) / (ASSUMED_LEVEL[i] - lo)
        end
    end
    return ASSUMED_REDUCTION[n]
end

-- The rage of a post-armor amount `post` from an attacker of level `attacker` (`own`: the player's), divided back by `reduced` (the percentage
-- reductions' product), with `armor` the cached armor x its buffs. Allocates nothing.
local function rageTaken(post, attacker, own, reduced, armor)
    local level = attacker > 0 and attacker or own -- the source's 0: unreadable; ours keeps the rage near right
    local mitigated = armor / (armor + 400 + 85 * level) -- below 1: 400 + 85 x level > 0
    local conversion = 0.0091107836 * level * level + 3.225598133 * level + 4.2652911 -- wowsims's rageConversion: > 4
    return post / (1 - mitigated) / reduced * TAKEN_RAGE_FACTOR * (1 - assumedReduction(level)) / conversion
end

-- A proc's expected rage at chance p and its half-width (none for a certain proc).
local function proc(p)
    if p >= 1 then
        return PROC_RAGE, 0
    end
    return p * PROC_RAGE, max(p, 1 - p) * PROC_RAGE
end

spec:RegisterResource(
    Enum.PowerType.Rage,
    {
        mainhand = {
            swing = "mainhand",

            last = function()
                local swing = state.swings.mainhand
                local t = state.query_time
                if state.mainhand_speed == 0 then
                    return 0
                end
                return swing + floor((t - swing) / state.mainhand_speed) * state.mainhand_speed
            end,

            interval = "mainhand_speed",

            stop = function()
                return state.swings.mainhand == 0
            end,
            value = function()
                local speed, twoHand = swingBase(1), weapon.size == 2 -- speed 0: no plain base read yet
                speed = speed > 0 and speed or mainhand_speed
                return (twoHand and 4.5 or 3.46) * speed + wrathRage(talent.unbridled_wrath.rank, twoHand)
            end,
            crit = function()
                local speed = swingBase(1)
                return (weapon.size == 2 and 4.5 or 3.46) * (speed > 0 and speed or mainhand_speed)
            end,
            -- The belief's rage from a hit on us (kind: "WOUND", "BLOCKED", "BLOCK", "DODGE", "PARRY", "MISS"): the
            -- expected gain and its half-width. Run in the belief's `now` context: `buff`, `talent` and `stat` read the belief
            -- at the hit; the helpers it calls get those values as arguments (their own environment is the file's).
            taken = function(kind, amount, attacker)
                local reduced = 1
                if buff.berserker_rage.up then
                    reduced = reduced / BERSERKER_RAGE_TAKEN -- divides the rage back up: x 2
                end
                local armorScale = 1
                for i = 1, #ARMOR_BUFFS do
                    if buff[ARMOR_BUFFS[i]].up then
                        armorScale = armorScale * ARMOR_BUFF_MULTIPLIER[i]
                    end
                end
                local _, armor = stat("UnitArmor")
                armor = armor * armorScale
                local gain, width = 0, 0
                if kind == "WOUND" or kind == "BLOCKED" then
                    local post = amount
                    if kind == "BLOCKED" then
                        post = post + stat("GetShieldBlock") -- the unblocked amount
                    end
                    unblockedAvg = unblockedAvg + UNBLOCKED_WEIGHT * (post - unblockedAvg)
                    gain = rageTaken(post, attacker, level, reduced, armor)
                    width = TAKEN_SPREAD * gain
                elseif kind == "BLOCK" then
                    gain = rageTaken(min(stat("GetShieldBlock"), unblockedAvg), attacker, level, reduced, armor)
                    width = gain
                end
                local rank = talent.shield_specialization.rank
                if (kind == "BLOCK" or kind == "BLOCKED") and rank > 0 then
                    local g, w = proc(SHIELD_SPECIALIZATION_CHANCE * rank)
                    gain, width = gain + g, width + w
                end
                rank = talent.master_of_defense.rank
                if (kind == "DODGE" or kind == "PARRY") and rank > 0 and equipped.shield then
                    gain, width = proc(MASTER_OF_DEFENSE_CHANCE * rank)
                end
                return gain, width
            end,
        },

        offhand = {
            swing = "offhand",

            last = function()
                local swing = state.swings.offhand
                local t = state.query_time
                if state.offhand_speed == 0 then
                    return 0
                end
                return swing + floor((t - swing) / state.offhand_speed) * state.offhand_speed
            end,

            interval = "offhand_speed",

            stop = function()
                return state.swings.offhand == 0
            end,
            value = function()
                local speed = swingBase(2)
                speed = speed > 0 and speed or offhand_speed
                return 1.73 * speed * (1 + 0.1 * talent.dual_wield_specialization.rank)
                    + wrathRage(talent.unbridled_wrath.rank, weapon.size == 2)
            end,
            -- A crit doubles the off hand's rage, Dual Wield Specialization included (W1, wowsims core/rage.go).
            crit = function()
                local speed = swingBase(2)
                return 1.73 * (speed > 0 and speed or offhand_speed) * (1 + 0.1 * talent.dual_wield_specialization.rank)
            end,
        },

        -- Anger Management (12296): 1.5 rage every 5 s in combat (DB2 effect 0: aura 85, power regen 15 tenths of rage
        -- per 5 s; m2 = 1, m3 = 3 are only tooltip values), from the combat start, as wowsims/forever's log ticks it.
        anger_management = {
            talent = "anger_management",

            last = function()
                local start = state.combat
                if start == 0 then
                    return state.query_time
                end
                return start + floor((state.query_time - start) / 5) * 5
            end,

            interval = 5,

            stop = function()
                return state.combat == 0
            end,
            value = 1.5,
        },

        -- Bloodrage's aura (29131): 1 rage every second for 10 s (DB2 effect: periodic energize 10 every 1000 ms).
        -- Its ten ticks all land; the tenth, at the expiry, meets the decay's first quantum (the meta table below).
        bloodrage = {
            aura = "bloodrage",
            pausesDecay = true, -- no out-of-combat decay while it is up (in game, user-confirmed)

            last = function()
                local app = state.buff.bloodrage.applied
                return app + floor(state.query_time - app)
            end,

            interval = 1,
            -- shortcut: Improved Bloodrage's +25% (12301) is unmodelled here, the belief's entries take a number fixed at
            -- build; the handler's instant gain carries it. Upgrade if the regen entries learn talent-scaled values.
            value = 1,
        },
    },
    nil,
    {
        -- Out-of-combat rage loss per second, the belief's `decay` (in the meta table: Hekili takes every regen entry for
        -- a model): the client's Rage tooltip, "1.25 Rage is lost every 1 sec" (measured 100 -> 0 in 82.2 s: 80 s plus
        -- reaction time); Anger Management's tooltip: 30% less.
        -- No `max`: rage is 100, and a Gnome's 105 comes from Expansive Mind in the Gnome's race pack
        -- (Hekili_Shared/Races/Gnome.lua, the belief's `maxMods`, event-facade spec §12b).
        decay = function()
            return 1.25 * (1 - 0.3 * talent.anger_management.rank)
        end,
        -- Stepped and front-loaded (stepped-decay design): 1.25 lost at once at the start of each 1 s window, the first
        -- when the decay starts (combat end, a tick aura's expiry), so Bloodrage's last tick ends at 10 - 1.25.
        decayInterval = function()
            return 1
        end,
        -- The share of the rage an ability flagged `refundOnAvoid = true` gives back when dodged, parried or missed:
        -- wowsims/forever's MissRefund (spelldata/attributes.go), 0.8 where the DB2 flags Discount Power On Miss and
        -- the spell issues the refund (the log's "Gained 12.000 rage from {OtherID: 8}" after a dodged 15-rage Sunder
        -- Armor); unmeasured in game. Not Cleave, Whirlwind, Thunder Clap, Victory Rush, Intercept or Charge.
        refundOnAvoid = 0.8,
    }
)

-- Talents: { talent tree (1 Arms, 2 Fury, 3 Protection: the dominant tree picks the spec), the definition spell,
-- max rank }: the 53 nodes of Forever's one talent tree (Raging Blows became Improved Whirlwind and Reckless Swings is
-- new at 4b0030a44b), grouped by their columns as the pane shows them. The tree is
-- wowsims/forever's ui/sim/talents/trees/warrior.json (tools/wowsims/talents.lua writes it; tests/Forever/
-- talent_trees_spec.lua checks it and the spec detection over it). Keys are Classic's where the talent exists (Bastion keeps Classic's
-- one_handed_weapon_specialization), snake_case names for the Forever-only ones. Each node reported one definition
-- spell at every rank the export saw (owned nodes at ranks 1-5 report their rank 1 spell; Iron Will and Defiance
-- define themselves by a higher DB2 rank's ID), so there are no rank aliases. The belief maps the trait walk's
-- spells to them.
spec:RegisterTalents({
    -- Arms (tree 1)
    improved_heroic_strike = { 1, 12282, 3 },
    deflection = { 1, 16462, 5 },
    improved_rend = { 1, 12286, 3 },
    improved_charge = { 1, 12285, 2 },
    improved_tactical_mastery = { 1, 12295, 3 }, -- 5 ranks before 4b0030a44b (e430b5e640)
    improved_overpower = { 1, 12290, 2 },
    anger_management = { 1, 12296, 1 },
    deep_wounds = { 1, 12834, 3 },
    spearing_strike = { 1, 1310222, 1 },
    two_handed_weapon_specialization = { 1, 12163, 3 },
    impale = { 1, 16493, 2 },
    bloodthrill = { 1, 1289682, 2 }, -- 5 ranks before 4b0030a44b (e430b5e640)
    sweeping_strikes = { 1, 12292, 1 },
    weaponmaster = { 1, 1290261, 5 },
    improved_slam = { 1, 12862, 2 }, -- the DB2 tab is Fury
    improved_hamstring = { 1, 12289, 3 },
    mortal_strike = { 1, 12294, 1 },
    -- Fury (tree 2)
    booming_voice = { 2, 12321, 5 },
    cruelty = { 2, 12320, 5 },
    lingering_rage = { 2, 1323964, 5 },
    unbridled_wrath = { 2, 12322, 5 },
    furious_precision = { 2, 1323963, 3 },
    piercing_howl = { 2, 12323, 1 },
    blood_craze = { 2, 16487, 3 },
    enrage = { 2, 12317, 5 },
    dual_wield_specialization = { 2, 23584, 5 },
    reckless_swings = { 2, 1329555, 1 },
    improved_execute = { 2, 20502, 2 },
    improved_berserker_rage = { 2, 20500, 2 },
    death_wish = { 2, 12328, 1 },
    gore_drinker = { 2, 1323967, 2 },
    improved_intercept = { 2, 20504, 2 },
    improved_whirlwind = { 2, 1310315, 2 },
    flurry = { 2, 12319, 3 }, -- 5 ranks before 4b0030a44b (e430b5e640)
    bloodthirst = { 2, 23881, 1 },
    -- Protection (tree 3)
    improved_bloodrage = { 3, 12301, 2 },
    shield_specialization = { 3, 12298, 5 },
    iron_will = { 3, 12962, 5 },
    anticipation = { 3, 12297, 5 },
    improved_revenge = { 3, 12797, 3 },
    improved_thunder_clap = { 3, 12287, 3 }, -- the DB2 tab is Arms
    last_stand = { 3, 12975, 1 },
    master_of_defense = { 3, 1310316, 2 },
    improved_disarm = { 3, 12313, 3 },
    defiance = { 3, 12792, 3 },
    improved_sunder_armor = { 3, 12308, 3 },
    vanguard = { 3, 1310317, 1 },
    improved_shield_bash = { 3, 12311, 2 },
    improved_shield_wall = { 3, 12312, 2 },
    concussion_blow = { 3, 12809, 1 },
    focused_rage = { 3, 29787, 3 },
    one_handed_weapon_specialization = { 3, 16538, 5 }, -- "Bastion" on Forever
    shield_slam = { 3, 23922, 1 },
})

spec:RegisterAuras({
    battle_shout = {
        id = 6673,
        copy = rest(BATTLE_SHOUT),
        duration = 180,
        max_stack = 1,
    },
    battle_stance = {
        id = 2457,
        duration = 3600,
        max_stack = 1,
    },
    berserker_rage = {
        id = 18499,
        duration = 10,
        max_stack = 1,
    },
    berserker_stance = {
        id = 2458,
        duration = 3600,
        max_stack = 1,
    },
    blood_craze = {
        id = 16488,
        copy = { 16490, 16491 },
        duration = 6,
        tick_time = 1,
        max_stack = 1,
    },
    bloodrage = {
        id = 29131,
        copy = { 2687 }, -- the viewer's Bloodrage entry names the cast, links the buff
        duration = 10,
        tick_time = 1,
        max_stack = 1,
    },
    challenging_shout = {
        id = 1161,
        duration = 6,
        max_stack = 1,
    },
    charge_stun = {
        id = 7922,
        duration = 1,
        max_stack = 1,
    },
    -- Cleave or Heroic Strike queued on the next swing (C_Spell.IsCurrentSpell, applied in reset_precast). A full
    -- swing long, not the time to the swing, so it can outlast the real queue by up to one swing after a reset.
    cleave = {
        duration = function()
            return state.mainhand_speed
        end,
        max_stack = 1,
    },
    concussion_blow = {
        id = 12809,
        duration = 5,
        max_stack = 1,
    },
    death_wish = {
        id = 12328,
        duration = 30,
        max_stack = 1,
    },
    deep_wound = {
        id = 23255,
        copy = { 23256 },
        duration = 12,
        max_stack = 1,
    },
    defensive_stance = {
        id = 71,
        duration = 3600,
        max_stack = 1,
    },
    demoralizing_shout = {
        id = 1160,
        copy = rest(DEMORALIZING_SHOUT),
        duration = 45,
        max_stack = 1,
    },
    disarm = {
        id = 676,
        duration = 10,
        max_stack = 1,
    },
    enrage = {
        id = 12880,
        copy = { 14201, 14202, 14203, 14204 },
        duration = 12,
        max_stack = 1,
    },
    -- A rogue's armor debuff; the Sunder Armor condition skips a target that has it.
    expose_armor = {
        id = 8647,
        copy = { 8649, 8650, 11197, 11198 },
        duration = 30,
        max_stack = 1,
    },
    flurry = {
        id = 12966,
        copy = { 12967, 12968, 12969, 12970 },
        duration = 15,
        max_stack = 1,
    },
    hamstring = {
        id = 1715,
        copy = rest(HAMSTRING),
        duration = 15,
        max_stack = 1,
    },
    heroic_strike = {
        duration = function()
            return state.mainhand_speed
        end,
        max_stack = 1,
    },
    improved_hamstring = {
        id = 23694,
        duration = 5,
        max_stack = 1,
    },
    -- a priest's armor buff on us (rage from damage taken: ARMOR_BUFFS); the one Forever ID (DB2), 15 s
    inspiration = {
        id = 14893,
        duration = 15,
        max_stack = 1,
    },
    intercept_stun = {
        id = 20253,
        copy = { 20614, 20615 },
        duration = 3,
        max_stack = 1,
    },
    intimidating_shout = {
        id = 20511,
        copy = { 5246 },
        duration = 8,
        max_stack = 1,
    },
    last_stand = {
        id = 12976,
        copy = { 12975 }, -- as Bloodrage: the viewer entry names the cast, links the buff
        duration = 20,
        max_stack = 1,
    },
    mocking_blow = {
        id = 694,
        copy = rest(MOCKING_BLOW),
        duration = 6,
        max_stack = 1,
    },
    mortal_strike = {
        id = 12294,
        copy = rest(MORTAL_STRIKE),
        duration = 10,
        max_stack = 1,
    },
    -- Forever's Overpower window: a 5 s player aura (DB2 1282733, "Overpower"), unseen in combat (checkpoint Q6: the
    -- aura walk raises). Modelled as Classic did, from the dodge in the combat log (reset_precast).
    overpower_ready = {
        id = 1282733,
        duration = 5,
        max_stack = 1,
    },
    piercing_howl = {
        id = 12323,
        duration = 6,
        max_stack = 1,
    },
    reckless_swings = {
        id = 1329555,
        duration = 8,
        max_stack = 4,
    },
    recklessness = {
        id = 1719,
        duration = 15,
        max_stack = 1,
    },
    rend = {
        id = 772,
        copy = rest(REND),
        duration = function()
            return REND_DURATION[knownRank(REND)] or 9
        end,
        tick_time = 3,
        max_stack = 1,
    },
    retaliation = {
        id = 20230,
        duration = 15,
        max_stack = 1,
    },
    revenge_stun = {
        id = 12798,
        duration = 3,
        max_stack = 1,
    },
    -- Revenge's window from the block, dodge or parry on us in the combat log, while Revenge is usable (reset_precast).
    revenge_usable = {
        duration = 5,
        max_stack = 1,
    },
    -- Victory Rush's window: 20 s from a kill that yields XP or honor (DB2 402974's PROC_FLAG_KILL triggers 402975).
    -- Timed from the plain usability flip (reset_precast), as the aura walk is secret in combat.
    victorious = {
        id = 402975,
        duration = 20,
        max_stack = 1,
    },
    shield_bash_silenced = {
        id = 18498,
        duration = 3,
        max_stack = 1,
    },
    -- Shield Block's blocks are the aura's charges (DB2: SpellAuraOptions.ProcCharges = 2, no charge category): its
    -- stacks, each block or partial block on us spending one (the belief's `consumedBy`).
    shield_block = {
        id = 2565,
        duration = 7,
        max_stack = 2,
        consumedBy = { BLOCK = true, BLOCKED = true },
    },
    shield_wall = {
        id = 871,
        duration = 12,
        max_stack = 1,
    },
    sunder_armor = {
        id = 7386,
        copy = rest(SUNDER_ARMOR),
        duration = 30,
        max_stack = 5,
    },
    sweeping_strikes = {
        id = 12292,
        duration = 20,
        max_stack = 5,
    },
    taunt = {
        id = 355,
        duration = 3,
        max_stack = 1,
    },
    thunder_clap = {
        id = 6343,
        copy = rest(THUNDER_CLAP),
        duration = function()
            return THUNDER_CLAP_DURATION[knownRank(THUNDER_CLAP)] or 10
        end,
        max_stack = 1,
        shared = "target", -- any warrior's Thunder Clap slows the target (read from the target since GAP AJ)
    },
    windfury = {
        id = 8515,
        copy = { 10609, 10612 },
        duration = 300,
        max_stack = 1,
    },
})

-- A stance change drops all rage above the amount kept by Tactical Mastery and its improved talent.
spec:RegisterStateFunction("swap_stance", function(stance)
    removeBuff("battle_stance")
    removeBuff("defensive_stance")
    removeBuff("berserker_stance")

    local lost = rage.lo - stanceKeep(talent.improved_tactical_mastery.rank) -- the sim's floor (border batch 2)
    if lost > 0 then
        spend(lost, "rage")
    end

    applyBuff(stance)
end)

-- Focused Rage: -1 rage a rank on the abilities its effect's class mask names (DB2 29787's SpellEffect
-- EffectSpellClassMask against each ability's SpellClassOptions: every strike, Disarm, Death Wish and the shouts
-- but Battle Shout), floored at 0. The DB2 holds one value (-30, rank 3's); the per-rank step is wowsims/forever's
-- logged costs at rank 3 (Shield Slam 17, Revenge 2, Sunder Armor 12: tests/Forever/wowsims/warrior_protection.log).
-- A file-local reading the caller's `talent`: the belief prices a cast in Families/Now.lua's context, which has
-- `talent` but no state functions.
local function offensive_cost(talent, cost)
    return max(0, cost - talent.focused_rage.rank)
end

-- Booming Voice: -5% a rank on the four shouts and, since 4b0030a44b, Piercing Howl (DB2 12321 effect 1, -25% at rank 5, class mask 983040; Battle Shout
-- 9 at rank 2 in wowsims/forever's Fury log), applied after the flat modifiers as the client's spell mods are;
-- `focused`: the shout is in Focused Rage's mask too.
local function shout_cost(talent, cost, focused)
    if focused then
        cost = offensive_cost(talent, cost)
    end
    return cost * (1 - 0.05 * talent.booming_voice.rank)
end

-- Improved Execute's -3 / -5 (DB2 20502: -50, rank 2's); rank 1's -3 is the rank curve wowsims/forever's spell data
-- generates from the DB2 (its log charges it), not wowsims's own logic.
local IMPROVED_EXECUTE = { [0] = 0, 3, 5 }

-- The reactive windows from the combat log, as Classic models them (origin/classic:Classic/Warrior.lua:400-456): our
-- dodged swing or ability opens Overpower's, a dodge, parry or block on us opens Revenge's. A partly blocked swing on
-- us (SWING_DAMAGE, blocked slot 16 > 0) opens it too, as in game and in wowsims (sim/warrior/revenge.go:31, any
-- OutcomeBlock; sim/core/spell_outcome.go:745 flags a block whatever damage is left). On Forever the rows come from
-- the belief's event facade (docs/superpowers/specs/2026-10-15-virtualstate-event-facade.md §6).
local enemy_revenge_trigger, enemy_dodged, enemy_dodged_target = 0, 0, nil
local last_overpower = 0
local misses = { DODGE = true, PARRY = true, BLOCK = true }
local overpower_ids, rend_ids = {}, {}
for _, id in ipairs(OVERPOWER) do
    overpower_ids[id] = true
end
for _, id in ipairs(REND) do
    rend_ids[id] = true
end

-- A short, bounded memory per unit. An immune result can come from a temporary buff.
local rendImmuneTargets, rendImmuneUntil = { false, false, false, false }, { 0, 0, 0, 0 }
local nextRendImmune = 1
local DISARM = 676
local disarmImmuneTarget, disarmImmuneUntil

spec:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
    local _, subtype, _, sourceGUID, _, _, _, destGUID, _, _, _, actionType, _, _, spellMissType, blocked =
        CombatLogGetCurrentEventInfo()

    if sourceGUID == state.GUID and subtype == "SPELL_MISSED" and spellMissType == "IMMUNE" then
        if rend_ids[actionType] then
            rendImmuneTargets[nextRendImmune], rendImmuneUntil[nextRendImmune] = destGUID, GetTime() + 30
            nextRendImmune = nextRendImmune % #rendImmuneUntil + 1
        elseif actionType == DISARM then
            disarmImmuneTarget, disarmImmuneUntil = destGUID, GetTime() + 60
        end
    elseif
        sourceGUID == state.GUID
        and subtype:match("_MISSED$")
        and (actionType == "DODGE" or spellMissType == "DODGE")
    then
        enemy_dodged = GetTime()
        enemy_dodged_target = destGUID
    elseif
        destGUID == state.GUID
        and (
            (subtype:match("_MISSED$") and misses[actionType])
            or (subtype == "SWING_DAMAGE" and type(blocked) == "number" and blocked > 0)
        )
    then
        enemy_revenge_trigger = GetTime()
    elseif sourceGUID == state.GUID and subtype == "SPELL_CAST_SUCCESS" and overpower_ids[actionType] then
        last_overpower = GetTime()
    end
end)

-- Victorious has no plain kill row: IsSpellUsable ignores the cooldown, so its false->true flip is the kill.
local victorious_at, victory_usable = 0, false
spec:RegisterEvent("SPELL_UPDATE_USABLE", function()
    local u = reactive(VICTORY_RUSH)
    if u ~= victory_usable then
        victory_usable = u
        victorious_at = u and GetTime() or 0
    end
end)

spec:RegisterHook("reset_precast", function()
    -- The stance comes from the belief's Forms source (Game/State/Sources/Forms.lua) through the aura walk.
    local hs, cl = knownRank(HEROIC_STRIKE), knownRank(CLEAVE)
    if hs > 0 and IsCurrentSpell(HEROIC_STRIKE[hs]) then
        applyBuff("heroic_strike")
    end
    if cl > 0 and IsCurrentSpell(CLEAVE[cl]) then
        applyBuff("cleave")
    end

    if now == query_time then
        if knownRank(OVERPOWER) > 0 then
            if
                enemy_dodged > 0
                and query_time - enemy_dodged < 6
                and target.unit == enemy_dodged_target
                and (last_overpower == 0 or enemy_dodged - last_overpower > 5)
                -- a dodge row can be another player's: in its stance the client's yes opens the window; out of it the client
                -- says no either way, and Fury's stance weave needs the window to swap
                and (usableNow(OVERPOWER) or not clientInBattle())
            then
                applyBuff("overpower_ready", enemy_dodged + 5 - now)
            elseif usableNow(OVERPOWER) then
                applyBuff("overpower_ready")
            end
        end
        if reactive(REVENGE) then
            if enemy_revenge_trigger > 0 and now - enemy_revenge_trigger < 5 then
                applyBuff("revenge_usable", enemy_revenge_trigger + 5 - now)
            else
                applyBuff("revenge_usable")
            end
        end
        -- With an expiry the sim knows the window's end ahead: Victory Rush is refused past it.
        if reactive(VICTORY_RUSH) then
            if victorious_at > 0 and now - victorious_at < 20 then
                applyBuff("victorious", victorious_at + 20 - now)
            else
                applyBuff("victorious")
            end
        end
    end
end)

-- `timeToReady` of the three stances: they share a 1 s category cooldown.
local function stanceReady()
    return max(cooldown.battle_stance.remains, cooldown.defensive_stance.remains, cooldown.berserker_stance.remains)
end

local function interruptReadyTime()
    local casting = state.debuff.casting
    if
        (state.spec.arms or state.spec.protection)
        and (state.level < 60 or state.arms_open_world)
        and casting.up
        and casting.v2 == 0
    then
        -- Forever hides the end time. Stop a leveling cast as soon as the interrupt is ready.
        return 0
    end
    return state.timeToInterrupt()
end

spec:RegisterAbilities({
    battle_shout = {
        id = 6673,
        copy = rest(BATTLE_SHOUT),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return shout_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = false,
        known = knows(BATTLE_SHOUT),

        now = function()
            applyBuff("battle_shout")
        end,

        handler = function()
            applyBuff("battle_shout")
        end,
    },

    battle_stance = {
        id = 2457,
        cast = 0,
        cooldown = 1,
        gcd = "off",

        startsCombat = false,
        known = knows({ 2457 }),
        nobuff = "battle_stance",
        timeToReady = stanceReady,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            removeBuff("defensive_stance")
            removeBuff("berserker_stance")
            local lost = rage.current - stanceKeep(talent.improved_tactical_mastery.rank)
            if lost > 0 then
                spend(lost, "rage")
            end
            applyBuff("battle_stance")
        end,

        handler = function()
            swap_stance("battle_stance")
        end,
    },

    berserker_rage = {
        id = 18499,
        cast = 0,
        cooldown = 30,
        gcd = "spell",

        startsCombat = false,
        known = knows({ 18499 }),
        form = "berserker_stance",

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyBuff("berserker_rage")
            if talent.improved_berserker_rage.enabled then
                gain(10 * talent.improved_berserker_rage.rank, "rage")
            end
        end,

        handler = function()
            applyBuff("berserker_rage")
            -- DB2 20500: energize 100 (10 rage) a rank.
            if talent.improved_berserker_rage.enabled then
                gain(10 * talent.improved_berserker_rage.rank, "rage")
            end
        end,
    },

    berserker_stance = {
        id = 2458,
        cast = 0,
        cooldown = 1,
        gcd = "off",

        startsCombat = false,
        known = knows({ 2458 }),
        nobuff = "berserker_stance",
        timeToReady = stanceReady,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            removeBuff("battle_stance")
            removeBuff("defensive_stance")
            local lost = rage.current - stanceKeep(talent.improved_tactical_mastery.rank)
            if lost > 0 then
                spend(lost, "rage")
            end
            applyBuff("berserker_stance")
        end,

        handler = function()
            swap_stance("berserker_stance")
        end,
    },

    -- 10 rage now (DB2: energize 100), then 10 over 10 s from its aura (the resource's bloodrage entry). Its health
    -- cost is not simulated: the player's health is secret on Forever.
    bloodrage = {
        id = 2687,
        cast = 0,
        cooldown = 60,
        gcd = "off",

        startsCombat = false,
        known = knows({ 2687 }),

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            gain(10 * (1 + 0.25 * talent.improved_bloodrage.rank), "rage")
            applyBuff("bloodrage")
        end,

        handler = function()
            -- 12301 (in-game tooltip): +25% of the rage Bloodrage generates a rank.
            gain(10 * (1 + 0.25 * talent.improved_bloodrage.rank), "rage")
            applyBuff("bloodrage")
        end,
    },

    bloodthirst = {
        id = 23881,
        copy = rest(BLOODTHIRST),
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 30)
        end,
        spendType = "rage",

        talent = "bloodthirst",
        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_fury.go; DB2 Discount Power On Miss
        known = knows(BLOODTHIRST),
    },

    challenging_shout = {
        id = 1161,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 600,
        gcd = "spell",

        spend = function()
            return shout_cost(talent, 5, true)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows({ 1161 }),
        toggle = "defensives",

        now = function()
            applyDebuff("target", "challenging_shout")
        end,

        handler = function()
            applyDebuff("target", "challenging_shout")
        end,
    },

    charge = {
        id = 100,
        copy = rest(CHARGE),
        cast = 0,
        cooldown = 15,
        gcd = "off",

        startsCombat = true,
        known = knows(CHARGE),
        -- Vanguard: Charge also in Defensive Stance (Forever, 1310317)
        form = function()
            if talent.vanguard.enabled and buff.defensive_stance.up then
                return "defensive_stance"
            end
            return "battle_stance"
        end,

        -- The spell's own range check: exact, where target.minR/maxR are only the coarse bracket (VS.TargetRange).
        usable = function()
            return combat == 0 and not action.rend.in_range, "cannot be in combat; target must be outside melee range"
        end,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            gain(chargeRage() + 3 * talent.improved_charge.rank, "rage")
            applyDebuff("target", "charge_stun")
        end,

        handler = function()
            setDistance(7)
            if not target.is_boss then
                applyDebuff("target", "charge_stun")
            end
            gain(chargeRage() + 3 * talent.improved_charge.rank, "rage")
        end,
    },

    cleave = {
        id = 845,
        copy = rest(CLEAVE),
        cast = 0,
        cooldown = 0,
        gcd = "off",

        spend = function()
            return offensive_cost(talent, 20)
        end,
        spendType = "rage",

        startsCombat = true,
        onNextSwing = true, -- The belief: paid at the main hand's next swing, which then brings no rage
        known = knows(CLEAVE),

        usable = function()
            return not buff.heroic_strike.up and not buff.cleave.up, "a strike is already queued"
        end,

        handler = function()
            applyBuff("cleave")
        end,
    },

    concussion_blow = {
        id = 12809,
        cast = 0,
        cooldown = 45,
        gcd = "off",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        talent = "concussion_blow",
        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_protection.go; DB2 Discount Power On Miss
        known = knows({ 12809 }),
        usable = hasMeleeWeapon,

        now = function()
            applyDebuff("target", "concussion_blow")
        end,

        handler = function()
            applyDebuff("target", "concussion_blow")
            interrupt()
        end,
    },

    death_wish = {
        id = 12328,
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        talent = "death_wish",
        startsCombat = true,
        known = knows({ 12328 }),
        toggle = "cooldowns",

        now = function()
            applyBuff("death_wish")
        end,

        handler = function()
            applyBuff("death_wish")
        end,
    },

    defensive_stance = {
        id = 71,
        cast = 0,
        cooldown = 1,
        gcd = "off",

        startsCombat = false,
        known = knows({ 71 }),
        nobuff = "defensive_stance",
        timeToReady = stanceReady,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            removeBuff("battle_stance")
            removeBuff("berserker_stance")
            local lost = rage.current - stanceKeep(talent.improved_tactical_mastery.rank)
            if lost > 0 then
                spend(lost, "rage")
            end
            applyBuff("defensive_stance")
        end,

        handler = function()
            swap_stance("defensive_stance")
        end,
    },

    demoralizing_shout = {
        id = 1160,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(DEMORALIZING_SHOUT),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return shout_cost(talent, 10, true)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(DEMORALIZING_SHOUT),

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "demoralizing_shout")
        end,

        handler = function()
            applyDebuff("target", "demoralizing_shout")
            active_dot.demoralizing_shout = active_enemies
        end,
    },

    disarm = {
        id = DISARM,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        missable = true,
        cast = 0,
        cooldown = 60,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 20)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims disarm.go; DB2 Discount Power On Miss
        known = knows({ DISARM }),
        toggle = "defensives",
        form = "defensive_stance",

        now = function()
            applyDebuff("target", "disarm")
        end,

        handler = function()
            applyDebuff("target", "disarm")
        end,
    },

    -- Usable below 20% health: the target's health is secret on Forever, so the window is the plain usability read.
    execute = {
        id = 5308,
        copy = rest(EXECUTE),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 15 - IMPROVED_EXECUTE[talent.improved_execute.rank])
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims execute.go; DB2 Discount Power On Miss
        known = knows(EXECUTE),
        nobuff = "defensive_stance",
        healthGate = 0.2, -- usable at or below 20% of the target's health: the belief's target health reads it

        usable = function()
            return reactive(EXECUTE), "requires target health under 20 percent"
        end,

        -- the belief's side of the handler: the rest after the cost goes into the strike (wowsims execute.go; gaps.md
        -- "Execute floor": with the cost alone the floor stayed above the truth); the band's top, so est, lo and hi
        -- all reach 0 (each clamps there)
        now = function()
            spend(rage.hi, "rage")
        end,

        handler = function()
            spend(rage.lo, "rage") -- the rest of the rage goes into the strike (the sim's floor, border batch 2)
        end,
    },

    hamstring = {
        id = 1715,
        copy = rest(HAMSTRING),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims hamstring.go; DB2 Discount Power On Miss
        known = knows(HAMSTRING),
        nobuff = "defensive_stance",
        usable = hasMeleeWeapon,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "hamstring")
        end,

        handler = function()
            applyDebuff("target", "hamstring")
        end,
    },

    heroic_strike = {
        id = 78,
        copy = rest(HEROIC_STRIKE),
        cast = 0,
        cooldown = 0,
        gcd = "off",

        -- Improved Heroic Strike: -1 a rank
        spend = function()
            return offensive_cost(talent, 15 - talent.improved_heroic_strike.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims heroic_strike_cleave.go; DB2 Discount Power On Miss
        -- The belief: paid at the main hand's next swing, which then brings no rage. Hekili's own simulation ignores
        -- onNextSwing: it spends the cost at the press and still adds the replaced swing's rage, so its forward
        -- projection is one swing of rage optimistic per queued strike until the belief's next drain corrects the
        -- belief (checkpoint Q9). Cleave alike.
        onNextSwing = true,
        known = knows(HEROIC_STRIKE),

        usable = function()
            if weapon.size == 0 then
                return false, "requires a melee weapon"
            end
            return not buff.heroic_strike.up and not buff.cleave.up, "a strike is already queued"
        end,

        handler = function()
            applyBuff("heroic_strike")
        end,
    },

    intercept = {
        id = 20252,
        copy = rest(INTERCEPT),
        cast = 0,
        cooldown = 30,
        gcd = "off",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(INTERCEPT),
        form = "berserker_stance",

        -- The spell's own range check: exact, where target.minR/maxR are only the coarse bracket (VS.TargetRange).
        usable = function()
            return action.intercept.in_range, "target must be within Intercept's range"
        end,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "intercept_stun")
        end,

        handler = function()
            setDistance(7)
            applyDebuff("target", "intercept_stun")
        end,
    },

    intimidating_shout = {
        id = 5246,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 180,
        gcd = "spell",

        spend = function()
            return shout_cost(talent, 25, true)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows({ 5246 }),

        now = function()
            applyDebuff("target", "intimidating_shout")
        end,

        handler = function()
            applyDebuff("target", "intimidating_shout")
        end,
    },

    -- Classic also raised the simulated maximum health; the player's health is secret on Forever.
    last_stand = {
        id = 12975,
        cast = 0,
        cooldown = 180,
        gcd = "off",

        talent = "last_stand",
        startsCombat = false,
        known = knows({ 12975 }),
        toggle = "defensives",

        now = function()
            applyBuff("last_stand")
        end,

        handler = function()
            applyBuff("last_stand")
        end,
    },

    mocking_blow = {
        id = 694,
        copy = rest(MOCKING_BLOW),
        cast = 0,
        cooldown = 120,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims mocking_blow.go; DB2 Discount Power On Miss
        known = knows(MOCKING_BLOW),
        form = "battle_stance",

        now = function()
            applyDebuff("target", "mocking_blow")
        end,

        handler = function()
            applyDebuff("target", "mocking_blow")
        end,
    },

    mortal_strike = {
        id = 12294,
        copy = rest(MORTAL_STRIKE),
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 30)
        end,
        spendType = "rage",

        talent = "mortal_strike",
        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_arms.go; DB2 Discount Power On Miss
        known = knows(MORTAL_STRIKE),

        now = function()
            applyDebuff("target", "mortal_strike")
        end,

        handler = function()
            applyDebuff("target", "mortal_strike")
        end,
    },

    overpower = {
        id = 7384,
        copy = rest(OVERPOWER),
        cast = 0,
        cooldown = 5,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 5)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims overpower.go; DB2 Discount Power On Miss
        known = knows(OVERPOWER),
        form = "battle_stance",

        usable = function()
            if weapon.size == 0 then
                return false, "requires a melee weapon"
            end
            return buff.overpower_ready.up, "only usable after dodging"
        end,

        now = function()
            removeBuff("overpower_ready")
        end,

        handler = function()
            removeBuff("overpower_ready")
        end,
    },

    piercing_howl = {
        id = 12323,
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        -- Focused Rage's class mask names it (29787, unchanged between the pins: the old kit missed it) and, since
        -- 4b0030a44b, Booming Voice's does too (12321's mask gained its bit)
        spend = function()
            return shout_cost(talent, 10, true)
        end,
        spendType = "rage",

        talent = "piercing_howl",
        startsCombat = true,
        known = knows({ 12323 }),

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "piercing_howl")
        end,

        handler = function()
            applyDebuff("target", "piercing_howl")
        end,
    },

    pummel = {
        id = 6552,
        copy = rest(PUMMEL),
        cast = 0,
        cooldown = 10,
        gcd = "spell", -- the DB2's (start recovery 1500 ms); Classic had it off the GCD (checkpoint question)

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims pummel.go; DB2 Discount Power On Miss
        known = knows(PUMMEL),
        toggle = "interrupts",
        form = "berserker_stance",
        debuff = "casting",
        readyTime = interruptReadyTime,

        handler = function()
            interrupt()
        end,
    },

    -- Fury talent (1329555, new at 4b0030a44b): 15 s cooldown, a 1 s GCD, 25% of base health (unsimulated, like
    -- Bloodrage's: the player's health is secret) for 4 charges in 8 s; each white swing spends one and gives 5 rage.
    -- shortcut: the belief cannot spend a charge on our own swing (consumedBy reads hits on us only), so the four
    -- swings' 20 rage are granted at the cast; upgrade when central support exists (blocker note warrior-1).
    reckless_swings = {
        id = 1329555,
        cast = 0,
        cooldown = 15,
        gcd = "spell",
        gcdTime = 1,

        startsCombat = false,
        talent = "reckless_swings",
        known = knows({ 1329555 }),

        now = function()
            applyBuff("reckless_swings", nil, 4)
            gain(20, "rage")
        end,

        handler = function()
            applyBuff("reckless_swings", nil, 4)
            gain(20, "rage")
        end,
    },

    recklessness = {
        id = 1719,
        cast = 0,
        cooldown = 1800,
        gcd = "spell",

        startsCombat = false,
        known = knows({ 1719 }),
        toggle = "cooldowns",
        form = "berserker_stance",

        now = function()
            applyBuff("recklessness")
        end,

        handler = function()
            applyBuff("recklessness")
        end,
    },

    rend = {
        id = 772,
        copy = rest(REND),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims rend.go; DB2 Discount Power On Miss
        known = knows(REND),
        nobuff = "berserker_stance",
        usable = hasMeleeWeapon,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "rend", REND_DURATION[knownRank(REND)] or 9)
        end,

        handler = function()
            applyDebuff("target", "rend")
        end,
    },

    retaliation = {
        id = 20230,
        cast = 0,
        cooldown = 900,
        gcd = "spell",

        startsCombat = false,
        known = knows({ 20230 }),
        toggle = "cooldowns",
        form = "battle_stance",

        now = function()
            applyBuff("retaliation")
        end,

        handler = function()
            applyBuff("retaliation")
        end,
    },

    revenge = {
        id = 6572,
        copy = rest(REVENGE),
        cast = 0,
        cooldown = 5,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 5)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims revenge.go; DB2 Discount Power On Miss
        known = knows(REVENGE),

        form = "defensive_stance",
        buff = "revenge_usable",

        handler = function()
            removeBuff("revenge_usable")
        end,
    },

    shield_bash = {
        id = 72,
        copy = rest(SHIELD_BASH),
        cast = 0,
        cooldown = 12,
        gcd = "spell", -- the DB2's (start recovery 1500 ms); Classic had it off the GCD (checkpoint question)

        spend = function()
            return offensive_cost(talent, 10)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims shield_bash.go; DB2 Discount Power On Miss
        known = knows(SHIELD_BASH),
        toggle = "interrupts",
        form = function()
            return buff.battle_stance.up and "battle_stance" or "defensive_stance"
        end,
        equipped = "shield",
        debuff = "casting",
        readyTime = interruptReadyTime,

        now = function()
            if talent.improved_shield_bash.rank >= 1 then
                applyDebuff("target", "shield_bash_silenced")
            end
        end,

        handler = function()
            interrupt()
            if talent.improved_shield_bash.rank >= 1 then
                applyDebuff("target", "shield_bash_silenced")
            end
        end,
    },

    shield_block = {
        id = 2565,
        cast = 0,
        cooldown = 5,
        gcd = "off",

        spend = 10,
        spendType = "rage",

        startsCombat = false,
        known = knows({ 2565 }),
        form = "defensive_stance",
        equipped = "shield",

        now = function()
            applyBuff("shield_block", nil, 2)
        end,

        handler = function()
            applyBuff("shield_block", nil, 2)
        end,
    },

    shield_slam = {
        id = 23922,
        copy = rest(SHIELD_SLAM),
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 20)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_protection.go; DB2 Discount Power On Miss
        known = knows(SHIELD_SLAM),
        equipped = "shield",
    },

    shield_wall = {
        id = 871,
        cast = 0,
        cooldown = 900,
        gcd = "spell", -- the DB2's (start recovery 1500 ms); Classic had it off the GCD (checkpoint question)

        startsCombat = false,
        known = knows({ 871 }),
        toggle = "defensives",
        form = "defensive_stance",
        equipped = "shield",

        now = function()
            applyBuff("shield_wall")
        end,

        handler = function()
            applyBuff("shield_wall")
        end,
    },

    -- Forever gave Slam a 15 s cooldown (wowsims/forever's category recovery from 4b0030a44b, 18 s before: hotfix 113600)
    -- and a rank 1 at level 20.
    slam = {
        id = 1240193,
        copy = rest(SLAM),
        -- Improved Slam (12862, wowsims/forever's curves at 4b0030a44b): the cast and the GCD 0.25 s a rank shorter (1 s
        -- at 2/2: wowsims's log) and the cooldown 2.5 s a rank (10 s at 2/2); at 2/2 Slam no longer delays the swing (its
        -- tooltip), and this kit models no delay either way
        cast = function()
            return 1.5 - 0.25 * talent.improved_slam.rank
        end,
        cooldown = function()
            return 15 - 2.5 * talent.improved_slam.rank
        end,
        gcd = "spell",
        gcdTime = function()
            return talent.improved_slam.enabled and 1.5 - 0.25 * talent.improved_slam.rank or nil
        end,

        spend = function()
            return offensive_cost(talent, 15)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims slam.go; DB2 Discount Power On Miss
        known = knows(SLAM),
    },

    -- Forever: a strike with a 20 s cooldown, an Arms talent (node 1310222; the DB2's level 1 is not the gate).
    spearing_strike = {
        id = 1310222,
        cast = 0,
        cooldown = 20,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 15)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims talents_arms.go; DB2 Discount Power On Miss
        talent = "spearing_strike",
        known = knows({ 1310222 }),
        form = "battle_stance",
    },

    sunder_armor = {
        id = 7386,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        copy = rest(SUNDER_ARMOR),
        cast = 0,
        cooldown = 0,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 15 - talent.improved_sunder_armor.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims sunder_armor.go; DB2 Discount Power On Miss
        known = knows(SUNDER_ARMOR),
        usable = hasMeleeWeapon,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "sunder_armor", nil, min(5, debuff.sunder_armor.stack + 1))
        end,

        handler = function()
            applyDebuff("target", "sunder_armor", nil, min(5, debuff.sunder_armor.stack + 1))
        end,
    },

    sweeping_strikes = {
        id = 12292,
        cast = 0,
        cooldown = 30,
        gcd = "off",

        spend = 30,
        spendType = "rage",

        talent = "sweeping_strikes",
        startsCombat = false,
        known = knows({ 12292 }),
        form = "battle_stance",
        toggle = "cooldowns",

        now = function()
            applyBuff("sweeping_strikes", nil, 5)
        end,

        handler = function()
            applyBuff("sweeping_strikes", nil, 5)
        end,
    },

    taunt = {
        id = 355,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        cast = 0,
        cooldown = 8,
        gcd = "off",

        startsCombat = true,
        known = knows({ 355 }),
        form = "defensive_stance",

        now = function()
            applyDebuff("target", "taunt")
        end,

        handler = function()
            applyDebuff("target", "taunt")
        end,
    },

    thunder_clap = {
        id = 6343,
        copy = rest(THUNDER_CLAP),
        cast = 0,
        cooldown = 6,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 20 - 2 * talent.improved_thunder_clap.rank)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(THUNDER_CLAP),
        nobuff = "berserker_stance",

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            applyDebuff("target", "thunder_clap", THUNDER_CLAP_DURATION[knownRank(THUNDER_CLAP)] or 10)
        end,

        handler = function()
            applyDebuff("target", "thunder_clap")
            active_dot.thunder_clap = min(active_enemies, 4 + active_dot.thunder_clap)
        end,
    },

    -- Forever: usable within Victorious (20 s) after a kill that yields experience or honor; free, 30 s cooldown (DB2 402927).
    victory_rush = {
        id = 402927,
        cast = 0,
        cooldown = 30,
        gcd = "spell",

        startsCombat = true,
        known = knows(VICTORY_RUSH),

        usable = function()
            return buff.victorious.up, "only usable after a kill"
        end,

        -- what the cast did to the now-state, in the belief's context (spec §12a)
        now = function()
            removeBuff("victorious")
        end,

        handler = function()
            removeBuff("victorious") -- confirmed in game (user, 2026-10-18)
        end,
    },

    whirlwind = {
        id = 1680,
        cast = 0,
        -- Improved Whirlwind (1310315): -1 s a rank (wowsims/forever's curve {-1000, -2000}, misc 11)
        cooldown = function()
            return 10 - talent.improved_whirlwind.rank
        end,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 25)
        end,
        spendType = "rage",

        startsCombat = true,
        known = knows(WHIRLWIND),
        form = "berserker_stance",
    },
})

-- The rage a stance swap would leave (swap_stance's rule: the rage now, up to what is kept), for a priority's guard:
-- Tactical Mastery is a passive, which no priority can read (Fury's overpower_weaving guard, the user's ruling
-- 2026-10-21).
spec:RegisterStateExpr("stance_rage_kept", function()
    local keep = stanceKeep(talent.improved_tactical_mastery.rank)
    if rage.lo < keep then -- the sim's floor, as every APL read (border batch 2)
        return rage.lo
    end
    return keep
end)

-- The execute phase: Execute's plain usability window (the target's health is secret on Forever).
spec:RegisterStateExpr("execute_phase", function()
    return reactive(EXECUTE)
end)

local function isPvE()
    local _, instanceType = Facade.IsInInstance()
    return instanceType == "none" or instanceType == "party" or instanceType == "raid" or instanceType == "scenario"
end

local function isOpenWorld()
    return Facade.IsInInstance() == false and Facade.IsInRaid() == false
end

spec:RegisterStateExpr("arms_pve_target", function()
    return isPvE()
        and Facade.UnitCanAttack("player", "target") == true
        and Facade.UnitIsPlayer("target") == false
        and not target.is_dummy
        and not target.is_dead
end)

-- Short outdoor pulls need a different rage budget than sustained fights.
spec:RegisterStateExpr("arms_open_world", function()
    return isOpenWorld() and state.arms_pve_target and not boss and not target.is_boss
end)

spec:RegisterStateExpr("prot_adventuring", function()
    return state.spec.protection and state.arms_pve_target and (level < 60 or state.arms_open_world)
end)

spec:RegisterStateExpr("prot_leveling", function()
    return level < 60 and state.prot_adventuring
end)

spec:RegisterStateExpr("prot_charge_range", function()
    return not action.rend.in_range and C_Spell.IsSpellInRange(CHARGE[1], "target") == true
end)

spec:RegisterStateExpr("prot_melee_target", function()
    return target.within5 and not target.outside5 and target.creature_type ~= "elemental" and debuff.casting.down
end)

spec:RegisterStateExpr("prot_disarm_target", function()
    if not state.prot_melee_target or target.creature_type ~= "humanoid" or boss or target.is_boss then
        return false
    end
    if disarmImmuneTarget and disarmImmuneUntil > now and Facade.UnitGUID("target") == disarmImmuneTarget then
        return false
    end
    local classification = Facade.UnitClassification("target")
    -- The client does not supply an NPC's weapon here. Use the dangerous melee cases from the leveling guide.
    return active_enemies > 1
        or (not issecretvalue(classification) and (classification == "elite" or classification == "rareelite"))
end)

-- Keep the original condition available to saved custom priorities.
spec:RegisterStateExpr("arms_solo", function()
    return solo and state.arms_open_world
end)

spec:RegisterStateExpr("arms_short_pull", function()
    local classification = Facade.UnitClassification("target")
    return not issecretvalue(classification) and (classification == "normal" or classification == "rare")
end)

local BLEED_IMMUNE_NPCS = {
    [114] = true, -- Harvest Watcher, confirmed in WoW Forever.
}

spec:RegisterStateExpr("arms_skip_rend", function()
    if not state.arms_pve_target then
        return false
    elseif BLEED_IMMUNE_NPCS[target.npcid] then
        return true
    end
    local guid = Facade.UnitGUID("target")
    if guid then
        for i = 1, #rendImmuneUntil do
            if rendImmuneTargets[i] == guid and rendImmuneUntil[i] > now then
                return true
            end
        end
    end
    return false
end)

spec:RegisterStateExpr("arms_moving_humanoid", function()
    return target.creature_type == "humanoid" and target.moving
end)

spec:RegisterStateExpr("arms_bloodrage_safe", function()
    if not (isOpenWorld() or level < 60 and isPvE()) or Facade.UnitIsPlayer("target") == true then
        return true
    end
    if rage.lo > 25 then
        return false
    end
    local inCombat = combat > 0
    if
        not inCombat
        and not (Facade.UnitCanAttack("player", "target") == true and target.within5 and not target.outside5)
    then
        return false
    end
    local playerHealth = Facade.PlayerHealthFraction()
    if playerHealth == nil then
        return inCombat
    end
    return playerHealth >= 0.65
end)

spec:RegisterStateExpr("prot_bloodrage_safe", function()
    if action.revenge.known then
        return state.arms_bloodrage_safe
    end
    -- Keep the early kit's rage generation, while honoring an observed low-health result.
    local playerHealth = Facade.PlayerHealthFraction()
    return playerHealth == nil or playerHealth >= 0.65
end)

-- The time to the next main-hand swing, ported from Hekili's Classic profile (Classic/Warrior.lua:462-575, without its
-- debug lines); the Slam weave reads it.
spec:RegisterStateExpr("mainhand_remains", function()
    -- out of combat no swing runs (nextMH is 0): anchor it at this evaluation, or its phase free-runs with the clock
    local mh = (nextMH == 0 and combat == 0) and now or nextMH
    if now == query_time then
        local real = mh - now
        return real > 0 and real or 0
    end
    if query_time <= mh then
        return mh - query_time
    end
    if mainhand_speed <= 0 then
        return 0
    end -- no swing speed read yet
    return mainhand_speed - (query_time - mh) % mainhand_speed
end)

-- The time to the next off-hand swing (translator-5: wowsims's MeleeAuto is the earlier hand), mainhand_remains's clock
-- on the off hand; with no off-hand weapon that hand never swings: 3600 s, so min() takes the main hand.
spec:RegisterStateExpr("offhand_remains", function()
    if offhand_speed <= 0 then
        return 3600 -- no off-hand weapon: that hand never swings (wowsims's NeverExpires)
    end
    local oh = (nextOH == 0 and combat == 0) and now or nextOH
    if now == query_time then
        local real = oh - now
        return real > 0 and real or 0
    end
    if query_time <= oh then
        return oh - query_time
    end
    return offhand_speed - (query_time - oh) % offhand_speed
end)

-- The wowsims.com priorities' switches (each .simc header's Setting lines), on the specs whose priority reads them.
spec:RegisterSetting("wowsims_recklessness", false, {
    type = "toggle",
    name = L["Recklessness (wowsims.com)"],
    desc = L["The wowsims.com priority's Recklessness ON/OFF switch (its default in wowsims's own APL)."],
    width = "full",
}, "arms")

spec:RegisterSetting("wowsims_stance_dance", false, {
    type = "toggle",
    name = L["Stance Dance (wowsims.com)"],
    desc = L["The wowsims.com priority's Stance Dance ON/OFF switch (its default in wowsims's own APL)."],
    width = "full",
}, "arms")

spec:RegisterSetting("wowsims_recklessness", false, {
    type = "toggle",
    name = L["Recklessness (wowsims.com)"],
    desc = L["The wowsims.com priority's Recklessness ON/OFF switch (its default in wowsims's own APL)."],
    width = "full",
}, "fury")

spec:RegisterSetting("wowsims_rend_weave", true, {
    type = "toggle",
    name = L["Rend Weave (wowsims.com)"],
    desc = L["The wowsims.com priority's Rend Weave ON/OFF switch (its default in wowsims's own APL)."],
    width = "full",
}, "fury")

-- The maintenance debuffs (tools/wowsims/apl.lua rule 15; the recipes' `maintenance`): a raid's debuffs, off in game
-- (open-world mobs die before they pay off), on under the harness (`sim`: wowsims's raid boss).
spec:RegisterSetting("maintain_demoralizing_shout", false, {
    type = "toggle",
    name = L["Maintain Demoralizing Shout"],
    desc = L["Keep Demoralizing Shout on the target, as a raid tank does. Off: the priority never shows it."],
    width = "full",
    sim = true,
}, "protection")

spec:RegisterSetting("maintain_thunder_clap", false, {
    type = "toggle",
    name = L["Maintain Thunder Clap"],
    desc = L["Keep Thunder Clap's slow on the target, recasting it only when it is missing (that includes the levels before Mortal Strike). Off: the priority never " .. "shows Thunder Clap."],
    width = "full",
    sim = true,
}, "arms")

-- The three priorities, written by `make packs` (tools/make_pack.lua) from APLs/packs.lua and APLs/*.simc; edit
-- those and run it, never these blocks (tests/Forever/warrior_spec.lua checks they match). Pick one with
-- /hekili priority <name>.
spec:RegisterPack(
    "Protection (wowsims.com)",
    20261110001,
    [[Hekili:TVvBpUTns4Fl7x8zJM41E315scIdqstlAoK2RiU463Smxj618SSOosQ13EWW)2VziLTOOeLLCCYvGROOj2sKZ8mdN34mXZhp)3MplIOOZ)LBgDZlgpE8OrJgpFM6Pu68zPKW1KhGpKq2a)5Vk4kAOIXt2VO)w(wjBJCyiFZaCLpfZjri1UpJfR(yY87RLWYuA48z)(7(8N)4F)ZVo9ifNpBflkIA2gvg2a3E9(fQv09lYF21l5c6JuX(fr0LKSy1(fV7x)0(fWJ3VOerYyxJSxE9wIqW4IRly)1K0y515eyi8LH)tjpzWZawjijYyqqIGpZrwZK7xqII4j)f4dRPpjhUFXhikYRRbs9)5p(BarwPuPYxF91pWuRYUhLIRDw6aGMaYPtiVkm6gYnrldbY(9CECeFBIe59dpedsnOMOsGvFMQiXmccEGbFGsuR2V43zYvW3MTLstzjpaFsjyRPiGtIYvBcsiJedpQ)7J5C4P)yM4jytVNkKuXAyBWx(HmbDnb)qCwcff0pXEyLAaIPyIuYcrDlBdr80(fHeq7kxX3UFrmF7ZxrjXiyaTjnrYEezpiIWA2Uc)tnkcJz0evU4SFXt8mqBz2jWJFc(Gg)PCuaHfKjP578dwK1OuGn8jGbMDWtP463Yqi89RiIhO5spqcP12rLdjjKEyTeugy04iGC)dsYdzebSPyQYaVcIHlNNbyxULKAuZsnLKLaIHDFgLCnewQqdcGl3hZdxdQ2iEe(c0mnfmiFkhMljpYfWoNPbd83XKnWQ0ivJdT6MSemCG3Yudlw67rkNtMiYgW195cAuwObJiOL50F)In0ykqX0S4yPnjiYvO8WtLiNK4oyjOvdifW6(4sKNW)JNjjKhjSyY9X0NH2QjHzGLb6Qbaz7b7cGuAXgjgkh6VKWtE(9CP8OErlzXuIijxM(atseBmmIyzmL7yhH4rWZG3UkBdjHZIQitVtHKeop2V4fJYTEaFUmWBMlqBAJoc2agnGPGtafr7TWbpsGa)qckB7x8ZewIIGQHpq3WfGT5)X4DzSdWWcA7tgQTs4IneGLBWnrtmMyGjbDieMuWxYIHqPeDuh5WubfcgCprn9OagymMEgqXa(YLbpegnD8ZylNIrRcirG9Kkta8Vx(oh1t)MqT5zG(GQh9FLXstPrdnM09GyfW2g(yUD9qQwYI6zWXqZEhUobI1aK1e05Wtfus0t9U6(SLlh6IYHzP5VbqIk2(Xcq1omM)MPMhfGFpynnvT)Vvr6)UPxxA)FzcFxfQkq)kFQRoktgE9fjmEuwyKBK5vPD)R00iopo0o93oU(ajzjDqZNaOrnsPYkh8PGU5So88OM7Fv(jvfRk9z2oVMCd6vwiRhucRmKiiAXwoTtOF3axfVJlyHs))hD1pTnsxe5Ukkxsh8lSBT2onCDmvkdKBHnjTFL5in4EiPCdm4TJGdDG0QHyPjSKjO8P)oMXhkWAsViQwrG5GH9HQaNN84nthzZ50Snq20VXmn8yjeyeRTTwd3cSKxPiMswiYsvYgqxzumeTQadjOALJKLjd0F)yemRdQdbVQ5nABYDvvcJhuqjJI3Hi5p0)(T1Iq95kTTEKJcmIjtJjpfCpfeRP3nQiEwXwkfxoh7BjXXLcjB)CiACnwS4RC43Ttk4xzcuWqlCyZVsWRm7u8ekuq4ghMnzKjxyxO7xOCdXyOIGWm4wu)VgmM7rP1nnAcC7i3DbgubM7C1cBhVEJ2u9St2bo1UP28MyQuEg)1gvkbDbBYv0cZv1YZNutDtLel91tAg(63ywyGjWrVRO)BAyMIgKUIiPhI4ywJoqtzvhCP(GTWD6lfKeoWdmFniMjvpdBoZ0WOGdxSVM8h6BCwTuX8SDVfop313OCZvcbzsmHyjNZs6NDhZ3E4XckEJh5BMoE4Kbd8wIgGQhzHWfWEkqKbP1wYHGTnE8CIq71vJXHsy9qXQf2wv1xCpVcY1xsvymx5Wn53imO6c3vIPGJSpXYKrQOljLf0XJCLu8j1B(ubdMCw9r5bCtOj0nmQ8TJnqtFl5CdYbLIBOwLLeHbXIjPD1FPe4FPl2F5bSAZcFOSFfy27kW)qIYMqfGxVFqDjDKXKnFrWUM6g85w41()TJ2D0TQCeCeEqXfs135Ge8zdkxrO(fxwFJMJf0AJ0QNn2zJ0up)C1NMRY5Tvyih1aucZf(8m3qAnlnajVhpk8vvIjinwUab4IloSkdJ(91We7LzWwUas95y)FaO2yAiKomCnCBJJ6ZBMmyx)(x5qRDvCM8tT3mPSNwymL8OBMvJz6nxADIRDspl7KY1Ti4SqOyaSv3DgADdfthJNn1jn2gX7QpNPDQ0Jf)v2ECGtGT8g5NlCYQ(TUkPMcN7S2BQ0YIAr9PIm5ppVty5UZnFfk4NL6c2GtsHS0n2b7z4g)5AXoOIgFgQOlyPd(ZVFSyRx0qDwUcxDPGTiu3fv3YTQwxvrrHJQlYE)RSd4Ql2SpyEVcUeuGmLsJMIotopPYvJ0jwDQk1(vhYmNxzkusw7e1A0iooRnLEOFdbv1rLpFzO241wQ6b1b9tDy2YWO9ReqSiDZOZHVNkLsL6dlfQ9myydxq8q7)E1Ok0v)nV9rV46xt1Rjyjou1s0VUfJOPySRTz5uZGzB1sXr3kH7i(WkL7gMp7rGVWECgppEHsjof)ckbF7x0)ZeiVhPZF)8zwudFz(4SMpRq2NRak32DDufG762wUlJMa3XDTDhwkK54)nlFG)DreD7(aOQemfvWi6X712ga)h6223PdpBQEUkJUkKxGg63ftndcotHRol0de2P1)4sN4zPw9rUfaPff22QUZJi6fEqKPP0FJbZFTThzLBI)LbLFZhIqdtrOlJrO(5iulfqD8lD0XL69lympYwB2XbiuFZR9FowqyezVQzKD7Kk(lihQc3wp)HA7npIKXJAgktgzbLddPWgiDKNNHofrPBwTMqP9em(2JuD(gxRa3Zxl4AnJdBjejLBy9gTF9gnWVnz5bLOzzBlb5mQEOlZbrJf3minwSMGutITw2aNAkjwdaFjmmJ5ODIS(nDC2jAM7MGOqZFyyk6L5gJ7yEdNPRykjoW8pawRIIrA4gnYNI2U3OLCSSN)sNhatxNaJUOo3OwN8G)ePeles7E1mFM((BOsazQBqOJgGwDkOfqPA3foCOFJBXQfh6UDoPK(Vv9K5pYZZPUb6OviUHapOqS79tlu5162FbN0t7g1JwI8vcTvtsUicuxMbutdb68McKwuDdGFsPQ1oP58YX)0nEDxJJ1AhIQh22Ld0MzhvD4rLMEKwC8LbaBzxlG9zzI0XXkPXPVuq2D17RgE)QnVP6g4uxN4Kw94MD9RJIW1EYU5IhDtUPH7zQ7EPUzcx6CRN3ON6YSNQo8P2iYLAuSwYBBVZChNLToY9GqtyF519LgZHivNWLN2dRzMBotRlnwUqQMdNEBhZu1fi6pZGpi6VSSB9vMU1m00RZx80sdvtVsFr0A5Xv1PT1KUWn(WbM91OMVZyqCigVZnKWPuiDCcDnOEURRfDxT6ARbkPPOpNr38QTAOEDAQETyKy1owV2oxVQd2tlW(kI2xc6gN4xJJ8Rfc4zmZVMmpCdszjfvs704a(8XKZjrYD(JV1XPa(fGQIm6312cJRTtknmlXAhM4C9ePo(Rrz(FotQ)CMuniJx8zs1jJ72Ar7DCw(sdDv18qM2A2AFrFN9EoLo1pcT2)RqdrP)7EE83IwdvTPQo7LZXL3VtxLJn3FKAZZhmojtTctU9t01Sy2(f9)X8FM66xp))c]]
)
spec:RegisterPack(
    "Fury (wowsims.com)",
    20261108000,
    [[Hekili:TV16VTTnq8)wYx8SrdKF0L(c1bODDfRfDDfXdyFtY0s02AwwYGKkEbOW)TVJuViPiLLCCcw76hAGk5X7(DhVJK3DjUJD)t3zbig29Ztgn5zJhp6fJgnYDg7UDy3z7q(BqRGpIrBHF((uYDhM3FFYEA4wQJFY2bCAUlkbfW5ZI0Wi2hIDxyKL0DyF3z)1BU5Mp8h38QLaVCNTomiaNTam13OeE1H5S14dZZhB4Yec(wm5W8a8suAe7W838LpDyom8H55lpnCixy0H7resyczyWo6q0UiyXaboWxo)nnjEWLaRjOyAea2a47eUOcPhMJccsI)j4Jn47OohM)oed9kdqO)V)H)eyYAgBh9vdhUkKToDbh1d1iDaWtaP4RqV0pycAsWsFGT)sssuqY(ykx2RwfbAjyqWuquVdJyRpm)VcPRbbCd2FteMsJH)bsffrbOUaVomgGDidgJVtDyofZyHXRGvKSCjqXDLwjUUoBpgVdMg(Irc3G5kkNbcZlb5hc8f4(BJsscYSLWIElMqXKnzC9xtj4ni(hrPXyUb6tHRwZga6YNbeffgZvbmb(jvaR04aUDsiHVKWct46kFN6D4L4yA4T4sDNBNVblui(cP8DKKyWMbMpqpyiYkmde9IeAopItyoG)hjzzye4DI8f83zhbd7alqSPlYWoM4raV4ldxoLHIWXmNWTWQUfh4PsHdogTice8hRXRNmD4cUDrWiaCEGb2BLFW0XwigXyryp66KugxWxSiD5sh5rDs3zEPK8nBp6EWQtntKpkkYlBcVOqk7sEe6uGcVDPWmBbTRCHtntmvS54HiBtiCiYj4wShogVnetLumRIZpWRWTrI2aURR3EUNlW1(l5EiEe8wuym91tf2HksCcsji(k)QcDx33pp2WeTpPVnUmCYGbdKbdrkYraN8qeQtEeQNmf9mIwzkooEnsDoInoNaZkGMMhO6rZItvD4QVxDTYE1(1HKiW1j4yeAEtf8Ci7s2dEg7XOB5hxiJSDyePczcl6fztx6CZqX(yNnXGX4RkE9ztKUtrxX)d2pLj4u(NE7wJOyJAKc6Ja4PflE5Ye)u60jcCPR69eH4rjxpDYvkq42qFwc5opsk4YMXbf7KiWhUyGqzYddNZLe6xyjSJJ(6bw9UqrtRW1ppAWx73)I(fg0k5MBoZNO0EKnSyrwxtPJP8ufUTtnSmqdg0RKHAYQIDvtOZSQz4SAWGsf8zJu9ZvCmmAbhByNemGMIIJdeoSyDRBPMWjjxjUiaNhpcdboKvBbJhjP7M8ORmNktwEIbOIvmOmwkFX9ZOwCzJ3g8owPnRIs)ekRxPuQgVqccGxfKsWOG7kMu)Sp4mGAEIM1REWvh36mwDkWXQbtrVV12x47mpUqU5TJoiznPOieLiQY3ZymOs4e09ZR7Dr)(gD7KrYvfF(6Pp)P2dbm6zd8Aa4S1bds33km(Sa93yz)zEz2o1l9vpAviTIl1lngVeotx9rft(AFl6s(WfhwKZINaOV8CIcs4NsmW2k1hnZa3BByCFoewdV6VanxckO8)FW1JCUskstZFsXnrFoWKpWI3yX7V)E82T2LtHXl(kYo47rZs9eEkplw7ql9erSQw9YdWLxGd485V51xPKMuvsqt9xZtC0qSC3pg0IianimMHj(W95njNogkvjTQ0SMkmjE8QyyqsMYDPAbhpZfd0MN3IHzuZ0scJvX98Ag0suwUGwGY60wGY6Z0ekXzfZODimJ4JJon6YrM2OnIkELvOq(ya)n5nDc5VkZYwObMOUqpmnNw(RDsDoI2uDjVuEZ53XvpHA(v(QA14R0Sixp(LxPDD80Nk)onLZwQvIKwD(tTeON228CEeEKvVMsF4AasfFFFFTDhb3)XYEQ(Mi4lxoM6MMDZ0jLu1pCcYtv7)MgIwX8kf5u8O6OEBv9o8r3zWquq8ATIHxTpQOZpzDha(8ZIobL)yv336oZNecpQjeLvyD5CMlk1oqJwfeZ4Sxw3IKpL0LbiqtaTIjvxMWzXtTWIQkblJ7wx65ZyTN5O8NTGs5lRuW5jCNU5AsFUlknxBUstBKU(I70uQD6fT2Uh01J589zwSsLjsCmg88tXFQwuiNtVWcN0Q2TYEwthmAj)bUOEPfrLNQUSiuksaFTJhDutgNk7bYnxsC3zIdH4bQw3KZk6Uqm2cNLRMEjlfByJTf(kLONGo9aijnOBftV5QPBnZ6gtT(CNB9jLCTCf1BZ(MsVke2y9WAREjNHAKEFQRBlELrdpZ4r4nJs(4wn)kqxy(1p9t3fVtpO8XUm9p07NpifQ)iLhw(AA(DpLXu8Dl9RAA(U7tPi(nkE97NS6MPvgjv3Qt4gRZzH)BQY)37s)FSA)lmJ2U7vRzaI3QQFvRvtErL)vT1NwFcQ1OGw2PG7rRcE47vqtnlqyQ1FVsDV5623VpVvVLDsqy1S98l5kU))bBMYbx1AZGWuz7zNkjOkzQSQXn1)bx(txNv(ROLPmQpUJD7CamLm9XpFQH0NT5Zy8xAT2KHR0jP6VZSG0gZstP)kzwwLnRgmU22uBZwNKmnibR5ej6W05i5W2UPw2UjZcTRNdNP)svAPdkFvNHoALxm1kQZyVO6IbSQtrhh1gAn1zS3uMclTH6SUiDueR3QQZqVQmfZBfLsD8r1)8ekZL5wxDU7DLPZP6S6D6TY6(0lltnZklEUELUASiVpkp0)eQ3(jMdzxH33Yftq)uVhYAj8dVKhGguDETfTJ7vQsLNv58Q1Tv)(jj)RoAbSQNhddIt0qPS18h19B4nHrHhM3)95)X1iM29Fp]]
)
spec:RegisterPack(
    "Arms (wowsims.com)",
    20261110000,
    [[Hekili:TZvBVTnos4Fl5dNRnAxfBN6Ux7vhGTx3fBpS3UlQlq)MvKLOJ5gzjbrP4ZhcYV9Bgs9cjTiLKTtWIEBbsQTi1mpZlCMHKdYYjl)YYfbEzKL)60XtFZKjtgd)B5IS9jKLls88VZ7w4drEBHF)dPBzpEZWDX7y0Tmh)4TJW5Spm2laPZQCAy2NIwUQrsYsi(lx81F4ZF(t)2NFNhqRLl2qdciIxGW8BKdV7XBY2qE8MIND564uY9K0hVjGS2lpm7XB(HF)xE8g4XWNeVEo9sKzSl35LMsJtVmiHDPxsi8lycoWNC(dwC0OxbKo1lIfcGna(CmYkkqbVGG4OxaF4oYEMZJ38rVmV31aeg(V)0xaISjllH9UlV8wA2M8viQVuBQJaAciLmZ7T(bt9MgS2hi7)moomiExed59T3gcsjOqimGvFK4LT5XB(kLTbyWNj(3fsySi4hGREHmaQRiBOraSPzWZql1J3Wizz0OBH3iE9Ayg7R0sOSUyhHKaddFklLEhbfuKaC1BQNpfOlq9peghdp9NYt3dV0hiPms6DcQ(J5PK78WpeMhrqf0VqVDt2iqw(csesuWTGNcahuTtZ2JQsVeeGEWp7JZF8MqIxAe89v0qAgLGQ3FlHe9D7Itdb2MKhIOiNHKZlnKI65ptqCYblyyX)lKRjsbNtqwrYLUfDayzGEaj5x3qr1ziO8d5Imo6AeSIVLNfehNYqbefxbHw7Dp8m4TI3jOTdYAqcwXnneVq0MSnNLHAFHjfeh8RVz2F7FWTEG7C9uPWNbVHvft8EuLtr)Gq6TuGOoLIg7oAc6UfbEdaTdjKGVJUDlOKbZJx6TKSsJ1kualTVPuY6qujVodvtEW7w(wPegFXbcHF)(FevjuesFKSMeXOCOqIqjl4vfQ7psaDOxi9)k8r2akjHnyVqhxO0kSraf)zVTmWtcNnd0zafJIJ(UvXOPb4jOhY36fftdycCSLacgQzJqT9UnOQcC(2JiHla)4)H4NNvofNcQKNHUk7X14Hc2aosWS)e(sP5jv6gzztSGIX1WzGq5Lr5(j8LoveQAfOdeilnEn40SCHNpoxMtskry8MVsSiGK6IEfVIUEoqsaZo0TWBDpjWvDgofA2h)xhqRxo)sFVWqxXaUHuw2RWORZHz4IkwxWhoYN08RUQ0z9vGfZfCcCV1py(eeryOn3QXDzERnrdVSSqycO9fFXlwLVETJ8tDYtokKVfufvV4C2gkje0mEqiSs8LCpXv4ppqq0Rhpq8DNDG7jnA2Glk(oGdgemC2GachG(W6mWvdWM(tUF68XvSfqzs(wWt75LNIv8SS4iDttaLLe6Th8qaxU5xn2gUKPyH6BhOY1OX0zwLTHxiiItiGvU3uGdpWYdclT0JZtgjZY6rSldDK)ssGcaKFUgcUN6NfNU3nnhCAwh7NZKCUJHq)U80enQWA8Dvr(3Bh5xOXgDdmy4DtIXNyv)8AR24bd5jLE)Bg)Gg7u0eP1rT0j)mBAKwDTfbgDcQIvoazkGtsezlKp(65t7Pl0jzXdKs6uhtQBs3KX6Ih8KdLVliI0kUjB8yKYvYhYyhmtGInVm)2jfl5cmHy1JPqqA87fF1pfk0dQQYfl4E(lkty(IbnI5kaDauBoYmlpkasjXloIldkw65tgCXqDnn)7G6inJhtFu7mXpWTS4rf7kuaR7oQi4)qEPxUPKTE0i27NxybkNItqEk3v)bL5D9q)I8Znn3xo0evUC6OrAlMQRFMdNHfvkZCkku3vEkdoyuroz3a83G)EtsJmbAxEAC2fsuJJXLjfHIvuoVltunFdLeOUWEsBrlLhh8yGaqf0gjMvDI8BwwjbF4dbvd6EzkPVATk2sDfwIPxeGru8I(ykrLuauXRvziuhSYKoE0ObCsdL0KMeVdlSd2jWESuGgFEPjgKZYppGxkyy81ZNvdMQ3thi1dOaIHIKs4geaoff8WfwvFpya0kEovdlNID4qZQRbqjE37mrDOrpytdp4VSZ9XoJw6)mGJ2DtSPTv2jrLfsj4GMfSP4ddT7IFy9ks(a72qtd3rRQxPsCRhGR)a9DL2A6SbsArqnm4cJEBYYsfjf6L(cARrBTtnfnAlBjSFLGwQvE)8jZgyBlL8SQGOlCnMATOnTqygkidh6G6AyHEBvC7u0ufg5IHW5Y3G27BCUGAz03K5PQiaxdkEpzDA1KLNgQnQxcmz8ttMgDxK))njZ5XiHe68qj9fLwTAgvJDohWGUHqlGQosGbW0Lidxp3yOHbiM2aBPTQA95vpHLGhi7WXVCSZvAfHNq8sRlc)CKHSLWsTKN5Ig5aSrV2EXdtqDmzvFAcJ0HQgSlChHnPqt2q9ydvCaFy4blhBYz)ADF9rMRLOZ5(lac(okyszt78lEqtJjV4wZWpPomXRhps9iWsJP(LE6gjOXYa0oAHbMx3Qh3wfIZLG4BMDeiupesf1El)aLupzFESJIZZVVoLptl6mxVQwHTJ6yHJLfb(2XTvd4kTlty4qRXJRKb1bRI4Ao6CpvLVF6OQfMAkYbnQivbq9iILQduIrWpSWkT6KJAvszf4YvjRhhrjrJ(r515vzA1E39vDfrXK5SddVGv9R(OtcSngpukKZdd1pg(hufbP6yUsv1NTrav)qVeL4OOLkd(XvEg2vffcV8liFTynyrSroJQY3pRpNbRJ2LeoVLIfmumqBlLoxPWBc44Deo3FdUH0MkUPqh2900gybyFO41d7tsYSXNEUpGAUvFQ3Z5rhDxJ9lXHCQPJkU(fA)GIByUfhtCdJOEW3sySoDfEBgDeLvVqhq5HZTeLhoInuseDys3qOyYTJoT5vGmTNAfvy7UWCdr63K30tW1jiZYoiHnn7s5SPX0UoHEjUNO0wNNt6AoeR7UOOSzPbWkXvL6jZ00yxp5TZEqthEL8zzQe39Glf7uJnVCbe5Jb8rRF3WBiJXBVorlybF8x5TBxrXKl)qzRMSCHuVsSCHFkfICr9GHp27CSt9VWYmaXgaKOhkEEXYvAyr5AVHHh3f4SCHKdlQWRejPw0a52RTZTPZoW6GxFDxGGLRpVX7phrZSwK9z9JXhEr8nFt8M1w1qeH3B0GNgwAOo0AkjFtJlxWRie5eq1V3Uq)9ZALiDrPOxojY5)UDo)6o5QjDm6hCo62DdPvnsccM32cyKudsDfsxmcTU280AgKE3nigCcbDWKXgceDyBA0Fb)POpr4G2u48Q(0OtUrTzKEYAGeUmONbqcW(9UBrQvb69kIiFOROrYLZ1YbHEO)orL6Aw40qpGEThuzdIilCDUJuoJTKchM6r6RxAxx1JcqpXYT6EVQCUBwfU4QN5Wuyr9UzXSJ418Cht0tE0E6Mj6r9lFfLDSlZyR6woj1JDBs8u23AlMxL9I3ZBW6yVcRoDhwg2N)5TbfARdfo80jA74jmE(e8cG1t8iBAmRWmCzLpR3w53(26NTUIPnGuVqUAC1ylt1lfqYnYQTqyd1pvR25NEABJbE0CpuDWB7KapOAql3pXzVxB4YPPkdQ4HQQUVIdNhMQCWyEb7SHtt908gTpLxTsNkv0YooARZD4OQ)7JRVnVJCbnOXPWPDkN9MYzJ3XwJlzA6oK6r7(WzQEw)VPtr3uZHCmDhYzojREzs)vs2ZP1YuxbDeKsF5UTLZxzP0P(0XqN1wgYkGnE8Rhe)Ph9y0tttgXXRPtNvRRJo5QnqEPNOT)Hj)ZqNj1Vwt6KcQDLEzdhvjyTEtS92A25gx647CjU4B6GmASYSwly6k9stkjxbMLjMIyWFz9clKuWAEpQT3Ku8bJMprduXzJEPeDO8jTti7m10tDb3k9Lbh(wYcF0De1rHKxRN54Ow68Cf4O7Txfx20tY0Rk)T35vC6BkPWkPUtsxpzl91ZApz9m2uwCLLEwTA1sxAaRJZ5202jvo17Jk2H2oX6ESelTYfhY6XYL2QRfMO02wn03wwBCRJt3AklHCFA1yEh0V4S0cyCyyCJSgmX24ZP1)baCYW)2vu8hPHLwAYG6ay6rD0JWRoZYy98DYzG2wVOgTUwJNl6ucsAkYypdm24F4lqczQYMUjKy7NjSkkEd26(ddEnNjpdjy1aimw2dVh9ohBTORhvzvd71mt77(ZfYV0Le2dHVU36uWsxBMVZy381hfyDV21oQBO5(oJD3xFwIl6dVwrSEZ(Dg62VMcAyeLs9eNQ)5tW9Z2CZ)DU7(VMc11BX)eL(6AUoOzapLUbSP2bulEyrUO(euW0jFCUAZ6J(4ieYgiDE5zBWCi)m5oAi9XBg(tf)9NJp8Y)3p]]
)

-- The hand-built lists the wowsims.com packs replace (wowsims packs plan, P9): a saved choice of one falls back to the
-- spec's default.
spec:RetirePacks({ "Arms", "Fury", "Protection" })
