-- Recommendation spacing is a configurable own-cast policy, not a model of other players' crowd control or DR.
local load = require("Game.State.helpers.load")
local fake = require("Game.State.helpers.fake_api")
local fs = require("Game.State.helpers.fake_spec")

describe("debuff recommendation spacing", function()
    local ns, VS, I, api, ctl, h, saved

    local function cast(id, t)
        ctl.now = t
        ctl.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-spacing", id)
        ctl.Tick(t + 0.01)
        VS.Drain(t + 0.02)
    end

    local function target(guid, t)
        ctl.now, ctl.guid.target = t, guid
        ctl.Fire("PLAYER_TARGET_CHANGED")
        VS.Drain(t)
    end

    local function refusal(id, castAt, t, kind, guid)
        I.Sources.Stage(VS.Obs.Avoided, t, I.ab.bySpell[id], castAt, kind, guid)
        VS.Drain(t + 0.01)
    end

    before_each(function()
        api, ctl = fake.new()
        ctl.now = 1
        saved = {}
        for _, key in ipairs({ "GetTime", "UnitGUID", "CreateFrame", "issecretvalue", "debugprofilestop" }) do
            saved[key] = rawget(_G, key) or false
        end
        _G.GetTime, _G.UnitGUID, _G.CreateFrame, _G.issecretvalue =
            api.GetTime, api.UnitGUID, api.CreateFrame, api.issecretvalue
        _G.debugprofilestop = function()
            return 0
        end
        ns = load.module()
        VS, I = ns.VirtualState, ns.VirtualStateInternal
        h = fs.new(9)
        fs.clock = api.GetTime
        ns.spendResources = fs.spend
        ns.ResourceRegenerates = function()
            return false
        end
        h.State.spec = { id = 1 }
        h.Engine = { settings = { specs = { [1] = { settings = { spacing = 30 } } } } }
        for _, key in ipairs({ "spender_a", "spender_c" }) do
            local aura = h.Class.auras[key]
            aura.debuffRepeatGroup, aura.debuffRepeatDelay = "control", 30
            aura.debuffRepeatSetting, aura.debuffRetryDelay = "spacing", 30
            h.Class.abilities[key].expects = "debuff"
        end
        h.Class.auras.spender_c.debuffMechanic = "test_effect"
        h.Class.auras.spender_c.debuffImmuneNPCs = { 123456 }
        h.Class.auras.spender_a.debuffImmunities = { "test_effect" }
        load.schema(ns, h)
        VS.Start(api)
        ns.BuildTracked()
        ctl.Tick(1)
        I.ObsLog.Clear(I.log)
    end)

    after_each(function()
        for key, value in pairs(saved) do
            _G[key] = value or nil
        end
        fs.clock = nil
    end)

    it("starts only on an actual own cast and shares spacing across declared effects", function()
        local guid = ctl.guid.target
        h.State:RunHandler("spender_c") -- forecast only
        assert.is_nil(VS.DebuffRepeatBlocked("spender_c", guid, 5))
        cast(fs.SPENDER_C, 5)
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_a", guid, 34.99))
        assert.are.equal("recent own control attempt", VS.DebuffBlocked("spender_a", 6, guid))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 35))
        assert.is_not_nil(VS.Aura("target", fs.SPENDER_C, 5.1)) -- history must not suppress the actual cast's aura
    end)

    it("retains separate targets through swaps and survives combat end", function()
        local first = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        target("Creature-2", 6)
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", ctl.guid.target, 6))
        ctl.now = 7
        ctl.Fire("PLAYER_REGEN_ENABLED")
        VS.Drain(7.1)
        target(first, 8)
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_a", first, 8))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", first, 35))
    end)

    it("honors a changed spacing setting and zero opt-out without forgetting the cast", function()
        local guid = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        local settings = h.Engine.settings.specs[1].settings
        settings.spacing = 0
        h:SettingsChanged()
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 6))
        settings.spacing = 10
        h:SettingsChanged()
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_a", guid, 14.99))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 15))
    end)

    it("bounds ambiguity when identity becomes hidden and clears known history on confirmed death", function()
        local guid = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        assert.are.equal("recent own control attempt; target unknown", VS.DebuffRepeatBlocked("spender_a", nil, 6))
        I.Units.Dead(I.Units.Find(guid), 7)
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", nil, 8))
        target(fake.SECRET, 9)
        cast(fs.SPENDER_C, 10)
        assert.are.equal("recent own control attempt; target unknown", VS.DebuffRepeatBlocked("spender_a", nil, 11))
        assert.are.equal(
            "recent own control attempt; target unknown",
            VS.DebuffRepeatBlocked("spender_a", "Creature-2", 11)
        )
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", nil, 40))
    end)

    it("expires a matched transient immunity even with spacing disabled", function()
        local guid = ctl.guid.target
        h.Engine.settings.specs[1].settings.spacing = 0
        h:SettingsChanged()
        local a = I.ab.bySpell[fs.SPENDER_C]
        I.DebuffRefused(a, guid, I.HitKind.IMMUNE, 5)
        assert.are.equal("temporary immunity", VS.DebuffImmunity("spender_c", guid, 34.99))
        I.DebuffRefused(a, guid, I.HitKind.IMMUNE, 34)
        assert.are.equal("temporary immunity", VS.DebuffImmunity("spender_c", guid, 35))
        assert.are.equal("temporary immunity", VS.DebuffImmunity("spender_c", guid, 63.99))
        assert.is_nil(VS.DebuffImmunity("spender_c", guid, 64))
    end)

    it("releases only a proven failed attempt while retaining an earlier attempt", function()
        local guid = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        refusal(fs.SPENDER_C, 5, 5.1, I.HitKind.MISS, guid)
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 6))
        cast(fs.SPENDER_C, 8)
        cast(fs.SPENDER_C, 10)
        refusal(fs.SPENDER_C, 10, 10.1, I.HitKind.RESIST, guid)
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_a", guid, 37.99))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 38))
    end)

    it("does not let a late failure erase another ability's later cast or a different target", function()
        local first = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        cast(fs.SPENDER_A, 6)
        target("Creature-2", 7)
        cast(fs.SPENDER_C, 8)
        refusal(fs.SPENDER_C, 5, 9, I.HitKind.PARRY, first)
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_c", first, 35.99))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_c", first, 36))
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_c", "Creature-2", 37.99))
        assert.is_nil(VS.DebuffRepeatBlocked("spender_c", "Creature-2", 38))
    end)

    it("retains history across a tracked rebuild and matches failures by stable ability key", function()
        local guid = ctl.guid.target
        cast(fs.SPENDER_C, 5)
        local previous = I.ab.bySpell[fs.SPENDER_C]
        local extra = { key = "a_before", id = 999, cast = 0, cooldown = 0, charges = 1, recharge = 0, funcs = {} }
        h.Class.abilities.a_before, h.Class.abilities[999] = extra, extra
        ns.BuildTracked()
        assert.is_not_equal(previous, I.ab.bySpell[fs.SPENDER_C])
        assert.are.equal("recent own control attempt", VS.DebuffRepeatBlocked("spender_a", guid, 6))
        refusal(fs.SPENDER_C, 5, 7, I.HitKind.MISS, guid)
        assert.is_nil(VS.DebuffRepeatBlocked("spender_a", guid, 8))
    end)

    it("builds verified NPC and protective-aura immunity from content metadata", function()
        local immuneNPC = "Creature-0-0-0-0-123456-000001"
        assert.are.equal("immune NPC", VS.DebuffImmunity("spender_c", immuneNPC, 5))
        assert.is_nil(VS.DebuffImmunity("spender_a", immuneNPC, 5))
        local guid = ctl.guid.target
        ctl.auras.target.HELPFUL[1] = { spellId = fs.SPENDER_A, expirationTime = 12 }
        ctl.now = 5
        ctl.Fire("UNIT_AURA", "target")
        VS.Drain(5.1)
        assert.are.equal("temporary immunity", VS.DebuffImmunity("spender_c", guid, 11.99))
        assert.is_nil(VS.DebuffImmunity("spender_c", guid, 12))
        assert.is_nil(VS.DebuffImmunity("spender_a", guid, 6))
    end)
end)
