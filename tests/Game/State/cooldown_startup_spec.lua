local load = require("Game.State.helpers.load")
local fake = require("Game.State.helpers.fake_api")
local fs = require("Game.State.helpers.fake_spec")

describe("cooldown flags at startup", function()
    local ITEM, USE_SPELL = 272438, 1291101

    local function drain(I, now)
        I.Sources.Flush()
        I.Sources.RunPolls(now)
        I.Fold(now)
        I.Settle(now)
    end

    local function setup(startFirst)
        local api, ctl = fake.new()
        local ns = load.module()
        local VS, I = ns.VirtualState, ns.VirtualStateInternal
        local h = fs.new(9)
        h.Class.abilities.spender_c.cooldown = 60
        ctl.now = 10
        ctl.known[fs.SPENDER_C_R2] = true
        ctl.cooldown[fs.SPENDER_C_R2] = {
            isActive = true,
            isOnGCD = false,
            startTime = fake.SECRET,
            duration = fake.SECRET,
        }
        if startFirst then
            VS.Start(api)
            I.Build(fs.def(h), ctl.now)
        else
            I.Build(fs.def(h), ctl.now)
            VS.Start(api)
        end
        return VS, I, api, ctl, h
    end

    it("seeds the highest known rank without a cooldown event in either initialization order", function()
        for _, startFirst in ipairs({ false, true }) do
            local VS, I, _, ctl = setup(startFirst)
            drain(I, ctl.now)
            local a = I.ab.bySpell[fs.SPENDER_C]
            assert.are.equal(fs.SPENDER_C_R2, I.ab.qid[a])
            assert.are.equal(ctl.now + I.CD_PROBE, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
            assert.is_true(VS.Cooldown(fs.SPENDER_A, ctl.now).est <= ctl.now)

            ctl.cooldown[fs.SPENDER_C_R2].isActive = false
            ctl.now = 11
            ctl.Fire("SPELL_UPDATE_COOLDOWN")
            drain(I, ctl.now)
            assert.is_true(VS.Cooldown(fs.SPENDER_C, ctl.now).est <= ctl.now)
        end
    end)

    it("seeds cooldowns again after a tracked-set rebuild", function()
        local VS, I, _, ctl, h = setup(false)
        drain(I, ctl.now)
        ctl.now = 12
        I.Build(fs.def(h), ctl.now)
        drain(I, ctl.now)
        assert.are.equal(ctl.now + I.CD_PROBE, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
    end)

    it("seeds an item's cooldown from the item API even while its use spell reads active", function()
        local api, ctl = fake.new()
        local ns = load.module()
        local VS, I = ns.VirtualState, ns.VirtualStateInternal
        local def = fs.def(fs.new(9))
        def.abilities[#def.abilities + 1] =
            { key = "trinket", id = USE_SPELL, item = ITEM, cooldown = 360, gcd = "off" }
        def.abilityIds[#def.abilityIds + 1] = { USE_SPELL }
        def.abilitySlot[#def.abilitySlot + 1] = 0
        ctl.now = 10
        ctl.cooldown[USE_SPELL] = { isActive = true, isOnGCD = false }
        ctl.itemCooldown[ITEM] = { 8, 5 }
        VS.Start(api)
        I.Build(def, ctl.now)
        drain(I, ctl.now)
        assert.are.equal(13, VS.ItemCooldown(ITEM, ctl.now).est)

        ctl.now, ctl.itemCooldown[ITEM] = 13, { 0, 0 }
        ctl.Fire("SPELL_UPDATE_COOLDOWN")
        drain(I, ctl.now)
        assert.is_true(VS.ItemCooldown(ITEM, ctl.now).est <= ctl.now)
        ctl.now, ctl.itemCooldown[ITEM] = 14, { fake.SECRET, fake.SECRET }
        ctl.Fire("SPELL_UPDATE_COOLDOWN")
        drain(I, ctl.now)
        assert.is_true(VS.ItemCooldown(ITEM, ctl.now).est <= ctl.now)
    end)

    it("does not erase a cast before the first drain with initial idle flags", function()
        local VS, I, _, ctl = setup(false)
        ctl.cooldown[fs.SPENDER_C_R2].isActive = false -- the initial answer has not caught up with our cast
        ctl.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-startup", fs.SPENDER_C_R2)
        ctl.now = 10.1
        drain(I, ctl.now)
        assert.are.equal(70, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
        assert.are.equal("modelled", VS.Cooldown(fs.SPENDER_C, ctl.now).basis)
        assert.are.equal(11.5, VS.Gcd(ctl.now).est)
        assert.are.equal("modelled", VS.Gcd(ctl.now).basis)
    end)

    it("retries unreadable startup flags without continuously polling resolved spells", function()
        local VS, I, api, ctl = setup(false)
        local getCooldown, reads, available = api.C_Spell.GetSpellCooldown, 0, false
        api.C_Spell.GetSpellCooldown = function(id)
            if id == fs.SPENDER_C_R2 then
                reads = reads + 1
                if not available then
                    return { isActive = fake.SECRET, isOnGCD = fake.SECRET }
                end
            end
            return getCooldown(id)
        end
        drain(I, ctl.now)
        assert.are.equal(-1, I.ab.flag[I.ab.bySpell[fs.SPENDER_C]])
        assert.are.equal(1, reads)
        ctl.now = 10.1
        drain(I, ctl.now)
        assert.are.equal(1, reads)
        available, ctl.now = true, 10.6
        drain(I, ctl.now)
        assert.are.equal(ctl.now + I.CD_PROBE, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
        assert.are.equal(2, reads)
        ctl.now = 11.2
        drain(I, ctl.now)
        assert.are.equal(2, reads)
    end)

    it("treats a GCD-only lock as ready and resamples a newly learned rank", function()
        local VS, I, _, ctl = setup(false)
        ctl.known[fs.SPENDER_C_R2] = false
        ctl.cooldown[fs.SPENDER_C] = { isActive = true, isOnGCD = true }
        ctl.Fire("SPELLS_CHANGED")
        drain(I, ctl.now)
        assert.is_true(VS.Cooldown(fs.SPENDER_C, ctl.now).est <= ctl.now)
        ctl.known[fs.SPENDER_C_R2], ctl.now = true, 11
        ctl.Fire("SPELLS_CHANGED")
        drain(I, ctl.now)
        assert.are.equal(ctl.now + I.CD_PROBE, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
    end)

    it("retries a cooldown edge dropped by a full event stage", function()
        local VS, I, _, ctl = setup(false)
        ctl.cooldown[fs.SPENDER_C_R2].isActive = false
        drain(I, ctl.now)
        local S = I.Sources
        for _ = 1, S.STAGE do
            assert.is_true(S.Stage(VS.Obs.Cooldown, ctl.now, I.ab.bySpell[fs.SPENDER_A], 1, 0))
        end
        ctl.cooldown[fs.SPENDER_C_R2].isActive, ctl.now = true, 11
        ctl.Fire("SPELL_UPDATE_COOLDOWN")
        drain(I, ctl.now)
        assert.are.equal(ctl.now + I.CD_PROBE, VS.Cooldown(fs.SPENDER_C, ctl.now).est)
    end)

    it("still clears known cooldowns when their ready edges overflow the event stage", function()
        local VS, I, _, ctl = setup(false)
        ctl.cooldown[I.GCD_SPELL] = { isActive = true, isOnGCD = false }
        drain(I, ctl.now)
        assert.is_true(VS.Gcd(ctl.now).est > ctl.now)
        local S = I.Sources
        for _ = 1, S.STAGE do
            assert.is_true(S.Stage(VS.Obs.Cooldown, ctl.now, I.ab.bySpell[fs.SPENDER_A], 1, 0))
        end
        ctl.cooldown[fs.SPENDER_C_R2].isActive = false
        ctl.cooldown[I.GCD_SPELL].isActive = false
        ctl.now = 10.3
        ctl.Fire("SPELL_UPDATE_COOLDOWN")
        drain(I, ctl.now)
        assert.is_true(VS.Cooldown(fs.SPENDER_C, ctl.now).est <= ctl.now)
        assert.is_true(VS.Gcd(ctl.now).est <= ctl.now)
    end)

    it("recovers a dropped ready edge before the preceding not-ready edge has folded", function()
        local VS, I, _, ctl = setup(false)
        ctl.Fire("SPELL_UPDATE_COOLDOWN") -- not ready is staged, the belief is still unknown
        local S = I.Sources
        while S.stN < S.STAGE do
            assert.is_true(S.Stage(VS.Obs.Cooldown, ctl.now, I.ab.bySpell[fs.SPENDER_A], 1, 0))
        end
        ctl.cooldown[fs.SPENDER_C_R2].isActive = false
        ctl.Fire("SPELL_UPDATE_COOLDOWN")
        drain(I, ctl.now)
        assert.are.equal(1, I.ab.flag[I.ab.bySpell[fs.SPENDER_C]])
        assert.is_true(VS.Cooldown(fs.SPENDER_C, ctl.now).est <= ctl.now)
    end)
end)
