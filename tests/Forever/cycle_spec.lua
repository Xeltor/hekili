-- tests/Forever/cycle_spec.lua (option D, owner 2026-11-11): Recommend Target Swaps on the engine's target-cycle
-- machinery. `active_dot` is the belief's count (Facade.DebuffCount, stubbed here; tests/Game/State/token_slots_spec.lua
-- proves the count itself), unknown is saturated (never 0: a 0 suggests a swap for ever), the current target's own
-- debuff floors it at 1, `max_cycle_targets` caps the targets, and time to die (never known on Forever) excludes nobody.
-- The bed: the headless Arms instance with a two-line list, Rend (cycle_targets=1, cast where it is down) over a filler.
local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

describe("target swaps (cycle_targets, option D)", function()
    local H, st, rec, t, count, enemies, rendId, others

    -- The list: `rendLine`'s modifiers (cycle_targets=1 unless overridden) over a Battle Shout filler.
    local function boot(mods)
        H = headless.new({ character = ww.character(), pack = ww.PACK })
        assert.are.same({}, H.loadErrors)
        H.ns.Output.steady = false -- assert the forecast from the test list, without holding the boot pack's icons
        st = H.Hekili.State
        rendId = H.Hekili.Class.auras.rend.id
        H.ctl.inRange.target, H.ctl.level.target = true, 60
        H.ctl.power[1] = 100
        H.Fire("PLAYER_TARGET_CHANGED")
        t = H.ctl.now + 0.2
        assert(headless.cycle(H, t))
        local rend = { enabled = true, action = "rend", criteria = "!debuff.rend.up", cycle_targets = 1 }
        for k, v in pairs(mods or {}) do
            rend[k] = v or nil
        end
        H.Hekili.DB.profile.packs[ww.PACK].lists = {
            default = { rend, { enabled = true, action = "battle_shout" } },
        }
        H.Hekili:LoadScripts()
        assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
        count, enemies, others = 1, 3, 0
        local sunderId = H.Hekili.Class.auras.sunder_armor.id
        H.ns.Facade.DebuffCount = function(id)
            if id == rendId then
                return count
            elseif id == sunderId then
                return others
            end
            return 0
        end
        H.ns.getNumberTargets = function()
            return enemies, enemies
        end
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle = true
    end

    local function rendUp(remains)
        H.ctl.auras.target.HARMFUL[1] = {
            name = "Rend",
            spellId = rendId,
            expirationTime = H.ctl.now + remains,
            duration = 21,
            applications = 1,
            sourceUnit = "player",
        }
        H.Fire("UNIT_AURA", "target")
    end

    local function update()
        t = t + 0.2
        assert(headless.cycle(H, t))
        assert.are.same({}, H.errors)
        rec = H.Hekili.Engine.Output.Primary.recs
        return rec[1].actionName, rec[1].indicator
    end

    after_each(function()
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle = false
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle_min = 6
    end)

    it("suggests Rend on another target while fewer enemies carry it than are in combat", function()
        boot()
        rendUp(10)
        assert.are.same({ "rend", "cycle" }, { update() })
    end)

    it("suggests no swap once every enemy carries it", function()
        boot()
        rendUp(10)
        count = 3
        assert.are.same({ "battle_shout" }, { update() })
    end)

    it("with the toggle off, the line reads the current target only, as without cycle_targets", function()
        boot()
        rendUp(10)
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle = false
        local on = { update() }
        boot({ cycle_targets = false })
        rendUp(10)
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle = false
        assert.are.same({ "battle_shout" }, on)
        assert.are.same(on, { update() })
    end)

    it("suggests no swap with one enemy", function()
        boot()
        rendUp(10)
        enemies = 1
        assert.are.same({ "battle_shout" }, { update() })
    end)

    it("caps the targets at max_cycle_targets", function()
        boot({ max_cycle_targets = 2 })
        rendUp(10)
        count = 2
        assert.are.same({ "battle_shout" }, { update() })
        count = 1
        assert.are.same({ "rend", "cycle" }, { update() })
    end)

    it("reads an unknown count as every enemy carrying it: no swap, never 0", function()
        boot()
        rendUp(10)
        count = nil -- the belief holds no slot for the target (Map with no plate, plates off)
        assert.are.same({ "battle_shout" }, { update() })
        st.reset("Primary", true)
        assert.are.equal(st.true_active_enemies, st.active_dot.rend)
        assert.are.equal(3, st.active_dot.rend)
    end)

    it("floors the count at 1 while the current target carries it", function()
        boot()
        rendUp(10)
        count, enemies = 0, 2
        assert.are.same({ "rend", "cycle" }, { update() })
        st.reset("Primary", true)
        st.SetupCycle(H.Hekili.Class.abilities.rend, true)
        assert.is_true((st.IsCycling(nil, true)))
        assert.are.equal(1, st.active_dot.rend)
    end)

    it("excludes nobody by time to die, which Forever never knows", function()
        boot()
        rendUp(10)
        H.Hekili.Engine.settings.specs[ww.SPEC].cycle_min = 15
        st.reset("Primary", true)
        assert.are.equal(3, st.cycle_enemies)
    end)

    -- Task 3a: a swapped cast's handler counts its debuff and leaves the current target's alone; its self-buffs apply.
    it(
        "forecasts a swapped cast as one more carrier, the current target's debuff unchanged, self-buffs applied",
        function()
            boot()
            local ab = H.Hekili.Class.abilities.rend
            local handler = ab.handler
            ab.handler = function() -- a test-only self-buff on the cast
                handler()
                st.applyBuff("battle_shout")
            end
            H.Hekili.DB.profile.packs[ww.PACK].lists.default = {
                { enabled = true, action = "rend", criteria = "!debuff.rend.up", cycle_targets = 1 },
                {
                    enabled = true,
                    action = "sunder_armor",
                    criteria = "debuff.rend.remains<12&active_dot.rend=3&buff.battle_shout.up",
                },
                { enabled = true, action = "battle_shout" },
            }
            H.Hekili:LoadScripts()
            rendUp(10)
            count = 2
            local first = { update() }
            ab.handler = handler
            assert.are.same({ "rend", "cycle" }, first)
            assert.are.equal("sunder_armor", rec[2].actionName)
        end
    )

    it("counts the swapped cast in the forecast: the next icon is no second swap", function()
        boot()
        rendUp(10)
        count = 2 -- one enemy left
        assert.are.same({ "rend", "cycle" }, { update() })
        assert.is_true(H.Hekili.Engine.Output.Primary.count >= 2)
        assert.are_not.same({ "rend", "cycle" }, { rec[2].actionName, rec[2].indicator })
    end)

    describe("navigation-only class actions", function()
        local action = "test_target_navigation"
        local wanted, safe, casts

        local function bootNavigation()
            boot()
            local kit, abilities = H.Hekili.Class.kit, H.Hekili.Class.abilities
            wanted, safe, casts = true, true, 0
            kit:RegisterAbility(action, {
                targetSwap = true,
                name = "Switch target",
                gcd = "off",
                usable = function()
                    return wanted
                end,
                targetSwapSafe = function()
                    return safe
                end,
                handler = function()
                    casts = casts + 1
                end,
            })
            local marker = kit.abilities[action]
            abilities[action], abilities[marker.id] = marker, marker
            H.Hekili.DB.profile.packs[ww.PACK].lists.default = {
                { enabled = true, action = action, use_off_gcd = 1 },
                { enabled = true, action = "battle_shout" },
            }
            H.Hekili:LoadScripts()
            H.ctl.combat, H.ctl.unitCombat.target = true, true
            H.ctl.exists.targettarget, H.ctl.unitIs.targettarget = true, "player"
            H.Fire("PLAYER_REGEN_DISABLED")
        end

        it(
            "shows an immediate solitary instruction without casting, then resumes the live landing's own list",
            function()
                bootNavigation()
                count, others = enemies, enemies
                rendUp(10)
                assert.are.same({ action, "cycle" }, { update() })
                assert.are.equal(1, H.Hekili.Engine.Output.Primary.count)
                assert.are.equal(0, rec[1].time)
                assert.is_true(rec[1].targetSwap)
                assert.is_nil(rec[1].texture)
                assert.are.equal(0, casts)
                H.ctl.guid.target = "Creature-held"
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.same({ action, "cycle" }, { update() }, "this distinct but held enemy still needs a switch")
                H.ctl.guid.target, wanted = "Creature-loose", false
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.same({ "battle_shout" }, { update() }, "class evidence determines when to stop")
                assert.are.equal(0, casts)
            end
        )

        it("reverses on a class-protected engaged enemy before ordinary actions can be considered", function()
            bootNavigation()
            local engine, origin = H.Hekili.Engine, H.ctl.guid.target
            local output = engine.Output
            assert.are.same({ action, "cycle" }, { update() })
            engine.TargetSwapShown("Primary", rec[1])
            safe, wanted, H.ctl.guid.target = false, false, "Creature-co-tank"
            H.Fire("PLAYER_TARGET_CHANGED")
            update()
            assert.are.equal("cycle_previous", output.status.targetNavigation)
            assert.are.equal(0, output.Primary.count, "even the fallback is suppressed on a protected target")
            H.ctl.guid.target, safe, wanted = origin, true, true
            H.Fire("PLAYER_TARGET_CHANGED")
            update()
            assert.are.equal(
                "cycle_previous",
                output.status.targetNavigation,
                "the safe origin supports reverse search"
            )
            H.ctl.guid.target, wanted = "Creature-loose", false
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ "battle_shout" }, { update() }, "ordinary priorities resume on a confirmed safe landing")
            assert.is_nil(output.status.targetNavigation)
        end)

        it("releases a trash navigation request when a boss encounter starts during the same combat", function()
            bootNavigation()
            local engine = H.Hekili.Engine
            assert.are.same({ action, "cycle" }, { update() })
            engine.TargetSwapShown("Primary", rec[1])
            wanted, safe = false, false
            H.Fire("ENCOUNTER_START", 123, "Boss", 1, 10)
            assert.are.same({ "battle_shout" }, { update() })
            assert.is_false(engine.Output.status.swapPending)
        end)

        it("stops at a repeated held enemy and permits a later independent recovery in the same fight", function()
            bootNavigation()
            local engine, origin = H.Hekili.Engine, H.ctl.guid.target
            assert.are.same({ action, "cycle" }, { update() })
            engine.TargetSwapShown("Primary", rec[1])
            H.ctl.guid.target = "Creature-held"
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ action, "cycle" }, { update() })
            engine.TargetSwapShown("Primary", rec[1])
            H.ctl.guid.target = origin
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ "battle_shout" }, { update() })
            assert.are.same({ "battle_shout" }, { update() }, "do not loop endlessly around held enemies")
            wanted = false
            assert.are.same({ "battle_shout" }, { update() })
            wanted = true
            assert.are.same(
                { action, "cycle" },
                { update() },
                "new positive request without changing the selected enemy"
            )
        end)

        it(
            "requires confirmed class evidence, combat, target identity, and the original switch and indicator settings",
            function()
                bootNavigation()
                wanted = nil
                assert.are.same({ "battle_shout" }, { update() })
                wanted = true
                safe = nil
                assert.are.same({ "battle_shout" }, { update() })
                safe = true
                local config = H.Hekili.Engine.settings.displays.Primary
                config.classic.indicators.enabled = false
                assert.are.same({ "battle_shout" }, { update() })
                config.classic.indicators.enabled = true
                config.style = "third_party"
                assert.are.same({ "battle_shout" }, { update() })
                config.style = nil
                H.Hekili.Engine.settings.specs[ww.SPEC].cycle = false
                assert.are.same({ "battle_shout" }, { update() })
                H.Hekili.Engine.settings.specs[ww.SPEC].cycle = true
                H.ctl.unitCombat.target = false
                assert.are.same({ "battle_shout" }, { update() })
                H.ctl.unitCombat.target, H.ctl.combat = true, false
                H.Fire("PLAYER_REGEN_ENABLED")
                assert.are.same({ "battle_shout" }, { update() })
                H.ctl.guid.target = nil
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.same({ "battle_shout" }, { update() })
            end
        )
    end)

    -- Task 3 (owner decision 1): other_target=1, a cast for another target only (a forced cycle). Sunder Armor stands in
    -- for a debuff the current target lacks; `others` is its count.
    describe("other_target=1", function()
        local function bootOther()
            boot()
            H.Hekili.DB.profile.packs[ww.PACK].lists.default = {
                {
                    enabled = true,
                    action = "sunder_armor",
                    criteria = "active_dot.sunder_armor=0",
                    other_target = 1,
                },
                {
                    enabled = true,
                    action = "rend",
                    criteria = "!debuff.sunder_armor.up&active_dot.sunder_armor=1&!debuff.rend.up",
                },
                { enabled = true, action = "battle_shout" },
            }
            H.Hekili:LoadScripts()
        end

        it("is never shown with the toggle off, and never on the current target", function()
            bootOther()
            H.Hekili.Engine.settings.specs[ww.SPEC].cycle = false
            assert.are.same({ "battle_shout" }, { update() })
        end)

        it("is shown with the cycle icon while no enemy carries it, and counted in the forecast", function()
            bootOther()
            enemies = 2
            assert.are.same({ "sunder_armor", "cycle" }, { update() })
            -- the forecast: the current target still lacks it, and one enemy carries it
            assert.are.equal("rend", rec[2].actionName)
        end)

        it("starts the next forced spread from the enemy that received the previous cast", function()
            bootOther()
            local original = H.ctl.guid.target
            assert.are.same({ "sunder_armor", "cycle" }, { update() })
            H.ctl.guid.target = "Creature-2"
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ "sunder_armor" }, { update() })
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-sunder", 7386)
            assert.are.same({ "sunder_armor", "cycle" }, { update() })
            assert.are.equal("Creature-2", rec[1].cycleOrigin)
            H.ctl.guid.target = original
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ "sunder_armor" }, { update() })
        end)

        it("skips a forced swap when the selected target cannot be identified", function()
            bootOther()
            H.ctl.guid.target = nil
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ "battle_shout" }, { update() })
        end)

        it("is not shown once an enemy carries it, with one enemy, or with the count unknown", function()
            bootOther()
            rendUp(10)
            others = 1
            assert.are.same({ "battle_shout" }, { update() })
            others, enemies = 0, 1
            assert.are.same({ "battle_shout" }, { update() })
            others, enemies = nil, 3
            assert.are.same({ "battle_shout" }, { update() })
        end)

        it("is parsed by the importer as the number 1", function()
            boot()
            local lines = H.Hekili:ParseActionList("actions=sunder_armor,other_target=1,if=active_dot.sunder_armor=0")
            assert.are.equal(1, lines[1].other_target)
        end)
    end)
end)
