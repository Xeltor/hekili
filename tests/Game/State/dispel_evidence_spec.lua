local load = require("Game.State.helpers.load")
local fake = require("Game.State.helpers.fake_api")
local fs = require("Game.State.helpers.fake_spec")
local alloc = require("Game.State.helpers.alloc")

describe("player harmful dispel evidence", function()
    local ns, VS, I, api, ctl, saved

    local function scan(unit)
        ctl.Fire("UNIT_AURA", unit or "player")
        VS.Drain(ctl.now)
    end

    local function effect(kind, expiry)
        return { spellId = 900001, dispelName = kind, expirationTime = expiry, duration = 10, applications = 2 }
    end

    before_each(function()
        api, ctl = fake.new()
        ctl.now = 5
        saved = {}
        for _, key in ipairs({ "GetTime", "issecretvalue", "CreateFrame", "UnitGUID", "debugprofilestop" }) do
            saved[key] = rawget(_G, key) or false
        end
        _G.GetTime, _G.issecretvalue, _G.CreateFrame, _G.UnitGUID =
            api.GetTime, api.issecretvalue, api.CreateFrame, api.UnitGUID
        _G.debugprofilestop = function()
            return 0
        end
        ns = load.module()
        VS, I = ns.VirtualState, ns.VirtualStateInternal
        I.Build(fs.def(fs.new(9)), 5)
        VS.Start(api)
        ctl.Tick(5)
    end)

    after_each(function()
        for key, value in pairs(saved) do
            _G[key] = value or nil
        end
    end)

    it("reads an untracked harmful effect without exposing it as a tracked aura", function()
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        scan()
        assert.are.same({ 2, 15, 5 }, { ns.Facade.PlayerDebuffByDispel("EffectA", 5) })
        assert.is_nil(VS.Aura("player", 900001, 5))
        assert.is_nil(ns.Facade.PlayerDebuffByDispel("EffectB", 5))
        assert.is_nil(ns.Facade.PlayerDebuffByDispel("EffectA", 15)) -- a forecast past its observed expiry
        assert.are.equal(2, ns.Facade.PlayerDebuffByDispel("EffectA", 6)) -- forecast did not mutate evidence
        ctl.now = 15
        assert.is_nil(ns.Facade.PlayerDebuffByDispel("EffectA")) -- the default query uses the real clock
    end)

    it("drops evidence on removal, a secret walk or an error", function()
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        scan()
        ctl.auras.player.HARMFUL[1] = nil
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        scan()
        ctl.auras.player.HARMFUL[1] = fake.SECRET
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        scan()
        ctl.auraError.player = true
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
    end)

    it("never treats secret types or expiries as a positive dispel signal", function()
        ctl.auras.player.HARMFUL[1] = effect(fake.SECRET, 15)
        ctl.auras.player.HARMFUL[2] = effect("EffectA", fake.SECRET)
        ctl.auras.player.HARMFUL[3] = effect("EffectA", 0 / 0)
        ctl.auras.player.HARMFUL[4] = effect("EffectA", math.huge)
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
    end)

    it("ignores target and helpful effects and does not clear the player on a target update", function()
        ctl.auras.target.HARMFUL[1] = effect("EffectA", 15)
        ctl.auras.player.HELPFUL[1] = effect("EffectA", 15)
        scan("target")
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        scan()
        scan("target")
        assert.are.equal(2, VS.PlayerDebuffByDispel("EffectA", 5))
    end)

    it("accepts explicit no-expiry effects and forgets them on the next missing read", function()
        local row = effect("EffectA", 0)
        row.duration, row.applications = fake.SECRET, fake.SECRET
        ctl.auras.player.HARMFUL[1] = row
        scan()
        assert.are.same({ 1, math.huge, 5 }, { VS.PlayerDebuffByDispel("EffectA", 50) })
        ctl.auras.player.HARMFUL[1] = nil
        scan()
        assert.is_nil(VS.PlayerDebuffByDispel("EffectA", 5))
    end)

    it("allocates nothing while refreshing and reading already supplied aura rows", function()
        ctl.auras.player.HARMFUL[1] = effect("EffectA", 15)
        assert.are.equal(
            0,
            alloc.bytes(function()
                I.WalkAuras(api, 1, "player", 5)
                VS.PlayerDebuffByDispel("EffectA", 5)
            end, 1000)
        )
    end)
end)
