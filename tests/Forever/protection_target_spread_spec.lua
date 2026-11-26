local fixture = require("Forever.helpers.protection_leveling")
local SECRET = require("Game.State.helpers.fake_api").SECRET

describe("Protection's optional target spreading", function()
    local instances = {}

    local function boot(options)
        options = options or {}
        local H = fixture.warrior(options.level or 28, options.rage or 60, {
            group = options.solo and 0 or options.group or 5,
            instance = options.instance or "party",
            threat = 3,
            classification = options.classification or "elite",
            revenge = options.revenge,
            talents = options.talents,
            health = options.health,
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
        return H, counts, addPlate, classifications
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

    local function showPrimarySwap(H)
        local engine = H.Hekili.Engine
        assert.are.same({ "rend", "cycle" }, { first(H) })
        assert.is_false(engine.Output.status.swapPending, "an unpublished-to-screen recommendation cannot arm recovery")
        local d = H.env.HekiliDisplayPrimary
        d:UpdateAlpha()
        d.__scripts.OnUpdate(d, 0.2)
        assert.is_true(d.Buttons[1].swapShown)
        assert.is_true(engine.Output.status.swapPending)
    end

    local function onlySpread(H, key)
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

    describe("party threat recovery", function()
        local function threatPull(options)
            local H, counts, addPlate = boot(options)
            addPlate(2)
            -- The current target and both nearby enemies are already covered. Only plate 1 attacks a party member.
            counts.rend, counts.sunder_armor = 3, 3
            H.ctl.threat.nameplate1, H.ctl.unitIs.nameplate1target = 0, "party1"
            H.ctl.exists.party1, H.ctl.isPlayer.party1 = true, true
            H.ctl.inParty.nameplate1target, H.ctl.isPlayer.nameplate1target = true, true
            H.ctl.groupRoles.player, H.ctl.groupRoles.party1 = "TANK", "HEALER"
            H.ctl.threat.nameplate2 = 3
            H.ctl.level.nameplate1, H.ctl.level.nameplate2 = H.ctl.level.target, H.ctl.level.target
            return H, addPlate, counts
        end

        local function selectPlate(H, unit, restricted)
            H.ctl.guid.target = H.ctl.guid[unit]
            H.ctl.unitIs.nameplate1, H.ctl.unitIs.nameplate2 = nil, nil
            H.ctl.unitIs.target, H.ctl.unitIs[unit] = unit, "target"
            H.ctl.threat.target = H.ctl.threat[unit]
            H.ctl.unitIs.targettarget = H.ctl.unitIs[unit .. "target"]
            H.ctl.inParty.targettarget = H.ctl.inParty[unit .. "target"]
            H.ctl.unitCombat.target = H.ctl.unitCombat[unit]
            if restricted then
                H.ctl.threat.target, H.ctl.unitCombat.target, H.ctl.distance.target = SECRET, SECRET, SECRET
                H.ctl.exists.targettarget, H.ctl.unitIs.targettarget = SECRET, SECRET
            end
            H.Fire("PLAYER_TARGET_CHANGED")
        end

        it("leads with ready Thunder Clap before requesting the loose enemy", function()
            local H = threatPull()
            for _, rank in ipairs({ 6343, 8198, 8204, 8205, 11580, 11581 }) do
                H.ctl.cooldown[rank] = nil
            end
            H.Fire("SPELL_UPDATE_COOLDOWN")
            assert.are.same({ "thunder_clap" }, { first(H) })
        end)

        it("lets the Clap pickup proceed while fear holds single-target recovery", function()
            for _, fearCount in ipairs({ false, 1 }) do
                local H = threatPull()
                local count = H.ns.Facade.DebuffCount
                H.ns.Facade.DebuffCount = function(id, now)
                    if id == 20511 then
                        return fearCount or nil
                    end
                    return count(id, now)
                end
                for _, rank in ipairs({ 6343, 8198, 8204, 8205, 11580, 11581 }) do
                    H.ctl.cooldown[rank] = nil
                end
                H.Fire("SPELL_UPDATE_COOLDOWN")
                assert.are.same({ "thunder_clap" }, { first(H) })
                local state = H.Hekili.State
                state.reset("Primary")
                assert.is_true(state.prot_clap_pickup)
                assert.is_false(state.prot_recovery_pack)
            end
        end)

        it("passes a secure mob and resumes threat attacks on the already-Sundered loose mob", function()
            local H = threatPull()
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            local display = H.env.HekiliDisplayPrimary
            local button, art = display.Buttons[1]
            button.TargetSwap.SetTexture = function(_, texture)
                art = texture
            end
            H.ns.UI.BuildTargetSwap(button)
            display:UpdateAlpha()
            display.__scripts.OnUpdate(display, 0.2)
            assert.are.equal(H.Hekili.TargetSwapTexture, art)
            assert.is_true(button.swapShown)
            selectPlate(H, "nameplate2")
            assert.are.same({ "recover_threat", "cycle" }, { first(H) }, "secure landing")
            display.__scripts.OnUpdate(display, 0.2)
            assert.is_true(button.swapShown, "the first button still shows the learned switch icon")
            selectPlate(H, "nameplate1")
            assert.are.same({ "sunder_armor" }, { first(H) }, "full Sunder stacks still allow a threat cast")
            assert.is_nil(H.Hekili.Engine.Output.status.targetNavigation)
            display.__scripts.OnUpdate(display, 0.2)
            assert.is_falsy(button.swapShown)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-recover", 7405)
            H.ctl.threat.target, H.ctl.unitIs.targettarget = 3, "player"
            H.ctl.threat.nameplate1, H.ctl.unitIs.nameplate1target = 3, "player"
            H.ctl.threat.nameplate2, H.ctl.unitIs.nameplate2target = 1, "party1"
            H.ctl.inParty.targettarget, H.ctl.inParty.nameplate1target = false, false
            H.ctl.inParty.nameplate2target, H.ctl.isPlayer.nameplate2target = true, true
            assert.are.equal("recover_threat", fixture.read(H, 1.6), "another mob changed to the healer")
            assert.are.equal("cycle", H.Hekili.Engine.Output.Primary.recs[1].indicator)
        end)

        it("uses positively matched dungeon plates when direct target and victim reads are restricted", function()
            local H = threatPull()
            H.ctl.guid.nameplate1, H.ctl.guid.nameplate2 = SECRET, SECRET
            selectPlate(H, "nameplate2", true)
            assert.are.equal(
                H.ns.VirtualStateInternal.plateID[2],
                H.ns.Facade.TargetMemoryKey(),
                "the selected enemy is identified by the plate's stable ID"
            )
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            local display = H.env.HekiliDisplayPrimary
            display:UpdateAlpha()
            display.__scripts.OnUpdate(display, 0.2)
            assert.is_true(H.Hekili.Engine.Output.status.swapPending)
            selectPlate(H, "nameplate1", true)
            assert.are.same({ "sunder_armor" }, { first(H) }, "confirmed melee plate on the group's healer")
            assert.is_nil(H.Hekili.Engine.Output.status.targetNavigation)
        end)

        it("rejects unmatched plates and respects conflicting direct target evidence under restrictions", function()
            for _, reason in ipairs({ "no match", "idle", "dead", "secure co-tank" }) do
                local H = threatPull()
                H.ctl.guid.nameplate1, H.ctl.guid.nameplate2 = SECRET, SECRET
                selectPlate(H, "nameplate2", true)
                if reason == "no match" then
                    H.ctl.unitIs.nameplate2, H.ctl.unitIs.target = nil, SECRET
                    H.Fire("PLAYER_TARGET_CHANGED")
                elseif reason == "idle" then
                    H.ctl.unitCombat.target = false
                elseif reason == "dead" then
                    H.ctl.dead.target = true
                else
                    H.ctl.threat.target, H.ctl.exists.targettarget, H.ctl.unitIs.targettarget = 3, true, "party2"
                    H.ctl.exists.party2, H.ctl.isPlayer.party2, H.ctl.groupRoles.party2 = true, true, "TANK"
                end
                noSwap(H, reason)
            end
        end)

        it("keeps a selected loose target for normal threat attacks", function()
            local H = threatPull()
            H.ctl.threat.target, H.ctl.unitIs.targettarget, H.ctl.inParty.targettarget = 0, "party2", true
            assert.are.same({ "sunder_armor" }, { first(H) })
        end)

        it("helps unassigned parties but leaves another tank's target alone", function()
            local H = threatPull()
            H.ctl.groupRoles.player, H.ctl.groupRoles.party1 = "NONE", "NONE"
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            H.ctl.groupRoles.party1 = "TANK"
            noSwap(H, "another tank")
            H.ctl.groupRoles.party1, H.ctl.mainTank.party1 = "NONE", true
            noSwap(H, "assigned main tank")
            H.ctl.mainTank.party1, H.ctl.groupRoles.player = false, "DAMAGER"
            noSwap(H, "player is not tanking")
            H.ctl.groupRoles.player, H.ctl.groupRoles.party1 = "TANK", SECRET
            noSwap(H, "unreadable role")
        end)

        it("recovers from landing on an idle enemy without offering an attack on it", function()
            local H = threatPull()
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            local display = H.env.HekiliDisplayPrimary
            display:UpdateAlpha()
            display.__scripts.OnUpdate(display, 0.2)
            H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-idle", false
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.is_nil(fixture.read(H, 0.2))
            assert.are.equal("cycle_previous", H.Hekili.Engine.Output.status.targetNavigation)
            selectPlate(H, "nameplate1")
            assert.are.same({ "sunder_armor" }, { first(H) })
            assert.is_nil(H.Hekili.Engine.Output.status.targetNavigation)
        end)

        it("ignores idle, secure, distant and unrelated enemies", function()
            for _, reason in ipairs({ "idle", "secure", "distant", "unrelated", "unknown threat", "idle origin" }) do
                local H = threatPull()
                if reason == "idle" then
                    H.ctl.unitCombat.nameplate1 = false
                elseif reason == "secure" then
                    H.ctl.threat.nameplate1 = 3
                elseif reason == "distant" then
                    H.ctl.distance.nameplate1 = 24
                elseif reason == "unrelated" then
                    H.ctl.unitIs.nameplate1target, H.ctl.inParty.nameplate1target = "outside", false
                elseif reason == "unknown threat" then
                    H.ctl.threat.nameplate1 = SECRET
                else
                    H.ctl.unitCombat.target = false
                end
                noSwap(H, reason)
            end
        end)

        it("respects the existing swap setting, single-target mode and solo play", function()
            for _, context in ipairs({ "disabled", "single", "solo" }) do
                local H = threatPull({ solo = context == "solo" })
                if context == "disabled" then
                    H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
                elseif context == "single" then
                    H.Hekili:FireToggle("mode", "single")
                end
                noSwap(H, context)
            end
        end)

        it("recovers a grouped outdoor pull with either an assigned tank or observable unassigned tanking", function()
            for _, role in ipairs({ "TANK", "NONE" }) do
                local H = threatPull({ instance = "none" })
                H.ctl.groupRoles.player, H.ctl.groupRoles.party1 = role, role == "NONE" and "NONE" or "DAMAGER"
                assert.are.same({ "recover_threat", "cycle" }, { first(H) })
                H.ctl.threat.target = SECRET
                noSwap(H, "the current enemy is not confirmed under control")
            end
        end)

        it("lets a solo outdoor warrior build Rage safely and protect low health", function()
            for _, health in ipairs({ 1000, 180 }) do
                local H =
                    fixture.warrior(12, 5, { instance = "none", health = health, potion = true, bloodrageReady = true })
                instances[#instances + 1] = H
                H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = true
                local action = fixture.read(H)
                if health == 1000 then
                    assert.are.equal("bloodrage", action)
                else
                    assert.are.equal("healing_potion", action)
                end
                assert.are_not.equal("taunt", action)
                assert.are_not.equal("recover_threat", action)
            end
        end)

        it("finishes a single controlled outdoor enemy with Execute in a legal stance", function()
            for _, form in ipairs({ 1, 2 }) do
                local H = fixture.warrior(
                    24,
                    35,
                    { instance = "none", classification = "normal", noShield = true, form = form }
                )
                H.ctl.usable[5308] = { true, false }
                H.Fire("SPELL_UPDATE_USABLE")
                if form == 1 then
                    assert.are.equal("execute", fixture.read(H))
                else
                    assert.are_not.equal("execute", fixture.read(H), "Defensive Stance")
                end
            end
        end)

        it("keeps an observed caster's interrupt reserve ahead of the outdoor finisher", function()
            local H = fixture.warrior(24, 35, {
                instance = "none",
                classification = "normal",
                target = "Creature-0-0-0-0-346-000001",
                form = 1,
            })
            -- Stay in Battle Stance with a shield so Bash and Execute are both legal.
            H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].abilities.defensive_stance.disabled = true
            H.ctl.usable[5308] = { true, false }
            H.Fire("SPELL_UPDATE_USABLE")
            assert.are.equal("execute", fixture.read(H))
            fixture.cast(H, true)
            assert.are.equal("shield_bash", fixture.read(H, 0.2))
            H.Fire("UNIT_SPELLCAST_STOP", "target", SECRET, SECRET, 77)
            assert.are_not.equal("execute", fixture.read(H, 0.2))
            assert.are.equal(10, H.Hekili.State.prot_bash_reserve)
            H.Hekili:FireToggle("interrupts", "off")
            assert.are.equal("execute", fixture.read(H))
        end)

        it("keeps the current target when the tank cannot afford a threat attack", function()
            local H = threatPull({ rage = 0 })
            assert.are_not.equal("recover_threat", first(H))
            selectPlate(H, "nameplate1")
            assert.are_not.equal("taunt", first(H), "empty Rage without a recovery attempt cannot authorize Taunt")
        end)

        it("can recover with an affordable Revenge proc at low Rage", function()
            local H = threatPull({ rage = 6, revenge = true })
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            selectPlate(H, "nameplate1")
            assert.are.same({ "revenge" }, { first(H) })
            H = threatPull({ rage = 6, revenge = false })
            assert.are_not.equal("recover_threat", first(H), "neither Revenge nor Sunder can be used")
        end)

        it("preserves emergency defenses while recovering, then resumes damage on a secure pack", function()
            local H = threatPull({ level = 60, health = 180, talents = { [12975] = 1, [23922] = 1 } })
            H.Hekili:FireToggle("defensives", "on")
            assert.are.equal("last_stand", fixture.read(H, 0.2), "Last Stand takes precedence over the swap")
            H.ctl.unitHealth.player = 1000
            H.Fire("UNIT_HEALTH", "player")
            H.ctl.threat.nameplate1, H.ctl.unitIs.nameplate1target = 3, "player"
            H.ctl.inParty.nameplate1target = false
            H.ctl.cooldown[2565] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 5 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            assert.are.same({ "shield_slam" }, { first(H) }, "return to ordinary damage once the tank holds the pack")
        end)

        it("uses Shield Block during melee pressure while reserving an affordable threat cast", function()
            for _, case in ipairs({
                { rage = 60, defensives = "on", action = "shield_block" },
                { rage = 15, defensives = "on", action = "recover_threat" },
                { rage = 60, defensives = "off", action = "recover_threat" },
            }) do
                local H = threatPull({ rage = case.rage })
                H.Hekili:FireToggle("defensives", case.defensives)
                assert.are.equal(case.action, first(H), "rage " .. case.rage .. ", defensives " .. case.defensives)
            end
        end)

        local function raidTrash(instance)
            local H, addPlate, counts = threatPull({ instance = instance or "raid", group = 20, level = 60 })
            H.ctl.isInRaid = true
            H.ctl.exists.raid11, H.ctl.isPlayer.raid11 = true, true
            H.ctl.unitIs.nameplate1target, H.ctl.groupRoles.raid11 = "raid11", "HEALER"
            H.ctl.inParty.nameplate1target, H.ctl.inRaid.nameplate1target = false, 11
            -- Exercise target decisions between Shield Block casts.
            H.ctl.cooldown[2565] = { isActive = true, isOnGCD = false, startTime = H.ctl.now, duration = 5 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            return H, addPlate, counts
        end

        local function attemptedSunder(H, cast)
            H.Fire("UNIT_SPELLCAST_SENT", "player", "Loose enemy", cast, 7405)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast, 7405)
        end

        local function twiceWithoutRecovering(H)
            selectPlate(H, "nameplate1")
            H.ctl.names.target, H.ctl.names.nameplate1 = "Loose enemy", "Loose enemy"
            assert.are_not.equal("taunt", first(H), "no prior attempt")
            attemptedSunder(H, "Cast-recovery-1")
            assert.are_not.equal("taunt", fixture.read(H, 1.6), "one real threat attack is insufficient")
            attemptedSunder(H, "Cast-recovery-2")
        end

        it("holds Taunt until two real same-target threat builders have failed to recover the mob", function()
            local H = threatPull()
            twiceWithoutRecovering(H)
            assert.are_not.equal("taunt", fixture.read(H, 1.4), "allow the normal threat update to settle")
            assert.are.equal("taunt", fixture.read(H, 0.2), "same enemy still attacking the same healer")
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-taunt", 355)
            assert.are_not.equal("taunt", first(H), "manual or recommended Taunt consumes this recovery attempt")
        end)

        it("ignores simulated builders, unmatched cast successes and ambiguous mouseover casts", function()
            local H = threatPull()
            selectPlate(H, "nameplate1")
            H.ctl.names.target = "Loose enemy"
            for i = 1, 2 do
                H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-orphan-" .. i, 7405)
                assert.are.equal("sunder_armor", fixture.read(H, 1.6))
            end
            H.ctl.exists.mouseover, H.ctl.names.mouseover = true, "Loose enemy"
            for i = 1, 2 do
                attemptedSunder(H, "Cast-mouseover-" .. i)
                assert.are_not.equal("taunt", fixture.read(H, 1.6))
            end
        end)

        it("discards interrupted and failed builders before considering a last-resort Taunt", function()
            local H = threatPull()
            selectPlate(H, "nameplate1")
            H.ctl.names.target = "Loose enemy"
            assert.are_not.equal("taunt", first(H))
            attemptedSunder(H, "Cast-confirmed")
            for index, event in ipairs({
                "UNIT_SPELLCAST_FAILED",
                "UNIT_SPELLCAST_FAILED_QUIET",
                "UNIT_SPELLCAST_INTERRUPTED",
            }) do
                local cast = "Cast-cancelled-" .. index
                H.Fire("UNIT_SPELLCAST_SENT", "player", "Loose enemy", cast, 7405)
                H.Fire(event, "player", cast, 7405)
                H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast, 7405)
                assert.are_not.equal("taunt", fixture.read(H, 1.6), event)
            end
            attemptedSunder(H, "Cast-second-confirmed")
            assert.are.equal("taunt", fixture.read(H, 1.6), "cancelled casts did not discard the genuine first attempt")
        end)

        it("discards recovery evidence on a new target, different victim, secure tank, expiry or opt-out", function()
            for _, reason in ipairs({ "different target", "different victim", "recovered", "expired", "disabled" }) do
                local H = threatPull()
                twiceWithoutRecovering(H)
                if reason == "different target" then
                    H.ctl.threat.nameplate2, H.ctl.unitIs.nameplate2target = 0, "party1"
                    H.ctl.inParty.nameplate2target, H.ctl.isPlayer.nameplate2target = true, true
                    selectPlate(H, "nameplate2")
                elseif reason == "different victim" then
                    H.ctl.exists.party2, H.ctl.isPlayer.party2, H.ctl.groupRoles.party2 = true, true, "DAMAGER"
                    H.ctl.unitIs.targettarget = "party2"
                elseif reason == "recovered" then
                    H.ctl.threat.target, H.ctl.unitIs.targettarget = 3, "player"
                    H.Fire("UNIT_THREAT_LIST_UPDATE", "target")
                    H.ctl.threat.target, H.ctl.unitIs.targettarget = 0, "party1"
                elseif reason == "disabled" then
                    H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
                end
                assert.are_not.equal("taunt", fixture.read(H, reason == "expired" and 9 or 1.6), reason)
            end
        end)

        it("never Taunts a raid co-tank's target or an active raid encounter add", function()
            for _, reason in ipairs({ "co-tank", "boss", "encounter add" }) do
                local H = raidTrash()
                H.ctl.inRaid.targettarget = 11
                twiceWithoutRecovering(H)
                if reason == "co-tank" then
                    H.ctl.groupRoles.raid11 = "TANK"
                elseif reason == "boss" then
                    H.ctl.level.target = -1
                else
                    H.ctl.encounterInProgress = true
                end
                assert.are_not.equal("taunt", fixture.read(H, 1.6), reason)
            end
        end)

        it("can make a last-resort Taunt on ordinary raid trash attacking another subgroup", function()
            local H = raidTrash()
            H.ctl.inRaid.targettarget = 11
            twiceWithoutRecovering(H)
            assert.are.equal("taunt", fixture.read(H, 1.6))
        end)

        it("switches to raid trash attacking a healer outside the tank's subgroup", function()
            local H = raidTrash()
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            H.ctl.groupRoles.raid11 = "TANK"
            noSwap(H, "raid co-tank")
        end)

        it("supports outdoor raid packs and leaves a selected world boss alone", function()
            local H = raidTrash("none")
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            H.ctl.level.target = -1
            noSwap(H, "outdoor raid boss")
        end)

        it("leaves outdoor raid adds alone when a third enemy is a world boss fighting the raid", function()
            local H, addPlate, counts = raidTrash("none")
            assert.are.same({ "recover_threat", "cycle" }, { first(H) })
            addPlate(3, "worldboss")
            counts.rend, counts.sunder_armor = 4, 4
            H.ctl.level.nameplate3 = -1
            H.ctl.unitIs.nameplate3target, H.ctl.inRaid.nameplate3target = "raid11", 11
            H.ctl.isPlayer.nameplate3target = true
            noSwap(H, "the raid is fighting the nearby world boss")
        end)

        it("keeps raid bosses and encounter adds on the ordinary raid priority", function()
            local H = raidTrash()
            H.ctl.encounterInProgress = true
            noSwap(H, "trash-looking add during an active boss encounter")
            H = raidTrash()
            H.ctl.level.target = -1
            noSwap(H, "selected boss")
            local enabled = first(H)
            H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
            assert.are.equal(enabled, first(H), "the raid boss damage priority is unchanged")
            H = raidTrash()
            H.ctl.level.nameplate1 = -1
            noSwap(H, "loose boss")
        end)
    end)

    it("recovers from an idle landing with Primary hidden and finds a target in the other direction", function()
        local H = boot()
        local engine, output = H.Hekili.Engine, H.Hekili.Engine.Output
        local origin = H.ctl.guid.target
        local d = H.env.HekiliDisplayPrimary
        local button, shown = d.Buttons[1], false
        -- The headless frame methods do not track visibility. Record the real renderer's calls.
        button.Show = function()
            shown = true
        end
        button.Hide = function()
            shown = false
        end
        showPrimarySwap(H)
        assert.is_true(shown)
        -- Hide the normal Primary display exactly as a target-sensitive visibility setting can.
        local primary = output.Primary
        for i = primary.subs.n, 1, -1 do
            engine.Unsubscribe("Primary", primary.subs[i])
        end
        H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-idle", false
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.are.equal("cycle_previous", output.status.targetNavigation)
        assert.are.equal(output.status.targetRevision, output.status.navigationRevision)
        assert.are.equal(0, primary.count)
        d:UpdateAlpha()
        d.__scripts.OnUpdate(d, 0.2)
        assert.is_true(d.returning, "the real Primary renderer shows the standalone previous-target icon")
        assert.is_false(shown)
        local firstReturn = output.status.navigationStep
        H.Fire("PLAYER_TARGET_CHANGED") -- duplicate from the same idle enemy
        fixture.read(H)
        assert.are.equal("cycle_previous", output.status.targetNavigation)
        assert.are.equal(firstReturn, output.status.navigationStep)
        H.ctl.guid.target, H.ctl.unitCombat.target = origin, true
        H.Fire("PLAYER_TARGET_CHANGED")
        engine.Subscribe("Primary", function() end)
        fixture.read(H)
        assert.are.equal("cycle_previous", output.status.targetNavigation, "continue past the origin in reverse")
        assert.are.equal(output.status.targetRevision, output.status.navigationRevision)
        assert.are_not.equal(firstReturn, output.status.navigationStep)
        H.ctl.guid.target, H.ctl.auras.target.HARMFUL = H.ctl.guid.nameplate1, {}
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.is_nil(output.status.targetNavigation)
        assert.is_false(output.status.swapPending)
        assert.is_true(primary.count > 0)
        assert.is_nil(primary.recs[1].indicator)
        d.__scripts.OnUpdate(d, 0.2)
        assert.is_nil(d.returning)
        assert.is_true(shown, "the new target has a normal actionable recommendation")
        assert.are.equal(primary.recs[1].actionName, button.Action)
    end)

    it("stops the reverse search on revisiting a covered enemy and keeps current-target spells available", function()
        local H, _, addPlate = boot()
        addPlate(2)
        addPlate(3)
        onlySpread(H, "rend")
        local output, origin = H.Hekili.Engine.Output, H.ctl.guid.target
        showPrimarySwap(H)
        local function tab(guid, engaged)
            H.ctl.guid.target, H.ctl.unitCombat.target = guid, engaged
            H.Fire("PLAYER_TARGET_CHANGED")
            fixture.read(H, 0.2)
            return output.status.targetNavigation
        end
        assert.are.equal("cycle_previous", tab("Creature-idle", false))
        assert.are.equal("cycle_previous", tab(origin, true))
        assert.are.equal("cycle_previous", tab(H.ctl.guid.nameplate1, true), "still covered")
        assert.is_nil(tab(origin, true), "already visited")
        assert.is_true(output.Primary.count > 0)
        noSwap(H, "no immediate forward or reverse after revisiting the origin")
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-rend", 6546)
        assert.are.same({ "rend", "cycle" }, { first(H) }, "an observed cast starts a distinct spread request")
    end)

    it("bounds forward cycling over covered enemies and rechecks spread after a new enemy joins", function()
        local H, _, addPlate = boot()
        addPlate(2)
        onlySpread(H, "rend")
        local origin, output = H.ctl.guid.target, H.Hekili.Engine.Output
        showPrimarySwap(H)
        H.ctl.guid.target = H.ctl.guid.nameplate1
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H, 0.2)
        assert.are.equal("cycle", output.Primary.recs[1].indicator)
        H.env.HekiliDisplayPrimary.__scripts.OnUpdate(H.env.HekiliDisplayPrimary, 0.2)
        H.ctl.guid.target = origin -- tab has looped even though the enemy count predicted a missing application
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H, 0.2)
        assert.is_nil(output.status.targetNavigation)
        noSwap(H, "already visited in forward order")
        addPlate(3)
        assert.are.same({ "rend", "cycle" }, { first(H) }, "a fresh enemy makes spreading worth checking again")
    end)

    it("holds attacks after an unconfirmed return until a group-engaged target is selected", function()
        local H = boot()
        local output = H.Hekili.Engine.Output
        showPrimarySwap(H)
        H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-unknown", SECRET
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.are.equal("cycle_previous", output.status.targetNavigation)
        H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-still-idle", false
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.is_nil(output.status.targetNavigation)
        assert.are.equal(0, output.Primary.count)
        fixture.read(H)
        assert.are.equal(0, output.Primary.count)
        H.ctl.guid.target, H.ctl.unitCombat.target = H.ctl.guid.nameplate1, true
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.is_true(output.Primary.count > 0)
        noSwap(H, "safe landing")
    end)

    it("drops an armed return when the player turns off Recommend Target Swaps", function()
        local H = boot()
        showPrimarySwap(H)
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = false
        H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-idle", false
        H.Fire("PLAYER_TARGET_CHANGED")
        fixture.read(H)
        assert.is_nil(H.Hekili.Engine.Output.status.targetNavigation)
        assert.is_false(H.Hekili.Engine.Output.status.swapPending)
    end)

    it("releases the other displays if Primary is disabled or changes to a custom style", function()
        for _, setting in ipairs({ "enabled", "style" }) do
            local H = boot()
            local engine = H.Hekili.Engine
            showPrimarySwap(H)
            H.ctl.guid.target, H.ctl.unitCombat.target = "Creature-idle", false
            H.Fire("PLAYER_TARGET_CHANGED")
            fixture.read(H)
            assert.are.equal("cycle_previous", engine.Output.status.targetNavigation)
            if setting == "enabled" then
                engine.settings.displays.Primary.enabled = false
            else
                engine.settings.displays.Primary.style = "third_party"
            end
            fixture.read(H)
            assert.is_false(engine.Output.status.swapPending)
            assert.is_nil(engine.Output.status.targetNavigation)
        end
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

    it("keeps looking past a covered enemy and casts the requested spread on a suitable target", function()
        for _, key in ipairs({ "rend", "sunder_armor" }) do
            local H, _, addPlate, classifications = boot()
            addPlate(2)
            addPlate(3)
            onlySpread(H, key)
            assert.are.same({ key, "cycle" }, { first(H) })
            H.ctl.guid.target = H.ctl.guid.nameplate1
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ key, "cycle" }, { first(H) }, "already covered")
            H.ctl.auras.target.HARMFUL = {}
            if key == "rend" then
                classifications.target = "normal"
                H.ctl.guid.target = H.ctl.guid.nameplate2
                H.Fire("PLAYER_TARGET_CHANGED")
                assert.are.same({ key, "cycle" }, { first(H) }, "ordinary enemies do not qualify for the Rend spread")
            end
            classifications.target = "elite"
            H.ctl.guid.target = H.ctl.guid.nameplate3
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.same({ key }, { first(H) }, "uncovered engaged elite")
            assert.are.same({ key }, { first(H) }, "still awaiting the cast")
        end
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
            onlySpread(H, key)
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
