-- tests/Forever/display_alpha_spec.lua (audit first wave, Task 3, item 9): the display's per-frame alpha check
-- (UI.lua's OnUpdate: every 0.5 s, UpdateAlpha), which upstream never ran (it read an unset global), over a headless
-- Arms fight with a combat-only Primary display: hidden before the pull, shown through combat, hidden after, and no
-- other alpha change (the check agrees with the status subscriber's UpdateAlpha at each combat edge).
local loop = require("Game.harness.loop")
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

describe("the per-frame alpha check of a combat-only display", function()
    it("shows recommendations on the first pull after an idle combat-end event at login", function()
        local H = headless.new({ character = ww.Raid.character(), pack = ww.PACK })
        local hekili, ctl = H.Hekili, H.ctl
        local vis = hekili.DB.profile.displays.Primary.visibility
        vis.advanced = true
        vis.pve.always, vis.pve.target, vis.pve.combat, vis.pve.combatTarget = 0, 0, 0, 1
        hekili:UpdateDisplayVisibility()
        local display = H.env.HekiliDisplayPrimary
        assert.are.equal(0, display.alpha)

        H.Fire("PLAYER_REGEN_ENABLED") -- Already idle, with no earlier fight to resume.
        ctl.inRange.target, ctl.level.target = true, 60
        H.Fire("PLAYER_TARGET_CHANGED")
        ctl.now, ctl.combat = ctl.now + 1, true
        H.Fire("PLAYER_REGEN_DISABLED")
        assert(headless.cycle(H, ctl.now + 0.2))
        assert.is_true(hekili.Engine.Output.status.combat)
        assert.are.equal(1, display.alpha)
        assert.is_string(hekili.Engine.Output.Primary.recs[1].actionName)

        local started = hekili.Engine.Output.status.combatStart
        ctl.combat = false
        H.Fire("PLAYER_REGEN_ENABLED")
        assert(headless.cycle(H, ctl.now + 0.2))
        assert.are.equal(0, display.alpha)

        ctl.now, ctl.combat = ctl.now + 1, true
        H.Fire("PLAYER_REGEN_DISABLED")
        assert(headless.cycle(H, ctl.now + 0.2))
        assert.are.equal(started, hekili.Engine.Output.status.combatStart)
        assert.are.equal(1, display.alpha)
    end)

    it("shows the display only in combat over a fight, changing alpha only at the combat edges", function()
        local L = loop.new(ww)
        local H = L.us
        local vis = H.Hekili.DB.profile.displays.Primary.visibility
        vis.advanced = true
        for key, v in pairs({ combat = 1, always = 0, target = 0, combatTarget = 0 }) do
            vis.pve[key] = v
        end
        H.Hekili:UpdateDisplayVisibility()
        local d = rawget(H.env, "HekiliDisplayPrimary")
        local checks, last, changes = 0, nil, {}
        local alpha = d.UpdateAlpha
        d.UpdateAlpha = function(self)
            checks = checks + 1
            return alpha(self)
        end
        local frames = 0
        local function frame(t)
            local f = d.__scripts.OnUpdate
            if f then
                frames = frames + 1
                f(d, 0.2)
            end
            local a = d.alpha or 0
            if a ~= last then
                changes[#changes + 1] = { t, a, H.Hekili.Engine.Output.status.combat }
                last = a
            end
        end
        local run = loop.run(L, 1, {
            duration = 60,
            on = function(_, _, t)
                frame(t)
            end,
        }, { { H = H } })
        for k = 1, 30 do -- 6 s after the fight
            H.ctl.now = H.ctl.now + 0.2
            H.RunTimers(H.ctl.now)
            frame(run.t + 0.2 * k)
        end
        local seen = {}
        for i, c in ipairs(changes) do
            seen[i] = { c[2], c[3] }
        end
        print(
            ("\nalpha check: %d frames, %d UpdateAlpha calls; shown at %.1f s, hidden at %.1f s"):format(
                frames,
                checks,
                changes[2] and changes[2][1] or -1,
                changes[3] and changes[3][1] or -1
            )
        )
        assert.are.same({ { 0, false }, { 1, true }, { 0, false } }, seen)
        assert.is_true(checks > 100) -- the check ran (every 0.5 s), not only the subscriber's edges
    end)
end)
