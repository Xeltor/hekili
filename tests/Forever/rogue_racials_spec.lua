local fixture = require("Forever.helpers.rogue_pve")
local rogue, pick, headless, SECRET = fixture.rogue, fixture.pick, fixture.headless, fixture.SECRET

local OFFENSIVE = {
    { race = "Orc", key = "blood_fury", id = 20572 },
    { race = "Troll", key = "berserking", id = 20554 },
    { race = "NightElf", key = "elunes_light", id = 1259799 },
    { race = "Gnome", key = "eureka", id = 1259812 },
}

local function damage(racial, spec, options)
    local o = {
        race = racial.race,
        spells = { racial.id },
        instance = "party",
        group = 5,
        threat = 0,
        kind = "elite",
        energy = 95,
        snd = true,
    }
    for key, value in pairs(options or {}) do
        o[key] = value
    end
    local H = rogue(spec or "Combat", 40, o)
    H.Hekili:FireToggle("cooldowns", "on")
    return H
end

local function control(race, id)
    local observed = { rows = {}, reads = 0 }
    local H = rogue("Combat", 30, {
        race = race,
        spells = { id },
        instance = "party",
        group = 5,
        threat = 0,
        defensives = true,
        beforeLogin = function(core)
            core.Client.C_LossOfControl.GetActiveLossOfControlDataCount = function()
                observed.reads = observed.reads + 1
                return observed.count or #observed.rows
            end
            core.Client.C_LossOfControl.GetActiveLossOfControlData = function(index)
                observed.reads = observed.reads + 1
                return observed.rows[index]
            end
        end,
    })
    return H, observed
end

local function effect(H, observed, kind, seconds)
    observed.rows[1] =
        { locType = kind, startTime = H.ctl.now, duration = seconds or 10, timeRemaining = seconds or 10 }
    H.Fire("LOSS_OF_CONTROL_UPDATE")
end

-- Movement is a plain client value captured by the state facade at load time.
local function resting(racial, options)
    local fake = require("Game.State.helpers.fake_api")
    local original = fake.new
    local motion = { moving = false }
    fake.new = function(...)
        local api, ctl = original(...)
        api.GetUnitSpeed = function()
            return motion.moving and 7 or 0, 7, 7, 4.72
        end
        return api, ctl
    end
    local o = {
        race = racial.race,
        spells = { racial.id },
        prepull = true,
        defensives = true,
        health = racial.health,
    }
    for key, value in pairs(options or {}) do
        o[key] = value
    end
    local ok, H = pcall(rogue, "Combat", 30, o)
    fake.new = original
    assert(ok, H)
    H.ctl.exists.target = false
    H.Fire("PLAYER_TARGET_CHANGED")
    H.Hekili:FireToggle("cooldowns", "on")
    return H, motion
end

