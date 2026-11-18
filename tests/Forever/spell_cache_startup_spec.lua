local headless = require("Game.harness.headless")
local ww = require("Forever.helpers.warrior_world")

local function boot(cold)
    cold.requested = {}
    return headless.new({
        character = ww.Protection.character(),
        pack = "Protection (wowsims.com)",
        beforeLoad = function(H)
            local spells = H.env.C_Spell
            local info, texture, cached = spells.GetSpellInfo, spells.GetSpellTexture, spells.IsSpellDataCached
            spells.GetSpellInfo = function(id)
                if not cold.info then
                    return info(id)
                end
            end
            spells.GetSpellTexture = function(id)
                if not cold.texture then
                    return texture(id)
                end
            end
            spells.IsSpellDataCached = function(id)
                return not cold.info and cached(id)
            end
            spells.RequestLoadSpellData = function(id)
                cold.requested[id] = true
            end
        end,
    })
end

local function catalog(H)
    local result = {}
    local registry = H.Hekili.Engine.Registry
    for key, ability in pairs(registry.Abilities()) do
        if type(key) == "string" and key == ability.key and not ability.unlisted and not ability.passive then
            result[key] = { id = ability.id, texture = ability.texture }
        end
    end
    return result
end

describe("spell data during startup", function()
    it("registers the full class when spell artwork is still unavailable", function()
        local warm = boot({})
        local H = boot({ texture = true })
        assert.are.same({}, H.loadErrors)
        assert.is_function(H.Hekili.Class.stateExprs.prot_contextual)
        assert.are.same(catalog(warm), catalog(H))
        H.ctl.inRange.target, H.ctl.level.target, H.ctl.combat = true, 60, true
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("PLAYER_REGEN_DISABLED")
        assert(headless.cycle(H, H.ctl.now + 0.2))
        assert.is_true(H.Hekili.Engine.Output.Primary.count > 0)
        assert.are.same({}, H.errors)
    end)

    it("keeps spell and aura identities until uncached metadata arrives", function()
        local cold = { info = true, texture = true }
        local H = boot(cold)
        assert.are.same({}, H.loadErrors)
        local ability = H.Hekili.Class.abilities.bloodrage
        local aura = H.Hekili.Class.auras.bloodrage
        assert.are.equal(2687, ability.id)
        assert.are.equal(29131, aura.id)
        cold.info, cold.texture = false, false
        H.Fire("SPELL_DATA_LOAD_RESULT", 2687, true)
        H.Fire("SPELL_DATA_LOAD_RESULT", 29131, true)
        assert.are.equal("Spell 2687", ability.name)
        assert.are.equal("Spell 29131", aura.name)
        assert.are.equal(29131, aura.id)
        for id in pairs(cold.requested) do
            H.Fire("SPELL_DATA_LOAD_RESULT", id, true)
        end
        assert.are.same(catalog(boot({})), catalog(H))
        assert.are.same({}, H.errors)
    end)

    it("delivers the first asynchronous spell result once, including load failure", function()
        local cold = { info = true }
        local H = boot(cold)
        local results = {}
        H.Hekili:ContinueOnSpellLoad(1234567, function(success)
            results[#results + 1] = success
        end)
        H.Hekili:RunSpellCallbacks()
        assert.are.same({}, results)
        H.Fire("SPELL_DATA_LOAD_RESULT", 1234567, false)
        assert.are.same({ false }, results)
        H.Fire("SPELL_DATA_LOAD_RESULT", 1234567, true)
        assert.are.same({ false }, results)
    end)
end)
