local field = require("Forever.helpers.warlock_field")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("level fourteen Affliction dungeon pulls", function()
    local corruption, agony, immolate, bolt = 6222, 980, 707, 705
    local wand = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }

    local function selectPlate(H, index)
        local ctl, plate = H.ctl, "nameplate" .. index
        if ctl.unitIs.target then
            ctl.unitIs[ctl.unitIs.target] = nil
        end
        ctl.guid.target = ctl.guid[plate]
        ctl.unitIs.target, ctl.unitIs[plate] = plate, "target"
        H.Fire("PLAYER_TARGET_CHANGED")
        return field.pick(H)
    end

    local function pull(pack)
        local spells = { corruption, agony, immolate, bolt, 1120, 689, 1454, 5782, 5019 }
        local H = field.warlock("Affliction", 14, spells, {
            instanceType = "party",
            group = 5,
            partyAggro = true,
            classification = pack.classification or "elite",
            boss = pack.boss,
            range = pack.range,
            maxMana = 550,
            mana = 550,
            health = pack.health or (pack.mana and SECRET or 1000),
            weapon = pack.wand and wand,
            shootUsable = pack.wand,
            items = { [6265] = 2 },
            talents = { [17810] = 5 }, -- Five talent points at 14; Corruption is instant.
            beforeLoad = function(h)
                h.ctl.regen[0] = { 0, 0 }
            end,
        })
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = pack.swaps == true
        local ctl = H.ctl
        for i = 1, pack.count do
            local plate = "nameplate" .. i
            local victim = plate .. "target"
            ctl.exists[plate], ctl.exists[victim] = true, true
            ctl.guid[plate] = pack.hiddenGUID and SECRET or "Creature-0-0-0-0-598-00000" .. i
            ctl.distance[plate], ctl.unitCombat[plate] = pack.range or 15, true
            ctl.inParty[victim], ctl.unitIs[victim] = true, "party1"
            if i > 1 and pack.extra then
                pack.extra(ctl, plate)
            end
            H.Fire("NAME_PLATE_UNIT_ADDED", plate)
        end
        selectPlate(H, 1)
        field.cast(H, corruption)
        if not pack.partial then
            field.cast(H, agony)
            field.cast(H, immolate)
        end
        if pack.mana then
            ctl.power[0] = pack.mana
            H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
        end
        return H
    end

    local function first(H)
        local action = field.pick(H)
        local slot = H.Hekili.Engine.Output.Primary.recs[1]
        return action, slot and slot.indicator
    end

    it("spreads Corruption on a pair of normal mobs before optional damage on the selected target", function()
        local H = pull({ count = 2, classification = "normal", swaps = true, wand = true, partial = true })
        assert.are.same({ "corruption", "cycle" }, { first(H) })
    end)

    it("spreads Corruption across three engaged elites before Agony or Immolate", function()
        local H = pull({ count = 3, swaps = true, wand = true, partial = true })
        assert.are.same({ "corruption", "cycle" }, { first(H) })
    end)

    it("uses plate identity to spread with protected dungeon GUIDs", function()
        local H = pull({ count = 2, swaps = true, hiddenGUID = true, wand = true })
        assert.are.equal(1, H.ns.Facade.DebuffCount(corruption, H.ctl.now))
        assert.are.same({ "corruption", "cycle" }, { first(H) })
        assert.are.equal("corruption", selectPlate(H, 2))
        field.cast(H, corruption)
        assert.are.equal(2, H.ns.Facade.DebuffCount(corruption, H.ctl.now))
        local _, indicator = first(H)
        assert.are_not.equal("cycle", indicator, "both identified enemies already carry our Corruption")
    end)

    it("wands between applications on dotted dungeon trash when swaps are disabled", function()
        local H = pull({ count = 3, swaps = false, wand = true, mana = 124 })
        assert.are.equal("shoot", (first(H)))
        assert.are.equal("corruption", selectPlate(H, 2), "manual selection still shows the affordable DoT")
        assert.are_not.equal("cycle", H.Hekili.Engine.Output.Primary.recs[1].indicator)
    end)

    it("preserves a manual tab's Corruption ahead of optional DoTs with swaps disabled", function()
        local H = pull({ count = 2, partial = true, wand = true, swaps = false, mana = 60, health = 500, range = 25 })
        assert.are.equal("shoot", (first(H)), "paying 25 for Agony or 45 for Immolate leaves less than 55")
        assert.are.equal("corruption", selectPlate(H, 2))
        assert.are_not.equal("cycle", H.Hekili.Engine.Output.Primary.recs[1].indicator)
    end)

    it("reserves one Corruption before a no-wand Shadow Bolt with swaps disabled", function()
        local H = pull({ count = 2, swaps = false, mana = 124 })
        assert.are_not.equal("shadow_bolt", (first(H)), "124 mana cannot fund rank 3 Bolt and rank 2 Corruption")
        H.ctl.power[0] = 125
        H.Fire("UNIT_POWER_FREQUENT", "player", "MANA")
        local action, indicator = first(H)
        assert.are.equal("shadow_bolt", action, "125 mana covers both spells")
        assert.are_not.equal("cycle", indicator)
    end)

    it("does not suggest a swap onto a friendly, idle, or unidentified extra unit", function()
        for _, extra in ipairs({
            function(ctl, plate)
                ctl.friendly[plate] = true
            end,
            function(ctl, plate)
                ctl.unitCombat[plate] = false
            end,
            function(ctl, plate)
                ctl.isPlayer[plate] = SECRET
            end,
        }) do
            local H = pull({ count = 2, swaps = true, extra = extra })
            local _, indicator = first(H)
            assert.are_not.equal("cycle", indicator)
        end
    end)

    it("keeps a recognized training dummy on the sustained priority", function()
        local H = pull({ count = 2, swaps = true })
        H.ctl.guid.nameplate1 = "Creature-0-0-0-0-4952-000001" -- Theramore Combat Dummy
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        selectPlate(H, 1)
        assert.is_true(H.Hekili.State.target.is_dummy)
        assert.is_true(H.Hekili.State.warlock_sustained)
        assert.is_false(H.Hekili.State.warlock_dungeon_trash)
    end)

    it("holds damage on a feared dungeon mob and holds the swap while Fear is still remembered", function()
        local H = pull({ count = 2, swaps = true, partial = true })
        selectPlate(H, 2)
        field.cast(H, 5782)
        -- Forever's Fear aura has a different ID from the cast, which can be resisted.
        local auras = H.ctl.auras.target.HARMFUL
        local expires = H.ctl.now + 10
        auras[1] = { spellId = 1324448, expirationTime = expires, applications = 1, sourceUnit = "player" }
        H.Fire("UNIT_AURA", "target")
        local action = field.pick(H)
        local damage = {
            corruption = true,
            bane_of_agony = true,
            immolate = true,
            shadow_bolt = true,
            drain_life = true,
            drain_soul = true,
            shoot = true,
            auto_attack = true,
        }
        if damage[action] then
            local slot = H.Hekili.Engine.Output.Primary.recs[1]
            assert.is_true(slot.time >= expires - H.ctl.now - 0.05, action .. " would break our observed Fear")
        end
        auras[1] = nil
        selectPlate(H, 1)
        assert.are.equal(1, H.ns.Facade.DebuffCount(1324448, H.ctl.now))
        local _, indicator = first(H)
        assert.are_not.equal("cycle", indicator)
        field.pick(H, expires - H.ctl.now + 0.1)
        field.cast(H, corruption)
        assert.are.same({ "corruption", "cycle" }, { first(H) })
    end)

    it("keeps Shadow Bolt on a dotted single dungeon boss with an equipped wand", function()
        local H = pull({ count = 1, classification = "worldboss", boss = true, swaps = true, wand = true })
        assert.are.equal("shadow_bolt", (first(H)))
    end)
end)
