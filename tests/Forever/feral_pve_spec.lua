local headless = require("Game.harness.headless")
local W = require("Forever.helpers.druid_loop_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function druid(o)
    local c = W.Feral.character()
    c.level, c.known, c.talents = o.level or 24, o.known, {}
    c.form = o.form and W.FORM[o.form] or 0
    c.power = { type = 0, token = "MANA", value = 3000, max = 3000 }
    c.instanceType = o.instance or "none"
    local H = headless.new({ character = c, pack = (o.spec or "Feral") .. " (wowsims.com)" })
    assert.are.same({}, H.loadErrors)
    local ctl = H.ctl
    ctl.cvars.autoSelfCast, ctl.cvars.enableMouseoverCast = o.selfCast or "1", "0"
    ctl.cvars.autoUnshift = o.autoUnshift or "0"
    ctl.groupMembers, ctl.inGroup = o.group or 0, (o.group or 0) > 1
    ctl.groupRoles.player = o.role or "NONE"
    ctl.distance.target, ctl.level.target = o.distance or 3, c.level
    ctl.unitCombat.target = o.combat == true and not o.idle
    if ctl.unitCombat.target then
        ctl.exists.targettarget, ctl.unitIs.targettarget = true, o.victim or "player"
        ctl.threat.target = o.threat or 3
    end
    if o.victim then
        ctl.exists[o.victim], ctl.isPlayer[o.victim], ctl.inParty.targettarget = true, true, true
        ctl.groupRoles[o.victim] = o.victimRole or "HEALER"
    end
    if o.plate then
        local p = "nameplate1"
        ctl.exists[p], ctl.guid[p], ctl.distance[p] = true, "Creature-2", o.plateDistance or 3
        ctl.unitCombat[p], ctl.threat[p], ctl.unitIs.nameplate1target = o.plate == true, 3, "player"
        H.Fire("NAME_PLATE_UNIT_ADDED", p)
    end
    ctl.healthPlain = o.health ~= SECRET
    ctl.unitHealth.player, ctl.unitHealthMax.player = o.health or 1000, 1000
    ctl.unitHealth.target, ctl.unitHealthMax.target = o.enemyHealth or 1000, 1000
    ctl.ranges[5176], ctl.ranges[8921], ctl.ranges[770], ctl.ranges[1238122] =
        { 0, 30 }, { 0, 30 }, { 0, 30 }, { 8, 25 }
    if o.noTarget then
        ctl.exists.target = false
    end
    H.Hekili:FireToggle("defensives", o.defensives == false and "off" or "on")
    H.Hekili:FireToggle("movement", o.movement and "on" or "off")
    H.Hekili:FireToggle("interrupts", o.interrupts and "on" or "off")
    H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = o.swaps == true
    H.Fire("PLAYER_TARGET_CHANGED")
    if o.combat then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    if o.setup then
        o.setup(H, ctl)
    end
    local pools = {}
    for pt, value in pairs({ [0] = o.mana or 3000, [1] = o.rage or 30, [3] = 100, [4] = o.points or 0 }) do
        pools[pt] = { lo = value, est = value, hi = value, conf = 1 }
    end
    H.ns.VirtualState.Power = function(pt)
        return pools[pt]
    end
    local display = o.display or "Primary"
    assert.is_true(H.Hekili.Engine.Subscribe(display, function() end))
    assert(headless.cycle(H, ctl.now + 1.6))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output[display]
    return out.count > 0 and out.recs[1].actionName or nil, out, H
end

local forms = { 5487, 768, 6807, 1082, 779 }
describe("Feral leveling and group tanking", function()
    it("opens in caster form before the Bear quest, then uses Bear before Cat is trained", function()
        assert.are.equal("wrath", (druid({ level = 1, known = { 5176 }, distance = 20 })))
        assert.are.equal("bear_form", (druid({ level = 10, known = { 5487, 6807, 5177 } })))
    end)
    it("starts a melee swing after a heal leaves too little mana to shift", function()
        local o = { level = 10, known = { 6603, 5487, 6807 }, combat = true, mana = 0 }
        assert.are.equal("auto_attack", (druid(o)))
        o.distance = 20
        assert.are_not.equal("auto_attack", (druid(o)))
    end)
    it("starts ordinary outdoor pulls in Cat and keeps a party tank in Bear", function()
        assert.are.equal("cat_form", (druid({ known = forms })))
        assert.are.equal(
            "bear_form",
            (druid({ known = forms, form = "cat_form", group = 5, instance = "party", role = "TANK" }))
        )
        assert.are.equal("bear_form", (druid({ known = forms, form = "cat_form", group = 3, instance = "party" })))
    end)
    it("shifts for a second engaged melee enemy and ignores idle or distant bystanders", function()
        for _, group in ipairs({ 0, 3 }) do
            local o = { known = forms, form = "cat_form", group = group, combat = true, plate = true }
            assert.are.equal("bear_form", (druid(o)))
            o.plateDistance = 20
            assert.are.equal("claw", (druid(o)))
            o.plateDistance, o.plate = 3, "idle"
            assert.are.equal("claw", (druid(o)))
        end
    end)
    it("leaves travel forms alone and treats an unreadable plate range as unknown", function()
        for _, form in ipairs({ "travel_form", "aquatic_form" }) do
            assert.is_nil((druid({ known = { 5487, 768, 1082, 783, 1066 }, form = form })))
        end
        local o = {
            known = forms,
            form = "cat_form",
            combat = true,
            plate = true,
            setup = function(H)
                local lib = H.ns.Facade.LibRangeCheck
                local getRange = lib.GetRange
                lib.GetRange = function(self, unit, ...)
                    if unit == "nameplate1" then
                        return SECRET, SECRET
                    end
                    return getRange(self, unit, ...)
                end
            end,
        }
        assert.are.equal("claw", (druid(o)))
    end)
    it("uses Swipe for an engaged pack and stays in Bear as the pull thins", function()
        local o = { known = forms, combat = true, form = "bear_form", plate = true }
        assert.are.equal("swipe_bear", (druid(o)))
        o.plate = nil
        local first = druid(o)
        assert.is_true(first == "swipe_bear" or first == "maul", tostring(first))
    end)
    it("recovers a groupmate with Growl only with confirmed loose melee threat", function()
        local o = {
            known = { 5487, 6795, 6807 },
            form = "bear_form",
            combat = true,
            instance = "party",
            group = 5,
            role = "TANK",
            victim = "party1",
            threat = 0,
        }
        assert.are.equal("growl", (druid(o)))
        for _, change in ipairs({
            { "victimRole", "TANK" },
            { "threat", 3 },
            { "threat", SECRET },
            { "distance", 20 },
            { "role", "DAMAGER" },
            { "idle", true },
        }) do
            local key, old = change[1], o[change[1]]
            o[key] = change[2]
            assert.are_not.equal("growl", (druid(o)), key)
            o[key] = old
        end
    end)
    it("recovers between pulls and keeps an active group tank in form", function()
        local o = { known = { 5185, 5487, 6807 }, level = 10, health = 350, noTarget = true }
        assert.are.equal("healing_touch", (druid(o)))
        o.health = 950
        assert.are_not.equal("healing_touch", (druid(o)))
        o.health, o.form = 350, "bear_form"
        assert.are.equal("cancel_buff", (druid(o)))
        o.combat, o.group, o.role, o.noTarget = true, 5, "TANK", false
        assert.are.equal("maul", (druid(o)))
    end)
    it("offers affordable in-form emergency recovery and respects the defensive toggle", function()
        local o = { level = 44, known = { 5487, 6807, 22812, 22842 }, form = "bear_form", health = 230, combat = true }
        assert.are.equal("frenzied_regeneration", (druid(o)))
        o.rage = 0
        assert.are.equal("barkskin", (druid(o)))
        o.rage, o.defensives = 30, false
        assert.are.equal("maul", (druid(o)))
    end)
    it("keeps other tanks' assignments and idle dungeon targets out of the pickup rotation", function()
        local o = {
            known = forms,
            form = "cat_form",
            group = 5,
            instance = "party",
            setup = function(_, ctl)
                ctl.exists.party2, ctl.groupRoles.party2 = true, "TANK"
            end,
        }
        assert.are_not.equal("bear_form", (druid(o)))
        o.role = "TANK"
        assert.are.equal("bear_form", (druid(o)))
        o.form, o.level = "bear_form", 60
        assert.is_nil((druid(o)))
    end)
    it("seeks a loose visible mob only with target swaps and a confirmed party victim", function()
        local o = {
            known = { 5487, 6795, 6807 },
            form = "bear_form",
            group = 5,
            instance = "party",
            combat = true,
            role = "TANK",
            plate = true,
            swaps = true,
            setup = function(H, ctl)
                ctl.exists.party1, ctl.groupRoles.party1, ctl.isPlayer.party1 = true, "HEALER", true
                ctl.exists.nameplate1target, ctl.unitIs.nameplate1target, ctl.threat.nameplate1 = true, "party1", 0
                H.ns.getNumberTargets = function()
                    return 2, 2
                end
            end,
        }
        local action, out = druid(o)
        assert.are.equal("recover_threat", action)
        assert.are.equal("cycle", out.recs[1].indicator)
        o.swaps = false
        assert.are_not.equal("recover_threat", (druid(o)))
    end)
    it("uses Bash in melee and the Bear charge talent only at its interrupt range", function()
        local function cast(event)
            return function(H)
                H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
                if event then
                    H.Fire(event, "target")
                end
            end
        end
        local o = {
            known = { 5487, 6807, 5211, 1238122 },
            form = "bear_form",
            combat = true,
            interrupts = true,
            setup = cast("UNIT_SPELLCAST_INTERRUPTIBLE"),
        }
        assert.are.equal("bash", (druid(o)))
        o.distance = 12
        assert.are.equal("feral_charge", (druid(o)))
        o.distance = 26
        assert.are_not.equal("feral_charge", (druid(o)))
        o.distance, o.setup = 12, cast("UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
        assert.are_not.equal("feral_charge", (druid(o)))
        o.distance, o.setup = 3, cast()
        assert.are_not.equal("bash", (druid(o)))
    end)
    it("uses the native health thresholds when combat health is hidden", function()
        local o = { known = { 5487, 6807, 22812, 22842 }, form = "bear_form", combat = true, health = SECRET }
        local action, out = druid(o)
        assert.are.equal("maul", action)
        local bands = {}
        for i = 1, out.healthCues.n do
            local cue = out.healthCues[i]
            bands[cue.action] = cue.percent
        end
        assert.are.equal(25, bands.frenzied_regeneration)
        assert.are.equal(60, bands.barkskin)
    end)
    it("uses auto-unshift for a self heal only when the cast can actually reach the player", function()
        local o = { level = 10, known = { 5185, 5487, 6807 }, health = 350, form = "bear_form", autoUnshift = "1" }
        assert.are.equal("healing_touch", (druid(o)))
        o.selfCast = "0"
        assert.are_not.equal("healing_touch", (druid(o)))
        o.selfCast, o.autoUnshift, o.mana = "1", "0", 0
        assert.are_not.equal("cancel_buff", (druid(o)))
    end)
    it("routes self healing to a separate Defensives display when configured", function()
        local o = {
            level = 10,
            known = { 5185, 5487 },
            health = 350,
            noTarget = true,
            setup = function(H)
                H.Hekili.DB.profile.toggles.defensives.separate = true
                H.Hekili:SettingsChanged("toggles")
            end,
        }
        assert.are_not.equal("healing_touch", (druid(o)))
        o.display = "Defensives"
        assert.are.equal("healing_touch", (druid(o)))
        o.form = "bear_form"
        assert.are.equal("cancel_buff", (druid(o)))
    end)
    it("does not Swipe through an idle bystander even if another mob is engaged", function()
        local o = {
            known = forms,
            form = "bear_form",
            combat = true,
            plate = true,
            setup = function(H, ctl)
                ctl.exists.nameplate2, ctl.distance.nameplate2, ctl.guid.nameplate2 = true, 3, "Creature-3"
                ctl.unitCombat.nameplate2 = false
                H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
            end,
        }
        assert.are.equal("maul", (druid(o)))
    end)
    it("keeps both packs flexible outdoors and shifts a Cat under direct pressure", function()
        for _, spec in ipairs({ "Feral", "Guardian" }) do
            local o = { spec = spec, known = forms, form = "bear_form" }
            assert.are.equal("cat_form", (druid(o)))
            o.form, o.health, o.combat = "cat_form", 300, true
            assert.are.equal("bear_form", (druid(o)))
            o.defensives = false
            assert.are.equal("claw", (druid(o)))
        end
    end)
    it("uses the learned poison or curse dispel only for a confirmed affliction", function()
        local typ = "Poison"
        local o = {
            known = { 8946, 2782 },
            noTarget = true,
            setup = function(H, ctl)
                ctl.auras.player.HARMFUL = {
                    {
                        spellId = 999001,
                        dispelName = typ,
                        duration = 20,
                        expirationTime = ctl.now + 20,
                        applications = 1,
                    },
                }
                H.Fire("UNIT_AURA", "player")
            end,
        }
        assert.are.equal("cure_poison", (druid(o)))
        typ = "Curse"
        assert.are.equal("remove_curse", (druid(o)))
        typ = SECRET
        assert.is_nil((druid(o)))
    end)
    it("uses direct finishing damage on a visibly dying target with two combo points", function()
        local o = {
            level = 24,
            known = { 768, 1082, 1822, 1328618 },
            form = "cat_form",
            combat = true,
            points = 2,
            enemyHealth = 200,
        }
        assert.are.equal("ferocious_bite", (druid(o)))
        o.enemyHealth = 950
        assert.are_not.equal("ferocious_bite", (druid(o)))
    end)
end)
