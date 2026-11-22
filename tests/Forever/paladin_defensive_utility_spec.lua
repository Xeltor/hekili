local fixture = require("Forever.helpers.paladin_protection")
local secret = require("Game.State.helpers.fake_api").SECRET
local paladin, read = fixture.paladin, fixture.read

describe("Protection Paladin defensive utility", function()
    it("uses a learned self-dispel for a confirmed outdoor affliction", function()
        local function pick(kind, spell, extra)
            local o = extra or {}
            o.known = { spell }
            local H = paladin(45, 1000, o)
            H.ctl.auras.player.HARMFUL = {
                {
                    spellId = 999001,
                    dispelName = kind,
                    duration = 20,
                    expirationTime = H.ctl.now + 20,
                    applications = 1,
                },
            }
            H.Fire("UNIT_AURA", "player")
            return read(H)
        end
        assert.are.equal("purify", pick("Poison", 1152))
        assert.are.equal("purify", pick("Disease", 1152))
        assert.are.equal("cleanse", pick("Magic", 4987))
        assert.is_nil(pick("Magic", 1152))
        assert.is_nil(pick("Curse", 4987))
        assert.is_nil(pick(secret, 4987))
        assert.is_nil(pick("Magic", 4987, { group = 5, instance = "party" }))
        assert.is_nil(pick("Poison", 1152, { defensives = false }))
    end)

    it("breaks a movement effect to regain melee without spending Freedom on a stun or Holy lockout", function()
        local rows = {}
        local H = paladin(40, 1000, {
            known = { 1044 },
            group = 5,
            role = "TANK",
            instance = "party",
            distance = 15,
            beforeLogin = function(core)
                local loc = core.Client.C_LossOfControl
                loc.GetActiveLossOfControlDataCount = function()
                    return #rows
                end
                loc.GetActiveLossOfControlData = function(i)
                    return rows[i]
                end
            end,
        })
        local function effect(i, kind, mask)
            rows[i] = kind and { locType = kind, lockoutSchool = mask, startTime = H.ctl.now, duration = 10 } or nil
            H.Fire("LOSS_OF_CONTROL_UPDATE")
            return read(H)
        end
        assert.is_nil(read(H))
        assert.are.equal("blessing_of_freedom", effect(1, "ROOT"))
        assert.is_nil(effect(2, "STUN"))
        assert.is_nil(effect(2, "SCHOOL_INTERRUPT", 2))
        assert.are.equal("blessing_of_freedom", effect(2, "SCHOOL_INTERRUPT", 4))
        H.ctl.distance.target = 3
        assert.is_nil(effect(1, "SNARE"))
    end)

    it("refreshes talented Iron Creed before optional damage under heavy incoming damage", function()
        local H = paladin(48, 1000, {
            known = { 679, 26573 },
            talents = { [1311034] = 1 },
            buffs = { 25780, 1311649 },
            group = 5,
            role = "TANK",
            instance = "party",
        })
        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, 300, 1)
        assert.are.equal("holy_strike", read(H))
        assert.is_true(H.Hekili.State.prot_pal_heavy_pressure)
    end)

    it("can buy time to heal by stunning one solo enemy with enough mana for both spells", function()
        local function pick(mana, options)
            local o = options or {}
            o.known, o.health = { 853, 635 }, 430
            return read(paladin(12, mana, o))
        end
        assert.are.equal("hammer_of_justice", pick(100))
        assert.are.equal("holy_light", pick(40))
        assert.are_not.equal("hammer_of_justice", pick(100, { group = 3, role = "TANK" }))
        assert.are_not.equal("hammer_of_justice", pick(100, { distance = 15 }))
    end)
end)
