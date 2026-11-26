local fixture = require("Forever.helpers.paladin_protection")
local secret = require("Game.State.helpers.fake_api").SECRET

describe("Protection Paladin tank recovery", function()
    local fury, righteousness, judgement, swift, strike, ground = 1311649, 20154, 20271, 1310994, 679, 26573

    local function member(H, token, role, health)
        local c = H.ctl
        c.exists[token], c.isPlayer[token], c.groupRoles[token] = true, true, role
        c.unitHealth[token], c.unitHealthMax[token] = health or 1000, 1000
    end

    local function victim(H, mob, target, threat)
        local c, token = H.ctl, mob .. "target"
        c.threat[mob], c.unitIs[token], c.exists[token] = threat, target, true
        c.inParty[token] = target:match("^party%d+$") ~= nil
        c.inRaid[token] = tonumber(target:match("^raid(%d+)$"))
    end

    local function plate(H, index, target, threat)
        local c, unit = H.ctl, "nameplate" .. index
        c.exists[unit], c.unitCombat[unit] = true, true
        c.guid[unit], c.level[unit], c.distance[unit] = "Creature-0-0-0-0-347-00000" .. index, 30, 3
        victim(H, unit, target, threat)
        H.Fire("NAME_PLATE_UNIT_ADDED", unit)
        return unit
    end

    local function selectPlate(H, unit, restricted)
        local c = H.ctl
        c.unitIs.nameplate1, c.unitIs.nameplate2 = nil, nil
        c.guid.target, c.unitIs.target, c.unitIs[unit] = c.guid[unit], unit, "target"
        c.unitCombat.target, c.distance.target = true, c.distance[unit]
        victim(H, "target", c.unitIs[unit .. "target"], c.threat[unit])
        if restricted then
            c.guid.target, c.guid[unit], c.threat.target, c.unitIs.targettarget = secret, secret, secret, secret
            c.exists.targettarget, c.distance.target = secret, secret
        end
        H.Fire("PLAYER_TARGET_CHANGED")
    end

    local function pull(o)
        o = o or {}
        local H = fixture.paladin(30, o.mana or 1000, {
            known = o.known or { 6603, judgement, swift, strike, fury, righteousness, ground },
            buffs = { o.seal or fury },
            group = o.group or 5,
            instance = o.instance or "party",
            role = o.role or "TANK",
            swaps = o.swaps ~= false,
        })
        H.ns.Output.steady = false
        H.ns.getNumberTargets = function()
            return 3, 3
        end
        local target = o.instance == "raid" and "raid12" or "party1"
        member(H, target, "HEALER", o.health)
        local loose = plate(H, 1, target, 0)
        local held = plate(H, 2, "player", 3)
        if not o.groundReady then
            H.ctl.cooldown[ground] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 20 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
        end
        return H, loose, held, target
    end

    local function first(H)
        local action = fixture.read(H)
        return action, H.Hekili.Engine.Output.Primary.recs[1].indicator
    end

    local function show(H)
        local display = H.env.HekiliDisplayPrimary
        display:UpdateAlpha()
        display.__scripts.OnUpdate(display, 0.2)
        assert.is_true(display.Buttons[1].swapShown)
    end

    local function cast(H, id, name, recipient)
        H.Fire("UNIT_SPELLCAST_SENT", "player", recipient or H.ctl.names.target or "Unit", name, id)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", name, id)
    end

    it(
        "casts affordable Consecration from the held enemy, then switches when the ground cannot settle the pack",
        function()
            local H, loose, held = pull({ groundReady = true })
            assert.are.equal("consecration", first(H))
            H.ctl.cooldown[ground] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 8 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            show(H)
            selectPlate(H, held)
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            show(H)
            selectPlate(H, loose)
            assert.are.equal("holy_strike", first(H))
            assert.is_nil(H.Hekili.Engine.Output.status.targetNavigation)
        end
    )

    it("can pick up a melee enemy with Consecration while single-target recovery sees crowd control", function()
        local H = pull({ groundReady = true })
        H.ctl.distance.target = 9
        local before = H.ns.Facade.DebuffCount
        H.ns.Facade.DebuffCount = function(spell, time)
            if spell == 1324543 then
                return 1
            end
            return before(spell, time)
        end
        assert.are.equal("consecration", first(H))
    end)

    it("can recover a dungeon enemy identified by a matched nameplate", function()
        local H, loose, held = pull()
        H.ctl.guid[loose], H.ctl.guid[held] = secret, secret
        selectPlate(H, held, true)
        assert.are.same({ "recover_threat", "cycle" }, { first(H) })
        show(H)
        selectPlate(H, loose, true)
        assert.are.equal("holy_strike", first(H))
    end)

    it(
        "continues past an enemy attacking a healthy party member when another is attacking a critical healer",
        function()
            local H, loose, intermediate = pull({ health = 230 })
            member(H, "party2", "DAMAGER", 850)
            victim(H, intermediate, "party2", 0)
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            show(H)
            selectPlate(H, intermediate)
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            show(H)
            selectPlate(H, loose)
            assert.are.equal("judgement", first(H))
        end
    )

    it("does not seek a critical ranged enemy using an ordinary loose enemy's melee reach", function()
        local H, loose, intermediate = pull({
            health = 230,
            mana = 5,
            known = { 6603, strike, fury, judgement },
        })
        member(H, "party2", "DAMAGER", 800)
        victim(H, intermediate, "party2", 0)
        H.ctl.distance[loose] = 9
        assert.are_not.equal("recover_threat", first(H))
        selectPlate(H, intermediate)
        assert.are.equal("holy_strike", first(H))
    end)

    it("reverses from an idle landing without publishing a damaging spell", function()
        local H = pull()
        assert.are.same({ "recover_threat", "cycle" }, { first(H) })
        show(H)
        H.ctl.unitCombat.target, H.ctl.guid.target = false, "Creature-idle"
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.is_nil(fixture.read(H))
        assert.are.equal("cycle_previous", H.Hekili.Engine.Output.status.targetNavigation)
    end)

    it("offers Consecration and holds targeted recovery spells on a controlled selection", function()
        local H, loose = pull({ groundReady = true, health = 180 })
        selectPlate(H, loose)
        fixture.read(H)
        H.ctl.auras.target.HARMFUL = {
            {
                spellId = 1324538,
                expirationTime = H.ctl.now + 6,
                duration = 6,
                applications = 1,
                sourceUnit = "player",
            },
        }
        H.Fire("UNIT_AURA", "target")
        assert.are.equal("consecration", fixture.read(H))
        H.ctl.cooldown[ground] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 20 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        assert.is_nil(fixture.read(H))
    end)

    it("honors party roles, the existing swap toggle, and raid tank assignments", function()
        for _, situation in ipairs({
            "disabled",
            "damage",
            "co-tank",
            "dead groupmate",
            "idle",
            "single",
            "boss encounter",
        }) do
            local H, loose, _, target = pull({
                role = situation == "damage" and "DAMAGER" or "TANK",
                swaps = situation ~= "disabled",
                instance = situation == "boss encounter" and "raid" or "none",
            })
            if situation == "co-tank" then
                H.ctl.mainTank[target] = true
            elseif situation == "dead groupmate" then
                H.ctl.dead[target] = true
            elseif situation == "idle" then
                H.ctl.unitCombat[loose] = false
            elseif situation == "single" then
                H.Hekili:FireToggle("mode", "single")
            elseif situation == "boss encounter" then
                H.ctl.encounterInProgress = true
            end
            assert.are_not.equal("recover_threat", first(H), situation)
        end
        local H = pull({ instance = "raid", group = 20 })
        assert.are.same({ "recover_threat", "cycle" }, { first(H) }, "explicit raid tank and a healer outside subgroup")
        H = pull({ instance = "none", role = "NONE" })
        assert.are.same({ "recover_threat", "cycle" }, { first(H) }, "unassigned outdoor tank holding the pull")
    end)

    it("holds Fury Judgement until subsequent real strikes leave the same groupmate exposed", function()
        local H, loose = pull()
        selectPlate(H, loose)
        assert.are.equal("holy_strike", first(H))
        cast(H, strike, "Cast-1")
        fixture.read(H, 10)
        assert.is_false(H.Hekili.State.prot_paladin_last_resort)
        cast(H, strike, "Cast-2")
        fixture.read(H, 1.4)
        assert.is_false(H.Hekili.State.prot_paladin_last_resort)
        assert.are.equal("judgement", fixture.read(H, 0.2))
        cast(H, judgement, "Cast-fury")
        fixture.read(H)
        assert.is_false(H.Hekili.State.prot_paladin_last_resort)
    end)

    it("recognizes a higher-rank damage seal as a real attempt and higher-rank Fury as the rescue", function()
        local highRight, highFury = 20287, 20163
        local H, loose = pull({
            seal = highRight,
            known = { 6603, strike, judgement, righteousness, 21084, highRight, fury, 1311656, highFury },
        })
        selectPlate(H, loose)
        first(H)
        assert.is_truthy(H.ns.Facade.C_UnitAuras.GetPlayerAuraBySpellID(righteousness))
        cast(H, judgement, "Cast-damage")
        fixture.read(H, 1.6)
        cast(H, strike, "Cast-builder")
        assert.are.equal("seal_of_fury", fixture.read(H, 1.6))
        H.ctl.auras.player.HELPFUL = {
            { spellId = highFury, expirationTime = H.ctl.now + 30, applications = 1, sourceUnit = "player" },
        }
        H.Fire("UNIT_AURA", "player")
        fixture.read(H)
        assert.is_truthy(H.ns.Facade.C_UnitAuras.GetPlayerAuraBySpellID(fury))
        cast(H, judgement, "Cast-rescue")
        fixture.read(H)
        assert.is_false(H.Hekili.State.prot_paladin_last_resort)
    end)

    it("counts Holy Shock only when its named recipient can be confirmed as the loose enemy", function()
        local shock = 1311606
        local H, loose, _, healer = pull({ known = { 6603, judgement, strike, fury, shock } })
        selectPlate(H, loose)
        H.ctl.names.target, H.ctl.names[healer] = "Defias Raider", "Healer"
        first(H)
        cast(H, strike, "Cast-strike")
        for _, recipient in ipairs({ secret, "Healer", "Player" }) do
            cast(H, shock, "Cast-heal", recipient)
            assert.are_not.equal("judgement", fixture.read(H, 1.6))
        end
        H.ctl.names[healer] = "Defias Raider"
        cast(H, shock, "Cast-ambiguous")
        assert.are_not.equal("judgement", fixture.read(H, 1.6))
        H.ctl.names[healer] = "Healer"
        cast(H, shock, "Cast-hostile")
        assert.are.equal("judgement", fixture.read(H, 1.6))
    end)

    it("can immediately rescue a critically injured healer and prepare the seal when necessary", function()
        for _, seal in ipairs({ fury, righteousness }) do
            local H, loose = pull({ groundReady = true, health = 240, seal = seal })
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            selectPlate(H, loose)
            assert.are.equal(seal == fury and "judgement" or "seal_of_fury", first(H))
        end
    end)

    it("can pick up a fleeing enemy within Judgement range and checks the actual destination range", function()
        for _, seal in ipairs({ fury, righteousness }) do
            local H, loose = pull({ groundReady = true, health = seal == fury and 240 or 900, seal = seal })
            H.ctl.distance[loose] = 9
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            selectPlate(H, loose)
            assert.are.equal("judgement", first(H))
        end
        local H, loose = pull({ health = 200 })
        H.ctl.distance[loose] = 15
        assert.are_not.equal("recover_threat", first(H), "no ranged pickup outside confirmed Judgement reach")
    end)

    it("uses Swift Judgement when a ranged pickup or a last-resort taunt needs it", function()
        for _, seal in ipairs({ righteousness, fury }) do
            local H, loose = pull({ health = seal == fury and 200 or 900, seal = seal })
            H.ctl.distance[loose] = 9
            H.ctl.cooldown[judgement] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 10 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            selectPlate(H, loose)
            assert.are.equal("swift_judgement", first(H))
        end
    end)

    it("can check a Swift-only ranged rescue with a learned hostile ten-yard probe", function()
        for _, probe in ipairs({ false, true }) do
            local known = { 6603, swift, strike, fury }
            if probe then
                known[#known + 1] = 853
            end
            local H, loose = pull({ health = 220, known = known })
            H.ctl.ranges[853], H.ctl.distance[loose] = { 0, 10 }, 9
            local action = first(H)
            if probe then
                assert.are.equal("recover_threat", action)
                selectPlate(H, loose)
                assert.are.equal("swift_judgement", first(H))
            else
                assert.are_not.equal("recover_threat", action)
            end
        end
    end)

    it("requires mana for both a new Fury seal and its emergency Judgement", function()
        local H, loose = pull({
            mana = 43,
            health = 230,
            seal = righteousness,
            known = { 6603, strike, fury, righteousness, judgement },
        })
        selectPlate(H, loose)
        assert.are.equal("holy_strike", first(H))
        assert.is_false(H.Hekili.State.prot_paladin_prepare_taunt)
    end)

    it("keeps the damage seal when a last-resort seal and Judgement cannot be completed", function()
        for _, situation in ipairs({ "seal alone affordable", "Judgement cooling" }) do
            local H, loose, _, healer = pull({
                mana = situation == "seal alone affordable" and 43 or 1000,
                health = 230,
                seal = righteousness,
                known = { 6603, fury, righteousness, judgement },
            })
            if situation == "Judgement cooling" then
                H.ctl.cooldown[judgement] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 10 }
                H.Fire("SPELL_UPDATE_COOLDOWN")
            end
            selectPlate(H, loose)
            local action = fixture.read(H)
            if action then
                assert.are.equal("judgement", action, situation)
                assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time > 0, situation)
            end
            assert.is_true(H.Hekili.State.prot_paladin_last_resort, situation)
            assert.is_false(H.Hekili.State.prot_paladin_prepare_taunt, situation)
            -- Recovery urgency has passed. Fury can again build ordinary threat on weapon hits.
            H.ctl.unitHealth[healer] = 800
            H.Fire("UNIT_HEALTH", healer)
            assert.are.equal("seal_of_fury", fixture.read(H), situation)
        end
    end)

    it(
        "withholds emergency Judgement when mana is low, health is hidden, the boss is on a co-tank, or swaps are off",
        function()
            for _, situation in ipairs({ "low mana", "hidden health", "co-tank", "disabled" }) do
                local H, loose, _, target = pull({
                    mana = situation == "low mana" and 0 or 1000,
                    health = situation == "hidden health" and secret or situation == "low mana" and 1000 or 200,
                    swaps = situation ~= "disabled",
                    instance = situation == "co-tank" and "raid" or "party",
                })
                if situation == "co-tank" then
                    H.ctl.groupRoles[target], H.ctl.encounterInProgress = "TANK", true
                end
                selectPlate(H, loose)
                local action = first(H)
                assert.are_not.equal("judgement", action, situation)
                assert.are_not.equal("swift_judgement", action, situation)
                assert.is_false(H.Hekili.State.prot_paladin_last_resort, situation)
            end
        end
    )
end)
