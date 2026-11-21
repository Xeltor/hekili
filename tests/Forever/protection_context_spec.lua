local SECRET = require("Game.State.helpers.fake_api").SECRET
local fixture = require("Forever.helpers.protection_leveling")
local warrior, read, cast = fixture.warrior, fixture.read, fixture.cast

local function applied(H, action)
    local spell = H.Hekili.State.action[action].id
    H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-" .. action, spell)
    H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. action, spell)
end

local function pack(H)
    H.ctl.exists.targettarget = true
    H.ctl.unitIs.targettarget = "player"
    H.ctl.exists.nameplate1 = true
    H.ctl.exists.nameplate1target = true
    H.ctl.guid.nameplate1 = "Creature-0-0-0-0-347-000003"
    H.ctl.unitIs.nameplate1target = "player"
    H.ctl.unitCombat.nameplate1 = true
    H.ctl.distance.nameplate1 = 4
    H.ctl.threat.nameplate1 = 3
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end

local function immediate(H, action, seconds)
    local result = read(H, seconds)
    return result == action and H.Hekili.Engine.Output.Primary.recs[1].time <= 0.05
end

describe("Protection outdoor and dungeon coverage", function()
    it("returns a shieldless dungeon tank to Defensive Stance when the aggro and Rage trade are confirmed", function()
        local function tank(level, rage, options)
            options.instance = options.instance or "party"
            options.group = 5
            options.form = options.form or 1
            options.noShield = true
            return warrior(level, rage, options)
        end

        -- Defensive Stance's threat, mitigation and access to Revenge do not require a shield.
        assert.is_true(immediate(tank(10, 0, { threat = 3 }), "defensive_stance"))
        assert.is_true(immediate(tank(30, 10, { threat = 2, form = 3 }), "defensive_stance"))
        assert.is_false(immediate(tank(9, 0, { threat = 3 }), "defensive_stance"))
        assert.is_false(immediate(tank(13, 10, { threat = 3 }), "defensive_stance")) -- no Tactical Mastery
        assert.is_false(immediate(tank(30, 35, { threat = 3 }), "defensive_stance"))
        assert.is_false(immediate(tank(30, 5, { threat = 1, targetVictim = "party1" }), "defensive_stance"))
        assert.is_false(immediate(tank(30, 5, { threat = SECRET }), "defensive_stance"))
        assert.is_false(immediate(tank(30, 5, { threat = 3, idleTarget = true }), "defensive_stance"))
        assert.is_false(immediate(tank(30, 5, { threat = 3, noWeapon = true }), "defensive_stance"))
        assert.is_false(immediate(tank(30, 5, { threat = 3, instance = "none" }), "defensive_stance"))
    end)

    it("uses Victory Rush before a routine Revenge when the full heal fits or the kill window is ending", function()
        for _, instance in ipairs({ "none", "party" }) do
            local options = {
                instance = instance,
                group = instance == "party" and 5 or 0,
                threat = 3,
                revenge = true,
                victorious = true,
                health = 900,
            }
            assert.is_true(immediate(warrior(20, 20, options), "victory_rush"))
            options.health = 1000
            assert.is_true(immediate(warrior(20, 20, options), "revenge"))
            assert.is_true(immediate(warrior(20, 20, options), "victory_rush", 18.6))
            options.health = SECRET
            local H = warrior(20, 20, options)
            assert.is_true(immediate(H, "revenge"))
            local cues = H.Hekili.Engine.Output.Primary.healthCues
            assert.are.equal("victory_rush", cues[cues.n].action)
            assert.are.equal(90, cues[cues.n].percent)
        end
    end)

    it("requires a learned, active Victory Rush in melee and preserves urgent interrupts and lost threat", function()
        for _, case in ipairs({
            { level = 19, victorious = true },
            { level = 20 },
            { level = 20, victorious = true, distance = 12 },
            { level = 20, victorious = true, instance = "party", group = 5, threat = 0 },
            { level = 20, victorious = true, instance = "party", group = 5, idleTarget = true },
        }) do
            case.health, case.revenge = 800, true
            assert.is_false(immediate(warrior(case.level, 35, case), "victory_rush"))
        end
        local H = warrior(20, 35, { victorious = true, health = 800 })
        cast(H, true)
        assert.is_true(immediate(H, "shield_bash"))
    end)

    it(
        "uses early Rend but avoids routine Rend and single-target Clap on ordinary dungeon trash once Revenge is learned",
        function()
            local options = { instance = "party", group = 5, threat = 3, demo = true, classification = "normal" }
            assert.is_true(immediate(warrior(13, 35, options), "rend"))
            for _, classification in ipairs({ "normal", "rare" }) do
                options.classification = classification
                assert.is_true(immediate(warrior(14, 35, options), "sunder_armor"))
            end
            options.classification = "elite"
            local H = warrior(14, 35, options)
            assert.is_true(immediate(H, "thunder_clap"))
            applied(H, "thunder_clap")
            assert.is_true(immediate(H, "rend", 1.6))
        end
    )

    it("reuses ready Thunder Clap on a controlled pack while its debuff remains up", function()
        for _, level in ipairs({ 6, 18, 28, 40, 59, 60 }) do
            local H = warrior(level, 35, { instance = "party", group = 5, threat = 3, demo = true })
            pack(H)
            read(H, 0.2)
            applied(H, "thunder_clap")
            assert.is_true(immediate(H, "thunder_clap", 6.2), "level " .. level)
            H.Hekili.State.reset("Primary")
            assert.is_true(H.Hekili.State.debuff.thunder_clap.up)
        end
    end)

    it("does not turn AoE Clap into a single-target, unlearned or out-of-range filler", function()
        for _, options in ipairs({ {}, { distance = 10 }, { noShield = true, form = 3 } }) do
            options.instance, options.group, options.threat, options.demo = "party", 5, 3, true
            local H = warrior(28, 35, options)
            if options.distance or options.form then
                pack(H)
            end
            read(H, 0.2)
            applied(H, "thunder_clap")
            assert.is_false(immediate(H, "thunder_clap", 6.2))
        end
        local H = warrior(5, 35, { instance = "party", group = 5, threat = 3 })
        pack(H)
        assert.is_false(immediate(H, "thunder_clap"))
        assert.is_false(H.Hekili.State:IsKnown("thunder_clap"))
    end)

    it("keeps interrupt Rage and the single-target toggle ahead of repeated Clap", function()
        local H = warrior(28, 20, {
            instance = "party",
            group = 5,
            threat = 3,
            demo = true,
            target = "Creature-0-0-0-0-346-000001",
        })
        pack(H)
        cast(H, true)
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        applied(H, "thunder_clap")
        assert.is_false(immediate(H, "thunder_clap", 6.2))
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)

        H = warrior(28, 35, { instance = "party", group = 5, threat = 3, demo = true })
        pack(H)
        read(H, 0.2)
        applied(H, "thunder_clap")
        H.Hekili:FireToggle("mode", "single")
        assert.is_false(immediate(H, "thunder_clap", 6.2))
    end)

    it("limits routine Sunder on normal dungeon trash but builds it on durable targets", function()
        for _, classification in ipairs({ "normal", "rare", "elite", "rareelite", "worldboss" }) do
            for _, level in ipairs({ 10, 28, 40, 60 }) do
                local H = warrior(level, 35, {
                    instance = "party",
                    group = 5,
                    threat = 3,
                    classification = classification,
                    demo = true,
                })
                H.Hekili:FireToggle("defensives", "off")
                applied(H, "rend")
                applied(H, "thunder_clap")
                applied(H, "sunder_armor")
                for _, id in ipairs({ 23922, 23923, 23924, 23925 }) do
                    H.ctl.cooldown[id] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 6 }
                end
                H.Fire("SPELL_UPDATE_COOLDOWN")
                local action = read(H, 4)
                local short = classification == "normal" or classification == "rare"
                assert.are.equal(short, H.Hekili.State.prot_short_pull)
                assert.are.equal(
                    not short,
                    action == "sunder_armor",
                    classification .. " level " .. level .. ": " .. tostring(action)
                )
            end
        end
    end)

    it("still spends Sunder on lost threat and exempts bosses from the short-pull budget", function()
        for _, boss in ipairs({ false, true }) do
            local H = warrior(28, 35, {
                instance = "party",
                group = 5,
                threat = boss and 3 or 0,
                classification = "normal",
                boss = boss,
                demo = true,
            })
            H.Hekili:FireToggle("defensives", "off")
            H.ctl.exists.targettarget = true
            H.ctl.unitIs.targettarget = boss and "player" or "party1"
            applied(H, "rend")
            applied(H, "thunder_clap")
            applied(H, "sunder_armor")
            assert.are.equal("sunder_armor", read(H, 4))
            assert.are.equal(not boss, H.Hekili.State.prot_short_pull)
        end
    end)

    it("keeps the contextual additions outside raids and respects learned spells at every level", function()
        for level = 1, 60 do
            local H = warrior(level, 35, { instance = "party", group = 5, threat = 3 })
            local action = read(H, 0.2)
            assert.is_not_nil(action, "level " .. level)
            assert.is_true(H.Hekili.State:IsKnown(action), action .. " at level " .. level)
            assert.is_true(H.Hekili.State.prot_contextual)
        end
        local H = warrior(60, 35, { instance = "raid", group = 10, threat = 3 })
        read(H)
        assert.is_false(H.Hekili.State.prot_contextual)
        assert.is_false(H.Hekili.State.prot_short_pull)
    end)
end)
