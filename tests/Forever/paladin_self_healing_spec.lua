local fixture = require("Forever.helpers.paladin_protection")
local secret = require("Game.State.helpers.fake_api").SECRET
local holyLight, flash, hands = 635, 19750, 633

local function paladin(o)
    local H = fixture.paladin(o.level or 30, o.mana or 1000, o)
    H.ctl.cvars.autoSelfCast, H.ctl.cvars.enableMouseoverCast = "1", "0"
    return H
end

local function read(H)
    return fixture.read(H, 1.6) -- the native health observation runs every 1.5 seconds
end

local function cue(H, action)
    local cues = H.Hekili.Engine.Output.Primary.healthCues
    for i = 1, cues.n do
        if cues[i].action == action then
            return cues[i]
        end
    end
end

describe("Protection Paladin self healing", function()
    it("tops up between outdoor pulls and prices the highest trained rank before choosing a heal", function()
        local function pick(health, known, mana)
            return read(paladin({ known = known, health = health, mana = mana, noTarget = true, prepull = true }))
        end
        assert.are.equal("holy_light", pick(500, { holyLight, flash, 647 }, 110))
        assert.are.equal("flash_of_light", pick(500, { holyLight, flash, 647 }, 109))
        assert.are.equal("flash_of_light", pick(800, { holyLight, flash }))
        assert.are.equal("holy_light", pick(800, { holyLight }))
        assert.is_nil(pick(801, { holyLight, flash }))
        assert.is_nil(pick(500, { holyLight, flash }, 34))
    end)

    it("uses Holy Light from level one and distinguishes a defeated enemy from a friendly target", function()
        local H = paladin({ level = 1, known = { holyLight }, health = 440, targetDead = true, prepull = true })
        assert.are.equal("holy_light", read(H))
        H.ctl.dead.target, H.ctl.friendly.target, H.ctl.unitIs.target = false, true, "party1"
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.is_nil(read(H))
    end)

    it("resumes recovery on the defeated target after combat ends", function()
        local H = paladin({ known = { flash, holyLight }, group = 4, instance = "party", role = "TANK", health = 450 })
        assert.is_nil(read(H))
        H.ctl.combat, H.ctl.unitCombat.target, H.ctl.dead.target = false, false, true
        H.Fire("PLAYER_REGEN_ENABLED")
        assert.are.equal("holy_light", read(H))
    end)

    it("respects movement, defensives, real meals and native self-cast routing between fights", function()
        for _, reason in ipairs({ "moving", "defensives", "food", "drink", "self cast off", "dead" }) do
            local H = paladin({
                known = { holyLight, flash },
                health = 400,
                prepull = true,
                defensives = reason ~= "defensives",
                beforeLoad = reason == "moving" and function(h)
                    h.env.GetUnitSpeed = function()
                        return 7, 7, 7, 4.72
                    end
                end or nil,
            })
            if reason == "moving" then
                H.Fire("PLAYER_STARTED_MOVING")
            elseif reason == "dead" then
                H.ctl.dead.player = true
            elseif reason == "self cast off" then
                H.ctl.cvars.autoSelfCast = "0"
            elseif reason == "food" or reason == "drink" then
                local id = reason == "food" and 433 or 430
                H.ctl.auras.player.HELPFUL = { { spellId = id, duration = 30, expirationTime = H.ctl.now + 30 } }
                H.Fire("UNIT_AURA", "player")
            end
            assert.is_nil(read(H), reason)
        end
    end)

    it("uses quick healing against one solo opponent and larger healing inside an observed immunity window", function()
        local function pick(buffs)
            return read(paladin({ known = { flash, holyLight }, buffs = buffs, health = 400 }))
        end
        assert.are.equal("flash_of_light", pick({}))
        assert.are.equal("holy_light", pick({ 642 }))
        assert.are.equal("holy_light", pick({ 498 }))
        assert.are.equal("holy_light", read(paladin({ level = 8, known = { holyLight }, health = 400 })))
        assert.are.equal(
            "holy_light",
            read(paladin({ known = { hands, flash, holyLight }, health = 140, buffs = { 642 } }))
        )
    end)

    it("holds hardcasts during active group tanking, including after losing the selected target", function()
        for _, instance in ipairs({ "none", "party", "raid" }) do
            local H =
                paladin({ known = { flash, holyLight }, health = 400, group = 5, role = "TANK", instance = instance })
            assert.is_nil(read(H), instance)
            H.ctl.exists.target = false
            H.ctl.exists.nameplate1, H.ctl.unitCombat.nameplate1, H.ctl.unitIs.nameplate1target = true, true, "player"
            H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.is_nil(read(H), instance .. " with an add but no selected enemy")
        end
    end)

    it("attempts an affordable last-chance cast against two solo enemies only at critical health", function()
        local function pick(known, health, mana, group)
            local H = paladin({ known = known, health = health, mana = mana, group = group })
            local c = H.ctl
            c.exists.nameplate1, c.unitCombat.nameplate1, c.distance.nameplate1 = true, true, 3
            c.guid.nameplate1, c.level.nameplate1 = "Creature-0-0-0-0-347-000001", 30
            c.unitIs.nameplate1target, c.threat.nameplate1 = "player", 3
            H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
            return read(H)
        end
        assert.are.equal("holy_light", pick({ holyLight }, 250, 35))
        assert.are.equal("flash_of_light", pick({ flash, holyLight }, 250, 35))
        assert.is_nil(pick({ flash, holyLight }, 251, 1000))
        assert.is_nil(pick({ flash, holyLight }, 200, 34))
        assert.is_nil(pick({ flash, holyLight }, 200, 1000, 5))
    end)

    it("can heal while a single enemy is controlled when enough time remains for the cast", function()
        for _, control in ipairs({ 1324513, 1324538, 1324543 }) do
            local H =
                paladin({ known = { holyLight, flash }, group = 5, instance = "party", role = "TANK", health = 400 })
            local aura = {
                spellId = control,
                duration = 6,
                expirationTime = H.ctl.now + 6,
                applications = 1,
                sourceUnit = "player",
            }
            H.ctl.auras.target.HARMFUL = { aura }
            H.Fire("UNIT_AURA", "target")
            assert.are.equal("holy_light", read(H))
            assert.is_nil(fixture.read(H, 3.6))
        end
    end)

    it("holds a second heal while the first cast is in flight", function()
        local H = paladin({ known = { holyLight, flash }, health = 450, noTarget = true, prepull = true })
        assert.are.equal("holy_light", read(H))
        H.ctl.casting = { H.ctl.now * 1000, (H.ctl.now + 2.5) * 1000 }
        H.Fire("UNIT_SPELLCAST_START", "player", "Cast-Self", holyLight)
        assert.is_nil(fixture.read(H))
        assert.is_nil(cue(H, "holy_light"))
    end)

    it("offers a non-dropping emergency heal in group combat and spends it only at critical health", function()
        for _, instance in ipairs({ "none", "party", "raid" }) do
            local H = paladin({ health = 150, group = 5, role = "TANK", instance = instance, known = { hands } })
            assert.are.equal("lay_on_hands", read(H), instance)
            H.ctl.unitHealth.player = 151
            H.Fire("UNIT_HEALTH", "player")
            assert.is_nil(read(H), instance)
        end
    end)

    it("forecasts only the recipient's mana from the trained or bound rank of Lay on Hands", function()
        local function project(H)
            local state = H.Hekili.State
            state.reset("Primary", true)
            state.this_action = "lay_on_hands"
            state:RunHandler("lay_on_hands")
            return state.mana.current
        end
        for _, rank in ipairs({ { 10, hands, 0 }, { 30, 2800, 250 }, { 50, 10310, 550 } }) do
            local H = paladin({ level = rank[1], known = { hands, rank[2] }, health = 100 })
            assert.are.equal("lay_on_hands", read(H))
            assert.are.equal(rank[3], project(H))
        end

        local boundID = 2800
        local H = paladin({
            level = 60,
            known = { hands, 2800, 10310 },
            health = 100,
            beforeLoad = function(world)
                world.env.GetBindingKey = function(command)
                    if command == "MULTIACTIONBAR1BUTTON1" then
                        return "3"
                    end
                end
                world.env.GetBindingAction = function(key)
                    if key == "3" then
                        return "MULTIACTIONBAR1BUTTON1"
                    end
                end
                world.env.GetActionInfo = function(slot)
                    if slot == 61 then
                        return "spell", boundID
                    end
                end
            end,
        })
        H.ns.ReadKeybindings()
        assert.are.equal("lay_on_hands", read(H))
        assert.are.equal(250, project(H))
        boundID = hands
        assert.are.equal(0, project(H))
        boundID = 10310
        H.ctl.friendly.target, H.ctl.unitIs.target = true, "party1"
        assert.are.equal(0, project(H), "a native button on another player")
        H.ctl.friendly.target, H.ctl.unitIs.target = false, nil
        local state = H.Hekili.State
        state.reset("Primary", true)
        state:HandleEvent({ action = "lay_on_hands", type = "CAST_FINISH", time = state.now })
        assert.are.equal(0, state.mana.current, "an observed cast finish has no verified recipient")
    end)

    it("holds Lay on Hands under a long immunity and offers it as that protection expires even at zero mana", function()
        for _, id in ipairs({ 642, 1020, 498, 5573 }) do
            local H = paladin({
                known = { hands, holyLight },
                health = 100,
                mana = 0,
                group = 4,
                role = "TANK",
                buffs = { id },
                instance = "party",
            })
            local expiry = H.ctl.now + 3.5
            H.ctl.auras.player.HELPFUL[1].expirationTime = expiry
            H.Fire("UNIT_AURA", "player")
            assert.is_nil(read(H), id)
            local live = H.Hekili.Client.C_UnitAuras.GetPlayerAuraBySpellID(642)
            assert.are.near(expiry, assert(live).expirationTime, 0.00001)
            assert.are.near(1.9, live.expirationTime - H.Hekili.Client.GetTime(), 0.00001)
            assert.are.equal("lay_on_hands", fixture.read(H, 0.7), id)
            live = H.Hekili.Client.C_UnitAuras.GetPlayerAuraBySpellID(642)
            assert.are.near(1.2, assert(live).expirationTime - H.Hekili.Client.GetTime(), 0.00001)
        end
    end)

    it("routes the emergency heal to a separate Defensives display", function()
        local H = paladin({ known = { hands }, health = 100, group = 5, instance = "party", role = "TANK" })
        local engine = H.Hekili.Engine
        engine.settings.toggles.defensives.separate = true
        assert.is_true(engine.Subscribe("Defensives", function() end))
        assert.is_nil(read(H))
        assert.is_nil(cue(H, "lay_on_hands"))
        assert.are.equal("lay_on_hands", engine.Output.Defensives.recs[1].actionName)
    end)

    it("allows an off-tank to heal while the co-tank holds the fight and stops when an add joins", function()
        local H = paladin({
            health = 410,
            group = 8,
            instance = "raid",
            role = "TANK",
            targetVictim = "raid2",
            threat = 0,
            known = { flash, holyLight },
            boss = true,
        })
        H.ctl.groupRoles.raid2 = "TANK"
        H.Fire("UNIT_TARGET", "target")
        assert.are.equal("holy_light", read(H))
        H.ctl.exists.nameplate1, H.ctl.unitCombat.nameplate1, H.ctl.unitIs.nameplate1target = true, true, "player"
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        assert.is_nil(read(H))
    end)

    it("delivers a Classic health cue for unreadable combat health without guessing an emergency", function()
        local H = paladin({ healthPlain = false, known = { hands, flash } })
        H.ctl.unitHealth.player, H.ctl.unitHealthMax.player = secret, secret
        H.Fire("UNIT_HEALTH", "player")
        assert.is_nil(read(H))
        assert.are.equal(15, assert(cue(H, "lay_on_hands")).percent)
        assert.are.equal(55, assert(cue(H, "flash_of_light")).percent)
        H.env.Enum.LuaCurveType = { Step = 1 }
        local displayApi = H.ns.Facade.Display
        displayApi.C_CurveUtil.CreateCurve = function()
            return { SetType = function() end, AddPoint = function() end }
        end
        displayApi.UnitHealthPercent = function()
            return secret
        end
        local display = H.env.HekiliDisplayPrimary
        display:UpdateAlpha()
        display.__scripts.OnUpdate(display, 0.2)
        assert.are.equal(2, display.healthCue.count)
    end)
end)
