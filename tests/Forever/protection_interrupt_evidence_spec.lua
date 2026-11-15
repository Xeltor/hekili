local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warrior, read, cast = fixture.warrior, fixture.read, fixture.cast

local CASTER = "Creature-0-0-0-0-346-000001"
local SAME_TYPE = "Creature-0-0-0-0-346-000002"
local OTHER_TYPE = "Creature-0-0-0-0-347-000003"

local function boot()
    return warrior(18, 15, { target = CASTER, demo = true })
end

local function reserve(H)
    read(H, 0.2)
    H.Hekili.State.reset("Primary")
    return H.Hekili.State.prot_bash_reserve
end

local function stop(H, channel, bar)
    if channel then
        H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "target", SECRET, SECRET, SECRET, bar or 77)
    else
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, bar or 77)
    end
end

local function target(H, guid)
    H.ctl.guid.target = guid
    H.Fire("PLAYER_TARGET_CHANGED")
end

describe("Protection interrupt evidence", function()
    it("does not remember unknown or explicitly uninterruptible casts and channels", function()
        for _, channel in ipairs({ false, true }) do
            for _, explicit in ipairs({ false, true }) do
                local H = boot()
                H.Fire(
                    channel and "UNIT_SPELLCAST_CHANNEL_START" or "UNIT_SPELLCAST_START",
                    "target",
                    SECRET,
                    SECRET,
                    77
                )
                if explicit then
                    H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
                end
                read(H, 0.2)
                stop(H, channel)
                assert.are.equal(0, reserve(H))
                target(H, SAME_TYPE)
                assert.are.equal(0, reserve(H))
            end
        end
    end)

    it("remembers a positively interruptible cast and retains mixed-caster evidence", function()
        for _, channel in ipairs({ false, true }) do
            local H = boot()
            cast(H, true, channel)
            stop(H, channel)
            assert.are.equal(10, reserve(H))
            cast(H, false, channel)
            stop(H, channel)
            assert.are.equal(10, reserve(H))
            target(H, SAME_TYPE)
            assert.are.equal(10, reserve(H))
            target(H, OTHER_TYPE)
            assert.are.equal(0, reserve(H))
        end
    end)

    it("requires an active cast belonging to the current readable target", function()
        local H = boot()
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        assert.are.equal(0, reserve(H))
        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
        target(H, OTHER_TYPE)
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        stop(H)
        assert.are.equal(0, reserve(H))
        target(H, CASTER)
        assert.are.equal(0, reserve(H))

        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
        H.ctl.guid.target = OTHER_TYPE -- even before the target-change event arrives
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        stop(H)
        assert.are.equal(0, reserve(H))
        target(H, CASTER)
        assert.are.equal(0, reserve(H))

        target(H, SECRET)
        cast(H, true)
        stop(H)
        target(H, CASTER)
        assert.are.equal(0, reserve(H))
    end)

    it("clears pending casts on world entry and ignores interruptibility after a cast ends", function()
        local H = boot()
        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
        H.Fire("PLAYER_ENTERING_WORLD", false, true)
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        stop(H)
        assert.are.equal(0, reserve(H))
        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
        stop(H)
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        assert.are.equal(0, reserve(H))
        assert.are.equal(0, reserve(boot())) -- session memory is not persisted across a fresh load
    end)

    it("does not let a delayed stop for an older cast erase the current cast", function()
        local H = boot()
        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 76)
        H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
        stop(H, false, 76)
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        stop(H)
        assert.are.equal(10, reserve(H))
    end)

    it("does not learn a caster type from friendly, dead or player targets", function()
        for _, field in ipairs({ "friendly", "dead", "isPlayer" }) do
            local H = boot()
            H.ctl[field].target = true
            cast(H, true)
            stop(H)
            H.ctl[field].target = false
            target(H, SAME_TYPE)
            assert.are.equal(0, reserve(H), field)
        end
    end)

    it("keeps Concussion Blow immunity temporary without imposing a stun-spacing policy", function()
        local H = warrior(30, 25, { target = CASTER, talents = { [12809] = 1 } })
        local aura = H.Hekili.Class.auras.concussion_blow
        assert.are.equal(30, aura.debuffRetryDelay)
        assert.is_nil(aura.debuffRepeatGroup)
        cast(H, false)
        assert.are.equal("concussion_blow", read(H, 0.2))

        local I = H.ns.VirtualStateInternal
        local at = H.ctl.now
        I.DebuffRefused(I.ab.bySpell[12809], CASTER, I.HitKind.IMMUNE, at)
        local immunity = H.Hekili.Client.DebuffImmunity
        assert.are.equal("temporary immunity", immunity("concussion_blow", CASTER, at + 29.99))
        assert.is_not_equal("concussion_blow", read(H, 0.2))
        assert.is_nil(immunity("concussion_blow", CASTER, at + 30))
        assert.is_nil(immunity("concussion_blow", OTHER_TYPE, at + 1))
    end)
end)
