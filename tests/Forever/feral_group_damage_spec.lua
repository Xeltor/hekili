local F = require("Forever.helpers.feral_pve")
local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local W = require("Forever.helpers.druid_loop_world")

local function cat(o)
    o.instance, o.group, o.role = "party", 5, "DAMAGER"
    o.form, o.combat = "cat_form", true
    o.victim, o.victimRole = "party1", "TANK"
    return F.druid(o)
end

local function aura(c, unit, id, source)
    c.auras[unit] = c.auras[unit] or { HARMFUL = {}, HELPFUL = {} }
    c.auras[unit].HARMFUL[1] =
        { spellId = id, expirationTime = c.now + 9, duration = 9, applications = 1, sourceUnit = source or "player" }
end

describe("Cat damage in a dungeon group", function()
    it("follows the assigned role from caster on dungeon and raid bosses and respects manually chosen forms", function()
        for _, instance in ipairs({ "party", "raid" }) do
            for _, spec in ipairs({ "Guardian", "Feral" }) do
                local label = instance .. " " .. spec
                local member = instance == "raid" and "raid2" or "party1"
                local o = {
                    level = 60,
                    known = { 5487, 768, 1082, 6807, 407995 },
                    boss = true,
                    instance = instance,
                    group = instance == "raid" and 10 or 5,
                    spec = spec,
                    role = "DAMAGER",
                    victim = member,
                    victimRole = "TANK",
                    combat = true,
                    form = "caster",
                    setup = function(_, c)
                        if instance == "raid" then
                            c.inRaid.targettarget = 2
                        end
                    end,
                }
                assert.are.equal("cat_form", (F.druid(o)), label .. " damage from caster")
                o.form = "cat_form"
                assert.are.equal("claw", (F.druid(o)), label .. " Cat damage with another tank")
                o.form = "bear_form"
                assert.are.equal("primal_bite", (F.druid(o)), label .. " manual Bear")
                o.role, o.form = "TANK", "caster"
                assert.are.equal("bear_form", (F.druid(o)), label .. " tank from caster")
                o.form = "cat_form"
                assert.are.equal("claw", (F.druid(o)), label .. " tank attacks from manual Cat")
                o.form = "bear_form"
                assert.are.equal("primal_bite", (F.druid(o)), label .. " tank attacks from Bear")
            end
        end
    end)

    it("offers a trained attack at every level to a damage player with a separate dungeon tank", function()
        local learn = require("Forever.wowsims.learn_druid")
        W.Balance.character()
        W.Guardian.character()
        W.Feral.character()
        local families = {
            wrath = W.Balance.IDS.wrath,
            moonfire = W.Balance.IDS.moonfire,
            maul = W.Guardian.IDS.maul,
            swipe_bear = W.Guardian.IDS.swipe_bear,
            claw = W.Feral.IDS.claw,
            shred = W.Feral.IDS.shred,
            rake = W.Feral.IDS.rake,
            rip = W.Feral.IDS.rip,
            ferocious_bite = W.Feral.IDS.ferocious_bite,
        }
        for level = 1, 60 do
            local known, highest = { 6603 }, {}
            for _, id in ipairs({ 5487, 768, 9634 }) do
                if learn[id] and learn[id] <= level then
                    known[#known + 1] = id
                end
            end
            for key, family in pairs(families) do
                for _, id in ipairs(family) do
                    -- Forever added Bite rank 1 at 24 after the SpellLevels export.
                    local trainedAt = id == 1328618 and 24 or learn[id]
                    if trainedAt and trainedAt <= level then
                        known[#known + 1], highest[key] = id, id
                    end
                end
            end
            local _, out, H = F.druid({
                level = level,
                known = known,
                form = level >= 20 and "cat_form" or level >= 10 and "bear_form" or "caster",
                instance = "party",
                group = 5,
                role = "DAMAGER",
                combat = true,
                victim = "party1",
                victimRole = "TANK",
                points = level >= 20 and level % 6 or 0,
                enemyHealth = level % 3 == 0 and 190 or 900,
                setup = function(_, c)
                    c.current[6603] = true
                end,
            })
            local label = "damage role at level " .. level
            assert.is_true(out.count > 0, label)
            for i = 1, out.count do
                local key = out.recs[i].actionName
                local family = assert(families[key], label .. " unexpected " .. key)
                local id = H.ns.VirtualState.KnownID(family[1])
                assert.is_true(H.ctl.known[id] == true, label .. " " .. key)
                assert.are.equal(highest[key], id, label .. " " .. key)
                assert.are.equal(level < 10, key == "wrath" or key == "moonfire", label)
                assert.are.equal(level >= 10 and level < 20, key == "maul" or key == "swipe_bear", label)
            end
        end
    end)

    it("switches builders on the same display when a party tank loses and recovers the target", function()
        local first, _, H = cat({ level = 42, known = { 768, 1082, 5221 }, talents = { [16966] = 3 } })
        assert.are.equal("shred", first)
        local c = H.ctl
        local function builder(victim)
            c.unitIs.targettarget, c.inParty.targettarget = victim, victim == "party1"
            H.Fire("UNIT_TARGET", "target")
            assert(headless.cycle(H, c.now + 1.6))
            assert.are.same({}, H.errors)
            return H.Hekili.Engine.Output.Primary.recs[1].actionName
        end
        assert.are.equal("claw", builder("player"))
        assert.are.equal("claw", builder(SECRET))
        assert.are.equal("shred", builder("party1"))
    end)

    it("uses the learned builder in either pack when Cat lacks the other one", function()
        for _, spec in ipairs({ "Feral", "Guardian" }) do
            local o = { spec = spec, level = 22, known = { 5487, 768, 5221, 6807 } }
            assert.are.equal("shred", (cat(o)), spec)
            o.level, o.boss = 60, true
            assert.are.equal("shred", (cat(o)), spec .. " with Shred alone on a dungeon boss")
            o.known = { 768, 1082 }
            assert.are.equal("claw", (cat(o)), spec)
            o.distance = 15
            assert.is_nil((cat(o)), spec)
        end
    end)

    it("spends four points on a durable enemy and avoids a new bleed on a dying enemy", function()
        local o = {
            level = 30,
            known = { 768, 1082, 1822, 1079, 1328618 },
            points = 4,
            energy = 35,
            setup = function(_, c)
                c.classification = "elite"
            end,
        }
        assert.are.equal("rip", (cat(o)))
        o.enemyHealth = 190
        assert.are.equal("ferocious_bite", (cat(o)))
        o.enemyHealth, o.points, o.setup, o.energy = 1000, 5, nil, 30
        assert.are.equal("rip", (cat(o)))
        o.points, o.energy = 0, 50
        assert.are.equal("rake", (cat(o)))
    end)

    it("spends on Bite when Rip is unavailable or the target is known to resist bleeds", function()
        local o = { known = { 768, 1082, 1328618 }, points = 4, energy = 35 }
        assert.are.equal("ferocious_bite", (cat(o)))
        o.known = { 768, 1082, 1079, 1822, 1328618 }
        o.setup = function(H, c)
            c.guid.target = "Creature-0-0-0-0-114-00000001"
            H.Fire("PLAYER_TARGET_CHANGED")
        end
        assert.are.equal("ferocious_bite", (cat(o)))
    end)

    it("uses a five-point dungeon Rip when the group will fight long enough for the bleed", function()
        local seconds = 12
        local o = {
            level = 34,
            known = { 768, 1082, 1822, 1079, 1328618 },
            points = 4,
            talents = { [16958] = 1 }, -- Blood Frenzy would unlock the raid line at four points.
            setup = function(H, c)
                c.classification = "elite"
                H.Hekili.GetTTD = function()
                    return seconds
                end
                H.Hekili.GetGreatestTTD = H.Hekili.GetTTD
            end,
        }
        assert.are.equal("rake", (cat(o)))
        o.points = 5
        assert.are.equal("rip", (cat(o)))
        seconds = 3
        assert.are.equal("ferocious_bite", (cat(o)))
        o.points, seconds = 3, 0.5
        assert.are.equal("claw", (cat(o)), "the raid's two-point Bite does not bypass the field minimum")
        o.points = 4
        assert.are.equal("ferocious_bite", (cat(o)))
    end)

    it("spreads the player's Rake only to a confirmed eligible second enemy without stranding points", function()
        local o = {
            known = { 768, 1082, 1822 },
            swaps = true,
            plate = true,
            setup = function(H, c)
                c.exists.nameplate1target, c.inParty.nameplate1target = true, true
                c.unitIs.nameplate1target = "party1"
                aura(c, "target", 1822)
                H.Fire("UNIT_AURA", "target")
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
            end,
        }
        local function check(want, label)
            local key, out, H = cat(o)
            assert.are.equal(want, key == "rake" and out.recs[1].indicator == "cycle", label)
            return H
        end
        local H = check(true, "confirmed melee enemy")
        local c = H.ctl
        c.guid.target, c.unitIs.target = c.guid.nameplate1, "nameplate1"
        c.auras.target.HARMFUL = {}
        H.Fire("PLAYER_TARGET_CHANGED")
        H.Fire("UNIT_AURA", "target")
        assert(headless.cycle(H, c.now + 1.6))
        local landing = H.Hekili.Engine.Output.Primary.recs[1]
        assert.are.equal("rake", landing.actionName, "direct Rake on the selected eligible mob")
        assert.are_not.equal("cycle", landing.indicator)
        o.points = 3
        check(false, "points on priority target")
        o.points, o.swaps = 0, false
        check(false, "swaps off")
        o.swaps, o.plateDistance = true, 18
        check(false, "distant enemy")
        o.plateDistance, o.plate = 3, "idle"
        check(false, "idle enemy")
        local base = o.setup
        o.plate = true
        o.setup = function(H, c)
            base(H, c)
            c.auraError.nameplate1 = true
        end
        check(false, "unreadable auras")
        o.setup = function(H, c)
            base(H, c)
            aura(c, "nameplate1", 1822)
        end
        check(false, "already has our Rake")
        o.setup = function(H, c)
            base(H, c)
            aura(c, "nameplate1", 118, "party2")
        end
        check(false, "party Polymorph")
        o.setup = function(H, c)
            base(H, c)
            c.unitHealth.nameplate1, c.unitHealthMax.nameplate1 = 150, 1000
        end
        check(false, "dying secondary enemy")
        o.setup = function(H, c)
            base(H, c)
            c.unitIs.nameplate1target = "player"
        end
        check(false, "add attacking the Cat")
    end)
end)
