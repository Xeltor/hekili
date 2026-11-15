local fixture = require("Forever.helpers.rogue_pve")
local rogue, pick, SECRET = fixture.rogue, fixture.pick, fixture.SECRET

describe("Rogue melee Stealth intent", function()
    for _, spec in ipairs({ "Assassination", "Combat", "Subtlety" }) do
        it(spec .. " lets the player position an opener without a target-of-target", function()
            local o = { prepull = true, stealthed = true, daggers = true }
            assert.are.equal("ambush", pick(rogue(spec, 20, o)).actionName)
            o.instance, o.group = "party", 5
            local H = rogue(spec, 20, o)
            assert.are.equal("ambush", pick(H).actionName)
            assert.is_true(H.Hekili.Engine.Output.Primary.count > 1)
            H.ctl.stealthed = false
            H.Fire("UPDATE_STEALTH")
            assert.is_nil(pick(H).actionName)
            o.stealthed = false
            assert.is_nil(pick(rogue(spec, 20, o)).actionName)
        end)

        it(spec .. " falls back to a strike or finisher instead of holding Stealth indefinitely", function()
            local o = { prepull = true, stealthed = true, instance = "party", group = 5 }
            assert.are.equal("sinister_strike", pick(rogue(spec, 2, o)).actionName)
            o.points = 5
            assert.are.equal("eviscerate", pick(rogue(spec, 20, o)).actionName)
            o.points, o.daggers = 4, true
            assert.are.equal("ambush", pick(rogue(spec, 20, o)).actionName)
        end)

        it(spec .. " avoids positional strikes when the enemy is clearly attacking the player", function()
            local o = { stealthed = true, daggers = true }
            assert.are.equal("sinister_strike", pick(rogue(spec, 20, o)).actionName)
            assert.are.equal("cheap_shot", pick(rogue(spec, 26, o)).actionName)
        end)

        it(spec .. " still requires a living hostile melee target and a main-hand weapon", function()
            local o = { prepull = true, stealthed = true, daggers = true, distance = 10 }
            assert.is_nil(pick(rogue(spec, 20, o)).actionName)
            o.distance = SECRET
            assert.is_nil(pick(rogue(spec, 20, o)).actionName)
            o.distance, o.noMainWeapon = 3, true
            assert.is_nil(pick(rogue(spec, 20, o)).actionName)
            o.noMainWeapon = false
            for _, field in ipairs({ "dead", "friendly" }) do
                local H = rogue(spec, 20, o)
                H.ctl[field].target = true
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.is_nil(pick(H).actionName, field)
            end
        end)

        it(spec .. " does not bypass opener range or weapons through the sustained raid priority", function()
            local o =
                { prepull = true, stealthed = true, daggers = true, boss = true, instance = "raid", distance = 10 }
            assert.is_nil(pick(rogue(spec, 60, o)).actionName)
            o.distance, o.noMainWeapon = 3, true
            assert.is_nil(pick(rogue(spec, 60, o)).actionName)
        end)
    end

    it("does not treat unreadable target-of-target as proof that a positional opener is blocked", function()
        local H = rogue("Combat", 20, { prepull = true, stealthed = true, daggers = true })
        local original = H.Hekili.Client.UnitIsUnit
        H.Hekili.Client.UnitIsUnit = function(a, b)
            if a == "targettarget" and b == "player" then
                return SECRET
            end
            return original(a, b)
        end
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("ambush", pick(H).actionName)
    end)

    it("offers the opener before poison preparation and without reserving Energy for an unusable Kick", function()
        local o = { prepull = true, stealthed = true, daggers = true, poison = true }
        assert.are.equal("ambush", pick(rogue("Combat", 20, o)).actionName)
        o.prepull, o.cast, o.energy, o.group, o.threat = false, true, 10, 5, 0
        local rec = pick(rogue("Combat", 20, o))
        assert.is_not_nil(rec.actionName)
        assert.is_not_equal("kick", rec.actionName)
        assert.is_not_equal("instant_poison", rec.actionName)
    end)

    it("does not use a recent attack on a different enemy to authorize an idle dungeon pull", function()
        local H = rogue("Combat", 20, { instance = "party", group = 5, threat = 0 })
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-prior-target", 1757)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-prior-target", 1757)
        H.ctl.guid.target = "Creature-idle-next-target"
        H.ctl.unitCombat.target, H.ctl.exists.targettarget, H.ctl.threat.target = false, false, nil
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.is_nil(pick(H).actionName)
    end)
end)
