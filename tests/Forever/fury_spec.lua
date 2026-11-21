-- tests/Forever/fury_spec.lua: the Fury kit on the headless engine: a booted Fury Warrior (helpers/warrior_world.lua's
-- character plus Bloodthirst) on its default priority, Fury (wowsims.com).
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

local BLOODTHIRST = 23881

local H, st

-- A Fury Warrior in `stance`, in melee with a level 60 target.
local function boot(stance)
    local c = ww.character()
    c.instanceType = "raid" -- this fixture exercises Victory Rush in the sustained WoWSims priority
    c.known[#c.known + 1] = BLOODTHIRST
    local talents = {}
    for k, v in pairs(ww.TALENTS) do
        talents[k] = v
    end
    talents[BLOODTHIRST] = 1
    c.talents, c.form = talents, ww.FORM[stance]
    H = headless.new({ character = c, pack = "Fury (wowsims.com)" })
    assert.are.same({}, H.loadErrors)
    H.ctl.inRange.target, H.ctl.level.target = true, 60
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, H.ctl.now + 0.2))
    st = H.Hekili.State
    st.reset("Primary", true) -- the now-state: the cycle's prediction may have simulated a stance return
    assert.is_true(st.buff[stance].up, stance)
end

describe("the Fury kit", function()
    -- The window (Victorious, 20 s) and the 30 s cooldown run apart: a cast is predicted only while both allow it.
    it("refuses Victory Rush when its cooldown ends after Victorious, and allows it when it ends inside", function()
        boot("berserker_stance")
        st.applyBuff("victorious", 5)
        st.cooldown.victory_rush.expires = st.query_time + 12
        st.advance(12)
        assert.is_true(st.cooldown.victory_rush.ready)
        assert.is_false(st.buff.victorious.up)
        assert.is_false((st:IsUsable("victory_rush")))
        st.reset("Primary", true)
        st.applyBuff("victorious", 5)
        st.cooldown.victory_rush.expires = st.query_time + 3
        st.advance(3)
        assert.is_true(st.cooldown.victory_rush.ready)
        assert.is_true(st.buff.victorious.up)
        assert.is_true((st:IsUsable("victory_rush")))
    end)

    -- The recipe's extra line (the user's ruling, 2026-10-21): Victory Rush, free, just above Bloodthirst.
    it("recommends Victory Rush ahead of Bloodthirst inside Victorious, and never outside it", function()
        boot("berserker_stance")
        H.ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
        H.ctl.auras.target.HARMFUL[1] = { -- Sunder Armor at 5: the list's Sunder lines stand aside
            name = "Sunder Armor",
            spellId = H.Hekili.Class.auras.sunder_armor.id,
            expirationTime = H.ctl.now + 30,
            duration = 30,
            applications = 5,
            sourceUnit = "player",
        }
        H.Fire("UNIT_AURA", "target")
        local function first()
            assert(headless.cycle(H, H.ctl.now + 0.2))
            local p = H.Hekili.Engine.Output.Primary
            local names = {} -- the on-GCD queue: an off-GCD line (Bloodrage) rides beside it
            for i = 1, p.count do
                local n = p.recs[i].actionName
                if H.Hekili.Class.abilities[n].gcd ~= "off" then
                    names[#names + 1] = n
                end
            end
            return names
        end
        local function pos(names, n)
            for i, v in ipairs(names) do
                if v == n then
                    return i
                end
            end
        end
        -- re-pin e2842f0a78: wowsims's plain Whirlwind now leads Bloodthirst, so the line sits below it
        local closed = first()
        assert.is_not_nil(pos(closed, "bloodthirst"), table.concat(closed, " "))
        assert.is_nil(pos(closed, "victory_rush"), table.concat(closed, " "))
        H.ctl.usable[402927] = { true, false } -- a kill with XP: the client's usability flips
        H.Fire("SPELL_UPDATE_USABLE")
        local open = first()
        local v, b = pos(open, "victory_rush"), pos(open, "bloodthirst")
        assert.is_true(v ~= nil and (b == nil or v < b), table.concat(open, " "))
    end)
end)

