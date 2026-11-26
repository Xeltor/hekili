local headless = require("Game.harness.headless")
local world = require("Forever.helpers.druid_loop_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local AQUATIC = 1066

local function boot(spec, style, advanced, trained)
    local c = world.Feral.character()
    c.level, c.talents, c.known = 24, {}, trained and { 5176, AQUATIC } or { 5176 }
    c.form, c.instanceType = 0, "none"
    c.power = { type = 0, token = "MANA", value = 1000, max = 1000 }
    local H = headless.new({
        character = c,
        pack = spec .. " (wowsims.com)",
        beforeLoad = function(h)
            h.ctl.combat, h.ctl.exists.target = false, false
            h.ctl.usable[AQUATIC] = { true, false }
        end,
    })
    assert.are.same({}, H.loadErrors)
    local conf = H.Hekili.DB.profile.displays.Primary
    conf.style, conf.visibility.advanced = style, advanced
    local vis = conf.visibility.pve
    vis.alpha, vis.always, vis.target, vis.combat, vis.combatTarget = 0, 0, 0, 0, advanced and 0.6 or 0
    H.Hekili:BuildUI()
    H.Hekili:UpdateDisplayVisibility()
    return H, H.env.HekiliDisplayPrimary, vis
end

local function draw(H, display)
    local update = display.__scripts.OnUpdate
    update(display, 0.55)
    assert(headless.cycle(H, H.ctl.now + 0.55))
    update(display, 0.55)
    assert.are.same({}, H.errors)
end

describe("Druid Aquatic Form display", function()
    for _, spec in ipairs({ "Balance", "Feral", "Guardian" }) do
        it("shows Aquatic Form without a target on hidden " .. spec .. " Primary", function()
            local advanced = spec ~= "Guardian"
            local H, display, vis = boot(spec, spec == "Feral" and "timeline" or "classic", advanced, true)
            if spec == "Balance" then
                vis.combatTarget = 0
            end
            draw(H, display)
            assert.are.equal(0, display.alpha)

            H.ctl.swimming = true
            draw(H, display)
            assert.are.equal(spec == "Feral" and 0.6 or 1, display.alpha)
            local out = H.Hekili.Engine.Output.Primary
            assert.are.equal("aquatic_form", out.recs[1].actionName)
            local cue = assert(display.upkeepCue)
            assert.are.equal("aquatic_form", cue.action)

            H.ctl.form, H.ctl.forms = 1, { AQUATIC }
            H.Fire("UPDATE_SHAPESHIFT_FORM")
            draw(H, display)
            assert.are.equal(0, display.alpha)
            assert.is_nil(cue.button)

            H.ctl.form = 0
            H.Fire("UPDATE_SHAPESHIFT_FORM")
            draw(H, display)
            assert.is_true(display.alpha > 0)
            H.ctl.swimming = false
            draw(H, display)
            assert.are.equal(0, display.alpha)
            assert.is_nil(cue.button)
        end)
    end

    it("uses the normal queue when visible and retires the cue at combat entry", function()
        local H, display, vis = boot("Feral", "classic", true, true)
        vis.always = 0.8
        H.ctl.swimming = true
        draw(H, display)
        local out = H.Hekili.Engine.Output.Primary
        assert.are.equal(0.8, display.alpha)
        assert.are.equal("aquatic_form", out.recs[1].actionName)
        assert.are.equal(1, display.Buttons[1].recIndex)

        vis.always = 0
        draw(H, display)
        assert.is_table(display.upkeepCue)
        assert.are.equal(0, display.Buttons[1].recIndex)
        H.ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
        draw(H, display)
        assert.are.equal(0, display.alpha)
        assert.is_nil(display.upkeepCue.button)
    end)

    it("keeps the hidden display closed for unknown, unusable or unconfirmed swimming", function()
        local H, display = boot("Feral", "classic", false, false)
        H.ctl.swimming = true
        draw(H, display)
        assert.are.equal(0, display.alpha)

        H, display = boot("Feral", "classic", false, true)
        H.ctl.swimming = SECRET
        draw(H, display)
        assert.are.equal(0, display.alpha)

        H.ctl.swimming = true
        H.ctl.usable[AQUATIC] = { false, true }
        draw(H, display)
        assert.are.equal(0, display.alpha)
    end)
end)
