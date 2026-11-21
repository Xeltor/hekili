local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local builds = { "Affliction", "SMRuin", "Demonology", "ShadowBrand", "Destruction" }
local heals = { 6789, 689 }

describe("Forever Warlock defensives", function()
    for _, build in ipairs(builds) do
        it(build .. " chooses instant emergency healing and conserves Death Coil during a stable pull", function()
            assert.are.equal("death_coil", field.pick(field.warlock(build, 42, heals, { health = 390 })))
            assert.are.equal("drain_life", field.pick(field.warlock(build, 42, heals, { health = 650 })))
            assert.are.equal("death_coil", field.pick(field.warlock(build, 42, heals, { health = 550, moving = true })))
            assert.is_nil(field.pick(field.warlock(build, 42, heals, { health = 300, defensives = false })))
        end)
    end

    it("protects against follow-up Shadow damage before starting a long healing channel", function()
        local h = field.warlock("Destruction", 42, { 6789, 689, 6229 }, { health = 550 })
        assert.are.equal("drain_life", field.pick(h))
        h.Fire("UNIT_COMBAT", "player", "WOUND", nil, 50, 32)
        assert.are.equal("shadow_ward", field.pick(h))
    end)

    it("uses an in-range Coil when Drain Life cannot reach, and holds both on a fresh enemy", function()
        assert.are.equal(
            "death_coil",
            field.pick(field.warlock("Destruction", 42, heals, { health = 550, range = 25 }))
        )
        assert.is_nil(field.pick(field.warlock("Destruction", 42, heals, { health = 300, idleTarget = true })))
        assert.is_nil(field.pick(field.warlock("Destruction", 42, heals, { health = 300, range = SECRET })))
    end)

    it("leaves low-health heals as display cues when player health is hidden", function()
        local h = field.warlock("Affliction", 42, heals, { health = SECRET })
        assert.is_nil(field.pick(h))
        local cues = h.Hekili.Engine.Output.Primary.healthCues
        assert.are.equal(2, cues.n)
        assert.are.same({ "death_coil", 40 }, { cues[1].action, cues[1].percent })
        assert.are.same({ "drain_life", 65 }, { cues[2].action, cues[2].percent })
        h.Hekili:FireToggle("defensives", "off")
        field.pick(h)
        assert.are.equal(0, h.Hekili.Engine.Output.Primary.healthCues.n)
    end)

    it("routes survival recommendations to a separately enabled Defensives display", function()
        local h = field.warlock("Affliction", 42, heals, { health = 390 })
        local engine = h.Hekili.Engine
        engine.settings.toggles.defensives.separate = true
        assert.is_true(engine.Subscribe("Defensives", function() end))
        assert.is_nil(field.pick(h))
        assert.are.equal("death_coil", engine.Output.Defensives.recs[1].actionName)
        h.ctl.unitHealth.player = 1000
        h.Fire("UNIT_HEALTH", "player")
        field.pick(h)
        assert.are.equal(0, engine.Output.Defensives.count)
    end)

    it("sends hidden health cues to the enabled Defensives display when it has no ordinary icon", function()
        local h = field.warlock("Affliction", 42, heals, { health = SECRET })
        local engine = h.Hekili.Engine
        engine.settings.toggles.defensives.separate = true
        assert.is_true(engine.Subscribe("Defensives", function() end))
        assert.is_nil(field.pick(h))
        assert.are.equal(0, engine.Output.Primary.healthCues.n)
        local out = engine.Output.Defensives
        assert.are.equal(0, out.count)
        assert.are.equal(2, out.healthCues.n)
        assert.are.equal("death_coil", out.healthCues[1].action)
        assert.are.equal("drain_life", out.healthCues[2].action)
    end)

    it("keeps damage Drain Life on Primary and sends emergency Drain Life to the separate pane", function()
        local h = field.warlock("Demonology", 38, { 709 }, { health = 1000 })
        local engine = h.Hekili.Engine
        engine.settings.toggles.defensives.separate = true
        assert.is_true(engine.Subscribe("Defensives", function() end))
        local damage, defensives = engine.Output.Primary, engine.Output.Defensives

        assert.are.equal("drain_life", field.pick(h))
        assert.are.equal(0, damage.healthCues.n)
        assert.are.equal(0, defensives.count)
        assert.are.equal("drain_life", defensives.healthCues[1].action)

        h.ctl.unitHealth.player = 550
        h.Fire("UNIT_HEALTH", "player")
        assert.is_nil(field.pick(h, 1.6))
        assert.are.equal("drain_life", defensives.recs[1].actionName)
        assert.are.equal(0, damage.healthCues.n)

        h.ctl.unitHealth.player = SECRET
        h.Fire("UNIT_HEALTH", "player")
        assert.are.equal("drain_life", field.pick(h, 1.6))
        assert.are.equal(0, damage.healthCues.n)
        assert.are.equal(0, defensives.count)
        assert.are.equal("drain_life", defensives.healthCues[1].action)

        h.Hekili:FireToggle("defensives", "off")
        assert.is_nil(field.pick(h))
        assert.are.equal(0, damage.healthCues.n)
        assert.are.equal(0, defensives.count)
        assert.are.equal(0, defensives.healthCues.n)
    end)

    it("restores Soul Link during combat only with a confirmed living demon in reach", function()
        for _, case in ipairs({
            { health = 600, petHealth = 800, petRange = 60, moving = true, noTarget = true, expected = "soul_link" },
            { petHealth = 800, petRange = 110 },
            { petHealth = 800, petRange = SECRET },
            { petHealth = 800, petDead = true },
            { petHealth = 800, buffs = { 25228 } },
            { petHealth = 800, defensives = false },
            {},
        }) do
            assert.are.equal(case.expected, field.pick(field.warlock("Demonology", 50, { 19028 }, case)))
        end
    end)

    it("rescues a critically wounded solo tanking demon when the caster can pay for Health Funnel", function()
        local function pick(opts)
            return field.pick(field.warlock("Demonology", 20, { 755 }, opts))
        end
        assert.are.equal("health_funnel", pick({ petHealth = 290, petTanking = true }))
        for _, case in ipairs({
            { petHealth = 310, petTanking = true },
            { petHealth = 200, petTanking = false },
            { petHealth = 200, petTanking = true, group = 5 },
            { petHealth = 200, petTanking = true, health = 650 },
            { petHealth = 200, petTanking = true, moving = true },
            { petHealth = 200, petTanking = true, petRange = 22 },
            { petHealth = 200, petTanking = true, defensives = false },
        }) do
            assert.is_nil(pick(case))
        end
    end)
end)
