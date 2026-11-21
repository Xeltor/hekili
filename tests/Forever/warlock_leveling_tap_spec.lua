local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("level fourteen Warlock Life Tap", function()
    local function pull(options)
        local H = field.warlock("Affliction", 14, { 1454, 6222, 980, 705, 707, 689, 1120, 5019 }, {
            instanceType = options.dungeon and "party" or "none",
            group = options.dungeon and 5 or 0,
            classification = options.dungeon and "elite" or "normal",
            partyAggro = options.dungeon,
            health = options.health,
            mana = options.mana or 20,
            maxMana = 550,
            moving = options.moving,
            shooting = options.wanding,
            weapon = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 },
            shootUsable = true,
            items = { [6265] = 2 },
            talents = { [17810] = 5 },
            beforeLoad = function(h)
                h.ctl.regen[0] = { options.idleRegen or 0, 0 }
                h.ctl.stats[5] = 30 -- Rank 1 at 14 exchanges 20 + 8 + 30 = 58 health for mana.
                h.ctl.usable[1454] = { true, false }
            end,
        })
        if options.wanding then
            H.Fire("START_AUTOREPEAT_SPELL")
        end
        return H
    end

    local function tapCue(H)
        local cues = H.Hekili.Engine.Output.Primary.healthCues
        for i = 1, cues.n do
            if cues[i].action == "life_tap" then
                return cues[i]
            end
        end
    end

    it("offers rank one for a healthy outdoor Warlock who would otherwise keep wanding", function()
        local H = pull({ health = 1000, wanding = true })
        assert.are.equal("life_tap", field.pick(H))
    end)

    it("can use the instant Tap while moving in a dungeon party", function()
        local H = pull({ dungeon = true, health = 1000, moving = true })
        assert.are.equal("life_tap", field.pick(H))
    end)

    it("keeps a fresh affordable Corruption ahead of Tap on an engaged enemy", function()
        for _, dungeon in ipairs({ false, true }) do
            local H = pull({ dungeon = dungeon, health = 1000, mana = 60 })
            assert.are.equal("corruption", field.pick(H))
            assert.is_nil(tapCue(H))
        end
    end)

    it("replenishes at 40 percent mana and wands at 50 percent on a dotted dungeon mob", function()
        local H = pull({ dungeon = true, health = 1000, mana = 550 })
        field.cast(H, 6222)
        field.cast(H, 980)
        field.cast(H, 707)
        H.ctl.power[0] = 220
        H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
        assert.are.equal("life_tap", field.pick(H))
        H.ctl.power[0] = 275
        H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
        assert.are.equal("shoot", field.pick(H))
        assert.is_nil(tapCue(H))
    end)

    it("requires WoW to report the learned Life Tap usable for either the queue or the display cue", function()
        for _, health in ipairs({ 1000, SECRET }) do
            local H = pull({ health = health, wanding = true })
            H.ctl.usable[1454] = { false, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.are_not.equal("life_tap", field.pick(H))
            assert.is_nil(tapCue(H))
        end
    end)

    it("leaves Tap off the queue at full mana or below its combat health reserve", function()
        for _, scenario in ipairs({ { health = 1000, mana = 550 }, { health = 607, mana = 20 } }) do
            local H = pull(scenario)
            assert.are_not.equal("life_tap", field.pick(H))
            if scenario.mana == 550 then
                assert.is_nil(tapCue(H))
            end
        end
        assert.are.equal("life_tap", field.pick(pull({ health = 608 })), "the 58-point cost leaves exactly 550 HP")
    end)

    it("uses only a minimum-health display cue when the player's combat health is protected", function()
        local H = pull({ dungeon = true, health = SECRET, wanding = true })
        field.pick(H)
        assert.is_nil(H.ns.Facade.PlayerHealthFraction())
        local out = H.Hekili.Engine.Output.Primary
        for i = 1, out.count do
            assert.are_not.equal("life_tap", out.recs[i].actionName)
        end
        local cue = assert(tapCue(H), "missing display-only Tap")
        assert.are.equal(100, cue.percent)
        assert.is_near(60.8, cue.playerFloor, 0.001)
        H.ctl.unitHealthMax.player = SECRET
        H.Fire("UNIT_MAXHEALTH", "player")
        assert.are_not.equal("life_tap", field.pick(H))
        assert.is_nil(tapCue(H), "the health budget requires a readable maximum")
    end)

    it("tracks a protected mana pool from the pre-pull reading and casts before showing a protected Tap", function()
        local H = pull({ dungeon = true, health = 1000, mana = 400, idleRegen = 10 })
        local ctl = H.ctl
        ctl.power[0], ctl.unitHealth.player = SECRET, SECRET
        H.Fire("UNIT_HEALTH", "player")
        H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
        for _, id in ipairs({ 6222, 980, 707, 705 }) do
            ctl.usable[id] = { true, false }
        end
        H.Fire("SPELL_UPDATE_USABLE")
        field.pick(H)
        local VS = H.ns.VirtualState
        assert.is_true(VS.Power(0, ctl.now).hi >= 275, "pre-pull mana starts above the Tap threshold")
        assert.is_nil(tapCue(H))
        field.cast(H, 6222) -- 5/5 Improved Corruption makes this cast instant.
        field.cast(H, 980)
        field.pick(H, 2) -- Allow the full cast time between the preceding GCD and the successful hard cast.
        field.cast(H, 707)
        field.pick(H, 2.8)
        field.cast(H, 705)
        assert.is_nil(H.ns.Facade.PlayerHealthFraction())
        assert.is_true(VS.Power(0, ctl.now).hi < 275, "confirmed casts place even the upper bound below half mana")
        local out = H.Hekili.Engine.Output.Primary
        for i = 1, out.count do
            assert.are_not.equal("life_tap", out.recs[i].actionName)
        end
        assert.is_near(60.8, assert(tapCue(H)).playerFloor, 0.001)
    end)

    it("disarms the Tap cue when a combat stat change hides its Spirit cost", function()
        local H = pull({ health = SECRET, wanding = true })
        field.pick(H)
        assert.is_table(tapCue(H))
        H.ctl.stats[5] = SECRET
        H.Fire("UNIT_STATS", "player")
        assert.are_not.equal("life_tap", field.pick(H))
        assert.is_nil(tapCue(H))
        H.ctl.stats[5] = 40
        H.ctl.combat = false
        H.Fire("PLAYER_REGEN_ENABLED")
        field.pick(H)
        H.ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
        field.pick(H)
        assert.is_near(61.8, assert(tapCue(H)).playerFloor, 0.001)
    end)
end)
