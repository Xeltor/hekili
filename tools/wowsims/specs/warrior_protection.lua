-- tools/wowsims/specs/warrior_protection.lua (wowsims packs plan, Task 6): Protection (wowsims.com)'s wowsims/forever
-- request and translation. Values from wowsims/forever (MIT, https://github.com/wowsims/forever)
-- ui/specs/warrior/protection/presets.ts (ProtectionTalents :32, DefaultOptions :93-102, OtherDefaults :127-142) and spec.ts
-- (default gear: Pre-BiS (Defense Cap), prebis.gear.json) at the pin.
-- Disagreements (P7; floor 0.90): decisions on-GCD 0.904 (94) top [shield_slam -> demoralizing_shout 3; shield_slam ->
-- sunder_armor 3; rend -> shield_slam 1], on the tanked export (central fix 13: the target swings at us, 76 swings;
-- the incoming healing model; Revenge's window read through the aura-only map). Each disagreement once, wowsims ->
-- ours, at the log's time:
-- 1. shield_slam -> sunder_armor / demoralizing_shout / battle_shout (13.53, 19.53, 81.15, 123.15, 165.17, 171.17):
--    wowsims casts Shield Slam the instant its cooldown ends; the decision runs just before, while the client still
--    answers "on cooldown", so the belief pushes the ready time a probe (0.5 s, VirtualState CD_PROBE) out and a filler
--    ready now wins: replay limit (the decision instant at a cooldown's end).
-- 2. shatter_curse -> shield_slam (30.38): the Orc racial at 50% health; the replay does not replay our health, so
--    health.pct reads full: replay limit.
-- 3. rend -> shield_slam (85.65): Rend's condition needs cooldown.shield_slam.remains>=1.5; Shield Slam was cast at
--    81.15 on a 6 s cooldown, so wowsims reads exactly 1.5 and ours reads an ulp under it (the engine's clock sums):
--    replay limit (an exact tie at the GCD's length).
-- Worked: shield_slam -> thunder_clap (18 at 0.585): the state read a `shared = "target"` aura from the player's
-- debuffs, so Thunder Clap's debuff always read down (central GAP AJ fixed the read; the kit shares it on the target); the kit's talent costs (Focused Rage 1 a rank, on the shouts too) priced as wowsims logs them.
-- The replay does not replay the target's swings (replay limit: rage from damage taken reaches the belief only
-- through the truth's after-values); Revenge's window (25288, 5302 since e2842f0a78) is a hidden aura in the replay knobs.
-- Precombat calls no list (fix 16 does not reach this pack). Automatic cooldowns (rule 13): none in the log.
-- Re-pin 4b0030a44b (0.7 warrior lane): talents 05-05050005-150531120300001351 (presets.ts:32, the owner's #841 build), the APL's
-- precombat Bloodrage, Battle Shout, Battle Stance, Retaliation and Defensive Stance (Retaliation sits under the Cooldowns
-- toggle and needs Battle Stance), Heroic Strike at 20 rage, Revenge moved up, Reckless Swings (no talent in this build:
-- the line is never usable). Revenge's window is read by 25288 again (`auras` below).
-- Re-pin e2842f0a78 (Task 14): talents from presets.ts:32 ProtectionTalents (35301003002-03-050530120301011351),
-- hasBsT2 false (DefaultOptions; battle_shout.go:30-36: +30 attack power only), the APL's 5 changed lines (Revenge's
-- window read as 5302 in Bloodrage's condition, mapped by `auras`; "Battle Shout: No Raid Buff" folds to true solo),
-- prebis gear (5 slots; main hand 2.35 s as before). Omitted 23 -> 23 (+1 `dropped the unresolved aura 5302` until
-- the `auras` entry, then gone); the pack's lines are unchanged. No untagged GCD-0 kit cast in the log (melee OtherID
-- 3; Deep Wound 412609, unmapped, not fed). The R29 audit's stale request (it lacked the APL's new variable) is
-- re-exported. Kit and world regen not refreshed (rage from wowsims's own numbers, the
-- 11-02 catch-up ruling).
-- Disagreements (P7; floor 0.93 -> 0.98, decisions on-GCD 0.990 (97 of 98), n 98): shatter_curse -> shield_slam 45.03 (the Orc
-- racial at <= 50% health; the replay does not replay our health: the old class). Nothing else disagrees.
-- Thunder Clap's and Demoralizing Shout's `debuff.X.remains<=6` are wowsims's own refresh lines, kept as wowsims has
-- them (R47, owner 2026-11-05: a refresh in the debuff's last 6 s is a maintenance need, not a filler).
-- Measured after 5049ede22 (the replay's GCD end): 0.990 (98); ready-time real 3, all early (wowsims's queued Shield
-- Block holds the GCD; wowsims.lua M.READY); live 6.0 / 17.2 / 17.2 (was 10.2 / 14.6 at L40 / L60; rage-starved, gap
-- CK; L60 at its limit; the seeds 1-20 sweep behind the limits predates this export).
local melee = "&target.within5&!target.outside5"
local adventure = "prot_adventuring"
local combat = adventure .. "&combat>0"
local leveling = "prot_leveling&combat>0"
local revengeLeveling = leveling .. "&action.revenge.known"
local baselineDamage = "(!prot_leveling|!action.revenge.known)" -- Retain the original fillers before Revenge is trained.
local noMajorDefense = "(!action.last_stand.known|!buff.last_stand.up)&(!action.shield_wall.known|!buff.shield_wall.up)"
local charge = adventure .. "&combat=0&prot_charge_range"

local function rageBudget(spell, threat)
    return "(prot_bash_reserve=0|"
        .. (threat and "prot_threat_spend|" or "")
        .. "prot_current_rage>=action."
        .. spell
        .. ".cost+prot_bash_reserve)"
end

return {
    class = "WARRIOR",
    pack = "Protection (wowsims.com)",
    spec = "protection",
    name = "Protection",
    talentTree = "warrior",
    apl = "ui/specs/warrior/protection/apls/default.apl.json",
    player = {
        race = "RaceOrc",
        class = "ClassWarrior",
        gear = "ui/specs/warrior/protection/gear_sets/prebis.gear.json",
        talentsString = "05-05050005-150531120300001351",
        specKey = "protectionWarrior",
        options = {
            classOptions = {
                queueDelay = 250,
                startingRage = 0,
                useBattleShout = true,
                defaultStance = "WarriorStanceDefensive",
                hasBsT2 = false,
                stanceSnapshot = true,
            },
        },
        profession1 = "Engineering",
        profession2 = "Blacksmithing",
        reactionTimeMs = 100, -- apply_defaults.ts: `other.reactionTime || 100` (OtherDefaults sets none)
        distanceFromTarget = 0,
    },
    -- player-facing lines of the in-game description (the user's audit rulings, 2026-10-21)
    notes = {
        "Cooldowns toggle hides: Retaliation, Death Wish, Sweeping Strikes and the racials (Blood Fury, Berserking, Eureka, Elune's Light).",
        "Classic Primary can show low-health defensives even when the client hides your health. Healing potions use the Defensives toggle.",
        "Leveling opens with Charge and uses Defensive Stance with a shield. Vanguard lets you Charge without swapping stances.",
        "Leveling uses Revenge after a block, dodge or parry and favors Shield Slam once you can afford it. Shield Block and damage-reducing shouts favor melee pulls.",
        "Shield Bash stops casts in range. If it is unavailable, Concussion Blow can stop a cast on a non-boss after you learn it.",
        "Protection remembers NPC types that cast this session and saves Rage for an approaching Shield Bash. Dungeon threat takes priority on the opener or when you lose aggro.",
        "Use Disarm manually against enemies with a disarmable weapon.",
        "At level 60 the simulator's damage priority takes over. Enable Maintain Demoralizing Shout to use its normal maintenance line.",
    },
    -- a tank: the raid's tank (the target swings at it) and presets.ts:127-142's healing model (apply_defaults.ts:108-122)
    tank = true,
    healingModel = {
        hps = 815,
        cadenceSeconds = 0.3,
        cadenceVariation = 0.64,
        absorbFrac = 0.015,
        burstWindow = 6,
        inspirationUptime = 0.25,
    },
    -- the Revenge window (DB2 5302 Defensive State, 5 s), the kit's revenge_usable; wowsims logged and read it under
    -- Revenge's own ID (25288) before e2842f0a78, read 5302 at e2842f0a78 and reads 25288 again at 4b0030a44b
    auras = { [25288] = "revenge_usable" },
    exclusive = { [11556] = true }, -- Demoralizing Shout bids in wowsims's "Demoralizing" category (an exclusive effect)
    map = { [12723] = "sweeping_strikes" }, -- Sweeping Strikes's effect id (wowdb); the kit's ability is 12292
    -- the user's tiers (2026-10-21): Revenge 1 (its reactive window); Heroic Strike and Cleave always 2 (the owner's
    -- ruling, 2026-10-22); Victory Rush 1 on its extra line; Shield Slam, Bloodthirst, Mortal Strike and Sunder Armor rotational (untiered)
    focus = { revenge = 1, heroic_strike = 2, cleave = 2 },
    -- Rule 15: the raid debuff, a setting off in game and on in the harness (the user's ruling, 2026-10-21); Thunder
    -- Clap stays always on here, as wowsims has it (the user's ruling: not a Protection option)
    maintenance = { demoralizing_shout = { setting = "maintain_demoralizing_shout", orWhen = "prot_leveling" } },
    condition = {
        last_stand = false,
        shield_wall = false,
        stoneform = false,
        shatter_curse = false,
        healthstone = false,
    },
    guard = {
        -- Keep the leveling Charge and shield rules. The simulator opens with a stance swap for Retaliation.
        battle_stance = "!prot_leveling",
        defensive_stance = "!prot_leveling|equipped.shield",
        retaliation = "!prot_leveling",
        bloodrage = "(!prot_leveling|prot_bloodrage_safe)",
        shield_block = "!prot_leveling&" .. rageBudget("shield_block"),
        shield_slam = baselineDamage .. "&" .. rageBudget("shield_slam", true),
        revenge = "!prot_leveling&" .. rageBudget("revenge", true),
        thunder_clap = baselineDamage .. "&" .. rageBudget("thunder_clap", true),
        demoralizing_shout = "!prot_leveling&" .. rageBudget("demoralizing_shout"),
        rend = baselineDamage .. "&(!prot_leveling|!arms_skip_rend)&" .. rageBudget("rend"),
        sunder_armor = baselineDamage .. "&" .. rageBudget("sunder_armor", true),
        heroic_strike = baselineDamage .. "&" .. rageBudget("heroic_strike"),
        cleave = baselineDamage .. "&" .. rageBudget("cleave"),
        battle_shout = rageBudget("battle_shout"),
        death_wish = rageBudget("death_wish"),
        sweeping_strikes = rageBudget("sweeping_strikes"),
        bloodthirst = rageBudget("bloodthirst", true),
        mortal_strike = rageBudget("mortal_strike", true),
    },
    levelingFirst = {
        "defensive_stance,use_off_gcd=1,if="
            .. charge
            .. "&equipped.shield&talent.vanguard.enabled&action.charge.known&cooldown.charge.ready"
            .. "&!buff.defensive_stance.up&!buff.battle_stance.up&rage.lo<=stance_rage_kept",
        "battle_stance,use_off_gcd=1,if="
            .. charge
            .. "&action.charge.known&cooldown.charge.ready&!buff.battle_stance.up&!talent.vanguard.enabled&rage.lo<=stance_rage_kept",
        "charge,use_off_gcd=1,if=" .. charge,
    },
    extra = {
        {
            before = "death_wish",
            line = "shield_bash,if=" .. combat .. melee .. "&debuff.casting.up&debuff.casting.v2=0",
        },
        { before = "death_wish", line = "pummel,if=" .. combat .. melee .. "&debuff.casting.up&debuff.casting.v2=0" },
        {
            before = "death_wish",
            line = "concussion_blow,use_off_gcd=1,if="
                .. combat
                .. melee
                .. "&toggle.interrupts&debuff.casting.up&debuff.concussion_blow.down&!boss&!target.is_boss"
                .. "&(!action.shield_bash.known|!action.shield_bash.ready|debuff.casting.v2=1)"
                .. "&(!action.pummel.known|!action.pummel.ready|debuff.casting.v2=1)",
        },
        -- The translated defensives use the same conditions and HP cutoffs as the simulator, with a Primary cue.
        {
            before = "death_wish",
            line = "last_stand,use_off_gcd=1,display_below=40,if=!buff.last_stand.up&(!action.shield_wall.known|!buff.shield_wall.up)",
        },
        {
            before = "death_wish",
            line = "shield_wall,display_below=35,if=!buff.shield_wall.up&(!action.last_stand.known|!buff.last_stand.up)",
        },
        { before = "death_wish", line = "stoneform,display_below=50,if=" .. noMajorDefense },
        { before = "death_wish", line = "shatter_curse,display_below=50,if=" .. noMajorDefense },
        { before = "death_wish", line = "healthstone,use_off_gcd=1,display_below=30" },
        { before = "death_wish", line = "healing_potion,use_off_gcd=1,display_below=40,if=" .. combat },
        {
            before = "death_wish",
            line = "defensive_stance,use_off_gcd=1,if=" .. combat .. "&equipped.shield&!buff.defensive_stance.up",
        },
        { before = "death_wish", line = "bloodrage,use_off_gcd=1,if=" .. revengeLeveling .. "&prot_bloodrage_safe" },
        { before = "sweeping_strikes", line = "victory_rush,focus=1,if=" .. leveling .. melee },
        {
            before = "sweeping_strikes",
            line = "battle_shout,if=" .. leveling .. "&buff.battle_shout.down&" .. rageBudget("battle_shout"),
        },
        {
            before = "sweeping_strikes",
            line = "demoralizing_shout,if="
                .. leveling
                .. "&toggle.defensives&target.within10&!target.outside10&!execute_phase&debuff.demoralizing_shout.down"
                .. "&(active_enemies>1|prot_melee_target)&"
                .. rageBudget("demoralizing_shout"),
        },
        {
            before = "sweeping_strikes",
            line = "thunder_clap,if="
                .. revengeLeveling
                .. "&target.within8&!target.outside8&debuff.thunder_clap.down"
                .. "&(active_enemies>1|(prot_melee_target&!arms_short_pull))&"
                .. rageBudget("thunder_clap", true),
        },
        {
            before = "sweeping_strikes",
            line = "shield_slam,if="
                .. revengeLeveling
                .. melee
                .. "&(!buff.revenge_usable.up|cooldown.revenge.remains>0|rage.lo>=action.shield_slam.cost+action.revenge.cost)&"
                .. rageBudget("shield_slam", true),
        },
        {
            before = "sweeping_strikes",
            line = "revenge,focus=1,if=" .. leveling .. melee .. "&" .. rageBudget("revenge", true),
        },
        {
            before = "sweeping_strikes",
            line = "shield_block,use_off_gcd=1,if="
                .. leveling
                .. "&toggle.defensives&prot_melee_target&buff.shield_block.down"
                .. "&(!buff.revenge_usable.up|active_enemies>1|rage.lo>=40)&"
                .. rageBudget("shield_block"),
        },
        {
            before = "sweeping_strikes",
            line = "rend,if="
                .. revengeLeveling
                .. melee
                .. "&!arms_skip_rend&!execute_phase&debuff.rend.down&"
                .. rageBudget("rend"),
        },
        {
            before = "sweeping_strikes",
            line = "sunder_armor,if="
                .. revengeLeveling
                .. melee
                .. "&!execute_phase&((arms_open_world&arms_short_pull&debuff.sunder_armor.stack=0&rage.lo>=25)"
                .. "|((!arms_open_world|!arms_short_pull)&debuff.sunder_armor.stack<5))&"
                .. rageBudget("sunder_armor", true),
        },
        {
            before = "sweeping_strikes",
            line = "cleave,use_off_gcd=1,focus=2,if="
                .. revengeLeveling
                .. melee
                .. "&active_enemies>1&rage.lo>=40&"
                .. rageBudget("cleave"),
        },
        {
            before = "sweeping_strikes",
            line = "heroic_strike,use_off_gcd=1,focus=2,if="
                .. leveling
                .. melee
                .. "&active_enemies=1&((action.revenge.known&rage.lo>=40)|(!action.revenge.known&(!action.rend.known|arms_skip_rend)))&"
                .. rageBudget("heroic_strike"),
        },
        -- The simulator has no kill window. Keep the original max-level placement before Bloodthirst.
        { before = "bloodthirst", line = "victory_rush,focus=1,if=!prot_leveling" },
    },
}
