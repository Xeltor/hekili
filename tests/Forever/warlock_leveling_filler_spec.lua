local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warlock, pick, cast = field.warlock, field.pick, field.cast

local WAND = { 11288, "Greater Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }

describe("Forever Warlock outdoor leveling filler", function()
    it("lets an active wand yield to restorative Drain Life across all five builds", function()
        for _, build in ipairs({ "Affliction", "Demonology", "Destruction", "ShadowBrand", "SMRuin" }) do
            local h = warlock(build, 38, { 5019, 7641, 7651 }, {
                health = 800,
                group = 3,
                partyAggro = true,
                weapon = WAND,
                shootUsable = true,
            })
            h.Fire("START_AUTOREPEAT_SPELL")
            assert.are.equal("drain_life", pick(h), build)
        end
    end)

    it("favors a learned rank-three drain outdoors before Wrack, then uses Wrack on fresh pulls", function()
        local spells = { 5019, 1106, 709 }
        assert.are.equal("drain_life", pick(warlock("Affliction", 30, spells, { weapon = WAND, shootUsable = true })))
        local h = warlock("Affliction", 48, { 5019, 11659, 11699, 1316697 }, {
            weapon = WAND,
            shootUsable = true,
            talents = { [1316697] = 1 },
        })
        assert.are.equal("wrack", pick(h))
        h.ctl.unitHealth.player = 800
        h.Fire("UNIT_HEALTH", "player")
        assert.are.equal("drain_life", pick(h))
    end)

    it("compares the early drain with the equipped wand and keeps a healthy no-wand Bolt", function()
        local function geared(damage)
            return warlock("Affliction", 22, { 5019, 1088, 699 }, {
                weapon = WAND,
                shootUsable = true,
                beforeLoad = function(h)
                    h.ctl.ranged = { 2, damage, damage, 0, 0, 1 }
                end,
            })
        end
        assert.are.equal("shoot", pick(geared(40)))
        assert.are.equal("drain_life", pick(geared(20)))
        assert.are.equal("shadow_bolt", pick(warlock("Affliction", 22, { 1088, 699 })))
        assert.are.equal("drain_life", pick(warlock("Affliction", 22, { 1088, 699 }, { health = 800 })))
    end)

    it("maintains Demonic Brand once, then drains or shoots while the demon spends its charges", function()
        for _, withDrain in ipairs({ true, false }) do
            local label = withDrain and "learned Drain Life" or "wand only"
            local spells = { 5019, 1106, 17919 }
            if withDrain then
                spells[#spells + 1] = 709
            end
            local h = warlock("Demonology", 30, spells, {
                talents = { [1293695] = 3 },
                petHealth = 1000,
                petTarget = "target",
                weapon = WAND,
                shootUsable = true,
            })
            assert.are.equal("searing_pain", pick(h), label)
            assert.are.equal(withDrain and "drain_life" or "shoot", cast(h, 17919), label)
            assert.are.equal("searing_pain", pick(h, 11), label)
        end
    end)

    it("preserves the healthy direct-cast builds' filler when a drain and a wand are both available", function()
        for _, row in ipairs({
            { "Destruction", 412758, 412758, "incinerate" },
            { "SMRuin", 11661, 17959, "shadow_bolt" },
            { "ShadowBrand", 11661, 17793, "shadow_bolt" },
        }) do
            local h = warlock(row[1], 60, { 5019, row[2], 11700 }, {
                weapon = WAND,
                shootUsable = true,
                talents = { [row[3]] = 1 },
            })
            assert.are.equal(row[4], pick(h), row[1])
        end
    end)

    it("replaces a delayed Bolt only when the wand wins and Bolt would still be the filler", function()
        for _, scenario in ipairs({
            { name = "faster wand", damage = 35, expected = "shoot" },
            { name = "weaker wand", damage = 10, expected = "shadow_bolt" },
            { name = "Incinerate filler", damage = 35, fire = true, expected = "incinerate" },
            { name = "high Shadow power", damage = 35, shadow = 150, expected = "shadow_bolt" },
            { name = "hidden Shadow power", damage = 35, shadow = SECRET, expected = "shadow_bolt" },
            { name = "hidden spell crit", damage = 35, crit = SECRET, expected = "shadow_bolt" },
            { name = "Nightfall after cast", damage = 35, nightfall = "after", expected = "shadow_bolt" },
            { name = "Nightfall during cast", damage = 35, nightfall = "during", expected = "shadow_bolt" },
        }) do
            local spells = { 5019, 686, 695, 705, 1088 }
            if scenario.fire then
                spells[#spells + 1] = 412758
            end
            local procLit = false
            local h = warlock("Destruction", 40, spells, {
                weapon = WAND,
                shootUsable = true,
                range = 3,
                talents = { [412758] = scenario.fire and 1 or 0, [18094] = scenario.nightfall and 2 or 0 },
                beforeLoad = function(harness)
                    harness.ctl.ranged = { 2, scenario.damage, scenario.damage, 0, 0, 1 }
                    harness.env.GetSpellBonusDamage = function(school)
                        return school == 6 and (scenario.shadow or 0) or 900
                    end
                    harness.env.GetSpellCritChance = function()
                        return scenario.crit or 0
                    end
                    harness.env.C_SpellActivationOverlay.IsSpellOverlayed = function(id)
                        return id == 686 and procLit
                    end
                end,
            })
            assert.are.equal(scenario.fire and "incinerate" or "shadow_bolt", pick(h), scenario.name)
            h.Hekili.State.reset("Primary")
            local start = h.ctl.now
            h.ctl.casting = { start * 1000, (start + 3) * 1000 }
            h.Fire("UNIT_SPELLCAST_START", "player", "Cast-leveling", 1088)
            h.ctl.now = start + 1
            h.ctl.casting[2] = (start + 4.25) * 1000
            h.Fire("UNIT_SPELLCAST_DELAYED", "player", "Cast-leveling", 1088)
            local function proc()
                procLit = true
                h.ctl.auras.player.HELPFUL[1] = SECRET
                h.Fire("UNIT_AURA", "player")
            end
            if scenario.nightfall == "during" then
                h.ctl.now = start + 3.5
                proc()
                assert.are.equal("shadow_bolt", pick(h), scenario.name)
                -- The current hardcast still has 0.55 seconds left. The next Bolt spends the proc.
                local recs = h.Hekili.Engine.Output.Primary.recs
                assert.is_near(0.55, recs[1].time, 0.01, scenario.name)
                assert.are.equal("shoot", recs[2].actionName, scenario.name)
            end
            h.ctl.now = start + 4.25
            h.ctl.casting = nil
            h.Fire("UNIT_SPELLCAST_STOP", "player", "Cast-leveling", 1088)
            h.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-leveling", 1088)
            if scenario.nightfall == "after" then
                proc()
            end
            assert.are.equal(scenario.expected, pick(h), scenario.name)
            if scenario.nightfall then
                h.Hekili.State.reset("Primary")
                assert.are.equal(0, h.Hekili.Class.abilities.shadow_bolt.cast, scenario.name)
                h.ctl.now = h.ctl.now + 0.1
                procLit = SECRET -- the instant cast itself is enough to spend Shadow Trance
                h.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-instant", 1088)
                pick(h)
                h.Hekili.State.reset("Primary")
                assert.is_true(h.Hekili.State.buff.shadow_trance.down, scenario.name)
            end
        end
    end)

    it("uses one safe Life Tap before the learned drain and keeps the wand when recovery is unsafe", function()
        local function lowMana(health, drain, range)
            return warlock("Affliction", 30, { 5019, 1106, 1456, drain }, {
                health = health,
                mana = 20,
                weapon = WAND,
                shootUsable = true,
                range = range,
            })
        end
        local h = lowMana(1000, 709)
        assert.are.equal("life_tap", pick(h))
        local recs = h.Hekili.Engine.Output.Primary.recs
        assert.are.equal("drain_life", recs[2].actionName)
        for _, health in ipairs({ 800, SECRET }) do
            assert.are.equal("shoot", pick(lowMana(health, 709)), health == SECRET and "hidden health" or "wounded")
        end
        assert.are.equal("shoot", pick(lowMana(1000, 699)))
        assert.are.equal("shoot", pick(lowMana(1000, 709, 25)))
    end)

    it(
        "starts the affordable drain after an actual Life Tap with health and mana still inside the Tap window",
        function()
            local h = warlock("Affliction", 30, { 5019, 1106, 1454, 709 }, {
                health = 1000,
                mana = 125,
                weapon = WAND,
                shootUsable = true,
            })
            assert.are.equal("life_tap", pick(h))
            h.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-recovery", 1454)
            h.ctl.power[0], h.ctl.unitHealth.player = 155, 970
            h.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
            h.Fire("UNIT_HEALTH", "player")
            assert.are.equal("drain_life", pick(h, 1.6))
        end
    )

    it("uses the wand for a finish, an unaffordable drain, and the gap between Drain Life and Shoot range", function()
        for _, options in ipairs({
            { name = "dying enemy", targetHealth = 200 },
            { name = "insufficient mana", mana = 20 },
            { name = "only wand in range", range = 25 },
        }) do
            options.weapon, options.shootUsable = WAND, true
            assert.are.equal("shoot", pick(warlock("Affliction", 30, { 5019, 1106, 709 }, options)), options.name)
        end
    end)

    it("requires an engaged outdoor enemy, a stationary player, range, and the Defensives switch", function()
        for _, options in ipairs({
            { name = "fresh target", idleTarget = true },
            { name = "moving", moving = true },
            { name = "hidden range", range = SECRET },
            { name = "Defensives off", defensives = false },
            { name = "dungeon", group = 5, instanceType = "party", partyAggro = true },
            { name = "raid", group = 10, instanceType = "raid", boss = true },
        }) do
            options.health = 800
            assert.is_not_equal("drain_life", pick(warlock("Affliction", 60, { 11661, 11700 }, options)), options.name)
        end
    end)

    it("does not spend health preparing a disabled drain or compare it with a disabled wand", function()
        local function disable(h, key)
            local spec = h.Hekili.State.spec.id
            h.Hekili.Engine.settings.specs[spec].abilities[key].disabled = true
            return pick(h)
        end
        local lowMana = warlock("Affliction", 30, { 5019, 1106, 1456, 709 }, {
            mana = 20,
            weapon = WAND,
            shootUsable = true,
        })
        assert.are.equal("shoot", disable(lowMana, "drain_life"))
        local wounded = warlock("Affliction", 22, { 5019, 1088, 699 }, {
            health = 800,
            weapon = WAND,
            shootUsable = true,
            beforeLoad = function(h)
                h.ctl.ranged = { 2, 100, 100, 0, 0, 1 }
            end,
        })
        assert.are.equal("drain_life", disable(wounded, "shoot"))
    end)
end)
