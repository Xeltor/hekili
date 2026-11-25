local F = require("Forever.helpers.feral_pve")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local HEALER, HEAL, SMITE = 4285, 6063, 9734

local function creature(npc, spawn)
    return ("Creature-0-4469-0-1941-%d-%010x"):format(npc, spawn)
end

local function recommend(selectedNPC, spellID, alternate)
    return F.druid({
        form = "bear_form",
        known = { 5487, 6807, 5211 },
        combat = true,
        interrupts = true,
        plate = alternate and (alternate.engaged or "idle"),
        plateDistance = alternate and alternate.distance,
        setup = function(H, ctl)
            ctl.guid.target = creature(selectedNPC, 1)
            ctl.ranges[5211] = { 0, 5 }
            H.Fire("PLAYER_TARGET_CHANGED")
            H.Fire("UNIT_SPELLCAST_START", "target", "Cast-42", spellID or SECRET, 42)
            H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
            if alternate then
                ctl.guid.nameplate1 = creature(alternate.npcID or HEALER, 2)
                ctl.exists.nameplate1target = true
                H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
                if alternate.casting then
                    H.Fire("UNIT_SPELLCAST_START", "nameplate1", "Cast-43", HEAL, 43)
                    H.Fire(
                        alternate.castShield and "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" or "UNIT_SPELLCAST_INTERRUPTIBLE",
                        "nameplate1"
                    )
                end
            end
        end,
    })
end

describe("PvE priority interrupt recommendations", function()
    it("uses Bash on a known heal and saves it through a readable routine cast", function()
        assert.are.equal("bash", (recommend(HEALER, HEAL)))
        assert.are_not.equal("bash", (recommend(HEALER, SMITE)))
    end)

    it("keeps a usable cue when the only healer's current spell is hidden", function()
        assert.are.equal("bash", (recommend(HEALER)))
        assert.are.equal("bash", (recommend(HEALER, nil, { engaged = true })))
        assert.are_not.equal("bash", (recommend(HEALER, nil, { engaged = true, casting = true })))
        assert.are.equal("bash", (recommend(HEALER, nil, { engaged = true, casting = true, castShield = true })))
    end)

    it("keeps Bash for an engaged healer in reach and ignores an idle or distant healer", function()
        assert.are_not.equal("bash", (recommend(1, SMITE, { engaged = true })))
        assert.are.equal("bash", (recommend(1, SMITE, { engaged = false })))
        assert.are.equal("bash", (recommend(1, SMITE, { engaged = true, distance = 20 })))
    end)

    it("uses Bash for a confirmed heal on the current target even with another healer nearby", function()
        assert.are.equal("bash", (recommend(HEALER, HEAL, { engaged = true })))
    end)

    it("recognizes a cataloged heal cast by a mob outside the NPC catalog", function()
        assert.are.equal("bash", (recommend(1, HEAL, { engaged = true })))
    end)

    it("reserves Bash for cataloged outdoor and dungeon healers before they start casting", function()
        local tornFinOracle = { npcID = 2376, engaged = true }
        local darkCaster = { npcID = 255072, engaged = true }
        assert.are_not.equal("bash", (recommend(1, SMITE, tornFinOracle)))
        assert.are_not.equal("bash", (recommend(1, SMITE, darkCaster)))
    end)

    it("saves Guardian Feral Charge through a movement opportunity when Interrupts is enabled", function()
        local function charge(npcID, interrupts)
            return F.tank({
                known = { 5487, 6807, 1238122 },
                combat = true,
                movement = true,
                distance = 12,
                interrupts = interrupts,
                setup = function(H, ctl)
                    ctl.guid.target = creature(npcID, 1)
                    H.Fire("PLAYER_TARGET_CHANGED")
                end,
            })
        end

        assert.are.equal("feral_charge", (charge(1, true)))
        assert.are_not.equal("feral_charge", (charge(HEALER, true)))
        assert.are.equal("feral_charge", (charge(HEALER, false)))
    end)
end)
