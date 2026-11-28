local headless = require("Game.harness.headless")
local world = require("Forever.helpers.druid_loop_world")

local BEAR, CAT, TRAVEL, AQUATIC, MOONKIN, CLAW, SHRED, MOONFIRE = 5487, 768, 783, 1066, 24858, 1082, 5221, 8921

local function boot(options)
    local spec = options.spec or "Feral"
    local c = world[spec].character()
    c.level, c.talents = options.level or 30, {}
    c.known = options.known or { BEAR, CAT, TRAVEL, AQUATIC, CLAW }
    c.forms, c.form = { options.bear or BEAR, CAT, TRAVEL, AQUATIC, MOONKIN }, options.form or 0
    c.instanceType = options.instance or "none"
    c.power = { type = 0, token = "MANA", value = 3000, max = 3000 }
    local H = headless.new({
        character = c,
        pack = spec .. " (wowsims.com)",
        beforeLoad = function(h)
            local ctl = h.ctl
            ctl.combat, ctl.exists.target = false, false
            ctl.intentSpeed, ctl.intentOutdoors, ctl.intentMounted = 0, options.outdoors ~= false, false
            ctl.groupMembers, ctl.inGroup = options.role and 5 or 0, options.role ~= nil
            ctl.groupRoles.player = options.role or "NONE"
            for _, id in ipairs(c.known) do
                ctl.usable[id] = { true, false }
            end
            h.env.GetUnitSpeed = function()
                return ctl.intentSpeed, 7, 7, 4.72
            end
            h.env.IsOutdoors = function()
                return ctl.intentOutdoors
            end
            h.env.IsMounted = function()
                return ctl.intentMounted
            end
        end,
    })
    assert.are.same({}, H.loadErrors)

    -- The test controls the range band independently of the learned spellbook.
    local range = H.ns.Facade.RangeLib
    H.ns.Facade.RangeLib = function(unit, ...)
        local yards = unit == "target" and H.ctl.distance.target
        if yards then
            return yards, yards
        end
        return range(unit, ...)
    end

    local conf = H.Hekili.DB.profile.displays.Primary
    conf.style, conf.visibility.advanced = options.style or "classic", true
    local vis = conf.visibility.pve
    vis.alpha, vis.always, vis.target, vis.combat, vis.combatTarget = 0, 0, 0, 0, 0.6
    H.Hekili:BuildUI()
    H.Hekili:UpdateDisplayVisibility()
    return H, H.env.HekiliDisplayPrimary, vis
end

local function draw(H, display)
    display.__scripts.OnUpdate(display, 0.55)
    assert(headless.cycle(H, H.ctl.now + 0.55))
    display.__scripts.OnUpdate(display, 0.55)
    assert.are.same({}, H.errors)
end

local function selectTarget(H, kind, yards)
    local ctl = H.ctl
    ctl.exists.target, ctl.distance.target = kind ~= nil, yards
    ctl.friendly.target, ctl.dead.target = kind == "friendly", kind == "dead"
    H.Fire("PLAYER_TARGET_CHANGED")
end

local function move(H, on)
    H.ctl.intentSpeed = on and 7 or 0
    H.Fire(on and "PLAYER_STARTED_MOVING" or "PLAYER_STOPPED_MOVING")
end

local function expectCue(H, display, action)
    draw(H, display)
    assert.is_true(display.alpha > 0)
    assert.are.equal(action, H.Hekili.Engine.Output.Primary.recs[1].actionName)
    assert.are.equal(action, assert(display.upkeepCue).action)
    assert.is_not_nil(display.upkeepCue.button)
    assert.are.equal(0, display.Buttons[1].recIndex)
end

local function expectHidden(H, display)
    draw(H, display)
    assert.are.equal(0, display.alpha)
    if display.upkeepCue then
        assert.is_nil(display.upkeepCue.button)
    end
end

