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
