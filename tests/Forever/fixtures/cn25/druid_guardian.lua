-- CN25 Guardian recipe from 0a49f4a5a, the revision that introduced the historical request beside it.
return {
    class = "DRUID",
    pack = "Guardian (wowsims.com)",
    spec = "guardian",
    name = "Guardian",
    talentTree = "druid",
    apl = "ui/specs/druid/feralbear/apls/adaptive.apl.json",
    player = {
        race = "RaceTauren",
        class = "ClassDruid",
        gear = "ui/specs/druid/feralbear/gear_sets/default.gear.json",
        talentsString = "050022-2322030212310212501-055",
        specKey = "feralBearDruid",
        options = { startingRage = 0, assumeBleedActive = true },
        profession1 = "Engineering",
        profession2 = "Enchanting",
        reactionTimeMs = 250,
        distanceFromTarget = 25,
    },
    -- a tank: the raid's tank (the target swings at it) and presets.ts:55-69's healing model (apply_defaults.ts:108-125)
    tank = true,
    healingModel = {
        hps = 2200,
        cadenceSeconds = 0.4,
        cadenceVariation = 1.2,
        absorbFrac = 0.02,
        burstWindow = 6,
        inspirationUptime = 0.25,
    },
    executePhase = "execute_phase",
    map = {},
    -- Faerie Fire's armor and Demoralizing Roar's attack power are exclusive effects (wowsims
    -- sim/core/debuffs_generated_test.go:326 with Curse of Recklessness, :446 with Demoralizing Shout): rule 10
    exclusive = { [9907] = true, [9898] = true },
    -- by role (docs/dev/wowsims-packs.md): Maul a rage dump as Heroic Strike ({ 1, 2 } by line; the leveling Maul,
    -- a literal, the second at 2); Lacerate (both lines) and Demoralizing Roar at 2
    focus = { maul = { 1, 2 }, lacerate = 2, demoralizing_roar = 2 },
    -- Before Primal Bite Maul is the only rage sink: queued whenever affordable instead of at
    -- wowsims's 20, which pools for the on-GCD strikes a low-level bear lacks (ruling L18; silent once Primal Bite is
    -- known). The re-pin's adaptive list maintains Faerie Fire (#14) and Demoralizing Roar (#16, "Attack-power reduction
    -- is covered") itself, whenever the debuff is down and at every level, above every strike: the leveling Roar and
    -- Faerie Fire lines R45 guarded were dead behind them and are gone (L47).
    -- Rule 15: the raid debuff, a setting off in game and on in the harness (the user's ruling, 2026-10-21)
    maintenance = { demoralizing_roar = "maintain_demoralizing_roar" },
    leveling = { "maul,use_off_gcd=1,focus=2,if=!action.primal_bite.known" },
    -- wowsims's sim starts in Dire Bear Form (its pre-pull shift only with Furor under 10 rage): the form first, as
    -- Balance's Moonkin Form (ruling L16); the re-pin's Faerie Fire line has no form gate, so a trailing line came after
    -- it. Silent in the replay (the log is in Bear Form from the pre-pull on).
    levelingFirst = { "bear_form,if=!buff.bear_form.up" },
}
