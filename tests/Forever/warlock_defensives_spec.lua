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

    it("rescues a critically wounded demon when WoW allows the channel to start", function()
        local function pick(opts)
            return field.pick(field.warlock("Demonology", 20, { 755 }, opts))
        end
        assert.are.equal("health_funnel", pick({ petHealth = 290, petTanking = true }))
        -- Enough for rank one's initial 11 health, even though a full channel would cost more.
        assert.are.equal("health_funnel", pick({ petHealth = 200, petTanking = true, health = 12 }))
        for _, case in ipairs({
            { petHealth = 310, petTanking = true },
            { petHealth = 200, petTanking = true, group = 5, instanceType = "party" },
            { petHealth = 200, petTanking = true, moving = true },
            { petHealth = 200, petTanking = true, petRange = 22 },
            { petHealth = 200, petTanking = true, defensives = false },
        }) do
            assert.is_nil(pick(case))
        end
        local dead = field.warlock("Affliction", 14, { 755 }, { petHealth = 200, petTanking = true })
        dead.ctl.dead.player = true
        assert.is_nil(field.pick(dead))
        assert.are.equal(0, dead.Hekili.Engine.Output.Primary.healthCues.n)
    end)

    it("rescues a level 14 demon in an engaged outdoor pull whoever has aggro", function()
        for _, opts in ipairs({
            { group = 2, petTanking = true },
            { group = 2, partyAggro = true },
            { group = 2 },
            {},
        }) do
            opts.petHealth = 300
            local h = field.warlock("Affliction", 14, { 755 }, opts)
            h.ctl.unitCombat.pet = SECRET
            assert.are.equal("health_funnel", field.pick(h))
            h.ctl.unitHealth.pet = 301
            assert.is_nil(field.pick(h))
        end
    end)

    it("uses Health Funnel on a living pet the spell can heal even when its identity is unavailable", function()
        local h = field.warlock("Affliction", 14, { 755 }, {
            group = 2,
            partyAggro = true,
            petHealth = 275,
            petGUID = SECRET,
            beforeLoad = function(client)
                -- The pet predates login, so a recent simulated summon cannot identify it.
                client.ctl.now = 5000
            end,
        })
        local facade = h.ns.Facade
        assert.is_nil(facade.UnitGUID("pet"))
        assert.is_true(facade.PetAlive())
        assert.is_true((facade.C_Spell.IsSpellInRange(755, "pet")))
        assert.is_true((facade.C_Spell.IsSpellUsable(755)))
        assert.are.equal("health_funnel", field.pick(h))

        h.ctl.guid.pet = "Pet-0-0-0-0-99999-000002"
        h.Fire("UNIT_PET", "player")
        assert.are.equal("health_funnel", field.pick(h))
        local out = h.Hekili.Engine.Output.Primary
        for _, usable in ipairs({ false, SECRET }) do
            h.ctl.usable[755] = { usable, false }
            assert.is_nil(field.pick(h))
            assert.are.equal(0, out.healthCues.n)
        end
        h.ctl.usable[755] = { true, false }
        h.ctl.distance.pet = 21
        assert.is_nil(field.pick(h))
        assert.are.equal(0, out.healthCues.n)
        h.ctl.distance.pet, h.ctl.dead.pet = 10, true
        assert.is_nil(field.pick(h))
        assert.are.equal(0, out.healthCues.n)
    end)

    it("keeps the level 14 party rescue available when the enemy is no longer selected", function()
        for _, selectPet in ipairs({ false, true }) do
            local h = field.warlock("Affliction", 14, { 755 }, {
                group = 2,
                health = SECRET,
                petHealth = SECRET,
                noTarget = not selectPet,
                friendly = selectPet,
            })
            if selectPet then
                h.ctl.unitIs.target = "pet"
                h.ctl.guid.target = h.ctl.guid.pet
            end
            h.ctl.exists.pettarget = true
            h.ctl.unitCombat.pet = true
            h.Fire("PLAYER_TARGET_CHANGED")
            assert.is_nil(field.pick(h))
            local out = h.Hekili.Engine.Output.Primary
            assert.are.equal(1, out.healthCues.n)
            local cue = out.healthCues[1]
            assert.are.same({ "health_funnel", "pet", 30 }, { cue.action, cue.unit, cue.percent })
            assert.is_nil(cue.playerFloor)
            for _, petCombat in ipairs({ false, SECRET }) do
                h.ctl.unitCombat.pet = petCombat
                assert.is_nil(field.pick(h))
                assert.are.equal(0, out.healthCues.n)
            end
            h.ctl.unitCombat.pet = true
            for _, isPlayer in ipairs({ true, SECRET }) do
                h.ctl.isPlayer.pettarget = isPlayer
                assert.is_nil(field.pick(h))
                assert.are.equal(0, out.healthCues.n)
            end
        end
    end)

    it("keeps an outdoor party rescue out of dungeons, raids and PvP", function()
        for _, opts in ipairs({
            { instanceType = "party" },
            { instanceType = "raid" },
            { instanceType = "pvp" },
            { playerTarget = true },
        }) do
            opts.group, opts.partyAggro, opts.petHealth = 2, true, 200
            local h = field.warlock("Affliction", 14, { 755 }, opts)
            assert.is_nil(field.pick(h))
            assert.are.equal(0, h.Hekili.Engine.Output.Primary.healthCues.n)
        end
    end)

    it("uses pet health alone for a combat rescue even when the player's health and maximum are hidden", function()
        for _, case in ipairs({
            { petHealth = SECRET, health = 900, petTanking = true },
            { petHealth = 300, health = SECRET, petTanking = true, expected = "health_funnel" },
            { petHealth = SECRET, health = SECRET, petTanking = true },
        }) do
            local h = field.warlock("Affliction", 12, { 755 }, case)
            h.ctl.unitHealthMax.player = SECRET
            assert.are.equal(case.expected, field.pick(h))
            local cues = h.Hekili.Engine.Output.Primary.healthCues
            assert.are.equal(1, cues.n)
            assert.are.same({ "health_funnel", "pet", 30 }, { cues[1].action, cues[1].unit, cues[1].percent })
            assert.is_nil(cues[1].playerFloor)
            local state = h.Hekili.State
            state.reset("Primary", true)
            assert.are.equal(case.expected == "health_funnel", state.warlock_funnel_safe)
        end
    end)

    it("keeps the full-channel reserve and current maximum requirement between pulls", function()
        local h = field.warlock("Demonology", 12, { 755 }, {
            petHealth = 550,
            health = SECRET,
            prepull = true,
            noTarget = true,
        })
        h.ctl.unitHealthMax.player = 250
        assert.is_nil(field.pick(h))
        local cues = h.Hekili.Engine.Output.Primary.healthCues
        -- Rank one's full-channel budget is 71 health. Starting at 221 reserves exactly 150 (60%).
        assert.are.equal(1, cues.n)
        assert.are.equal(55, cues[1].percent)
        assert.are.equal(88.4, cues[1].playerFloor)
        h.ctl.unitHealth.player = 220
        assert.is_nil(field.pick(h))
        h.ctl.unitHealth.player = 221
        assert.are.equal("health_funnel", field.pick(h))
        h.ctl.unitHealthMax.player = SECRET
        assert.is_nil(field.pick(h))
        assert.are.equal(0, h.Hekili.Engine.Output.Primary.healthCues.n)
    end)

    it("routes the protected pet heal to the selected Defensives display in all five builds", function()
        for _, build in ipairs(builds) do
            local h = field.warlock(build, 12, { 755 }, { petHealth = SECRET, health = SECRET, petTanking = true })
            local engine = h.Hekili.Engine
            engine.settings.toggles.defensives.separate = true
            assert.is_true(engine.Subscribe("Defensives", function() end))
            assert.is_nil(field.pick(h), build)
            assert.are.equal(0, engine.Output.Primary.healthCues.n, build)
            assert.are.equal(0, engine.Output.Defensives.count, build)
            local cues = engine.Output.Defensives.healthCues
            assert.are.equal(1, cues.n, build)
            assert.are.equal("health_funnel", cues[1].action, build)
        end
    end)

    it("withholds the pet-health cue when Funnel is untrained or the pet rescue is unavailable", function()
        for _, case in ipairs({
            { untrained = true, petTanking = true },
            { moving = true, petTanking = true },
            { idleTarget = true },
            { petRange = 22, petTanking = true },
            { defensives = false, petTanking = true },
        }) do
            case.petHealth, case.health = SECRET, SECRET
            local h = field.warlock("Demonology", case.untrained and 11 or 12, case.untrained and {} or { 755 }, case)
            assert.is_nil(field.pick(h))
            assert.are.equal(0, h.Hekili.Engine.Output.Primary.healthCues.n)
        end
    end)
end)
