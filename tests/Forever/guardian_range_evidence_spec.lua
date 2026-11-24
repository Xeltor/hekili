local tank = require("Forever.helpers.feral_pve").tank
local SECRET = require("Game.State.helpers.fake_api").SECRET

-- The client can check an individual melee spell even when the distance library can only
-- place the target somewhere between zero and eight yards.
local function contact(known, options)
    local o = options or {}
    o.known, o.combat, o.level, o.rage = known, true, o.level or 44, 50
    local setup = o.setup
    o.setup = function(H, ctl)
        ctl.current[6603] = true
        local lib = H.ns.Facade.LibRangeCheck
        local getRange = lib.GetRange
        lib.GetRange = function(self, unit, ...)
            if unit == "target" then
                return 0, 8
            end
            return getRange(self, unit, ...)
        end
        if setup then
            setup(H, ctl)
        end
    end
    return tank(o)
end

describe("Guardian group melee range", function()
    local strikes = { 5487, 6603, 6807, 1328616, 407995 }

    local function biteOnCooldown(H, ctl)
        ctl.cooldown[407995] = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 6 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
    end

    it("uses a confirmed melee spell through a distance bracket spanning melee", function()
        assert.are.equal("primal_bite", (contact(strikes)))
        assert.are.equal("lacerate", (contact(strikes, { setup = biteOnCooldown })))
        assert.are.equal("maul", (contact({ 5487, 6603, 6807, 407995 }, { setup = biteOnCooldown })))
        assert.are.equal("primal_bite", (contact(strikes, { level = 60, boss = true })))
    end)

    it("requires positive reach and group engagement even when movement is enabled", function()
        local function hidden(H)
            H.ns.Facade.C_Spell.IsSpellInRange = function()
                return nil, true
            end
        end
        for _, movement in ipairs({ false, true }) do
            assert.is_nil((contact(strikes, { movement = movement, distance = 7 })))
            assert.is_nil((contact(strikes, { movement = movement, setup = hidden })))
            assert.is_nil((contact(strikes, { movement = movement, idle = true })))
        end
    end)

    it("uses the live selected unit when no plate identifies its hidden GUID", function()
        local function keyless(H, ctl)
            ctl.guid.target = SECRET
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.is_nil(H.ns.Facade.TargetMemoryKey())
        end
        assert.are.equal("primal_bite", (contact(strikes, { setup = keyless })))
        assert.is_nil((contact(strikes, { setup = keyless, idle = true })))

        local rescue = { setup = keyless, threat = 0, victim = "party1", victimRole = "HEALER" }
        assert.are.equal("growl", (contact({ 5487, 6603, 6795 }, rescue)))
        rescue.victimRole = "TANK"
        assert.is_nil((contact({ 5487, 6603, 6795 }, rescue)))

        local pull = { known = { 5487, 770 }, distance = 20, setup = keyless }
        assert.are.equal("faerie_fire", (tank(pull)))
        pull.setup = function(H, ctl)
            keyless(H, ctl)
            ctl.exists.party1, ctl.unitCombat.party1 = true, true
        end
        assert.is_nil((tank(pull)))
    end)
end)
