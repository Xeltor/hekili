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
    it("opens on a targeted enemy without hard-casting a routine heal during the aggro transition", function()
        local headless = require("Game.harness.headless")
        for _, spec in ipairs({ "Feral", "Guardian" }) do
            local o = {
                spec = spec,
                level = 8,
                known = { 5176, 5185, 774 },
                health = 700,
                noTarget = true,
                uiOnly = true,
                setup = function(H)
                    local vis = H.Hekili.DB.profile.displays.Primary.visibility
                    vis.advanced = true
                    vis.pve.always, vis.pve.combat, vis.pve.target, vis.pve.combatTarget = 0, 0, 1, 1
                    H.Hekili:UpdateDisplayVisibility()
                end,
            }
            local _, _, H = F.druid(o)
            local c, d = H.ctl, H.env.HekiliDisplayPrimary
            local function refresh()
                d:UpdateAlpha()
                assert(headless.cycle(H, c.now + 0.5))
                assert.are.same({}, H.errors)
                local out = H.Hekili.Engine.Output.Primary
                return out.count > 0 and out.recs[1].actionName or nil
            end
            assert.are.equal(0, d.alpha)
            c.exists.target = true
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.equal("rejuvenation", refresh())
            assert.are.equal(1, d.alpha)
            c.exists.targettarget, c.unitIs.targettarget = true, "player"
            H.Fire("UNIT_TARGET", "target")
            assert.are.equal("wrath", refresh())
            c.unitCombat.target, c.threat.target = true, 3
            assert.are.equal("wrath", refresh())
            c.combat = true
            H.Fire("PLAYER_REGEN_DISABLED")
            assert.are.equal("wrath", refresh())
            c.unitHealth.player = 500
            H.Fire("UNIT_HEALTH", "player")
            assert.are.equal("rejuvenation", refresh())
            c.unitHealth.player = 350
            H.Fire("UNIT_HEALTH", "player")
            assert.are.equal("healing_touch", refresh())
            c.healthPlain, c.unitHealth.player = false, SECRET
            H.Fire("UNIT_HEALTH", "player")
            assert.are.equal("wrath", refresh())
            local cues = H.Hekili.Engine.Output.Primary.healthCues
            local bands = {}
            for i = 1, cues.n do
                bands[cues[i].action] = cues[i].percent
            end
            assert.are.same({ healing_touch = 40, rejuvenation = 55 }, bands)
            c.exists.target = false
            H.Fire("PLAYER_TARGET_CHANGED")
            refresh()
            assert.are.equal(0, d.alpha)
        end
    end)

    it("preserves tank form at a healthy pull and uses cast-time recovery between fights", function()
        for _, unshift in ipairs({ "0", "1" }) do
            local o = { known = { 5487, 6807, 6603, 5185, 774 }, autoUnshift = unshift, health = 700 }
            assert.are.equal("auto_attack", (F.tank(o)))
            o.noTarget = true
            assert.are.equal(unshift == "0" and "cancel_buff" or "healing_touch", (F.tank(o)))
        end
        local o = { level = 8, known = { 5176, 5185 }, health = 700 }
        assert.are.equal("wrath", (F.druid(o)))
    end)

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

    it("prepares Cat from caster for a damage assignment and keeps a manually chosen Bear", function()
        local o = { known = forms, role = "DAMAGER", form = "caster", noTarget = true, setup = assignedTank }
        assert.are.equal("cat_form", (F.tank(o)))
        o.noTarget = false
        assert.are.equal("cat_form", (F.tank(o)))
        o.form = "bear_form"
        assert.are_not.equal("cat_form", (F.tank(o)))
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
        local o = { known = forms, group = 3, combat = true, plate = true, setup = assignedTank }
        assert.are.equal("cat_form", (F.druid(o)))
        o.setup = nil
        assert.are.equal("bear_form", (F.druid(o)))
        o.form = "cat_form"
        assert.are.equal("claw", (F.druid(o)))
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
