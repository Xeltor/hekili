local feral = require("Forever.helpers.feral_pve")

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

describe("Guardian threat and Rage priorities", function()
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

    it("reserves a white swing below 35 Rage after learning Primal Bite, and keeps the early Maul", function()
        local o = { level = 44, known = { 5487, 6807, 407995 }, combat = true, rage = 34, setup = biteCooldown }
        local action, out = feral.tank(o)
        assert.is_false(action == "maul" and out.recs[1].time == 0)
        o.rage = 35
        assert.are.equal("maul", (feral.tank(o)))
        o.rage, o.known, o.setup = 15, { 5487, 6807 }, nil
        assert.are.equal("maul", (feral.tank(o)))
        o.known = { 5487, 6807, 22842 }
        o.health = 200
        assert.are.equal("frenzied_regeneration", (feral.tank(o)))
        o.defensives = false
        assert.are.equal("maul", (feral.tank(o)))
        o.defensives, o.health = true, 1000
        o.setup = function(H)
            aura(H, "player", true, 22842, 1, 9)
        end
        assert.are_not.equal("maul", (feral.tank(o)))
    end)

    it("uses Berserk with funded Primal Bites on a durable enemy or safe pack", function()
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
        assert.are.equal("primal_bite", (feral.tank(o)))
        berserking = true
        assert.are.equal("lacerate", (feral.tank(o)))
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
