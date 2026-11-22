local fixture = require("Forever.helpers.paladin_protection")
local light, flash, attack, bulwark = 635, 19750, 6603, 1311015
local fury = 25780
local texture = { [light] = 135920, [flash] = 135907, [bulwark] = 135891, [fury] = 135962 }

local function spellArt(H)
    local spells = H.env.C_Spell
    local info, art = spells.GetSpellInfo, spells.GetSpellTexture
    spells.GetSpellInfo = function(id)
        local row = info(id)
        if row and texture[id] then
            row.iconID = texture[id]
        end
        return row
    end
    spells.GetSpellTexture = function(id)
        return texture[id] or art(id)
    end
end

-- The headless client's curves and widgets are inert. Record the alpha the native step
-- curve would return at the player's actual health and the ordinary buttons' visibility.
local function healthCurves(H)
    local api = H.ns.Facade.Display
    H.env.Enum.LuaCurveType = { Step = 1 }
    api.C_CurveUtil.CreateCurve = function()
        return {
            points = {},
            SetType = function() end,
            AddPoint = function(self, x, y)
                self.points[#self.points + 1] = { x, y }
            end,
        }
    end
    api.UnitHealthPercent = function(unit, _, curve)
        local hp = H.ctl.unitHealth[unit] / H.ctl.unitHealthMax[unit]
        local alpha = 0
        for _, point in ipairs(curve.points) do
            if hp < point[1] then
                break
            end
            alpha = point[2]
        end
        curve.drawAlpha = alpha
        return alpha
    end
end

local function recordShown(widget)
    widget.Show = function(self)
        self.testShown = true
    end
    widget.Hide = function(self)
        self.testShown = false
    end
    widget.SetShown = function(self, shown)
        self.testShown = shown == true
    end
    widget.IsShown = function(self)
        return self.testShown == true
    end
end

local function boot(style, o, separate)
    o.known = o.known or { light, flash, attack }
    o.beforeLoad, o.prepull, o.autoAttack = spellArt, true, false
    local H = fixture.paladin(30, o.mana or 500, o)
    H.ctl.usable[fury] = { true, false }
    healthCurves(H)
    local profile = H.Hekili.DB.profile
    profile.toggles.defensives.separate = separate or false
    for _, id in ipairs({ "Primary", "Defensives" }) do
        local conf = profile.displays[id]
        conf.style, conf.visibility.advanced = style, true
        local pve = conf.visibility.pve
        pve.combatTarget, pve.combat, pve.target, pve.always = 1, 0, 0, 0
    end
    H.Hekili:BuildUI()
    local display = H.env[separate and "HekiliDisplayDefensives" or "HekiliDisplayPrimary"]
    for _, button in ipairs(display.Buttons) do
        recordShown(button)
    end
    if display.TargetReturn then
        recordShown(display.TargetReturn)
    end
    H.Hekili:UpdateDisplayVisibility()
    return H, display
end

local function draw(H, d)
    d:UpdateAlpha()
    fixture.read(H, 1.6)
    d.__scripts.OnUpdate(d, 0.55)
    assert.are.same({}, H.errors)
end

local function visibleHeal(d)
    local cue = d.healthCue
    if d.alpha == 0 or not cue or not cue.button then
        return
    end
    for i = 1, cue.count do
        local layer = cue.layers[i]
        if layer.curve.drawAlpha == 1 then
            return layer.texture
        end
    end
end

local function assertNoAttack(d)
    assert.is_falsy(d.returning)
    if d.TargetReturn then
        assert.is_false(d.TargetReturn:IsShown())
    end
    for _, button in ipairs(d.Buttons) do
        assert.is_false(button:IsShown(), "ordinary spell button")
        assert.is_falsy(button.swapShown, "forward target-switch cue")
    end
end

describe("Protection Paladin between-pull display", function()
    it("starts the level-13 combat-only display with a missing realm and an unrelated remembered tree", function()
        local headless = require("Game.harness.headless")
        local c = require("Forever.helpers.paladin_world").Protection.character()
        c.level, c.talents, c.known = 13, {}, { attack, fury, 20154, light, 465, 20271 }
        c.power.max, c.power.value, c.instanceType = 434, 434, "none"
        local saved = {
            profiles = {
                Default = {
                    specChoice = { ["Ann-"] = { last = 3 }, ["Ann-Realm"] = {} },
                    displays = {
                        Primary = {
                            visibility = {
                                advanced = true,
                                pve = { combatTarget = 1, combat = 0, target = 0, always = 0 },
                            },
                        },
                    },
                },
            },
        }
        local realm = ""
        local H = headless.new({
            character = c,
            saved = saved,
            beforeLoad = function(h)
                h.env.GetRealmName = function()
                    return realm
                end
                local ctl = h.ctl
                ctl.names.player, ctl.exists.target, ctl.combat = "Ann", false, false
                ctl.healthPlain, ctl.unitHealth.player, ctl.unitHealthMax.player = true, 379, 379
                ctl.usable[fury], ctl.costs[fury] = { true, false }, { { type = 0, cost = 69 } }
                spellArt(h)
            end,
        })
        assert.are.same({}, H.loadErrors)
        local d = H.env.HekiliDisplayPrimary
        -- Drive the actual observer, recommendation engine and display. Only the display subscribes to Primary.
        local function drawFrames()
            for _ = 1, 120 do
                H.ctl.now = H.ctl.now + 0.05
                local observer = H.ns.VirtualStateInternal.Events.frame
                observer.__scripts.OnUpdate(observer, 0.05)
                H.RunTimers(H.ctl.now)
                local engine = H.ns.EngineFrame
                engine.__scripts.OnUpdate(engine, 0.05)
                d.__scripts.OnUpdate(d, 0.05)
            end
            assert.are.equal("protection", H.Hekili.State.spec.key)
            assert.are.equal("righteous_fury", H.Hekili.Engine.Output.Primary.recs[1].actionName)
            assert.are.equal(texture[fury], assert(d.upkeepCue).texture)
            assert.are.same({}, H.errors)
        end
        drawFrames()
        realm = "Realm"
        drawFrames()
    end)

    for _, style in ipairs({ "classic", "timeline" }) do
        it("shows the selected tank buff at full health on hidden " .. style .. " Primary", function()
            for _, o in ipairs({
                { noTarget = true, defensives = false },
                { friendly = true, group = 5, role = "TANK", instance = "party" },
                { idleTarget = true },
            }) do
                o.known, o.health, o.swaps = { fury, attack }, 1000, true
                local H, d = boot(style, o)
                draw(H, d)
                local out = H.Hekili.Engine.Output.Primary
                assert.are.equal("righteous_fury", out.recs[1].actionName)
                assert.are.equal(texture[fury], assert(d.upkeepCue).texture)
                assertNoAttack(d)

                recordShown(d.upkeepCue)
                H.ctl.auras.player.HELPFUL = {
                    { spellId = fury, expirationTime = H.ctl.now + 1800, applications = 1, sourceUnit = "player" },
                }
                H.Fire("UNIT_AURA", "player")
                draw(H, d)
                assert.are.equal(0, d.alpha)
                assert.is_false(d.upkeepCue:IsShown())
                assertNoAttack(d)
            end
        end)

        it("renders only the real heal on the combat-only " .. style .. " Primary", function()
            local H, d = boot(style, { health = 500, swaps = true })
            draw(H, d)
            assert.are.equal(texture[light], visibleHeal(d))
            assertNoAttack(d)
            H.ctl.unitHealth.player = 800
            H.Fire("UNIT_HEALTH", "player")
            draw(H, d)
            assert.are.equal(texture[flash], visibleHeal(d))
            assertNoAttack(d)
            H.ctl.unitHealth.player = 801
            H.Fire("UNIT_HEALTH", "player")
            draw(H, d)
            assert.are.equal(0, d.alpha)
            assert.is_nil(visibleHeal(d))
            assertNoAttack(d)
        end)

        it("leaves a real attack recommendation hidden when healing is unaffordable on " .. style, function()
            local H, d = boot(style, { health = 500, mana = 1, known = { light, attack } })
            draw(H, d)
            local out = H.Hekili.Engine.Output.Primary
            assert.are.equal("auto_attack", out.recs[1].actionName)
            assert.is_truthy(out.count > 0)
            assert.is_nil(visibleHeal(d))
            assertNoAttack(d)
        end)
    end

    it("keeps upkeep on Primary with separate healing and gives a needed heal priority on a shared display", function()
        local o = { health = 400, noTarget = true, known = { light, flash, fury } }
        local H, defenses = boot("timeline", o, true)
        local primary = H.env.HekiliDisplayPrimary
        draw(H, defenses)
        draw(H, primary)
        assert.are.equal(texture[light], visibleHeal(defenses))
        assert.is_nil(defenses.upkeepCue)
        assert.are.equal(texture[fury], assert(primary.upkeepCue).texture)
        assert.is_nil(visibleHeal(primary))

        H, primary = boot("classic", o)
        draw(H, primary)
        assert.are.equal(texture[light], visibleHeal(primary))
        assert.is_nil(primary.upkeepCue)
        assertNoAttack(primary)
    end)

    it("retires a visible tank buff when the player starts a meal or changes to a non-tanking role", function()
        local H, d = boot("classic", { group = 5, role = "TANK", known = { fury, attack }, idleTarget = true })
        draw(H, d)
        recordShown(assert(d.upkeepCue))
        draw(H, d)
        assert.is_true(d.upkeepCue:IsShown())
        H.ctl.auras.player.HELPFUL = { { spellId = 430, duration = 20, expirationTime = H.ctl.now + 20 } }
        H.Fire("UNIT_AURA", "player")
        assert.is_false(d.upkeepCue:IsShown())
        draw(H, d)
        assert.is_false(d.upkeepCue:IsShown())
        assertNoAttack(d)
        H.ctl.auras.player.HELPFUL = {}
        H.Fire("UNIT_AURA", "player")
        draw(H, d)
        assert.is_true(d.upkeepCue:IsShown())
        H.ctl.groupRoles.player = "DAMAGER"
        H.Fire("PLAYER_ROLES_ASSIGNED")
        assert.is_false(d.upkeepCue:IsShown())
        draw(H, d)
        assert.is_false(d.upkeepCue:IsShown())
        assertNoAttack(d)
    end)

    it("keeps a disabled display and an untrained tank buff hidden at full health", function()
        local H, d = boot("classic", { health = 1000, known = { fury }, noTarget = true })
        H.Hekili.DB.profile.displays.Primary.visibility.pve.combatTarget = 0
        draw(H, d)
        assert.are.equal(0, d.alpha)
        assert.is_nil(d.upkeepCue)
        H, d = boot("classic", { health = 1000, known = { light, attack } })
        draw(H, d)
        assert.are.equal(0, d.alpha)
        assert.is_nil(d.upkeepCue)
        assertNoAttack(d)
    end)

    it("honors zero visibility and disabled defensives on the Primary display", function()
        local H, d = boot("classic", { health = 500 })
        local pve = H.Hekili.DB.profile.displays.Primary.visibility.pve
        pve.combatTarget = 0
        draw(H, d)
        assert.are.equal(0, d.alpha)
        assertNoAttack(d)
        pve.combatTarget = 1
        H.Hekili:FireToggle("defensives", "off")
        draw(H, d)
        assert.are.equal(0, d.alpha)
        assert.is_nil(visibleHeal(d))
        assertNoAttack(d)
    end)

    it("uses only the separate Defensives display when requested", function()
        local H, d = boot("timeline", { health = 700, noTarget = true }, true)
        draw(H, d)
        assert.are.equal(texture[flash], visibleHeal(d))
        assertNoAttack(d)
        local primary = H.env.HekiliDisplayPrimary
        assert.are.equal(0, primary.alpha)
        assert.is_nil(visibleHeal(primary))
    end)

    it("restores the tank buff in combat after losing the enemy at full health", function()
        local H, d = boot("classic", { group = 5, role = "TANK", health = 1000, known = { fury, attack } })
        H.ctl.combat, H.ctl.exists.target = true, false
        H.Fire("PLAYER_REGEN_DISABLED")
        H.Fire("PLAYER_TARGET_CHANGED")
        draw(H, d)
        assert.are.equal(texture[fury], assert(d.upkeepCue).texture)
        assertNoAttack(d)
    end)

    it("shows the emergency absorb in combat when a combat-target-only display loses its enemy", function()
        local H, d = boot("classic", { health = 600, known = { bulwark, attack }, group = 5, role = "TANK" })
        H.ctl.combat, H.ctl.unitCombat.target = true, true
        H.Fire("PLAYER_REGEN_DISABLED")
        H.ctl.exists.target = false
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("UNIT_COMBAT", "player", "WOUND", nil, 290, 1)
        draw(H, d)
        assert.are.equal(texture[bulwark], visibleHeal(d))
        assertNoAttack(d)
    end)

    it("retires a heal on a real target change before drawing another recommendation", function()
        local H, d = boot("classic", { health = 500, noTarget = true })
        draw(H, d)
        assert.are.equal(texture[light], visibleHeal(d))
        H.ctl.exists.target, H.ctl.unitIs.target, H.ctl.friendly.target = true, "party1", true
        H.ctl.guid.target = "Player-0-002"
        H.Fire("PLAYER_TARGET_CHANGED")
        d.__scripts.OnUpdate(d, 0.01)
        assert.is_nil(visibleHeal(d), "retire the previous target's heal before the next engine update")
        draw(H, d)
        assert.is_nil(visibleHeal(d))
        assertNoAttack(d)
    end)

    it("retires a visible heal immediately when a mouseover or focus can receive it", function()
        for unit, event in pairs({
            mouseover = "UPDATE_MOUSEOVER_UNIT",
            focus = "PLAYER_FOCUS_CHANGED",
            softfriend = "PLAYER_SOFT_FRIEND_CHANGED",
            softinteract = "PLAYER_SOFT_INTERACT_CHANGED",
        }) do
            local H, d = boot("classic", { health = 500, noTarget = true })
            draw(H, d)
            assert.are.equal(texture[light], visibleHeal(d))
            H.ctl.cvars.enableMouseoverCast, H.ctl.modifiedClicks.FOCUSCAST = "1", "SHIFT"
            H.ctl.exists[unit], H.ctl.friendly[unit] = true, true
            H.Fire(event)
            assert.is_nil(visibleHeal(d), unit)
            assertNoAttack(d)
        end
    end)
end)
