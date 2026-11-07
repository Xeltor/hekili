local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local ws = require("Forever.helpers.wowsims")
local ww = require("Forever.helpers.warrior_world")
local HARVEST_WATCHER = "Creature-0-0-0-0-114-000001"

local function warrior(level, rage, options)
    options = options or {}
    local character = ws.content(ww, {
        level = level,
        learn = ws.learn("WARRIOR"),
        talents = ws.header("warrior_arms").talents,
        kit = { "shield_bash", "shield_wall", "retaliation" },
    }).character()
    if options.unarmed then
        character.items = {}
    elseif options.shield then
        character.items = { [16] = { 1, "Sword", "INVTYPE_WEAPON" }, [17] = { 2, "Shield", "INVTYPE_SHIELD" } }
    end
    character.form = options.form or 1
    character.power.value = rage
    character.instanceType = options.instance

    local H = headless.new({ character = character, pack = ww.PACK })
    assert.are.same({}, H.loadErrors)
    local ctl = H.ctl
    ctl.level.target, ctl.distance.target = level, options.distance or 3
    ctl.guid.target = options.target or ctl.guid.target
    ctl.groupMembers = options.group or 0
    ctl.inRaid = options.raid == true
    ctl.unitHealth.player = options.health or 1000
    ctl.itemCount[5512] = options.healthstone and 1 or 0
    if level == 1 or options.shout then
        ctl.auras.player.HELPFUL[1] = { spellId = 6673, expirationTime = ctl.now + 100, applications = 0 }
        H.Fire("UNIT_AURA", "player")
    elseif options.victorious then
        ctl.auras.player.HELPFUL[1] = { spellId = 402975, expirationTime = ctl.now + 20, applications = 0 }
        H.Fire("UNIT_AURA", "player")
    end
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, ctl.now + 0.2))
    ctl.combat = true
    H.Fire("PLAYER_REGEN_DISABLED")
    local VS = H.ns.VirtualState
    local power, pool = VS.Power, { est = rage, lo = rage, hi = rage, conf = 1 }
    VS.Power = function(pt, now)
        return pt == 1 and pool or power(pt, now)
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 0.2)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    local picks = {}
    for i = 1, out.count do
        picks[i] = out.recs[i].actionName
    end
    return picks
end

