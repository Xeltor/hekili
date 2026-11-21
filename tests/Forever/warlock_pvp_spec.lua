local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local builds = { "Affliction", "SMRuin", "Demonology", "ShadowBrand", "Destruction" }

describe("Forever Warlock player combat", function()
    it("uses a learned damage spell against players in the world, battlegrounds and arenas", function()
        for _, build in ipairs(builds) do
            for _, instance in ipairs({ "none", "pvp", "arena" }) do
                local h = field.warlock(build, 60, { 11661, 603 }, { instanceType = instance, playerTarget = true })
                assert.are.equal("shadow_bolt", field.pick(h), build .. " " .. instance)
            end
        end
    end)

    it("requires an engaged hostile player and confirmed spell range", function()
        for _, options in ipairs({
            { playerTarget = true, friendly = true },
            { playerTarget = true, idleTarget = true },
            { playerTarget = true, prepull = true },
            { playerTarget = true, targetDead = true },
            { playerTarget = true, range = 50 },
            { playerTarget = true, range = SECRET },
            { playerTarget = SECRET },
            { noTarget = true },
        }) do
            options.instanceType = "pvp"
            local h = field.warlock("Destruction", 60, { 11661, 603 }, options)
            assert.is_nil(field.pick(h))
        end
    end)

    it("uses a learned slow against close moving opponents and skips it when stationary or out of reach", function()
        for _, case in ipairs({ { 4, 7, "curse_of_exhaustion" }, { 15, 7, "shadow_bolt" }, { 4, 0, "shadow_bolt" } }) do
            local h = field.warlock("SMRuin", 40, { 7641, 18223 }, {
                playerTarget = true,
                range = case[1],
                targetSpeed = case[2],
                talents = { [18223] = 1 },
            })
            assert.are.equal(case[3], field.pick(h))
        end
    end)

    it("uses Curse of Tongues on an observed cast", function()
        local h = field.warlock("Affliction", 30, { 1088, 1714 }, { instanceType = "pvp", playerTarget = true })
        assert.are.equal("shadow_bolt", field.pick(h))
        h.Fire("UNIT_SPELLCAST_START", "target", "Cast-test-target", 123)
        assert.are.equal("curse_of_tongues", field.pick(h))
    end)

    it("uses an instant finisher with a shard and switches to direct damage when out of shards", function()
        for _, shards in ipairs({ 0, 1 }) do
            local h = field.warlock("Destruction", 40, { 7641, 17877 }, {
                playerTarget = true,
                targetHealth = 200,
                items = { [6265] = shards },
                talents = { [17877] = 1 },
            })
            assert.are.equal(shards == 1 and "shadowburn" or "shadow_bolt", field.pick(h))
        end
    end)

    it("holds damage only for Fear or Howl observed on the selected player", function()
        for _, auraID in ipairs({ 1324451, 5484 }) do
            local h = field.warlock("SMRuin", 40, { 7641, 6213, 5484 }, { instanceType = "pvp", playerTarget = true })
            local ctl = h.ctl
            local function seeFear()
                ctl.auras.target.HARMFUL[1] = {
                    spellId = auraID,
                    expirationTime = ctl.now + 10,
                    duration = 10,
                    applications = 1,
                    sourceUnit = "player",
                }
                h.Fire("UNIT_AURA", "target")
                assert.is_nil(field.pick(h))
            end
            seeFear()
            ctl.auras.target.HARMFUL[1] = nil
            h.Fire("UNIT_AURA", "target")
            assert.are.equal("shadow_bolt", field.pick(h))
            seeFear()
            ctl.guid.target = "Player-1-00000002"
            ctl.auras.target.HARMFUL[1] = nil
            h.Fire("PLAYER_TARGET_CHANGED")
            assert.are.equal("shadow_bolt", field.pick(h))
        end
    end)

    it("continues pressure after unconfirmed Fear and self-centered Howl casts", function()
        local h = field.warlock("SMRuin", 40, { 7641, 6213, 5484 }, { instanceType = "pvp", playerTarget = true })
        assert.are.equal("shadow_bolt", field.cast(h, 6213))
        h.ctl.distance.target = 25
        assert.are.equal("shadow_bolt", field.cast(h, 5484))
    end)

    it("can use a carried Healthstone without a selected opponent in an arena", function()
        local h = field.warlock("Affliction", 20, { 1088 }, {
            instanceType = "arena",
            noTarget = true,
            health = 200,
            items = { [5512] = 1 },
        })
        assert.are.equal("healthstone", field.pick(h))
    end)

    it("uses a carried Healthstone while fighting in a battleground", function()
        local h = field.warlock("Affliction", 20, { 1088 }, {
            instanceType = "pvp",
            playerTarget = true,
            health = 200,
            items = { [5512] = 1 },
        })
        assert.are.equal("healthstone", field.pick(h))
    end)
end)
