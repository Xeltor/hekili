local fixture = require("Forever.helpers.rogue_pve")
local rogue, pick = fixture.rogue, fixture.pick

describe("Rogue PvE priorities", function()
    for _, spec in ipairs({ "Assassination", "Combat", "Subtlety" }) do
        it(spec .. " uses a learned builder at every level from 1 to 60", function()
            for level = 1, 60 do
                local H = rogue(spec, level)
                local rec = pick(H)
                assert.are.equal("sinister_strike", rec.actionName, "level " .. level)
                assert.is_true(H.ctl.known[rec.actionID] == true, tostring(rec.actionID))
            end
        end)
    end

    it("uses the learned Mutilate rank with two daggers and falls back after a weapon swap", function()
        local o = { daggers = true, spells = { 1310707 }, talents = { [1310707] = 1 } }
        assert.are.equal("mutilate", pick(rogue("Assassination", 40, o)).actionName)
        o.singleWeapon = true
        assert.are.equal("sinister_strike", pick(rogue("Assassination", 40, o)).actionName)
    end)

    it("uses a quick finisher outdoors in solo and party play, and Slice and Dice on an elite", function()
        assert.are.equal("eviscerate", pick(rogue("Combat", 20, { points = 5 })).actionName)
        assert.are.equal("eviscerate", pick(rogue("Combat", 60, { points = 5, group = 5, threat = 0 })).actionName)
        assert.are.equal("slice_and_dice", pick(rogue("Combat", 20, { points = 5, kind = "elite" })).actionName)
    end)

    it("cleaves only when a second target is in range and multi-target mode is allowed", function()
        local o = { spells = { 13877 }, talents = { [13877] = 1 }, instance = "party", group = 5, threat = 0, add = 4 }
        local H = rogue("Combat", 30, o)
        H.Hekili:FireToggle("cooldowns", "on")
        assert.are.equal("blade_flurry", pick(H).actionName)
        H.Hekili:FireToggle("mode", "single")
        assert.is_not_equal("blade_flurry", pick(H).actionName)
        o.add = 12
        H = rogue("Combat", 30, o)
        H.Hekili:FireToggle("cooldowns", "on")
        assert.is_not_equal("blade_flurry", pick(H).actionName)
    end)

    it("uses Shank for Energy with a usable off hand and room in the pool", function()
        local o = { energy = 65 }
        assert.are.equal("shank", pick(rogue("Assassination", 24, o)).actionName)
        o.singleWeapon = true
        assert.are.equal("sinister_strike", pick(rogue("Assassination", 24, o)).actionName)
        o.singleWeapon, o.energy = false, 100
        assert.are.equal("sinister_strike", pick(rogue("Assassination", 24, o)).actionName)
    end)

    it("uses Hemorrhage on short pulls and Rupture on durable dungeon targets", function()
        local o = { spells = { 16511 }, talents = { [16511] = 1 } }
        assert.are.equal("hemorrhage", pick(rogue("Subtlety", 30, o)).actionName)
        o.points, o.kind, o.instance, o.group, o.threat = 5, "elite", "party", 0, 0
        assert.are.equal("rupture", pick(rogue("Subtlety", 30, o)).actionName)
    end)

    it("uses learned Death Mark on durable targets when Rupture is unavailable", function()
        local o = { spells = { 1316709 }, talents = { [1316709] = 1 }, points = 5, kind = "elite" }
        assert.are.equal("death_mark", pick(rogue("Subtlety", 40, o)).actionName)
        o.kind, o.snd = "normal", true
        assert.are.equal("eviscerate", pick(rogue("Subtlety", 40, o)).actionName)
    end)

    it("uses the dagger builder with a different aggro target and falls back when facing the enemy", function()
        local o = { daggers = true, group = 5, threat = 0 }
        assert.are.equal("backstab", pick(rogue("Assassination", 10, o)).actionName)
        o.group, o.threat = nil, nil
        assert.are.equal("sinister_strike", pick(rogue("Assassination", 10, o)).actionName)
    end)

    it("prioritizes Stealth and Cheap Shot for an outdoor opener and leaves idle dungeon pulls alone", function()
        assert.are.equal("stealth", pick(rogue("Combat", 26, { prepull = true })).actionName)
        assert.are.equal("cheap_shot", pick(rogue("Combat", 26, { prepull = true, stealthed = true })).actionName)
        assert.are.equal(nil, pick(rogue("Combat", 26, { prepull = true, instance = "party", group = 5 })).actionName)
    end)

    it("offers a finisher at full points in Stealth and prompts Attack after Stealth ends", function()
        for _, spec in ipairs({ "Assassination", "Combat", "Subtlety" }) do
            local o = { prepull = true, stealthed = true, attack = false, spells = { 6603 }, points = 5 }
            local H = rogue(spec, 20, o)
            assert.are.equal("eviscerate", pick(H).actionName, spec)
            H.ctl.stealthed = false
            H.Fire("UPDATE_STEALTH")
            assert.are.equal("auto_attack", pick(H).actionName, spec)
            H.ctl.current[6603] = true
            assert.are.equal("eviscerate", pick(H).actionName, spec)
        end
    end)

    it("uses Ambush with a dagger when another player has aggro and a regular strike from the front", function()
        local o = { instance = "party", group = 5, threat = 0, stealthed = true, daggers = true }
        assert.are.equal("ambush", pick(rogue("Combat", 20, o)).actionName)
        local H = rogue("Combat", 20, o)
        H.ctl.unitIs.targettarget = "player"
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("sinister_strike", pick(H).actionName)
    end)

    it("offers a strike through a cast while stealthed and a legal Garrote on a planned raid pull", function()
        local o = { instance = "party", group = 5, threat = 0, stealthed = true, cast = true }
        assert.are.equal("sinister_strike", pick(rogue("Combat", 20, o)).actionName)
        o.instance, o.boss, o.prepull = "raid", true, true
        assert.are.equal("garrote", pick(rogue("Combat", 60, o)).actionName)
    end)

    it("prompts Attack only with an eligible target and the current spell explicitly off", function()
        local o = { spells = { 6603 }, attack = false, prepull = true }
        local H = rogue("Combat", 1, o)
        assert.are.equal("auto_attack", pick(H).actionName)
        local out = H.Hekili.Engine.Output.Primary
        for i = 2, out.count do
            assert.is_not_equal("auto_attack", out.recs[i].actionName)
        end
        o.secretAttack = true
        assert.are.equal("sinister_strike", pick(rogue("Combat", 1, o)).actionName)
        o.secretAttack, o.distance = false, 10
        assert.is_not_equal("auto_attack", pick(rogue("Combat", 1, o)).actionName)
    end)

    it("prompts Attack at zero Energy on an engaged dungeon enemy and holds it on an idle one", function()
        local o = { instance = "party", group = 5, threat = 0, attack = false, energy = 0, spells = { 6603 } }
        local H = rogue("Combat", 20, o)
        local attack = pick(H)
        assert.are.equal("auto_attack", attack.actionName)
        assert.are.equal(0, attack.time)
        o.threat, o.idleTarget = nil, true
        assert.is_nil(pick(rogue("Combat", 20, o)).actionName)
    end)

    it("kicks a channel, uses Kidney Shot when Kick is cooling, and skips the stun on a boss", function()
        local o = { instance = "party", group = 5, threat = 0, points = 3, cast = true }
        assert.are.equal("kick", pick(rogue("Combat", 30, o)).actionName)
        o.noKick = true
        assert.are.equal("kidney_shot", pick(rogue("Combat", 30, o)).actionName)
        o.boss = true
        assert.is_not_equal("kidney_shot", pick(rogue("Combat", 30, o)).actionName)
        o.noKick, o.boss, o.uninterruptible = false, false, true
        local H = rogue("Combat", 30, o)
        assert.are.equal("kidney_shot", pick(H).actionName)
        H.Hekili:FireToggle("interrupts", "off")
        assert.are.equal("sinister_strike", pick(H).actionName)
    end)

    it("offers Evasion when taking melee pressure and a potion at low health", function()
        assert.are.equal("evasion", pick(rogue("Combat", 8, { defensives = true })).actionName)
        assert.are.equal(
            "healing_potion",
            pick(rogue("Combat", 8, { defensives = true, health = 300, potion = true })).actionName
        )
        assert.are.equal(
            "sinister_strike",
            pick(rogue("Combat", 8, { defensives = true, group = 5, threat = 0 })).actionName
        )
    end)

    it("offers poison for an empty equipped hand before combat and skips it in combat", function()
        local o = { prepull = true, poison = true }
        local H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("potions", "on")
        local main = pick(H)
        assert.are.equal("instant_poison", main.actionName)
        assert.are.equal("Main Hand", main.label)
        assert.are.equal(6947, H.Hekili.Class.abilities.instant_poison.item)
        o.mainPoison = true
        H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("potions", "on")
        assert.are.equal("Off Hand", pick(H).label)
        o.kind, o.deadly = "elite", true
        H = rogue("Combat", 30, o)
        H.Hekili:FireToggle("potions", "on")
        assert.are.equal("deadly_poison", pick(H).actionName)
        o.singleWeapon = true
        H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("potions", "on")
        assert.is_not_equal("instant_poison", pick(H).actionName)
        o.prepull, o.mainPoison, o.singleWeapon = false, false, false
        H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("potions", "on")
        assert.is_not_equal("instant_poison", pick(H).actionName)
    end)
end)