describe("Fury leveling and nonraid PvE recommendations", function()
    local fixture = require("Forever.helpers.protection_leveling")
    local function fight(level, rage, options)
        options = options or {}
        options.pack = "Fury (wowsims.com)"
        options.form = options.form or 1
        options.classification = options.classification or "normal"
        return fixture.warrior(level, rage, options)
    end

    it(
        "uses the first Heroic Strike before Rend is trained, then spends on Rend without stacking short-pull armor",
        function()
            for _, group in ipairs({ 0, 2 }) do
                assert.are.equal("heroic_strike", fixture.read(fight(1, 15, { group = group })))
                assert.are.equal("rend", fixture.read(fight(24, 15, { group = group })))
            end
        end
    )

    it("changes its damage stance at the Whirlwind unlock and uses the trained attack first", function()
        assert.are.equal("rend", fixture.read(fight(35, 30)))
        assert.are.equal("berserker_stance", fixture.read(fight(36, 10)))
        assert.are.equal("whirlwind", fixture.read(fight(36, 30, { form = 3 })))
        assert.is_not_equal("whirlwind", fixture.read(fight(36, 30, { form = 3, distance = 12 })))
    end)

    it("uses Battle Stance attacks if Whirlwind was trained without completing the stance quest", function()
        local H = fight(36, 25)
        H.ctl.known[2458] = nil
        H.Fire("SPELLS_CHANGED")
        assert.are.equal("rend", fixture.read(H))
        assert.is_false(H.Hekili.State:IsKnown("berserker_stance"))
    end)

    it("spends banked Rage on Bloodthirst or a short-pull Execute before considering a stance swap", function()
        local H = fight(40, 50, { talents = { [BLOODTHIRST] = 1 } })
        H.ctl.known[BLOODTHIRST] = true
        H.Fire("SPELLS_CHANGED")
        assert.are.equal("bloodthirst", fixture.read(H))
        H.ctl.usable[20660] = { true, false } -- the learned level-40 Execute rank
        H.Fire("SPELL_UPDATE_USABLE")
        assert.are.equal("execute", fixture.read(H))

        H = fight(40, 50, { form = 2 })
        assert.is_not_equal("berserker_stance", fixture.read(H))
        H = fight(40, 15, { form = 3 })
        H.ctl.cooldown[1680] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 10 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        H.ctl.usable[7887] = { true, false } -- an Overpower proc while Whirlwind is cooling
        H.Fire("SPELL_UPDATE_USABLE")
        fixture.read(H)
        local out = H.Hekili.Engine.Output.Primary
        for i = 1, out.count do
            assert.is_not_equal("battle_stance", out.recs[i].actionName)
            assert.is_not_equal("rend", out.recs[i].actionName)
        end
    end)

    it("takes a payable Overpower window, casts it before returning and leaves banked Rage alone", function()
        local function open(H)
            H.ctl.usable[11585] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
        end
        local H = fight(60, 8, { form = 3 })
        open(H)
        assert.are.equal("battle_stance", fixture.read(H))
        H.ctl.form = 1
        H.Fire("UPDATE_SHAPESHIFT_FORM")
        assert.are.equal("overpower", fixture.read(H))
        H.ctl.usable[11585] = { false, false }
        H.Fire("SPELL_UPDATE_USABLE")
        assert.are.equal("berserker_stance", fixture.read(H))

        H = fight(44, 8, { form = 3 })
        H.ctl.usable[11584] = { true, false } -- level-44 Overpower
        H.Fire("SPELL_UPDATE_USABLE")
        assert.are.equal("battle_stance", fixture.read(H))
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].abilities.battle_stance.disabled = true
        assert.is_not_equal("battle_stance", fixture.read(H))

        H = fight(60, 24, { form = 3 })
        open(H)
        assert.is_not_equal("battle_stance", fixture.read(H))
        H = fight(60, 3, { form = 3 })
        open(H)
        local first = fixture.read(H)
        assert.is_true(first ~= "battle_stance" or H.Hekili.Engine.Output.Primary.recs[1].time > 0)
    end)

    it("uses spare early Rage while Rend is active, with enough left for the next proc", function()
        local function bleeding(rage)
            local H = fight(24, rage)
            H.ctl.auras.target.HARMFUL[1] =
                { spellId = 6547, expirationTime = H.ctl.now + 15, applications = 0, sourceUnit = "player" }
            H.Fire("UNIT_AURA", "target")
            return H
        end
        assert.are.equal("heroic_strike", fixture.read(bleeding(40)))
        local H = bleeding(28)
        local first = fixture.read(H)
        assert.is_true(first ~= "heroic_strike" or H.Hekili.Engine.Output.Primary.recs[1].time > 0)
    end)

    it("keeps rage for Whirlwind and Bloodthirst before sundering a durable dungeon target", function()
        local options = { instance = "party", group = 5, threat = 0, form = 3, classification = "elite" }
        local H = fight(44, 35, options)
        assert.are.equal("whirlwind", fixture.read(H))
        H.ctl.cooldown[1680] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 10 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        -- Upcoming swings can fund a future Sunder. The slot must wait if it cannot yet leave 30 Rage.
        if fixture.read(H) == "sunder_armor" then
            local wait = H.Hekili.Engine.Output.Primary.recs[1].time
            local state = H.Hekili.State
            state.reset("Primary", true)
            assert.is_true(state.rage.lo < state.action.sunder_armor.cost + 30)
            assert.is_true(wait > 0)
            state.advance(wait)
            assert.is_true(state.rage.lo >= state.action.sunder_armor.cost + 30)
        end
        options.form = 1
        H = fight(24, 35, options)
        H.ctl.auras.target.HARMFUL[1] =
            { spellId = 6547, expirationTime = H.ctl.now + 15, applications = 0, sourceUnit = "player" }
        H.Fire("UNIT_AURA", "target")
        assert.are.equal("sunder_armor", fixture.read(H))
    end)

    it("spends an interrupt on an interruptible cast in the equipped stance", function()
        local H = fight(38, 15, { form = 3, instance = "party", group = 5 })
        fixture.cast(H, true)
        assert.are.equal("pummel", fixture.read(H))
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_equal("pummel", fixture.read(H))
        H = fight(14, 15)
        fixture.cast(H, true)
        assert.are.equal("shield_bash", fixture.read(H))
        H = fight(14, 15, { noShield = true })
        fixture.cast(H, true)
        assert.is_not_equal("shield_bash", fixture.read(H))
    end)

    it("uses direct damage before armor stacks against an engaged hostile player", function()
        local H = fight(40, 35, { form = 1, instance = "pvp", talents = { [BLOODTHIRST] = 1 } })
        H.ctl.isPlayer.target = true
        H.ctl.known[BLOODTHIRST] = true
        H.Fire("SPELLS_CHANGED")
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("bloodthirst", fixture.read(H))
        H.ctl.usable[20660] = { true, false }
        H.Fire("SPELL_UPDATE_USABLE")
        assert.are.equal("execute", fixture.read(H))
    end)

    it("uses Thunder Clap and then Cleave only when a second pack member is confirmed in range", function()
        local H = fight(24, 50, { group = 5, instance = "party", threat = 0 })
        H.ctl.guid.nameplate1 = "Creature-0-0-0-0-347-000003"
        H.ctl.exists.nameplate1, H.ctl.exists.nameplate1target = true, true
        H.ctl.unitIs.nameplate1target = "party1"
        H.ctl.unitCombat.nameplate1 = true
        H.ctl.distance.nameplate1 = 4
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        assert.are.equal("thunder_clap", fixture.read(H))
        fixture.cast(H, true)
        assert.are.equal("shield_bash", fixture.read(H))
        H.Fire("UNIT_SPELLCAST_STOP", "target", nil, nil, 77)
        H.ctl.cooldown[8198] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 6 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.are.equal("cleave", fixture.read(H))
        H.ctl.distance.nameplate1 = 40
        assert.is_not_equal("cleave", fixture.read(H))
    end)

    it("offers a learned damage action at every level on an ordinary engaged target", function()
        for level = 1, 60 do
            local H = fight(level, 35, { form = level < 36 and 1 or 3, instance = "party", group = 5, threat = 0 })
            local action = fixture.read(H, 0.2)
            assert.is_not_nil(action, "level " .. level)
            assert.is_true(H.Hekili.State:IsKnown(action), action .. " at level " .. level)
            assert.are.equal(level < 4 and "heroic_strike" or level < 36 and "rend" or "whirlwind", action)
        end
    end)

    it("holds health-spending rage generators while Gore Drinker healing is active", function()
        local H = fight(34, 0, { bloodrageReady = true, talents = { [1323967] = 2, [1329555] = 1 } })
        H.ctl.auras.player.HELPFUL[2] = { spellId = 1323969, expirationTime = H.ctl.now + 8, applications = 3 }
        H.Fire("UNIT_AURA", "player")
        local first = fixture.read(H)
        assert.is_not_equal("bloodrage", first)
        assert.is_not_equal("reckless_swings", first)
        H.ctl.auras.player.HELPFUL[2] = nil
        H.Fire("UNIT_AURA", "player")
        assert.are.equal("bloodrage", fixture.read(H))
    end)
