local field = require("Forever.helpers.warlock_field")
local warlock, pick, cast = field.warlock, field.pick, field.cast
local SECRET = require("Game.State.helpers.fake_api").SECRET

local WAND = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }
local RANGED_WEAPON = { 2504, "Worn Shortbow", "INVTYPE_RANGED", 2, 2 }
local STAFF = { 35, "Bent Staff", "INVTYPE_2HWEAPON", 2, 10 }

describe("Forever Warlock leveling and PvE", function()
    for _, build in ipairs({ "Affliction", "Demonology", "Destruction", "SMRuin", "ShadowBrand" }) do
        it(build .. " opens with Shadow Bolt when Immolate is unlearned at level one", function()
            local H = warlock(build, 1, { 686, 688, 687 })
            assert.are.equal("shadow_bolt", pick(H))
            assert.is_true(H.Hekili.State:IsKnown("shadow_bolt"))
            assert.is_false(H.Hekili.State:IsKnown("immolate"))
            assert.is_false(H.Hekili.State:IsKnown("life_tap"))
        end)

        it(build .. " opens with learned Immolate and continues with Shadow Bolt at level three", function()
            local H = warlock(build, 3, { 686, 348 })
            assert.are.equal("immolate", pick(H))
            assert.are.equal("shadow_bolt", cast(H, 348))
            assert.is_true(H.Hekili.State.debuff.immolate.up)
        end)
    end

    it("uses Immolate and Corruption before Shadow Bolt at level four without a wand", function()
        for _, build in ipairs({ "Affliction", "Demonology", "Destruction" }) do
            local H = warlock(build, 4, { 686, 348, 172 })
            assert.are.equal("immolate", pick(H), build)
            assert.are.equal("corruption", cast(H, 348), build)
            assert.are.equal("shadow_bolt", cast(H, 172), build)
        end
    end)

    it("finishes a low-health starter enemy with direct damage", function()
        for _, build in ipairs({ "Affliction", "Demonology", "Destruction" }) do
            local H = warlock(build, 4, { 686, 348, 172 })
            assert.are.equal("immolate", pick(H), build)
            H.ctl.unitHealth.target = 200
            assert.are.equal("shadow_bolt", cast(H, 348), build)
        end
    end)

    it("uses Corruption as the single DoT on ordinary Affliction and Demonology pulls at level ten", function()
        for _, build in ipairs({ "Affliction", "Demonology" }) do
            local H = warlock(build, 10, { 695, 707, 172 })
            assert.are.equal("corruption", pick(H), build)
            assert.are.equal("shadow_bolt", cast(H, 172), build)
        end
    end)

    it("uses Corruption then conserves mana on ordinary solo and party outdoor pulls", function()
        for _, group in ipairs({ 0, 3 }) do
            local H = warlock("Affliction", 60, { 11661, 11668, 11672, 11713, 603, 1311680, 5019 }, {
                classification = group > 0 and "rare" or "normal",
                group = group,
                partyAggro = group > 0,
                weapon = WAND,
                shootUsable = true,
            })
            assert.are.equal("corruption", pick(H))
            assert.are.equal("shoot", cast(H, 11672))
            H.Fire("START_AUTOREPEAT_SPELL") -- between shots the cast/queue flag can already be off
            local whileWanding = pick(H)
            assert.is_not_equal("shoot", whileWanding)
            assert.is_not_equal("shadow_bolt", whileWanding)
            H.Fire("STOP_AUTOREPEAT_SPELL")
            assert.are.equal("shoot", pick(H))
        end
    end)

    it("uses learned damage on ordinary healthy enemies and finishes with a wand", function()
        for _, scenario in ipairs({
            { "Affliction", 1316697, "wrack", { [1316697] = 1 } },
            { "Destruction", 412758, "incinerate", { [412758] = 1 } },
            { "SMRuin", 11661, "shadow_bolt", { [17959] = 1 } },
            { "ShadowBrand", 11661, "shadow_bolt", { [17793] = 1 } },
        }) do
            local H = warlock(scenario[1], 60, { 5019, scenario[2] }, {
                weapon = WAND,
                shootUsable = true,
                talents = scenario[4],
            })
            assert.are.equal(scenario[3], pick(H), scenario[1])
            H.ctl.unitHealth.target = 200
            assert.are.equal("shoot", pick(H), scenario[1])
        end
    end)

    it("lets an active wand yield to a confirmed shard finish", function()
        local H = warlock("Affliction", 10, { 695, 5019, 1120 }, { weapon = WAND, shootUsable = true })
        assert.are.equal("shoot", pick(H))
        H.Fire("START_AUTOREPEAT_SPELL")
        assert.is_not_equal("drain_soul", pick(H))
        H.ctl.unitHealth.target = 200
        assert.are.equal("drain_soul", pick(H))
    end)

    it("forecasts restarting the wand after casting Corruption", function()
        local H = warlock("Affliction", 10, { 172, 695, 5019 }, { weapon = WAND, shootUsable = true })
        H.Fire("START_AUTOREPEAT_SPELL")
        assert.are.equal("corruption", pick(H))
        assert.are.equal("shoot", H.Hekili.Engine.Output.Primary.recs[2].actionName)
    end)

    it("sets up a dungeon elite with its assigned Curse, then Corruption and Bane", function()
        local H = warlock("Affliction", 22, { 1088, 6222, 980, 440892, 1094 }, {
            instanceType = "party",
            group = 5,
            classification = "elite",
            partyAggro = true,
        })
        assert.are.equal("curse_of_the_elements", pick(H))
        assert.are.equal("corruption", cast(H, 440892))
        assert.are.equal("bane_of_agony", cast(H, 6222))
        assert.are.equal("immolate", cast(H, 980))
    end)

    it("uses Shadow Bolt through Destruction's Incinerate unlock", function()
        local early = warlock("Destruction", 39, { 7641, 2941 })
        local later = warlock("Destruction", 40, { 7641, 11665, 412758 }, { talents = { [412758] = 1 } })
        assert.are.same({ "immolate", "immolate" }, { pick(early), pick(later) })
        assert.are.equal("shadow_bolt", cast(early, 2941))
        assert.are.equal("incinerate", cast(later, 11665))
    end)

    it("applies Demonic Brand when the demon is on the same target", function()
        for _, build in ipairs({ "Demonology", "ShadowBrand" }) do
            for _, scenario in ipairs({
                { petHealth = 1000, petTarget = "target", action = "searing_pain" },
                { petHealth = 1000, petTarget = "nameplate1", action = "shadow_bolt" },
                { action = "shadow_bolt" },
            }) do
                scenario.talents = { [1293695] = 3 }
                local H = warlock(build, 38, { 7641, 5676 }, scenario)
                assert.are.equal(scenario.action, pick(H), build)
            end
        end
    end)

    it("uses Rain of Fire on three distinct in-range enemies engaged with the party", function()
        local function pull(combat, distance)
            local H = warlock("Affliction", 20, { 1088, 5740 }, {
                instanceType = "party",
                group = 5,
                partyAggro = true,
            })
            local ctl = H.ctl
            for i = 1, 3 do
                local plate = "nameplate" .. i
                local victim = plate .. "target"
                ctl.guid[plate] = i == 1 and ctl.guid.target or "Creature-p" .. i
                ctl.exists[plate], ctl.exists[victim] = true, true
                ctl.unitIs[plate] = i == 1 and "target" or nil
                ctl.unitIs[victim], ctl.inParty[victim] = "party1", true
                ctl.distance[plate], ctl.unitCombat[plate] = i == 3 and distance or 15, i ~= 3 or combat
                H.Fire("NAME_PLATE_UNIT_ADDED", plate)
            end
            return pick(H)
        end

        assert.are.equal("rain_of_fire", pull(true, 15))
        assert.are.equal("shadow_bolt", pull(false, 8))
        assert.are.equal("shadow_bolt", pull(true, SECRET))
    end)

    it("retains Bane of Doom for the sustained level-sixty damage priority", function()
        for _, options in ipairs({
            { instanceType = "raid", group = 10 },
            { boss = true, classification = "worldboss" },
        }) do
            local H = warlock("Demonology", 60, { 11661, 603 }, options)
            assert.are.equal("bane_of_doom", pick(H))
        end
    end)

    it("does not start a fresh dungeon fight while the party is fighting elsewhere", function()
        for _, prepull in ipairs({ true, false }) do
            local H = warlock("Affliction", 10, { 695, 172 }, {
                instanceType = "party",
                group = 5,
                idleTarget = true,
                prepull = prepull,
            })
            local action = pick(H)
            assert.is_not_equal("shadow_bolt", action)
            assert.is_not_equal("corruption", action)
        end
    end)

    it("waits for a level-sixty dungeon boss to engage before suggesting sustained damage", function()
        for _, idle in ipairs({ true, false }) do
            local h = warlock("Demonology", 60, { 11661, 603 }, {
                instanceType = "party",
                group = 5,
                boss = true,
                idleTarget = idle,
                partyAggro = true,
            })
            assert.are.equal(not idle, pick(h) == "bane_of_doom")
        end
    end)

    it("shows a learned Life Tap when mana is low and suppresses unsafe or unreadable health", function()
        for _, health in ipairs({ 1000, 560, 300, SECRET }) do
            local H = warlock("Demonology", 10, { 695, 1454 }, { health = health, mana = 10 })
            assert.are.equal(health == 1000, pick(H) == "life_tap")
        end
        local H = warlock("Demonology", 10, { 695, 1454 }, { mana = 1000 })
        assert.are.equal("shadow_bolt", pick(H))
    end)

    it("budgets the projected health cost of repeated Life Taps", function()
        local H = warlock("Demonology", 10, { 695, 1454 }, { health = 580, mana = 10 })
        assert.are.equal("life_tap", pick(H))
        local out = H.Hekili.Engine.Output.Primary
        for i = 2, out.count do
            assert.is_not_equal("life_tap", out.recs[i].actionName)
        end
    end)

    it("uses Shoot only with an equipped usable wand on an eligible target", function()
        local function lowManaShot(options)
            options.mana = 10 -- lower than the only learned damaging spell's cost
            options.shootUsable = options.shootUsable ~= false
            return pick(warlock("Destruction", 10, { 695, 5019 }, options))
        end

        assert.are.equal("shoot", lowManaShot({ weapon = WAND }))
        assert.are.equal("shoot", lowManaShot({ weapon = WAND, playerTarget = true }))
        for _, options in ipairs({
            {},
            { weapon = RANGED_WEAPON },
            { weapon = WAND, range = 35 },
            { weapon = WAND, range = SECRET },
            { weapon = WAND, shootUsable = false },
            { weapon = WAND, shooting = true },
            { weapon = WAND, shooting = SECRET },
            { weapon = WAND, moving = true },
            { weapon = WAND, playerTarget = true, idleTarget = true },
            { weapon = WAND, targetDead = true },
            { weapon = WAND, friendly = true },
        }) do
            assert.is_not_equal("shoot", lowManaShot(options))
        end
    end)

    it("falls back to weapon swings once when mana is exhausted and no wand is equipped", function()
        for _, options in ipairs({ {}, { instanceType = "party", group = 5, partyAggro = true } }) do
            options.mainHand, options.range, options.mana = STAFF, 3, 10
            local H = warlock("Affliction", 10, { 6603, 695 }, options)
            assert.are.equal("auto_attack", pick(H))
            local out = H.Hekili.Engine.Output.Primary
            for i = 2, out.count do
                assert.is_not_equal("auto_attack", out.recs[i].actionName)
            end
            H.ctl.current[6603] = true
            assert.is_not_equal("auto_attack", pick(H))
            H.ctl.power[0] = 1000
            H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
            assert.are.equal("shadow_bolt", pick(H))
        end
    end)

    it("keeps casting with Corruption or Immolate active on a melee target", function()
        for _, spells in ipairs({
            { level = 1, bolt = 686, dot = 348, aura = "immolate" },
            { level = 10, bolt = 695, dot = 172, aura = "corruption" },
        }) do
            local H = warlock("Affliction", spells.level, { 6603, spells.bolt, spells.dot }, {
                mainHand = STAFF,
                range = 10,
            })
            assert.are.equal("shadow_bolt", cast(H, spells.dot))
            assert.is_true(H.Hekili.State.debuff[spells.aura].up)
            H.ctl.distance.target = 3
            assert.are.equal("shadow_bolt", pick(H))
            H.ctl.current[6603] = true
            assert.are.equal("shadow_bolt", pick(H))
        end
    end)

    it("requires a melee weapon, confirmed range, an engaged enemy, and auto-attack off for the fallback", function()
        for _, options in ipairs({
            { noWeapon = true },
            { range = 10 },
            { range = SECRET },
            { attacking = SECRET },
            { idleTarget = true, instanceType = "party", group = 5 },
            { playerTarget = true },
            { targetDead = true },
            { friendly = true },
        }) do
            options.mainHand = not options.noWeapon and STAFF or nil
            options.range, options.mana = options.range or 3, 10
            assert.is_not_equal("auto_attack", pick(warlock("Affliction", 10, { 6603, 695 }, options)))
        end
        local H = warlock("Affliction", 10, { 6603, 695, 5019 }, {
            mainHand = STAFF,
            weapon = WAND,
            shootUsable = true,
            mana = 10,
            range = 3,
        })
        assert.are.equal("shoot", pick(H))
    end)

    it("opens at melee range with a learned spell when mana is available", function()
        local H = warlock("Affliction", 1, { 6603, 686 }, { mainHand = STAFF, range = 3, prepull = true })
        assert.are.equal("shadow_bolt", pick(H))
    end)

    it("suggests Drain Soul to finish an eligible solo or party pull when running low on shards", function()
        local function lowTarget(options)
            options.targetHealth = options.targetHealth or 200
            return pick(warlock("Affliction", 10, { 695, 1120 }, options))
        end

        assert.are.equal("drain_soul", lowTarget({}))
        assert.are.equal("drain_soul", lowTarget({ items = { [6265] = 1 } }))
        assert.are.equal("drain_soul", lowTarget({ group = 3 }))
        assert.are.equal(
            "drain_soul",
            lowTarget({ instanceType = "party", group = 5, partyAggro = true, classification = "elite" })
        )
        for _, options in ipairs({
            { items = { [6265] = 2 } },
            { instanceType = "party", group = 5, idleTarget = true },
            { instanceType = "party", group = 5, partyAggro = true, boss = true },
            { targetHealth = 400 },
            { targetHealth = SECRET },
            { trivial = true },
            { trivial = SECRET },
            { range = 35 },
            { health = 250 },
        }) do
            assert.is_not_equal("drain_soul", lowTarget(options))
        end
    end)

    it("suggests Drain Soul behind a tanking pet once a DoT is established", function()
        local spells = { 695, 172, 1120 }
        for _, petTanking in ipairs({ true, false }) do
            local H =
                warlock("Affliction", 10, spells, { targetHealth = SECRET, petHealth = 800, petTanking = petTanking })
            assert.are.equal("corruption", pick(H))
            assert.are.equal(petTanking and "drain_soul" or "shadow_bolt", cast(H, 172))
        end
    end)

    it("continues dealing damage while the pet tanks an observably healthy target", function()
        local h = warlock(
            "Affliction",
            10,
            { 695, 172, 1120 },
            { targetHealth = 900, petHealth = 800, petTanking = true }
        )
        assert.are.equal("corruption", pick(h))
        assert.are.equal("shadow_bolt", cast(h, 172))
    end)

    it("recovers our health with a carried stone or a learned in-range Drain Life", function()
        local spells = { 705, 689 }
        local function lowHealth(options)
            options.health = 250
            return pick(warlock("Affliction", 14, spells, options))
        end

        assert.are.equal("healthstone", lowHealth({ items = { [5512] = 1 } }))
        assert.are.equal("drain_life", lowHealth({}))
        assert.are.equal("shadow_bolt", lowHealth({ range = 25 }))
        assert.are.equal("shadow_bolt", lowHealth({ defensives = false, items = { [5512] = 1 } }))
    end)

    it("heals a known wounded demon only while stationary, safe, and healthy", function()
        local function recovery(options)
            options.prepull, options.noTarget = true, true
            return pick(warlock("Demonology", 12, { 755 }, options))
        end

        assert.are.equal("health_funnel", recovery({ petHealth = 300 }))
        assert.are.equal("health_funnel", recovery({ petHealth = 300, instanceType = "raid", group = 10 }))
        for _, options in ipairs({
            {},
            { petHealth = 300, petDead = true },
            { petHealth = 800 },
            { petHealth = SECRET },
            { petHealth = 300, petRange = 30 },
            { petHealth = 300, health = 400 },
            { petHealth = 300, health = SECRET },
            { petHealth = 300, moving = true },
        }) do
            assert.is_not_equal("health_funnel", recovery(options))
        end
    end)

    it("summons a learned demon out of combat without overwriting a sacrificed demon's buff", function()
        local function summon(options)
            options.prepull, options.noTarget = true, true
            options.maxMana, options.mana = 2500, 2500
            return pick(warlock("Demonology", 40, { 688, 697 }, options))
        end

        assert.are.equal("summon_imp", summon({}))
        assert.are.equal("summon_voidwalker", summon({ items = { [6265] = 1 } }))
        assert.are.equal("summon_imp", summon({ group = 3, items = { [6265] = 1 } }))
        assert.is_not_equal("summon_imp", summon({ petHealth = 800 }))
        assert.is_not_equal("summon_imp", summon({ moving = true }))
        assert.is_not_equal("summon_imp", summon({ buffs = { 18789 }, talents = { [18788] = 1 } }))
    end)
end)

