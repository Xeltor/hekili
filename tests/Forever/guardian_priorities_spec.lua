local feral = require("Forever.helpers.feral_pve")
local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function aura(H, unit, helpful, id, stacks, remaining)
    local rows = H.ctl.auras[unit][helpful and "HELPFUL" or "HARMFUL"]
    rows[#rows + 1] = {
        name = "Spell " .. id,
        spellId = id,
        sourceUnit = "player",
        applications = stacks,
        duration = 30,
        expirationTime = H.ctl.now + remaining,
    }
    H.Fire("UNIT_AURA", unit)
end

local function biteCooldown(H, c)
    c.cooldown[407995] = { isActive = true, isOnGCD = false, startTime = c.now, duration = 15 }
    H.Fire("SPELL_UPDATE_COOLDOWN")
end

local function addPlate(H, c, unit, distance, fighting)
    c.exists[unit], c.guid[unit], c.distance[unit] = true, "Creature-" .. unit, distance
    c.unitCombat[unit], c.threat[unit] = fighting, fighting and 3 or nil
    H.Fire("NAME_PLATE_UNIT_ADDED", unit)
end

describe("Guardian threat and Rage priorities", function()
    it("banks Rage before an idle tank pull, then opens with trained Faerie Fire", function()
        local o = { level = 14, known = { 5487, 6807, 5229 }, distance = 20, rage = 0 }
        assert.are.equal("enrage", (feral.tank(o)))
        o.level, o.known[4] = 18, 770
        assert.are.equal("enrage", (feral.tank(o)))
        o.rage = 21
        assert.are.equal("faerie_fire", (feral.tank(o)))
        o.rage, o.distance = 0, 40
        assert.is_nil((feral.tank(o)))
        o.distance, o.role = 20, "DAMAGER"
        assert.are_not.equal("enrage", (feral.tank(o)))
        o.role, o.combat = "TANK", true
        assert.are.equal("faerie_fire", (feral.tank(o)))
        o.combat = false
        o.setup = function(_, c)
            c.exists.party1, c.unitCombat.party1 = true, true
        end
        assert.are_not.equal("enrage", (feral.tank(o)))
    end)

    it("uses early Maul on one mob and Swipe on a pack, including a skipped Maul", function()
        local o = { level = 16, known = { 5487, 6807, 779 }, combat = true, rage = 30 }
        assert.are.equal("maul", (feral.tank(o)))
        o.plate = true
        assert.are.equal("swipe_bear", (feral.tank(o)))
        o.distance = 8
        assert.are_not.equal("swipe_bear", (feral.tank(o)), "the selected mob is outside Swipe reach")
        o.distance = 3
        o.setup = function(H)
            H.Hekili:FireToggle("mode", "single")
        end
        assert.are.equal("maul", (feral.tank(o)), "explicit Single Target mode")
        o.setup = nil
        o.plate = "idle"
        assert.are.equal("swipe_bear", (feral.tank(o)), "the tank is already against the idle mob")
        o.plateDistance = 8
        assert.are.equal("maul", (feral.tank(o)))
        o.plate, o.known = nil, { 5487, 779 }
        assert.are.equal("swipe_bear", (feral.tank(o)))
    end)

    it("uses Swipe on close dungeon packs and requires confirmed reach to include controlled adds", function()
        local distance, controlled = 8, false
        local o = {
            level = 16,
            known = { 5487, 6807, 779 },
            combat = true,
            plate = true,
            setup = function(H, c)
                addPlate(H, c, "nameplate2", distance, false)
                if controlled then
                    c.auras.nameplate2 = { HARMFUL = {}, HELPFUL = {} }
                    aura(H, "nameplate2", false, 1324189, 1, 20)
                end
            end,
        }
        assert.are.equal("swipe_bear", (feral.tank(o)), "idle at eight yards")
        controlled = true
        assert.are.equal("swipe_bear", (feral.tank(o)), "sheep at eight yards")
        distance = 3
        assert.are.equal("swipe_bear", (feral.tank(o)), "sheep confirmed in Swipe reach")
        distance = SECRET
        assert.are.equal("swipe_bear", (feral.tank(o)), "unknown range does not veto two confirmed melee mobs")
        o.plate = nil
        assert.are.equal("maul", (feral.tank(o)), "unknown range also does not count toward the pack")
    end)

    it(
        "uses Swipe on a selected melee mob with unknown or idle combat only when another close mob is fighting the party",
        function()
            local o = { level = 16, known = { 5487, 6807, 779 }, combat = true, idle = true, plate = true }
            assert.are.equal("swipe_bear", (feral.tank(o)))
            o.setup = function(_, c)
                c.unitCombat.target = SECRET
            end
            assert.are.equal("swipe_bear", (feral.tank(o)))
            o.plateDistance = 8
            assert.is_nil((feral.tank(o)))
            o.plateDistance, o.plate = 3, "idle"
            assert.is_nil((feral.tank(o)))
        end
    )

    it("uses Demoralizing Roar on a confirmed nearby attacker regardless of the other plates", function()
        local o = {
            level = 16,
            known = { 99, 5487, 6807 },
            combat = true,
            distance = 8,
            setup = function(H, c)
                addPlate(H, c, "nameplate1", SECRET, false)
                aura(H, "target", false, 1324189, 1, 20)
            end,
        }
        assert.are.equal("demoralizing_roar", (feral.tank(o)))
        o.distance = 20
        assert.are_not.equal("demoralizing_roar", (feral.tank(o)))
    end)

    it("uses melee evidence when Swipe range and the selected GUID are hidden", function()
        local secondPlate = true
        local o = {
            level = 16,
            known = { 5487, 6807, 779 },
            combat = true,
            setup = function(H, c)
                c.guid.target = SECRET
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.is_nil(H.ns.Facade.TargetMemoryKey())
                addPlate(H, c, "nameplate1", 3, true)
                c.unitIs.nameplate1 = SECRET
                if secondPlate then
                    addPlate(H, c, "nameplate2", 3, true)
                    c.unitIs.nameplate2 = SECRET
                end
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
                H.ns.Facade.LibRangeCheck.GetRange = function()
                    return 0, 8
                end
                local spell = H.ns.Facade.C_Spell
                local inRange = spell.IsSpellInRange
                spell.IsSpellInRange = function(id, unit)
                    if id == 779 then
                        return nil, true
                    end
                    return inRange(id, unit)
                end
            end,
        }
        assert.are.equal("swipe_bear", (feral.tank(o)))
        secondPlate = false
        assert.are.equal("maul", (feral.tank(o)), "one plate might just be the selected mob")
    end)
    it("saves a five-stack Lacerate when another global would let it fall on a single target", function()
        local stacks, remaining = 5, 2.7
        local o = {
            known = { 5487, 1328616, 407995, 779 },
            level = 44,
            combat = true,
            rage = 50,
            setup = function(H)
                aura(H, "target", false, 1328616, stacks, remaining)
            end,
        }
        assert.are.equal("lacerate", (feral.tank(o)))
        remaining = 10
        assert.are.equal("primal_bite", (feral.tank(o)))
        stacks, remaining = 4, 2.7
        assert.are.equal("primal_bite", (feral.tank(o)))
        stacks, o.plate = 5, true
        assert.are.equal("primal_bite", (feral.tank(o)))
    end)

    it("queues advanced Maul above 35 Rage on one target and above 50 on a pack", function()
        local o = { level = 44, known = { 5487, 6807, 407995 }, combat = true, setup = biteCooldown }
        for _, plate in ipairs({ false, true }) do
            local threshold = plate and 50 or 35
            o.plate, o.rage = plate, threshold
            local action, out = feral.tank(o)
            assert.is_false(action == "maul" and out.recs[1].time == 0)
            o.rage = threshold + 1
            action, out = feral.tank(o)
            assert.are.equal("maul", action)
            assert.are.equal(0, out.recs[1].time)
        end
        o.plate = false
        o.rage, o.known, o.setup = 15, { 5487, 6807 }, nil
        assert.are.equal("maul", (feral.tank(o)))
        o.known[3] = 407995
        o.setup = function(H)
            H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].abilities.primal_bite.disabled = true
        end
        local action, out = feral.tank(o)
        assert.are.equal("maul", action)
        assert.are.equal(0, out.recs[1].time)
        o.known, o.setup = { 5487, 6807, 22842 }, nil
        o.health = 200
        assert.are.equal("frenzied_regeneration", (feral.tank(o)))
        o.distance = 20
        assert.are.equal("frenzied_regeneration", (feral.tank(o)), "self-defense does not need melee contact")
        o.distance = nil
        o.defensives = false
        assert.are.equal("maul", (feral.tank(o)))
        o.defensives, o.health = true, 1000
        o.setup = function(H)
            aura(H, "player", true, 22842, 1, 9)
        end
        assert.are_not.equal("maul", (feral.tank(o)))
    end)

    it("maintains Lacerate on the selected elite once the tank has secured the pack", function()
        local stacks, remains, threat = 0, 0, 3
        local o = {
            level = 44,
            known = { 5487, 779, 1328616, 407995 },
            combat = true,
            plate = true,
            setup = function(H, c)
                c.classification = "elite"
                c.exists.nameplate1target, c.threat.nameplate1 = true, threat
                if stacks > 0 then
                    aura(H, "target", false, 1328616, stacks, remains)
                end
            end,
        }
        assert.are.equal("primal_bite", (feral.tank(o)))
        stacks, remains = 2, 2.7
        assert.are.equal("lacerate", (feral.tank(o)))
        remains = 12
        assert.are.equal("primal_bite", (feral.tank(o)))
        o.known[4] = nil
        assert.are.equal("swipe_bear", (feral.tank(o)))
        stacks = 0
        assert.are.equal("lacerate", (feral.tank(o)))
        threat = 1
        assert.are.equal("swipe_bear", (feral.tank(o)))
        threat, o.enemyHealth = 3, 200
        assert.are.equal("swipe_bear", (feral.tank(o)))
    end)

    it("spreads its own Lacerate only to a held, durable melee add with swaps enabled", function()
        local durable, covered, threat = true, nil, 3
        local o = {
            level = 34,
            known = { 5487, 779, 1328616 },
            combat = true,
            plate = true,
            swaps = true,
            setup = function(H, c)
                H.ns.Facade.UnitClassification = function(unit)
                    return (unit == "target" or durable) and "elite" or "normal"
                end
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
                c.exists.nameplate1target, c.threat.nameplate1 = true, threat
                aura(H, "target", false, 1328616, 2, 12)
                if covered then
                    c.auras.nameplate1 = { HELPFUL = {}, HARMFUL = {} }
                    aura(H, "nameplate1", false, covered, 1, 10)
                end
            end,
        }
        local function check(want)
            local key, out, H = feral.tank(o)
            assert.are.equal(want, key == "lacerate" and out.recs[1].indicator == "cycle")
            return H
        end
        local H = check(true)
        local c = H.ctl
        c.guid.target, c.unitIs.target = c.guid.nameplate1, "nameplate1"
        c.auras.target.HARMFUL = {}
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("UNIT_AURA", "target")
        assert(headless.cycle(H, c.now + 1.6))
        local landing = H.Hekili.Engine.Output.Primary.recs[1]
        assert.are.equal("lacerate", landing.actionName)
        assert.are_not.equal("cycle", landing.indicator)
        durable = false
        check(false)
        durable, covered = true, 1328616
        check(false)
        covered = 118 -- Polymorph
        check(false)
        covered, threat = nil, 1
        check(false)
        threat, o.swaps = 3, false
        check(false)
        o.swaps, o.plateDistance = true, 12
        check(false)
    end)

    it("uses Berserk with funded Primal Bites on a durable enemy or confirmed melee pack", function()
        local elites, cooldowns, berserking = true, true, false
        local o = {
            level = 60,
            known = { 5487, 6807, 1328616, 407995, 417141 },
            combat = true,
            rage = 50,
            setup = function(H, c)
                c.classification = elites and "elite" or "normal"
                H.Hekili:FireToggle("cooldowns", cooldowns and "on" or "off")
                if berserking then
                    aura(H, "player", true, 417141, 1, 12)
                end
            end,
        }
        assert.are.equal("berserk", (feral.tank(o)))
        o.rage = 20
        assert.are.equal("primal_bite", (feral.tank(o)))
        o.rage, elites = 50, false
        assert.are.equal("primal_bite", (feral.tank(o)))
        o.plate = true
        assert.are.equal("berserk", (feral.tank(o)))
        o.enemyHealth = 200
        assert.are.equal("primal_bite", (feral.tank(o)))
        o.enemyHealth = 1000
        cooldowns = false
        assert.are.equal("primal_bite", (feral.tank(o)))
        elites, cooldowns, o.plate = true, true, "idle"
        assert.are.equal("berserk", (feral.tank(o)))
        berserking = true
        assert.are.equal("primal_bite", (feral.tank(o)))
        berserking, o.plate, o.instance, o.group, o.role = false, nil, "none", 0, "NONE"
        assert.are.equal("berserk", (feral.druid(o)))
    end)

    it("spreads Faerie Fire to an engaged dungeon enemy after the selected target's urgent attacks", function()
        local holding, waiting = true, true
        local o = {
            level = 44,
            known = { 5487, 770, 779, 407995 },
            combat = true,
            rage = 50,
            swaps = true,
            plate = true,
            setup = function(H, c)
                c.exists.nameplate1target, c.unitIs.nameplate1target = true, "player"
                if holding then
                    aura(H, "target", false, 770, 1, 20)
                end
                if waiting then
                    biteCooldown(H, c)
                end
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
            end,
        }
        local action, out = feral.tank(o)
        assert.are.equal("faerie_fire", action)
        assert.are.equal("cycle", out.recs[1].indicator)
        waiting = false
        assert.are.equal("primal_bite", (feral.tank(o)))
        waiting, o.swaps = true, false
        assert.are.equal("swipe_bear", (feral.tank(o)))
        o.swaps, o.plate = true, "idle"
        assert.are_not.equal("faerie_fire", (feral.tank(o)))
        holding, o.plate = false, true
        action, out = feral.tank(o)
        assert.are.equal("faerie_fire", action)
        assert.are_not.equal("cycle", out.recs[1].indicator)
    end)
end)
