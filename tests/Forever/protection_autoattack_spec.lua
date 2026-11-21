local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warrior, read, cast = fixture.warrior, fixture.read, fixture.cast

local function boot(rage, options)
    options = options or {}
    options.autoAttack = false
    local H = warrior(options.level or 28, rage, options)
    H.ns.Output.steady = false
    if options.engaged ~= false then
        H.ctl.exists.targettarget = true
        H.ctl.unitIs.targettarget = "player"
        H.ctl.unitCombat.target = true
    end
    return H
end

local function noAttack(H)
    read(H, 0.2)
    local out = H.Hekili.Engine.Output.Primary
    for i = 1, out.count do
        assert.is_not_equal("auto_attack", out.recs[i].actionName)
    end
end

describe("Protection's start-autoattack reminder", function()
    it("starts swinging before spending opening Rage on Battle Shout", function()
        local H = boot(10, { noBattleShout = true })
        assert.are.equal("auto_attack", read(H, 0.2))
        local out = H.Hekili.Engine.Output.Primary
        assert.are.equal(6603, out.recs[1].actionID)
        assert.are.equal(0, out.recs[1].time)
        H.ctl.current[6603] = true
        assert.are.equal("battle_shout", read(H, 0.2))
    end)

    it("requires no Rage, works through the GCD and appears only once per forecast", function()
        local H = boot(0)
        local gcd = H.Hekili.Engine.Registry.GCD_SPELL
        H.ctl.cooldown[gcd] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 1.5 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        for _ = 1, 2 do
            assert.are.equal("auto_attack", read(H, 0.2))
            local out, count = H.Hekili.Engine.Output.Primary, 0
            assert.are.equal(0, out.recs[1].time)
            for i = 1, out.count do
                if out.recs[i].actionName == "auto_attack" then
                    count = count + 1
                end
            end
            assert.are.equal(1, count)
        end
        H.ctl.current[6603] = true
        noAttack(H)
        H.ctl.current[6603] = false
        assert.are.equal("auto_attack", read(H, 0.2))
    end)

    it("can begin an outdoor melee pull even before Charge is learned", function()
        for _, level in ipairs({ 1, 5, 28, 60 }) do
            local H = boot(0, { level = level, prepull = true, engaged = false })
            H.ctl.unitCombat.target = false
            assert.are.equal("auto_attack", read(H, 0.2))
        end
        local H = boot(10, { prepull = true, distance = 15, noBattleShout = true })
        assert.is_not_equal("auto_attack", read(H, 0.2))
    end)

    it("starts melee before routine protection buffs but leaves urgent interrupts first", function()
        local H = boot(10, { demo = true })
        assert.are.equal("auto_attack", read(H, 0.2))
        H.ctl.current[6603] = true
        assert.are.equal("shield_block", read(H, 0.2))
        H = boot(10)
        cast(H, true)
        assert.are.equal("shield_bash", read(H, 0.2))
    end)

    it("helps an engaged dungeon target but leaves idle group pulls and raid priorities alone", function()
        assert.are.equal("auto_attack", read(boot(0, { instance = "party", group = 5, threat = 3 }), 0.2))
        local H = boot(0, { instance = "party", group = 5, prepull = true })
        H.ctl.unitIs.targettarget = "party1"
        assert.are.equal("auto_attack", read(H, 0.2))
        noAttack(boot(0, { instance = "party", group = 5, prepull = true, engaged = false }))
        noAttack(boot(0, { instance = "party", group = 5, engaged = false }))
        noAttack(boot(0, { instance = "raid", group = 10, threat = 3 }))
    end)

    it("requires a learned Attack, melee weapon and confirmed range", function()
        for _, options in ipairs({
            { noAttackSpell = true },
            { noWeapon = true },
            { distance = 10 },
            { distance = SECRET },
        }) do
            noAttack(boot(0, options))
        end
    end)

    it("requires an engaged hostile opponent for PvP Attack", function()
        for _, knob in ipairs({ "dead", "friendly" }) do
            local H = boot(0)
            H.ctl[knob].target = true
            H.Fire("PLAYER_TARGET_CHANGED")
            noAttack(H)
        end
        local H = boot(0)
        H.ctl.isPlayer.target = true
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("auto_attack", read(H, 0.2))
        H.ctl.unitCombat.target = false
        noAttack(H)
        noAttack(boot(0, { instance = "pvp" }))
    end)

    it("does not turn an unknown or secret autoattack flag into permission to attack", function()
        noAttack(boot(0, {
            autoAttackProbe = function()
                return nil
            end,
        }))
        noAttack(boot(0, {
            autoAttackProbe = function()
                return SECRET
            end,
        }))
    end)
end)
