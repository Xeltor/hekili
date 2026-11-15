-- Scripted client observations across a pull, rather than independent first-icon snapshots. These exercise the
-- shipped field priorities and their event transitions; the separate pinned replays retain the raid baseline.
local fixture = require("Forever.helpers.rogue_pve")
local rogue, pick, headless, SECRET = fixture.rogue, fixture.pick, fixture.headless, fixture.SECRET

local function refresh(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 0.2)))
    assert.are.same({}, H.errors)
end

local function resources(H, points, energy)
    H.ctl.power[4], H.ctl.comboPoints.target = points, points
    H.ctl.power[3] = energy
    H.Fire("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS")
    H.Fire("UNIT_POWER_FREQUENT", "player", "ENERGY")
end

local function cast(H, rec, points, energy)
    local guid = "Cast-" .. rec.actionName .. "-" .. H.ctl.now
    H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", guid, rec.actionID)
    H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, rec.actionID)
    resources(H, points, energy)
    refresh(H, 1.1)
end

local function engage(H)
    H.ctl.combat, H.ctl.unitCombat.target = true, true
    H.ctl.exists.targettarget, H.ctl.unitIs.targettarget = true, "player"
    H.Fire("PLAYER_REGEN_DISABLED")
    H.Fire("PLAYER_TARGET_CHANGED")
end

local function equip(H, slot, item)
    H.ctl.inventory[slot] = item
    H.Fire("PLAYER_EQUIPMENT_CHANGED", slot, item ~= nil)
    refresh(H)
    H.ctl.now = H.ctl.now + 1.1
    H.RunTimers(H.ctl.now)
    refresh(H)
end

describe("Rogue field pull sequences", function()
    it("opens in Stealth, builds and finishes, and respects target-bound points through a swap", function()
        local H = rogue("Combat", 20, {
            prepull = true,
            daggers = true,
            talents = { [13732] = 2 },
            settings = { behind = true },
        })
        local rec = pick(H)
        assert.are.equal("stealth", rec.actionName)
        H.ctl.stealthed = true
        H.Fire("UPDATE_STEALTH")
        cast(H, rec, 0, 100)
        rec = pick(H)
        assert.are.equal("ambush", rec.actionName)
        H.ctl.stealthed = false
        H.Fire("UPDATE_STEALTH")
        engage(H)
        cast(H, rec, 1, 40)

        for points = 2, 5 do
            -- The player stays on this mob and allows Energy to recover between builders. Resource amounts are
            -- client observations; no simulated handler is invoked by the test.
            resources(H, points - 1, 100)
            refresh(H, 6)
            rec = pick(H)
            assert.are.equal("sinister_strike", rec.actionName, "builder to " .. points)
            cast(H, rec, points, 60)
        end
        rec = pick(H)
        assert.are.equal("eviscerate", rec.actionName)
        local first = H.ctl.guid.target
        H.ctl.guid.target, H.ctl.comboPoints.target = "Creature-second", 0
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("sinister_strike", pick(H).actionName)
        H.ctl.guid.target, H.ctl.comboPoints.target = first, 5
        H.Fire("PLAYER_TARGET_CHANGED")
        rec = pick(H)
        assert.are.equal("eviscerate", rec.actionName)
        cast(H, rec, 0, 65)
        assert.are.equal("sinister_strike", pick(H).actionName)

        -- A hidden answer on the next target cannot reuse the old target's apparent five-point pool.
        H.ctl.guid.target, H.ctl.power[4], H.ctl.comboPoints.target = "Creature-third", 5, SECRET
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("sinister_strike", pick(H).actionName)
    end)

    it("uses Ghostly Strike's observed follow-up window, then returns to its learned builder", function()
        local H = rogue("Subtlety", 30, {
            instance = "party",
            group = 5,
            threat = 0,
            kind = "elite",
            spells = { 14278, 16511 },
            talents = { [14278] = 1, [16511] = 1, [14082] = 2 },
        })
        local rec = pick(H)
        assert.are.equal("ghostly_strike", rec.actionName)
        H.ctl.cooldown[14278] = {
            isActive = true,
            isOnGCD = false,
            startTime = H.ctl.now,
            duration = 20,
        }
        cast(H, rec, 1, 75)
        rec = pick(H)
        assert.are.equal("garrote", rec.actionName)
        cast(H, rec, 2, 45)
        -- The target's bleed is now confirmed and the consumed follow-up must not reappear.
        H.ctl.auras.target.HARMFUL[1] = { spellId = 703, expirationTime = H.ctl.now + 18, applications = 0 }
        H.Fire("UNIT_AURA", "target")
        resources(H, 2, 100)
        H.ctl.auras.player.HELPFUL[1] = { spellId = 5171, expirationTime = H.ctl.now + 20, applications = 0 }
        H.Fire("UNIT_AURA", "player")
        assert.are.equal("hemorrhage", pick(H).actionName)
    end)

    it("reserves Energy for a channel and resumes damage when the channel ends early", function()
        local H = rogue("Combat", 20, { instance = "party", group = 5, threat = 0, energy = 10, cast = true })
        local rec = pick(H)
        -- Steady icons retain an existing countdown for one publication when another countdown replaces it.
        -- That old builder must remain in the future; the next update exposes the reserved interrupt.
        assert.are.equal("sinister_strike", rec.actionName)
        assert.is_true(rec.time > 2)
        resources(H, 0, 12) -- 0.2 s of Energy regeneration; a constant plain 10 would erase that progress
        rec = pick(H)
        assert.are.equal("kick", rec.actionName)
        assert.is_true(rec.time > 0)
        -- Forever hides Energy; the already-seeded belief must remain usable through the cast-stop event.
        H.ctl.power[3] = SECRET
        H.Fire("UNIT_POWER_FREQUENT", "player", "ENERGY")
        H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "target", SECRET, SECRET, nil, 77)
        pick(H) -- the one-publication countdown hold also applies when the stopped interrupt is replaced
        rec = pick(H)
        assert.are.equal("sinister_strike", rec.actionName)
        assert.is_true(rec.time >= 0 and rec.time < math.huge)
        H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 78)
        resources(H, 0, 30)
        rec = pick(H)
        assert.are.equal("kick", rec.actionName)
        assert.are.equal(0, rec.time)
    end)

    it("falls back after losing a dagger in combat and restores Mutilate after equipping it", function()
        local H = rogue("Assassination", 40, {
            daggers = true,
            spells = { 1310707 },
            talents = { [1310707] = 1 },
        })
        assert.are.equal("mutilate", pick(H).actionName)
        local offhand = H.ctl.inventory[17]
        equip(H, 17)
        assert.are.equal("sinister_strike", pick(H).actionName)
        equip(H, 17, offhand)
        local rec = pick(H)
        assert.are.equal("mutilate", rec.actionName)
        cast(H, rec, 2, 40)
        resources(H, 2, 100)
        refresh(H, 6)
        rec = pick(H)
        assert.are.equal("mutilate", rec.actionName)
        cast(H, rec, 4, 40)
        assert.are.equal("eviscerate", pick(H).actionName)
    end)
end)
