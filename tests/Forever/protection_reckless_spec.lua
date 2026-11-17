local SECRET = require("Game.State.helpers.fake_api").SECRET
local fixture = require("Forever.helpers.protection_leveling")
local lw = require("Forever.helpers.load_warrior")
local warrior, read = fixture.warrior, fixture.read
local RECKLESS = 1329555

local function ready(options, rage, level)
    options = options or {}
    if options.talents == nil then
        options.talents = { [RECKLESS] = 1 }
    end
    if options.classification == nil then
        options.classification = "elite"
    end
    local H = warrior(level or 59, rage or 5, options)
    H.ctl.current[6603] = true
    return H
end

local function safe(H)
    read(H, 0.1)
    H.Hekili.State.reset("Primary")
    return H.Hekili.State.prot_reckless_safe
end

describe("Protection's contextual Reckless Swings", function()
    it("uses the learned talent at low rage with spare health and a durable melee target", function()
        for _, level in ipairs({ 59, 60 }) do
            for _, classification in ipairs({ "elite", "rareelite", "worldboss" }) do
                local H = ready({ health = 750, classification = classification }, 25, level)
                assert.is_true(safe(H), classification)
            end
        end
        assert.are.equal("reckless_swings", read(ready({ health = 1000 }, 0)))
    end)

    it("does not authorize a health cost with low or hidden health or an unlearned talent", function()
        for _, options in ipairs({ { health = 749 }, { health = SECRET }, { talents = {} } }) do
            local H = ready(options)
            assert.is_false(safe(H))
            assert.is_not_equal("reckless_swings", read(H))
        end
        local H = ready()
        H.ctl.unitHealthMax.player = SECRET
        assert.is_false(safe(H))
    end)

    it("requires current low rage and an active melee attack opportunity", function()
        assert.is_false(safe(ready({}, 26)))
        for _, options in ipairs({
            { prepull = true },
            { distance = 10 },
            { classification = "normal" },
            { classification = "rare" },
            { classification = SECRET },
            { instance = "raid" },
            { instance = "pvp" },
        }) do
            assert.is_false(safe(ready(options)))
        end
        local H = ready()
        H.ctl.current[6603] = false
        assert.is_false(safe(H))
        H = ready()
        H.ctl.usable[20662] = { true, false } -- level 59's Execute rank: target already near death
        assert.is_false(safe(H))
    end)

    it("does not refresh an active Reckless Swings buff", function()
        local H = ready()
        H.ctl.auras.player.HELPFUL[2] = { spellId = RECKLESS, expirationTime = H.ctl.now + 8, applications = 4 }
        H.Fire("UNIT_AURA", "player")
        assert.is_false(safe(H))
    end)
end)

describe("Reckless Swings' conservative rage accounting", function()
    local function belief()
        local H = ready({ unpinnedPower = true })
        local VS, I = H.ns.VirtualState, H.ns.VirtualStateInternal
        local t = H.ctl.now + 0.1
        VS.Drain(t) -- fold the fixture's queued combat entry before reading the pre-cast rage
        local before = VS.Power(1, t).est
        I.Sources.Direct(VS.Obs.CastSuccess, t, I.ab.bySpell[RECKLESS])
        VS.Drain(t)
        assert.are.equal(before, VS.Power(1, t).est) -- none of the four gains is paid at the cast
        assert.are.equal(4, select(2, VS.Aura("player", RECKLESS, t)))
        return H, VS, I, t, before
    end

    local function settled(VS, I, t, hand, kind)
        I.Sources.Direct(VS.Obs.SwingSettled, t, hand, t, kind)
        VS.Drain(t)
    end

    it("does not invent the four swings' rage at the cast or through an unmodelled charge reaction", function()
        local H, VS, I, t, before = belief()
        for n = 1, 5 do
            t = t + 0.1
            -- CN15 is still open: no charge bonus is invented from either known or presumed landed swings.
            settled(VS, I, t, n % 2 + 1, n == 2 and -1 or I.HitKind.WOUND)
            assert.are.equal(before, VS.Power(1, t).est)
        end
        assert.are.equal(0, I.nowErrors, tostring(I.nowError))
        assert.are.same({}, H.errors)
    end)

    it("accepts observed rage without paying delayed swings again after a later pin", function()
        local H, VS, I, t = belief()
        local pinTime = t + 1
        H.ctl.power[1] = 25 -- the real resource poll reads this exact value during Drain
        VS.Drain(pinTime)
        assert.are.equal(25, VS.Power(1, pinTime).est)
        H.ctl.power[1] = SECRET -- later polls must not mask a mistaken late gain by pinning it away
        -- The bonus, if earned, is already included in the exact read. Both late outcomes predate it.
        for n = 1, 2 do
            I.Sources.Direct(VS.Obs.SwingSettled, pinTime + n * 0.1, n, t + n * 0.1, I.HitKind.WOUND)
            VS.Drain(pinTime + n * 0.1)
            assert.are.equal(25, VS.Power(1, pinTime + n * 0.1).est)
        end
        -- An old swing settling after the buff expires also cannot revive a historical charge budget.
        I.Sources.Direct(VS.Obs.SwingSettled, t + 8.1, 1, t + 0.3, I.HitKind.WOUND)
        VS.Drain(t + 8.1)
        assert.are.equal(25, VS.Power(1, t + 8.1).est)
        assert.are.equal(0, I.nowErrors, tostring(I.nowError))
    end)

    it("does not pay or consume a charge for avoided swings or spell hits", function()
        local _, VS, I, t, before = belief()
        for _, kind in ipairs({ "DODGE", "PARRY", "MISS", "BLOCK" }) do
            t = t + 0.1
            settled(VS, I, t, 1, I.HitKind[kind])
            assert.are.equal(before, VS.Power(1, t).est)
            assert.are.equal(4, select(2, VS.Aura("player", RECKLESS, t)))
        end
        -- Heroic Strike and Cleave replace a white swing with a landed ability; neither is a white-swing reaction.
        for _, spell in ipairs({ 11567, 11609 }) do
            t = t + 0.1
            I.Sources.Direct(VS.Obs.Landed, t, I.ab.bySpell[spell], t)
            VS.Drain(t)
            assert.are.equal(before, VS.Power(1, t).est)
            assert.are.equal(4, select(2, VS.Aura("player", RECKLESS, t)))
        end
        assert.are.equal(0, I.nowErrors, tostring(I.nowError))
    end)

    it("does not pay after the eight-second buff expires", function()
        local _, VS, I, t, before = belief()
        t = t + 8.1
        settled(VS, I, t, 1, I.HitKind.WOUND)
        assert.are.equal(before, VS.Power(1, t).est)
        assert.is_nil(VS.Aura("player", RECKLESS, t))
    end)

    it("does not grant unearned rage in the forward simulation", function()
        local w = lw.load()
        local e = lw.env(w)
        lw.run(w.abilities.reckless_swings.handler, e)
        assert.are.same({}, e.gained)
        assert.are.equal(4, e.stacks.reckless_swings)
        assert.is_nil(w.resource[2].reckless_mainhand)
        assert.is_nil(w.resource[2].reckless_offhand)
    end)
end)
