-- tools/wowsims/specs/warrior_arms.lua (wowsims packs plan, Task 5): Arms (wowsims.com)'s wowsims/forever request and
-- translation. Values from wowsims/forever (MIT, https://github.com/wowsims/forever) ui/specs/warrior/dps/presets.ts
-- (ArmsTalents :102, DefaultOptions :143-152, OtherDefaults :169-175) at the pin; gear p1_arms (the spike's, a level
-- 60 set; the presets' default is the Fury build).
-- Re-pin e2842f0a78 (lane 14): hasBsT2 false (the pin's DefaultOptions; +30 AP only). Replay assumption (R42): the
-- replay world answers `fight_remains` from the log's known length (the game reads 3600, gap AN), so the translated
-- multipleCdUsages lines (Death Wish, Recklessness, the racials) follow wowsims's 180 s fight there and fire on
-- cooldown in game. Floor 0.91, on-GCD 0.917 (72; base 0.943) after the spellGcdHastedDuration fix (Slam's
-- `action.mortal_strike.gcd` read; 0.875 before) and the replay's GCD fix (a late-line GCD end cleared the client's
-- flag; the belief learned a 1.3 s GCD at 78.85). Disagreements, wowsims -> ours:
-- 1. berserker_rage -> battle_shout (-4.50): the ruled pre-pull gate (below).
-- 2. overpower -> execute (155.85): wowsims casts Overpower on a white swing's rage logged at the same instant (3.0 ->
--    20.1); the replay lands the swing one landing lag later and Overpower's window line reads the client's usability
--    now (short at 3.0), so ours shows Execute: replay limit (landing lag; item 2 below).
-- 3. execute -> sunder_armor (159.65): Sunder's five stacks fade on the cast's own timestamp, logged after the cast;
--    wowsims decides before the fade, ours sees the fade due: a same-instant tie.
-- Since the user's Berserker Rage ruling (2026-10-21; recipe `requires`): floor 0.89, on-GCD 0.896 (67): the build has no
-- Improved Berserker Rage, so the pre-pull Berserker Rage wowsims casts at -4.5 is gated off (berserker_rage ->
-- battle_shout at -4.50, a ruled deviation). Before it:
-- Disagreements (P7; floor 0.91, final): decisions on-GCD 0.910 (67) top [execute -> overpower 1; execute ->
-- sunder_armor 1; mortal_strike -> slam 1] after central fixes 7 (outcome belief), 13 and 16 (0.866 before them,
-- 0.836 before fix 6), with Improved Slam (12862) and Anger Management's 1.5 rage per 5 s (12296, DB2 aura 85)
-- modelled in the kit and the replay character at the build's 3.8 s Arcanite Reaper. Each disagreement once, wowsims
-- -> ours, at the log's time:
-- 1. execute -> overpower (165.08) and slam -> mortal_strike (64.08): wowsims casts 0.08 s after a tick crosses the
--    15 the cast costs (Anger Management 13.5 -> 15.0 at 165.00; Bloodrage 13.8 -> 15.3 at 64.00); the client answers
--    usability 0.1 s after a gain, so at the cast its last answer is still "short" (believed hi 14.99, the sim's
--    floor(lo) 14): replay limit (the usability answer's delay). At 64.08 the belief is also 1.3 short because
--    Improved Bloodrage 2/2's +50% on the periodic ticks (wowsims logs 1.5 a second) cannot be modelled: the belief's
--    aura regen entries take a fixed number, not a talent-rank-scaled one (shared gap, lane report); with 1.5 forced in
--    a scratch run the belief reads 14.99 there and agreement stays 0.910.
-- 2. execute -> sunder_armor (171.08), mortal_strike -> slam (110.28), spearing_strike -> sunder_armor (34.28): wowsims
--    casts on a white swing's rage logged at the same instant; the replay lands the swing one landing lag later (fix
--    6's M.LAND, as the client hears it): replay limit (landing lag).
-- 3. overpower -> sunder_armor (79.98): Bloodthrill's proc (1289682) opens the hidden window 0.09 s before the cast,
--    seen only by usability: replay limit (the 0.2 s tick).
-- Fixed since the provisional floor: sunder_armor -> rend (7.58, a dodged Sunder counted as a stack) and rend -> slam
-- (78.08, a missed Rend kept up) by fix 7's undo of an avoided cast's target auras; sunder_armor -> overpower (177.88)
-- no longer disagrees. Fix 6 cleared 45.68, 60.88 and 102.68 (the belief's rage at a same-instant swing, gap B).
-- Pre-pull: Berserker Rage at -4.5 and Battle Shout at -3 are on-GCD decisions and agree; Battle Stance,
-- Bloodrage, Charge and Blood Fury are off the GCD (not scored).
-- Automatic cooldowns (rule 13): cd_trinkets's two castAllStatBuffCooldowns entries cast nothing in the log (no
-- stat-buff cooldown in this gear): no lines; GAP 14 (autocastOtherCooldowns) costs Arms nothing (none in its APL).
-- Not a deviation: Blood Fury's cooldown is the DB2's 120 s; wowsims holds it to 180 s (queued at 3m), so from 120 s
-- our off-GCD icon shows it while wowsims waits (off the GCD: not scored).
local outdoorCombat = "arms_open_world&combat>0"
local pveCombat = "arms_pve_target&combat>0"
local melee = "&target.within5&!target.outside5"
local noLastStand = "&(!action.last_stand.known|!buff.last_stand.up)"
local noShieldWall = "&(!action.shield_wall.known|!buff.shield_wall.up)"

return {
    class = "WARRIOR",
    pack = "Arms (wowsims.com)",
    spec = "arms",
    name = "Arms",
    talentTree = "warrior",
    apl = "ui/specs/warrior/dps/apls/arms.apl.json",
    player = {
        race = "RaceOrc",
        class = "ClassWarrior",
        gear = "ui/specs/warrior/dps/gear_sets/p1_arms.gear.json",
        talentsString = "30325213132515201-0505-2",
        specKey = "dpsWarrior",
        options = {
            classOptions = {
                queueDelay = 250,
                startingRage = 50,
                useBattleShout = true,
                defaultStance = "WarriorStanceBerserker",
                hasBsT2 = false,
                stanceSnapshot = true,
            },
        },
        profession1 = "Engineering",
        profession2 = "Blacksmithing",
        reactionTimeMs = 100,
        distanceFromTarget = 25,
    },
    -- player-facing lines of the in-game description (the user's audit rulings, 2026-10-21)
    notes = {
        "Cooldowns toggle hides: Death Wish, Recklessness (also behind its pack setting, off by default), Sweeping Strikes and the racials (Blood Fury, Berserking, Eureka, Elune's Light).",
        "The endgame priority adapts as you learn abilities. Open-world pulls use earlier Rend and spend less rage on armor stacks.",
        "While leveling or fighting outdoors, Bloodrage favors low rage. Readable health must be at least 65%; hidden health in combat leaves it eligible.",
        "Rend skips known bleed-immune targets and backs off briefly after an immune result in PvE.",
        "With Defensives enabled, use Demoralizing Shout early on outdoor pulls.",
        "Hamstring slows non-boss PvE humanoids in melee range when they enter Execute range.",
        "PvE utility follows your Interrupts and Defensives toggles. Retaliation also follows Cooldowns.",
    },
    executePhase = "execute_phase",
    -- the user's ruling (2026-10-21): Berserker Rage only "if talented for the rage gain", precombat and in combat
    requires = { berserker_rage = "improved_berserker_rage" },
    map = { [12723] = "sweeping_strikes" }, -- Sweeping Strikes's effect id (wowdb); the kit's ability is 12292
    -- the user's tiers (2026-10-21): Rend's uptime and Overpower are focus; Mortal Strike, Slam and Execute rotational
    -- (untiered); Arms casts no Revenge. Heroic Strike and Cleave always 2, Victory Rush 1 on its extra line (the owner's
    -- ruling, 2026-10-22)
    focus = { overpower = 1, heroic_strike = 2, cleave = 2, rend = 2 },
    -- Rule 15: Thunder Clap, a setting off in game and on in the harness (the user's ruling, 2026-10-21); its only
    -- line is the leveling line below (the slow missing: a need, R41). Fury casts no Thunder Clap, so its recipe names
    -- none (rule 15 errors on a key with no cast line) and the setting is registered for Arms only.
    maintenance = { thunder_clap = "maintain_thunder_clap" },
    guard = {
        -- Bloodrage uses a health threshold only when the client supplies a readable value in combat.
        bloodrage = "arms_bloodrage_safe",
        sunder_armor = "!(arms_open_world&arms_short_pull)",
        rend = "!arms_skip_rend",
        -- When stance dancing, a swap for Overpower still makes sense if Rend is blocked.
        battle_stance = "!arms_skip_rend|!settings.wowsims_stance_dance|buff.overpower_ready.up",
    },
    leveling = {
        -- Until Rend is trained, Heroic Strike is the only damage spender. After that, keep rage for Rend and Overpower.
        "heroic_strike,use_off_gcd=1,focus=2,if=level<60&combat>0&!action.rend.known",
        -- One armor stack gives the early kit a useful alternative against a bleed-immune short pull.
        "sunder_armor,if="
            .. outdoorCombat
            .. "&arms_short_pull&arms_skip_rend&!action.mortal_strike.known&!execute_phase&debuff.sunder_armor.stack=0",
        "heroic_strike,use_off_gcd=1,focus=2,if=!action.mortal_strike.known&(rage.lo>=40|(!arms_open_world|arms_skip_rend)&rage.lo>=30)",
        "thunder_clap,if=!action.mortal_strike.known&!debuff.thunder_clap.up",
        "sunder_armor,if=!action.mortal_strike.known&debuff.sunder_armor.stack<5&!(arms_open_world&arms_short_pull)",
    },
    -- Situational PvE utility and short outdoor pulls use the same underlying damage priority.
    extra = {
        {
            before = "call_action_list",
            line = "shield_bash,if=" .. pveCombat .. melee .. "&debuff.casting.up&debuff.casting.v2=0",
        },
        {
            before = "call_action_list",
            line = "pummel,if=" .. pveCombat .. melee .. "&debuff.casting.up&debuff.casting.v2=0",
        },
        { before = "call_action_list", line = "healthstone,use_off_gcd=1,display_below=30,if=" .. pveCombat },
        { before = "call_action_list", line = "shield_wall,display_below=25,if=" .. pveCombat .. noLastStand },
        {
            before = "call_action_list",
            line = "last_stand,use_off_gcd=1,display_below=35,if=" .. pveCombat .. noShieldWall,
        },
        {
            before = "call_action_list",
            line = "victory_rush,focus=1,if=" .. outdoorCombat,
        },
        {
            before = "call_action_list",
            line = "victory_rush,focus=1,display_below=75,if=" .. pveCombat .. "&!arms_open_world",
        },
        {
            -- Icy Veins advises keeping a healing potion ready for dangerous leveling pulls.
            before = "call_action_list",
            line = "healing_potion,use_off_gcd=1,display_below=40,if=" .. pveCombat .. "&(level<60|arms_open_world)",
        },
        {
            before = "call_action_list",
            line = "retaliation,display_below=45,if="
                .. outdoorCombat
                .. melee
                .. "&toggle.defensives&active_enemies>=2"
                .. noLastStand
                .. noShieldWall,
        },
        {
            before = "call_action_list",
            -- Icy Veins' Forever leveling priority puts the shout after Victory Rush and before Rend.
            line = "demoralizing_shout,if="
                .. outdoorCombat
                .. "&target.within10&!target.outside10&toggle.defensives&!execute_phase&debuff.demoralizing_shout.down",
        },
        {
            before = "call_action_list",
            line = "hamstring,if="
                .. pveCombat
                .. melee
                .. "&!boss&!target.is_boss&target.creature_type='humanoid'&execute_phase&debuff.hamstring.down",
        },
        -- Keep the upstream kill-window placement as well. The ability itself checks for Victorious.
        { before = "mortal_strike", line = "victory_rush,focus=1" },
        {
            before = "slam",
            line = "bloodrage,use_off_gcd=1,if="
                .. pveCombat
                .. "&(level<60|arms_open_world)&rage.lo<=15&arms_bloodrage_safe",
        },
        {
            before = "slam",
            line = "rend,focus=2,if=" .. outdoorCombat .. "&!arms_skip_rend&!execute_phase&debuff.rend.down",
        },
        {
            before = "heroic_strike",
            line = "heroic_strike,use_off_gcd=1,focus=2,if="
                .. outdoorCombat
                .. "&arms_short_pull&action.mortal_strike.known&!execute_phase&active_enemies=1&rage.lo>=65",
        },
    },
}