describe("Rogue racial actives", function()
    for _, spec in ipairs({ "Assassination", "Combat", "Subtlety" }) do
        it(spec .. " uses each learned offensive racial in an engaged durable pull", function()
            for _, racial in ipairs(OFFENSIVE) do
                local H = damage(racial, spec)
                local rec = pick(H)
                assert.are.equal(racial.key, rec.actionName, racial.race)
                assert.are.equal(racial.id, rec.actionID, racial.race)
                H.Hekili:FireToggle("cooldowns", "off")
                assert.is_not_equal(racial.key, pick(H).actionName, racial.race)
            end
        end)
    end

    it("requires both racial ownership and the learned active", function()
        for _, racial in ipairs(OFFENSIVE) do
            assert.is_not_equal(racial.key, pick(damage(racial, nil, { race = "Human" })).actionName, racial.race)
            assert.is_not_equal(racial.key, pick(damage(racial, nil, { spells = {} })).actionName, racial.race)
        end
    end)

    it("does not start damage racials without enough certain Energy, and saves Eureka for a full burst", function()
        for _, racial in ipairs(OFFENSIVE) do
            assert.is_not_equal(racial.key, pick(damage(racial, nil, { energy = 0 })).actionName, racial.race)
            local H = damage(racial)
            H.ctl.power[3] = SECRET
            local VS = H.ns.VirtualState
            local original = VS.Power
            local pool = { est = 100, lo = 0, hi = 100, conf = 1 }
            VS.Power = function(pt, now)
                return pt == 3 and pool or original(pt, now)
            end
            local rec = pick(H)
            if rec.actionName == racial.key then
                -- A countdown is valid once guaranteed regeneration fills the required pool; the best estimate
                -- alone must not turn this into an immediate burst. Energy regenerates at 10 per second here.
                assert.is_true(rec.time >= (racial.key == "eureka" and 9 or 4), racial.race .. " uncertain Energy")
            end
        end
        assert.is_not_equal("eureka", pick(damage(OFFENSIVE[4], nil, { energy = 50 })).actionName)
    end)

    it("keeps offensive racials out of Stealth approaches, idle dungeon targets and ordinary short pulls", function()
        for _, racial in ipairs(OFFENSIVE) do
            local H = damage(racial, nil, { prepull = true, stealthed = true })
            assert.is_nil(pick(H).actionName, racial.race .. " stealth approach")
            H = damage(racial, nil, { prepull = true, idleTarget = true, threat = false })
            assert.is_nil(pick(H).actionName, racial.race .. " idle pull")
            H = damage(racial, nil, { kind = "normal" })
            assert.is_not_equal(racial.key, pick(H).actionName, racial.race .. " short pull")
        end
    end)

    for _, racial in ipairs({
        { race = "Human", key = "will_to_survive", id = 1259718, kinds = { "STUN", "STUN_MECHANIC" } },
        { race = "Gnome", key = "escape_artist", id = 20589, kinds = { "ROOT", "SNARE" } },
        {
            race = "Scourge",
            key = "will_of_the_forsaken",
            id = 7744,
            kinds = { "FEAR", "FEAR_MECHANIC", "CHARM", "SLEEP" },
        },
    }) do
        it(racial.key .. " reacts to observed removable control and clears after the event", function()
            local H, observed = control(racial.race, racial.id)
            for _, kind in ipairs(racial.kinds) do
                effect(H, observed, kind)
                assert.are.equal(racial.key, pick(H).actionName, kind)
                observed.rows[1] = nil
                H.Fire("LOSS_OF_CONTROL_UPDATE")
                assert.is_not_equal(racial.key, pick(H).actionName, "cleared " .. kind)
            end
            effect(H, observed, racial.kinds[1])
            H.Hekili:FireToggle("defensives", "off")
            assert.is_not_equal(racial.key, pick(H).actionName)
            H.Hekili:FireToggle("defensives", "on")
            effect(H, observed, "DISARM")
            assert.is_not_equal(racial.key, pick(H).actionName)
            effect(H, observed, racial.kinds[1])
            H.ctl.stealthed = true
            H.Fire("UPDATE_STEALTH")
            assert.is_not_equal(racial.key, pick(H).actionName, "preserved Stealth")
        end)
    end

    it("uses event-cached control without polling allocating rows during predictions, even without a target", function()
        local H, observed = control("Human", 1259718)
        H.ctl.exists.target = false
        H.Fire("PLAYER_TARGET_CHANGED")
        effect(H, observed, "STUN_MECHANIC", 2)
        assert.are.equal("will_to_survive", pick(H).actionName)
        local reads = observed.reads
        pick(H)
        pick(H)
        assert.are.equal(reads, observed.reads)
        assert(headless.cycle(H, H.ctl.now + 3))
        assert.is_not_equal("will_to_survive", pick(H).actionName)
    end)

    it("does not turn hidden control fields into permission to use a defensive racial", function()
        local H, observed = control("Human", 1259718)
        effect(H, observed, SECRET)
        assert.is_not_equal("will_to_survive", pick(H).actionName)
        observed.rows[1] = { locType = "STUN", startTime = SECRET, duration = SECRET, timeRemaining = SECRET }
        H.Fire("LOSS_OF_CONTROL_UPDATE")
        assert.is_not_equal("will_to_survive", pick(H).actionName)
        observed.count = SECRET
        H.Fire("LOSS_OF_CONTROL_UPDATE")
        assert.is_not_equal("will_to_survive", pick(H).actionName)
        assert.are.same({}, H.errors)
    end)

    it("offers the matching racial cleanse only for a readable removable player debuff", function()
        for _, racial in ipairs({
            { race = "Dwarf", key = "stoneform", id = 20594, dispels = { "Poison", "Disease" } },
            { race = "Orc", key = "shatter_curse", id = 1299026, dispels = { "Curse" } },
        }) do
            for _, dispel in ipairs(racial.dispels) do
                local H = rogue("Combat", 30, {
                    race = racial.race,
                    spells = { racial.id },
                    instance = "party",
                    group = 5,
                    threat = 0,
                    defensives = true,
                })
                H.ctl.auras.player.HARMFUL[1] = {
                    name = "Removable effect",
                    spellId = 900001,
                    dispelName = dispel,
                    applications = 1,
                    duration = 10,
                    expirationTime = H.ctl.now + 10,
                }
                H.Fire("UNIT_AURA", "player")
                assert.are.equal(racial.key, pick(H).actionName, dispel)
                H.Hekili:FireToggle("defensives", "off")
                assert.is_not_equal(racial.key, pick(H).actionName, dispel .. " disabled")
                H.Hekili:FireToggle("defensives", "on")
                H.ctl.auras.player.HARMFUL[1] = nil
                H.Fire("UNIT_AURA", "player")
                assert.is_not_equal(racial.key, pick(H).actionName, dispel .. " cleared")
            end
        end
    end)

    it("uses Stoneform for low-health physical pressure without requiring a dispellable effect", function()
        local H = rogue("Combat", 6, { race = "Dwarf", spells = { 20594 }, health = 600, defensives = true })
        assert.are.equal("stoneform", pick(H).actionName)
        H.Hekili:FireToggle("defensives", "off")
        assert.is_not_equal("stoneform", pick(H).actionName)
        H.Hekili:FireToggle("defensives", "on")
        H.ctl.unitHealth.player = 1000
        H.Fire("UNIT_HEALTH", "player")
        assert.is_not_equal("stoneform", pick(H).actionName)
        H.ctl.unitHealth.player = 600
        H.ctl.exists.targettarget = false
        H.ctl.unitIs.targettarget = nil
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("UNIT_HEALTH", "player")
        assert.is_not_equal("stoneform", pick(H).actionName, "no incoming melee pressure")
    end)

    for _, racial in ipairs({
        { race = "Troll", key = "rapid_regeneration", id = 1260270, health = 500, threshold = 60 },
        { race = "HighOrderSkyborne", key = "read_ley_line", id = 1259705, health = 700, threshold = 80 },
    }) do
        it(racial.key .. " offers recovery while stationary and safely out of combat, without a target", function()
            local H, motion = resting(racial)
            assert.are.equal(racial.key, pick(H).actionName)
            H.Hekili:FireToggle("defensives", "off")
            assert.is_not_equal(racial.key, pick(H).actionName)
            H.Hekili:FireToggle("defensives", "on")
            motion.moving = true
            H.Fire("PLAYER_STARTED_MOVING")
            assert.is_not_equal(racial.key, pick(H).actionName)
            motion.moving = false
            H.Fire("PLAYER_STOPPED_MOVING")
            assert.are.equal(racial.key, pick(H).actionName)
            H.ctl.unitCombat.player = true
            assert.is_not_equal(racial.key, pick(H).actionName)
            H.ctl.unitCombat.player = SECRET
            assert.is_not_equal(racial.key, pick(H).actionName)
            H.ctl.unitCombat.player = false
            H.ctl.stealthed = true
            H.Fire("UPDATE_STEALTH")
            assert.is_not_equal(racial.key, pick(H).actionName)
            H.ctl.stealthed = false
            H.Fire("UPDATE_STEALTH")
            H.ctl.unitHealth.player = 1000
            H.Fire("UNIT_HEALTH", "player")
            assert.is_not_equal(racial.key, pick(H).actionName)
        end)

        it(racial.key .. " keeps hidden health as a display cue without spending a predicted action", function()
            local H = resting(racial, { health = SECRET })
            assert.is_not_equal(racial.key, pick(H).actionName)
            local cues = H.Hekili.Engine.Output.Primary.healthCues
            assert.are.equal(1, cues.n)
            assert.are.equal(racial.key, cues[1].action)
            assert.are.equal(racial.threshold, cues[1].percent)
            H.Hekili:FireToggle("defensives", "off")
            pick(H)
            assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
        end)
    end
end)
