-- tools/wowsims/specs/paladin_protection.lua (wowsims packs plan, Task 9): Protection (wowsims.com)'s wowsims/forever
-- request and translation.
-- Values from wowsims/forever (MIT, https://github.com/wowsims/forever) ui/specs/paladin/protection/presets.ts:23
-- (DefaultTalents), :25-27 (DefaultOptions), :86-98 (OtherDefaults) at the pin; the APL and gear spec.ts's default.
-- Disagreements worked (P7, resume 3: after central fixes 6/8/C and 9/9b): replay 0.750 (28; wowsims's own Protection
-- is out of mana from 24 s, so few decisions) on an export with no tank, so the target never swung (GAP AE, central fix
-- 13: re-exported as the tank, 0.583 (48), the hits' and blocks' mana returns unmodelled; the notes below are the
-- untanked fight's). The tanked log carries {SpellID: 20423, Tag: 1}, a stacking counter wowsims logs beside the seal
-- 20423 and fades each few seconds; the replay drops such tagged lines (replay.lua), or the seal would vanish with it. 0.679 on the rebase alone (fix 6/8/C report: the replay's client now
-- reads the log's 2597 maximum); back to 0.750 once wowsims's character is booted with that maximum too, so the class
-- file prices Righteous Fury's 30% on it (on 6000, its short answers capped the belief at 779 under a true 1568).
-- holy_strike -> false 4 and seal_of_fury -> holy_strike 3: GAP R (central fix 12;
-- src/Hekili/Engine/Sim/State.lua): in combat the engine forecasts mana at GetManaRegen's in-five-second-rule rate
-- (this build's mp5 is 0) and never the spirit part after the window, so a spell short by a few mana is never shown
-- with a wait (measured with the window-aware rate: 0.964). The floor stays 0.75. [The OLD pin's state, see the re-pin
-- below:] Holy Shock is unconditional: the APL's Consecrated Ground (1310905) is never on the target (wowsims logs Consecration's 1280353), as in wowsims; the
-- build takes no Holy Shock. Lost to autocastOtherCooldowns (not translated): nothing cast.
-- Re-pin e2842f0a78 (Task 12; floor 0.62 -> 0.84): talents presets.ts DefaultTalents 050050002-05302102213301531-502
-- (was 50003-0530313321301531-5022; by spell ID: Improved Seals 3 -> 5, + Toughness 2, + Shieldsworn 1), the pin's
-- default gear, Human, no buffs in the request (R25 does not apply), executeProportion25/45/90 dropped; the log's
-- maximum is 2627 (was 2597) and its regen 1.73 / 0.08 a tick (was 1.738 / none). Omitted 2 -> 2. The APL now opens
-- with the Righteous Fury pre-pull (-20 s); Swift Judgement reads spellFullCooldown (`cooldown.judgement.duration`;
-- wowsims's inputDelay is 0 here, so the line holds whenever Judgement is known: deviation, off-GCD only); Holy Shock
-- reads talentIsKnown(1310905) as `talent.consecrated_ground.enabled` (the kit's talent, tree 0). The APL holds no
-- `wait` or `waitUntil` at the pin (dry: waitUntil 0), so there is nothing to carry (spec §3 names Protection: premise
-- void). Decisions on-GCD 0.846 (52) top [holy_shield -> holy_strike 6; seal_of_fury -> holy_strike 2] (log times):
--   holy_shield -> holy_strike (34.04, 45.00, 88.04, 103.90, 128.04, 163.00) and seal_of_fury -> holy_strike (108.04,
--   172.04): the belief is under the truth (lo 119-208) at each. Cause (Task 12 review): wowsims restores mana on
--   every LANDED Shieldsworn Holy Strike (talents_protection.go:161-170, ProcChance 100 at rank 2): all 26 landed Holy
--   Strikes give 105.08 mana tagged 1328544 (none on the miss at 31.50 or the dodges at 80.50, 173.54), unmodelled by the
--   kit (gaps.md CU). 45.00 (return 43.50), 103.90 (return 98.50, 5.4 s earlier) and 163.00 (return 161.50) follow such a
--   return, not a block (a block returns on every block, 3 s cooldown: Shield Specialization 1310925, unseen). Holy
--   Shield's price (before R31): ours 240 (DB2 70707) vs wowsims's 195 (both pins), kit unchanged; the log's mana just before the six
--   Holy Shield misses is 224.67, 223.71, 275.24, 196.22, 213.65, 238.48 (the other two misses are Seal of Fury's), five
--   of six under 240: the price is a necessary cause in 5 of the 8 (gaps.md CU).
--   [Superseded 2026-11-06, owner's tooltips (L15): Holy Shield has FOUR ranks, 100/150/195/240 mana at levels 30/40/50/60.]
--   R31 (owner fact): Holy Shield's max rank is 3 and costs 195; DB2 70707 carries the Era ladder one rank up (20925/
--   20927/20928 at levels 40/50/60, 150/195/240; wowsims 30/40/50, 100/150/195), so the kit's rank 3 is 195 now (ranks
--   1-2 and the learn levels stay the DB2's, owner item gaps.md CV). Replay 0.846 -> 0.885 (52), floor 0.84 -> 0.88;
--   45.00 and 163.00 agree. The 6 left (Holy Shield 34.04, 88.04, 103.90, 128.04; Seal of Fury 108.04, 172.04) have
--   the truth over the cost and the belief's lo under it (lo 119 / 161 / 171 / 22 / 162 / 23 vs truth 225 / 275 /
--   196 / 214 / 300 / 256): the unmodelled Shieldsworn Holy Strike return (gaps.md CU). Live L60 4.6 -> 4.4.
--   Fixed: Holy Shield's block hits {20928, Tag 2}, Shieldsworn's {20928, Tag 1328544} and Retribution Aura's {10301,
--   Tag 2} were replayed as our casts and restarted Holy Shield's believed cooldown (0.788 -> 0.846, wowsims_paladin_spec
--   PROT_REPLAY procs).
-- Regen: Paladin.lua's seeds and tests/Forever/helpers/paladin_world.lua's `fsr = { 17.38, 0 }` were not refreshed to this
-- log's 17.3 / 0.8 (within tolerance; lanes 10/11 precedent).
-- Re-pin 4b0030a44b (0.7): APL and gear are upstream's .siml files (translated the same as the .json), the log re-exported at
-- the new pin; Holy Shield now casts rank 4 (1239570, 240 mana: R31 retired, owner tooltips 100/150/195/240) and the replay world no longer drops it (L120).
-- The simulator's tanked raid priority stays in its original order. Short field pulls skip
-- the Crusader setup and use the equipped shield, current assignment and available mana.
local field = "prot_pal_field&prot_pal_attack_target"
local fight = field .. "&combat>0"
local groundFight = "prot_pal_field&combat>0"
local melee = "&target.within5&!target.outside5"
local judgement = "&target.within10&!target.outside10&prot_paladin_judgement_allowed"
local damageSeal =
    "((!prot_pal_tanking|!action.seal_of_fury.known)&(!seal_up|(action.seal_of_fury.known&buff.seal_of_fury.up)))"
local tankSeal = "prot_pal_tanking&buff.seal_of_fury.down"
local tankBuff = "buff.righteous_fury.down&prot_pal_maintain_fury"
local raidSetup = "(prot_pal_sustained|combat=0&prot_pal_raid_prep)"

-- These lead both lists, so a heal between pulls precedes a new seal or attack.
local preparation = {
    "holy_light,display_below=50,if=combat=0&toggle.defensives&prot_pal_big_heal",
    "flash_of_light,display_below=80,if=combat=0&toggle.defensives&prot_pal_cast_heal",
    "holy_light,display_below=80,if=combat=0&toggle.defensives&prot_pal_cast_heal",
    "righteous_fury,if=combat=0&" .. tankBuff,
    "retribution_aura,if=combat=0&prot_pal_field&prot_pal_aura_missing",
    "devotion_aura,if=combat=0&prot_pal_field&prot_pal_aura_missing&!action.retribution_aura.known",
    "seal_of_fury,focus=2,if=combat=0&prot_pal_field&" .. tankSeal,
    "seal_of_righteousness,if=combat=0&prot_pal_field&" .. damageSeal,
    "auto_attack,use_off_gcd=1,if=combat=0&prot_pal_start_attack",
}

local extra = {}
local function add(line)
    extra[#extra + 1] = { before = "templars_bulwark", translated = true, line = line }
end

local function addHealth(ability, percent, predicate)
    local action = ability
    if ability == "healthstone" or ability == "healing_potion" then
        action = ability .. ",use_off_gcd=1"
    end
    add(action .. ",if=health.known&health.pct<=settings." .. ability .. "_health&" .. predicate)
    add(action .. ",display_below=" .. percent .. ",if=!health.known&" .. predicate)
end

-- The client paints overlapping health bands in priority order. An available absorb buys time without
-- surrendering threat or draining mana. Reserve the instant full heal for imminent death.
add(
    "templars_bulwark,use_off_gcd=1,display_below=65,if=toggle.defensives&prot_pal_heavy_pressure&buff.templars_bulwark.down"
)
add(
    "templars_bulwark,use_off_gcd=1,display_below=45,if=toggle.defensives&prot_pal_combat_defense&buff.templars_bulwark.down"
)
local noShield = "(!action.divine_shield.known|!buff.divine_shield.up)"
addHealth("lay_on_hands", 15, "combat>0&toggle.defensives&prot_pal_emergency_heal&" .. noShield)
add("hammer_of_justice,display_below=45,if=toggle.defensives&prot_pal_stun_to_heal")
addHealth("healthstone", 30, "toggle.defensives&prot_pal_combat_defense")
addHealth("healing_potion", 40, "toggle.defensives&prot_pal_combat_defense")
addHealth("divine_shield", 20, "toggle.defensives&prot_pal_solo_immunity")
add("divine_protection,display_below=20,if=toggle.defensives&prot_pal_solo_immunity")
add(
    "hammer_of_justice,if=prot_pal_attack_target&combat>0&toggle.interrupts&debuff.casting.up"
        .. "&!boss&!target.is_boss&target.within10&!target.outside10&debuff.hammer_of_justice.down&pve_priority_interrupt"
)

-- Fury Judgement is a taunt. Only the recovery policy can promote it on an enemy we don't hold.
add("seal_of_fury,focus=2,if=prot_paladin_prepare_taunt")
add("judgement,use_off_gcd=1,if=prot_paladin_fury_taunt_ready")
add("swift_judgement,use_off_gcd=1,if=prot_paladin_fury_taunt_ready")
add("consecration,if=prot_paladin_ground_pickup&prot_pal_can_consecrate")
add("recover_threat,use_off_gcd=1,if=prot_paladin_recovery_pack")
add("holy_strike,if=prot_paladin_loose_melee&weapon.size>0")
add("judgement,use_off_gcd=1,if=prot_paladin_loose_target&prot_paladin_judgement_allowed")
add("swift_judgement,use_off_gcd=1,if=prot_paladin_loose_target&prot_paladin_judgement_allowed")
add("holy_shock,if=prot_paladin_loose_target")

add("holy_light,display_below=50,if=combat>0&toggle.defensives&prot_pal_big_heal")
add("flash_of_light,display_below=55,if=combat>0&toggle.defensives&prot_pal_cast_heal")
add("holy_light,display_below=55,if=combat>0&toggle.defensives&prot_pal_cast_heal")
add("flash_of_light,display_below=25,if=combat>0&toggle.defensives&prot_pal_desperate_solo_heal")
add("holy_light,display_below=25,if=combat>0&toggle.defensives&prot_pal_desperate_solo_heal")
add(
    "blessing_of_freedom,if=prot_pal_combat_defense&toggle.defensives&paladin_movement_control&!paladin_incapacitated"
        .. "&prot_pal_attack_target&target.outside5&prot_pal_self_utility&buff.blessing_of_freedom.down"
)
add(
    "cleanse,if=toggle.defensives&prot_pal_solo_dispel&(buff.dispellable_magic.up|buff.dispellable_poison.up|buff.dispellable_disease.up)"
)
add("purify,if=toggle.defensives&prot_pal_solo_dispel&(buff.dispellable_poison.up|buff.dispellable_disease.up)")
add(
    "holy_strike,if=toggle.defensives&prot_pal_heavy_pressure&prot_pal_attack_target&weapon.size>0&target.within5&!target.outside5"
        .. "&prot_pal_iron_creed_due"
)

add("righteous_fury,if=combat>0&" .. tankBuff)
add("auto_attack,use_off_gcd=1,if=combat>0&prot_pal_start_attack")
-- During a last-resort rescue only the preparation above may change seals.
add("seal_of_fury,focus=2,if=" .. fight .. "&" .. tankSeal .. "&!prot_paladin_last_resort")
-- A raid off-tank may have chosen a specific utility seal. Keep it until it expires.
add("seal_of_righteousness,if=prot_pal_attack_target&" .. damageSeal)
add(
    "holy_shield,focus=2,if=prot_pal_field&prot_pal_combat_defense&toggle.defensives&prot_pal_shield_pressure&buff.holy_shield.down"
)
add("consecration,if=" .. groundFight .. "&prot_pal_consecrate_pack")
add("holy_strike,if=" .. field .. melee .. "&weapon.size>0")
add("judgement,use_off_gcd=1,if=" .. field .. judgement .. "&prot_pal_spare_mana>=action.judgement.cost")
add("swift_judgement,use_off_gcd=1,if=" .. field .. judgement)
add(
    "hammer_of_wrath,if="
        .. fight
        .. "&!prot_pal_pack&(!moving|action.hammer_of_wrath.cast_time=0)"
        .. "&target.within30&!target.outside30&prot_pal_spare_mana>=action.hammer_of_wrath.cost"
)
add("exorcism,if=" .. field .. "&target.within30&!target.outside30&prot_pal_spare_mana>=action.exorcism.cost")
add(
    "holy_shock,if="
        .. field
        .. "&target.within20&!target.outside20&prot_pal_spare_mana>=action.holy_shock.cost"
        .. "&(!talent.consecrated_ground.enabled|debuff.consecrated_ground.up)"
)
add("consecration,if=" .. groundFight .. "&prot_pal_durable&prot_pal_can_consecrate&target.within8&!target.outside8")
add("retribution_aura,if=" .. fight .. "&prot_pal_aura_missing")
add("devotion_aura,if=" .. fight .. "&prot_pal_aura_missing&!action.retribution_aura.known")

return {
    class = "PALADIN",
    pack = "Protection (wowsims.com)",
    spec = "protection",
    name = "Protection",
    talentTree = "paladin",
    apl = "ui/specs/paladin/protection/apls/default.apl.siml",
    player = {
        race = "RaceHuman",
        class = "ClassPaladin",
        gear = "ui/specs/paladin/protection/gear_sets/default.gear.siml",
        talentsString = "050050002-05302102213301531-502",
        specKey = "protectionPaladin",
        -- PaladinOptions is an empty message: an object, not dkjson's default empty array
        options = { classOptions = setmetatable({}, { __jsontype = "object" }) },
        profession1 = "Engineering",
        profession2 = "Enchanting",
        reactionTimeMs = 100, -- defaults.siml: reaction_time 100ms, in_front_of_target
        inFrontOfTarget = true,
        distanceFromTarget = 5,
    },
    -- a tank: the raid's tank (the target swings at it) and presets.ts:92-99's healing model (apply_defaults.ts:108-122)
    tank = true,
    healingModel = {
        hps = 2200,
        cadenceSeconds = 0.4,
        cadenceVariation = 1.2,
        absorbFrac = 0.02,
        burstWindow = 6,
        inspirationUptime = 0.25,
    },
    -- 25903: Holy Shock rank 4's hostile spell (wowdb: 25903, range 40), the kit's 20930; 1311015: Templar's Bulwark, the
    -- major cooldown wowsims's autocastOtherCooldowns casts at the pull (log line 223: 110 mana, off the GCD)
    map = { [25903] = "holy_shock", [1311015] = "templars_bulwark" },
    focus = { seal_of_fury = 2, holy_shield = 2 },
    prepullSkip = { "righteous_fury" }, -- preparation supplies the same buff after any needed self-heal
    guard = {
        retribution_aura = raidSetup .. "&prot_pal_aura_missing",
        seal_of_the_crusader = raidSetup .. "&prot_pal_tanking&!seal_up",
        templars_bulwark = "target.is_dummy&prot_pal_sustained&prot_pal_tanking&toggle.defensives",
        stoneform = noShield,
        seal_of_fury = "prot_pal_sustained&prot_pal_tanking&!prot_paladin_last_resort",
        judgement = "prot_pal_sustained&prot_paladin_judgement_allowed",
        swift_judgement = "prot_pal_sustained&prot_paladin_judgement_allowed",
        holy_shield = "prot_pal_sustained&prot_pal_tanking&toggle.defensives&(target.is_dummy|prot_pal_shield_pressure)",
        holy_strike = "prot_pal_sustained&weapon.size>0",
        holy_shock = "prot_pal_sustained",
        consecration = "prot_pal_raid_prep&prot_pal_ground_safe&target.within8&!target.outside8",
        exorcism = "prot_pal_sustained",
    },
    levelingFirst = preparation,
    extra = extra,
    settings = {
        divine_shield_health = { default = 20, desc = "player health threshold, percent" },
        lay_on_hands_health = { default = 15, desc = "player health threshold, percent" },
    },
}
