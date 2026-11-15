-- The real stance handlers and now handlers must apply the same cap to all three resource streams.
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

describe("stance resource bands", function()
    local H, s, VS, I, slot

    before_each(function()
        H = headless.new({ character = ww.character(), pack = ww.PACK })
        assert.are.same({}, H.loadErrors)
        H.ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
        assert.is_true(headless.cycle(H, H.ctl.now + 0.2))
        s, VS, I = H.Hekili.State, H.ns.VirtualState, H.ns.VirtualStateInternal
        s.reset("Primary", true)
        slot = I.res.slotOf[1]
    end)

    local function seed(b)
        local R = I.res
        R.lo0[slot], R.est0[slot], R.hi0[slot], R.over[slot] = b[1], b[2], b[3], 0
        s.rage.actual_lo, s.rage.actual, s.rage.actual_hi = b[1], b[2], b[3]
        s.forecastResources("rage")
    end

    for _, stance in ipairs({ "battle_stance", "defensive_stance", "berserker_stance" }) do
        for _, case in ipairs({
            { "below", { 5, 10, 15 }, { 5, 10, 15 } },
            { "straddling", { 10, 30, 40 }, { 10, 25, 25 } },
            { "above", { 30, 40, 50 }, { 25, 25, 25 } },
        }) do
            it("keeps actual and forecast bands aligned for " .. stance .. " " .. case[1] .. " the cap", function()
                seed(case[2])
                local a = I.ab.bySpell[H.Hekili.Class.abilities[stance].id]
                local errors = I.nowErrors
                I.Sources.Direct(VS.Obs.CastSuccess, I.clock, a)
                I.Fold(I.clock)
                assert.are.equal(errors, I.nowErrors, I.nowError)
                local p = VS.Power(1, I.clock)
                assert.are.same(case[3], { p.lo, p.est, p.hi })
                s:RunHandler(stance, true)
                assert.are.same(case[3], { s.rage.lo, s.rage.current, s.rage.hi })
                s.rawGain(10, "rage")
                assert.are.same(
                    { case[3][1] + 10, case[3][2] + 10, case[3][3] + 10 },
                    { s.rage.lo, s.rage.current, s.rage.hi }
                )
            end)
        end
    end

    it("rebuilds cached resource forecasts and invalidates cost memoization", function()
        seed({ 10, 30, 40 })
        assert.are.equal(30, s.rage.current) -- populate the query-time cache before mutation
        local changes = s.changes
        s.capResource("rage", 20)
        assert.is_true(s.changes > changes)
        assert.are.same({ 10, 20, 20 }, { s.rage.lo, s.rage.current, s.rage.hi })
        s.capResource("rage", 50)
        assert.are.same({ 10, 20, 20 }, { s.rage.lo, s.rage.current, s.rage.hi })
    end)
end)
