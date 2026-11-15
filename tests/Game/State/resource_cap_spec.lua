-- A resource cap is a nonlinear change: each stream keeps at most the cap, not a common estimated spend.
local load = require("Game.State.helpers.load")
local fake = require("Game.State.helpers.fake_api")
local fs = require("Game.State.helpers.fake_spec")
local alloc = require("Game.State.helpers.alloc")

describe("a modelled resource cap", function()
    local VS, I, R, r

    before_each(function()
        local ns = load.module()
        VS, I = ns.VirtualState, ns.VirtualStateInternal
        I.Build(fs.def(fs.new(9)), 1)
        I.api = fake.new()
        R, r = I.res, I.res.slotOf[fs.RAGE]
    end)

    local function seed(lo, est, hi)
        R.lo0[r], R.est0[r], R.hi0[r], R.over[r] = lo, est, hi, 0
    end

    local function band()
        local p = VS.Power(fs.RAGE, I.clock)
        return { p.lo, p.est, p.hi }
    end

    for _, case in ipairs({
        { "below", { 5, 10, 15 }, { 5, 10, 15 } },
        { "straddling", { 10, 20, 40 }, { 10, 20, 25 } },
        { "straddling above the estimate", { 10, 30, 40 }, { 10, 25, 25 } },
        { "above", { 30, 40, 50 }, { 25, 25, 25 } },
    }) do
        it("caps each stream independently when " .. case[1], function()
            seed(unpack(case[2]))
            I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
            assert.are.same(case[3], band())
            assert.are.equal(0, R.gain[r]) -- no invented gain or energize to explain a usability flip
            assert.are.equal(0, R.castGain[r])
        end)
    end

    it("caps the modelled floor without turning it into observed resource", function()
        seed(10, 30, 40)
        R.over[r] = 15
        I.ResourceCap(r, 20, I.clock, VS.Obs.CastSuccess)
        assert.are.same({ 10, 10 }, { R.lo0[r], R.over[r] })
        assert.are.same({ 20, 20, 20 }, band())
    end)

    it("keeps zero and repeated caps loss-only, and does not change the resource maximum", function()
        seed(5, 10, 15)
        I.ResourceCap(r, 0, I.clock, VS.Obs.CastSuccess)
        I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
        assert.are.same({ 0, 0, 0 }, band())
        assert.are.equal(100, R.max[r])
        I.ResourceShift(r, 30, I.clock, VS.Obs.CastSuccess)
        assert.are.same({ 30, 30, 30 }, band()) -- the one-time cap does not limit later gains
    end)

    it("retires the old calibration interval and accepts a later plain observation", function()
        seed(30, 40, 50)
        R.pinValid[r], R.pinDelta[r] = true, 10
        local spends = R.spends[r]
        I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
        assert.is_false(R.pinValid[r])
        assert.are.equal(0, R.pinDelta[r])
        assert.is_true(R.spends[r] > spends) -- an old credit cannot subtract a pre-cap step again
        I.Sources.Direct(VS.Obs.Read, 2, r, 38, I.ReadOf.Resource)
        I.Fold(2)
        assert.are.same({ 38, 38, 38 }, band())
    end)

    it("does not start a spend-triggered regeneration pause", function()
        seed(30, 40, 50)
        R.fsr[r], R.fsrUntil[r] = true, 0
        I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
        assert.are.equal(0, R.fsrUntil[r])
    end)

    it("does not discard calibration when the entire band was already below the cap", function()
        seed(5, 10, 15)
        R.pinValid[r], R.pinDelta[r] = true, 7
        local spends = R.spends[r]
        I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
        assert.are.same({ true, 7, spends }, { R.pinValid[r], R.pinDelta[r], R.spends[r] })
    end)

    it("allocates nothing on repeated casts", function()
        local function cap()
            seed(10, 30, 40)
            I.ResourceCap(r, 25, I.clock, VS.Obs.CastSuccess)
        end
        cap()
        assert.are.equal(0, alloc.bytes(cap, 1000))
    end)
end)
