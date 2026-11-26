local headless = require("Game.harness.headless")
local W = require("Forever.helpers.druid_loop_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local fixture = require("Forever.helpers.feral_pve")
local druid, tank = fixture.druid, fixture.tank

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
    it("leaves travel forms alone and requires a bracket or positive spell range for a second attacker", function()
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
        assert.are.equal("bear_form", (druid(o)), "positive native melee range on the second enemy")
        local hideBracket = o.setup
        o.setup = function(H)
            hideBracket(H)
            local range = H.ns.Facade.C_Spell.IsSpellInRange
            H.ns.Facade.C_Spell.IsSpellInRange = function(id, unit)
                if unit == "nameplate1" then
                    return nil
                end
                return range(id, unit)
            end
        end
        assert.are.equal("claw", (druid(o)))
    end)
    it("uses Swipe for an engaged pack and stays in Bear as the pull thins", function()
        local o = { known = forms, combat = true, form = "bear_form", plate = true }
        assert.are.equal("swipe_bear", (druid(o)))
        o.plate = nil
        assert.are.equal("maul", (druid(o)))
    end)

    it("uses the hybrid Cat finisher when the selected outdoor enemy has time for two bleed ticks", function()
        local seconds = 6
        local o = {
            known = { 5487, 768, 1082, 1079, 1822, 1328618 },
            level = 30,
            form = "cat_form",
            combat = true,
            points = 3,
            setup = function(H)
                H.Hekili.GetTTD = function()
                    return seconds
                end
            end,
        }
        assert.are.equal("rip", (druid(o)))
        seconds = 5
        assert.are.equal("claw", (druid(o)))
        o.points, seconds = 4, 3
        assert.are.equal("ferocious_bite", (druid(o)))
        o.points = 3
        assert.are.equal("claw", (druid(o)))
        seconds = 3600
        assert.are.equal("rake", (druid(o)), "unmeasured ordinary enemy")
        o.enemyHealth = 200
        assert.are.equal("ferocious_bite", (druid(o)), "unmeasured dying enemy")
        seconds = 12
        assert.are.equal("rip", (druid(o)), "slow health loss even at low health")
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
        local setup = o.setup
        o.swaps, o.rage = true, 0
        o.setup = function(H, ctl)
            setup(H, ctl)
            ctl.cooldown[6795] = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 8 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
        end
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
    it("Swipes a confirmed outdoor pack with an idle mob in melee", function()
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
        assert.are.equal("swipe_bear", (druid(o)))
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

describe("Guardian in a dungeon party", function()
    it("offers a ranged pull to the tank before anyone enters combat", function()
        local o = { known = { 5487, 770, 6603 }, distance = 20 }
        assert.are.equal("faerie_fire", (tank(o)))
        o.role = "NONE"
        assert.are.equal("faerie_fire", (tank(o)))
        o.setup = function(_, ctl)
            ctl.exists.party2, ctl.groupRoles.party2 = true, "TANK"
        end
        assert.is_nil((tank(o)))
        o.setup = nil
        o.role = "DAMAGER"
        assert.is_nil((tank(o)))
        o.role, o.combat, o.idle = "TANK", true, true
        assert.is_nil((tank(o)))
        o.combat, o.setup =
            false, function(_, ctl)
                ctl.exists.party1, ctl.unitCombat.party1 = true, true
            end
        assert.is_nil((tank(o)))
        o.setup, o.distance = nil, 35
        assert.is_nil((tank(o)))
    end)

    it("opens with trained caster spells before Bear and stays in Bear once trained", function()
        local o = { level = 6, form = "caster", distance = 20, known = { 5177, 8921, 6603 } }
        assert.are.equal("wrath", (tank(o)))
        o.distance = 40
        assert.is_nil((tank(o)))
        o.level, o.form, o.distance, o.known = 12, "bear_form", 3, { 5487, 6807, 5177, 8921, 6603 }
        assert.are.equal("auto_attack", (tank(o)))
        o.distance = 20
        assert.is_nil((tank(o)))
    end)

    it("uses Roar on a held single enemy and prioritizes Growl on a loose one", function()
        local o = { known = { 5487, 99, 6807, 6795 }, combat = true }
        assert.are.equal("demoralizing_roar", (tank(o)))
        o.defensives = false
        assert.are.equal("maul", (tank(o)))
        o.defensives, o.victim, o.threat = true, "party1", 0
        assert.are.equal("growl", (tank(o)))
        o.victimRole = "TANK"
        assert.are.equal("maul", (tank(o)))
    end)

    it("updates the same party display from a ranged pull through a healer pickup and a target change", function()
        local opener, _, H = tank({ known = { 5487, 770, 6795, 6807, 6603 }, distance = 20 })
        assert.are.equal("faerie_fire", opener)
        local c = H.ctl
        local function nextIcon()
            assert(headless.cycle(H, c.now + 1.6))
            assert.are.same({}, H.errors)
            local out = H.Hekili.Engine.Output.Primary
            return out.count > 0 and out.recs[1].actionName or nil
        end
        c.combat, c.unitCombat.target, c.unitCombat.party1 = true, true, true
        c.exists.party1, c.isPlayer.party1, c.groupRoles.party1 = true, true, "HEALER"
        c.exists.targettarget, c.unitIs.targettarget, c.inParty.targettarget = true, "party1", true
        c.distance.target, c.threat.target, c.current[6603] = 3, 0, true
        c.cooldown[770] = { isActive = true, isOnGCD = false, startTime = c.now, duration = 6 }
        H.Fire("SPELL_UPDATE_COOLDOWN")
        H.Fire("PLAYER_REGEN_DISABLED")
        H.Fire("UNIT_THREAT_SITUATION_UPDATE", "player")
        assert.are.equal("growl", nextIcon())
        c.threat.target, c.unitIs.targettarget = 3, "player"
        H.Fire("UNIT_THREAT_SITUATION_UPDATE", "player")
        assert.are.equal("maul", nextIcon())
        c.guid.target, c.unitCombat.target, c.threat.target = "Creature-3", false, nil
        c.exists.targettarget, c.unitIs.targettarget = false, nil
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.is_nil(nextIcon())
        c.guid.target, c.unitCombat.target, c.threat.target = "Creature-4", true, 3
        c.exists.targettarget, c.unitIs.targettarget = true, "player"
        c.cooldown[770] = nil
        H.Fire("SPELL_UPDATE_COOLDOWN")
        H.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("faerie_fire", nextIcon())
    end)

    it("restarts swings on an engaged dungeon boss before the first point of Rage", function()
        local o = { level = 60, known = { 5487, 6603, 6807 }, combat = true, boss = true, rage = 0 }
        assert.are.equal("auto_attack", (tank(o)))
        o.setup = function(_, ctl)
            ctl.current[6603] = true
        end
        local action, out = tank(o)
        assert.are.equal("maul", action)
        assert.is_true(out.recs[1].time > 0, "Maul waits for incoming swing Rage")
        o.setup, o.distance, o.movement, o.rage = nil, 20, true, 40
        assert.is_nil((tank(o)))
        o.known = { 5487, 770, 6603, 6807 }
        assert.are.equal("faerie_fire", (tank(o)))
    end)

    it("retains a melee attack when the spell range is hidden but the distance is confirmed", function()
        local o = {
            known = { 5487, 6807 },
            combat = true,
            setup = function(H)
                H.ns.Facade.C_Spell.IsSpellInRange = function()
                    return nil, true
                end
            end,
        }
        assert.are.equal("maul", (tank(o)))
        o.distance = 20
        assert.is_nil((tank(o)))
    end)

    it("keeps a low-health tank in form when the healer enters combat first", function()
        local o = {
            known = { 5185, 5487, 6795, 6807 },
            health = 350,
            autoUnshift = "1",
            setup = function(_, c)
                c.unitCombat.target, c.unitCombat.party1 = true, true
                c.exists.party1, c.isPlayer.party1, c.groupRoles.party1 = true, true, "HEALER"
                c.exists.targettarget, c.unitIs.targettarget, c.inParty.targettarget = true, "party1", true
                c.threat.target = 0
            end,
        }
        assert.are.equal("growl", (tank(o)))
    end)

    it("uses the learned Bear single-target attack and switches filler for a safe pack", function()
        local o = { level = 44, known = { 5487, 6807, 779, 1328616, 407995 }, combat = true, rage = 50 }
        assert.are.equal("primal_bite", (tank(o)))
        o.setup = function(H, c)
            c.cooldown[407995] = { isActive = true, isOnGCD = false, startTime = c.now, duration = 6 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
        end
        assert.are.equal("lacerate", (tank(o)))
        o.plate = true
        assert.are.equal("swipe_bear", (tank(o)))
    end)

    it("keeps a damage-assigned Guardian in Cat when another party member tanks", function()
        local o =
            { known = forms, role = "DAMAGER", form = "caster", combat = true, victim = "party1", victimRole = "TANK" }
        assert.are.equal("cat_form", (tank(o)))
    end)

    it("recovers a raid healer on trash and leaves boss handoffs to the raid tanks", function()
        local o = {
            spec = "Guardian",
            instance = "raid",
            group = 10,
            role = "TANK",
            form = "bear_form",
            known = { 5487, 6795, 6807 },
            level = 60,
            combat = true,
            victim = "raid3",
            threat = 0,
            setup = function(_, ctl)
                ctl.inRaid.targettarget = 3
            end,
        }
        assert.are.equal("growl", (druid(o)))
        o.victimRole = "TANK"
        assert.are_not.equal("growl", (druid(o)))
        o.victimRole, o.boss = "HEALER", true
        assert.are_not.equal("growl", (druid(o)))
        o.boss = false
        o.setup = function(_, ctl)
            ctl.inRaid.targettarget, ctl.encounterInProgress = 3, true
            ctl.exists.boss1 = true
        end
        assert.are_not.equal("growl", (druid(o)))
    end)

    it("offers a trained action at every level with party combat already under way", function()
        local learn = require("Forever.wowsims.learn_druid")
        local kit = W.Guardian
        kit.character()
        W.Balance.character()
        local ranks = {
            maul = kit.IDS.maul,
            primal_bite = kit.IDS.primal_bite,
            lacerate = kit.IDS.lacerate,
            swipe_bear = kit.IDS.swipe_bear,
            faerie_fire = kit.IDS.faerie_fire,
            demoralizing_roar = kit.IDS.demoralizing_roar,
            wrath = W.Balance.IDS.wrath,
            moonfire = W.Balance.IDS.moonfire,
        }
        local tankLevels = { [1328617] = 25, [1328616] = 34 }
        for level = 1, 60 do
            local known = { 6603 }
            if level >= 10 then
                known[#known + 1] = 5487
            end
            if level >= 40 then
                known[#known + 1] = 9634
            end
            local highest = {}
            for key, family in pairs(ranks) do
                for _, id in ipairs(family) do
                    -- Tank talent path: Primal Bite at 40. The hotfixed Lacerate ranks precede the DB2 rows.
                    local trainedAt = tankLevels[id] or learn[id]
                    if trainedAt and trainedAt <= level and (key ~= "primal_bite" or level >= 40) then
                        highest[key] = id
                        known[#known + 1] = id
                    end
                end
            end
            local o = {
                level = level,
                known = known,
                form = level >= 10 and "bear_form" or "caster",
                combat = true,
                plate = level % 2 == 0,
                rage = 30,
                setup = function(_, ctl)
                    ctl.current[6603] = true
                end,
            }
            local action, out, H = tank(o)
            local label = "level " .. level
            assert.is_truthy(action, label .. " has a usable attack")
            assert.is_true(H.Hekili.State.spec.guardian, label)
            for i = 1, out.count do
                local key = out.recs[i].actionName
                local family = assert(ranks[key], label .. " unexpected action " .. key)
                local id = H.ns.VirtualState.KnownID(family[1])
                assert.is_true(H.ctl.known[id] == true, label .. " " .. key)
                assert.are.equal(highest[key], id, label .. " rank of " .. key)
                assert.are.equal(level < 10, key == "wrath" or key == "moonfire", label .. " " .. key)
            end
        end
    end)
end)
