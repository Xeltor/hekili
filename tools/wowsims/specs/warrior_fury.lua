-- tools/wowsims/specs/warrior_fury.lua (wowsims packs plan, Task 6): Fury (wowsims.com)'s wowsims/forever request and
-- translation. Values from wowsims/forever (MIT, https://github.com/wowsims/forever) ui/specs/warrior/dps/presets.ts
-- (FuryTalents :73, DefaultOptions :143-152, OtherDefaults :169-175) at the pin; gear p1_fury (a level 60 dual-wield set).
-- Re-pin 4b0030a44b (0.7 warrior lane): talents 30303213002-350530005122100231-1 (presets.ts:74; Reckless Swings 1329555 takes
-- Raging Blows's slot, Flurry and Improved Tactical Mastery cut to 3 ranks, Improved Intercept to 2), the Fury APL's new
-- Reckless Swings lines (precombat -1.5 s and priority #28), Spearing Strike and the Cleave 25 rage line, the Rend weave on
-- one target only. This build takes Improved Berserker Rage 2/2, so the `requires` gate below now passes: Berserker Rage
-- shows at -4.5 and in combat as wowsims casts it (the ruled pre-pull deviation applies to Arms only). Omitted: Spearing
-- Strike's Dragonkin/Giant sequence (default #15 `targetIsMobType`: the build has no Spearing Strike, the target is
-- Mechanical; blocker note warrior-2) and Bloodrage #29 (`autoTimeToNext`, translator-5).
-- Re-pin e2842f0a78 (lane 14): talents 30305213002-15053105102210501 (presets.ts), hasBsT2 false. Replay assumption
-- (R42): the replay world answers `fight_remains` from the log's known length (the game reads 3600, gap AN), so the
-- translated multipleCdUsages lines (Death Wish, Recklessness, the racials) follow wowsims's 180 s fight there and fire
-- on cooldown in game. Floor 0.85, on-GCD 0.851 (87; base 0.922), owner ruling R46: the new Overpower Weaving group
-- (kept by the actionGroupUsed fix) swaps to Battle Stance on our dodge row alone, and the belief holds an avoid on our
-- own swing provisional until the swing ticket closes (1.5 s main hand, 2.0 s off hand), so the row reaches the kit
-- 1.57-2.17 s after the dodge while wowsims swaps and casts 0.1-1.1 s after it: overpower -> bloodthirst / whirlwind /
-- execute (3, 3, 2). In game the swap shows about 2 s late. Omitted: Bloodrage #26 (`autoTimeToNext` MeleeAuto, no
-- translator rule; R42 item 2). The loop world's off hand (warrior_world.lua FURY_SPEED 1.9 s) is not refreshed to the
-- build's 2.4 s (17016); the replay reads the log's swings.
-- Since the user's Berserker Rage ruling (2026-10-21; recipe `requires`): floor 0.91, on-GCD 0.917 (60): the build has no
-- Improved Berserker Rage, so the pre-pull Berserker Rage wowsims casts at -4.5 is gated off (berserker_rage ->
-- battle_shout at -4.50, a ruled deviation). Before it:
-- Disagreements (P7; floor 0.93, final): decisions on-GCD 0.933 (60) top [sunder_armor -> bloodthirst 2; death_wish ->
-- sunder_armor 1; overpower -> bloodthirst 1] after central fixes 7, 13 and 16 (0.817 before, with GAP AD: precombat's
-- in-combat filter did not reach pre_pull_move, so Intercept showed all fight; fix 16 closed it). Each disagreement
-- once, wowsims -> ours, at the log's time: sunder_armor -> bloodthirst (89.82): our Sunder stacks read 5 where
-- wowsims's are 4: fix 7 undoes the Sunder missed at 81.32, but the one missed at 86.82, 0.04 s after our off-hand
-- swing, is never attributed to our cast, so its stack stays (believed 4 while the client lists 3 from 86.82; the
-- belief re-reads stacks only on an aura change): shared gap (the avoid's attribution, lane report); sunder_armor -> bloodthirst (133.04): a same-instant crit swing's rage (replay
-- limit, landing lag); overpower -> bloodthirst (69.51): believed rage 0.0 under the truth's 10.8: an
-- off-hand crit (67.90, +9.86) and our Whirlwind (67.91, 25) in one frame leave the belief at 0.0 against the truth's
-- 4.88 for 1.6 s (the crit's extra step is not credited after the cast's success lift: shared gap, lane report), then
-- the off-hand swing at 69.42 lands 0.09 s before the cast (replay limit, landing lag). Unbridled Wrath's procs (1 rage
-- a proc) are the kit's measured ~7.5% a rank (Warrior.lua rageOf); wowsims procs 85 of 140 landed white hits (60%,
-- the tooltip): wowsims quirk, kept (Forever measured);
-- death_wish -> sunder_armor (0.00): wowsims is 6 yd away after Intercept's travel and cannot Sunder yet; the engine
-- does not gate Sunder on melee range (replay limit). Fix 16 cleared 57.09, 67.91, 76.16, 117.06 and 138.30; 62.81
-- and 88.32 no longer disagree.
-- Historical WoWSims fallback, still used on sustained targets: Sunder below 5 stacks while Bloodthirst is unlearned
-- (levels 10-40 idled 7.4 s and 8.2 s over the
-- 60 bracket's 6.8 s with only Rend's or Whirlwind's wait left); silent at 60. At 5 stacks it stays silent (fix 18).
-- The leveling Hamstring (out of Battle Stance while Bloodthirst is unlearned) is gone (R41: not a PvE rotation ability,
-- pressed only to fill the idle GCD); the idle it filled is a measured per-bracket limit
-- (tests/Forever/wowsims_warrior_spec.lua). wowsims's own Windfury-gated "Hamstring Weave" line (7373) stays.
-- Replay knobs (tests/Forever/wowsims_warrior_spec.lua): Whirlwind's off-hand hit (1680 Tag 15) is a hit, not a cast;
-- the Heroic Strike queue (25286 Tag 1) is an aura the client never shows; the main hand's 2.1 s period (the log's
-- first two main-hand swings are 4.2 s apart: Heroic Strike replaced one).
-- Automatic cooldowns (rule 13): cd_trinkets's castAllStatBuffCooldowns cast nothing in the log: no lines.
-- Icy Veins' Forever Fury leveling guide (November 16, 2026) uses Battle Stance and Rend before
-- Whirlwind, then Berserker Stance and the trained direct attacks. The raid build keeps its WoWSims weaves.
local field = "warrior_field&warrior_attack_target&combat>0"
local melee = field .. "&target.within5&!target.outside5"
local interrupt = "warrior_pvp_interrupt|(arms_pve_target&warrior_attack_target&combat>0"
    .. "&target.within5&!target.outside5&debuff.casting.up&debuff.casting.v2=0)"
