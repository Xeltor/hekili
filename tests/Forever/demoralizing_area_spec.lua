local headless = require("Game.harness.headless")
local protection = require("Forever.helpers.protection_leveling")
local feral = require("Forever.helpers.feral_pve")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function plate(H, index, distance, restricted)
    local ctl, unit = H.ctl, "nameplate" .. index
    local victim = unit .. "target"
    ctl.exists[unit], ctl.exists[victim] = true, true
    ctl.guid[unit] = restricted and SECRET or "Creature-0-0-0-0-347-00000" .. index
    ctl.distance[unit], ctl.level[unit] = distance, ctl.level.target
    ctl.unitCombat[unit], ctl.threat[unit], ctl.unitIs[victim] = true, 3, "player"
    ctl.auraError[unit] = true
    H.Fire("NAME_PLATE_UNIT_ADDED", unit)
    return unit
end

local function selectPlate(H, unit)
    local ctl = H.ctl
    local previous = ctl.unitIs.target
    if previous then
        ctl.unitIs[previous] = nil
    end
    ctl.guid.target, ctl.distance.target = ctl.guid[unit], ctl.distance[unit]
    ctl.unitIs.target, ctl.unitIs[unit] = unit, "target"
    H.Fire("PLAYER_TARGET_CHANGED")
end

local function read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + seconds))
    assert.are.same({}, H.errors)
    H.Hekili.State.reset("Primary")
    local output = H.Hekili.Engine.Output.Primary
    return output.count > 0 and output.recs[1].actionName or nil
end

local cases = {
    {
        action = "demoralizing_shout",
        spell = 1160,
        boot = function()
            local H = protection.warrior(14, 15, { instance = "party", group = 5, threat = 3 })
            H.ctl.cooldown[6343] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 60 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            return H
        end,
    },
    {
        action = "demoralizing_roar",
        spell = 99,
        boot = function()
            local _, _, H = feral.tank({ level = 16, known = { 5487, 6807, 99 }, combat = true, rage = 15 })
            return H
        end,
    },
}

describe("Demoralizing area debuffs", function()
    for _, case in ipairs(cases) do
        it("excludes a selected target outside " .. case.action .. " and preserves unknown range behavior", function()
            local H = case.boot()
            H.ctl.auraError.target = true
            local distant = plate(H, 1, 20, false)
            local close = plate(H, 2, 4, false)
            selectPlate(H, distant)
            read(H, 0.2)

            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demoralizing-distant", case.spell)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demoralizing-distant", case.spell)
            read(H, 1.6)
            assert.is_true(H.Hekili.State.debuff[case.action].down, "selected target was outside the cast radius")

            selectPlate(H, close)
            read(H, 0.2)
            assert.is_true(H.Hekili.State.debuff[case.action].up, "nearby enemy was inside the cast radius")

            selectPlate(H, distant)
            H.ctl.distance.target = SECRET
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demoralizing-unknown", case.spell)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demoralizing-unknown", case.spell)
            read(H, 1.6)
            assert.is_true(H.Hekili.State.debuff[case.action].up, "selected target range was unknown")
        end)

        for _, restricted in ipairs({ false, true }) do
            local identity = restricted and "a restricted target matched to its plate" or "a readable GUID"
            it("remembers " .. case.action .. " coverage after tabbing using " .. identity, function()
                local H = case.boot()
                H.ns.Output.steady = false
                H.ctl.auraError.target = true
                local selected = plate(H, 1, 3, restricted)
                local close = plate(H, 2, 4, restricted)
                local distant = plate(H, 3, 20, restricted)
                selectPlate(H, selected)
                assert.are.equal(case.action, read(H, 0.2))
                if restricted then
                    assert.is_number(H.ns.Facade.TargetMemoryKey())
                end

                H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demoralizing-area", case.spell)
                H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demoralizing-area", case.spell)
                if not restricted then
                    read(H, 1.6)
                    assert.is_true(H.Hekili.State.debuff[case.action].up, "original target")
                end

                selectPlate(H, close)
                local action = read(H, restricted and 1.6 or 0.2)
                assert.is_true(H.Hekili.State.debuff[case.action].up, "nearby during the original cast")
                assert.are_not.equal(case.action, action)

                H.ctl.distance[distant] = 3
                selectPlate(H, distant)
                action = read(H, 0.2)
                assert.is_true(H.Hekili.State.debuff[case.action].down, "outside the original cast radius")
                assert.are.equal(case.action, action)

                if restricted then
                    H.Fire("NAME_PLATE_UNIT_REMOVED", close)
                    selectPlate(H, plate(H, 2, 4, true))
                    action = read(H, 0.2)
                    assert.is_true(H.Hekili.State.debuff[case.action].down, "reused plate is a different enemy")
                else
                    selectPlate(H, close)
                    action = read(H, 46)
                    assert.is_true(H.Hekili.State.debuff[case.action].down, "original debuff expired")
                end
                assert.are.equal(case.action, action)
            end)
        end
    end

    it("reuses old area memory when another pack comes into range", function()
        local H = cases[2].boot()
        H.ctl.auraError.target = true
        selectPlate(H, plate(H, 1, 3, false))
        for index = 2, 17 do
            plate(H, index, 4, false)
        end
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demoralizing-first-pack", 99)
        read(H, 1.6)
        for index = 2, 17 do
            H.ctl.distance["nameplate" .. index] = 20
        end
        local new = plate(H, 18, 4, false)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demoralizing-second-pack", 99)
        selectPlate(H, new)
        assert.are_not.equal("demoralizing_roar", read(H, 1.6))
        assert.is_true(H.Hekili.State.debuff.demoralizing_roar.up)
    end)
end)
