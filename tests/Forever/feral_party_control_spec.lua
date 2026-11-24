local headless = require("Game.harness.headless")
local tank = require("Forever.helpers.feral_pve").tank

local function control(c, unit, id)
    c.auras[unit] = {
        HARMFUL = { { spellId = id, duration = 20, expirationTime = c.now + 20, sourceUnit = "party2" } },
        HELPFUL = {},
    }
end

describe("Druid party crowd control", function()
    it("continues tanking the active target without hitting a nearby sheep or trap", function()
        local o = { level = 44, combat = true, rage = 50, known = { 5487, 6807, 779, 1328616 }, plate = true }
        assert.are.equal("swipe_bear", (tank(o)))
        for _, id in ipairs({ 1324189, 3355 }) do
            o.setup = function(_, c)
                control(c, "nameplate1", id)
            end
            assert.are.equal("lacerate", (tank(o)))
        end
        o.plateDistance = 25
        assert.are.equal("lacerate", (tank(o))) -- the only active melee target
    end)

    it("resumes attacks on the same enemy when the party's Polymorph ends", function()
        local first, _, H = tank({
            level = 44,
            combat = true,
            rage = 50,
            known = { 5487, 6603, 6807, 407995 },
            setup = function(_, c)
                c.current[6603] = true
                control(c, "target", 1324189)
            end,
        })
        assert.is_nil(first)
        H.ctl.auras.target.HARMFUL = {}
        H.Fire("UNIT_AURA", "target")
        assert(headless.cycle(H, H.ctl.now + 1.6))
        assert.are.same({}, H.errors)
        assert.are.equal("primal_bite", H.Hekili.Engine.Output.Primary.recs[1].actionName)
    end)

    it("only seeks a taunt-immune enemy if another pickup attack is funded", function()
        local o = {
            combat = true,
            rage = 0,
            known = { 5487, 6795, 6807 },
            swaps = true,
            plate = true,
            setup = function(H, c)
                c.exists.party1, c.groupRoles.party1, c.isPlayer.party1 = true, "HEALER", true
                c.exists.nameplate1target, c.unitIs.nameplate1target, c.threat.nameplate1 = true, "party1", 0
                local original = H.ns.Facade.DebuffImmunity
                H.ns.Facade.DebuffImmunity = function(key, guid, now)
                    if key == "growl" and guid == c.guid.nameplate1 then
                        return "immune NPC"
                    end
                    return original(key, guid, now)
                end
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
            end,
        }
        assert.are_not.equal("recover_threat", (tank(o)))
        o.rage = 50
        assert.are.equal("recover_threat", (tank(o)))
    end)

    it("keeps Growl and target switching off a controlled mob attacking a groupmate", function()
        local o = {
            combat = true,
            known = { 5487, 6795, 6807 },
            swaps = true,
            plate = true,
            setup = function(H, c)
                c.exists.party1, c.groupRoles.party1, c.isPlayer.party1 = true, "HEALER", true
                c.exists.nameplate1target, c.unitIs.nameplate1target, c.threat.nameplate1 = true, "party1", 0
                control(c, "nameplate1", 1324483)
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
            end,
        }
        assert.are_not.equal("recover_threat", (tank(o)))
        o.victim, o.threat = "party1", 0
        o.setup = function(_, c)
            control(c, "target", 1324483)
        end
        assert.is_nil((tank(o)))
    end)
end)