local burst = "!warrior_field|(" .. melee .. "&(warrior_durable|warrior_nearby_enemies>1))"
local healingSpent = "(!talent.gore_drinker.enabled|buff.gore_drinker.down)"
local holdBattle = "(fury_whirlwind_available&fury_overpower_opportunity&fury_overpower_window)"
local battle = "action.battle_stance.known&(!action.battle_stance.known|buff.battle_stance.up)"

return require("tools.wowsims.warrior_dps")({
    class = "WARRIOR",
    pack = "Fury (wowsims.com)",
    spec = "fury",
    name = "Fury",
    talentTree = "warrior",
    apl = "ui/specs/warrior/dps/apls/fury.apl.json",
    player = {
        race = "RaceOrc",
        class = "ClassWarrior",
        gear = "ui/specs/warrior/dps/gear_sets/p1_fury.gear.json",
        talentsString = "30303213002-350530005122100231-1",
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
        "Before Whirlwind, use Rend and low-Rage Overpower. After training Whirlwind, favor Berserker Stance. Take a low-Rage Overpower window when the switch retains your Rage and your main attacks have to wait.",
        "During nonraid pulls, save Sunder Armor for durable targets and stagger health-spending Rage abilities with Gore Drinker healing.",
        "Shield Bash and Pummel follow Interrupts. Recovery items and Demoralizing Shout follow Defensives.",
    },
    executePhase = "execute_phase",
    -- the user's ruling (2026-10-21): Berserker Rage only "if talented for the rage gain", precombat and in combat
    requires = { berserker_rage = "improved_berserker_rage" },
    map = { [12723] = "sweeping_strikes" }, -- Sweeping Strikes's effect id (wowdb); the kit's ability is 12292
    -- the user's tiers (2026-10-21): Bloodthirst and Whirlwind rotational (untiered); Overpower 1; Heroic Strike and
    -- Cleave always 2 (the owner's ruling, 2026-10-22, superseding { 1, 2 }); Victory Rush 1 on its extra line; Rend 2
    -- (the rend weave); Battle Stance 1 (overpower_weaving's swap, Fury's only Battle Stance line). A tier is static:
    -- the weave's lines carry theirs whether Rend Weave is on or off.
    focus = { overpower = 1, heroic_strike = 2, cleave = 2, rend = 2, battle_stance = 1 },
    -- the user's ruling (2026-10-21): "guard against recommending battle stance if there won't be enough time or rage
    -- to cast overpower". wowsims's swap (overpower_weaving #2: Overpower: Can Cast, i.e. the Delay Check, not the
    -- execute phase, the window up with 5 <= rage <= 100, and gcd 0) checks the rage before the swap only: below
    -- Tactical Mastery (level 14; Overpower is 12) the swap keeps no rage, and it never reads Overpower's 5 s cooldown
    -- against the 5 s window. The guard: the rage a swap keeps (the kit's stance_rage_kept: Tactical Mastery's 10, its
    -- improvement's 5 a rank) pays for Overpower, and Overpower is ready before the window closes. A deviation
    -- (docs/dev/wowsims-packs.md).
    guard = {
        -- A field stance swap for Overpower should not discard Rage. The raid dance retains its own bounds.
        battle_stance = "(!warrior_field|("
            .. melee
            .. "&fury_overpower_opportunity&fury_overpower_window&rage.hi<=stance_rage_limit"
            .. "&action.berserker_stance.known&(!action.berserker_stance.known|buff.berserker_stance.up)))"
            .. "&(!action.overpower.known|(stance_rage_kept>=action.overpower.cost"
            .. "&cooldown.overpower.remains<buff.overpower_ready.remains))",
        overpower_weaving = "!warrior_field|(" .. melee .. "&fury_overpower_opportunity)",
        berserker_stance = "!warrior_field",
        whirlwind = "!warrior_field|(combat>0&target.within8&!target.outside8)",
        rend = "!warrior_field",
        sunder_armor = "!warrior_field&!warrior_pvp_target",
        death_wish = burst,
        recklessness = burst,
        cd_racials = burst,
        sweeping_strikes = "!warrior_field|(" .. melee .. "&warrior_nearby_enemies>1)",
        heroic_strike = "!warrior_field|("
            .. melee
            .. "&(fury_whirlwind_available|action.bloodthirst.known)&rage.lo>=65)",
        cleave = "!warrior_field",
        reckless_swings = "warrior_attack_target&(!warrior_field|(warrior_reckless_safe&" .. healingSpent .. "))",
        bloodrage = "!warrior_field|(warrior_field_bloodrage_safe&" .. healingSpent .. ")",
        berserker_rage = "!warrior_field|(" .. field .. "&rage.lo<=25&" .. healingSpent .. ")",
    },
    leveling = {
        "sunder_armor,if=!warrior_field&!warrior_pvp_target&warrior_attack_target&!action.bloodthirst.known&debuff.sunder_armor.stack<5",
    },
    extra = {
        { before = "call_action_list", line = "shield_bash,if=" .. interrupt },
        { before = "call_action_list", line = "pummel,if=" .. interrupt },
        {
            before = "call_action_list",
            line = "healthstone,use_off_gcd=1,display_below=30,if=arms_pve_target&combat>0",
        },
        { before = "call_action_list", line = "healing_potion,use_off_gcd=1,display_below=40,if=" .. field },
        { before = "call_action_list", line = "victory_rush,focus=1,if=" .. melee },
        {
            before = "call_action_list",
            line = "demoralizing_shout,if="
                .. field
                .. "&toggle.defensives&target.is_targeting_player&debuff.casting.down&!execute_phase"
                .. "&target.within10&!target.outside10&(warrior_durable|warrior_nearby_enemies>1)&debuff.demoralizing_shout.down",
        },
        {
            before = "call_action_list",
            line = "thunder_clap,if="
                .. field
                .. "&!fury_whirlwind_available&target.within8&!target.outside8&warrior_nearby_enemies>1"
                .. "&!fury_wait_for_bash",
        },
        -- Shift immediately if the swap keeps all confirmed Rage. With excess Rage, take an available
        -- Bloodthirst or Execute in Battle Stance before shifting to gain access to Whirlwind.
        {
            before = "call_action_list",
            line = "berserker_stance,use_off_gcd=1,if="
                .. field
                .. "&fury_whirlwind_available&"
                .. battle
                .. "&!execute_phase&rage.lo<=stance_rage_kept&!"
                .. holdBattle,
        },
        {
            before = "execute",
            line = "whirlwind,if=" .. field .. "&target.within8&!target.outside8&(!execute_phase|warrior_durable)",
        },
        { before = "execute", line = "bloodthirst,if=" .. melee .. "&(!execute_phase|warrior_durable)" },
        {
            before = "heroic_strike",
            line = "berserker_stance,use_off_gcd=1,if="
                .. field
                .. "&fury_whirlwind_available&"
                .. battle
                .. "&!"
                .. holdBattle,
        },
        {
            before = "heroic_strike",
            line = "cleave,use_off_gcd=1,focus=2,if="
                .. melee
                .. "&warrior_nearby_enemies>1&rage.lo>=40&(!fury_whirlwind_available|rage.lo>=65)",
        },
        {
            before = "heroic_strike",
            line = "rend,focus=2,if="
                .. melee
                .. "&"
                .. battle
                .. "&settings.wowsims_rend_weave&!fury_whirlwind_available&!arms_skip_rend&!execute_phase&debuff.rend.down",
        },
        {
            before = "heroic_strike",
            line = "sunder_armor,if="
                .. melee
                .. "&!execute_phase&((warrior_durable&debuff.sunder_armor.stack<5)|"
                .. "warrior_sustained_target&!fury_whirlwind_available&(debuff.sunder_armor.stack<2|debuff.sunder_armor.remains<=3))"
                .. "&rage.lo>=action.sunder_armor.cost+fury_sunder_reserve",
        },
        {
            before = "heroic_strike",
            line = "heroic_strike,use_off_gcd=1,focus=2,if="
                .. melee
                .. "&!fury_whirlwind_available&!action.bloodthirst.known&!execute_phase&warrior_nearby_enemies<=1"
                .. "&(!action.rend.known|(!fury_maintains_rend|debuff.rend.remains>gcd.max))"
                .. "&rage.lo>=action.heroic_strike.cost+fury_heroic_reserve",
        },
        -- The kill window is absent in the simulator. Preserve its original placement on sustained fights.
        {
            before = "bloodthirst",
            translated = true,
            line = "victory_rush,focus=1,if=!warrior_field&warrior_attack_target",
        },
    },
})
