local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("Forever Warlock sustained health spending", function()
    local function raid(health, rune, moving)
        local H = field.warlock("SMRuin", 60, { 11661, 1454 }, {
            instanceType = "raid",
            group = 10,
            boss = true,
            mana = 10,
            moving = moving,
            items = rune and { [12662] = 1 },
        })
        H.ctl.unitHealth.player, H.ctl.unitHealthMax.player = health, 5000
        H.Fire("UNIT_MAXHEALTH", "player")
        H.Fire("UNIT_HEALTH", "player")
        H.Hekili:FireToggle("potions", "on")
        return H
    end

    it("keeps the combat reserve after Life Tap and preserves stationary recovery when health is hidden", function()
        assert.are.equal("life_tap", field.pick(raid(4000)))
        assert.are_not.equal("life_tap", field.pick(raid(2755)))
        assert.are.equal("life_tap", field.pick(raid(SECRET)))
        assert.are_not.equal("life_tap", field.pick(raid(SECRET, false, true)))
    end)

    it("checks the maximum Demonic Rune roll and preserves stationary recovery when health is hidden", function()
        assert.are.equal("demonic_rune", field.pick(raid(4000, true)))
        assert.are_not.equal("demonic_rune", field.pick(raid(3650, true)))
        assert.are.equal("demonic_rune", field.pick(raid(SECRET, true)))
        assert.are_not.equal("demonic_rune", field.pick(raid(SECRET, true, true)))
    end)

    it(
        "charges projected rune damage before evaluating a later Life Tap, then resets it on a fresh forecast",
        function()
            local H = raid(3760, true)
            local st = H.Hekili.State
            st.reset("Primary", true)
            assert.is_true(st.warlock_sustained_demonic_rune)
            assert.is_true(st.warlock_sustained_life_tap)
            st:RunHandler("demonic_rune", true)
            assert.are.equal(1000, st.warlock_forecast.healthSpent)
            assert.is_false(st.warlock_sustained_life_tap)
            st.reset("Primary", true)
            assert.are.equal(0, st.warlock_forecast.healthSpent)
            assert.is_true(st.warlock_sustained_life_tap)
        end
    )
end)