local function hostileChannel(H, interruptible)
    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
    H.Fire(interruptible and "UNIT_SPELLCAST_INTERRUPTIBLE" or "UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
end

describe("the shipped Arms leveling and PvE priority", function()
    it("uses Heroic Strike on a starting warrior as soon as it is affordable", function()
        assert.are.equal("heroic_strike", read(warrior(1, 18), 1.6)[1])
        local H = warrior(1, 5)
        if read(H, 1.6)[1] == "heroic_strike" then
            assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time > 0)
        end
    end)

    it("favors Rend on short outdoor pulls while leveling solo or in a party", function()
        assert.are.equal("rend", read(warrior(10, 25), 1.6)[1])
        assert.are.equal("rend", read(warrior(10, 25, { group = 2 }), 1.6)[1])
    end)

    it("keeps the sustained-fight damage priority in instances and raids", function()
        for _, options in ipairs({ { group = 2, instance = "party" }, { group = 2, raid = true } }) do
            local H = warrior(15, 25, options)
            assert.are.equal("sunder_armor", read(H, 1.6)[1])
            assert.is_false(H.Hekili.State.arms_open_world)
            assert.is_true(H.Hekili.State.arms_pve_target)
        end
    end)

    it("uses the same short-pull priority solo or in an outdoor party at level 60", function()
        local H = warrior(60, 35, { group = 2 })
        assert.are.same(read(warrior(60, 35)), read(H))
        assert.is_true(H.Hekili.State.arms_open_world)
    end)

    it("skips Rend on a Harvest Watcher before casting it", function()
        local H = warrior(14, 25, { target = HARVEST_WATCHER })
        assert.is_not_true(read(H, 1.6)[1] == "rend")
        assert.is_true(H.Hekili.State.arms_skip_rend)
    end)

    it("uses one Sunder Armor on a bleed-immune short pull before Mortal Strike is learned", function()
        local H = warrior(15, 35, { target = HARVEST_WATCHER, shout = true, health = SECRET, group = 2 })
        assert.are.equal("sunder_armor", read(H)[1])
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-sunder", 7386)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-sunder", 7386)
        assert.are.equal("heroic_strike", read(H, 1.6)[1])
        assert.are.equal(1, H.Hekili.State.debuff.sunder_armor.stack)
    end)

    it("backs off Rend for the immune unit without treating an ordinary miss as immunity", function()
        for _, outcome in ipairs({ "IMMUNE", "MISS" }) do
            local H = warrior(14, 25)
            assert.are.equal("rend", read(H, 1.6)[1])
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-1", 6546)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 6546)
            H.Fire("UNIT_COMBAT", "target", outcome, "", 0, 1)
            local nextAction = read(H, 1.6)[1]
            assert.are.equal(outcome == "IMMUNE", H.Hekili.State.arms_skip_rend)
            if outcome == "IMMUNE" then
                assert.is_not_true(nextAction == "rend")
                H.ctl.guid.target = "Creature-2"
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.equal("rend", read(H)[1])
                H.ctl.guid.target = "Creature-1"
                H.Fire("PLAYER_TARGET_CHANGED")
                read(H)
                assert.is_true(H.Hekili.State.arms_skip_rend)
                read(H, 30)
                assert.is_false(H.Hekili.State.arms_skip_rend)
            else
                assert.are.equal("rend", nextAction)
            end
        end
    end)

    it("keeps Bloodrage and the Rend immunity rule when joining an outdoor party at level 15", function()
        local H = warrior(15, 12, { target = HARVEST_WATCHER, health = SECRET })
        assert.are.equal("bloodrage", read(H)[1])
        H.ctl.groupMembers = 2
        H.Fire("GROUP_ROSTER_UPDATE")
        assert.are.equal("bloodrage", read(H)[1])
        assert.is_false(H.Hekili.State.solo)
        assert.is_true(H.Hekili.State.arms_skip_rend)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-bloodrage", 2687)
        H.ctl.cooldown[2687] = { isActive = true, isOnGCD = false }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.is_not_true(read(H)[1] == "bloodrage")
    end)

    it("holds Bloodrage when readable health is low or rage is already high", function()
        assert.are.equal("bloodrage", read(warrior(10, 5))[1])
        assert.is_not_true(read(warrior(10, 5, { health = 400 }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 5, { health = 400, group = 2 }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 5, { health = 400, group = 5, instance = "party" }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 40, { target = HARVEST_WATCHER, health = SECRET }))[1] == "bloodrage")
    end)

    it("takes Victory Rush at its level-20 unlock only with the kill proc", function()
        assert.are.equal("victory_rush", read(warrior(20, 35, { health = 600, victorious = true }), 1.6)[1])
        assert.is_not_true(read(warrior(20, 35, { health = 600 }), 1.6)[1] == "victory_rush")
        assert.is_not_true(read(warrior(19, 35, { health = 600, victorious = true }), 1.6)[1] == "victory_rush")
    end)

    it("uses Shield Bash only with a shield and an interruptible cast in range", function()
        local H = warrior(12, 35, { shield = true })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_true(read(H)[1] == "shield_bash")

        H = warrior(12, 35, { shield = true, form = 2 })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])

        H = warrior(15, 35, { shield = true, group = 5, instance = "party" })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])

        for _, case in ipairs({
            { options = { shield = true }, interruptible = false },
            { options = { shield = true, distance = 20 }, interruptible = true },
            { options = {}, interruptible = true },
            { level = 30, options = { shield = true, form = 3 }, interruptible = true },
        }) do
            H = warrior(case.level or 12, 35, case.options)
            hostileChannel(H, case.interruptible)
            assert.is_not_true(read(H)[1] == "shield_bash")
        end
    end)

    it("uses Pummel when already in Berserker Stance and respects the Interrupts toggle", function()
        local H = warrior(40, 35, { form = 3 })
        hostileChannel(H, true)
        assert.are.equal("pummel", read(H)[1])
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_true(read(H)[1] == "pummel")

        for _, form in ipairs({ 1, 2 }) do
            H = warrior(40, 35, { form = form })
            hostileChannel(H, true)
            assert.is_not_true(read(H)[1] == "pummel")
        end
    end)

    it("offers a Healthstone at low health in solo and group PvE and respects Defensives", function()
        local H = warrior(60, 35, { health = 250, healthstone = true })
        assert.are.equal("healthstone", read(H, 1.6)[1])
        H.Hekili:FireToggle("defensives", "off")
        assert.is_not_true(read(H)[1] == "healthstone")

        H = warrior(60, 35, { health = 250, healthstone = true, group = 5, instance = "party" })
        assert.are.equal("healthstone", read(H, 1.6)[1])

        H = warrior(60, 35, { health = 250, healthstone = true, group = 5, instance = "pvp" })
        assert.is_not_true(read(H, 1.6)[1] == "healthstone")
    end)

    it("offers Shield Wall only with a shield and the appropriate stance", function()
        assert.are.equal("shield_wall", read(warrior(30, 35, { health = 240, shield = true, form = 2 }), 1.6)[1])
        assert.is_not_true(read(warrior(30, 35, { health = 240, form = 2 }), 1.6)[1] == "shield_wall")
        assert.is_not_true(read(warrior(30, 35, { health = 240, shield = true }), 1.6)[1] == "shield_wall")
    end)

    it("requires a melee weapon for Heroic Strike, Rend, Sunder Armor, and Hamstring", function()
        local H = warrior(15, 35, { unarmed = true })
        read(H)
        for _, key in ipairs({ "heroic_strike", "rend", "sunder_armor", "hamstring" }) do
            assert.is_false((H.Hekili.State:IsUsable(key)), key)
        end
    end)

    it("uses a ready Overpower in Battle Stance with a melee weapon", function()
        for _, options in ipairs({ {}, { unarmed = true }, { form = 2 } }) do
            options.target = HARVEST_WATCHER
            local H = warrior(15, 35, options)
            H.ctl.usable[7384] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.are.equal(not options.unarmed and not options.form, read(H)[1] == "overpower")
        end
    end)

    it("respects the stance combinations for Rend, Thunder Clap, Hamstring, and Retaliation", function()
        for _, form in ipairs({ 1, 2, 3 }) do
            local H = warrior(30, 35, { form = form })
            read(H)
            local state = H.Hekili.State
            assert(state.reset())
            local function ready(key)
                return state:IsUsable(key) and state:TimeToReady(key) < 1
            end
            assert.are.equal(form ~= 3, ready("rend"))
            assert.are.equal(form ~= 3, ready("thunder_clap"))
            assert.are.equal(form ~= 2, ready("hamstring"))
            assert.are.equal(form == 1, ready("retaliation"))
        end
    end)
end)
