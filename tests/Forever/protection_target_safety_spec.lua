local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warrior, read, cast = fixture.warrior, fixture.read, fixture.cast

local offensive = {}
for _, action in ipairs({
    "auto_attack",
    "charge",
    "reckless_swings",
    "shield_slam",
    "revenge",
    "execute",
    "thunder_clap",
    "demoralizing_shout",
    "rend",
    "sunder_armor",
    "heroic_strike",
    "cleave",
    "bloodthirst",
    "mortal_strike",
    "victory_rush",
    "death_wish",
    "sweeping_strikes",
    "retaliation",
    "blood_fury",
    "berserking",
    "eureka",
    "elunes_light",
}) do
    offensive[action] = true
end

local function boot(level, rage, options)
    local H = warrior(level, rage, options)
    H.ns.Output.steady = false
    return H
end

local function noOffense(H, context)
    read(H, 0.2)
    local out = H.Hekili.Engine.Output.Primary
    for i = 1, out.count do
        local action = out.recs[i].actionName
        assert.is_not_true(offensive[action], (context or "target") .. ": " .. tostring(action))
    end
end

local function addAttacker(H, options)
    options = options or {}
    local ctl = H.ctl
    ctl.exists.nameplate1 = true
    ctl.guid.nameplate1 = options.guid or "Creature-0-0-0-0-347-000003"
    ctl.exists.nameplate1target = true
    ctl.unitIs.nameplate1target = options.victim or "player"
    ctl.distance.nameplate1 = options.distance or 4
    ctl.creature.nameplate1 = options.creature
    ctl.unitCombat.nameplate1 = options.combat == nil and true or options.combat
    ctl.friendly.nameplate1, ctl.dead.nameplate1, ctl.isPlayer.nameplate1 =
        options.friendly, options.dead, options.player
    H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end

