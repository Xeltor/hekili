local fixture = require("Forever.helpers.paladin_protection")
local kit = require("Forever.helpers.paladin_world").Protection
local learn = require("Forever.wowsims.learn_paladin")

describe("Protection Paladin leveling", function()
    it("offers the trainer's Righteous Fury from level 10 on a solo Paladin with no target", function()
        local options = { prepull = true, noTarget = true }
        for _, level in ipairs({ 9, 10, 13 }) do
            local H = fixture.paladin(level, 1000, options)
            assert.are.equal(level >= 10, fixture.read(H) == "righteous_fury", "level " .. level)
        end
    end)

    it("uses trained ranks throughout the 1–60 Primary queue on solo and group pulls", function()
        for level = 1, 60 do
            local dungeon = level % 2 == 0
            local H = fixture.paladin(level, 1000, {
                group = dungeon and 5 or 0,
                instance = dungeon and "party" or "none",
                role = dungeon and "TANK" or "NONE",
            })
            local where = "level " .. level
            assert.is_truthy(fixture.read(H), where .. " must have an opening action")
            local queue = H.Hekili.Engine.Output.Primary
            for slot = 1, queue.count do
                local action = queue.recs[slot].actionName
                local ranks = assert(kit.IDS[action], where .. ": unexpected " .. action)
                local highest
                for _, id in ipairs(ranks) do
                    if learn[id] and learn[id] <= level and H.ctl.known[id] then
                        highest = id
                    end
                end
                assert.is_truthy(highest, where .. ": untrained " .. action)
                assert.are.equal(highest, H.ns.VirtualState.KnownID(ranks[1]), where .. ": " .. action)
            end
        end
    end)

    it("suppresses the level-60 notice only for a supported Paladin tree", function()
        local H = fixture.paladin(9, 1000, { prepull = true })
        local hk, notices = H.Hekili, {}
        assert.is_true(hk:GetSpecialization(100022).supportsLeveling)
        assert.is_falsy(hk:GetSpecialization(100021).supportsLeveling)
        assert.is_falsy(hk:GetSpecialization(100023).supportsLeveling)
        hk.Notify = function(_, message)
            if message:find("level 60", 1, true) then
                notices[#notices + 1] = message
            end
        end
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-protection", 20154)
        assert.are.equal(0, #notices)
        assert.is_truthy(hk:SetSpecChoice("retribution"))
        hk:SpecializationChanged()
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-retribution", 20154)
        assert.are.equal(1, #notices)
    end)
end)
