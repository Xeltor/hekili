local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local wand = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }

-- Damage observations occur before combat. Deliberately return a different
-- number for Arcane so a wrong school cannot satisfy a Shadow comparison.
local function character(drain, options)
    local o = options or {}
    local known = { drain }
    if o.shoot ~= false then
        known[#known + 1] = 5019
    end
    local equipment
    if o.weapon ~= false then
        equipment = wand
    end
    return field.warlock("Affliction", o.level or 24, known, {
        weapon = equipment,
        shootUsable = true,
        health = o.health,
        talents = o.talents,
        beforeLoad = function(h)
            h.ctl.ranged = o.ranged or { 2, 24, 24, 0, 0, 1 } -- 12 DPS
            h.env.GetSpellBonusDamage = function(school)
                if school == 6 then
                    return o.shadow
                end
                return 900
            end
        end,
    })
end

local function worthDraining(h)
    field.pick(h)
    local state = h.Hekili.State
    state.reset("Primary")
    return state.warlock_leveling_drain
end

describe("Forever early Drain Life versus an equipped wand", function()
    it("compares the trained rank, real wand interval, and observed Shadow damage bonus", function()
        assert.is_false(worthDraining(character(689, { shadow = 0 }))) -- 10 vs 12
        assert.is_true(worthDraining(character(699, { shadow = 0 }))) -- 14 vs 12
        assert.is_true(worthDraining(character(689, { shadow = 30 }))) -- 13 vs 12
        assert.is_false(worthDraining(character(689, { shadow = 20 }))) -- equal DPS favors the free wand
        assert.is_false(worthDraining(character(699, { ranged = { 1, 20, 22, 0, 0, 1 }, shadow = 0 })))
    end)

    it("treats hidden, incomplete and invalidated observations as unknown", function()
        for _, o in ipairs({
            {},
            { shadow = SECRET },
            { shadow = 100, ranged = { 2, SECRET, 24, 0, 0, 1 } },
            { shadow = 100, ranged = { 2, 10, 24, SECRET, 0, 1 } },
            { shadow = 100, ranged = { 2, true, 24, 0, 0, 1 } },
            { shadow = 100, ranged = { 2, 0, 0, 0, 0, 1 } },
        }) do
            assert.is_false(worthDraining(character(699, o)))
        end
        for _, event in ipairs({ "UNIT_RANGEDDAMAGE", "SPELL_POWER_CHANGED", "PLAYER_EQUIPMENT_CHANGED" }) do
            local h = character(699, { shadow = 0 })
            assert.is_true(worthDraining(h))
            h.Fire(event, event == "UNIT_RANGEDDAMAGE" and "player" or 18)
            assert.is_false(worthDraining(h), event)
            h.ctl.combat = false
            h.Fire("PLAYER_REGEN_ENABLED")
            assert.is_true(worthDraining(h), event)
        end
    end)

    it("uses trained Improved Drains, Shadow Mastery and Soul Siphon for our qualifying DoTs", function()
        local function improved(rank)
            return worthDraining(character(699, {
                shadow = 0,
                ranged = { 1, 15, 16, 0, 0, 1 }, -- 15.5 DPS
                talents = { [403511] = rank },
            }))
        end
        assert.is_false(improved(1)) -- 14 * 1.07
        assert.is_true(improved(2)) -- 14 * 1.13
        local h = character(699, {
            shadow = 0,
            ranged = { 1, 16, 16, 0, 0, 1 },
            talents = { [18271] = 5, [17804] = 3 },
            level = 45,
        })
        assert.is_false(worthDraining(h)) -- 14 * 1.10 = 15.4
        local state = h.Hekili.State
        state.applyDebuff("target", "corruption", 1)
        assert.is_false(state.warlock_leveling_drain) -- only one tick benefits before Corruption ends
        state.applyDebuff("target", "corruption", 18)
        assert.is_true(state.warlock_leveling_drain) -- one Soul Siphon share raises the tick above 16
    end)

    it("permits all trained ranks from three and gates early ranks without a learned wand on sustain", function()
        assert.is_true(worthDraining(character(709, { level = 30, shadow = SECRET })))
        assert.is_false(worthDraining(character(699, { shoot = false, health = 1000 })))
        assert.is_true(worthDraining(character(699, { shoot = false, health = 800 })))
        assert.is_false(worthDraining(character(699, { weapon = false, health = SECRET })))
    end)
end)
