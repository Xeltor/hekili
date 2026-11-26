local fixture = require("Forever.helpers.paladin_protection")
local secret = require("Game.State.helpers.fake_api").SECRET
local paladin, read = fixture.paladin, fixture.read
local bulwark, bubble, protection, holyShield, strike = 1311015, 642, 498, 20925, 679

local function healthCue(H, key, elapsed)
    read(H, elapsed)
    local cues = H.Hekili.Engine.Output.Primary.healthCues
    for i = 1, cues.n do
        if cues[i].action == key then
            return cues[i].percent
        end
    end
end

local function addMob(H, index, victim, yards)
    local c, token = H.ctl, "nameplate" .. index
    c.exists[token], c.unitCombat[token], c.distance[token] = true, true, yards or 3
    c.guid[token], c.level[token] = "Creature-0-0-0-0-347-00000" .. index, 45
    c.unitIs[token .. "target"] = victim
    c.threat[token] = victim == "player" and 3 or 0
    H.Fire("NAME_PLATE_UNIT_ADDED", token)
end

describe("Protection Paladin defensive decisions", function()
    it("reserves the raid tank's absorb until health or observed pressure calls for it", function()
        local H = paladin(60, 800, {
            known = { bulwark, strike },
            group = 20,
            instance = "raid",
            role = "TANK",
            boss = true,
        })
        assert.are_not.equal("templars_bulwark", read(H))
        assert.are.equal(45, healthCue(H, "templars_bulwark"))

        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, secret, 4)
        assert.are.equal(45, healthCue(H, "templars_bulwark"))
        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, 249, 4)
        assert.are.equal(45, healthCue(H, "templars_bulwark"))
        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, 250, 4)
        assert.are.equal(65, healthCue(H, "templars_bulwark"))
        assert.are_not.equal("templars_bulwark", read(H))
        assert.are.equal(45, healthCue(H, "templars_bulwark", 5.1))
    end)

    it("uses the absorb after taking damage when the selected mob disappears", function()
        local H = paladin(45, 800, { known = { bulwark }, group = 5, role = "TANK", instance = "party" })
        H.ctl.exists.target = false
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, 300, 1)
        assert.are.equal(65, healthCue(H, "templars_bulwark"))
        H.ctl.combat = false
        H.Fire("PLAYER_REGEN_ENABLED")
        assert.is_nil(healthCue(H, "templars_bulwark"))
    end)

    it("counts individual melee attackers, including while selecting a mob chasing someone else", function()
        local H = paladin(45, 800, {
            known = { bulwark, holyShield, strike },
            group = 5,
            role = "TANK",
            instance = "party",
            targetVictim = "party1",
            threat = 0,
            distance = 15,
        })
        addMob(H, 1, "player")
        addMob(H, 2, "player")
        addMob(H, 3, "party1")
        addMob(H, 4, "player", 15)
        assert.are.equal(45, healthCue(H, "templars_bulwark"))
        assert.is_true(H.Hekili.State.prot_pal_shield_pressure)
        addMob(H, 5, "player")
        assert.are.equal(65, healthCue(H, "templars_bulwark"))
    end)

    it("can bubble with the learned immunity when fighting alone outside", function()
        for _, spell in ipairs({ protection, bubble }) do
            local key = spell == bubble and "divine_shield" or "divine_protection"
            local H = paladin(spell == bubble and 40 or 6, 500, { known = { spell, strike }, health = secret })
            assert.are.equal(20, healthCue(H, key))
            H.ctl.unitHealth.player = 190
            H.Fire("UNIT_HEALTH", "player")
            assert.are.equal(key, read(H))
        end
    end)

    it("keeps both immunities out of shared pulls, uncertain fights and boss handoffs", function()
        for _, o in ipairs({
            { group = 3, role = "TANK" },
            { group = 3, role = "DAMAGER" },
            { group = 1, instance = "raid" },
            { instance = "party" },
            { classification = "worldboss" },
            { boss = true },
            { targetVictim = "pet" },
            { threat = 2 },
            { pet = true },
            { outsider = true },
            { roleHidden = true },
            { encounter = true },
            { bossUnit = true },
            { buffs = { 25771 } },
            { defensives = false },
            { prepull = true },
        }) do
            o.known, o.health = { bubble, protection, strike }, secret
            local H = paladin(45, 500, o)
            if o.pet then
                H.ctl.exists.pet = true
            end
            if o.outsider then
                addMob(H, 1, "stranger")
            end
            if o.roleHidden then
                H.ctl.unitIs.targettarget = secret
            end
            if o.encounter then
                H.ctl.encounterInProgress = true
            end
            if o.bossUnit then
                H.ctl.exists.boss1 = true
            end
            assert.is_nil(healthCue(H, "divine_shield"))
            assert.is_nil(healthCue(H, "divine_protection"))
            H.ctl.unitHealth.player = 190
            H.Fire("UNIT_HEALTH", "player")
            local pick = read(H)
            assert.are_not.equal("divine_shield", pick)
            assert.are_not.equal("divine_protection", pick)
        end
    end)
end)
