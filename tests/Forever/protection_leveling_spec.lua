local SECRET = require("Game.State.helpers.fake_api").SECRET
local fixture = require("Forever.helpers.protection_leveling")
local warrior, read, cast, PACK = fixture.warrior, fixture.read, fixture.cast, fixture.PACK
local CASTER = "Creature-0-0-0-0-346-000001"

describe("the Protection leveling priority", function()
    it("uses early weapon attacks before the Revenge unlock", function()
        assert.are.equal("heroic_strike", read(warrior(1, 18, { noShield = true })))
        local H = warrior(13, 18, { revenge = true })
        assert.are.equal("rend", read(H))
        assert.is_false(H.Hekili.State:IsKnown("revenge"))
    end)

    it("keeps early Bloodrage available and skips it when readable health is low", function()
        for _, health in ipairs({ 1000, SECRET, 250 }) do
            local H = warrior(12, 5, { health = health, bloodrageReady = true })
            assert.are.equal(health ~= 250, read(H) == "bloodrage")
        end
    end)

    it("does not show Bloodrage as ready after reloading during its hidden cooldown", function()
        local H = warrior(28, 5, { bloodrageReady = true })
        H.ctl.cooldown[2687] = { startTime = SECRET, duration = SECRET, isActive = true, isOnGCD = false }
        -- No cast or SPELL_UPDATE_COOLDOWN has been seen by this addon session.
        for _, seconds in ipairs({ 0.2, 0.4, 1.6 }) do
            read(H, seconds)
            local out = H.Hekili.Engine.Output.Primary
            if out.count > 0 and out.recs[1].actionName == "bloodrage" then
                assert.is_true(out.recs[1].time > 0.05)
            end
            H.Hekili.State.reset("Primary")
            assert.is_true(H.Hekili.State.cooldown.bloodrage.remains > 0.05)
        end
        H.ctl.cooldown[2687].isActive = false
        assert.are.equal("bloodrage", read(H, 0.2))
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
    end)

    it("prefers a live Revenge proc at low rage and Shield Slam when both are affordable", function()
        assert.are.equal("revenge", read(warrior(14, 8, { revenge = true })))
        local talents = { [23922] = 1 }
        assert.are.equal("revenge", read(warrior(40, 20, { talents = talents, revenge = true, demo = true })))
        local H = warrior(40, 30, { talents = talents, revenge = true })
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("shield_slam", read(H))
        H = warrior(40, 30, { talents = talents, noShield = true })
        assert.is_not_equal("shield_slam", read(H))
    end)

    it("switches to Defensive Stance in combat with a shield and uses Vanguard Charge from that stance", function()
        assert.are.equal("defensive_stance", read(warrior(16, 18, { form = 1 })))
        local H = warrior(25, 0, { prepull = true, distance = 20, talents = { [1310317] = 1 } })
        assert.are.equal("charge", read(H))
        H = warrior(24, 0, { prepull = true, distance = 20 })
        assert.are.equal("battle_stance", read(H))
        for _, distance in ipairs({ 3, 30 }) do
            H = warrior(25, 0, { prepull = true, distance = distance, talents = { [1310317] = 1 } })
            assert.is_not_equal("charge", read(H))
        end
    end)

    it("offers early channels and delays hard casts briefly while Shield Block is active", function()
        for _, options in ipairs({ {}, { instance = "party", group = 5 }, { instance = "raid", group = 10 } }) do
            for _, channel in ipairs({ false, true }) do
                options.shieldBlock = true
                local H = warrior(60, 15, options)
                cast(H, true, channel)
                assert.are.equal(channel, read(H, 0.1) == "shield_bash")
                assert.are.equal("shield_bash", read(H, 0.2))
                assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
                if channel then
                    H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "target", SECRET, SECRET, nil, 77)
                else
                    H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
                end
                assert.is_not_equal("shield_bash", read(H, 0.2))
            end
            options.shieldBlock = false
            local H = warrior(60, 15, options)
            cast(H, true)
            assert.are.equal("shield_bash", read(H, 0.1))
        end
        for _, options in ipairs({ { noShield = true }, { distance = 10 }, { instance = "pvp" } }) do
            local H = warrior(12, 15, options)
            cast(H, true)
            assert.is_not_equal("shield_bash", read(H))
        end
    end)

    it("reserves Bash rage between casts and for later mobs of the observed type", function()
        local H = warrior(18, 15, { target = CASTER, demo = true })
        assert.are.equal("shield_block", read(H, 0.2))
        assert.are.equal(0, H.Hekili.State.prot_bash_reserve)
        cast(H, true)
        assert.are.equal("shield_bash", read(H, 0.3))
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        assert.is_not_equal("shield_block", read(H, 0.2))
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)

        H.ctl.guid.target = "Creature-0-0-0-0-346-000002"
        H.Fire("PLAYER_TARGET_CHANGED")
        read(H, 0.2)
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)
        H.ctl.guid.target = "Creature-0-0-0-0-347-000003"
        H.Fire("PLAYER_TARGET_CHANGED")
        read(H, 0.2)
        assert.are.equal(0, H.Hekili.State.prot_bash_reserve)

        H = warrior(18, 20, { target = CASTER, demo = true })
        cast(H, true)
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        assert.are.equal("shield_block", read(H, 0.2))
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
    end)

    it("keeps Bash and a live Revenge in the same Rage budget", function()
        local H = warrior(40, 30, { target = CASTER, talents = { [23922] = 1 }, revenge = true, demo = true })
        H.Hekili:FireToggle("defensives", "off")
        cast(H, true)
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        assert.are.equal("revenge", read(H))
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)
    end)

    it("releases the reserve without an available interrupt and respects the global cooldown", function()
        local H = warrior(18, 15, { target = CASTER, bashCooldown = true, demo = true })
        cast(H, true)
        read(H, 0.2)
        H.Hekili.State.reset("Primary")
        assert.are.equal(0, H.Hekili.State.prot_bash_reserve)

        H = warrior(18, 15, { target = CASTER, demo = true })
        local gcd = H.Hekili.Engine.Registry.GCD_SPELL
        H.ctl.cooldown[gcd] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 1.5 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        cast(H, true)
        read(H, 0.3)
        local out = H.Hekili.Engine.Output.Primary
        local forecastBash
        for i = 1, out.count do
            local rec = out.recs[i]
            if rec.actionName == "shield_bash" then
                assert.is_true(rec.time > 0)
                forecastBash = true
            end
        end
        assert.is_true(forecastBash)
        H.Hekili.State.reset("Primary")
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)
        H.ctl.cooldown[gcd] = { isActive = false, isOnGCD = false, startTime = 0, duration = 0 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.are.equal("shield_bash", read(H, 0.2))
        assert.are.equal(0, out.recs[1].time)
        H.Hekili:FireToggle("interrupts", "off")
        read(H, 0.2)
        assert.are.equal(0, H.Hekili.State.prot_bash_reserve)
    end)

    it("spends Rage on the rotation when Shield Bash will miss the current cast", function()
        for _, options in ipairs({ { group = 0 }, { instance = "party", group = 5, threat = 3 } }) do
            options.target, options.demo, options.revenge = CASTER, true, true
            local H = warrior(28, 10, options)
            H.Hekili:FireToggle("defensives", "off")
            local bash = H.Hekili.State.action.shield_bash.id
            H.ctl.cooldown[bash] = {
                isActive = true,
                isOnGCD = false,
                startTime = H.ctl.now - 9.5,
                duration = 12,
            }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            cast(H, true)
            assert.are.equal("revenge", read(H, 1.6))
            assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
            local state = H.Hekili.State
            state.reset("Primary")
            assert.is_true(state.debuff.casting.up)
            assert.is_true(state.cooldown.shield_bash.remains > state.debuff.casting.remains)
            assert.is_true(state.cooldown.shield_bash.remains < 1.5)
            assert.are.equal(0, state.prot_bash_reserve)
        end
    end)

    it("releases the cast reserve when the global cooldown ends too late", function()
        local H = warrior(28, 15, { target = CASTER, demo = true })
        cast(H, true)
        read(H, 1.1)
        local state = H.Hekili.State
        local gcd = H.Hekili.Engine.Registry.GCD_SPELL
        H.ctl.cooldown[gcd] = { isActive = true, isOnGCD = true, startTime = H.ctl.now, duration = 1.5 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        read(H, 0.1)
        state.reset("Primary")
        assert.is_true(state.debuff.casting.up)
        assert.are.equal(0, state.cooldown.shield_bash.remains)
        assert.is_true(state.cooldown.global_cooldown.remains > state.debuff.casting.remains)
        assert.are.equal(0, state.prot_bash_reserve)
    end)

    it("lets dungeon threat spend the reserve on the opener or when aggro is lost", function()
        local H =
            warrior(60, 20, { target = CASTER, group = 5, instance = "party", threat = 0, talents = { [23922] = 1 } })
        H.Hekili:FireToggle("defensives", "off")
        cast(H, true)
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        assert.are.equal("shield_slam", read(H, 0.2))
        H.ctl.threat.target = 3
        assert.is_not_equal("shield_slam", read(H, 4))
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)

        H.ctl.exists.targettarget = true
        H.ctl.unitIs.targettarget = "party1"
        H.ctl.threat.target = 0
        assert.are.equal("shield_slam", read(H, 0.2))

        H.ctl.threat.target = 3
        assert.is_not_equal("shield_slam", read(H, 0.2))
        H.ctl.guid.target = "Creature-0-0-0-0-346-000002"
        H.ctl.threat.target = 0
        H.ctl.exists.targettarget = false
        H.ctl.unitIs.targettarget = nil
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("shield_slam", read(H, 0.2))
    end)

    it("opens on confirmed nearby dungeon mobs even with idle or controlled enemies", function()
        local H = warrior(60, 25, { group = 5, instance = "party", threat = 3, talents = { [23922] = 1 } })
        H.ctl.auras.player.HELPFUL[1] = nil
        H.Fire("UNIT_AURA", "player")
        H.ctl.exists.nameplate1 = true
        H.ctl.exists.nameplate1target = true
        H.ctl.guid.nameplate1 = "Creature-0-0-0-0-347-000003"
        H.ctl.unitIs.nameplate1target = "party1"
        H.ctl.distance.nameplate1 = SECRET
        H.ctl.unitCombat.nameplate1 = false
        H.Fire("PLAYER_ENTERING_WORLD", false, true) -- a visible plate can predate the reload
        assert.are.equal("shield_slam", read(H, 0.2))

        H.ctl.distance.nameplate1 = 4
        H.ctl.auras.nameplate1 = { HARMFUL = { { spellId = 20511, expirationTime = H.ctl.now + 8 } } }
        H.Fire("UNIT_AURA", "nameplate1")
        H.ctl.exists.nameplate2, H.ctl.guid.nameplate2 = true, "Creature-0-0-0-0-347-000004"
        H.ctl.distance.nameplate2 = SECRET
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        assert.are.equal("thunder_clap", read(H, 0.2))
        H.Hekili:FireToggle("mode", "single")
        assert.are.equal("shield_slam", read(H, 0.2))
    end)

    it("budgets a level-60 queued strike for an upcoming Shield Slam", function()
        local function check(rage)
            local H = warrior(60, rage, { classification = "normal", talents = { [23922] = 1 } })
            H.Hekili:FireToggle("defensives", "off")
            local slam = { isActive = true, isOnGCD = false, startTime = H.ctl.now - 5, duration = 6 }
            H.ctl.cooldown[23922], H.ctl.cooldown[23925] = slam, slam
            H.Fire("SPELL_UPDATE_COOLDOWN")
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-sunder", 11597)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-sunder", 11597)
            return read(H, 0.2)
        end

        assert.is_not_equal("heroic_strike", check(20))
        assert.are.equal("heroic_strike", check(60))
    end)

    it("spends excess level-28 Rage before adding filler debuffs", function()
        for _, group in ipairs({ 0, 2 }) do
            for _, rage in ipairs({ 80, 95 }) do
                local H = warrior(28, rage, {
                    group = group,
                    threat = 3,
                    classification = "normal",
                    demo = true,
                    shieldBlock = true,
                })
                H.ctl.unitIs.targettarget = "player"
                assert.are.equal("heroic_strike", read(H))
            end
        end
    end)

    it("keeps the level-28 main abilities and low-Rage pooling ahead of an excess dump", function()
        local options = { classification = "normal", demo = true, shieldBlock = true }
        assert.are.equal("sunder_armor", read(warrior(28, 35, options)))
        options.revenge = true
        assert.are.equal("revenge", read(warrior(28, 95, options)))
        options.revenge, options.shieldBlock = false, false
        assert.are.equal("shield_block", read(warrior(28, 95, options)))

        local H = warrior(28, 95, options)
        cast(H, true)
        assert.are.equal("shield_bash", read(H))
        options.distance = 12
        assert.is_not_equal("heroic_strike", read(warrior(28, 95, options)))
    end)

    it("uses Cleave for excess level-28 Rage only with multiple targets", function()
        local H = warrior(28, 95, { demo = true, shieldBlock = true })
        H.Hekili:FireToggle("mode", "aoe")
        for _, spell in ipairs({ 6343, 8198, 8204 }) do
            H.ctl.cooldown[spell] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 6 }
        end
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.are.equal("cleave", read(H))
        H.Hekili:FireToggle("mode", "single")
        assert.are.equal("heroic_strike", read(H))
    end)

    it("uses positive five-yard evidence for Cleave and wider evidence for Clap and Demo", function()
        local H = warrior(28, 95, { group = 5, instance = "party", threat = 3, demo = true, shieldBlock = true })
        H.ctl.exists.nameplate1, H.ctl.guid.nameplate1 = true, SECRET
        H.ctl.distance.nameplate1, H.ctl.unitCombat.nameplate1 = 7, false
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        for _, spell in ipairs({ 6343, 8198, 8204 }) do
            H.ctl.cooldown[spell] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 6 }
        end
        H.Fire("SPELL_UPDATE_COOLDOWN")
        local range, upper = H.ns.Facade.LibRangeCheck.GetRange, 8
        H.ns.Facade.LibRangeCheck.GetRange = function(self, unit)
            if unit == "nameplate1" then
                return 5, upper
            end
            return range(self, unit)
        end
        assert.are.equal("heroic_strike", read(H, 0.2))
        local state = H.Hekili.State
        state.reset("Primary")
        assert.are.equal(2, state.prot_nearby_enemies)
        assert.are.equal(1, state.prot_cleave_targets)

        upper = 10
        read(H, 0.2)
        state.reset("Primary")
        assert.are.equal(1, state.prot_nearby_enemies)
        assert.are.equal(2, state.prot_shout_targets)

        H.ctl.distance.nameplate1 = 4
        assert.are.equal("cleave", read(H, 0.2))
    end)

    it("uses a learned Concussion Blow as a backup on a non-boss cast", function()
        local talents = { [12809] = 1 }
        for _, options in ipairs({
            { talents = talents, bashCooldown = true },
            { talents = talents, boss = true, bashCooldown = true },
            { bashCooldown = true },
        }) do
            local H = warrior(33, 20, options)
            cast(H, true)
            local action = read(H, 0.1)
            assert.are.equal(options.talents ~= nil and not options.boss, action == "concussion_blow", tostring(action))
        end
    end)

    it("reserves Shield Block for nearby melee pressure", function()
        local H = warrior(16, 10, { demo = true })
        assert.are.equal("shield_block", read(H))
        for _, options in ipairs({ { creature = "elemental" }, { noShield = true }, { bashCooldown = true } }) do
            options.demo = true
            H = warrior(16, 10, options)
            if options.bashCooldown then
                cast(H, true)
            end
            assert.is_not_equal("shield_block", read(H, 0.2))
        end
    end)

    it("continues past a weaponless humanoid without depending on a rejected cast event", function()
        for _, options in ipairs({
            { creature = "humanoid", group = 2 },
            { creature = "humanoid", classification = "elite" },
        }) do
            options.threat = 3
            local H = warrior(18, 25, options)
            if options.group then
                H.Hekili:FireToggle("mode", "aoe")
                H.ctl.unitIs.targettarget = "player"
            end
            assert.is_true(H.Hekili.State:IsKnown("disarm"))
            assert.is_false(H.Hekili.State.prot_disarm_target) -- old priorities still resolve this condition
            for _ = 1, 3 do
                assert.are.equal(options.group and "thunder_clap" or "demoralizing_shout", read(H, 0.2))
                local out = H.Hekili.Engine.Output.Primary
                for i = 1, out.count do
                    assert.is_not_equal("disarm", out.recs[i].actionName)
                end
            end
            for _, list in pairs(H.Hekili.DB.profile.packs[PACK].lists) do
                for _, entry in ipairs(list) do
                    assert.is_not_equal("disarm", entry.action)
                    if entry.action == "taunt" then
                        assert.is_truthy(entry.criteria and entry.criteria:find("prot_last_resort_taunt", 1, true))
                    end
                end
            end
        end
    end)

    it("uses Sunder Armor as a fallback on a protected target with Rend already up", function()
        local H = warrior(18, 30, { demo = true })
        H.Hekili:FireToggle("defensives", "off")
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-rend", 6546)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-rend", 6546)
        assert.are.equal("sunder_armor", read(H))
    end)

    it("opens with Demoralizing Shout on melee pulls even with raid maintenance off", function()
        for _, group in ipairs({ 0, 2 }) do
            local H = warrior(16, 25, { group = group, threat = 3 })
            H.ctl.unitIs.targettarget = "player"
            assert.are.equal("demoralizing_shout", read(H))
            H.Hekili:FireToggle("defensives", "off")
            assert.is_not_equal("demoralizing_shout", read(H))
        end
        local H = warrior(16, 25)
        H.Hekili:FireToggle("mode", "aoe")
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("thunder_clap", read(H))
    end)

    it("publishes the potion and trained defensive cues even with hidden health", function()
        local H = warrior(12, 20, { health = SECRET, potion = true })
        read(H)
        local out = H.Hekili.Engine.Output.Primary
        assert.are.equal(1, out.healthCues.n)
        assert.are.same({ action = "healing_potion", percent = 40, texture = 134829 }, out.healthCues[1])
        H = warrior(30, 20, { health = SECRET, talents = { [12975] = 1 }, potion = true })
        read(H)
        out = H.Hekili.Engine.Output.Primary
        assert.are.equal("last_stand", out.healthCues[1].action)
        H.ctl.cooldown[12975] = { isActive = true, isOnGCD = false }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        read(H)
        assert.are.equal("shield_wall", out.healthCues[1].action)
        assert.are.equal("healing_potion", out.healthCues[2].action)
        H.Hekili:FireToggle("defensives", "off")
        read(H)
        assert.are.equal(0, out.healthCues.n)
    end)

    it("keeps the leveling rules in the Protection pack and the sustained raid rotation at 60", function()
        for _, pack in ipairs({ "Arms (wowsims.com)", "Fury (wowsims.com)" }) do
            local H = warrior(20, 20, { pack = pack })
            read(H)
            assert.is_false(H.Hekili.State.prot_leveling)
            assert.is_false(H.Hekili.State.prot_adventuring)
            assert.are.equal(pack, H.Hekili.Engine.Output.status.packName)
        end
        local H = warrior(60, 35, { instance = "raid", talents = { [23922] = 1 }, potion = true, health = SECRET })
        local action = read(H)
        local cues = H.Hekili.Engine.Output.Primary.healthCues
        assert.is_false(H.Hekili.State.prot_leveling)
        assert.is_false(H.Hekili.State.prot_adventuring)
        assert.is_not_equal("healing_potion", action)
        for i = 1, cues.n do
            assert.is_not_equal("healing_potion", cues[i].action)
        end
        assert.is_false(H.Hekili.State.prot_threat_spend)
    end)

    it("conserves Block while a raid boss is visibly held by another player", function()
        local H = warrior(60, 45, { boss = true, instance = "raid", group = 10, threat = 1, talents = { [23922] = 1 } })
        H.ctl.exists.targettarget = true
        H.ctl.unitIs.targettarget = "raid1"
        assert.is_not_equal("shield_block", read(H))
        assert.is_true(H.Hekili.State.prot_offtanking)

        H.ctl.threat.target = SECRET
        read(H, 0.2)
        assert.is_false(H.Hekili.State.prot_offtanking)

        H.ctl.threat.target = 3
        H.ctl.unitIs.targettarget = "player"
        read(H, 0.2)
        H.Hekili.State.reset("Primary")
        assert.is_true(H.Hekili.State.prot_dump_reserve >= 20)
    end)
end)
