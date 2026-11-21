local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("Forever Warlock observed cast pushback", function()
    local function warlock(options)
        options = options or {}
        options.range = options.range or 3
        local H = field.warlock("SMRuin", 60, { 686, 11661, 17923, 1293813, 689 }, options)
        H.Hekili.State.reset("Primary", true)
        return H
    end

    local function start(H, spellID, guid)
        H.ctl.casting = { H.ctl.now * 1000, H.ctl.now * 1000 + 3000 }
        H.Fire("UNIT_SPELLCAST_START", "player", guid or "Cast-A", spellID or 11661)
    end

    local function delayed(H, extraMS, spellID, guid, unit)
        H.ctl.casting[2] = H.ctl.now * 1000 + 3000 + extraMS
        H.Fire("UNIT_SPELLCAST_DELAYED", unit or "player", guid or "Cast-A", spellID or 11661)
    end

    it("compares each delayed Shadow Bolt end with its original end and expires the evidence", function()
        local H = warlock()
        local st = H.Hekili.State
        start(H)
        assert.is_false(st.warlock_recent_cast_pushback)
        delayed(H, 500)
        assert.is_true(st.warlock_recent_cast_pushback)
        assert.are.equal(0.5, st.warlock_recent_bolt_pushback)
        delayed(H, 1250)
        assert.are.equal(1.25, st.warlock_recent_bolt_pushback)
        H.Fire("UNIT_SPELLCAST_STOP", "player", "Cast-A", 11661)
        delayed(H, 2000)
        assert.are.equal(1.25, st.warlock_recent_bolt_pushback)
        st.offset = 5
        assert.is_false(st.warlock_recent_cast_pushback)
        assert.are.equal(0, st.warlock_recent_bolt_pushback)
        assert.are.same({}, H.errors)
    end)

    it("requires a matching player filler cast and retains only measured Shadow Bolt delay", function()
        local H = warlock()
        local st = H.Hekili.State
        start(H)
        delayed(H, 500, 11661, "Cast-B")
        delayed(H, 500, 17923)
        delayed(H, 500, 11661, "Cast-A", "target")
        H.Fire("UNIT_SPELLCAST_DELAYED", "player", SECRET, 11661)
        H.Fire("UNIT_SPELLCAST_DELAYED", "player", "Cast-A", SECRET)
        delayed(H, 0)
        assert.is_false(st.warlock_recent_cast_pushback)
        for _, spellID in ipairs({ 17923, 1293813 }) do
            start(H, spellID)
            delayed(H, 500, spellID)
            assert.is_true(st.warlock_recent_cast_pushback)
            assert.are.equal(0, st.warlock_recent_bolt_pushback)
        end
        H.Fire("PLAYER_TARGET_CHANGED")
        start(H, 689)
        H.Fire("UNIT_SPELLCAST_CHANNEL_UPDATE", "player", "Cast-A", 689)
        delayed(H, 500, 689)
        assert.is_false(st.warlock_recent_cast_pushback)
        start(H, 686)
        H.ctl.casting[2] = SECRET
        H.Fire("UNIT_SPELLCAST_DELAYED", "player", "Cast-A", 686)
        assert.is_true(st.warlock_recent_cast_pushback)
        assert.are.equal(0, st.warlock_recent_bolt_pushback)
        assert.are.same({}, H.errors)
    end)

    it("checks melee range and the current victim both when the cast is delayed and when queried", function()
        local H = warlock()
        local ctl, st = H.ctl, H.Hekili.State
        start(H)
        ctl.unitIs.targettarget = "pet"
        delayed(H, 500)
        ctl.unitIs.targettarget = "player"
        assert.is_false(st.warlock_recent_cast_pushback)
        delayed(H, 750)
        assert.is_true(st.warlock_recent_cast_pushback)
        for _, victim in ipairs({ "pet", "party1", SECRET }) do
            ctl.unitIs.targettarget = victim
            assert.is_false(st.warlock_recent_cast_pushback)
        end
        ctl.unitIs.targettarget = "player"
        ctl.distance.target = SECRET
        assert.is_false(st.warlock_recent_cast_pushback)
        ctl.distance.target = 15
        assert.is_false(st.warlock_recent_cast_pushback)
        ctl.distance.target, ctl.guid.target = 3, SECRET
        assert.is_false(st.warlock_recent_cast_pushback)
        assert.are.same({}, H.errors)
    end)

    it("discards evidence on a new target, combat boundary or world change", function()
        local H = warlock()
        local st = H.Hekili.State
        for _, event in ipairs({
            "PLAYER_TARGET_CHANGED",
            "PLAYER_REGEN_ENABLED",
            "PLAYER_REGEN_DISABLED",
            "PLAYER_ENTERING_WORLD",
        }) do
            start(H)
            delayed(H, 500)
            assert.is_true(st.warlock_recent_cast_pushback)
            H.Fire(event)
            assert.is_false(st.warlock_recent_cast_pushback)
            delayed(H, 750)
            assert.is_false(st.warlock_recent_cast_pushback)
        end
        assert.are.same({}, H.errors)
    end)

    it("excludes dungeons, raid bosses, player opponents and elite outdoor targets", function()
        for _, options in ipairs({
            { instanceType = "party", group = 5 },
            { instanceType = "raid", group = 10, boss = true },
            { playerTarget = true },
            { classification = "elite" },
        }) do
            local H = warlock(options)
            start(H)
            delayed(H, 500)
            assert.is_false(H.Hekili.State.warlock_recent_cast_pushback)
            assert.are.equal(0, H.Hekili.State.warlock_recent_bolt_pushback)
            assert.are.same({}, H.errors)
        end
    end)
end)
