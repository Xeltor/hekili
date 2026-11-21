local headless = require("Game.harness.headless")
local mage = require("Forever.helpers.mage_world").Frost
local rogue = require("Forever.helpers.rogue_world").Combat
local warlock = require("Forever.helpers.warlock_world").Affliction
local warrior = require("Forever.helpers.warrior_world")

local function warnings(world, level, spell, beforeLoad)
    local character = world.character()
    character.level, character.known, character.talents = level, { spell }, {}
    local H = headless.new({ character = character, beforeLoad = beforeLoad })
    assert.are.same({}, H.loadErrors)
    local seen = { level = 0, missing = 0 }
    H.Hekili.Notify = function(_, message)
        if message:find("below level 60", 1, true) then
            seen.level = seen.level + 1
        end
        if message:find("does not have any Hekili Forever modules loaded", 1, true) then
            seen.missing = seen.missing + 1
        end
    end
    for i, unit in ipairs({ "target", "player", "player" }) do
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", unit, "Cast-level-" .. i, spell)
    end
    assert.are.same({}, H.errors)
    return seen, H.Hekili.Class.initialized
end

describe("Forever class leveling warnings", function()
    for _, case in ipairs({
        { "Warrior", warrior, 78 },
        { "Rogue", rogue, 1752 },
        { "Warlock", warlock, 686 },
    }) do
        it("keeps " .. case[1] .. " quiet at levels 1 and 59", function()
            for _, level in ipairs({ 1, 59 }) do
                local seen, initialized = warnings(case[2], level, case[3])
                assert.is_true(initialized)
                assert.are.same({ level = 0, missing = 0 }, seen)
            end
        end)
    end

    it("warns a Mage once below 60 and stays quiet at 60", function()
        for _, level in ipairs({ 59, 60 }) do
            local seen, initialized = warnings(mage, level, 133)
            assert.is_true(initialized)
            assert.are.same({ level = level == 59 and 1 or 0, missing = 0 }, seen)
        end
    end)

    it("still warns when the player has no class module loaded", function()
        local seen, initialized = warnings(warlock, 12, 686, function(H)
            local loadAddon = H.env.C_AddOns.LoadAddOn
            H.env.C_AddOns.LoadAddOn = function(name)
                if name == "Hekili_Warlock" then
                    return false, "MISSING"
                end
                return loadAddon(name)
            end
        end)
        assert.is_falsy(initialized)
        assert.are.same({ level = 0, missing = 1 }, seen)
    end)
end)
