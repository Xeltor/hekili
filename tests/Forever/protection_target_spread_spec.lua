local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("Protection's optional target spreading", function()
    local instances = {}

    local function boot(options)
        options = options or {}
        local H = fixture.warrior(28, 60, {
            group = options.solo and 0 or 5,
            instance = options.instance or "party",
            threat = 3,
            classification = options.classification or "elite",
        })
        instances[#instances + 1] = H
        H.ns.Output.steady = false
        H.Hekili:FireToggle("defensives", "off")
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = true
        H.ctl.exists.targettarget = true
        H.ctl.unitIs.targettarget = "player"
        local classifications = { target = options.classification or "elite" }
        H.ns.Facade.UnitClassification = function(unit)
            return classifications[unit] or "elite"
        end
        local counts = { rend = 1, sunder_armor = 1 }
        local enemies = 2
        H.ns.getNumberTargets = function()
            return enemies, enemies
        end
        H.ns.Facade.DebuffCount = function(id)
            for key, count in pairs(counts) do
                if id == H.Hekili.Class.auras[key].id then
                    return count
                end
            end
            return 0
        end
        -- Current-target upkeep is complete. Keep Clap cooling down so a fresh damage cast does not
        -- hide the later target-spread decision under test.
        for _, key in ipairs({ "rend", "sunder_armor", "thunder_clap", "demoralizing_shout" }) do
            if key ~= options.missingAura then
                local auras = H.ctl.auras.target.HARMFUL
                auras[#auras + 1] = {
                    spellId = H.Hekili.Class.auras[key].id,
                    expirationTime = H.ctl.now + 30,
                    duration = 30,
                    applications = key == "sunder_armor" and (options.currentSunderStacks or 5) or 1,
                    sourceUnit = "player",
                }
            end
        end
        for _, id in ipairs({ 6343, 8198, 8204, 8205, 11580, 11581 }) do
            H.ctl.cooldown[id] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 20 }
        end
        H.Fire("UNIT_AURA", "target")
        local function addPlate(index, classification)
            local unit = "nameplate" .. index
            H.ctl.exists[unit], H.ctl.exists[unit .. "target"] = true, true
            H.ctl.guid[unit] = "Creature-0-0-0-0-347-00000" .. index
            H.ctl.unitIs[unit .. "target"] = "player"
            H.ctl.distance[unit] = 4
            H.ctl.unitCombat[unit] = true
            classifications[unit] = classification or "elite"
            H.Fire("NAME_PLATE_UNIT_ADDED", unit)
            enemies = index + 1
        end
        addPlate(1, options.plateClassification)
        return H, counts, addPlate
    end

    local function first(H)
        local action = fixture.read(H, 0.2)
        return action, H.Hekili.Engine.Output.Primary.recs[1].indicator
    end

    local function noSwap(H, context)
        fixture.read(H, 0.2)
        local output = H.Hekili.Engine.Output.Primary
        for i = 1, output.count do
            assert.are_not.equal("cycle", output.recs[i].indicator, (context or "swap") .. ": icon " .. i)
        end
    end

    after_each(function()
        for _, H in ipairs(instances) do
            H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
        end
        instances = {}
    end)

    it("suggests missing Rend on a confirmed engaged melee elite", function()
        local H = boot()
        assert.are.same({ "rend", "cycle" }, { first(H) })
    end)

    it("spreads Sunder's first application across grouped normal enemies", function()
        local H, counts = boot({ classification = "normal", plateClassification = "normal" })
        counts.rend = 2
        assert.are.same({ "sunder_armor", "cycle" }, { first(H) })
    end)

    it("spreads Rend before adding routine Sunder stacks on the current elite", function()
        local H = boot({ currentSunderStacks = 1 })
        assert.are.same({ "rend", "cycle" }, { first(H) })
    end)

    it("spreads Sunder before adding the current elite's second routine stack", function()
        local H, counts = boot({ currentSunderStacks = 1 })
        counts.rend = 2
        assert.are.same({ "sunder_armor", "cycle" }, { first(H) })
    end)

    it("does not use the current normal enemy's short pull rule for two nearby elites", function()
        local H, _, addPlate = boot({ classification = "normal" })
        addPlate(2, "elite")
        assert.are.same({ "rend", "cycle" }, { first(H) })
    end)

    it("does not assume an ordinary or unreadable extra enemy survives a Rend", function()
        for _, classification in ipairs({ "normal", SECRET }) do
            local H, counts = boot({ plateClassification = classification })
            counts.sunder_armor = 2
            noSwap(H)
        end
    end)

    it("respects Recommend Target Swaps and Single Target mode", function()
        local H = boot()
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
        noSwap(H)
        H = boot()
        H.Hekili:FireToggle("mode", "single")
        noSwap(H)
    end)

    it("leaves raid priorities and solo Sunder unchanged", function()
        local H = boot({ instance = "raid" })
        noSwap(H)
        local counts
        H, counts = boot({ solo = true, classification = "normal", plateClassification = "normal" })
        counts.rend = 2
        noSwap(H)
    end)

    it("does not suggest a swap when every confirmed enemy already carries the debuffs", function()
        local H, counts = boot()
        counts.rend, counts.sunder_armor = 2, 2
        noSwap(H)
    end)

    it("does not turn an unreadable aura count into an endless swap", function()
        local H = boot()
        H.ns.Facade.DebuffCount = function()
            return nil
        end
        noSwap(H)
    end)

    it("does not request another target when only the current target lacks the aura", function()
        for _, key in ipairs({ "rend", "sunder_armor" }) do
            local H, counts = boot({ missingAura = key })
            counts.rend, counts.sunder_armor = 2, 2
            counts[key] = 1 -- the other elite already has it
            -- Exercise the shipped swap line even when earlier upkeep is skipped (e.g. Execute's window).
            local pack = H.Hekili.DB.profile.packs[fixture.PACK]
            local spread
            for _, list in pairs(pack.lists) do
                for _, entry in ipairs(list) do
                    if entry.action == key and entry.other_target == 1 then
                        spread = entry
                    end
                end
            end
            assert.is_not_nil(spread)
            pack.lists = { default = { spread, { enabled = true, action = "battle_shout" } } }
            H.Hekili:LoadScripts()
            noSwap(H, key)
        end
    end)

    it("reports no spread candidates out of combat even while nearby enemies are engaged", function()
        local H = boot()
        H.ctl.unitCombat.target = true
        H.ctl.combat = false
        H.Fire("PLAYER_REGEN_ENABLED")
        fixture.read(H, 0.2)
        local state = H.Hekili.State
        state.reset("Primary", true)
        assert.are.equal(0, state.combat)
        assert.are.equal(0, state.prot_spread_targets)
        assert.are.equal(0, state.prot_rend_spread_targets)
    end)

    it("ignores unengaged, friendly, dead and player nameplates", function()
        for _, knob in ipairs({ "unitCombat", "friendly", "dead", "isPlayer" }) do
            local H = boot()
            H.ctl[knob].nameplate1 = knob ~= "unitCombat"
            noSwap(H)
        end
    end)

    it("requires a confirmed melee range and a player or party victim", function()
        for _, distance in ipairs({ 12, SECRET }) do
            local H = boot()
            H.ctl.distance.nameplate1 = distance
            noSwap(H)
        end
        local H = boot()
        H.ctl.unitIs.nameplate1target = "party5"
        noSwap(H)
    end)

    it("does not count assumed AoE enemies or start spreading from an unengaged target", function()
        local H = boot()
        H.ctl.unitCombat.nameplate1 = false
        H.Hekili:FireToggle("mode", "aoe")
        noSwap(H)
        H = boot()
        H.ctl.unitCombat.target = false
        noSwap(H)
    end)
end)