describe("Forever Warlock preparation", function()
    it("prepares a learned Felhunter between battleground fights and keeps an existing pet", function()
        local function prepare(petHealth, shards)
            return pick(warlock("SMRuin", 40, { 688, 691 }, {
                instanceType = "pvp",
                group = 10,
                prepull = true,
                noTarget = true,
                petHealth = petHealth,
                maxMana = 2500,
                mana = 2500,
                items = { [6265] = shards },
            }))
        end
        assert.are.equal("summon_felhunter", prepare(nil, 1))
        assert.are.equal("summon_imp", prepare(nil, 0))
        assert.is_nil(prepare(800, 1))
    end)

    it("prepares learned Soul Link with a living demon", function()
        for _, case in ipairs({
            { petHealth = 1000, action = "soul_link" },
            { petHealth = 1000, buffs = { 25228 } },
            { petHealth = 1000, petDead = true },
            { petHealth = 1000, defensives = false },
            { moving = true, petHealth = 1000, action = "soul_link" },
            {},
        }) do
            case.noTarget, case.prepull = true, true
            case.talents = { [19028] = 1 }
            assert.are.equal(case.action, pick(warlock("Demonology", 30, { 19028 }, case)))
        end
    end)

    it("conjures one missing Healthstone at the highest learned rank", function()
        for _, rank in ipairs({ { 10, 6201 }, { 22, 6202 }, { 34, 5699 }, { 46, 11729 }, { 58, 11730 } }) do
            local h = warlock("Demonology", rank[1], { rank[2] }, {
                prepull = true,
                noTarget = true,
                items = { [6265] = 1 },
                maxMana = 2000,
                mana = 2000,
            })
            assert.are.equal("create_healthstone", pick(h))
            local output = h.Hekili.Engine.Output.Primary
            for i = 2, output.count do
                assert.is_not_equal("create_healthstone", output.recs[i].actionName)
            end
        end
    end)

    it("shows a future cast time while mana regenerates for Create Healthstone", function()
        local h = warlock("Destruction", 10, { 6201 }, {
            noTarget = true,
            prepull = true,
            mana = 1,
            items = { [6265] = 1 },
        })
        assert.are.equal("create_healthstone", pick(h))
        assert.is_true(h.Hekili.Engine.Output.Primary.recs[1].delay > 1)
    end)

    it("conjures an eligible Healthstone while carrying only a higher-level stone", function()
        local h = warlock("Destruction", 10, { 6201 }, {
            prepull = true,
            noTarget = true,
            items = { [6265] = 1, [9421] = 1 },
        })
        assert.are.equal("create_healthstone", pick(h))
    end)

    it("skips conjuring while fighting or moving, without resources, or while carrying an eligible stone", function()
        for _, o in ipairs({
            { items = {} },
            { items = { [6265] = 3, [19005] = 1 } },
            { items = { [6265] = 3, [5512] = 1, [9421] = 1 } },
            { moving = true },
            { mana = 1, maxMana = 90 },
            { prepull = false },
            { defensives = false },
        }) do
            o.noTarget = true
            o.prepull = o.prepull ~= false
            o.items = o.items or { [6265] = 1 }
            assert.is_not_equal("create_healthstone", pick(warlock("Destruction", 10, { 6201 }, o)))
        end
    end)

    it("summons a different demon with Demonic Pact while preserving the sacrificed demon's buff", function()
        for _, case in ipairs({ { 18792, "summon_imp" }, { 18789, "summon_voidwalker" } }) do
            local h = warlock("Demonology", 40, { 688, 697, 18788 }, {
                prepull = true,
                noTarget = true,
                buffs = { case[1] },
                talents = { [425464] = 1, [18788] = 1 },
                items = { [6265] = 2 },
                maxMana = 2400,
                mana = 2400,
            })
            assert.are.equal(case[2], pick(h))
        end
    end)
end)
