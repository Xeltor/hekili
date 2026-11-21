local field = require("Forever.helpers.warlock_field")

describe("Forever Warlock movement on bosses", function()
    local builds = {
        Affliction = { 11661, 1316697 },
        SMRuin = { 11661, 25309 },
        Demonology = { 11661, 17923, 17924 },
        ShadowBrand = { 11661, 17923 },
        Destruction = { 11661, 25309, 1293813 },
    }

    for build, spells in pairs(builds) do
        it(build .. " waits out a boss move when it has only hard casts, then resumes casting", function()
            local options = { instanceType = "party", group = 5, partyAggro = true, boss = true, moving = true }
            local H = field.warlock(build, 60, spells, options)
            assert.is_true(H.Hekili.State.warlock_sustained)
            assert.is_nil(field.pick(H))
            assert.is_nil(field.pick(H, 6))
            options.moving = false
            H.Fire("PLAYER_STOPPED_MOVING")
            local action = field.pick(H)
            assert.is_string(action)
            assert.is_true(H.Hekili.State.action[action].cast > 0)
        end)
    end

    it("uses a Nightfall Shadow Bolt and fully talented Corruption on the move", function()
        local proc = field.warlock("SMRuin", 60, { 11661 }, {
            instanceType = "raid",
            group = 10,
            boss = true,
            moving = true,
            buffs = { 17941 },
        })
        assert.are.equal("shadow_bolt", field.pick(proc))
        for _, rank in ipairs({ 4, 5 }) do
            local H = field.warlock("Affliction", 60, { 11661, 11672 }, {
                instanceType = "raid",
                group = 10,
                boss = true,
                moving = true,
                talents = { [17810] = rank },
            })
            assert.are.equal(rank == 5 and "corruption" or nil, field.pick(H))
        end
    end)

    it("can save mana during movement only with enough health after Life Tap", function()
        local function pick(health, mana, moving)
            return field.pick(field.warlock("SMRuin", 60, { 11661, 1454 }, {
                instanceType = "raid",
                group = 10,
                boss = true,
                health = health,
                mana = mana,
                moving = moving,
            }))
        end
        assert.are.equal("life_tap", pick(1000, 500, true))
        assert.is_nil(pick(300, 100, true))
        assert.is_nil(pick(1000, 1000, true))
        assert.are.equal("shadow_bolt", pick(1000, 500, false))
    end)

    it("finishes on the move when Shadowburn is learned, in range and has a spare shard", function()
        local function pick(shards, range)
            return field.pick(field.warlock("ShadowBrand", 60, { 11661, 18871 }, {
                instanceType = "raid",
                group = 10,
                boss = true,
                moving = true,
                targetHealth = 150,
                range = range,
                items = { [6265] = shards },
            }))
        end
        assert.are.equal("shadowburn", pick(2, 15))
        assert.is_nil(pick(1, 15))
        assert.is_nil(pick(2, 40))
    end)
end)
