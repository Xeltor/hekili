local field = require("Forever.helpers.warlock_field")
local world = require("Forever.helpers.warlock_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local warlock, pick, cast = field.warlock, field.pick, field.cast

describe("Forever Warlock field damage", function()
    describe("Affliction leveling pulls", function()
        local function levelEleven(trainedAgony, options)
            local spells = { 172, 695, 707, 1120, 5019 }
            if trainedAgony then
                spells[#spells + 1] = 980
            end
            options = options or {}
            options.items = options.items or { [6265] = 2 }
            options.weapon = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }
            options.shootUsable = true
            return warlock("Affliction", 11, spells, options)
        end

        local function modelLowHealth(H)
            local belief = H.ns.VirtualStateInternal.th
            belief.lo0, belief.est0, belief.hi0 = 0, 0.1, 0.2
            assert.is_nil(H.ns.Facade.TargetHealthFraction())
            assert.are.same({ 0.2, false }, { H.ns.Facade.TargetHealthUpperFraction() })
        end

        it("opens with Corruption on an ordinary enemy, adds trained Agony, then wands", function()
            local H = levelEleven(true)
            assert.are.equal("corruption", pick(H))
            assert.are.equal("bane_of_agony", cast(H, 172))
            assert.are.equal("shoot", cast(H, 980))
        end)

        it("offers Agony over an active wand after manual Corruption despite a low health estimate", function()
            local H = levelEleven(true, { targetHealth = SECRET })
            modelLowHealth(H)
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-manual-corruption", 172)
            H.Fire("START_AUTOREPEAT_SPELL")
            assert.are.equal("bane_of_agony", pick(H, 1.6))
        end)

        it("requires readable low health to top up one shard on an undotted target", function()
            local H = warlock("Affliction", 11, { 695, 1120 }, { targetHealth = SECRET, items = { [6265] = 1 } })
            modelLowHealth(H)
            assert.are.equal("shadow_bolt", pick(H))
            H.ctl.unitHealth.target = 200
            assert.are.equal(0.2, H.ns.Facade.TargetHealthFraction())
            assert.are.equal("drain_soul", pick(H))
        end)

        it("wands after the opening DoTs when health is hidden even with an empty shard bag", function()
            local H = levelEleven(true, { targetHealth = SECRET, items = {} })
            assert.are.equal("bane_of_agony", cast(H, 172))
            assert.are.equal("shoot", cast(H, 980))
        end)

        it("finishes for a shard at 25 percent even when both DoTs are missing and the wand is firing", function()
            local H = levelEleven(true, { targetHealth = 251, items = { [6265] = 1 } })
            H.Fire("START_AUTOREPEAT_SPELL")
            assert.are.equal("corruption", pick(H))
            H.ctl.unitHealth.target = 250
            H.Fire("UNIT_HEALTH", "target")
            assert.are.equal("drain_soul", pick(H))
            H.ctl.itemCount[6265] = 2
            H.Fire("BAG_UPDATE_DELAYED")
            assert.is_not_equal("drain_soul", pick(H))
        end)

        it("keeps Drain Soul through both DoT expirations when the wand stops after the channel starts", function()
            local H = levelEleven(true, { targetHealth = SECRET, items = {} })
            assert.are.equal("bane_of_agony", cast(H, 172))
            assert.are.equal("shoot", cast(H, 980))
            H.Fire("START_AUTOREPEAT_SPELL")
            pick(H, 8)

            local start = H.ctl.now
            local finish = start + 15
            H.Fire("UNIT_SPELLCAST_SENT", "player", "target", "Cast-wand-drain", 1120)
            H.ctl.channel = { start * 1000, finish * 1000, spell = 1120 }
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-wand-drain", 1120)
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-wand-drain", 1120)
            H.Fire("STOP_AUTOREPEAT_SPELL")

            assert.are.equal("drain_soul", pick(H, 14.8))
            assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time >= finish - H.ctl.now - 0.05)
            local state = H.Hekili.State
            state.reset("Primary", true)
            assert.is_true(state:IsChanneling("drain_soul"))
            assert.is_true(state.debuff.corruption.down)
            assert.is_true(state.debuff.bane_of_agony.down)
        end)

        it("wands after Corruption on a trivial enemy even with hidden health", function()
            local H = levelEleven(true, { trivial = true, targetHealth = SECRET })
            assert.are.equal("shoot", cast(H, 172))
        end)

        it("still offers missing Agony late in a manually applied Corruption", function()
            local H = levelEleven(true, { targetHealth = SECRET })
            assert.are.equal("bane_of_agony", cast(H, 172))
            assert.are.equal("bane_of_agony", pick(H, 5)) -- 6.6 seconds into rank one's 12-second Corruption.
        end)

        it("uses trained Agony even when Corruption is untrained", function()
            local H = warlock("Affliction", 11, { 695, 980 }, { targetHealth = SECRET })
            assert.are.equal("bane_of_agony", pick(H))
            assert.are.equal("shadow_bolt", cast(H, 980))
        end)

        it("renews each DoT independently and lets Agony finish its final tick", function()
            local H = levelEleven(true, { targetHealth = SECRET })
            assert.are.equal("bane_of_agony", cast(H, 172))
            local expires = H.ctl.now + 24
            assert.are.equal("shoot", cast(H, 980))
            assert.are.equal("corruption", pick(H, 14))
            assert.are.equal("shoot", cast(H, 172))

            -- The display may queue the refresh before the last tick. It must schedule the cast at expiry.
            if pick(H, expires - H.ctl.now - 0.4) == "bane_of_agony" then
                assert.is_true(H.ctl.now + H.Hekili.Engine.Output.Primary.recs[1].time >= expires - 0.01)
            end
            assert.are.equal("bane_of_agony", pick(H, 0.6))
            assert.is_not_equal("bane_of_agony", cast(H, 980))
        end)

        it("starts with Corruption again after switching to an undotted target", function()
            local H = levelEleven(true, { targetHealth = SECRET })
            assert.are.equal("bane_of_agony", cast(H, 172))
            H.ctl.guid.target = "Creature-0-0-0-0-999-000002"
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.equal("corruption", pick(H))
        end)

        it("wands after Corruption when the enemy is dying or Agony is untrained", function()
            local dying = levelEleven(true)
            assert.are.equal("corruption", pick(dying))
            dying.ctl.unitHealth.target = 200
            assert.are.equal("shoot", cast(dying, 172))

            local untrained = levelEleven(false)
            assert.are.equal("corruption", pick(untrained))
            assert.are.equal("shoot", cast(untrained, 172))
        end)

        it("preserves an existing Bane of Doom when Agony is available while moving", function()
            local H = warlock("Affliction", 60, { 11713, 603 }, { moving = true })
            assert.are.equal("bane_of_agony", pick(H))
            assert.is_not_equal("bane_of_agony", cast(H, 603))
            assert.is_true(H.Hekili.State.debuff.bane_of_doom.up)
        end)
    end)

    describe("level fourteen Drain Life in an outdoor duo", function()
        local function duo(options)
            options.group = 2
            options.weapon = { 11287, "Lesser Magic Wand", "INVTYPE_RANGEDRIGHT", 2, 19 }
            options.shootUsable, options.items = true, { [6265] = 2 }
            return warlock("Affliction", 14, { 6222, 980, 705, 689, 755, 1120, 5019 }, options)
        end

        local function startGCD(H)
            local gcd = H.Hekili.Engine.Registry.GCD_SPELL
            H.ctl.cooldown[gcd] = { isActive = true, isOnGCD = true, startTime = H.ctl.now, duration = 1.5 }
            H.Fire("SPELL_UPDATE_COOLDOWN")
        end

        local function startWandGCD(H)
            H.Fire("START_AUTOREPEAT_SPELL")
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-duo-wand", 5019)
            startGCD(H)
        end

        local function startDrain(H, spell, duration)
            local start = H.ctl.now
            H.Fire("UNIT_SPELLCAST_SENT", "player", "target", "Cast-duo-drain", spell)
            H.ctl.channel = { start * 1000, (start + duration) * 1000, spell = spell }
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-duo-drain", spell)
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-duo-drain", spell)
            return start
        end

        local function findCue(out, action)
            for i = 1, out.healthCues.n do
                if out.healthCues[i].action == action then
                    return out.healthCues[i]
                end
            end
        end

        it("offers the pet rescue during an ongoing drain without prompting another damage spell", function()
            for _, channel in ipairs({ { 689, 5 }, { 1120, 15 } }) do
                local H = duo({ health = 550, petHealth = SECRET, partyAggro = true })
                local spell, duration = channel[1], channel[2]
                local start = startDrain(H, spell, duration)
                pick(H, 1.6) -- The cast's GCD is over; both drains still have ticks to come.
                local out = H.Hekili.Engine.Output.Primary
                local cue = assert(findCue(out, "health_funnel"), "missing rescue during " .. spell)
                assert.are.same({ "pet", 30 }, { cue.unit, cue.percent })
                assert.is_nil(cue.playerFloor)
                assert.is_nil(cue.gcdStart)
                H.ctl.unitHealth.pet = 900
                H.Fire("UNIT_HEALTH", "pet")
                pick(H, 0.1)
                assert.is_true(out.count == 0 or out.recs[1].time >= start + duration - H.ctl.now - 0.05)
                H.ctl.unitHealth.pet = 300
                H.Fire("UNIT_HEALTH", "pet")
                assert.are.equal("health_funnel", pick(H, 0.1))
                assert.is_near(0, out.recs[1].time, 0.01)
            end
        end)

        it("waits for the drain's global cooldown before a mid-channel pet rescue", function()
            local H = duo({ health = 550, petHealth = SECRET, partyAggro = true })
            local start = startDrain(H, 689, 5)
            startGCD(H)
            pick(H, 0.2)
            local out = H.Hekili.Engine.Output.Primary
            local cue = assert(findCue(out, "health_funnel"))
            local readyAt = cue.gcdStart + cue.gcdDuration
            assert.is_near(start + 1.5, readyAt, 0.01)
            assert.is_true(out.count == 0 or out.recs[1].time >= start + 5 - H.ctl.now - 0.05)

            H.ctl.unitHealth.pet = 300
            H.Fire("UNIT_HEALTH", "pet")
            pick(H, 0.1)
            assert.are.equal("health_funnel", out.healthCues[1].action)
            assert.are.equal("health_funnel", pick(H, 0.1)) -- the ordinary countdown settles on the next publish
            assert.is_near(readyAt - H.ctl.now, out.recs[1].time, 0.01)
        end)

        it("holds the active Funnel and a Shadow Bolt cast while the demon is critically hurt", function()
            for _, spell in ipairs({ 755, 705 }) do
                local H = duo({ health = 250, petHealth = 200, partyAggro = true })
                local start = H.ctl.now
                local finish = start + (spell == 755 and 10 or 2.8)
                H.Fire("UNIT_SPELLCAST_SENT", "player", spell == 755 and "pet" or "target", "Cast-duo-held", spell)
                if spell == 755 then
                    H.ctl.channel = { start * 1000, finish * 1000, spell = spell }
                    H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-duo-held", spell)
                    H.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-duo-held", spell)
                else
                    H.ctl.casting = { start * 1000, finish * 1000 }
                    H.Fire("UNIT_SPELLCAST_START", "player", "Cast-duo-held", spell)
                end
                pick(H, 1.6) -- The GCD is over but the active spell has not finished.
                local out = H.Hekili.Engine.Output.Primary
                assert.is_nil(findCue(out, "health_funnel"), spell)
                assert.is_true(out.count == 0 or out.recs[1].time >= finish - H.ctl.now - 0.05, spell)
            end
        end)

        it("drains for the Warlock's missing health whether the enemy attacks the player, demon, or partner", function()
            for _, victim in ipairs({ "player", "pet", "party1" }) do
                local H = duo({
                    health = 650,
                    petHealth = 900,
                    petTanking = victim == "pet",
                    partyAggro = victim == "party1",
                })
                H.ctl.threat.target = nil -- identify the engaged enemy by its victim alone
                assert.are.equal("drain_life", pick(H), victim)
                H.ctl.unitHealth.player, H.ctl.unitHealth.pet = 1000, 250
                H.Fire("UNIT_HEALTH", "player")
                H.Fire("UNIT_HEALTH", "pet")
                assert.are.equal("health_funnel", pick(H), victim)
            end
        end)

        it("rescues a critical demon before self-healing even when the Warlock also needs health", function()
            local H = duo({ health = 250, petHealth = 300, partyAggro = true })
            H.ctl.itemCount[5512] = 1
            H.Fire("BAG_UPDATE_DELAYED")
            assert.are.equal("health_funnel", pick(H))

            H.ctl.unitHealth.pet = SECRET
            H.Fire("UNIT_HEALTH", "pet")
            assert.are.equal("healthstone", pick(H))
            local out = H.Hekili.Engine.Output.Primary
            assert.are.equal("health_funnel", out.healthCues[1].action)
            assert.is_nil(out.healthCues[1].playerFloor)
            H.ctl.unitHealth.pet, H.ctl.unitHealth.player = 300, SECRET
            H.Fire("UNIT_HEALTH", "player")
            H.Fire("UNIT_HEALTH", "pet")
            assert.are.equal("health_funnel", pick(H))

            local moving = duo({ moving = true, health = 250, petHealth = 300, partyAggro = true })
            assert.is_not_equal("health_funnel", pick(moving))
            assert.is_nil(findCue(moving.Hekili.Engine.Output.Primary, "health_funnel"))
        end)

        it("keeps the player-health Drain Life cue through a wand global cooldown", function()
            local H = duo({ health = SECRET, petHealth = SECRET, partyAggro = true })
            H.ctl.itemCount[5512] = 1 -- a Minor Healthstone can still be used immediately
            H.Fire("BAG_UPDATE_DELAYED")
            assert.are.equal("corruption", pick(H))
            startWandGCD(H)
            assert.are.equal("corruption", pick(H, 0.1))
            local out = H.Hekili.Engine.Output.Primary
            assert.is_true(out.recs[1].time > 0)
            assert.are.equal("health_funnel", out.healthCues[1].action)
            local cue = assert(findCue(out, "drain_life"))
            assert.are.equal(65, cue.percent)
            assert.is_nil(cue.unit) -- this threshold is the Warlock's health
            assert.is_near(out.recs[1].time, cue.gcdStart + cue.gcdDuration - H.ctl.now, 0.01)
            local funnel = assert(findCue(out, "health_funnel"))
            assert.are.same({ "pet", 30 }, { funnel.unit, funnel.percent })
            assert.is_nil(funnel.playerFloor)
            assert.are.same({ cue.gcdStart, cue.gcdDuration }, { funnel.gcdStart, funnel.gcdDuration })
            local stone = assert(findCue(out, "healthstone"))
            assert.is_nil(stone.gcdStart)
            assert.is_nil(stone.gcdDuration)
        end)

        it("holds Drain Life during a wand global cooldown when mana or spell range prevents the cast", function()
            for _, options in ipairs({ { mana = 1 }, { range = 25 } }) do
                options.health, options.petHealth, options.partyAggro = SECRET, 900, true
                local H = duo(options)
                startWandGCD(H)
                pick(H, 0.1)
                assert.is_nil(findCue(H.Hekili.Engine.Output.Primary, "drain_life"))
            end
        end)
    end)

    it("stops setting up fresh DoTs on a dying ordinary enemy in all five builds", function()
        for _, build in ipairs({ "Affliction", "SMRuin", "Demonology", "ShadowBrand", "Destruction" }) do
            local H = warlock(build, 36, { 7641, 2941, 7648 }, { targetHealth = 200 })
            assert.are.equal("shadow_bolt", pick(H), build)
        end
    end)

    it("uses the instant spells actually available while moving", function()
        local spells = { 705, 6222, 980, 707 }
        for _, rank in ipairs({ 4, 5 }) do
            local H = warlock("Destruction", 26, spells, { moving = true, talents = { [17810] = rank } })
            assert.are.equal(rank == 5 and "corruption" or "bane_of_agony", pick(H))
        end
        local H = warlock("Affliction", 26, { 705, 689, 6222 }, { moving = true, health = 400, buffs = { 17941 } })
        assert.are.equal("shadow_bolt", pick(H))
        local runner = warlock("Affliction", 26, { 705, 689, 6222 }, { moving = true, health = 400 })
        assert.is_true(runner.Hekili.State.moving)
        assert.is_nil(pick(runner))
        assert.is_nil(pick(runner, 6))
    end)

    it("suspends boss hardcasts until movement stops when the client hides player speed", function()
        local H = warlock("SMRuin", 60, { 11661 }, {
            instanceType = "raid",
            boss = true,
            beforeLoad = function(h)
                h.env.GetUnitSpeed = function()
                    return SECRET, 7, 7, 4.72
                end
            end,
        })
        assert.are.equal("shadow_bolt", pick(H))
        H.Fire("PLAYER_STARTED_MOVING")
        assert.is_nil(pick(H))
        assert.is_nil(pick(H, 7))
        H.Fire("PLAYER_STOPPED_MOVING")
        assert.are.equal("shadow_bolt", pick(H))
    end)

    it("holds Conflagrate for Immolate's last tick, an ordinary finisher, or full Shadow and Flame", function()
        local function immolate(rank, low)
            local H = warlock("Destruction", 38, { 7641, 2941, 1293817 }, {
                talents = { [426316] = rank, [1293817] = 1 },
            })
            assert.are.equal("immolate", pick(H))
            if low then
                H.ctl.unitHealth.target = 200
            end
            return H, cast(H, 2941)
        end
        local H, first = immolate(4)
        assert.are.equal("shadow_bolt", first)
        assert.are.equal("conflagrate", pick(H, 11))
        assert.are.equal("conflagrate", select(2, immolate(4, true)))
        assert.are.equal("conflagrate", select(2, immolate(5)))
    end)

    it("uses Shadowburn to finish with a spare shard, or with the first shard at full Shadow and Flame", function()
        local function shadowburn(build, health, shards, talentRank, distance)
            local H = warlock(build, 40, { 7641, 18869 }, {
                targetHealth = health,
                range = distance,
                items = { [6265] = shards },
                talents = { [426316] = talentRank },
            })
            return pick(H)
        end
        assert.are.equal("shadowburn", shadowburn("SMRuin", 200, 2, 0))
        assert.are.equal("shadow_bolt", shadowburn("SMRuin", 200, 1, 0))
        assert.are.equal("shadow_bolt", shadowburn("SMRuin", SECRET, 2, 0))
        assert.are.equal("shadowburn", shadowburn("Destruction", 1000, 1, 5))
        assert.are.equal("shadow_bolt", shadowburn("Destruction", 1000, 0, 5))
        assert.is_not_equal("shadowburn", shadowburn("Destruction", 200, 2, 5, SECRET))
    end)

    it("uses Amplify Curse only for a ready Agony and respects the cooldown switch", function()
        local function pull(spells, options, cds)
            options.classification = "elite"
            local H = warlock("Affliction", 30, spells, options)
            H.Hekili:FireToggle("cooldowns", cds)
            return H
        end
        local H = pull({ 1088, 1014, 18288 }, {}, "on")
        assert.are.equal("amplify_curse", pick(H))
        assert.are.equal("bane_of_agony", cast(H, 18288))
        assert.are.equal("shadow_bolt", cast(H, 1014))
        assert.are.equal("bane_of_agony", pick(pull({ 1088, 1014, 18288 }, {}, "off")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 18288 }, {}, "on")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 1014, 18288 }, { range = SECRET }, "on")))
        assert.is_not_equal("amplify_curse", pick(pull({ 1088, 1014, 18288 }, { mana = 10, maxMana = 40 }, "on")))
        local recovering = pull({ 1088, 1014, 18288 }, { mana = 10 }, "on")
        assert.are.equal("amplify_curse", pick(recovering))
        assert.is_true(recovering.Hekili.Engine.Output.Primary.recs[1].delay > 0.5)
    end)

    it("preserves Havoc on the selected target", function()
        local H = warlock("Destruction", 40, { 7641, 1014, 1225228 }, { classification = "elite" })
        assert.are.equal("bane_of_agony", pick(H))
        assert.are.equal("shadow_bolt", cast(H, 1225228))
        assert.is_true(H.Hekili.State.debuff.bane_of_havoc.up)
    end)

    it("offers Corruption on a second engaged enemy only with target swaps enabled", function()
        local function pair(cycle, engaged, extra, knownCount)
            local H = warlock("Affliction", 30, { 1106, 6223 }, {
                classification = "elite",
                instanceType = "party",
                group = 5,
                partyAggro = true,
            })
            H.Hekili.Engine.settings.specs[world.Affliction.SPEC].cycle = cycle
            local ctl = H.ctl
            ctl.guid.nameplate1, ctl.guid.nameplate2 = ctl.guid.target, "Creature-secondary"
            ctl.unitIs.nameplate1 = "target"
            local plates = { "nameplate1", "nameplate2" }
            if extra then
                plates[3] = "nameplate3"
                ctl.guid.nameplate3 = "Creature-third"
            end
            for _, plate in ipairs(plates) do
                ctl.exists[plate], ctl.exists[plate .. "target"] = true, true
                ctl.unitIs[plate .. "target"], ctl.inParty[plate .. "target"] = "party1", true
                ctl.distance[plate], ctl.unitCombat[plate] = 15, plate == "nameplate1" or engaged
                H.Fire("NAME_PLATE_UNIT_ADDED", plate)
            end
            if knownCount == false then
                H.ns.Facade.DebuffCount = function()
                    return nil
                end
            end
            assert.are.equal("corruption", pick(H))
            local nextCast = cast(H, 6223)
            return nextCast, H.Hekili.Engine.Output.Primary.recs[1].indicator
        end
        assert.are.same({ "corruption", "cycle" }, { pair(true, true) })
        assert.are.equal("shadow_bolt", (pair(false, true)))
        assert.are.equal("shadow_bolt", (pair(true, false)))
        assert.are.same({ "corruption", "cycle" }, { pair(true, true, true) })
        assert.are.equal("shadow_bolt", (pair(true, true, false, false)))
    end)
end)