describe("Druid form intent on Primary", function()
    it("keeps an outdoor tank in Bear between single pulls with hidden or visible Primary", function()
        for _, known in ipairs({ { BEAR, CAT, TRAVEL, CLAW }, { BEAR, CAT, CLAW } }) do
            local H, display, vis = boot({ spec = "Guardian", role = "TANK", form = 1, known = known })
            move(H, true)
            expectHidden(H, display)

            vis.always = 0.8
            for _, kind in ipairs({ "enemy", "dead", "enemy" }) do
                selectTarget(H, kind, 22)
                draw(H, display)
                assert.is_nil(display.upkeepOnly)
                local out = H.Hekili.Engine.Output.Primary
                for i = 1, out.count do
                    assert.are_not.equal("cat_form", out.recs[i].actionName)
                    assert.are_not.equal("travel_form", out.recs[i].actionName)
                end
            end
        end
    end)

    it("chooses Cat even in Aquatic Form once a hostile target is selected", function()
        local H, display = boot({ form = 4, style = "timeline" })
        H.ctl.swimming = true
        expectHidden(H, display)
        selectTarget(H, "enemy", 17)
        move(H, true)
        expectCue(H, display, "cat_form")

        selectTarget(H, nil)
        expectHidden(H, display)
        H.ctl.form = 0
        H.Fire("UPDATE_SHAPESHIFT_FORM")
        expectCue(H, display, "aquatic_form")
    end)

    it("chooses Bear for a Guardian tank and for an early Feral without a Cat builder", function()
        local H, display = boot({ spec = "Guardian", role = "TANK", instance = "party", form = 3 })
        selectTarget(H, "enemy", 5)
        expectCue(H, display, "bear_form")

        H, display = boot({ level = 16, known = { BEAR, AQUATIC } })
        selectTarget(H, "enemy", 5)
        expectCue(H, display, "bear_form")
    end)

    it("allows manual Travel before Balance selects a hostile target and prepares Moonkin", function()
        local H, display = boot({ spec = "Balance", level = 40, known = { TRAVEL, MOONKIN }, form = 3 })
        move(H, true)
        expectHidden(H, display)

        selectTarget(H, "enemy", 18)
        expectCue(H, display, "moonkin_form")
    end)

    it("prepares Cat for group damage with Shred when the enemy is facing the tank", function()
        local H, display = boot({ role = "DAMAGER", instance = "party", known = { BEAR, CAT, SHRED } })
        local ctl = H.ctl
        ctl.unitCombat.target, ctl.threat.target = true, 0
        ctl.exists.targettarget, ctl.unitIs.targettarget, ctl.inParty.targettarget = true, "party1", true
        ctl.exists.party1, ctl.groupRoles.party1 = true, "TANK"
        selectTarget(H, "enemy", 3)
        expectCue(H, display, "cat_form")
    end)

    it("can use a ranged opener before learning a combat form", function()
        local H, display, vis = boot({ level = 8, known = { MOONFIRE } })
        H.ctl.ranges[MOONFIRE] = { 0, 30 }
        vis.always = 0.8
        selectTarget(H, "enemy", 18)
        move(H, true)
        draw(H, display)
        assert.are.equal("moonfire", H.Hekili.Engine.Output.Primary.recs[1].actionName)
        assert.is_nil(display.upkeepOnly)
    end)

    it("uses an explicit target to cue combat Cat from manual Travel at any distance", function()
        local H, display = boot({ form = 3 })
        move(H, true)
        expectHidden(H, display)

        selectTarget(H, "enemy", 22)
        expectCue(H, display, "cat_form")
        selectTarget(H, nil)
        expectHidden(H, display)
    end)

    it("never brings up a travel form in combat, including while moving with an out-of-range target", function()
        local H, display, vis = boot({})
        move(H, true)
        H.ctl.swimming = true
        expectCue(H, display, "aquatic_form")

        H.ctl.combat, H.ctl.unitCombat.target, H.ctl.threat.target = true, true, 3
        H.Fire("PLAYER_REGEN_DISABLED")
        selectTarget(H, "enemy", 22)
        vis.always = 0.8
        draw(H, display)
        assert.is_nil(display.upkeepOnly)
        local out = H.Hekili.Engine.Output.Primary
        for i = 1, out.count do
            local action = out.recs[i].actionName
            assert.are_not.equal("travel_form", action)
            assert.are_not.equal("aquatic_form", action)
        end
    end)

    it("shows the selected combat shift when the regular combat queue is hidden", function()
        for _, context in ipairs({
            { spec = "Feral", form = 3, expected = "cat_form" },
            { spec = "Guardian", role = "TANK", instance = "party", form = 4, expected = "bear_form" },
        }) do
            local H, display, vis = boot(context)
            vis.combatTarget = 0
            H.ctl.combat, H.ctl.unitCombat.target, H.ctl.threat.target = true, true, 3
            H.Fire("PLAYER_REGEN_DISABLED")
            selectTarget(H, "enemy", 22)
            move(H, true)
            expectCue(H, display, context.expected)
            H.ctl.form = context.expected == "cat_form" and 2 or 1
            H.Fire("UPDATE_SHAPESHIFT_FORM")
            expectHidden(H, display)
        end
    end)

    it("keeps ground movement manual around friendly or dead targets", function()
        local H, display = boot({})
        move(H, true)
        expectHidden(H, display)
        selectTarget(H, "friendly", 3)
        expectHidden(H, display)
        selectTarget(H, "dead", 3)
        expectHidden(H, display)

        H.ctl.intentOutdoors = false
        H.Fire("ZONE_CHANGED_INDOORS")
        expectHidden(H, display)
    end)

    it("keeps combat form cues hidden while mounted or dead", function()
        local H, display = boot({})
        move(H, true)
        H.ctl.intentMounted = true
        H.Fire("PLAYER_MOUNT_DISPLAY_CHANGED")
        selectTarget(H, "enemy", 3)
        expectHidden(H, display)

        H.ctl.intentMounted, H.ctl.dead.player = false, true
        expectHidden(H, display)
    end)

    it("leaves movement forms manual in dungeons and raids while keeping the selected-target Bear cue", function()
        for _, instance in ipairs({ "party", "raid" }) do
            local H, display = boot({ spec = "Guardian", role = "TANK", instance = instance, outdoors = false })
            move(H, true)
            expectHidden(H, display)
            H.ctl.intentOutdoors = true
            expectHidden(H, display)
            H.ctl.swimming = true
            expectHidden(H, display)

            H.ctl.form = 4
            H.Fire("UPDATE_SHAPESHIFT_FORM")
            selectTarget(H, "enemy", 22)
            expectCue(H, display, "bear_form")
        end
    end)

    it("retains a tank's chosen Cat at combat entry and cues Bear after the player leaves Cat", function()
        for _, instance in ipairs({ "party", "raid" }) do
            local H, display, vis =
                boot({ spec = "Guardian", role = "TANK", instance = instance, outdoors = false, form = 2 })
            vis.combatTarget = 0
            move(H, true)
            expectHidden(H, display)

            H.ctl.combat = true
            H.Fire("PLAYER_REGEN_DISABLED")
            expectHidden(H, display)

            H.ctl.form = 0
            H.Fire("UPDATE_SHAPESHIFT_FORM")
            expectCue(H, display, "bear_form")
        end
    end)

    it("retains both Bear ranks when an outdoor enemy is selected", function()
        for _, bear in ipairs({ BEAR, 9634 }) do
            local H, display, vis =
                boot({ spec = "Feral", level = 40, bear = bear, form = 1, known = { bear, CAT, CLAW } })
            selectTarget(H, "enemy", 3)
            expectHidden(H, display)

            vis.always = 0.8
            draw(H, display)
            assert.is_false(H.Hekili.State:IsUsable("cat_form"))
            local out = H.Hekili.Engine.Output.Primary
            for i = 1, out.count do
                assert.are_not.equal("cat_form", out.recs[i].actionName)
            end
        end
    end)

    it("keeps a combat Cat recommendation in the normal queue when it is visible", function()
        local H, display, vis = boot({ known = { BEAR, CAT, AQUATIC, CLAW } })
        move(H, true)
        selectTarget(H, "enemy", 18)
        expectCue(H, display, "cat_form")

        vis.always = 0.8
        draw(H, display)
        assert.are.equal(0.8, display.alpha)
        assert.are.equal("cat_form", H.Hekili.Engine.Output.Primary.recs[1].actionName)
        assert.are.equal(1, display.Buttons[1].recIndex)
        assert.is_nil(display.upkeepCue.button)
    end)
end)