describe("Protection target and melee-pressure safety", function()
    for _, instance in ipairs({ "none", "party", "raid" }) do
        it("never uses an invalid target to enter offensive priorities in " .. instance, function()
            for _, invalid in ipairs({
                { key = "dead", value = true },
                { key = "friendly", value = true },
                { key = "exists", value = false },
                { key = "exists", value = SECRET },
                { key = "friendly", value = SECRET },
                { key = "isPlayer", value = SECRET },
            }) do
                local H = boot(59, 20, {
                    instance = instance,
                    group = instance == "none" and 0 or instance == "raid" and 10 or 5,
                    threat = 3,
                    classification = "elite",
                    talents = { [23922] = 1, [1329555] = 1 },
                })
                H.Hekili:FireToggle("cooldowns", "on")
                H.Hekili:FireToggle("defensives", "off")
                H.ctl[invalid.key].target = invalid.value
                H.Fire("PLAYER_TARGET_CHANGED")
                noOffense(H, invalid.key)
                H.Hekili.State.reset("Primary")
                assert.is_false(H.Hekili.State.prot_reckless_safe, invalid.key)
            end
        end)
    end

    it("practices the raid priority on a hostile training dummy", function()
        local H = boot(60, 35, { target = "Creature-0-0-0-0-4952-000001", revenge = true })
        H.Hekili:FireToggle("defensives", "off")
        assert.are.equal("revenge", read(H, 0.2))
        H.Hekili.State.reset("Primary")
        assert.is_true(H.Hekili.State.target.is_dummy)
        assert.is_true(H.Hekili.State.prot_sustained)
        assert.is_false(H.Hekili.State.prot_contextual)
        H.ctl.friendly.target = true
        H.Fire("PLAYER_TARGET_CHANGED")
        noOffense(H, "friendly practice target")
    end)

    it("uses trained melee attacks against hostile players already fighting", function()
        local function opponent(level, rage, options)
            options.instance = options.instance or "pvp"
            local H = boot(level, rage, options)
            H.ctl.isPlayer.target = true
            H.Fire("PLAYER_TARGET_CHANGED")
            return H
        end
        assert.are.equal("heroic_strike", read(opponent(1, 18, {})))
        assert.are.equal("victory_rush", read(opponent(20, 20, { victorious = true, revenge = true })))
        assert.are.equal("revenge", read(opponent(40, 5, { revenge = true })))
        assert.are.equal("shield_slam", read(opponent(40, 30, { talents = { [23922] = 1 } })))
        local H = opponent(24, 20, { form = 1, instance = "none" })
        H.ctl.usable[5308] = { true, false }
        assert.are.equal("execute", read(H))
        H = opponent(24, 20, { form = 2 })
        H.ctl.usable[5308] = { true, false }
        assert.is_not_equal("execute", read(H))
        assert.is_not_equal("shield_slam", read(opponent(40, 30, { noShield = true })))
        assert.is_not_equal("revenge", read(opponent(40, 5, { revenge = true, noWeapon = true })))
        for _, options in ipairs({
            { distance = 12 },
            { prepull = true },
            { idleTarget = true },
            { instance = "party" },
            { instance = "raid" },
        }) do
            options.victorious, options.revenge, options.talents = true, true, { [23922] = 1 }
            noOffense(opponent(40, 35, options), "PvP eligibility")
        end
    end)

    it("holds Charge, Attack and damage on idle dungeon targets both before and during another fight", function()
        for _, prepull in ipairs({ true, false }) do
            for _, distance in ipairs({ 3, 20 }) do
                local H = boot(46, 35, {
                    instance = "party",
                    group = 5,
                    prepull = prepull,
                    idleTarget = true,
                    autoAttack = false,
                    distance = distance,
                    talents = { [1310317] = 1, [23922] = 1 },
                })
                H.Hekili:FireToggle("defensives", "off")
                noOffense(H, "idle dungeon target")
            end
        end
    end)

    it("does not join an unrelated NPC fight merely because a solo dungeon target is in combat", function()
        for _, prepull in ipairs({ true, false }) do
            for _, distance in ipairs({ 3, 20 }) do
                local H = boot(46, 35, {
                    instance = "party",
                    group = 0,
                    prepull = prepull,
                    engaged = true,
                    targetVictim = "nameplate2",
                    autoAttack = false,
                    distance = distance,
                    talents = { [1310317] = 1, [23922] = 1 },
                })
                H.Hekili:FireToggle("defensives", "off")
                noOffense(H, "unrelated NPC fight")
            end
        end
    end)

    it("can join an engaged dungeon enemy with the learned Charge rank at levels 26 and 46", function()
        for _, rank in ipairs({
            { level = 26, normal = 6178, vanguard = 1240288 },
            { level = 46, normal = 11578, vanguard = 1240289 },
        }) do
            for _, vanguard in ipairs({ false, true }) do
                local H = boot(rank.level, 35, {
                    instance = "party",
                    group = 5,
                    prepull = true,
                    engaged = true,
                    targetVictim = "party1",
                    autoAttack = false,
                    form = vanguard and 2 or 1,
                    distance = 20,
                    talents = vanguard and { [1310317] = 1 } or {},
                })
                assert.are.equal("charge", read(H, 0.2))
                local id = vanguard and rank.vanguard or rank.normal
                assert.are.equal(id, H.ns.VirtualState.KnownID(100))
                assert.is_true(H.ctl.known[id])
                assert.is_not_true(H.ctl.known[vanguard and rank.normal or rank.vanguard])
                H.ctl.distance.target = 3
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.equal("auto_attack", read(H, 0.2))
                H.ctl.current[6603], H.ctl.combat, H.ctl.form = true, true, 2
                H.Fire("UPDATE_SHAPESHIFT_FORM")
                H.Fire("PLAYER_REGEN_DISABLED")
                H.Hekili:FireToggle("defensives", "off")
                assert.is_true(offensive[read(H, 0.2)])
            end
        end
    end)

    it("allows selected outdoor openers in both solo and party play", function()
        for _, group in ipairs({ 0, 2 }) do
            local H = boot(26, 0, {
                group = group,
                prepull = true,
                engaged = false,
                autoAttack = false,
                distance = 20,
                talents = { [1310317] = 1 },
            })
            assert.are.equal("charge", read(H, 0.2))
            H.ctl.distance.target = 3
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.equal("auto_attack", read(H, 0.2))
        end
    end)

    it("does not infer dungeon engagement from a hidden target-combat answer", function()
        local H = boot(26, 25, {
            instance = "party",
            group = 5,
            engaged = SECRET,
            autoAttack = false,
            distance = 3,
            talents = { [1310317] = 1 },
        })
        noOffense(H)
    end)

    it("uses Shield Block for a nearby melee attacker while the selected enemy casts", function()
        local H = boot(28, 10, { instance = "party", group = 5, threat = 3, demo = true, bashCooldown = true })
        addAttacker(H)
        cast(H, false)
        assert.are.equal("shield_block", read(H, 0.2))
        assert.are.equal(0, H.Hekili.Engine.Output.Primary.recs[1].time)
        H.Hekili.State.reset("Primary")
        assert.is_true(H.Hekili.State.prot_melee_target)
        assert.is_true(H.Hekili.State.prot_dump_reserve >= H.Hekili.State.action.shield_block.cost)
        H.ctl.exists.nameplate1 = false
        H.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
        assert.is_not_equal("shield_block", read(H, 0.2))
    end)

    it(
        "does not mistake the selected caster's readable nameplate for another attacker when its target GUID is hidden",
        function()
            local H = boot(28, 10, { instance = "party", group = 5, threat = 3, demo = true, bashCooldown = true })
            local targetGUID = H.ctl.guid.target
            H.ctl.guid.target = SECRET
            addAttacker(H, { guid = targetGUID })
            H.ctl.unitIs.nameplate1 = "target"
            -- Identity became unreadable without a target change. The target-token cast events remain usable and
            -- must still suppress selected-target melee pressure; this plate cannot prove a distinct second enemy.
            cast(H, false)
            assert.is_not_equal("shield_block", read(H, 0.2))
            local state = H.Hekili.State
            state.reset("Primary")
            assert.is_true(state.debuff.casting.up)
            assert.is_nil(H.ns.Facade.UnitGUID("target"))
            assert.are.equal(targetGUID, H.ns.Facade.UnitGUID("nameplate1"))
            assert.are.equal(1, state.prot_nearby_enemies)
            assert.is_false(state.prot_melee_target)
        end
    )

    it("requires positive melee pressure on the player for the extra Shield Block cue", function()
        for _, options in ipairs({
            { distance = 12 },
            { distance = SECRET },
            { combat = false },
            { combat = SECRET },
            { guid = SECRET },
            { friendly = true },
            { dead = true },
            { player = true },
            { creature = "elemental" },
            { victim = "party1" },
            { victim = SECRET },
        }) do
            local H = boot(28, 10, { instance = "party", group = 5, threat = 3, demo = true, bashCooldown = true })
            addAttacker(H, options)
            if options.creature == "elemental" then
                local creatureType = H.ns.Facade.UnitCreatureType
                H.ns.Facade.UnitCreatureType = function(unit)
                    local name, id = creatureType(unit)
                    return unit == "nameplate1" and "Elementar" or name, id
                end
            end
            cast(H, false)
            assert.is_not_equal("shield_block", read(H, 0.2))
            H.Hekili.State.reset("Primary")
            assert.is_false(H.Hekili.State.prot_melee_target)
        end
    end)
end)
