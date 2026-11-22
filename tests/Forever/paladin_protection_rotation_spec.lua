local fixture = require("Forever.helpers.paladin_protection")
local paladin, read = fixture.paladin, fixture.read
local strike, fury, righteous, rf, shield, ground = 679, 1311649, 20154, 25780, 20925, 26573

describe("Protection Paladin field priorities", function()
    it("shows the same Attack artwork as the learning catalog and respects an icon override", function()
        local H = paladin(1, 100, { known = { 6603 }, autoAttack = false, prepull = true })
        local engine = H.Hekili.Engine
        local attack = engine.Registry.Abilities().auto_attack
        assert.are.equal(135274, attack.texture)
        assert.are.equal("auto_attack", read(H))
        assert.are.equal(attack.texture, engine.Output.Primary.recs[1].texture)
        engine.settings.specs[H.Hekili.State.spec.id].abilities.auto_attack.icon = 132223
        assert.are.equal("auto_attack", read(H))
        assert.are.equal(132223, engine.Output.Primary.recs[1].texture)
    end)

    it("keeps manual resistance and utility auras, with Devotion as a learned fallback", function()
        local known = { 465, 7294 }
        local function prep(auras, learned)
            return read(paladin(20, 500, { known = learned or known, prepull = true, buffs = auras }))
        end
        assert.are.equal("devotion_aura", prep({}, { 465 }))
        assert.are.equal("retribution_aura", prep({}))
        assert.is_nil(prep({ 19891 }))
        assert.is_nil(prep({ 20218 }))
        assert.is_nil(prep({ 465 }))
    end)

    it("maintains Righteous Fury solo and keeps the short damage seal for ordinary pulls", function()
        local known = { fury, righteous, rf, strike }
        local function seal(o)
            o.known = known
            return read(paladin(30, 1000, o))
        end
        assert.are.equal("righteous_fury", seal({}))
        assert.are.equal("seal_of_righteousness", seal({ buffs = { rf } }))
        assert.are.equal("righteous_fury", seal({ group = 4, role = "TANK" }))
        assert.are.equal("seal_of_fury", seal({ group = 4, role = "TANK", buffs = { rf } }))
        assert.are.equal("seal_of_righteousness", seal({ group = 4, role = "DAMAGER" }))
        assert.are.equal("holy_strike", seal({ group = 4, role = "DAMAGER", buffs = { 20166 } }))
        assert.are.equal("seal_of_fury", seal({ classification = "elite", buffs = { rf } }))
        assert.are.equal("seal_of_righteousness", seal({ classification = "elite", noShield = true, buffs = { rf } }))
    end)

    it("reapplies a trained Righteous Fury without an enemy and honors role assignments before the pull", function()
        local function setup(o)
            o.noTarget, o.prepull, o.noShield, o.defensives = true, true, true, false
            o.known = o.known or { rf }
            return paladin(10, o.mana or 1000, o)
        end
        assert.are.equal("righteous_fury", read(setup({})))
        assert.are.equal("righteous_fury", read(setup({ group = 3 })))
        for _, id in ipairs({ rf, 407627 }) do
            assert.is_nil(read(setup({ buffs = { id } })))
        end
        assert.is_nil(read(setup({ known = {} })))
        assert.is_nil(read(setup({ mana = 1 })))
        for _, role in ipairs({ "DAMAGER", "HEALER" }) do
            assert.is_nil(read(setup({ group = 3, role = role })))
        end
        for _, instance in ipairs({ "none", "party", "raid" }) do
            local H = setup({ group = 3, role = "NONE", instance = instance })
            H.ctl.groupRoles[instance == "raid" and "raid2" or "party2"] = "TANK"
            H.Fire("GROUP_ROSTER_UPDATE")
            assert.is_nil(read(H), instance)
        end
        assert.are.equal("righteous_fury", read(paladin(10, 1000, { known = { rf }, noTarget = true })))
    end)

    it("prices Righteous Fury from the learned spell, with free upkeep only during the resurrection buff", function()
        local function prep(id, mana, legacy)
            return paladin(13, mana, {
                known = { id },
                noTarget = true,
                prepull = true,
                buffs = legacy and { 1262310 } or {},
                beforeLoad = function(H)
                    H.ctl.costs[id] = { { type = 0, cost = 63 } } -- 30% of a 210 base, gear raises maximum mana
                end,
            })
        end
        for _, id in ipairs({ rf, 407627 }) do
            assert.are.equal("righteous_fury", read(prep(id, 63)))
            assert.is_nil(read(prep(id, 62)))
        end
        local H = prep(rf, 0, true)
        assert.are.equal("righteous_fury", read(H))
        H.ctl.auras.player.HELPFUL = {}
        H.Fire("UNIT_AURA", "player")
        assert.is_nil(read(H), "buff removed")
        H = prep(rf, 0, true)
        assert.are.equal("righteous_fury", read(H))
        H.ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
        assert.is_nil(read(H), "combat ends the free upkeep")
    end)

    it("leaves an interrupted meal or travel to the player", function()
        local function setup(beforeLoad)
            return paladin(13, 1000, { known = { rf }, noTarget = true, prepull = true, beforeLoad = beforeLoad })
        end
        for _, spell in ipairs({ 433, 430 }) do
            local H = setup()
            H.ctl.auras.player.HELPFUL = { { spellId = spell, duration = 30, expirationTime = H.ctl.now + 30 } }
            H.Fire("UNIT_AURA", "player")
            assert.is_nil(read(H))
        end
        for _, api in ipairs({ "IsMounted", "UnitOnTaxi", "UnitHasVehicleUI", "UnitIsDeadOrGhost" }) do
            assert.is_nil(
                read(setup(function(H)
                    H.env[api] = function()
                        return true
                    end
                end)),
                api
            )
        end
    end)

    it("blocks actively with a shield under melee pressure, and spends the free global on damage otherwise", function()
        local function pick(o)
            o.known, o.buffs = { shield, strike }, { rf, fury }
            return read(paladin(30, 300, o))
        end
        assert.are.equal("holy_shield", pick({ group = 3, role = "TANK" }))
        assert.are.equal("holy_strike", pick({ group = 3, role = "TANK", noShield = true }))
        assert.are.equal("holy_strike", pick({ group = 3, role = "TANK", defensives = false }))
        assert.are.equal("holy_strike", pick({ group = 3, role = "TANK", targetVictim = "party1", threat = 0 }))
        assert.are.equal("holy_strike", pick({}))
        assert.are.equal("holy_shield", pick({ classification = "elite" }))
    end)

    it("uses Holy Shield against a solo elite attacking us when solo threat numbers are unavailable", function()
        local H = paladin(30, 300, { known = { shield, strike }, buffs = { fury }, classification = "elite" })
        H.ctl.threat.target = nil
        H.Fire("UNIT_THREAT_SITUATION_UPDATE", "player")
        assert.are.equal("holy_shield", read(H))
        H.ctl.unitIs.targettarget = "pet"
        H.Fire("UNIT_TARGET", "target")
        assert.are.equal("holy_strike", read(H))
    end)

    it("keeps raid off-tank seals even when the target's role is only known through the roster", function()
        for _, ownRole in ipairs({ "NONE", "TANK" }) do
            local H = paladin(60, 1000, {
                known = { strike, rf, fury, righteous },
                buffs = { 20166 },
                group = 20,
                instance = "raid",
                targetVictim = "raid2",
                threat = 0,
                role = ownRole,
                boss = true,
            })
            H.ctl.groupRoles.raid2 = "TANK"
            H.Fire("UNIT_TARGET", "target")
            assert.are.equal(ownRole == "TANK" and "righteous_fury" or "holy_strike", read(H))
            assert.is_false(H.Hekili.State.prot_pal_tanking)
        end
    end)

    it("protects a selected crowd-controlled enemy from a new swing, spell or area effect", function()
        for _, control in ipairs({ 1324538, 1324543 }) do
            local H = paladin(30, 500, {
                known = { 6603, 20066, 2878, strike, ground },
                buffs = { fury },
                classification = "elite",
                autoAttack = false,
            })
            H.ctl.auras.target.HARMFUL = {
                {
                    spellId = control,
                    expirationTime = H.ctl.now + 10,
                    duration = 10,
                    applications = 1,
                    sourceUnit = "player",
                },
            }
            H.Fire("UNIT_AURA", "target")
            assert.is_nil(read(H))
        end
    end)

    local function addMob(H, engaged, index, distance)
        index = index or 1
        local c, unit = H.ctl, "nameplate" .. index
        c.exists[unit], c.unitCombat[unit], c.distance[unit] = true, engaged, distance or 3
        c.guid[unit], c.level[unit], c.isPlayer[unit] = "Creature-0-0-0-0-347-00000" .. index, 30, false
        if engaged then
            c.unitIs[unit .. "target"], c.threat[unit] = "player", 3
        end
        H.Fire("NAME_PLATE_UNIT_ADDED", unit)
    end

    it("places Consecration on engaged packs, keeps a melee attack's mana and avoids idle bystanders", function()
        local function pick(mana, situation)
            local H = paladin(30, mana, {
                known = { ground, strike },
                buffs = { rf, fury },
                group = 4,
                role = "TANK",
                instance = situation == "raid" and "raid" or "party",
                classification = situation == "single" and "normal" or "elite",
            })
            if situation ~= "single" then
                addMob(H, true)
                if situation == "idle" or situation == "raid" or situation == "distant" then
                    addMob(H, false, 2, situation == "distant" and 35 or 7)
                end
            end
            return read(H)
        end
        assert.are.equal("consecration", pick(300, "pack"))
        assert.are.equal("holy_strike", pick(135, "pack"))
        assert.are.equal("holy_strike", pick(300, "single"))
        assert.are.equal("holy_strike", pick(300, "idle"))
        assert.are.equal("holy_strike", pick(300, "raid"))
        assert.are.equal("consecration", pick(300, "distant"))
    end)

    it("uses Hammer of Justice only for a real cast on a reachable, non-boss enemy", function()
        local function stop(o, cast)
            o.known, o.buffs = { 853, strike }, { righteous }
            local H = paladin(20, 300, o)
            if cast then
                fixture.cast(H, true)
            end
            return read(H)
        end
        assert.are.equal("hammer_of_justice", stop({}, true))
        assert.are.equal("hammer_of_justice", stop({ distance = 10 }, true))
        assert.are.equal("holy_strike", stop({}, false))
        assert.are.equal("holy_strike", stop({ boss = true }, true))
        assert.is_nil(stop({ distance = 20 }, true))
        assert.is_nil(stop({ instance = "party", idleTarget = true }, true))
    end)

    it("allows a real ranged execute, and observes Exorcism's creature and range requirements", function()
        local function pick(o)
            o.known = { 879, 24275 }
            return read(paladin(44, 1000, o))
        end
        assert.are.equal("hammer_of_wrath", pick({ distance = 15, targetHealth = 180, creature = "mechanical" }))
        assert.is_nil(pick({ distance = 15, targetHealth = 750, creature = "mechanical" }))
        assert.are.equal("exorcism", pick({ distance = 15, creature = "undead" }))
        assert.is_nil(pick({ distance = 40, creature = "undead" }))
    end)

    it("offers non-dropping emergency mitigation, preserves Forbearance, and honors the defense toggle", function()
        local function cues(o)
            o.known = { 1311015, 642, 498, 1022, strike }
            local H = paladin(40, 500, o)
            H.Hekili:FireToggle("cooldowns", "off")
            read(H)
            local c = H.Hekili.Engine.Output.Primary.healthCues
            return c.n > 0 and c[1].action or nil
        end
        assert.are.equal("templars_bulwark", cues({ group = 3, role = "TANK" }))
        assert.is_nil(cues({ group = 3, role = "TANK", buffs = { 25771 } }))
        assert.is_nil(cues({ group = 3, role = "TANK", defensives = false }))
    end)
end)
