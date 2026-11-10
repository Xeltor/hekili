local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local ws = require("Forever.helpers.wowsims")
local world = require("Forever.helpers.warrior_world")
local prot = require("Forever.helpers.protection_gate")

local PACK = "Protection (wowsims.com)"
local CASTER = "Creature-0-0-0-0-346-000001"
local KIT = {}
for i, key in ipairs(prot.KIT) do
    KIT[i] = key
end
KIT[#KIT + 1] = "concussion_blow"
KIT[#KIT + 1] = "disarm"
KIT[#KIT + 1] = "last_stand"

local function warrior(level, rage, options)
    options = options or {}
    local character = ws.content(world.Protection, {
        level = level,
        learn = ws.learn("WARRIOR"),
        kit = KIT,
    }).character()
    character.talents = options.talents or {}
    local talentSpells = { 12809, 12975, 23922, 1310317 }
    for _, spell in ipairs(talentSpells) do
        if character.talents[spell] then
            character.known[#character.known + 1] = spell
        end
    end
    character.form = options.form or (level >= 10 and 2 or 1)
    character.power.value = rage
    character.instanceType = options.instance
    character.ranges = { [100] = { 8, 25 }, [1240287] = { 8, 25 } }
    local hasVanguard = character.talents[1310317]
    for i = #character.known, 1, -1 do
        local spell = character.known[i]
        if (not hasVanguard and spell >= 1240287 and spell <= 1240289) or (hasVanguard and spell == 100) then
            table.remove(character.known, i)
        end
    end
    if options.noShield then
        character.items = world.character().items
    end
    local H = headless.new({ character = character, pack = options.pack or PACK })
    local ctl = H.ctl
    assert.are.same({}, H.loadErrors)
    ctl.distance.target = options.distance or 3
    ctl.guid.target = options.target or ctl.guid.target
    ctl.creature.target = options.creature
    ctl.classification = options.classification
    ctl.groupMembers = options.group or 0
    ctl.level.target = options.boss and -1 or level
    ctl.unitHealth.player = options.health or 1000
    ctl.auras.player.HELPFUL[1] = { spellId = 6673, expirationTime = ctl.now + 100, applications = 0 }
    if options.victorious then
        ctl.auras.player.HELPFUL[2] = { spellId = 402975, expirationTime = ctl.now + 20, applications = 0 }
    end
    for _, rank in ipairs({ 6572, 6574, 7379, 11600, 11601, 25288 }) do
        ctl.usable[rank] = options.revenge and { true, false } or { false, false }
    end
    if options.potion then
        ctl.itemCount[118] = 1
        ctl.items[118] = { "Minor Healing Potion", nil, 134829 }
    end
    if options.bashCooldown then
        local rank = ctl.known[1671] and 1671 or 72
        local cd = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 12 }
        ctl.cooldown[72], ctl.cooldown[rank] = cd, cd
    end
    if not options.bloodrageReady then
        ctl.cooldown[2687] = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 60 }
    end
    H.Fire("UNIT_AURA", "player")
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, ctl.now + 0.2))
    if not options.prepull then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    if options.demo then
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demo", 1160)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demo", 1160)
    end
    local VS = H.ns.VirtualState
    local power, pool = VS.Power, { est = rage, lo = rage, hi = rage, conf = 1 }
    VS.Power = function(pt, now)
        return pt == 1 and pool or power(pt, now)
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 1.6)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    return out.count > 0 and out.recs[1].actionName or nil
end

local function cast(H, interruptible)
    H.Fire("UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
    if not interruptible then
        H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
    end
end

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

    it("puts a ready Shield Bash first as a cast begins in solo and party PvE", function()
        for _, options in ipairs({ {}, { instance = "party", group = 5 } }) do
            local H = warrior(12, 15, options)
            cast(H, true)
            local action = read(H, 0.2)
            local out = H.Hekili.Engine.Output.Primary
            assert.are.equal("shield_bash", action)
            assert.are.equal(0, out.recs[1].time)
            H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
            assert.is_not_equal("shield_bash", read(H, 0.2))
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
        assert.are.equal("shield_bash", read(H, 0.2))
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
        read(H, 0.2)
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

    it("lets dungeon threat spend the reserve on the opener or when aggro is lost", function()
        local H = warrior(40, 20, { target = CASTER, group = 5, instance = "party", talents = { [23922] = 1 } })
        H.Hekili:FireToggle("defensives", "off")
        cast(H, true)
        read(H, 0.2)
        H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
        assert.are.equal("shield_slam", read(H, 0.2))
        assert.is_not_equal("shield_slam", read(H, 4))
        assert.are.equal(10, H.Hekili.State.prot_bash_reserve)

        H.ctl.exists.targettarget = true
        H.ctl.unitIs.targettarget = "party1"
        assert.are.equal("shield_slam", read(H, 0.2))
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
            local action = read(H, 0.2)
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
            local H = warrior(18, 25, options)
            if options.group then
                H.Hekili:FireToggle("mode", "aoe")
            end
            assert.is_true(H.Hekili.State:IsKnown("disarm"))
            assert.is_false(H.Hekili.State.prot_disarm_target) -- old priorities still resolve this condition
            for _ = 1, 3 do
                assert.are.equal("demoralizing_shout", read(H, 0.2))
                local out = H.Hekili.Engine.Output.Primary
                for i = 1, out.count do
                    assert.is_not_equal("disarm", out.recs[i].actionName)
                end
            end
            for _, list in pairs(H.Hekili.DB.profile.packs[PACK].lists) do
                for _, entry in ipairs(list) do
                    assert.is_not_equal("disarm", entry.action)
                    assert.is_not_equal("taunt", entry.action)
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
            local H = warrior(16, 25, { group = group })
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
    end)
end)
