local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local ws = require("Forever.helpers.wowsims")
local ww = require("Forever.helpers.warrior_world")
local HARVEST_WATCHER = "Creature-0-0-0-0-114-000001"

local function warrior(level, rage, options)
    options = options or {}
    local character = ws.content(ww, {
        level = level,
        learn = ws.learn("WARRIOR"),
        talents = options.talents or ws.header("warrior_arms").talents,
        kit = { "shield_bash", "shield_wall", "retaliation" },
    }).character()
    if options.unarmed then
        character.items = {}
    elseif options.shield then
        character.items = { [16] = { 1, "Sword", "INVTYPE_WEAPON" }, [17] = { 2, "Shield", "INVTYPE_SHIELD" } }
    end
    character.form = options.form or 1
    character.power.value = rage
    character.instanceType = options.instance
    if options.lastStand then
        character.talents[12975] = 1
        character.known[#character.known + 1] = 12975
    end
    if options.talents and not character.talents[1310222] then
        for i = #character.known, 1, -1 do
            if character.known[i] == 1310222 then
                table.remove(character.known, i)
            end
        end
    end

    local H = headless.new({
        character = character,
        pack = ww.PACK,
        beforeLoad = function(h)
            if options.targetSpeed then
                h.env.GetUnitSpeed = function(unit)
                    return unit == "target" and options.targetSpeed or 0, 7, 7, 4.72
                end
            end
        end,
    })
    assert.are.same({}, H.loadErrors)
    local ctl = H.ctl
    ctl.current[6603] = true
    ctl.unitCombat.target, ctl.exists.targettarget, ctl.unitIs.targettarget = true, true, "player"
    ctl.classification = options.classification
    ctl.level.target, ctl.distance.target = options.boss and -1 or level, options.distance or 3
    ctl.guid.target = options.target or ctl.guid.target
    ctl.creature.target = options.creature
    ctl.isPlayer.target = options.player
    ctl.groupMembers = options.group or 0
    ctl.isInRaid = options.raid == true
    ctl.healthPlain = true -- explicit fixture health; SECRET cases remain unreadable
    ctl.unitHealth.player = options.health or 1000
    ctl.itemCount[5512] = options.healthstone and 1 or 0
    ctl.items[5512] = { "Minor Healthstone", icon = 538745 }
    for id, icon in pairs(options.potions or {}) do
        ctl.itemCount[id], ctl.items[id] = 1, { "Healing Potion", icon = icon }
    end
    if level == 1 or options.shout then
        ctl.auras.player.HELPFUL[1] = { spellId = 6673, expirationTime = ctl.now + 100, applications = 0 }
        H.Fire("UNIT_AURA", "player")
    elseif options.victorious then
        ctl.auras.player.HELPFUL[1] = { spellId = 402975, expirationTime = ctl.now + 20, applications = 0 }
        H.Fire("UNIT_AURA", "player")
    end
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, ctl.now + 0.2))
    ctl.combat = true
    H.Fire("PLAYER_REGEN_DISABLED")
    local VS = H.ns.VirtualState
    local power, pool = VS.Power, { est = rage, lo = rage, hi = rage, conf = 1 }
    VS.Power = function(pt, now)
        return pt == 1 and pool or power(pt, now)
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 0.2)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    local picks = {}
    for i = 1, out.count do
        picks[i] = out.recs[i].actionName
    end
    return picks
end