end)

describe("the Fury world's off hand", function()
    local gate = require("Forever.helpers.fury_gate")

    it("learns talent attacks only from its allocated points", function()
        local function known(c, id)
            for _, learned in ipairs(c.known) do
                if learned == id then
                    return true
                end
            end
            return false
        end
        for _, level in ipairs({ 10, 24, 40, 60 }) do
            local c = gate.content(level).character()
            assert.is_false(known(c, 1310222), "the Fury build has no Spearing Strike")
            assert.are.equal(c.talents[1329555] ~= nil, known(c, 1329555))
        end
    end)

    it("pays Dual Wield Specialization by the character's rank", function()
        local ww = require("Forever.helpers.warrior_world")
        local function offHand(level)
            local C = gate.content(level)
            return C.gain(1, 2, 0, "HIT", C.character())
        end
        -- both cuts carry Unbridled Wrath 5/5: a proc's 1 rage on top (the roll stubbed to a proc)
        ww.wrng = {
            chance = function()
                return true
            end,
        }
        assert.is_near(1.73 * 1.9 + 1, offHand(24), 1e-9) -- the L24 cut stops short of the talent
        assert.is_near(1.73 * 1.5 * 1.9 + 1, offHand(60), 1e-9)
        ww.wrng = nil
    end)
end)
