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
-- upstream Hekili's TheWarWithin/WarriorArms.lua; the priorities are translated from wowsims/forever's APLs (MIT,
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
local ceil, floor, max, min = math.ceil, math.floor, math.max, math.min

local function plain(value)
    if not issecretvalue(value) then
        return value
    end
end

-- The class kit and one spec a talent tree (ids the core's: Arms 100011, Fury 100012, Protection 100013; the client's
-- one pseudo-spec, 1491, only keys the legacy profile the core migrates). Icons are the DB2 talent tabs' (wowdb
-- TalentTab.SpellIconID), numeric: Options formats them with %d.
local spec = Hekili:NewClass("WARRIOR", {
    supportsLeveling = true,
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
local IMPROVED_DISARM = { [0] = 0, 7, 13, 20 } -- the cooldown cut by Improved Disarm's rank
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
-- Forever). Unbridled Wrath: 1 rage a proc with any weapon (owner L1419, wowsims ab0f00e4fc: the Arms log's two-hander procs
-- all give 1.000) at 11.9% a rank: 59.5% at 5/5, measured in game over
-- 5,252 landed swings, strikes, Heroic Strikes and Cleave hits (wowsims EV-0148, build 1.60.1.70938; owner ruling L1397
-- (3); wowsims's own ladder is the tooltip's 12% a rank); the belief cannot see a proc, so its floor counts none: the
-- swing entries pass the expected rage as their value's `width`, a strike's `now` as its gain's spread. The two-hander flag is Hekili's gear scan (main_hand.size from C_Item.GetItemInfo's equip location on
-- PLAYER_EQUIPMENT_CHANGED, and the belief's own read of the same answers; the Forever API data marks neither it nor
-- GetInventoryItemID secret). The helpers below run in the file's environment: the entry functions, which run in the sim's
-- `state` and the belief's context both, read those names and pass them in.
local WRATH_CHANCE = 0.119 -- a rank
local function wrathRage(rank)
    return WRATH_CHANCE * rank
end

local function mainhandWhiteRage(size, baseSpeed, currentSpeed)
    return (size == 2 and 4.5 or 3.46) * (baseSpeed > 0 and baseSpeed or currentSpeed)
end

-- Rage from damage taken: wowsims/forever's rule (MIT, sim/core/rage.go:11-49 and 91-103; owner ruling 2026-10-25,
-- "stick with wowsims": armor does not change it): 2.5 x (1 - A) x the hit before every mitigation / c, A and c by the
-- attacker's level only (our health, level and armor play no part), x 2 under Berserker Rage
-- (sim/warrior/berserker_rage.go). A partly blocked hit gives the rage of its unblocked amount; a hit blocked in full
-- gives none (rage.go:112-115; 6 of 6 in wowsims's in-game logs, 144ca5865f). The client
-- reports the hit after armor, so the pre-armor amount is rebuilt as post / (1 - armor / (armor + 400 + 85 x attacker
-- level)), the armor the belief's out-of-combat cached armor times the armor buffs it sees on us (ARMOR_BUFFS), the
-- block value the cached one. Defensive Stance's 10% and Shield Wall's reduction stay off: rage is from the hit after
-- the defender's multipliers (owner ruling W2 2026-11-02, wowsims b3784e45b6; supersedes 2026-10-16). Shield
-- Specialization (a 20% chance a rank to gain 5 on a block) and Master of Defense (50% a rank on a dodge or parry with a shield) as their
-- expected values, the band carrying the spread (tooltips read in game 2026-10-16).
local TAKEN_RAGE_FACTOR = 2.5
-- A by the attacker's level: wowsims's measured rows at e4ef929e54 (rage.go:34-46: 21.8% up to 38, 40% from 63),
-- interpolated between two rows.
local ASSUMED_LEVEL = { 38, 42, 44, 46, 47, 50, 55, 59, 63 }
local ASSUMED_REDUCTION = { 0.218, 0.239, 0.31, 0.36, 0.377, 0.38, 0.381, 0.38, 0.40 }
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
local lastIncomingSwing = 0
local warriorPlates, pullFirstSeen = {}, {}
local pull = { updated = -1 }
local area = { updated = -1, count = {}, visible = {}, engaged = {} }
local recovery
-- Each fight learns its own mobs' hits: a full block before the fight's first unblocked hit estimates 0.
spec:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    unblockedAvg = 0
    for guid in pairs(pullFirstSeen) do
        pullFirstSeen[guid] = nil
    end
    pull.updated, lastIncomingSwing = -1, 0
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
                return mainhandWhiteRage(weapon.size, swingBase(1), mainhand_speed)
                    + wrathRage(talent.unbridled_wrath.rank)
            end,
            -- Unbridled Wrath's part is a roll the belief cannot see: its expected rage is the value's half-width, so a
            -- swing's floor counts no proc and its top a whole one (5/5; L1456 i, no optimistic proc modelling)
            width = function()
                return wrathRage(talent.unbridled_wrath.rank)
            end,
            crit = function()
                return mainhandWhiteRage(weapon.size, swingBase(1), mainhand_speed)
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
                -- -1 is the source's plain sentinel for hidden damage. The block kind still proves eligibility
                -- for Shield Specialization below; neither invent damage nor train its average from the sentinel.
                if (kind == "WOUND" or kind == "BLOCKED") and amount >= 0 then
                    local post = amount
                    if kind == "BLOCKED" then
                        post = post + stat("GetShieldBlock") -- the unblocked amount
                    end
                    gain = rageTaken(post, attacker, level, reduced, armor)
                    width = TAKEN_SPREAD * gain
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
                    + wrathRage(talent.unbridled_wrath.rank)
            end,
            width = function() -- Unbridled Wrath's roll, as the main hand's
                return wrathRage(talent.unbridled_wrath.rank)
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
            -- Improved Bloodrage (12301): +25% a rank on each tick too (wowsims bloodrage.go:21-23)
            value = function()
                return 1 + 0.25 * talent.improved_bloodrage.rank
            end,
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
    -- Simulation-only marker. Attack changes the real client's autoattack flag, not an aura; this marker keeps
    -- one forecast from recommending Attack repeatedly while the live flag has not changed yet.
    warrior_autoattacking = { duration = 3600, max_stack = 1 },
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
        copy = { 1324556 }, -- the CDM item's spell
        duration = 5,
        max_stack = 1,
        debuffRetryDelay = 30, -- A refused stun can be temporary; never blacklist this target for the session.
    },
    death_wish = {
        id = 12328,
        duration = 30,
        max_stack = 1,
    },
    deep_wound = {
        id = 23255,
        copy = { 23256, 412609 }, -- 412609: the CDM item's spell
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
        copy = { 1324558 }, -- the CDM item's spell
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
        max_stack = 3,
    },
    -- Gore Drinker's heal buff (the talent's trigger): 3 charges, 8 s, from the five abilities the tooltip names.
    gore_drinker = {
        id = 1323969,
        duration = 8,
        max_stack = 3,
    },
    hamstring = {
        id = 1715,
        copy = rest(HAMSTRING),
        debuffRetryDelay = 15, -- Wait one slow duration after a matched immunity on this target.
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
    -- Bloodthrill's own aura (1289681), the buff the CDM links; its proc opens the overpower_ready window above, which
    -- the plain usability read observes. Declared for the CDM mapping only: never applied. The 5 s is unsourced:
    -- it matches the Overpower window 1282733 (1289681 is not in the pin's spell data).
    bloodthrill = {
        id = 1289681,
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
        debuffMechanic = "bleed",
        debuffImmuneNPCs = { 114 }, -- Harvest Watcher, verified in WoW Forever.
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
        max_stack = 30,
    },
    -- Revenge's window from the block, dodge or parry on us in the combat log, while Revenge is usable (reset_precast).
    revenge_usable = {
        id = 5302, -- Defensive State, wowsims G/revenge.go:19-26: the same 5 s window
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
        copy = { 1324551 }, -- the CDM item's spell (Improved Shield Bash, "Silenced")
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
    -- A shaman's Windfury Totem raid aura on us (its three ranks). Its proc is a weapon strike (10610, wowsims
    -- core/buffs/drivers.go): main-hand weapon damage on the special's table, no extra swing and no swing reset; a landed
    -- strike pays rage as a main-hand swing does (rage.go:155, SpellFlagSwingRage). The belief does not pay that rage:
    -- the strike is a target row, secret live (shortcut: upgrade if a strike row turns plain).
    windfury = {
        id = 8515,
        copy = { 10609, 10612 },
        duration = 300,
        max_stack = 1,
    },
    -- Weaponmaster's three branches (talent 1290261; wowsims talents_arms.go:276-384 registers one aura each, tags 1/2/3 of
    -- the one spell id, so ours are id-less): up while the talent is known and either hand holds the branch's weapon kind
    -- (the gear scan's main_hand.sword and kin), applied at reset_precast. Display and custom priorities only; the sim-only
    -- auras are not tracked by the belief. Axe/polearm crit and mace/staff armor ignore are damage-only effects no
    -- priority consumes. The sword branch's extra attack (a chance roll on a landed melee hit, Whirlwind/Cleave once a
    -- cast, none from Sweeping Strikes; Windfury Totem's strike rolls it as a white swing does) stays unmodelled: the roll
    -- is unseen, and an observed
    -- extra swing already pays its rage through the swing rows. Needs in-game check: whether PLAYER_SWING fires for it.
    weaponmaster_axe_polearm = { duration = 3600, max_stack = 1 },
    weaponmaster_mace_staff = { duration = 3600, max_stack = 1 },
    weaponmaster_sword = { duration = 3600, max_stack = 1 },
})

