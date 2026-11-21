local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function wound(h, unit, amount, school)
    h.Fire("UNIT_COMBAT", unit, "WOUND", "", amount, school)
end

describe("Forever Warlock Shadow Ward", function()
    it("reacts to recent pure Shadow wounds on the player with a hidden amount and no selected target", function()
        local h = field.warlock("Affliction", 32, { 6229 }, { noTarget = true, moving = true, health = SECRET })
        assert.is_not_equal("shadow_ward", field.pick(h))
        for _, school in ipairs({ 1, 4, 6, 36, SECRET }) do
            wound(h, "player", 50, school)
        end
        wound(h, "player", 0, 32)
        wound(h, "target", 50, 32)
        wound(h, "pet", 50, 32)
        h.Fire("UNIT_COMBAT", "player", "HEAL", "", SECRET, 32)
        h.Fire("UNIT_COMBAT", "player", "RESIST", "", 0, 32)
        assert.is_not_equal("shadow_ward", field.pick(h))
        wound(h, "player", SECRET, 32)
        assert.are.equal("shadow_ward", field.pick(h))
        assert.is_not_equal("shadow_ward", field.pick(h, 5))
    end)

    it("requires a learned Ward, its defensive toggle, mana and a missing absorb", function()
        for _, case in ipairs({
            { {}, {}, "unlearned" },
            { { 6229 }, { defensives = false }, "defensives disabled" },
            { { 6229 }, { buffs = { 6229 } }, "absorb active" },
            { { 6229 }, { mana = 1, maxMana = 100 }, "insufficient maximum mana" },
        }) do
            local h = field.warlock("Destruction", 32, case[1], case[2])
            wound(h, "player", 50, 32)
            assert.is_not_equal("shadow_ward", field.pick(h), case[3])
        end
    end)

    it("drops wounds from an earlier fight or world", function()
        local h = field.warlock("Demonology", 60, { 11740 }, { instanceType = "raid", group = 10 })
        wound(h, "player", 50, 32)
        assert.are.equal("shadow_ward", field.pick(h))
        h.ctl.combat = false
        h.Fire("PLAYER_REGEN_ENABLED")
        wound(h, "player", 50, 32)
        h.ctl.combat = true
        h.Fire("PLAYER_REGEN_DISABLED")
        assert.is_not_equal("shadow_ward", field.pick(h))
        wound(h, "player", 50, 32)
        assert.are.equal("shadow_ward", field.pick(h))
        h.Fire("PLAYER_ENTERING_WORLD", false, true)
        assert.is_not_equal("shadow_ward", field.pick(h))
    end)

    it("excludes wounds beside a Life Tap or mana rune, in either event order", function()
        local h = field.warlock("Demonology", 60, { 6229, 11689 })
        for _, id in ipairs({ 11689, 16666, 27869 }) do
            wound(h, "player", SECRET, 32)
            h.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-self", id)
            wound(h, "player", SECRET, 32)
            assert.is_not_equal("shadow_ward", field.pick(h))
            assert.is_not_equal("shadow_ward", field.pick(h, 1.6))
        end
        wound(h, "player", SECRET, 32)
        assert.are.equal("shadow_ward", field.pick(h))
    end)

    it("excludes self damage throughout a Health Funnel and resumes after an interrupted channel", function()
        local h = field.warlock("Affliction", 32, { 6229, 755 }, { petHealth = 950 })
        local t = h.ctl.now
        h.ctl.channel = { t * 1000, (t + 10) * 1000, spell = 755 }
        h.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-funnel", 755)
        field.pick(h, 3)
        wound(h, "player", SECRET, 32)
        field.pick(h)
        local state = h.Hekili.State
        state.reset("Primary")
        assert.is_false(state.warlock_recent_shadow_damage)
        local remainingTicks = 0
        for _, event in ipairs(state.queue) do
            if event.action == "health_funnel" and event.type == "CHANNEL_TICK" and event.time > h.ctl.now then
                assert.is_true(event.time < t + 10)
                remainingTicks = remainingTicks + 1
            end
        end
        assert.is_true(remainingTicks > 0)
        h.ctl.channel = nil
        h.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "Cast-funnel", 755)
        wound(h, "player", SECRET, 32)
        assert.is_not_equal("shadow_ward", field.pick(h))
        field.pick(h, 1)
        wound(h, "player", SECRET, 32)
        assert.are.equal("shadow_ward", field.pick(h))
    end)
end)
