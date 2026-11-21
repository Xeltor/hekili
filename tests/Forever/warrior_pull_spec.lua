local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warrior, read, cast = fixture.warrior, fixture.read, fixture.cast

for _, spec in ipairs({ "Arms", "Fury", "Protection" }) do
    local pack = spec .. " (wowsims.com)"
    local function boot(level, rage, options)
        options.pack = pack
        local H = warrior(level, rage, options)
        H.ns.Output.steady = false
        return H
    end

    describe(pack .. " pull and interrupt decisions", function()
        if spec == "Fury" then
            it("counts only elapsed combat on the engaged enemy when weighing armor reduction", function()
                local H = boot(24, 35, { form = 1, classification = "normal" })
                local st = H.Hekili.State
                local function sustained(seconds)
                    read(H, seconds)
                    st.reset("Primary", true)
                    return st.warrior_sustained_target
                end
                assert.is_false(sustained(0.2))
                st.advance(15)
                assert.is_false(st.warrior_sustained_target)
                assert.is_true(sustained(12.1))
                H.ctl.guid.target = "Creature-0-0-0-0-347-000003"
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.is_false(sustained(0.2))
                H.ctl.unitCombat.target = false
                assert.is_false(sustained(14))
                H.ctl.unitCombat.target = true
                assert.is_false(sustained(0.2))
            end)
        end
        if spec ~= "Protection" then
            it("can open a level-one melee pull, then drops Attack when swings begin", function()
                local H = boot(1, 0, { autoAttack = false, prepull = true })
                assert.are.equal("auto_attack", read(H, 0.2))
                H.ctl.current[6603] = true
                assert.are_not.equal("auto_attack", read(H, 0.2))
            end)

            it("holds attacks on idle dungeon enemies, including bosses, and joins a party pull", function()
                for _, boss in ipairs({ true, false }) do
                    local H = boot(60, 60, { instance = "party", group = 5, idleTarget = true, boss = boss })
                    read(H, 0.2)
                    local out = H.Hekili.Engine.Output.Primary
                    for i = 1, out.count do
                        local action = H.Hekili.Class.abilities[out.recs[i].actionName]
                        assert.is_not_true(action.startsCombat, action.key)
                    end
                end
                local H = boot(28, 0, {
                    instance = "party",
                    group = 5,
                    autoAttack = false,
                    prepull = true,
                    engaged = true,
                    targetVictim = "party1",
                })
                assert.are.equal("auto_attack", read(H, 0.2))
            end)

            it("holds damage when an idle outdoor target stands beside the current attacker", function()
                local H = boot(35, 60, { idleTarget = true, form = 1 })
                H.ctl.exists.nameplate1, H.ctl.exists.nameplate1target = true, true
                H.ctl.guid.nameplate1 = "Creature-0-0-0-0-347-000002"
                H.ctl.unitIs.nameplate1target = "player"
                H.ctl.unitCombat.nameplate1, H.ctl.distance.nameplate1 = true, 3
                H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
                read(H, 0.2)
                local st = H.Hekili.State
                st.reset("Primary", true)
                assert.is_false(st.warrior_attack_target)
                assert.are.equal(0, st.warrior_nearby_enemies)
                H.ctl.unitCombat.target, H.ctl.exists.targettarget = true, true
                H.ctl.unitIs.targettarget = "player"
                read(H, 0.2)
                st.reset("Primary", true)
                assert.is_true(st.warrior_attack_target)
                assert.are.equal(2, st.warrior_nearby_enemies)
            end)

            it("allows a hostile practice dummy in an instance", function()
                local H =
                    boot(60, 50, { instance = "party", idleTarget = true, target = "Creature-0-0-0-0-4952-000001" })
                read(H, 0.2)
                local st = H.Hekili.State
                st.reset("Primary", true)
                assert.is_true(st.warrior_attack_target)
                assert.is_false(st.warrior_field)
                H.ctl.friendly.target = true
                H.Fire("PLAYER_TARGET_CHANGED")
                read(H, 0.2)
                st.reset("Primary", true)
                assert.is_false(st.warrior_attack_target)
            end)

            it("requires positive gap-closer range on a level-60 dungeon boss", function()
                for _, distance in ipairs({ 15, SECRET }) do
                    local H = boot(60, 35, {
                        instance = "party",
                        group = 5,
                        targetVictim = "party1",
                        engaged = true,
                        boss = true,
                        prepull = true,
                        form = 3,
                        distance = distance,
                    })
                    read(H, 0.2)
                    local out = H.Hekili.Engine.Output.Primary
                    H.Hekili.State.reset("Primary", true)
                    assert.is_true(H.Hekili.State.warrior_attack_target)
                    assert.are.equal(distance == 15, H.Hekili.State.warrior_intercept_range)
                    if distance == SECRET then
                        for i = 1, out.count do
                            assert.are_not.equal("intercept", out.recs[i].actionName)
                            assert.are_not.equal("charge", out.recs[i].actionName)
                        end
                    end
                end
            end)

            it("offers Charge only inside its learned range and on an eligible pull", function()
                for _, distance in ipairs({ 15, 3, 35, SECRET }) do
                    local H = boot(4, 0, { form = 1, prepull = true, distance = distance })
                    assert.are.equal(distance == 15, read(H, 0.2) == "charge")
                end
            end)
        end

        it("interrupts a hostile player's confirmed cast with the equipped shield", function()
            local H = boot(20, 40, { instance = "pvp", form = 1 })
            H.ctl.isPlayer.target = true
            H.Fire("PLAYER_TARGET_CHANGED")
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
            assert.are_not.equal("shield_bash", read(H, 0.2))
            H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
            assert.are.equal("shield_bash", read(H, 0.2))
            H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
            assert.are_not.equal("shield_bash", read(H, 0.2))
        end)

        it("follows a manual shield swap during combat", function()
            local H = boot(38, 40, { instance = "pvp", form = 1, noShield = true })
            H.ctl.isPlayer.target = true
            H.Fire("PLAYER_TARGET_CHANGED")
            cast(H, true)
            assert.are_not.equal("shield_bash", read(H, 0.2))

            H.ctl.items[80001] = { "Sword", "INVTYPE_WEAPON", 2, 7 }
            H.ctl.items[80002] = { "Shield", "INVTYPE_SHIELD", 4, 6 }
            H.ctl.inventory[16], H.ctl.inventory[17] = 80001, 80002
            H.Fire("PLAYER_EQUIPMENT_CHANGED", 16, true)
            H.Fire("PLAYER_EQUIPMENT_CHANGED", 17, true)
            read(H, 1.2)
            cast(H, true)
            assert.are.equal("shield_bash", read(H, 0.2))

            H.ctl.inventory[17] = nil
            H.Fire("PLAYER_EQUIPMENT_CHANGED", 17, false)
            read(H, 1.2)
            cast(H, true)
            assert.are_not.equal("shield_bash", read(H, 0.2))
        end)

        it("uses Pummel with Berserker Stance and respects range, spell knowledge and Interrupts", function()
            for _, options in ipairs({
                { level = 38, expected = true },
                { level = 37 },
                { level = 38, form = 1 },
                { level = 38, distance = 12 },
                { level = 38, disabled = true },
            }) do
                local H = boot(
                    options.level,
                    40,
                    { instance = "pvp", form = options.form or 3, distance = options.distance, noShield = true }
                )
                H.ctl.isPlayer.target = true
                H.Fire("PLAYER_TARGET_CHANGED")
                H.Hekili:FireToggle("interrupts", options.disabled and "off" or "on")
                cast(H, true)
                assert.are.equal(options.expected == true, read(H, 0.2) == "pummel")
            end
        end)
    end)
end