local function hostileChannel(H, interruptible)
    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
    H.Fire(interruptible and "UNIT_SPELLCAST_INTERRUPTIBLE" or "UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
end

describe("the shipped Arms leveling and PvE priority", function()
    it("uses Heroic Strike on a starting warrior as soon as it is affordable", function()
        assert.are.equal("heroic_strike", read(warrior(1, 18), 1.6)[1])
        local H = warrior(1, 5)
        if read(H, 1.6)[1] == "heroic_strike" then
            assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time > 0)
        end
    end)

    it("finds a learned attack on an engaged dungeon pull at every level", function()
        for level = 1, 60 do
            local H = warrior(level, 45, { instance = "party", group = 5, shout = true })
            H.Hekili:FireToggle("defensives", "off")
            local key = read(H)[1]
            assert.is_not_nil(key, "level " .. level)
            assert.is_true(H.Hekili.State:IsKnown(key), key .. " at level " .. level)
            assert.is_true(H.ctl.known[H.Hekili.Engine.Output.Primary.recs[1].actionID], key .. " at level " .. level)
        end
    end)

    it("favors Rend on short outdoor pulls while leveling solo or in a party", function()
        assert.are.equal("rend", read(warrior(10, 25), 1.6)[1])
        assert.are.equal("rend", read(warrior(10, 25, { group = 2 }), 1.6)[1])
    end)

    it("holds field melee and area attacks outside their range even when Rage and Victorious are available", function()
        local offensive = {
            heroic_strike = true,
            rend = true,
            victory_rush = true,
            sunder_armor = true,
            thunder_clap = true,
        }
        for _, level in ipairs({ 1, 10, 20, 60 }) do
            local H = warrior(level, 80, { instance = "party", group = 5, distance = 12, victorious = true })
            for _, key in ipairs(read(H)) do
                assert.is_nil(offensive[key], key .. " at level " .. level)
            end
        end
    end)

    it("treats ordinary dungeon enemies as short pulls and keeps armor stacking for elites and raids", function()
        local regular = warrior(15, 25, { group = 2, instance = "party" })
        assert.are.equal("rend", read(regular, 1.6)[1])
        for _, options in ipairs({
            { group = 2, instance = "party", classification = "elite" },
            { group = 2, raid = true },
        }) do
            local H = warrior(15, 25, options)
            assert.are.equal("sunder_armor", read(H, 1.6)[1])
            assert.is_false(H.Hekili.State.arms_open_world)
            assert.is_true(H.Hekili.State.arms_pve_target)
        end
    end)

    it("uses the same short-pull priority solo or in an outdoor party at level 60", function()
        local H = warrior(60, 35, { group = 2 })
        assert.are.same(read(warrior(60, 35)), read(H))
        assert.is_true(H.Hekili.State.arms_open_world)
    end)

    it("skips Rend on a Harvest Watcher before casting it", function()
        local H = warrior(14, 25, { target = HARVEST_WATCHER })
        assert.is_not_true(read(H, 1.6)[1] == "rend")
        assert.is_true(H.Hekili.State.arms_skip_rend)
    end)

    it("uses one Sunder Armor on a bleed-immune short pull before Mortal Strike is learned", function()
        local H = warrior(15, 35, { target = HARVEST_WATCHER, shout = true, health = SECRET, group = 2 })
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("sunder_armor", read(H)[1])
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-sunder", 7386)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-sunder", 7386)
        assert.are.equal("heroic_strike", read(H, 1.6)[1])
        assert.are.equal(1, H.Hekili.State.debuff.sunder_armor.stack)
    end)

    it("honors the same NPC immunity on another spawn and resumes after readable temporary protection", function()
        local H = warrior(14, 30, { target = HARVEST_WATCHER })
        local VS, ctl = H.ns.VirtualState, H.ctl
        assert.are.equal("immune NPC", VS.DebuffBlocked("rend", ctl.now))
        ctl.guid.target = "Creature-0-0-0-0-114-000002"
        H.Fire("PLAYER_TARGET_CHANGED")
        read(H)
        assert.are.equal("immune NPC", VS.DebuffBlocked("rend", ctl.now))
        ctl.guid.target = "Creature-0-0-0-0-999-000001"
        ctl.auras.target.HELPFUL[1] = { spellId = 20594, expirationTime = ctl.now + 8 }
        H.Fire("PLAYER_TARGET_CHANGED")
        read(H)
        assert.are.equal("temporary immunity", VS.DebuffBlocked("rend", ctl.now))
        assert.is_nil(VS.DebuffBlocked("sunder_armor", ctl.now))
        ctl.auraError.target = true
        H.Fire("UNIT_AURA", "target")
        read(H)
        assert.are.equal("temporary immunity", VS.DebuffBlocked("rend", ctl.now))
        ctl.auraError.target = false
        ctl.auras.target.HELPFUL[1] = nil
        H.Fire("UNIT_AURA", "target")
        read(H)
        assert.is_nil(VS.DebuffBlocked("rend", ctl.now))
    end)

    it("backs off Rend for the immune unit without treating an ordinary miss as immunity", function()
        for _, outcome in ipairs({ "IMMUNE", "MISS" }) do
            local H = warrior(13, 25)
            assert.are.equal("rend", read(H, 1.6)[1])
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-1", 6546)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 6546)
            H.Fire("UNIT_COMBAT", "target", outcome, "", 0, 1)
            local nextAction = read(H, 1.6)[1]
            assert.are.equal(outcome == "IMMUNE", H.Hekili.State.arms_skip_rend)
            if outcome == "IMMUNE" then
                assert.is_not_true(nextAction == "rend")
                H.ctl.guid.target = "Creature-2"
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.equal("rend", read(H)[1])
                H.ctl.guid.target = "Creature-1"
                H.Fire("PLAYER_TARGET_CHANGED")
                read(H)
                assert.is_true(H.Hekili.State.arms_skip_rend)
                read(H, 30)
                assert.is_true(H.Hekili.State.arms_skip_rend)
            else
                assert.are.equal("rend", nextAction)
            end
        end
    end)

    it("keeps Bloodrage and the Rend immunity rule when joining an outdoor party at level 15", function()
        local H = warrior(15, 12, { target = HARVEST_WATCHER, health = SECRET })
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("bloodrage", read(H)[1])
        H.ctl.groupMembers = 2
        H.Fire("GROUP_ROSTER_UPDATE")
        assert.are.equal("bloodrage", read(H)[1])
        assert.is_false(H.Hekili.State.solo)
        assert.is_true(H.Hekili.State.arms_skip_rend)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-bloodrage", 2687)
        H.ctl.cooldown[2687] = { isActive = true, isOnGCD = false }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.is_not_true(read(H)[1] == "bloodrage")
    end)

    it("holds Bloodrage when readable health is low or rage is already high", function()
        assert.are.equal("bloodrage", read(warrior(10, 5))[1])
        assert.is_not_true(read(warrior(10, 5, { health = 400 }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 5, { health = 400, group = 2 }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 5, { health = 400, group = 5, instance = "party" }))[1] == "bloodrage")
        assert.is_not_true(read(warrior(15, 40, { target = HARVEST_WATCHER, health = SECRET }))[1] == "bloodrage")
    end)

    it("uses learned Reckless Swings for low Rage after Bloodrage on a durable pull with health to spare", function()
        local function pick(options)
            options.instance, options.group, options.shout = "party", 5, true
            options.talents = options.talents or { { 1329555, 1, 2 } }
            local H = warrior(56, 5, options)
            if not options.bloodrageReady then
                H.ctl.cooldown[2687] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 60 }
                H.Fire("SPELL_UPDATE_COOLDOWN")
            end
            return read(H)[1]
        end
        assert.are.equal("reckless_swings", pick({ classification = "elite" }))
        assert.are.equal("bloodrage", pick({ classification = "elite", bloodrageReady = true }))
        assert.is_not_equal("reckless_swings", pick({ classification = "elite", health = SECRET }))
        assert.is_not_equal("reckless_swings", pick({ classification = "elite", health = 740 }))
        assert.is_not_equal("reckless_swings", pick({ classification = "elite", talents = {} }))
        assert.is_not_equal("reckless_swings", pick({ classification = "normal" }))
    end)

    it("takes Victory Rush at its level-20 unlock only with the kill proc", function()
        assert.are.equal("victory_rush", read(warrior(20, 35, { health = 600, victorious = true }), 1.6)[1])
        assert.are.equal("victory_rush", read(warrior(20, 35, { health = SECRET, victorious = true }), 1.6)[1])
        assert.is_not_true(read(warrior(20, 35, { health = 600 }), 1.6)[1] == "victory_rush")
        assert.is_not_true(read(warrior(19, 35, { health = 600, victorious = true }), 1.6)[1] == "victory_rush")
    end)

    it("opens outdoor pulls with Demoralizing Shout once trained, including with hidden health", function()
        for _, options in ipairs({ { shout = true }, { shout = true, group = 2, health = SECRET } }) do
            local H = warrior(14, 25, options)
            assert.are.equal("demoralizing_shout", read(H)[1])
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demo", 1160)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demo", 1160)
            assert.are.equal("rend", read(H, 1.6)[1])
            assert.is_true(H.Hekili.State.debuff.demoralizing_shout.up)
        end
    end)

    it("prioritizes Demoralizing Shout over damage on an outdoor multi-target pull", function()
        local H = warrior(30, 45, { shout = true, health = SECRET })
        H.Hekili:FireToggle("mode", "aoe")
        assert.are.equal("demoralizing_shout", read(H)[1])
        assert.is_true(H.Hekili.State.active_enemies >= 2)
    end)

    it("respects the spell requirements and player controls for Demoralizing Shout", function()
        for _, options in ipairs({
            { level = 13 },
            { rage = 5 },
            { distance = 20 },
            { group = 5, instance = "party" },
            { group = 5, raid = true },
            { instance = "pvp" },
        }) do
            options.shout = true
            local H = warrior(options.level or 14, options.rage or 25, options)
            assert.is_not_true(read(H)[1] == "demoralizing_shout")
        end
        local H = warrior(14, 25, { shout = true })
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("rend", read(H)[1])
    end)

    it("slows a humanoid as soon as it enters Execute range and skips an active Hamstring", function()
        for _, options in ipairs({
            { creature = "humanoid", shout = true },
            { creature = "humanoid", shout = true, group = 2 },
            { creature = "humanoid", shout = true, group = 5, instance = "party" },
        }) do
            local H = warrior(24, 35, options)
            H.ctl.unitHealth.target = SECRET
            H.ctl.unitHealthMax.target = SECRET
            assert.is_not_true(read(H)[1] == "hamstring")
            H.ctl.usable[5308] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.are.equal("hamstring", read(H)[1])
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-hamstring", 1715)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-hamstring", 1715)
            local nextAction = read(H, 1.6)[1]
            assert.is_true(H.Hekili.State.debuff.hamstring.up)
            assert.is_not_true(nextAction == "hamstring")
        end
    end)

    it("uses untalented Slam just after the main-hand swing and lifts that restriction with Improved Slam", function()
        local function withSlam(talents)
            local H = warrior(35, 35, { talents = talents, target = HARVEST_WATCHER, shout = true })
            H.ns.Output.steady = false
            H.Hekili:FireToggle("defensives", "off")
            read(H, 1.6)
            H.Fire("PLAYER_SWING", 3.6, 0)
            H.Fire("UNIT_COMBAT", "target", "WOUND", "", 40, 1)
            return H
        end
        local H = withSlam({})
        assert.are.equal("slam", read(H, 0.1)[1])
        local nextPick = read(H, 1)
        assert.is_false(nextPick[1] == "slam" and H.Hekili.Engine.Output.Primary.recs[1].time < 0.1)
        H = withSlam({ { 12862, 1, 1 } })
        assert.are.equal("slam", read(H, 1)[1])
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
    end)

    it("prioritizes learned Spearing Strike against Giants and Dragonkin", function()
        for _, creature in ipairs({ "giant", "dragonkin", "beast", SECRET }) do
            local H = warrior(30, 25, { creature = creature, shout = true, talents = { { 1310222, 1, 1 } } })
            H.Hekili:FireToggle("defensives", "off")
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-rend", 6548)
            assert.are.equal(creature == "giant" or creature == "dragonkin", read(H, 1.6)[1] == "spearing_strike")
        end
        for _, options in ipairs({
            { "unlearned", talents = {} },
            { "Defensive Stance", form = 2 },
            { "unarmed", unarmed = true },
            { "out of melee range", distance = 12 },
        }) do
            options.creature, options.shout = "dragonkin", true
            options.talents = options.talents or { { 1310222, 1, 1 } }
            local H = warrior(30, 25, options)
            H.Hekili:FireToggle("defensives", "off")
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-rend", 6548)
            assert.are_not.equal("spearing_strike", read(H, 1.6)[1], options[1])
        end
    end)

    it("swaps for Whirlwind only on a confirmed pack when the learned attack is affordable after the swap", function()
        local function pack(level, count, mastery, rage, form, shield)
            local H = warrior(level, rage or 35, {
                group = 5,
                instance = "party",
                shout = true,
                form = form,
                shield = shield,
                talents = { { 12295, mastery, 1 } },
            })
            for i = 2, count do
                local unit = "nameplate" .. i
                H.ctl.exists[unit], H.ctl.exists[unit .. "target"] = true, true
                H.ctl.guid[unit] = "Creature-0-0-0-0-347-00000" .. i
                H.ctl.unitCombat[unit], H.ctl.unitIs[unit .. "target"] = true, "player"
                H.ctl.distance[unit] = 3
                H.Fire("NAME_PLATE_UNIT_ADDED", unit)
            end
            H.Hekili:FireToggle("mode", "aoe")
            return H
        end
        assert.are.equal("berserker_stance", read(pack(36, 4, 3))[1])
        assert.are_not.equal("berserker_stance", read(pack(35, 4, 3))[1])
        assert.are_not.equal("berserker_stance", read(pack(36, 2, 3))[1])
        assert.are_not.equal("berserker_stance", read(pack(36, 4, 2))[1])
        assert.are_not.equal("berserker_stance", read(pack(36, 4, 3, 80))[1])
        local defensive = read(pack(36, 4, 3, 35, 2, true))
        for _, key in ipairs(defensive) do
            assert.is_false(key == "battle_stance" or key == "berserker_stance")
        end
        local disabled = pack(36, 4, 3)
        disabled.Hekili.Engine.settings.specs[ww.SPEC].abilities.whirlwind.disabled = true
        assert.are_not.equal("berserker_stance", read(disabled)[1])
        local H = pack(36, 4, 3, 25, 3)
        assert.are.equal("whirlwind", read(H)[1])
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-whirlwind", 1680)
        H.ctl.cooldown[1680] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 10 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.are.equal("battle_stance", read(H, 1.6)[1])
        H = pack(36, 2, 3, 25, 3)
        H.Hekili.DB.profile.specs[ww.SPEC].settings.wowsims_stance_dance = true
        H.Hekili:SettingsChanged()
        assert.are.equal("battle_stance", read(H)[1])
        assert.is_true(H.Hekili.State.settings.wowsims_stance_dance)
        H = pack(36, 4, 3, 80)
        H.Hekili.DB.profile.specs[ww.SPEC].settings.wowsims_stance_dance = true
        H.Hekili:SettingsChanged()
        assert.are_not.equal("berserker_stance", read(H)[1])
    end)

    it("uses the known Execute rank in Berserker Stance and waits until Hamstring is affordable", function()
        for _, rage in ipairs({ 5, 12 }) do
            local H = warrior(32, rage, { creature = "humanoid", form = 3, health = 600, shout = true })
            H.ctl.usable[20658] = { false, true }
            H.Fire("SPELL_UPDATE_USABLE")
            if rage == 12 then
                assert.are.equal("hamstring", read(H)[1])
            elseif read(H)[1] == "hamstring" then
                assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time > 0)
            end
        end
    end)

    it("skips Hamstring when the Execute window, target, or cast requirements cannot be confirmed", function()
        for _, options in ipairs({
            { "unlearned Execute", level = 23 },
            { "beast", creature = "beast" },
            { "secret creature type", creature = SECRET },
            { "unknown creature type", creature = "unknown" },
            { "boss", boss = true },
            { "out of melee range", distance = 20 },
            { "Defensive Stance", form = 2 },
            { "PvP", instance = "pvp" },
            { "unarmed", unarmed = true },
        }) do
            options.creature = options.creature or "humanoid"
            local H = warrior(options.level or 24, 35, options)
            H.ctl.usable[5308] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.is_not_true(read(H)[1] == "hamstring", options[1])
        end
    end)

    it("uses Shield Bash only with a shield and an interruptible cast in range", function()
        local H = warrior(12, 35, { shield = true })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_true(read(H)[1] == "shield_bash")

        H = warrior(12, 35, { shield = true, form = 2 })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])

        H = warrior(15, 35, { shield = true, group = 5, instance = "party" })
        hostileChannel(H, true)
        assert.are.equal("shield_bash", read(H)[1])

        for _, case in ipairs({
            { options = { shield = true }, interruptible = false },
            { options = { shield = true, distance = 20 }, interruptible = true },
            { options = {}, interruptible = true },
            { level = 30, options = { shield = true, form = 3 }, interruptible = true },
        }) do
            H = warrior(case.level or 12, 35, case.options)
            hostileChannel(H, case.interruptible)
            assert.is_not_true(read(H)[1] == "shield_bash")
        end
    end)

    it("slows a visibly moving hostile player and prioritizes Mortal Strike healing pressure", function()
        for _, instance in ipairs({ "pvp", "none" }) do
            local H = warrior(48, 45, { instance = instance, player = true, targetSpeed = 7, shout = true })
            assert.are.equal("hamstring", read(H)[1])
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-hamstring", 7372)
            assert.are.equal("mortal_strike", read(H, 1.6)[1])
        end
        for _, options in ipairs({
            { "stationary", targetSpeed = 0 },
            { "hidden speed", targetSpeed = SECRET },
            { "out of range", targetSpeed = 7, distance = 12 },
            { "unarmed", targetSpeed = 7, unarmed = true },
            { "Defensive Stance", targetSpeed = 7, form = 2 },
            { "untrained", targetSpeed = 7, level = 7 },
        }) do
            options.instance, options.player, options.shout = "pvp", true, true
            local H = warrior(options.level or 48, 45, options)
            local pick = read(H)[1]
            assert.are_not.equal("hamstring", pick, options[1])
            if options.distance or options.unarmed or options.level then
                assert.are_not.equal("mortal_strike", pick, options[1])
            else
                assert.are.equal("mortal_strike", pick, options[1])
            end
        end
    end)

    it("backs off an immune player's Hamstring for one Hamstring duration", function()
        local guid = "Player-1-00123456"
        local H = warrior(32, 45, { player = true, target = guid, targetSpeed = 7, shout = true })
        assert.are.equal("hamstring", read(H)[1])
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-hamstring", 7372)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-hamstring", 7372)
        H.Fire("UNIT_COMBAT", "target", "IMMUNE", "", 0, 1)
        assert.are_not.equal("hamstring", read(H, 1.6)[1])
        assert.are.equal("temporary immunity", H.ns.VirtualState.DebuffImmunity("hamstring", guid, H.ctl.now))
        assert.are.equal("hamstring", read(H, 15)[1])
        assert.is_nil(H.ns.VirtualState.DebuffImmunity("hamstring", guid, H.ctl.now))
    end)

    it("uses Pummel when already in Berserker Stance and respects the Interrupts toggle", function()
        local H = warrior(40, 35, { form = 3 })
        hostileChannel(H, true)
        assert.are.equal("pummel", read(H)[1])
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_true(read(H)[1] == "pummel")

        for _, form in ipairs({ 1, 2 }) do
            H = warrior(40, 35, { form = form })
            hostileChannel(H, true)
            assert.is_not_true(read(H)[1] == "pummel")
        end
    end)

    it("shows the leveling interrupt at the start of a normal cast, even with hidden cast timing", function()
        for _, case in ipairs({
            { level = 12, options = { shield = true }, action = "shield_bash" },
            { level = 38, options = { form = 3, instance = "party" }, action = "pummel" },
        }) do
            local H = warrior(case.level, 35, case.options)
            H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
            assert.are.equal(case.action, read(H)[1])
            assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
            H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
            assert.is_not_equal(case.action, read(H)[1])
        end
    end)

    it("offers a Healthstone at low health in solo and group PvE and respects Defensives", function()
        local H = warrior(60, 35, { health = 250, healthstone = true })
        assert.are.equal("healthstone", read(H, 1.6)[1])
        H.Hekili:FireToggle("defensives", "off")
        assert.is_not_true(read(H)[1] == "healthstone")

        H = warrior(60, 35, { health = 250, healthstone = true, group = 5, instance = "party" })
        assert.are.equal("healthstone", read(H, 1.6)[1])

        H = warrior(60, 35, { health = 250, healthstone = true, group = 5, instance = "pvp" })
        assert.is_not_true(read(H, 1.6)[1] == "healthstone")
    end)

    it("offers Shield Wall only with a shield and the appropriate stance", function()
        assert.are.equal("shield_wall", read(warrior(30, 35, { health = 240, shield = true, form = 2 }), 1.6)[1])
        assert.is_not_true(read(warrior(30, 35, { health = 240, form = 2 }), 1.6)[1] == "shield_wall")
        assert.is_not_true(read(warrior(30, 35, { health = 240, shield = true }), 1.6)[1] == "shield_wall")
    end)

    it("prepares a Primary Shield Wall cue with hidden HP without consuming a recommendation", function()
        local H = warrior(30, 35, { health = SECRET, shield = true, form = 2 })
        local out = H.Hekili.Engine.Output.Primary
        local picks = read(H, 1.6)
        assert.are.equal(1, out.healthCues.n)
        assert.are.equal(25, out.healthCues[1].percent)
        assert.are.equal(H.ns.Facade.C_Spell.GetSpellTexture(871), out.healthCues[1].texture)
        for _, action in ipairs(picks) do
            assert.is_not_equal("shield_wall", action)
        end

        H.ctl.cooldown[871] = { isActive = true, isOnGCD = false }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        read(H, 1.6)
        assert.are.equal(0, out.healthCues.n)

        H = warrior(30, 35, { health = SECRET, shield = true, form = 2 })
        H.Hekili:FireToggle("defensives", "off")
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)

        for _, options in ipairs({ { form = 2 }, { shield = true }, { form = 2, shield = true, instance = "pvp" } }) do
            options.health = SECRET
            H = warrior(30, 35, options)
            read(H, 1.6)
            assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
        end
    end)

    it("uses the strongest usable healing potion for early outdoor PvE and honors the item cooldown", function()
        local H = warrior(12, 35, { health = SECRET, potions = { [858] = 134830, [929] = 134831, [1710] = 134832 } })
        local out = H.Hekili.Engine.Output.Primary
        local picks = read(H, 1.6)
        assert.are.equal(1, out.healthCues.n)
        assert.are.same({ action = "healing_potion", percent = 40, texture = 134831 }, out.healthCues[1])
        assert.is_not_equal("healing_potion", picks[1])

        H.ctl.itemCount[929] = 0
        H.Fire("BAG_UPDATE_COOLDOWN")
        read(H, 1.6)
        assert.are.equal(134830, out.healthCues[1].texture)
        H.ctl.itemCooldown[858] = { H.ctl.now, 120 }
        H.Fire("BAG_UPDATE_COOLDOWN")
        read(H, 1.6)
        assert.are.equal(0, out.healthCues.n)

        local potions = { [118] = 134829 }
        assert.are.equal("healing_potion", read(warrior(1, 35, { health = 300, potions = potions }), 1.6)[1])
        H = warrior(12, 35, { health = SECRET, instance = "party", group = 5, potions = potions })
        read(H, 1.6)
        assert.are.equal("healing_potion", H.Hekili.Engine.Output.Primary.healthCues[1].action)
        for _, context in ipairs({ { level = 12, instance = "pvp" }, { level = 60, instance = "raid" } }) do
            H = warrior(context.level, 35, { health = SECRET, instance = context.instance, potions = potions })
            read(H, 1.6)
            assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
        end
    end)

    it("keeps the Last Stand talent, Retaliation pull, and Victory Rush proc requirements with hidden HP", function()
        local function primaryCue(H)
            read(H, 1.6)
            return H.Hekili.Engine.Output.Primary.healthCues[1]
        end
        local H = warrior(20, 35, { health = SECRET, lastStand = true })
        assert.are.equal("last_stand", primaryCue(H).action)
        H.ctl.cooldown[12975] = { isActive = true, isOnGCD = false }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)

        H = warrior(20, 35, { health = SECRET })
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
        H.Hekili:FireToggle("mode", "aoe")
        assert.are.equal("retaliation", primaryCue(H).action)
        H.Hekili:FireToggle("cooldowns", "off")
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)

        H = warrior(20, 35, { health = SECRET, victorious = true, instance = "party" })
        assert.are.equal("victory_rush", primaryCue(H).action)
        H = warrior(20, 35, { health = SECRET, instance = "party" })
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
    end)

    it("keeps higher priority health cues and covers the remaining HP range with the next eligible action", function()
        local H = warrior(30, 35, {
            health = SECRET,
            healthstone = true,
            shield = true,
            form = 2,
            group = 2,
            potions = { [929] = 134831 },
        })
        read(H, 1.6)
        local cues = H.Hekili.Engine.Output.Primary.healthCues
        assert.are.equal(2, cues.n)
        assert.are.same({ action = "healthstone", percent = 30, texture = 538745 }, cues[1])
        assert.are.same({ action = "healing_potion", percent = 40, texture = 134831 }, cues[2])
        H.Hekili:FireToggle("defensives", "off")
        read(H, 1.6)
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.healthCues.n)
    end)

    it("requires a melee weapon for Heroic Strike, Rend, Sunder Armor, and Hamstring", function()
        local H = warrior(15, 35, { unarmed = true })
        read(H)
        for _, key in ipairs({ "heroic_strike", "rend", "sunder_armor", "hamstring" }) do
            assert.is_false((H.Hekili.State:IsUsable(key)), key)
        end
    end)

    it("uses a ready Overpower in Battle Stance with a melee weapon", function()
        for _, options in ipairs({ {}, { unarmed = true }, { form = 2 } }) do
            options.target = HARVEST_WATCHER
            local H = warrior(13, 35, options)
            H.ctl.usable[7384] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.are.equal(not options.unarmed and not options.form, read(H)[1] == "overpower")
        end
    end)

    it("respects the stance combinations for Rend, Thunder Clap, Hamstring, and Retaliation", function()
        for _, form in ipairs({ 1, 2, 3 }) do
            local H = warrior(30, 35, { form = form })
            read(H)
            local state = H.Hekili.State
            assert(state.reset())
            local function ready(key)
                return state:IsUsable(key) and state:TimeToReady(key) < 1
            end
            assert.are.equal(form ~= 3, ready("rend"))
            assert.are.equal(form ~= 3, ready("thunder_clap"))
            assert.are.equal(form ~= 2, ready("hamstring"))
            assert.are.equal(form == 1, ready("retaliation"))
        end
    end)
end)
