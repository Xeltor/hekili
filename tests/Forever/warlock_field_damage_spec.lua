local field = require("Forever.helpers.warlock_field")
local world = require("Forever.helpers.warlock_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warlock, pick, cast = field.warlock, field.pick, field.cast

describe("Forever Warlock field damage", function()
    it("stops setting up fresh DoTs on a dying ordinary enemy in all five builds", function()
        for _, build in ipairs({ "Affliction", "SMRuin", "Demonology", "ShadowBrand", "Destruction" }) do
            local H = warlock(build, 36, { 7641, 2941, 7648 }, { targetHealth = 200 })
            assert.are.equal("shadow_bolt", pick(H), build)
        end
    end)

    it("uses the instant spells actually available while moving", function()
        local spells = { 705, 6222, 980, 707 }
        for _, rank in ipairs({ 4, 5 }) do
            local H = warlock("Destruction", 26, spells, { moving = true, talents = { [17810] = rank } })
            assert.are.equal(rank == 5 and "corruption" or "bane_of_agony", pick(H))
        end
        local H = warlock("Affliction", 26, { 705, 689, 6222 }, { moving = true, health = 400, buffs = { 17941 } })
        assert.are.equal("shadow_bolt", pick(H))
        local runner = warlock("Affliction", 26, { 705, 689, 6222 }, { moving = true, health = 400 })
        assert.is_true(runner.Hekili.State.moving)
        assert.is_nil(pick(runner))
        assert.is_nil(pick(runner, 6))
    end)

    it("suspends boss hardcasts until movement stops when the client hides player speed", function()
        local H = warlock("SMRuin", 60, { 11661 }, {
            instanceType = "raid",
            boss = true,
            beforeLoad = function(h)
                h.env.GetUnitSpeed = function()
                    return SECRET, 7, 7, 4.72
                end
            end,
        })
        assert.are.equal("shadow_bolt", pick(H))
        H.Fire("PLAYER_STARTED_MOVING")
        assert.is_nil(pick(H))
        assert.is_nil(pick(H, 7))
        H.Fire("PLAYER_STOPPED_MOVING")
        assert.are.equal("shadow_bolt", pick(H))
    end)

    it("holds Conflagrate for Immolate's last tick, an ordinary finisher, or full Shadow and Flame", function()
        local function immolate(rank, low)
            local H = warlock("Destruction", 38, { 7641, 2941, 1293817 }, {
                talents = { [426316] = rank, [1293817] = 1 },
            })
            assert.are.equal("immolate", pick(H))
            if low then
                H.ctl.unitHealth.target = 200
            end
            return H, cast(H, 2941)
        end
        local H, first = immolate(4)
        assert.are.equal("shadow_bolt", first)
        assert.are.equal("conflagrate", pick(H, 11))
        assert.are.equal("conflagrate", select(2, immolate(4, true)))
        assert.are.equal("conflagrate", select(2, immolate(5)))
    end)

    it("uses Shadowburn to finish with a spare shard, or with the first shard at full Shadow and Flame", function()
        local function shadowburn(build, health, shards, talentRank, distance)
            local H = warlock(build, 40, { 7641, 18869 }, {
                targetHealth = health,
                range = distance,
                items = { [6265] = shards },
                talents = { [426316] = talentRank },
            })
            return pick(H)
        end
        assert.are.equal("shadowburn", shadowburn("SMRuin", 200, 2, 0))
        assert.are.equal("shadow_bolt", shadowburn("SMRuin", 200, 1, 0))
        assert.are.equal("shadow_bolt", shadowburn("SMRuin", SECRET, 2, 0))
        assert.are.equal("shadowburn", shadowburn("Destruction", 1000, 1, 5))
        assert.are.equal("shadow_bolt", shadowburn("Destruction", 1000, 0, 5))
        assert.is_not_equal("shadowburn", shadowburn("Destruction", 200, 2, 5, SECRET))
    end)

    it("uses Amplify Curse only for a ready Agony and respects the cooldown switch", function()
        local function pull(spells, options, cds)
            options.classification = "elite"
            local H = warlock("Affliction", 30, spells, options)
            H.Hekili:FireToggle("cooldowns", cds)
            return H
        end
        local H = pull({ 1088, 1014, 18288 }, {}, "on")
        assert.are.equal("amplify_curse", pick(H))
        assert.are.equal("bane_of_agony", cast(H, 18288))
        assert.are.equal("shadow_bolt", cast(H, 1014))
        assert.are.equal("bane_of_agony", pick(pull({ 1088, 1014, 18288 }, {}, "off")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 18288 }, {}, "on")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 1014, 18288 }, { range = SECRET }, "on")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 1014, 18288 }, { mana = 10, maxMana = 40 }, "on")))
        local recovering = pull({ 1088, 1014, 18288 }, { mana = 10 }, "on")
        assert.are.equal("amplify_curse", pick(recovering))
        assert.is_true(recovering.Hekili.Engine.Output.Primary.recs[1].delay > 0.5)
    end)

    it("preserves Havoc on the selected target", function()
        local H = warlock("Destruction", 40, { 7641, 1014, 1225228 }, { classification = "elite" })
        assert.are.equal("bane_of_agony", pick(H))
        assert.are.equal("shadow_bolt", cast(H, 1225228))
        assert.is_true(H.Hekili.State.debuff.bane_of_havoc.up)
    end)

    it("offers Corruption on a second engaged enemy only with target swaps enabled", function()
        local function pair(cycle, engaged, extra, knownCount)
            local H = warlock("Affliction", 30, { 1106, 6223 }, {
                classification = "elite",
                instanceType = "party",
                group = 5,
                partyAggro = true,
            })
            H.Hekili.Engine.settings.specs[world.Affliction.SPEC].cycle = cycle
            local ctl = H.ctl
            ctl.guid.nameplate1, ctl.guid.nameplate2 = ctl.guid.target, "Creature-secondary"
            ctl.unitIs.nameplate1 = "target"
            local plates = { "nameplate1", "nameplate2" }
            if extra then
                plates[3] = "nameplate3"
                ctl.guid.nameplate3 = "Creature-third"
            end
            for _, plate in ipairs(plates) do
                ctl.exists[plate], ctl.exists[plate .. "target"] = true, true
                ctl.unitIs[plate .. "target"], ctl.inParty[plate .. "target"] = "party1", true
                ctl.distance[plate], ctl.unitCombat[plate] = 15, plate == "nameplate1" or engaged
                H.Fire("NAME_PLATE_UNIT_ADDED", plate)
            end
            if knownCount == false then
                H.ns.Facade.DebuffCount = function()
                    return nil
                end
            end
            assert.are.equal("corruption", pick(H))
            local nextCast = cast(H, 6223)
            return nextCast, H.Hekili.Engine.Output.Primary.recs[1].indicator
        end
        assert.are.same({ "corruption", "cycle" }, { pair(true, true) })
        assert.are.equal("shadow_bolt", (pair(false, true)))
        assert.are.equal("shadow_bolt", (pair(true, false)))
        assert.are.equal("shadow_bolt", (pair(true, true, true)))
        assert.are.equal("shadow_bolt", (pair(true, true, false, false)))
    end)
end)
