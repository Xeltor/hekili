local F = require("Forever.helpers.feral_pve")
local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function loosePack(options, adjust)
    local o = options or {}
    o.spec, o.instance, o.role, o.group = "Guardian", o.instance or "party", o.role or "TANK", 5
    o.level, o.combat, o.form = o.level or 36, o.combat ~= false, o.form or "bear_form"
    o.known = o.known or { 5487, 6807, 6795, 5209, 5211 }
    o.plate, o.victim, o.threat = true, "party1", 0
    o.setup = function(H, c)
        c.exists.party2, c.isPlayer.party2, c.groupRoles.party2 = true, true, "DAMAGER"
        c.level.nameplate1 = 36
        c.exists.nameplate1target, c.unitIs.nameplate1target = true, "party2"
        c.inParty.nameplate1target, c.threat.nameplate1 = true, 1
        if adjust then
            adjust(H, c)
        end
    end
    return F.druid(o)
end

describe("Guardian emergency threat and regeneration", function()
    it("uses Challenging Roar on two loose enemies inside its ten-yard effect before single-target Growl", function()
        assert.are.equal("challenging_roar", (loosePack({ rage = 15, plateDistance = 8 })))
        assert.are.equal("growl", (loosePack({ level = 27, known = { 5487, 6807, 6795 } })))
        assert.are.equal("growl", (loosePack({ rage = 14 })))
        assert.are.equal("growl", (loosePack({ plateDistance = 20 })))
        assert.are_not.equal("challenging_roar", (loosePack({ defensives = false })))
        assert.are_not.equal("challenging_roar", (loosePack({ instance = "none" })))
        assert.are_not.equal("challenging_roar", (loosePack({ instance = "raid" })))
        assert.are_not.equal("challenging_roar", (loosePack({ role = "DAMAGER" })))
        assert.are_not.equal("challenging_roar", (loosePack({ boss = true })))
        assert.are_not.equal("challenging_roar", (loosePack({ form = "cat_form" })))
        local first = loosePack({}, function(H)
            H.Hekili:FireToggle("mode", "single")
        end)
        assert.are_not.equal("challenging_roar", first)
    end)

    it("rescues two nearby adds even with a distant target or no target and never initiates a fresh pull", function()
        local function adds(H, c)
            c.exists.nameplate2, c.guid.nameplate2, c.level.nameplate2 = true, "Creature-3", 36
            c.distance.nameplate2, c.unitCombat.nameplate2, c.threat.nameplate2 = 3, true, 0
            c.exists.nameplate2target, c.unitIs.nameplate2target, c.inParty.nameplate2target = true, "party1", true
            H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        end
        assert.are.equal("challenging_roar", (loosePack({ distance = 35 }, adds)))
        assert.are.equal("challenging_roar", (loosePack({ noTarget = true }, adds)))
        assert.are_not.equal("challenging_roar", (loosePack({ noTarget = true, combat = false }, adds)))
        local first = loosePack({ noTarget = true, combat = false }, function(H, c)
            adds(H, c)
            c.unitCombat.party1, c.unitCombat.party2 = true, true
        end)
        assert.are.equal("challenging_roar", first)
    end)

    it("does not count a loose mob with an observed taunt immunity", function()
        for _, key in ipairs({ "growl", "challenging_roar" }) do
            local first = loosePack({}, function(H)
                local original = H.ns.Facade.DebuffImmunity
                H.ns.Facade.DebuffImmunity = function(aura, guid, time)
                    return aura == key and guid == "Creature-2" or original(aura, guid, time)
                end
            end)
            assert.are_not.equal("challenging_roar", first)
        end
    end)

    it("requires two confirmed loose mobs and holds Roar on boss encounters", function()
        for _, change in ipairs({
            function(c)
                c.unitIs.nameplate1 = "target"
            end,
            function(c)
                c.unitCombat.nameplate1 = false
            end,
            function(c)
                c.threat.nameplate1 = SECRET
            end,
            function(c)
                c.groupRoles.party2 = "TANK"
            end,
            function(c)
                c.groupRoles.party2 = "NONE"
            end,
            function(c)
                c.dead.party2 = true
            end,
            function(c)
                c.level.nameplate1 = -1
            end,
            function(c)
                c.encounterInProgress = true
            end,
            function(c)
                c.exists.boss1 = true
            end,
        }) do
            local first = loosePack({}, function(_, c)
                change(c)
            end)
            assert.are_not.equal("challenging_roar", first)
        end
    end)

    it("uses Roar for two confirmed loose enemies regardless of other plates or readable control", function()
        local distance, idle = 3, false
        local function third(H, c)
            c.exists.party3, c.isPlayer.party3, c.groupRoles.party3 = true, true, "TANK"
            c.exists.nameplate2, c.guid.nameplate2, c.level.nameplate2 = true, "Creature-3", 36
            c.distance.nameplate2, c.unitCombat.nameplate2, c.threat.nameplate2 = distance, not idle, 0
            c.exists.nameplate2target, c.unitIs.nameplate2target, c.inParty.nameplate2target = true, "party3", true
            c.auras.nameplate1 = { HARMFUL = { { spellId = 118, sourceUnit = "party2" } }, HELPFUL = {} }
            c.auras.target.HARMFUL = { { spellId = SECRET, sourceUnit = "party2" } }
            H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        end
        assert.are.equal("challenging_roar", (loosePack({}, third)))
        idle = true
        assert.are.equal("challenging_roar", (loosePack({}, third)))
        distance = SECRET
        assert.are.equal("challenging_roar", (loosePack({}, third)))
    end)

    it("keeps an urgent interrupt ahead of the group taunt and routes the taunt to Defensives", function()
        local first = loosePack({ interrupts = true }, function(H)
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
            H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        end)
        assert.are.equal("bash", first)
        local function separate(H)
            H.Hekili.DB.profile.toggles.defensives.separate = true
            H.Hekili:SettingsChanged("toggles")
        end
        assert.are_not.equal("challenging_roar", (loosePack({}, separate)))
        local pick, out, H = loosePack({ display = "Defensives" }, separate)
        assert.are.equal("challenging_roar", pick)
        local rage = H.ns.VirtualState.Power(1)
        for _, amount in ipairs({ 14, 15 }) do
            rage.lo, rage.est, rage.hi = amount, amount, amount
            assert(headless.cycle(H, H.ctl.now + 0.25))
            assert.are.equal(amount >= 15, out.count > 0 and out.recs[1].actionName == "challenging_roar")
        end
    end)

    it("keeps a separate interrupt forecast from spending the defensive display's Rage", function()
        local pick, _, H = loosePack({ interrupts = true, rage = 15, display = "Defensives" }, function(H)
            local profile = H.Hekili.DB.profile
            profile.toggles.interrupts.separate = true
            profile.toggles.defensives.separate = true
            profile.displays.Interrupts.numIcons = 2
            H.Hekili:SettingsChanged()
            assert.is_true(H.Hekili.Engine.Subscribe("Interrupts", function() end))
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
            H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
        end)
        local interrupt = H.Hekili.Engine.Output.Interrupts.recs[1]
        assert.are.equal("bash", interrupt.actionName)
        assert.are.equal(0, interrupt.time)
        assert.are.equal(10, interrupt.cost)
        assert.are.equal("challenging_roar", pick)
    end)

    it("converts banked Rage early only under repeated heavy damage on a held dungeon pack", function()
        local wounds = { 120, 110 }
        local o = {
            level = 44,
            combat = true,
            plate = true,
            known = { 5487, 6807, 22842 },
            health = 500,
            rage = 30,
            setup = function(H)
                for _, amount in ipairs(wounds) do
                    H.Fire("UNIT_COMBAT", "player", "WOUND", nil, amount, 1)
                end
            end,
        }
        assert.are.equal("frenzied_regeneration", (F.tank(o)))
        o.health = SECRET
        local first, out = F.tank(o)
        assert.are_not.equal("frenzied_regeneration", first)
        local threshold
        for i = 1, out.healthCues.n do
            local cue = out.healthCues[i]
            if cue.action == "frenzied_regeneration" then
                threshold = cue.percent
            end
        end
        assert.are.equal(55, threshold)
        o.health = 560
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.health, o.defensives = 500, false
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.defensives, o.rage = true, 29
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.rage, o.plate = 30, false
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.plate, o.victim, o.threat = true, "party1", 0
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.victim, o.threat, wounds = nil, 3, { 240 }
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        wounds = { 120, SECRET }
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        local hit = o.setup
        wounds = { 120, 110 }
        o.setup = function(H)
            hit(H)
            H.Fire("PLAYER_REGEN_ENABLED")
            H.Fire("PLAYER_REGEN_DISABLED")
        end
        assert.are_not.equal("frenzied_regeneration", (F.tank(o)))
        o.health, o.rage = 200, 10
        assert.are.equal("frenzied_regeneration", (F.tank(o)))
    end)
end)
