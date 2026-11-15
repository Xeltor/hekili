local pve = require("Forever.helpers.rogue_pve")
local rogue, pick, SECRET = pve.rogue, pve.pick, pve.SECRET
local ld = require("Forever.helpers.load_druid")

describe("Rogue PvE follow-through", function()
    it("uses Ghostly Strike's Ambush follow-up without requiring Stealth", function()
        local o = {
            daggers = true,
            group = 5,
            threat = 0,
            buffs = { [1329326] = 7 },
            spells = { 14278, 16511 },
            talents = { [14278] = 1, [16511] = 1 },
        }
        assert.are.equal("ambush", pick(rogue("Subtlety", 30, o)).actionName)
        o.daggers = false
        assert.is_not_equal("ambush", pick(rogue("Subtlety", 30, o)).actionName)
        o.daggers, o.group, o.threat = true, nil, nil
        assert.is_not_equal("ambush", pick(rogue("Subtlety", 30, o)).actionName)
    end)

    it("forecasts only Initiative's guaranteed extra opener point", function()
        local kit = ld.load(nil, "src/Hekili_Rogue/Rogue.lua", "ROGUE")
        for _, key in ipairs({ "ambush", "garrote", "cheap_shot" }) do
            for rank = 0, 3 do
                local env = ld.env(kit)
                env.interrupt = function() end
                env.talent = setmetatable({ initiative = { rank = rank, enabled = rank > 0 } }, {
                    __index = function()
                        return { rank = 0, enabled = false }
                    end,
                })
                ld.run(kit.abilities[key].handler, env)
                local expected = (key == "cheap_shot" and 2 or 1) + (rank == 3 and 1 or 0)
                assert.are.same({ { expected, "combo_points" } }, env.gained, key .. " rank " .. rank)
            end
        end
    end)

    it("uses Shank at five points only when its Energy advances a finisher without point waste", function()
        local o = { points = 5, energy = 5 }
        assert.are.equal("shank", pick(rogue("Combat", 44, o)).actionName)
        o.talents = { [1329286] = 1 }
        assert.is_not_equal("shank", pick(rogue("Combat", 44, o)).actionName)
        o.talents, o.energy = nil, 30
        assert.is_not_equal("shank", pick(rogue("Combat", 44, o)).actionName)
        o.energy, o.singleWeapon = 5, true
        assert.is_not_equal("shank", pick(rogue("Combat", 44, o)).actionName)
    end)

    it("does not trust the best Energy estimate when Shank affordability or pool room is uncertain", function()
        for _, band in ipairs({
            { est = 5, lo = 5, hi = 5, allow = true },
            { est = 5, lo = 0, hi = 5, allow = false },
            { est = 5, lo = 5, hi = 100, allow = false },
        }) do
            local H = rogue("Combat", 44, { points = 5, energy = 5 })
            H.ctl.power[3] = SECRET
            local VS = H.ns.VirtualState
            local original = VS.Power
            local pool = { est = band.est, lo = band.lo, hi = band.hi, conf = 1 }
            VS.Power = function(pt, now)
                return pt == 3 and pool or original(pt, now)
            end
            local action = pick(H).actionName
            if band.allow then
                assert.are.equal("shank", action)
            else
                assert.is_not_equal("shank", action)
            end
        end
    end)

    it("counts only positively engaged melee enemies for Blade Flurry", function()
        local o = {
            group = 5,
            threat = 0,
            instance = "party",
            spells = { 13877 },
            talents = { [13877] = 1 },
            plates = { { distance = 4, combat = true, target = "party1" } },
        }
        local function cleave()
            local H = rogue("Combat", 30, o)
            H.Hekili:FireToggle("cooldowns", "on")
            return pick(H).actionName
        end
        assert.are.equal("blade_flurry", cleave())
        for _, change in ipairs({
            { combat = false },
            { combat = SECRET },
            { distance = 15 },
            { distance = SECRET },
            { target = "unrelated" },
            { sameTarget = true },
        }) do
            o.plates[1] = { distance = 4, combat = true, target = "party1" }
            for k, v in pairs(change) do
                o.plates[1][k] = v
            end
            assert.is_not_equal("blade_flurry", cleave())
        end
    end)

    it("sees melee pressure from another enemy while the selected target casts", function()
        local o = {
            group = 5,
            threat = 0,
            instance = "party",
            cast = true,
            health = 500,
            defensives = true,
            plates = { { distance = 4, combat = true, target = "player" } },
        }
        local H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("interrupts", "off")
        assert.are.equal("evasion", pick(H).actionName)
        o.plates[1].target = "party1"
        H = rogue("Combat", 20, o)
        H.Hekili:FireToggle("interrupts", "off")
        assert.is_not_equal("evasion", pick(H).actionName)
    end)

    it("finds an already visible melee attacker without a nameplate-added event", function()
        local H = rogue("Combat", 30, {
            group = 5,
            threat = 0,
            instance = "party",
            spells = { 13877 },
            talents = { [13877] = 1 },
        })
        H.ctl.exists.nameplate1, H.ctl.distance.nameplate1, H.ctl.unitCombat.nameplate1 = true, 4, true
        H.ctl.exists.nameplate1target, H.ctl.unitIs.nameplate1target = true, "player"
        H.Hekili:FireToggle("cooldowns", "on")
        assert.are.equal("blade_flurry", pick(H).actionName)
    end)

    it("does not mistake a casting target's duplicate or unidentified plate for another attacker", function()
        for _, identity in ipairs({ "target", SECRET }) do
            local H = rogue("Combat", 20, {
                group = 5,
                threat = 3,
                instance = "party",
                cast = true,
                health = 500,
                defensives = true,
                plates = { { distance = 4, combat = true, target = "player" } },
            })
            H.ctl.unitIs.nameplate1 = identity
            H.Hekili:FireToggle("interrupts", "off")
            assert.is_not_equal("evasion", pick(H).actionName)
        end
    end)

    it("allows group Feint recovery at full aggro", function()
        assert.are.equal(
            "feint",
            pick(rogue("Combat", 20, {
                group = 5,
                threat = 3,
                defensives = true,
            })).actionName
        )
    end)

    it("keeps short-pull finishers by default and supports continuous combat upkeep", function()
        local o = { points = 2 }
        assert.is_not_equal("slice_and_dice", pick(rogue("Combat", 20, o)).actionName)
        o.settings = { pve_continuous_combat = true }
        assert.are.equal("slice_and_dice", pick(rogue("Combat", 20, o)).actionName)
    end)

    it("offers independently enabled poison reminders with per-hand preferences", function()
        local o = {
            prepull = true,
            poison = true,
            deadly = true,
            settings = { main_hand_poison = "deadly", off_hand_poison = "instant" },
        }
        local H = rogue("Combat", 30, o)
        H.Hekili:FireToggle("potions", "off")
        local rec = pick(H)
        assert.are.equal("deadly_poison", rec.actionName)
        assert.are.equal("Main Hand", rec.label)
        o.mainPoison = true
        H = rogue("Combat", 30, o)
        rec = pick(H)
        assert.are.equal("instant_poison", rec.actionName)
        assert.are.equal("Off Hand", rec.label)
        o.settings.poison_reminders = false
        H = rogue("Combat", 30, o)
        H.Hekili:FireToggle("potions", "on")
        rec = pick(H)
        assert.is_not_equal("instant_poison", rec.actionName)
        assert.is_not_equal("deadly_poison", rec.actionName)
        o.settings.poison_reminders, o.settings.off_hand_poison = true, "off"
        rec = pick(rogue("Combat", 30, o))
        assert.is_not_equal("instant_poison", rec.actionName)
        assert.is_not_equal("deadly_poison", rec.actionName)
    end)

    it("offers a finisher from Stealth but leaves an unstealthed idle dungeon pull alone", function()
        local H = rogue("Combat", 20, { prepull = true, stealthed = true, points = 5 })
        assert.are.equal("eviscerate", pick(H).actionName)
        H = rogue("Combat", 20, { prepull = true, instance = "party", group = 5 })
        assert.is_nil(pick(H).actionName)
        H = rogue("Combat", 26, { prepull = true, stealthed = true })
        assert.are.equal("cheap_shot", pick(H).actionName)
    end)

    it("applies the Off Hand forecast when the main hand is unequipped", function()
        local H = rogue("Combat", 20, { prepull = true, poison = true, noMainWeapon = true })
        local rec = pick(H)
        assert.are.equal("instant_poison", rec.actionName)
        assert.are.equal("Off Hand", rec.label)
        local out = H.Hekili.Engine.Output.Primary
        for i = 2, out.count do
            assert.is_not_equal("instant_poison", out.recs[i].actionName)
        end
    end)

    it("shares own-stun spacing between Cheap Shot and Kidney Shot and honors its opt-out", function()
        local H = rogue("Combat", 30, { group = 5, threat = 0, points = 3 })
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-cheap-shot-spacing", 1833)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-cheap-shot-spacing", 1833)
        H.ctl.power[3] = 100
        assert(pve.headless.cycle(H, H.ctl.now + 6.1))
        H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
        H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
        assert.is_not_equal("kidney_shot", pick(H).actionName)
        assert.is_not_nil(H.Hekili.Client.DebuffRepeatBlocked("kidney_shot", H.ctl.guid.target, H.ctl.now))
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].settings.stun_spacing = 0
        H.Hekili:SettingsChanged()
        assert.are.equal("kidney_shot", pick(H).actionName)
    end)
end)
