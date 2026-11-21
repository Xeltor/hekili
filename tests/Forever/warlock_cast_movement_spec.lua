local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("Forever Warlock cast movement requirements", function()
    it("blocks hardcasts and channels while running and resumes them on stopping, even with hidden speed", function()
        local spells = {
            shadow_bolt = 686,
            immolate = 348,
            corruption = 172,
            searing_pain = 5676,
            incinerate = 412758,
            soul_fire = 6353,
            drain_life = 689,
            drain_soul = 1120,
            drain_mana = 5138,
            health_funnel = 755,
            wrack = 1316697,
            rain_of_fire = 5740,
            hellfire = 1949,
            shoot = 5019,
            summon_imp = 688,
            summon_voidwalker = 697,
            create_healthstone = 6201,
        }
        local known = {}
        for _, id in pairs(spells) do
            known[#known + 1] = id
        end
        local h = field.warlock("Affliction", 60, known, {
            instanceType = "raid",
            group = 10,
            range = 3,
            petHealth = 500,
            weapon = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 },
            shootUsable = true,
            items = { [6265] = 3 },
            moving = true,
            beforeLoad = function(client)
                client.env.GetUnitSpeed = function()
                    return SECRET, SECRET, SECRET, SECRET
                end
            end,
        })
        local state = h.Hekili.State
        for _, moving in ipairs({ true, false }) do
            if not moving then
                h.Fire("PLAYER_STOPPED_MOVING")
            end
            field.pick(h)
            state.reset("Primary")
            assert.are.equal(moving, state.moving)
            for key in pairs(spells) do
                local usable, reason = state:IsUsable(key)
                assert.are.equal(not moving, usable, key .. ": " .. tostring(reason))
            end
        end
    end)

    it("distinguishes a true instant from a shortened but nonzero cast", function()
        local h = field.warlock("Demonology", 60, { 686, 172, 6353, 688 }, {
            moving = true,
            buffs = { 17941, 440873, 18708 },
            talents = { [17810] = 5, [440870] = 2, [18709] = 2 },
        })
        field.pick(h)
        local state = h.Hekili.State
        state.reset("Primary")
        for _, key in ipairs({ "shadow_bolt", "corruption" }) do
            assert.are.equal(0, state.action[key].cast)
            assert.is_true((state:IsUsable(key)), key)
        end
        for _, key in ipairs({ "soul_fire", "summon_imp" }) do
            assert.is_true(state.action[key].cast > 0, key)
            assert.are.same({ false, "requires standing still" }, { state:IsUsable(key) }, key)
        end
    end)

    it("distinguishes a root, silence, and stun when choosing spells or a wand", function()
        local rows = {}
        local h = field.warlock("Affliction", 24, { 705, 980, 5019 }, {
            weapon = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 },
            shootUsable = true,
            beforeLogin = function(client)
                local control = client.Client.C_LossOfControl
                control.GetActiveLossOfControlDataCount = function()
                    return #rows
                end
                control.GetActiveLossOfControlData = function(i)
                    return rows[i]
                end
            end,
        })
        local state = h.Hekili.State
        for _, case in ipairs({
            { "ROOT", true, true },
            { "SILENCE", false, true },
            { "STUN", false, false },
            { "FEAR", false, false },
        }) do
            rows[1] = { locType = case[1], startTime = h.ctl.now, duration = 30 }
            h.Fire("LOSS_OF_CONTROL_UPDATE")
            field.pick(h)
            state.reset("Primary")
            assert.are.equal(case[2], (state:IsUsable("shadow_bolt")), case[1])
            assert.are.equal(case[2], (state:IsUsable("bane_of_agony")), case[1])
            assert.are.equal(case[3], (state:IsUsable("shoot")), case[1])
        end
        rows[1] = nil
        h.Fire("LOSS_OF_CONTROL_UPDATE")
        field.pick(h)
        state.reset("Primary")
        assert.is_true((state:IsUsable("shadow_bolt")))
    end)

    it("can renew instant armor and safely tap on the move between pulls", function()
        local function prepare(spell, health, mana)
            return field.pick(field.warlock("Demonology", 20, { spell }, {
                prepull = true,
                noTarget = true,
                moving = true,
                health = health,
                mana = mana,
            }))
        end
        assert.are.equal("demon_skin", prepare(687))
        assert.are.equal("demon_armor", prepare(706))
        assert.are.equal("life_tap", prepare(1454, 1000, 100))
        assert.is_nil(prepare(1454, 250, 100))
    end)
end)