-- A stance change drops all rage above the amount kept by Tactical Mastery and its improved talent.
spec:RegisterStateFunction("swap_stance", function(stance)
    removeBuff("battle_stance")
    removeBuff("defensive_stance")
    removeBuff("berserker_stance")

    capResource("rage", stanceKeep(talent.improved_tactical_mastery.rank))

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
local overpower_ids, rend_ids, sunder_ids = {}, {}, {}
for _, id in ipairs(OVERPOWER) do
    overpower_ids[id] = true
end
for _, id in ipairs(REND) do
    rend_ids[id] = true
end
for _, id in ipairs(SUNDER_ARMOR) do
    sunder_ids[id] = true
end

spec:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
    local rowT, subtype, _, sourceGUID, _, _, _, destGUID, _, _, _, actionType, _, _, spellMissType, blocked =
        CombatLogGetCurrentEventInfo()

    if destGUID == state.GUID and (subtype == "SWING_DAMAGE" or subtype == "SWING_MISSED") then
        lastIncomingSwing = GetTime()
    end
    if
        sourceGUID == state.GUID
        and subtype:match("_MISSED$")
        and (actionType == "DODGE" or spellMissType == "DODGE")
    then
        enemy_dodged = rowT -- the row's own time: a held avoid's row arrives late (R46), its dodge is still this old
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
        last_overpower = rowT
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
    if plain(IsCurrentSpell(6603)) == true then
        applyBuff("warrior_autoattacking")
    elseif buff.warrior_autoattacking.up then
        removeBuff("warrior_autoattacking")
    end
    -- The stance comes from the belief's Forms source (Game/State/Sources/Forms.lua) through the aura walk.
    local hs, cl = knownRank(HEROIC_STRIKE), knownRank(CLEAVE)
    if hs > 0 and IsCurrentSpell(HEROIC_STRIKE[hs]) then
        applyBuff("heroic_strike")
    end
    if cl > 0 and IsCurrentSpell(CLEAVE[cl]) then
        applyBuff("cleave")
    end

    if talent.weaponmaster.rank > 0 then
        local mh, oh = main_hand, off_hand
        if mh.axe or mh.polearm or oh.axe or oh.polearm then
            applyBuff("weaponmaster_axe_polearm")
        end
        if mh.mace or mh.staff or oh.mace or oh.staff then
            applyBuff("weaponmaster_mace_staff")
        end
        if mh.sword or oh.sword then
            applyBuff("weaponmaster_sword")
        end
    end

    if now == query_time then
        if knownRank(OVERPOWER) > 0 then
            if
                enemy_dodged > 0
                and query_time - enemy_dodged < 6
                and target.unit == enemy_dodged_target
                and enemy_dodged > last_overpower -- a dodge after our last Overpower (an earlier one was spent)
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
    if casting.up and casting.v2 == 0 then
        -- The hostile cast end is modeled. Use the next real GCD for a current interrupt opportunity.
        if state.prot_pve_target or state.warrior_pvp_interrupt or state.spec.fury and state.warrior_field then
            return state.cooldown.global_cooldown.remains
        elseif state.spec.arms and (state.level < 60 or state.arms_open_world) then
            return 0
        end
    end
    return state.timeToInterrupt()
end

-- A landed Heroic Strike or Cleave (wowsims talents_fury.go:65-87 and :374-420 at ab0f00e4fc; EV-0148, EV-0138): it
-- rolls Unbridled Wrath (its expected rage; the floor gains none, as no proc is seen). Paid at the cast, which
-- comes with its swing (onNextSwing): an `onLand` would idle on live (target rows secret). Its own avoid
-- (strikeAvoid) takes the estimate back. Reckless Swings remains unmodelled (CN15). Its Flurry charge
-- (one a cast, landed or not) is not modelled: the belief reads the swings live.
-- shortcut: one Unbridled Wrath roll a Cleave, as on one target (wowsims rolls each target it lands on: a second target
-- is a roll short, the low side); upgrade with the belief's enemy count if a pack line reads rage after a Cleave.
local strikeWrath = 0
local function strikeNow()
    strikeWrath = wrathRage(talent.unbridled_wrath.rank)
    if strikeWrath > 0 then
        gain(strikeWrath, "rage", strikeWrath)
    end
end
local function strikeAvoid()
    if strikeWrath > 0 then
        spend(strikeWrath, "rage")
    end
    strikeWrath = 0
end

spec:RegisterAbilities({
    recover_threat = {
        name = L["Recover Threat"],
        texture = Hekili.TargetSwapTexture,
        unlisted = true,
        targetSwap = true,
        targetSwapSafe = function()
            return recovery.safeLanding()
        end,
        gcd = "off",
        startsCombat = false,
        usable = function()
            return state.prot_recover_threat
        end,
    },
    auto_attack = {
        id = 6603,
        texture = 135274, -- INV_Sword_04: the same Attack artwork with every equipped weapon.
        cast = 0,
        cooldown = 0,
        gcd = "off",
        startsCombat = true,
        known = knows({ 6603 }),
        nobuff = "warrior_autoattacking",
        usable = function()
            return state.warrior_start_attack, "requires an eligible melee target with autoattack off"
        end,
        -- Only predict the result. The player starts autoattack with the real Attack action; no live command is run.
        handler = function()
            applyBuff("warrior_autoattacking")
        end,
    },
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
            capResource("rage", stanceKeep(talent.improved_tactical_mastery.rank))
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
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
            if talent.improved_berserker_rage.enabled then
                gain(5 * talent.improved_berserker_rage.rank, "rage")
            end
        end,

        handler = function()
            applyBuff("berserker_rage")
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
            -- wowsims spell data curve {50, 100} tenths: 5 / 10 rage (the DB2's 100 on rank 1 is not it; wowsims wins)
            if talent.improved_berserker_rage.enabled then
                gain(5 * talent.improved_berserker_rage.rank, "rage")
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
            capResource("rage", stanceKeep(talent.improved_tactical_mastery.rank))
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
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
        end,

        handler = function()
            -- 12301 (in-game tooltip): +25% of the rage Bloodrage generates a rank.
            gain(10 * (1 + 0.25 * talent.improved_bloodrage.rank), "rage")
            applyBuff("bloodrage")
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
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

        now = function()
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
        end,

        handler = function()
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
        end,
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
        -- no damage (DB2, wowsims charge.go): its ticket takes its own avoid only. The stun lands when the charge
        -- arrives, so its speed widens the verdict's window for it alone (cdm-facts fix round 1 I3).
        -- shortcut: 21 yd/s is Feral Charge's (one 863 ms sample, Druid.lua), borrowed, unmeasured; upgrade with a probe
        -- pairing distance with the stun's light
        expects = "debuff",
        velocity = 21,
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
        now = strikeNow,
        onAvoid = strikeAvoid,

        usable = function()
            if weapon.size == 0 then
                return false, "requires a melee weapon"
            end
            return not buff.heroic_strike.up and not buff.cleave.up, "a strike is already queued"
        end,

        handler = function()
            applyBuff("cleave")
        end,
    },

    concussion_blow = {
        id = 12809,
        cast = 0,
        debuffApplication = "concussion_blow",
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
        priorityInterruptRange = { 0, 5 },
        priorityInterruptStun = true,

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
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
        end,

        handler = function()
            applyBuff("death_wish")
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
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
            capResource("rage", stanceKeep(talent.improved_tactical_mastery.rank))
            applyBuff("defensive_stance")
        end,

        handler = function()
            swap_stance("defensive_stance")
        end,
    },

    demoralizing_shout = {
        id = 1160,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        areaDebuff = { aura = "demoralizing_shout", radius = 10, melee = REND },
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
        id = 676,
        expects = "debuff", -- no damage (DB2, wowsims): its ticket takes its own avoid only
        missable = true,
        cast = 0,
        -- Improved Disarm (12313): -7 / -13 / -20 s (the pin's spell data curve)
        cooldown = function()
            return 60 - IMPROVED_DISARM[talent.improved_disarm.rank]
        end,
        gcd = "spell",

        spend = function()
            return offensive_cost(talent, 20)
        end,
        spendType = "rage",

        startsCombat = true,
        refundOnAvoid = true, -- wowsims disarm.go; DB2 Discount Power On Miss
        known = knows({ 676 }),
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
        -- An avoid costs the base rage alone, none of it back, and keeps the extra rage (wowsims execute.go at e4ef929e54,
        -- 7025f28b98: 36 avoided Executes in in-game logs), so no `refundOnAvoid`; the extra the `now` below spent
        -- comes back on the avoid (L1237).
        refundNowOnAvoid = true,
        known = knows(EXECUTE),
        nobuff = "defensive_stance",
        healthGate = 0.2, -- usable at or below 20% of the target's health: the belief's target health reads it

        usable = function()
            if weapon.size == 0 then
                return false, "requires a melee weapon"
            end
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
        debuffApplication = "hamstring",
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
        -- The belief pays at the main hand's next swing. Forward simulation reserves the cost at the press
        -- and suppresses that swing's white Rage. Cleave uses the same queue behavior.
        onNextSwing = true,
        known = knows(HEROIC_STRIKE),
        now = strikeNow,
        onAvoid = strikeAvoid,

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
        -- The stun lands when the charge arrives: Charge's velocity (cdm-facts fix round 1 I3). Its damage is the stun's
        -- (wowsims intercept.go), at the arrival; the ticket takes its avoid only, so the stun's own wound (a secret
        -- amount on live: background) or crit row (routed by kind) goes to nobody's ticket.
        expects = "debuff",
        velocity = 21,
        cast = 0,
        -- Improved Intercept (20504): -5 s a rank
        cooldown = function()
            return 30 - 5 * talent.improved_intercept.rank
        end,
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
        usable = hasMeleeWeapon,

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
        debuffApplication = "piercing_howl",
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
        priorityInterruptRange = { 0, 5 },
        readyTime = interruptReadyTime,

        handler = function()
            interrupt()
        end,
    },

    -- Fury talent (1329555, new at 4b0030a44b): 15 s cooldown, a 1 s GCD, 25% of base health (unsimulated, like
    -- Bloodrage's: the player's health is secret) for 4 charges in 8 s; each white swing spends one and gives 5 rage.
    -- Do not grant the four swings' 20 rage at the cast. Their live and forecast bonus remains unmodelled until
    -- resource models share a bounded charge budget that respects late swing settlement and later resource pins
    -- (CN15). A plain gain() from a landed-swing reaction would double-count a bonus already included in a later pin.
    -- Actual rage/usability observations still reconcile the pool through the ordinary resource model.
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
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
        end,

        handler = function()
            applyBuff("reckless_swings", nil, 4)
            if talent.gore_drinker.rank > 0 then
                applyBuff("gore_drinker", nil, 3)
            end
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
        debuffApplication = "rend",
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
            applyBuff("retaliation", nil, 30)
        end,

        handler = function()
            applyBuff("retaliation", nil, 30)
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
        usable = hasMeleeWeapon,

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
        priorityInterruptRange = { 0, 5 },
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
        -- Improved Shield Wall (12312): -330 s a rank (the pin's curve, 900 -> 570 / 240; the 240 is unmeasured in game)
        cooldown = function()
            return 900 - 330 * talent.improved_shield_wall.rank
        end,
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
        usable = hasMeleeWeapon,
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
        usable = hasMeleeWeapon,
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
        usable = hasMeleeWeapon,
        form = "berserker_stance",
    },
})

-- The rage a stance swap would leave (swap_stance's rule: the rage now, up to what is kept), for a priority's guard:
-- Tactical Mastery is a passive, which no priority can read (Fury's overpower_weaving guard, the user's ruling
-- 2026-10-21).
spec:RegisterStateExpr("stance_rage_limit", function()
    return stanceKeep(talent.improved_tactical_mastery.rank)
end)

spec:RegisterStateExpr("stance_rage_kept", function()
    return min(rage.lo, stanceKeep(talent.improved_tactical_mastery.rank))
end)

-- Arms field play leaves a deliberately equipped tank setup in its chosen stance.
spec:RegisterStateExpr("arms_shield_stance", function()
    return action.defensive_stance.known and buff.defensive_stance.up and equipped.shield
end)

-- A four-target Whirlwind can justify losing up to a base Slam's 15 Rage. Check retained Rage
-- before swapping. A Warrior already in Berserker can use all available Rage for Whirlwind.
spec:RegisterStateExpr("arms_whirlwind_ready", function()
    if
        not action.whirlwind.known
        or action.whirlwind.disabled
        or not action.berserker_stance.known
        or not cooldown.whirlwind.ready
        or weapon.size == 0
        or state.warrior_nearby_enemies < 4
    then
        return false
    end
    if buff.berserker_stance.up then
        return rage.lo >= action.whirlwind.cost
    end
    return not action.berserker_stance.disabled
        and not state.arms_shield_stance
        and state.stance_rage_kept >= action.whirlwind.cost
        and rage.hi <= state.stance_rage_limit + 15
end)

spec:RegisterStateExpr("arms_resume_battle", function()
    return action.berserker_stance.known
        and buff.berserker_stance.up
        and rage.hi <= state.stance_rage_limit + 15
        and not state.arms_whirlwind_ready
end)

-- Fury can keep its early Battle Stance attacks if the Berserker quest is incomplete, or if
-- Whirlwind or its stance is disabled. Already being in that stance still grants access.
spec:RegisterStateExpr("fury_whirlwind_available", function()
    return action.whirlwind.known
        and not action.whirlwind.disabled
        and action.berserker_stance.known
        and (buff.berserker_stance.up or not action.berserker_stance.disabled)
end)

local function furyAttackDelayed(key, horizon)
    local ability = state.action[key]
    return not ability.known
        or ability.disabled
        or state.cooldown[key].remains >= horizon
        or state.rage.timeToLo(ability.cost) > horizon
end

spec:RegisterStateExpr("fury_overpower_opportunity", function()
    if not action.overpower.known or action.overpower.disabled then
        return false
    end
    if not state.fury_whirlwind_available then
        return rage.lo < 25
            or (action.battle_stance.known and buff.battle_stance.up and action.rend.known and debuff.rend.up)
    end
    if rage.lo >= 25 or state.execute_phase or state.warrior_nearby_enemies > 1 then
        return false
    end
    -- Leave the next GCD for a core attack if a swing can fund it before then. This also
    -- allows the 1-second shared stance cooldown to finish before Berserker is needed again.
    return furyAttackDelayed("whirlwind", gcd.max) and furyAttackDelayed("bloodthirst", gcd.max)
end)

spec:RegisterStateExpr("fury_overpower_window", function()
    return action.overpower.known
        and not action.overpower.disabled
        and buff.overpower_ready.up
        and rage.lo >= action.overpower.cost
        and cooldown.overpower.remains < buff.overpower_ready.remains
end)

-- A queued Heroic Strike/Cleave replaces the white hit. Budget for its normal main-hand
-- Rage as well as the listed cost when deciding whether the available Rage is surplus.
spec:RegisterStateExpr("warrior_mainhand_rage", function()
    return ceil(mainhandWhiteRage(weapon.size, swingBase(1), mainhand_speed))
end)

spec:RegisterStateExpr("fury_maintains_rend", function()
    return action.rend.known
        and not action.rend.disabled
        and state.settings.wowsims_rend_weave
        and buff.battle_stance.up
        and not state.arms_skip_rend
end)

-- Before the core attacks are learned, an armor GCD leaves Rage for an Overpower proc or an imminent Rend.
spec:RegisterStateExpr("fury_sunder_reserve", function()
    if state.fury_whirlwind_available or action.bloodthirst.known then
        return 30
    end
    local reserve = action.overpower.known and not action.overpower.disabled and action.overpower.cost or 0
    if state.fury_maintains_rend and debuff.rend.remains <= gcd.max then
        return max(reserve, action.rend.cost)
    end
    return reserve
end)

spec:RegisterStateExpr("fury_heroic_reserve", function()
    if not action.rend.known then
        return 0
    end
    local reserve = max(state.fury_maintains_rend and action.rend.cost or 0, state.fury_sunder_reserve)
    return state.warrior_mainhand_rage + reserve
end)

spec:RegisterStateExpr("fury_wait_for_bash", function()
    return state.toggle.interrupts
        and debuff.casting.up
        and debuff.casting.v2 == 0
        and equipped.shield
        and action.shield_bash.known
        and not action.shield_bash.disabled
        and cooldown.shield_bash.remains <= 1.5
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

local function hostileTarget()
    return plain(Facade.UnitExists("target")) == true
        and plain(Facade.UnitCanAttack("player", "target")) == true
        and plain(Facade.UnitIsDeadOrGhost("target")) == false
end

spec:RegisterStateExpr("warrior_pvp_target", function()
    if combat == 0 or plain(Facade.UnitIsPlayer("target")) ~= true then
        return false
    end
    local _, instance = Facade.IsInInstance()
    return (instance == "none" or instance == "arena" or instance == "pvp")
        and hostileTarget()
        and plain(Facade.UnitAffectingCombat("target")) == true
end)

spec:RegisterStateExpr("warrior_pvp_interrupt", function()
    return debuff.casting.up
        and target.within5
        and not target.outside5
        and state.warrior_pvp_target
        and Facade.TargetCastInterruptible()
end)

spec:RegisterStateExpr("arms_pve_target", function()
    return isPvE() and hostileTarget() and plain(Facade.UnitIsPlayer("target")) == false and not target.is_dummy
end)

-- Short outdoor pulls need a different rage budget than sustained fights.
spec:RegisterStateExpr("arms_open_world", function()
    return isOpenWorld() and state.arms_pve_target and not boss and not target.is_boss
end)

spec:RegisterStateExpr("prot_pve_target", function()
    return state.spec.protection and isPvE() and hostileTarget() and plain(Facade.UnitIsPlayer("target")) == false
end)

spec:RegisterStateExpr("prot_contextual", function()
    local _, instanceType = Facade.IsInInstance()
    return state.prot_pve_target and not target.is_dummy and instanceType ~= "raid" and not Facade.IsInRaid()
end)

spec:RegisterStateExpr("warrior_field", function()
    local _, instanceType = Facade.IsInInstance()
    return state.arms_pve_target
        and instanceType ~= "raid"
        and not Facade.IsInRaid()
        and (level < 60 or not (boss or target.is_boss))
end)

spec:RegisterStateExpr("warrior_durable", function()
    local classification = plain(Facade.UnitClassification("target"))
    return target.is_boss or classification == "elite" or classification == "rareelite" or classification == "worldboss"
end)

-- An invalid target must not select the raid priority just because the contextual predicate is false.
spec:RegisterStateExpr("prot_sustained", function()
    return state.prot_pve_target and not state.prot_contextual
end)

-- Normal and rare enemies get the short-pull budget in dungeons as well as outdoors.
-- This is a classification rule, not an estimate of hidden remaining health or lifespan.
spec:RegisterStateExpr("prot_short_pull", function()
    return state.prot_contextual and not boss and not target.is_boss and state.arms_short_pull
end)

spec:RegisterStateExpr("prot_adventuring", function()
    return state.prot_pve_target and (level < 60 or state.arms_open_world)
end)

spec:RegisterStateExpr("prot_leveling", function()
    return level < 60 and state.prot_adventuring
end)

spec:RegisterStateExpr("prot_interrupt_window", function()
    local casting = debuff.casting
    -- Stop channels promptly. Give active Block a brief chance to catch a swing during a hard cast.
    -- The hostile cast end is hidden, so don't time Bash from the modeled duration.
    return casting.up and (casting.v3 == 1 or buff.shield_block.down or now - casting.applied >= 0.25)
end)

-- Session-only observations. START alone does not prove interruptibility: the facade's target cast is modelled,
-- and a NOT_INTERRUPTIBLE event can follow START. Remember only an explicit INTERRUPTIBLE event for the same
-- active, readable target. A later uninterruptible spell does not erase a type's proven interruptible spell.
local casterIDs, casterSlots, nextCasterSlot = {}, {}, 1
local CASTER_SLOTS = 64
local pendingCasterGUID, pendingCasterID, pendingCastBar = false, 0, 0
local function clearProtectionCast()
    pendingCasterGUID, pendingCasterID, pendingCastBar = false, 0, 0
end

local function protectionCasterTarget()
    if
        not state.spec.protection
        or not isPvE()
        or plain(Facade.UnitExists("target")) ~= true
        or plain(Facade.UnitCanAttack("player", "target")) ~= true
        or plain(Facade.UnitIsPlayer("target")) ~= false
        or plain(Facade.UnitIsDeadOrGhost("target")) ~= false
    then
        return
    end
    local guid = plain(Facade.UnitGUID("target"))
    if type(guid) ~= "string" then
        return
    end
    local id = state.target.npcid
    if id > 0 then
        return guid, id
    end
end

local function beginProtectionCast(_, _, _, _, bar)
    clearProtectionCast()
    local guid, id = protectionCasterTarget()
    if guid then
        pendingCasterGUID, pendingCasterID = guid, id
        bar = plain(bar)
        pendingCastBar = type(bar) == "number" and bar or 0
    end
end

local function rememberProtectionCaster()
    if not pendingCasterGUID then
        return
    end
    local guid, id = protectionCasterTarget()
    if guid ~= pendingCasterGUID or id ~= pendingCasterID then
        clearProtectionCast()
        return
    end
    if not casterIDs[id] then
        local replaced = casterSlots[nextCasterSlot]
        if replaced then
            casterIDs[replaced] = nil
        end
        casterIDs[id], casterSlots[nextCasterSlot] = true, id
        nextCasterSlot = nextCasterSlot % CASTER_SLOTS + 1
    end
end

local function endProtectionCast(event, _, _, _, fourth, fifth)
    local bar =
        plain((event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_INTERRUPTED") and fifth or fourth)
    if type(bar) == "number" and bar ~= 0 and pendingCastBar ~= 0 and bar ~= pendingCastBar then
        return -- A delayed stop for the preceding cast must not clear the new active cast.
    end
    clearProtectionCast()
end

spec:RegisterUnitEvent("UNIT_SPELLCAST_START", "target", nil, beginProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "target", nil, beginProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTIBLE", "target", nil, rememberProtectionCaster)
spec:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "target", nil, endProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "target", nil, endProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "target", nil, endProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "target", nil, clearProtectionCast)
spec:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "target", nil, clearProtectionCast)
spec:RegisterEvent("PLAYER_TARGET_CHANGED", clearProtectionCast)
spec:RegisterEvent("PLAYER_ENTERING_WORLD", clearProtectionCast)

spec:RegisterStateExpr("prot_bash_reserve", function()
    if combat == 0 or not state.prot_pve_target or not state.toggle.interrupts then
        return 0
    end
    local bashCooldown = cooldown.shield_bash.remains
    if
        bashCooldown > 1.5
        or not equipped.shield
        or not (buff.defensive_stance.up or buff.battle_stance.up)
        or not target.within5
        or target.outside5
        or not action.shield_bash.known
        or state:IsDisabled("shield_bash", true)
    then
        return 0
    end

    local casting = debuff.casting
    if casting.up then
        -- Hostile cast ends are estimated. Release Rage if Bash cannot fit in the remaining forecast.
        if casting.v2 ~= 0 or max(bashCooldown, cooldown.global_cooldown.remains) >= casting.remains then
            return 0
        end
    elseif not state.prot_contextual or not casterIDs[target.npcid] then
        return 0
    end
    return action.shield_bash.cost
end)

spec:RegisterStateExpr("prot_current_rage", function()
    -- An icon offered now must leave the reserve even if another swing is forecast before it.
    return min(rage.lo, rage.actual_lo or rage.lo)
end)

local partyUnits = { "party1", "party2", "party3", "party4" }

spec:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    unit = plain(unit)
    if type(unit) == "string" then
        warriorPlates[unit] = unit .. "target"
        pull.updated, area.updated = -1, -1
    end
end)

spec:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    unit = plain(unit)
    if type(unit) == "string" then
        warriorPlates[unit] = nil
        pull.updated, area.updated = -1, -1
    end
end)

spec:RegisterEvent("PLAYER_TARGET_CHANGED", function()
    area.updated = -1
end)

spec:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    pull.updated, area.updated = -1, -1
end)

local function warriorVictim(unit)
    if plain(Facade.UnitIsUnit(unit, "player")) == true then
        return true, false
    end
    if not state.solo and plain(Facade.UnitExists(unit)) == true then
        for _, member in ipairs(partyUnits) do
            if plain(Facade.UnitIsUnit(unit, member)) == true then
                return false, true, member
            end
        end
    end
    return false, false
end

local areaRadii = { 5, 8, 10 }

local function areaDistance(unit, melee)
    local _, upper = Facade.LibRangeCheck:GetRange(unit)
    upper = plain(upper)
    if type(upper) == "number" and upper <= 5 then
        return upper
    end
    if melee and plain(C_Spell.IsSpellInRange(melee, unit)) == true then
        return 5
    end
    return type(upper) == "number" and upper or math.huge
end

local function protectionArea()
    local time = state.now
    if area.updated == time then
        return area
    end
    area.updated, area.onMe = time, false
    for _, radius in ipairs(areaRadii) do
        area.count[radius], area.visible[radius], area.engaged[radius] = 0, 0, false
    end

    local guid = plain(Facade.UnitGUID("target"))
    local melee = REND[knownRank(REND)] or SUNDER_ARMOR[knownRank(SUNDER_ARMOR)]
    local targetDistance = areaDistance("target", melee)
    local targetEngaged = Facade.TargetInPlayerCombat() == true

    for unit, victim in pairs(warriorPlates) do
        if
            plain(Facade.UnitExists(unit)) == true
            and plain(Facade.UnitCanAttack("player", unit)) == true
            and plain(Facade.UnitIsPlayer(unit)) == false
            and plain(Facade.UnitIsDead(unit)) == false
        then
            local distance = areaDistance(unit, melee)
            local same = plain(Facade.UnitIsUnit(unit, "target"))
            if same == nil and guid then
                local other = plain(Facade.UnitGUID(unit))
                if other then
                    same = guid == other
                end
            end
            if same == true then
                targetDistance = min(targetDistance, distance)
            end

            if distance <= areaRadii[#areaRadii] then
                local onMe, inParty = warriorVictim(victim)
                local engaged = plain(Facade.UnitAffectingCombat(unit)) == true
                    and (
                        onMe
                        or inParty
                        or plain(Facade.UnitInParty(victim)) == true
                        or type(Facade.UnitThreatSituation("player", unit)) == "number"
                    )
                area.onMe = area.onMe or engaged and onMe
                for _, radius in ipairs(areaRadii) do
                    if distance <= radius then
                        area.visible[radius] = area.visible[radius] + 1
                        if same == false then
                            area.count[radius] = area.count[radius] + 1
                        end
                        area.engaged[radius] = area.engaged[radius] or engaged
                    end
                end
            end
        end
    end

    area.targetMelee = targetDistance <= 5
    for _, radius in ipairs(areaRadii) do
        local hasTarget = targetDistance <= radius
        -- Two independently observed plates prove two enemies even when the client hides their link to the target.
        area.count[radius] = max(area.visible[radius], area.count[radius] + (hasTarget and 1 or 0))
        area.engaged[radius] = area.engaged[radius] or hasTarget and targetEngaged
    end
    return area
end

local function protectionAreaCount(radius, needsMeleeTarget)
    -- The contextual priority requires a living, hostile NPC selected before sampling its range.
    if state.combat == 0 or not state.prot_contextual then
        return 0
    end
    local current = protectionArea()
    if needsMeleeTarget and not current.targetMelee or not current.engaged[radius] then
        return 0
    end
    if not state.prot_attack_target then
        local _, instance = Facade.IsInInstance()
        local role = Facade.GroupRole("player")
        if instance ~= "party" or not (role == "TANK" or role == "NONE" and current.onMe) then
            return 0
        end
    end
    local count = current.count[radius]
    if state.max_targets == 1 or state.toggle.mode == "single" then
        return min(count, 1)
    elseif state.toggle.mode == "aoe" then
        return max(count, state.active_enemies)
    end
    return count
end

do
    local builders = {}
    for _, ranks in ipairs({ SHIELD_SLAM, REVENGE, SUNDER_ARMOR }) do
        for _, id in ipairs(ranks) do
            builders[id] = true
        end
    end
    recovery = Hekili:NewTankRecovery(spec, {
        specKey = "protection",
        plates = warriorPlates,
        meleeSpell = function()
            return SUNDER_ARMOR[knownRank(SUNDER_ARMOR)]
                or REVENGE[knownRank(REVENGE)]
                or SHIELD_SLAM[knownRank(SHIELD_SLAM)]
        end,
        safePack = function()
            return Facade.DebuffCount(20511, GetTime()) == 0
        end,
        usableBuilder = function(guid, time)
            return not guid or not Facade.DebuffBlocked("sunder_armor", time, guid)
        end,
        classifyCast = function(id)
            if builders[id] then
                return "builder"
            end
            if id == 355 then
                return "rescue"
            end
        end,
    })
    spec:RegisterStateExpr("prot_loose_victim", function()
        local current = recovery.evidence()
        return current and current.loose or false
    end)

    spec:RegisterStateExpr("prot_recovery_pack", function()
        local current = recovery.evidence()
        return current and current.other or false
    end)

    spec:RegisterStateExpr("prot_clap_pickup", function()
        local current = recovery.evidence(true)
        return current and current.other or false
    end)

    local function canUseOnNextGCD(spell, rage)
        local action = state.action[spell]
        return action.known
            and not action.disabled
            and rage >= action.cost
            and state:IsUsable(spell)
            and state.cooldown[spell].remains <= state.gcd.remains
    end

    local function canBuildThreat(current, rage)
        return (
            current.builder
            and state.weapon.size > 0
            and state.action.sunder_armor.known
            and not state.action.sunder_armor.disabled
            and rage >= state.action.sunder_armor.cost
        )
            or canUseOnNextGCD("revenge", rage)
            or canUseOnNextGCD("shield_slam", rage)
    end

    spec:RegisterStateExpr("prot_recovery_block", function()
        local current = recovery.evidence()
        if not current or not current.other or not state.prot_melee_target then
            return false
        end
        -- Block is off the GCD. Keep enough Rage for the best threat action available after it.
        local rage = state.prot_current_rage
            - action.shield_block.cost
            - (debuff.casting.up and state.prot_bash_reserve or 0)
        if canUseOnNextGCD("thunder_clap", state.prot_current_rage) then
            return canUseOnNextGCD("thunder_clap", rage)
        end
        return canBuildThreat(current, rage)
    end)

    spec:RegisterStateExpr("prot_recover_threat", function()
        local current = recovery.evidence()
        if not current or not current.other or state.weapon.size <= 0 then
            return false
        end
        local rage = state.prot_current_rage - (debuff.casting.up and state.prot_bash_reserve or 0)
        -- Clap is centered on us; a positive melee check on the loose mob puts it within the radius.
        -- Re-read the victim and threat after its real cast, including packs larger than its four-target cap.
        if canUseOnNextGCD("thunder_clap", rage) then
            return false
        end
        return canBuildThreat(current, rage)
    end)
end

local function observePullEnemy(guid, time)
    if guid and not pullFirstSeen[guid] then
        pullFirstSeen[guid] = time
    end
end

local function durableRendEnemy(unit, guid, time)
    local classification = plain(Facade.UnitClassification(unit))
    if classification ~= "elite" and classification ~= "rareelite" and classification ~= "worldboss" then
        return false
    end
    return Facade.DebuffImmunity("rend", guid, time) == nil
end

local function warriorPull()
    local time = state.now
    local guid = plain(Facade.UnitGUID("target"))
    local tank = state.spec.protection
    if pull.updated == time and pull.target == guid and pull.tank == tank then
        return pull
    end

    -- Sample live units once for all priority evaluations at this instant.
    pull.updated, pull.target, pull.tank, pull.nearby = time, guid, tank, 0
    pull.spreadTargets, pull.rendSpreadTargets = 0, 0
    pull.currentMelee, pull.currentRendEligible = false, false
    pull.rendExpires, pull.sunderExpires = 0, 0
    pull.packLoose, pull.nearbyOnMe, pull.nearbyMeleeOnMe = false, false, false
    local onMe, onParty, member = warriorVictim("targettarget")
    local role = tank and not state.solo and Facade.GroupRole("player")
    pull.threatRole = role ~= "HEALER" and role ~= "DAMAGER"
    pull.otherTank = member and Facade.GroupRole(member) == "TANK" or false
    local status = not state.solo and plain(Facade.UnitThreatSituation("player", "target")) or nil
    pull.status, pull.onMe = status, onMe
    pull.targetEngaged = plain(Facade.UnitAffectingCombat("target")) == true and (onMe or onParty or status ~= nil)
    pull.targetLoose = pull.targetEngaged and onParty and (status == nil or status < 2)
    if pull.targetEngaged and (tank or state.combat > 0) then
        observePullEnemy(guid, time)
    elseif guid then
        pullFirstSeen[guid] = nil
    end
    if (pull.targetEngaged or state.solo) and state.target.within8 and not state.target.outside8 then
        pull.nearby = 1
    end
    if tank and pull.targetEngaged and state.target.within5 and not state.target.outside5 then
        pull.spreadTargets, pull.currentMelee = 1, true
        if durableRendEnemy("target", guid, time) and not state.arms_skip_rend then
            pull.rendSpreadTargets, pull.currentRendEligible = 1, true
        end
        -- The cycle simulation virtualizes debuff.* to absent. Read the current target's plain belief
        -- through the public client API, retaining only expiry numbers in this once-per-instant sample.
        for i = 1, 40 do
            local aura = Facade.C_UnitAuras.GetDebuffDataByIndex("target", i)
            if not aura then
                break
            end
            local expires = aura.expirationTime == 0 and math.huge or aura.expirationTime
            if rend_ids[aura.spellId] then
                pull.rendExpires = expires
            elseif sunder_ids[aura.spellId] then
                pull.sunderExpires = expires
            end
        end
    end

    -- A self-centered Clap can't prove another unit's range. A positive Rend check puts it inside melee and Clap.
    local meleeProbe = REND[knownRank(REND)]
    for plate, victim in pairs(warriorPlates) do
        local plateGUID = plain(Facade.UnitGUID(plate))
        if
            guid
            and plateGUID
            and plateGUID ~= guid
            and plain(Facade.UnitExists(plate)) == true
            and plain(Facade.UnitCanAttack("player", plate)) == true
            and plain(Facade.UnitIsPlayer(plate)) == false
            and plain(Facade.UnitIsDead(plate)) == false
            and plain(Facade.UnitAffectingCombat(plate)) == true
        then
            local plateOnMe, plateOnParty, plateMember = warriorVictim(victim)
            if plateOnMe or plateOnParty then
                if tank then
                    observePullEnemy(plateGUID, time)
                end
                if meleeProbe and plain(C_Spell.IsSpellInRange(meleeProbe, plate)) == true then
                    pull.nearby = pull.nearby + 1
                    if tank then
                        pull.spreadTargets = pull.spreadTargets + 1
                        if durableRendEnemy(plate, plateGUID, time) then
                            pull.rendSpreadTargets = pull.rendSpreadTargets + 1
                        end
                        pull.nearbyOnMe = pull.nearbyOnMe or plateOnMe
                        local _, creatureType = Facade.UnitCreatureType(plate)
                        pull.nearbyMeleeOnMe = pull.nearbyMeleeOnMe or (plateOnMe and plain(creatureType) ~= 4)
                        if plateOnParty and not pull.packLoose and Facade.GroupRole(plateMember) ~= "TANK" then
                            local plateThreat = plain(Facade.UnitThreatSituation("player", plate))
                            pull.packLoose = plateThreat == nil or plateThreat < 2
                        end
                    end
                end
            end
        end
    end
    return pull
end

-- A normal target that has already survived twelve seconds of combat can merit armor reduction.
-- Use observed time on this particular enemy, never the predicted duration of a queued action.
spec:RegisterStateExpr("warrior_sustained_target", function()
    if combat == 0 or not state.warrior_field then
        return false
    end
    local current = warriorPull()
    local since = pullFirstSeen[current.target]
    return current.targetEngaged and (state.warrior_durable or since ~= nil and state.now - since >= 12)
end)

spec:RegisterStateExpr("prot_threat_spend", function()
    if combat == 0 or solo or not state.prot_contextual then
        return false
    end
    local current = warriorPull()
    if not current.threatRole or current.otherTank then
        return false
    end
    if debuff.taunt.up then
        return true
    end
    local engagedAt = pullFirstSeen[current.target]
    return current.targetEngaged
        and (
            current.status == 2
            or current.targetLoose
            or (engagedAt ~= nil and current.status ~= 3 and query_time - engagedAt <= 3)
        )
end)

spec:RegisterStateExpr("prot_pack_threat_spend", function()
    return combat > 0
        and not solo
        and state.prot_contextual
        and state.max_targets ~= 1
        and state.toggle.mode ~= "single"
        and warriorPull().threatRole
        and warriorPull().packLoose
end)

-- Execute spends the entire remaining pool. Use a legal current stance on a controlled, short
-- single-target fight without consuming Rage reserved for an interrupt or mitigation.
spec:RegisterStateExpr("prot_controlled_finisher", function()
    if
        combat == 0
        or not state.prot_attack_target
        or not state.prot_short_pull
        or state.true_active_enemies > 1
        or state.prot_dump_reserve > 0
        or state.prot_threat_spend
        or state.prot_pack_threat_spend
    then
        return false
    end
    local current = warriorPull()
    return current.targetEngaged
        and current.nearby <= 1
        and (solo or current.otherTank or current.status == 3 and current.onMe)
end)

spec:RegisterStateExpr("prot_nearby_enemies", function()
    return protectionAreaCount(8)
end)

spec:RegisterStateExpr("prot_cleave_targets", function()
    return protectionAreaCount(5, true)
end)

spec:RegisterStateExpr("prot_shout_targets", function()
    return protectionAreaCount(10)
end)

spec:RegisterStateExpr("warrior_nearby_enemies", function()
    if combat == 0 or not state.warrior_field then
        return 0
    end
    local current = warriorPull()
    if not current.targetEngaged then
        return 0
    end
    local nearby = current.nearby
    return (state.max_targets == 1 or state.toggle.mode == "single") and min(nearby, 1) or nearby
end)

spec:RegisterStateExpr("warrior_attack_target", function()
    if not hostileTarget() then
        return false
    end
    local _, instance = Facade.IsInInstance()
    if instance == "party" or instance == "scenario" then
        return target.is_dummy or state.arms_pve_target and warriorPull().targetEngaged
    end
    if instance == "none" and combat > 0 and state.warrior_field and state.false_start == 0 then
        return plain(Facade.UnitAffectingCombat("target")) == true
    end
    return instance == "raid" or instance == "none" or instance == "pvp" or instance == "arena"
end)

spec:RegisterStateExpr("prot_attack_target", function()
    if not state.prot_pve_target then
        return false
    end
    if state.prot_sustained or warriorPull().targetEngaged then
        return true
    end
    -- A selected outdoor enemy is a pull cue; instance targets must already be fighting us or our party.
    if combat == 0 then
        return state.arms_open_world
    end
    return state.arms_open_world
        and (state.false_start > 0 or solo and plain(Facade.UnitAffectingCombat("target")) == true)
end)

spec:RegisterStateExpr("warrior_start_attack", function()
    local eligible
    if state.warrior_pvp_target then
        eligible = true
    elseif state.spec.protection then
        eligible = state.prot_contextual and state.prot_attack_target
    else
        eligible = state.warrior_field
            and state.warrior_attack_target
            and (combat == 0 or state.false_start > 0 or plain(Facade.UnitAffectingCombat("target")) == true)
    end
    if
        not eligible
        or weapon.size == 0
        or not target.within5
        or target.outside5
        or plain(IsCurrentSpell(6603)) ~= false
        or buff.warrior_autoattacking.up
    then
        return false
    end
    return true
end)

-- Existing saved Protection lists can still refer to the original expression.
spec:RegisterStateExpr("prot_start_attack", function()
    return state.spec.protection and state.warrior_start_attack
end)

spec:RegisterHook("CanAcceptCycleTarget", function(key)
    if state.spec.protection and (key == "rend" or key == "sunder_armor") then
        local current = warriorPull()
        return current.currentMelee and (key ~= "rend" or current.currentRendEligible)
    end
end)

local function protectionSpreadTargets(rend)
    if state.combat == 0 or not state.prot_contextual or state.max_targets == 1 or state.toggle.mode == "single" then
        return 0
    end
    local current = warriorPull()
    if not current.targetEngaged then
        return 0
    end
    if state.cycleInfo.selected then
        return rend and current.rendSpreadTargets or current.spreadTargets
    end
    -- The global aura count includes the current target. If it is missing its aura, exclude it from
    -- the comparison: it cannot prove that ANOTHER eligible unit needs a cast. Forecast-only current
    -- applications remain conservative until observed, and expiry is checked at the forecast's time.
    if rend then
        return current.rendSpreadTargets
            - (current.currentRendEligible and current.rendExpires <= state.query_time and 1 or 0)
    end
    -- These are confirmed units, never the assumed enemy count from forced AoE mode. The engine's
    -- cycle icon asks the player to select a target; it cannot rank individual threat or time to die.
    return current.spreadTargets - (current.currentMelee and current.sunderExpires <= state.query_time and 1 or 0)
end

spec:RegisterStateExpr("prot_spread_targets", function()
    return protectionSpreadTargets(false)
end)

spec:RegisterStateExpr("prot_rend_spread_targets", function()
    return protectionSpreadTargets(true)
end)

spec:RegisterStateExpr("warrior_charge_range", function()
    return not action.rend.in_range and C_Spell.IsSpellInRange(CHARGE[1], "target") == true
end)

spec:RegisterStateExpr("warrior_intercept_range", function()
    return C_Spell.IsSpellInRange(INTERCEPT[1], "target") == true
end)

spec:RegisterStateExpr("prot_charge_range", function()
    return state.warrior_charge_range
end)

spec:RegisterStateExpr("prot_charge_ready", function()
    return action.charge.known and cooldown.charge.ready
end)

spec:RegisterStateExpr("prot_melee_target", function()
    if combat == 0 or not state.prot_pve_target then
        return false
    end
    if lastIncomingSwing > 0 and now - lastIncomingSwing <= 3 then
        return true
    end
    if warriorPull().nearbyMeleeOnMe then
        return true
    end
    return target.within5
        and not target.outside5
        and target.creature_type ~= "elemental"
        and debuff.casting.down
        and (solo or warriorPull().onMe)
end)

spec:RegisterStateExpr("prot_last_resort_taunt", function()
    return recovery.lastResort()
        and buff.defensive_stance.up
        and debuff.taunt.down
        and not Facade.DebuffBlocked("taunt", GetTime(), Facade.UnitGUID("target"))
end)

-- A tank still gains mitigation, threat and access to Revenge without a shield. In a dungeon,
-- confirm the enemy is actually tanked by us and the switch preserves even the upper Rage estimate.
spec:RegisterStateExpr("prot_shieldless_tanking", function()
    local _, instanceType = Facade.IsInInstance()
    if instanceType ~= "party" or solo or combat == 0 or not state.prot_contextual or weapon.size == 0 then
        return false
    end
    local current = warriorPull()
    return current.targetEngaged
        and current.onMe
        and (current.status == 2 or current.status == 3)
        and rage.hi <= state.stance_rage_limit
end)

spec:RegisterStateExpr("prot_offtanking", function()
    local _, instanceType = Facade.IsInInstance()
    if combat == 0 or instanceType ~= "raid" or not state.prot_pve_target or not target.is_boss then
        return false
    end
    local current = warriorPull()
    return current.targetEngaged
        and current.status ~= nil
        and current.status < 2
        and plain(Facade.UnitExists("targettarget")) == true
        and plain(Facade.UnitIsUnit("targettarget", "player")) == false
        and not current.nearbyOnMe
        and not state.prot_melee_target
end)

spec:RegisterStateExpr("prot_dump_reserve", function()
    local reserve = state.prot_bash_reserve
    if not buff.defensive_stance.up or not state.prot_pve_target then
        return reserve
    end
    if not state.prot_contextual then
        local status = not solo and plain(Facade.UnitThreatSituation("player", "target"))
        if type(status) ~= "number" or status < 2 then
            return reserve
        end
    end

    local horizon = 1.5
    local block = state.toggle.defensives
        and equipped.shield
        and state.prot_melee_target
        and action.shield_block.known
        and not action.shield_block.disabled
        and cooldown.shield_block.remains <= horizon
        and buff.shield_block.remains <= horizon
    local slam = equipped.shield
            and action.shield_slam.known
            and not action.shield_slam.disabled
            and cooldown.shield_slam.remains <= horizon
            and action.shield_slam.cost
        or 0
    local revenge = action.revenge.known
            and not action.revenge.disabled
            and cooldown.revenge.remains <= horizon
            and (buff.revenge_usable.up or block)
            and action.revenge.cost
        or 0

    -- Shield Block is off the GCD. Shield Slam and Revenge compete for the next GCD.
    reserve = reserve + max(slam, revenge) + (block and action.shield_block.cost or 0)
    if reserve > 0 then
        reserve = reserve + state.warrior_mainhand_rage
    end
    return reserve
end)

-- Saved priorities can still refer to this condition. Humanoid type cannot establish weapon eligibility.
spec:RegisterStateExpr("prot_disarm_target", function()
    return false
end)

-- Keep the original condition available to saved custom priorities.
spec:RegisterStateExpr("arms_solo", function()
    return solo and state.arms_open_world
end)

spec:RegisterStateExpr("arms_short_pull", function()
    local classification = Facade.UnitClassification("target")
    return not issecretvalue(classification) and (classification == "normal" or classification == "rare")
end)

spec:RegisterStateExpr("arms_skip_rend", function()
    return state.arms_pve_target and Facade.DebuffImmunity("rend", Facade.UnitGUID("target"), now) ~= nil
end)

spec:RegisterStateExpr("arms_moving_humanoid", function()
    return target.creature_type == "humanoid" and target.moving
end)

local function lowRageBloodrageSafe()
    if state.rage.lo > 25 then
        return false
    end
    local inCombat = state.combat > 0
    if
        not inCombat
        and not (
            plain(Facade.UnitCanAttack("player", "target")) == true
            and state.target.within5
            and not state.target.outside5
        )
    then
        return false
    end
    local playerHealth = Facade.PlayerHealthFraction()
    if playerHealth == nil then
        return inCombat
    end
    return playerHealth >= 0.65
end

spec:RegisterStateExpr("warrior_field_bloodrage_safe", function()
    return lowRageBloodrageSafe()
end)

spec:RegisterStateExpr("arms_bloodrage_safe", function()
    if not (isOpenWorld() or level < 60 and isPvE()) or plain(Facade.UnitIsPlayer("target")) == true then
        return true
    end
    return lowRageBloodrageSafe()
end)

spec:RegisterStateExpr("prot_bloodrage_safe", function()
    if not state.prot_contextual then
        return state.arms_bloodrage_safe
    end
    if action.revenge.known then
        return lowRageBloodrageSafe()
    end
    -- Keep the early kit's rage generation, while honoring an observed low-health result.
    local playerHealth = Facade.PlayerHealthFraction()
    return rage.lo <= 25 and (playerHealth == nil or playerHealth >= 0.65)
end)

-- Icy Veins' leveling advice: low rage, health to spare and time to keep attacking. 75% is this fork's conservative
-- health policy, not a guide threshold: the 25%-base-health cost can leave at least half of maximum health. An
-- unreadable health value never authorizes the cost. A durable target classification is positive evidence of an
-- attack opportunity; ordinary mobs' lifetime is unknown and target.time_to_die is not a usable estimate here.
spec:RegisterStateExpr("warrior_reckless_safe", function()
    if
        not (
            (state.spec.protection and state.prot_contextual and state.prot_attack_target)
            or (not state.spec.protection and state.warrior_field and state.warrior_attack_target)
        )
        or combat == 0
        or not action.reckless_swings.known
        or rage.hi > 25
        or (rage.actual_hi or rage.hi) > 25
        or buff.reckless_swings.up
        or weapon.size == 0
        or not target.within5
        or target.outside5
        or plain(IsCurrentSpell(6603)) ~= true
        or state.execute_phase
    then
        return false
    end
    if not state.warrior_durable then
        return false
    end
    local playerHealth = Facade.PlayerHealthFraction()
    return playerHealth ~= nil and playerHealth >= 0.75
end)

spec:RegisterStateExpr("prot_reckless_safe", function()
    return state.spec.protection and state.warrior_reckless_safe
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
    20261125001,
    [[Hekili:T316ZTTns8)w8hoDstDLLFO0MmXzMKM2R9M2EzI71(nrdjbjXZuK8iiTRVXJ(B)2Db4lqcsqjkN0P9lTsIK7JFyFHLyJND(SFz2nlzX8z)8ftU4fNF(ftNm58z3e)yiF2nHSf3XwdFWNTf(VFikiMVi2nWF3TdFi4bH7wX4fbBhH35JEbSLi1MN46f)d(ZMxlHfH8fZU53E7h)4p8V(4RcZO4SB24UCjx(yCXIg42R2DB8g(UBv)2zRcI43ZJ2D7s(kwIx8UBF7h(XD3c)8UBlrKe3Zq2lo7bwuKBq0z5S)mwON4mfbgdFz8)re4p6uGvrmFHhOilHphGS2vS7w2YLb()D4d3XFumE3TVNfZEvnI0WF6h(fGiBIJdfV6SZw7gVjzoQfNPDRJaAcsoB(KvtMWVA1IV(sGSFtqG3YGh8fiVxV2d0AaM4cGvFKhZ8CzOWdm49Cw8MD3(BUInW3U5bop01Fn8P4i374Oa7VubBrSfUmp4Ng(oVGa4x)UKOhHh6D8ibp6o4XGV8Tjr87y4h8s85OI(JUR3epcLjpMq4UaXw3TSOh3D7cgGUInbpS7wVGh(YnCMhkmaAY9fU3JShur4EEyd(FjPyHNl3pwPo7U9XGeaTKpjWJVh(aj)HbOcc3qIGREY3xGSsqbEG)vs8YaCbpmXd1nsKON5B2WIwd)F8IVnogSOXLRe)1C0MGr)sk(KEVHr8qwetA2eX)VjUrC8wa9WNVf0yMxeNTe(Wkevijf0ajtKQc88XpooLLa8ed)GqEhrCrYwu83Y94aHfpaua(6CoAmaxpibOj8H5jRwjsHnwsCatrn0emy1kG()kZFDclceEpESqjgP6XdG5gqlKdSqPbbih(l4Oj7VLErgU45Y9wEkkAXjr(sl9mGgnJWNktsG12uaubiOaTiWFLB02uhL54cgZ)o87ZFujz5MHGshVydH1Gz395gbFeI4aI3)aqHq8zvRORy3Jy3VSjXFj6zbMHHaiaIGpNfHmiSWk5nKcb)Fp22trNfW(l1k4gffEB0w8RuCc3TGCdEtKrgS2glTPeG1j6X4UuCAfEdgjWnkQriWhwItca0rVw)GOTmp1YpdxKjG7uLrk8WEpIIjk7j(XUEfKzeB9G7Whrds78C36gxWojvJqypa)bHYohLcyzjokWZldltz6V6Uioa9F)yIytnwFz(gYvDxuvxbeq6NI2(Pg0b(O0tCETxWC8IlurUqyAlZfDHDtjYDUiraJE4gYHQC58ukAsuCk89LXO5CSu8Xys)oFrcUurE5RC9Dr5VG75QOGTqanqb8uR5QGBiiv2w2pqAXjHzFoFjItKnbGXURvbbiBe)yEuusymU((wppmE3VOKSBahS0WoIK1R5cu6dXOeY4WQviA5dxMpvsZq3f3r3qsibcPMrkfjEdMuGs4qlg0Tc32A05aJFSDopACflZ1uOaYnd8irrzXgPsJwir8fbuYjx0k)J8f35XfcuhKHHqqqqHYLqdfwGTKnNs)OcUhSsMWcmmr6)vt)BNkxcyq(umKrXWvKwtRpEUXQvK5bcLnHkkiKNLC8tDDHStPH6uHisxyC9HeOeuqpkLVikatjjt3LgnhKnusGC(eQtRYE8vG4k1F2Qy8)LeMsoPR)PLx6jAvATptczs7o4JFibcGqM9eLLrYwKefrj5sTFrT9d3)TuID)fjqAuKbVJqAPPtCG0oybHQbspd)a)VucxsBwksQNezLRnpwqchxUQhbJITk1(58yO0aFj9fPoUeO(ZF4Babfk7d)55P4nEFe0KrExYmaWuissXW0sSlZ6kRSaj4lnKvRJ6YHkzu9ovyCxwIFQBaQ4cjPOieQ1qzS4IYrw0RvmmAkcfY8oqPSk)lGVVdG1SYJc9y(uqwmTLmPPGILckZwMFcZdEI)ng689UcweeIHTgdTfxk4ZdKQG5iPBs628aNfg4JUByUef)2eaGlEvOgtiigcZlb7ixuGYR3bQsmbQ)micRctKaIJljKHyjSUurgVlfoXmvsxlocCfTdOvJmxFGJKTBPOkOVnEr0CyjBlzXSK(nGhFRVut(jG9OiG1ha5pH60(FYiCYIjCX4cGH9AqgXWKzaub1fW5hP4pu2PTZjxosH1TLffJ27k9g84RXemYczovln2P0TKL6ekWFXUQveutedYofb4qk7mvecSTMOGvGip7ggHIIXHicIs81zv36OKeqbCGAYCwVy51NFQ7QRXDx4Gz14)Emy7mG(UeXDKregOO1e51wqLT5qbchGvDgcEwJL1MnaQ2hILm(Ev9EJ506XYYpjcFdoblBCSU8nojCWWtK6X45uQX0RCNpKO(j5Jv(kjHJgeHqHxWRVw(Bo43DUJhgV7Fwbv(IRpReb6BqXKYQl1doXeC1rTrYREwnQNvyctfjQYVYeJ2mH6EnSkGBTd1ndIEzrDOKQPXwEQm3YOLJGTIpQ5LDmkaYLYRl4VsgGDG5JuxzoePYrL546jpjrtzMvA17nxRzutmBbeS5lQ88JAr6ny0AWilZDQIVwrpQACehnOSoxVqfvyh(PRBT8iThuQHGdARd6M4AbKYrY)kuyEWJ2TLomO45ia4rpSxpeSdiH0yGCVXhs1tpNW7dDYQF4jJc4BMmq(9Xy9AU(treJ(EGCB)thSKtqRQeyeudbtO0YUYzI(nE)fPIE2T4i3SBrXpK2XWNFsEjZGSDPGjbEWQCj9VqQAYxErHzpAzXBm2VbWFaQ(nJBUch67zU7fSAsD2R5kKR1tvrNZhLtj5cOgru)O5NVi8gP26TJSbGneKhUzCBpK)9sTLbyBgyb1oZ5agC9vtYJYN)iLI4Pu0hyEELI3v83HOD14RHxsJFxonNFLjqodlihf5xjXRm7Id8XUrTvJztjLRB0TZ69GHYKgU0ECXGMoHbUcGajHpv5sWN5mbVkGbEf8iSqfb)tHwuuyK9SHa1gTDUCI(tbMLoYwWBHrNEYH0ibfjA3lvilEsd5Y1kqqg7u(zY)cUtCtULaLySPcgypH9Yom4q3xD5DW2tv95vbRYF3hdkU6qpKmofXO0MLiVqjXt2rpNfESWCyb(Id2YWSY10koEyLBtlgeY6rnudDr2AQgATqyOc4O6Cw9WzMwgQLc3IQaEtlvbCVC3)or4M)xfa5dQyD(YATopKuxNiXzPs7qToqIPHe1k8ZJAvw)0jAsltPq5gKigR6u)RVgwdgVL97LQQTLnuAP4xXY71xFX062Mz5GgS4nqjuYc9QH86BD5KkyqN3mzopTXnybe11r(vhpxr8P4lm)6flDsFzRwh)yOQ(83abvFAOmMxKSDwojcmLtPuRQlPYeK(sxY(5Sv0ZhpD0Or6a1ajqbcGkczxrPsH1ADl3nuYt(VRT2ZLD)tVoz1cFBEdQN2jCdKJ2gxXUZJYAhb79hbv4RaFlMhmX2qT8eIKID8uZYtkXxSFmXK5yMP80jJAn3M8nF5Gnr3LlEZ5gsW1HWBh5uFARnkjZY4GTGOk5eIicRsOTQ72rqO96q5bgcryowaukvnWyDWv1W16E(O2lblnzd)TMqBBE(6cM0uDpTPoDsEAEXVgp9JVbWrs1BbYlzZlDry4jNO315bv0KNtuOOQzdu8mumNH8GzCqEAjCKhacEu5SDDH46nVVl6qNl4SuB6ZlqzsxR9WM29xUkY8xxzUQouWJr7dX4TQxSPt1BuVx4zfsHxuHiIoIfv3O4jLx)u2VvLgzO56KGZLCJoveQFCpk8Tc)SPWoBYPpjvNkLQnprtr5wvAkDoGCWZ9ZFuQhWqD96Uu5XaQyhuflm0cHoUYAtX6L2udD(zmxOOKt0nLBbwxjdFDn77ltQKeOG8SmzByQ8ShLVQd0033V4VdQrdHivyHyrBfobGzLZdbrElhqFVGTAjp5rDgtkPQwanr4bkRN19Uel7eP(FNlkDqQ36JKHxsz4w)(f0D57CSlIdwyzt4vq8gSXvKA37PUtBVNpusjDkal4HGYbyqTmiMe4xB6wBWartrnzxOxUwFQG1VgxQkkbsyy7gd1xyRBj8IPDE5URLSvcooUl)Nic8cuDUSH1)Is0RR5UBAdy1R8FgykujZTrBdG2dnEXxp9P6UwwfJxE0Tx6TeG)5ov3EMutOgIf1tiQPxP6TZu5zL1dPrzVqKYRrMAJqdMoAcJnMp6LeRjDxuPBSDuMSPa12AAXHjbDPZbL7w2HX3o2SMg3QETVSD6DraEkrI4gFLd9ExikWyB0miqwmZlnqXZQKwI12iRT4oC(ZU7q)2qaZBxplJ1louvSd7nVrOF4jL3i(QKOhhN)YIlHK5sF1xFuhf)oVcP3xkB6FuZVzWNPdxAH9KLH1un707UBiKfBdJQ3NZxccZt6)sLJ7bfQt7L8v8skC4nQx03bVu10oPAUJWnvp3WdsTQToYcgahUwBtbIJ2Jc1gwowhuxfYw6vJDXetsDX6IAuQTPWQrDQW2HvInNjVxD4YBJLbRfaW8PoqjrV(LDZXVUZAqXtfE(7S)A6MCWyJ2CWhRJeOgKpv17pr4YPX(aiaof3chpCALTJmZU5EqYbkPn)(4PBqGJ5Fo9HV9Z0)ocOoIXZE3SBkWd8IQ5Nz2n5ykqHi3yEKlJgZgnbywmWxBPzge3onV0sAkr82P3v2sVclaTs1y8FceO)LiOlqR(jJRcBSzNIFEC(77(bWVt2lfjB)HsM0EDTypoA(DXYvkb9MA1fJ8chNVI838X5hj(unINsSchh7IeR(dl)tg1jlA9H1heDRpN)OE9cd6L8eI)zSkHc)xz5kU2jWV5iBhbX)ipAanmBaDz4aQF6aQLci4)1gSC0o7Cva7SIDqI8snIu6iXcU0tk(4DCCbQ)eNB2kjNWOKD(KMfTlNwjiaYIQYR1JBqTNOEsu0ZTQjktNuqusNjHIcsh5z3b1ghgHgNgbs)0tj2K(vCIfEw1rssP0B6gq6wgfe3cZ0qrnejLE6Qgn91toMgJYS1C55IG4OEoS(OeT9zUhK5mQzWhiPupJKjPKM4HkIwLzIGOPTjkkE2dks6dzCjibWuWYI9AQkm32Cuy7GuCGn7I0a9i1MGWYJArfDQ0qwqLdRhNDVkBRU5VGOElHoFzbF1I9FF2nuFgibypkr1IIhQ7Gly6KlqAIEqYp9IvRtMrRylQx2UJHSMHSVQEfNatd1bjw6HNZdoMoXfTugPERDSFCpAS16TnVhKWBA3k6daISrjoY)DtSqRsqAyBCytXmlnIiDEgrowdjs7VUUMNsecA0tNyBPVLgFeIsMYlOED1M2)LYeRnN5sV0BIF6rXpeYBJ39L6r37hgQSj04LESEnluSv9hOaGCXCC4UtqJw)z(otNmktlVOPQ9k0CDsm1dRAvfh2nDl1ECw725zThQi5strOnSC3RdbqQg8h(rFP94H90SVy97YVlsKbld90FpRgbhnTVfCVTOJM60xX3M4rdQgur9FMbpBENPemPNBF)Q1STej2K6Sd1gKjAh0S2qCvVcHSYVz5NSG9fv6(MlA5uuyFXD2CWiq9)k9cwYR7x)qTuYzXQJJtnNhh6xSzaDmIthNj0rYolgrN(5CarqVP636sjlhHH35ZJYDUY23BOP9JP7OE0gTN2tG34wSiLvV61kDgR9tZ8(pop2uWTKaKSQxh6(fB0QeOhNt(8bpKp2ayv2HYvMAsbEOUowOyNIS2tZlKTdm0EEo3iSuV4UJd6rpBu1ra6OpTq6ghfNkgv5sxzQPmMQVTpbMdAkJQBD34yg1dL4ELEHLhjm5ZHzlYKzqDgqMQ89tGbu)nBs73Wj1dwztn35pjXTifE)NSEQEnMhNLZA0W(kz9XoT8uRRZuBwJQP3bnnYtDCMNAYI0YHEI0UU2wunb3YPH6aR3xkQTux5(lchwJKM2YrHtVVRhOWAzp)M2sfq5N6ilA9Yut1suyUNQWH6E7FhHgzzXOxrQGPUhvAGO(uPewnvwKAykPSL(RwoUw9H)6lEM7Cu)njx9tlCKGqx7HZrDgV6LLv98HzXcm0quB6BzlNuGwg)RdSnNs1YuIq9DFB1GH1PjdZIzOY6rdBp3ZSecm(cen9grASq7MMAmlu5(ASXoWs3LitdVaTYby3RzeRbr0MYAhTFVr8xyUcH(yqYAqPAzsYSrBY3bZlS9Smw75LsPx2ooATmpAZOHak7VShZ(RXa6VgdO)CngqDY57GD4i))owoYjvRhjXU)ch9CugI1bZm5fyWQTT)Mhz)F0JqP08OUK9N(Og2WzC1XCzFIk2q0j9foDFi9)Mintn(MGlWgSeNVNFNRN7UBh(DQ)kptxE2))d]]
)
spec:RegisterPack(
    "Fury (wowsims.com)",
    20261125000,
    [[Hekili:T3vBtQnos4Fl8fotnzzaMHSztfMQsUC7D5Q9TkKQ2VHrJTa8HX2LL9WYvu8B)Aj)MSSKFddzYC5d3TmwYTE6h1Q7wYQ3DX4fFzXCtuaEXVnz0KxpE8KPJgnAX8GdE4fZ9qgBrRHF4G2b)))CO)Htl127UNyTJm0WD3aAFoy7ImPY5Xql7Gp5S4rPIK4Hnwm)pF)N)8N(9p)2vGSwmFJLPjo6fWedPJWBpTmyd(0Y4ND7kxF8ty)tlnXRqH2bNw(()4xoTeE8PLXVEO1T0bJC7EKVVLR)TMEKBrE2WldDyi8RH)hIRZGxbI2h5qSbWAc)2LouwKtlrMMUo)n4hBXhidpT8JOa0BLabTF9tFbeYMGapYBV921wbBcFKI6Bf66aqMasrpoA1Or47xz8M7aX(3DDTnD37qOJ9612GwcecMad1hXOGnNw(NwKnWa8zSXwBmH4a)pyur2eaQpI3y5aW2kaEgDM60scoiWYzn8gURwb94qklr1157XypOz4xb(wBXufLkag96JmSa5cs)d2UUMrCj8sFa7tW(BJK6)i0hVfr)HDOdMsq)I16nbdgs7hvvbeVXY3EpamOxHemf70XGnq2U7)Hpd2tNw(7aN45Uh7dV57xfq5syMWYHHoErSc9eDIngf0(npa5yGH37lOTGKqsflmxbVV7E4FUb7eRIK9wbgaP6JdGHca)b3qONrVkdGrpyh0kD(ka4uOxBqpHJmo2JScOwdH(mC646aygEnVqBBcawcRNZdDmPi49(7OqNzyAg6JEKo)gG8xJdsyEsaA9AAF3Gr2bB(bWQ1XKj7yq9OLTvGfDMcWoa9)jJJ)im(BtEnO7aMGvsyBqIFar2el8)iC3oSnfa22uM4toap7h6fqTOblkxGSoqnFW7sWZhXaKbr(FJSs24ggK9(FeVc7qSEctgcR69Dxzzd(eqgbwUoKHE(Ge39ikyMXgQo(kyYxhSc1xByoB8RSwnlU5r9JxvQVIc50)kIV1JiO0NgjmDyvkWh)7cd2nZUffg4g)Y1ymbg3piU7YL3JjMAWGcQbiKaKn2jyO1oqPFcBQNVhdXo0PwZ(A9YPyh1QJEgnSpmQptu2UVB2KPGKIhY1W0TUz0SDY4C8XWvRY3c1hYGbduOp0LZmvPa7uoI1tFtDcAfUTOsUIRaRqFSHHJA4rbypMu5F6Wqp5VQFSlsDyvUZAc9TLZ4kv6mjCgARCWzGST1JAq32Ie8kA80zqp0PUo03bMvPV4vy9t3SQbKcztKHc40HNW9EYt3kXBZrnK)oc8mSi2uSsi6VhsD4z5mTFV4)gM8jqWXP9nXm23arOX6adcXN80ea60XZJomwbhYaZaE07XCq(niWJIwqcCDentmTiE2OdGlkWL9S7grvorTibVIseqGUNl9jLk07hXZy1X3g)a9KLrGR)bD)qWKzLRrijYKRjYRkIUH25puTDUjxCXmVtndZSe8gAMgenrlSiX9LX)apJ9fTlO(w63d)xyJWaW4ydIGZZbJhjscWtsDSfN8XXK)2bJ8F8Go2bVdsT4HXdsgVIQjBO5zcibxA2n6g2iVgZb9OPFRVpj9oD0tilBk0YRnVruzEtFvqprKqIz6qIwmpr8WnlunHL2yrBGgPakXF0iMgPkkf1To05nTEQB8yU4Brne6nqCUon3GOUWs7qFl2lOFpnLqI1GBscX6UEEU(bHoGxfXMIsvoNhg5bSirZ9iAITmplqha)kXZgZg3xti4A)E8EwJytfjeumUCfRY5d2QeXgM6XBSP68DQAYVk371F9wLjfXC5aBaeMAIISQTIUpliff6EtiVBw8Y1KUmKoK038yU(9GMr8omL13B0ujLBNqHO4K5Zo6k38Vp3wKzmw8EHjdJ3kUoFp6lLq57r1uQ0EhtQsBJrRFRXRK4dnaCpXoZGIEqZ7f4HIEb6yfuT(ud1j1tznrUCuvmcLQbVc3AYeunCRX57gJEIE2m0nlDjjD1rtYBT4btkzwlroDBE8pT2WLvgIi3CF7zhjPNOLpG9rHLG5qbBx1GC8jTijYQw73aCe3tkgYNTXvG8FoSml3QmByzKyYHr7ozcdVf8ueNs2dZMmTOh92bYkPqv7DQxnSHQHf45I1xc5DFPsNUc7Rgrgv5eqv8XmB27HnhQCVyht72RNkKHfS49sb6oEIusYFGosdwIlzxO9yhvczRLhR)IBdlExY0MkSVyXTg1PKJao0etXlbz8GyiHouVB6G0GaKqc97EGntgF1eHMAbo5OS2sZJ(oWdDQbu88wUEA4scUHnWXp2hdEkEcN)0O8DTmsYH46SQPmRIyZVm3MXwMcZlYx49o6(ItKbZ2jYYnEfiL3yFokMj3rEBSKTCak(WDO)scZMJO4O24N3EQvtiIhOdYptcQZKbhHaGAQyPJXnKsTrpM9skFN0nzX3ucFmtYRbAWGmAwySYexwdIclRfQO446xp6kSNnLoJvXqC2cGB6luch58Rk1yzSKSJO27L6)vWBMK1g94xgq9NNQSJhnO8aczwo5Am1bv0S5LD6SP5kePEBSYFaF2w7ScsdmkKqvHyJsBpo8OyBaJoGJgtHtINjXJzmDrswpP(A6NY1zppHNzdCME6JrMhsASEh8Gy6gAALKJGNp(PHJZ3e4HPedL(FRz1sNXUUq(QTXMct1nqRe0abo)6G)Q3TJwBsITNMM0Lr8A50SpoWpEN6L0sxPcYAaSiPbKDZnHgiYT14OVFU9P8VP8lrr(Js(H8PUWiJKdaoDU6NGCMYFa0toQPGQJFCIV5yrCdqUPULt6c1P8avVP4tJM)7VZYrJcHniyspgnVcuq()EWdJgo98I18v8QMOyPAYT75LyUR17glvyTzdtdQlVYs3u8Y)8sCIjNNE2hypnepSGUSduO6pSQIPl1BFTKtnifjdZDjLuE3KAt4n5Wn5PkV4FzObyj29JXasrTmi1q3vvaS0HueBzFR5zmUwNMRVeCj7lpM9cv)DhL034V6OKwyFZrzymZxi9ZhvtuM(c1aLf7Bckl2szOehDNJRhcJ6C1OtOFXit4PLIk6fGMa7rdKVmBVw81N5fzn0az9orpK1w0xFUDQtfAtwwHCF174SoIZnKRb6sS8A14PcmYdJ)PPcjin7Ur8ON3PvH7Lsjo2(QDfvgw4B2oRUhVYvyxa9lB)6SdGm(3N72yBi4((H28n0H2u0eh8SK(S8M0QnIA1z589LiXNq0ZtIOwcNFT(1W)RsJZgsHkzQovnwmhKob0eHQQJEPGiSI4lQqVGF(BSI6lEVxl(WI5CHwOngxZolMhLJn8p9TGCATqWVo3AmyraGVAo8C3n7sXaSej9wztL)DcYprECvJaV84JVND5(FED7(PQ19kuROYu4BrnAQGgLRqcG5Xr8kLQYuqT9dxzqqhTxx(OD)izuyDsDOCeKv2euq8JcGODJyvtnziG)obTyoZlgfHasEtxSkurTrqL)pPWCTyre0Ew4RFnt06IMGsrJhPGJ4RIIwZoxNQPGPh1nGIysRTw368l81ZQkTGXPIrj58eACblRI6KTbxgccx)4O8n0J(xha87VMPsIbMZuPIOOrMdvfPQblBvTnMAQZzNActJvfZoROkYXc1TkoUOLXXZpUpAbHy2cjCj)HhLJnBXzSjVcpU8L4XZvoxmNjvo2fRce1URKvffDS2RwxltvfZmlr1s9O3uDQZVZ614sRhPkIP2LH7llXxsrGut3Nf2eotFuLkPq1KKpGslc2xZ9JxRqK095Qk9oPMuTFMOgfCsHk9GHpX02sttl7tb2niSgLIICekMeuccJFxE01QIuP2tLQotbPtLpp8fWWTyciCGSGpS0ZV6CQzLAXOjBeDsjN9eRKiy6GyGFvUZQkXn17fEIyCUAUs4SPc2Glg55f0UN64nfnrDKTgrav5Csvge1TezYvJmn0Axmy3fsf76P6Rsf1WN0p1LBkXgWoTqfzjWVn0lfDEELGtNxdoxOIWHXZIznCPy0RDb3OOIBUiLCtD8jKtsmMx9rc1W6XP8cYr5LNR0BpxxF95A19NlrlLxuoD82DuxvoDCz5uJejQvuMIwuLCICfmOo3lc(5u)d14ZIl7gG0Xt4nnNLl3vaPD3bKVIxceU8TvNFl)ulZ8SKDV08BiY1UCFU027xKc(5svXp1Zfwjz3PEtGnrLVivd0zRB19uwlBdGLxbrxHsiQSAi6SlIOoQkIySTQd6vOSIAZ(9t(7MuFrQl(bgAR7NPpTczYBu0UApQqXhvZQp6mk)OlF9h1Scq6SQaPgxcsSPAvhZD(QZryr)lY04BB9j1W89s9Rvzbkv(I07vD0djoCfVLlVuN3YfLPq5lXOkvFZbvNst13SbfZYQpLGsokMf0qeZt)xnZl()3llPANo1BX5ZM1M1K)Kh)8Rzqbk6vDNhu5yr6)crNkivFGJNLj9OkdTs)0X5k9VO1X58PizPCv(EUw1juT2arINjoL8S8o1Q9lCz8DLwYKYXxttNRcukuGMrel392QbSAwbvMd51Tco7Ws4Sj0DwbwwnQLurNDyjDklaKkuhv8LvIyXk8SdkXZMegHVqjZBn3IBJM8k(SRl5tzXzAS61(ka9Ckbuz1aA065IxKijlR5ti)kCmiTOWOA5zd2u499dr)L7HOx1hnuUvw7od9VVk6cuPLDlxupPZ7qOdZHn1knDSYFpSk5Zr2q28Sl6YUqFyrIGnMVHUTI)fERLT1PLA)C8)j)J18I)3p]]
)
spec:RegisterPack(
    "Arms (wowsims.com)",
    20261125000,
    [[Hekili:T31wZTTnw4Fl6HvHAsISKTvAA2ipt6M2TzNEBI7m9nrtlcjH1uKC5fR6oA8V99Ca4fqqasiQlX1Tp0ursWdo3phaIVKzJN9RZU21jHm7NoF05Vz84ZNmA0OzxN8qiz21HoZVZzj8dFN1WF(HO1XpEJ1MGnX01XdNhSEaoMh8cCCr6CBk1l5t(ZUvjjJdjZND9V9Hp)5p9ZF(DoaTMD9kQRlH)cK45kNH394njRipEt29oBrqe5Es0J34sw4K6L84nF4x(HhVbUn8l(RNspdNS4Z24efrdIoZnm(mNqp4pGbme(1W)BCG)GxbKoYXp2dywx43b4urbk446g4)c4h3rEiE4J38rNeN3PGfS(Xp9RarwLKeg)UZoBjnzv6TixFM0qha0e4uNBhTy0iYLlM)2laY(Vcc8Cd24hJZ9YLEGuckesmmvFK4KS6XB(nA8kyc(mz(DEK4yF4)Gz1Xlgy1BjRO(aBttG7HwQhVjMKKq9xcVrWIfWiEOqlHY61BiKq4XWVsIO3rqbfjat9g5mNc0fO(34fea397sJEaEPVHeftIUJt1VnnICNd(dVuFcQG(b6Yvjdaz5NJCP(orWmgKM4gGwdgXDt9xsc8F8gIpznfNZLeqtqCI8OOk8ZeCuSH6XKoWeHVCCcirWScK(FtD8tYz2pg5SmWhEcqi69aJFDiqlbPktH46Sg8CbDqGFkAc)50Kyq3Ick1nUygVN4963mchgo3lqPjgKVu)ehpIpZT4ApN1O)LNhytHx8XBw7q9F9kgfI3W5XpTomk4(YHhrwdxIg2vOHpHUMXIrK)xkfEgqA4L(vuX)BROrEBywsqM9NtqI6ec6rFMPjgUryQhAA8jeK1xeKgHx4eHg4m96RWFfKUCfojjadI8YNzQawOrX08QmzhzR1bXWFoEs(i9yxt9Z8jq(yi7vrxtMYIjfi9yQk(vC7nYbmxNi(K6CpCpKKBqD(sYq0w746ClZnN44H(3RtXj8wcND8io4LVzY)4FYIeGudLdf5kiY62SbYuUu0tYJUKceDyUVu8D0qm01hISaA7bkTxtxVgCybXYjcC)Yn)3cUyX5XkruYcpqF6SiHWCEbYN9wrKywIgKf(L7)wuLqrw6JKfe)ykJvi(OKHA3u0I9rW(h54r)dUN5kqjXD6FGBylcsyMwGIFVZ64eUFCm3rZpW)1C3syob9q6Ah)aMVlYhRjGGHAwFuBVzfHB0yoemb4B)DY80K8HaZWhwcEfO(f8GxbgAMrn0Z5bs0RQm)WZVNgd60hqpK75g5WWaFGYzAUqmTknH(haj(XGiiyPm8dtJgrCtrpzQpyYyeanJ8qfM0Kctpn5bH4QhyE1Fcz(O0WY4DbDmpjzmZsdtj1jHI6sE6WccvKvDiuCkkybiNZU2zoo24HHreUt005RqFHxbwlBWbWE5C3PJFfDX0ShpQFwXd7fuINBXvojyIjBUJuXD5eZMBn(p1MSxo9mN0KGSx2G5eYeeLKnC107wEEzsKngCHeHNXAinltKD1rmmZbvn1M745zZFGThno5vyb)PWiSr)t7SetQzK8y(6ILfwU1Uya2XoliduRj1qBymEW7HHpib7DB6IfdfV7W0Wojry25Ix8e4lCy8aaQeVczb7BDGgdkuXH3tY5coHUAKgMK))gUbYFr9N0Vx21b8QJt67syQ45qIymAnnu(o3FoWK48LLc4bBAEi7GT5Zz49HL3wK7dtxdjU(tiJZRcfNajbLmEU0ymjkeUbPFMEXiu40jBkmKBa)ujAC(KMOrFRECIm0dKmwOP7qwXUT8WdHBNgoqCklFsZYGHZVGeuHbeVVehCpDEsq0d2rPG77IG5PXC3F2Kfes8T3eebryT4my1Rsa5wRw8og0otuvf8vnRcouCv)EscUSlh44AhgG3Prl2Ln6113I1627FZOTstxf1suznvzYpPrBuBHMAcOzfZh6wuFVpYka3N1q7vtpFhD13lptdYoFv7zNDfA7RSS1o6DxrFoEKScfUtDDxpcVDp7WvoXK8CF1zNHyNrv8YY77RrpOUzI7HTVwmyk0kaED2LZJGL4cRN0g3QHPViV92x0xPKuWMnlaI5XnSWr218gDvpDLowHWAwNJkZvbBYDTYELQpcFTk(xRzDjBhZAsUBSQi5u3EtCQVl0VhBj0m7zLiQPJ7BvMJsyE7zvT)gMBa4UaU4yZsQTJd00jxhsdoODjBURD2ouiQ7u3cjlo0jzL9gAwtsSfRAdR7gxb07NMfBKpKHUPrS0EBRmURSMNTscvJ9Lw6OYzNpqNUPA62Y90HXKwz7Et8WSnpYwCi9R9uEt52U4Fc5(ujJIeODPu5OZKtLpJjPgiQXzB8uM3FC9eSsP(R4OY9IYVIVThcfj0m)TxXxNFuhCGfNR8vNWSo1LutwjrrAxwGiU7dRj2C62ykLgDruh7BGWDCcZBrnPiAOIWivVRibD5IE5dplhnFDJYpRspdvyOSxRi0O6dlcYgbAhgPHvtgfgSbxRnXX9bC5hkVFEqhiN5)UpB15EbxnDsjZu8EYms5dQWewGXLN1(oAimx(UB71OcCRg2Eqn7kJ9wrF)0SxNTsEp6AAYlhpbhUL6a1sFSbBZxD72mMK3ggNG6CWQ4TuWOIrVww6nD9Hv6F)WXvF0GTnzT7)3(C7Iph619uGp6BDuYpP2JRjdxL9MsWyFuypz)Q9SqtpDoR9fSwG6MxrAt(3sGBz3n(ctv1CCMuZayj(cfFXul7Cu(agpb(ff(wNprwk0kU8mPvTmQe5tvEVIPDNTOTzOQq5UyrmTbTl7wdeVvoc4Tsra16(Pfz4jw7p6318oSno5(6VF64j9vSP7Qw3Hn7txwz5uLpcEhHQu50klMRCfdLprm5(ANFNxbO8XSLdlTBtGRhp1657SZDl66(wskOTDCbUs9uPzxwWhvBBjIZ(S021xX)HreZUH02OSe)w5VyR6h6M)TZFrftrSNZ6kv3QeALz0ZEeow2wQ)ELJfm)ksny1lB3vSK)gvmYL9LP2AHUq4Nv3guEexqjuCJC3RPvhYRhn8c9lbDVJrFUSeLccW8uRSRvS7umyXHXmLf1qhp65)ImKtj9x31xCyCyyRl9GqP(188osH81Cb0AtmFbaMjUNkjSmzVgjZKK)xnvF2)wZzBn6LS02pBQtOOuFx8tQPokIaEZKT7z5(JKK3wfYwAjVNsnr)ENOvi(8VIMbRgVLfn1b)4E62viRkzC2AvRYGQuLxjNPCWt61OB8Aq)YSO5mlaYPsP)7Y01A(H5SdQPKxNy5vPa5XLv9VC0oShd6(iq7l)VIefqNNNxxRyCGpzeYRovFHz5wgRQoNkOoFZKoixY9iuqTVMDOe0xI(l3UEEY2Drt3X0NAzRAyJNY3ejW62LtU5lRFEnTSASTYc1B1hw0eN(Mm3rR87pFqr5gjBCFL24Qmq5tYkavPYh7y1uyWHvR0HiT8D2RTJg0Uh)0V(cWQ07Q0jgPc5379OQk1mBx36lVNBMN(lR9brzAymY5th1bBYb3cOscSek4T1s(4aUvEjHfJ(IQUzjR4Y8CpNWkTHGELiAqSfhr3YoRQ5IMToz2dXPw(y3PZ)Bxym1k96zpBKz1678(jD88rviMdLoh9tBzztAwwuBP8EoUygvkr8O7R9e73LfSO2Nl)UAH2rj3a(XSdn(CsystS0UUpEnZyftPmVvEw5MYQGBVaHYxD(s1jgR8fA)8IPySzNwmfpHDwXuXJLT1boQMYLfVGbCz9XMZL1FstCjHd(rZ4q(GBN7KgxgNjD3g5kejMXqWiqFv(EhHtvO4uAGeQA05YPQNXpvHDtC3tPTSxjHt7ipkTx2oti8ameTQupEIKg7QXF9KTs6qO0TG0jwWP253TPIspzpkVZUgQOedcNe(VXdZBmdU5Cijd)8NyWppBrJZ(MzxlyrXhMbBVzxZtcd))ikK0J6a)AFHM1SeG)mC6fahqJ8ayBkGfas)lKOFo9eaXLi9EAHjk1GIcfRl1iwC0D9NrjAIKevb)lGDCKOqPtM07)iGEmC2EtZZ25tQ5PGiwXewOmfwneZOeYmi38vTi7t2TjUo2Bud(g9ARswezV3kXEs8I5WQrozMbzZk5jXtq(SRzRse5zG)(6MvFF1KwjIjQ3dMivdYzOmmEuZcXLg5)lCaLQDcLAo2GwaZng3ixvqMBeuPcGwZixJ2sWOjT0EHvTDgSAAcyqvZbPILgGSXMaDLSQdLmJ03gKM)yGWnMOORmvb4UmYPUBEmhnOVXKm5Yvnkzk6sSnzk76UJjUgafhtaKRaMlav2zM9tiyZJCTnb798NaqJZG81c1GKrghVLAB(F3mjUgbMORVUPsEZWPPCXySjrU4xz2ICyXvPBqtXH3rhiESM)Ll6vwtPCrEvy)9C1LMJqVtde9ykbtxbMmg(0hlPc9E78xULLM4C5QDT4d3L4Rw7od5d5II6usv2BrvSRrFwfwoMkO(JXe6kNPnNzBBxSI8DMOXoK52syR2zpvUh4ZvzxpyLgDYk1SL7hwet1oKPQ)PcA7Bfy(hlyN)Abk)CbLFVGD6dgW8OK7Uq0vrVbuZr69KEMEF(77HEFpjyet)iOgLhRijvXCjvbrFJOnBx5(do1oRONsExUtsTjOLCB7CbqtpBnkb5gJLL7lTlS8H9OeDkqQOPhSOdDc3l01jDbR0zxbDw4lK7BTXPSlgsJBH14ZQPbNNcU6uUT3w70R1tgWtJw9UW4(OZp4zgTdnnSTJTbmsgxPRXAjKsQYh2qet2DitYyq5oK7ySulgP6OM8ebBsrnog3Mv85CMSRBNIKaDXXtPKDd1aVODKxWec5Q)fcHNZAL9cO60sUxqW0uS1C8bxJXjlmUTJNdRl0Q(X0CB3ak3Z5v2DHCFD)9k7oKEpSDg4WqQUJNrJYp0qfJlLBgvm96oGMZVqW5CVfFDngxVwZoaa0tfcq)ZxzQl11SEdnO0j)U66kr8H2carBVpLdUEX4E91w((Pa6r3v4J(mQy7LYRlQtBIYEGV09fGPhueM(LAVvUu336x5gDy8(aCQ3tJl1ToUmtMOq0jKPACEPg2jwPedTHg1D(JA2nMUS8U(JhldNTmXRdhxUw4bnYI8MbOV7HDbLQMiTvWVftOByzbhDiSEOSH1KQjYnY2P8VNQQHgVP9pLsUoX0t)GYnKSB4LLnV6AAmVyN85RRfG0EArs7jekTmLLCNKLQLUcBwdIzvGB2UffRB3LRCGToA7EzvQz2g4ECqGltz0(ozF4mCTc3wf4TTra32n7VUgFerfRYw4WOGodDxd6lRty3LjsA3o7wCP3jwwTTTEbGtmQENHjWVU4FPPM9xxqmvwQxUWOCFvvhzEhwSo30q7gpdQsWPM5sAOoqzD8DS4TUaAD1Uv(pAziH0fgzMWJapM7mwjStH)yBHNp1qzObjckddfug7vOyN2jIJtGAbWUvZF783xOzUucg5CfRWX8Eh0QLW(UcNBkoZpGanFxu3LWaVDUwbUZpGapxv2wDCnhI4TYXY4q)aaeDv5T1YLcW1UQ38r4S0Rgx6hAGPVlLB0k(7P0xU2KA4uFFaQUkKQlLOnRK7UKuq3(7F4(R5KNjB6oxxNW6uBfwI(7j3r9OpEJ13L9VI4Shp7)d]]
)

-- The hand-built lists the wowsims.com packs replace (wowsims packs plan, P9): a saved choice of one falls back to the
-- spec's default.
spec:RetirePacks({ "Arms", "Fury", "Protection" })
