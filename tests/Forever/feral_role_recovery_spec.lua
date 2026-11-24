local F = require("Forever.helpers.feral_pve")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local forms = { 5487, 768, 6807, 1082 }

local function assignedTank(_, ctl)
    ctl.exists.party2, ctl.isPlayer.party2, ctl.groupRoles.party2 = true, true, "TANK"
end

local function noForm(out)
    for i = 1, out.count do
        local key = out.recs[i].actionName
        assert.is_false(key == "cat_form" or key == "bear_form", key)
    end
end

describe("Feral and Guardian party roles and recovery", function()
    it("keeps a wounded tank in Bear when the healer pulls a different enemy", function()
        local healerCombat = true
        local o = {
            known = { 5487, 6807, 5185 },
            health = 350,
            setup = function(_, ctl)
                ctl.exists.party1, ctl.groupRoles.party1, ctl.unitCombat.party1 = true, "HEALER", healerCombat
            end,
        }
        for _, auto in ipairs({ "0", "1" }) do
            o.autoUnshift = auto
            for _, missing in ipairs({ true, false }) do
                o.noTarget = missing
                local _, out = F.tank(o)
                for i = 1, out.count do
                    local key = out.recs[i].actionName
                    assert.is_false(key == "cancel_buff" or key == "healing_touch", key)
                end
            end
        end
        healerCombat, o.noTarget = SECRET, true
        assert.is_nil((F.tank(o)))
        healerCombat = false
        assert.are.equal("healing_touch", (F.tank(o)))
    end)

    it("prepares Cat for a damage assignment between pulls and respects a manual Bear during the fight", function()
        local o = { known = forms, role = "DAMAGER", noTarget = true, setup = assignedTank }
        assert.are.equal("cat_form", (F.tank(o)))
        o.noTarget = false
        assert.are.equal("cat_form", (F.tank(o)))
        o.setup = function(H, ctl)
            assignedTank(H, ctl)
            ctl.unitCombat.party2 = true
        end
        assert.are_not.equal("cat_form", (F.tank(o)))
        o.combat, o.victim, o.victimRole = true, "party2", "TANK"
        assert.are_not.equal("cat_form", (F.tank(o)))
        o.role, o.form = "NONE", "caster"
        assert.are.equal("cat_form", (F.tank(o)))
    end)

    it("leaves a caster assigned to healing in form when a dungeon or raid tank holds the enemy", function()
        for _, spec in ipairs({ "Feral", "Guardian" }) do
            local o = {
                spec = spec,
                known = forms,
                group = 5,
                role = "HEALER",
                form = "caster",
                combat = true,
                victim = "party1",
                victimRole = "TANK",
            }
            for _, instance in ipairs({ "none", "party", "raid" }) do
                o.instance = instance
                local _, out = F.druid(o)
                noForm(out)
            end
        end
    end)

    it("recognizes an outdoor party's assigned tank even when the selected enemy attacks the druid", function()
        local o = { known = forms, form = "cat_form", group = 3, combat = true, plate = true, setup = assignedTank }
        assert.are.equal("claw", (F.druid(o)))
        o.setup = nil
        assert.are.equal("bear_form", (F.druid(o)))
    end)

    it("uses Bear on an ordinary pull until both Cat Form and its front-facing builder are learned", function()
        for _, spec in ipairs({ "Feral", "Guardian" }) do
            local o = { spec = spec, known = { 5487, 768, 6807 } }
            assert.are.equal("bear_form", (F.druid(o)))
            o.known = forms
            assert.are.equal("cat_form", (F.druid(o)))
        end
    end)

    it("interrupts the enemy casting at the healer before the tank personally enters combat", function()
        local engaged = true
        local o = {
            known = { 5487, 6807, 5211, 1238122 },
            interrupts = true,
            setup = function(H, ctl)
                ctl.exists.party1, ctl.groupRoles.party1, ctl.unitCombat.party1 = true, "HEALER", true
                ctl.unitCombat.target = engaged
                ctl.exists.targettarget, ctl.unitIs.targettarget, ctl.inParty.targettarget = true, "party1", true
                H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
                H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
            end,
        }
        assert.are.equal("bash", (F.tank(o)))
        o.distance = 12
        assert.are.equal("feral_charge", (F.tank(o)))
        o.interrupts = false
        assert.are_not.equal("feral_charge", (F.tank(o)))
        o.interrupts, engaged = true, false
        assert.are_not.equal("feral_charge", (F.tank(o)))
    end)
end)
