local field = require("Forever.helpers.warlock_field")
local warlock, pick = field.warlock, field.pick
local SECRET = require("Game.State.helpers.fake_api").SECRET

local OFFENSIVE = {
    { race = "Gnome", key = "eureka", id = 1259821 },
    { race = "Troll", key = "berserking", id = 20554 },
    { race = "Orc", key = "blood_fury", id = 20572 },
}

local function burst(build, racial, options)
    local o = { race = racial.race, classification = "elite", instanceType = "party", group = 5, partyAggro = true }
    for k, v in pairs(options or {}) do
        o[k] = v
    end
    local spells = { 705 }
    if not o.unlearned then
        spells[#spells + 1] = racial.id
    end
    local H = warlock(build, 16, spells, o)
    H.Hekili:FireToggle("cooldowns", "on")
    return H
end

local function observeControl(rows)
    return function(core)
        core.Client.C_LossOfControl.GetActiveLossOfControlDataCount = function()
            return #rows
        end
        core.Client.C_LossOfControl.GetActiveLossOfControlData = function(i)
            return rows[i]
        end
    end
end

local function setControl(H, rows, ...)
    for i = #rows, 1, -1 do
        rows[i] = nil
    end
    for i = 1, select("#", ...) do
        rows[i] = { locType = select(i, ...), startTime = H.ctl.now, duration = 12 }
    end
    H.Fire("LOSS_OF_CONTROL_UPDATE")
end

describe("Warlock racial actives", function()
    for _, racial in ipairs(OFFENSIVE) do
        it("saves " .. racial.key .. " on a raid boss until the Warlock can cast again", function()
            local rows = {}
            local options = {
                race = racial.race,
                instanceType = "raid",
                group = 10,
                boss = true,
                moving = true,
                beforeLogin = observeControl(rows),
            }
            local H = warlock("SMRuin", 60, { 11661, racial.id }, options)
            H.Hekili:FireToggle("cooldowns", "on")
            assert.is_not_equal(racial.key, pick(H))
            options.moving = false
            H.Fire("PLAYER_STOPPED_MOVING")
            assert.are.equal(racial.key, pick(H))
            for _, kind in ipairs({ "SILENCE", "STUN" }) do
                rows[1] = { locType = kind, startTime = H.ctl.now, duration = 10 }
                H.Fire("LOSS_OF_CONTROL_UPDATE")
                assert.is_not_equal(racial.key, pick(H), kind)
            end
            rows[1] = nil
            H.Fire("LOSS_OF_CONTROL_UPDATE")
            assert.are.equal(racial.key, pick(H))
        end)
    end

    for _, build in ipairs({ "Affliction", "Demonology", "Destruction", "SMRuin", "ShadowBrand" }) do
        it(build .. " uses the learned damage racial on an engaged elite with casting mana", function()
            for _, racial in ipairs(OFFENSIVE) do
                local H = burst(build, racial)
                assert.are.equal(racial.key, pick(H), racial.race)
                local rec = H.Hekili.Engine.Output.Primary.recs[1]
                assert.are.equal(racial.id, rec.actionID, racial.race)
                H.Hekili:FireToggle("cooldowns", "off")
                assert.is_not_equal(racial.key, pick(H), racial.race)
            end
        end)
    end

    it("offers the field's Blood Fury during a running global cooldown", function()
        local H = burst("Affliction", OFFENSIVE[3])
        local now = H.ctl.now
        H.ctl.cooldown[H.ns.GCD_SPELL] = { isActive = true, isOnGCD = false, startTime = now, duration = 1.5 }
        assert.are.equal("blood_fury", pick(H))
        local rec = H.Hekili.Engine.Output.Primary.recs[1]
        assert.is_true(rec.time < 0.05, "the GCD must not delay Blood Fury")
    end)

    it("holds damage cooldowns when the field target or the caster cannot use the window", function()
        for label, options in pairs({
            wrongRace = { race = "Human" },
            unlearned = { unlearned = true },
            shortPull = { classification = "normal" },
            idle = { idleTarget = true },
            nearlyDead = { targetHealth = 200 },
            outOfRange = { range = 40 },
            unknownRange = { range = SECRET },
            lowMana = { mana = 50 },
            moving = { moving = true },
        }) do
            local racial = OFFENSIVE[1]
            assert.is_not_equal(racial.key, pick(burst("Destruction", racial, options)), label)
        end
    end)

    it("uses Eureka for Immolate setup and saves it during Incinerate-only filler", function()
        local function fire(spells)
            local H = warlock("Destruction", 40, spells, {
                race = "Gnome",
                classification = "elite",
                talents = { [412758] = 1 },
            })
            H.Hekili:FireToggle("cooldowns", "on")
            return pick(H)
        end
        assert.are.equal("incinerate", fire({ 7641, 412758, 1259821 }))
        assert.are.equal("eureka", fire({ 7641, 11665, 412758, 1259821 }))
    end)

    it("uses defensive racials on the matching control even without a hostile target", function()
        for _, racial in ipairs({
            { race = "Human", key = "will_to_survive", id = 1259718, kinds = { "STUN", "STUN_MECHANIC" } },
            { race = "Gnome", key = "escape_artist", id = 20589, kinds = { "ROOT", "SNARE" } },
            { race = "Scourge", key = "will_of_the_forsaken", id = 7744, kinds = { "FEAR", "CHARM", "SLEEP" } },
        }) do
            local rows = {}
            local H = warlock("Affliction", 10, { racial.id }, {
                race = racial.race,
                instanceType = "pvp",
                noTarget = true,
                beforeLogin = observeControl(rows),
            })
            for _, kind in ipairs(racial.kinds) do
                rows[1] = { locType = kind, startTime = H.ctl.now, duration = 10 }
                H.Fire("LOSS_OF_CONTROL_UPDATE")
                assert.are.equal(racial.key, pick(H), kind)
            end
            H.Hekili:FireToggle("defensives", "off")
            assert.is_not_equal(racial.key, pick(H), "disabled")
            H.Hekili:FireToggle("defensives", "on")
            for _, kind in ipairs({ "DISARM", SECRET }) do
                rows[1] = { locType = kind, startTime = H.ctl.now, duration = 10 }
                H.Fire("LOSS_OF_CONTROL_UPDATE")
                assert.is_not_equal(racial.key, pick(H), "unconfirmed control")
            end
            rows[1] = nil
            H.Fire("LOSS_OF_CONTROL_UPDATE")
            assert.is_not_equal(racial.key, pick(H), "cleared")
        end
    end)

    it("allows a matching racial break with another effect present", function()
        for _, example in ipairs({
            { "Human", 1259718, "will_to_survive", "STUN", "ROOT" },
            { "Scourge", 7744, "will_of_the_forsaken", "FEAR", "SNARE" },
            { "Gnome", 20589, "escape_artist", "ROOT", "SILENCE" },
        }) do
            local rows = {}
            local H = warlock("Affliction", 20, { example[2] }, {
                race = example[1],
                noTarget = true,
                beforeLogin = observeControl(rows),
            })
            setControl(H, rows, example[4], example[5])
            assert.are.equal(example[3], pick(H))
            if example[3] == "escape_artist" then
                setControl(H, rows, "ROOT", "STUN")
                assert.is_not_equal("escape_artist", pick(H))
                setControl(H, rows, "ROOT")
                assert.are.equal("escape_artist", pick(H))
            end
        end
    end)

    it("offers emergency items under silence or roots and waits out hard control", function()
        for _, item in ipairs({ { 5512, "healthstone" }, { 118, "healing_potion" } }) do
            local rows = {}
            local H = warlock("Affliction", 20, {}, {
                race = "Human",
                noTarget = true,
                health = 250,
                items = { [item[1]] = 1 },
                beforeLogin = observeControl(rows),
            })
            for _, kind in ipairs({ "SILENCE", "ROOT", "SNARE" }) do
                setControl(H, rows, kind)
                assert.are.equal(item[2], pick(H), kind)
            end
            for _, kind in ipairs({ "STUN", "FEAR", "CHARM", "SLEEP", "CONFUSE", "POSSESS" }) do
                setControl(H, rows, kind, "ROOT")
                assert.is_not_equal(item[2], pick(H), kind)
            end
            setControl(H, rows)
            assert.are.equal(item[2], pick(H))
            H.Hekili:FireToggle("defensives", "off")
            assert.is_not_equal(item[2], pick(H), "Defensives disabled")
        end
    end)

    it("uses Shatter Curse only for a readable curse", function()
        local rows = {}
        local H = warlock("Destruction", 20, { 20572, 1299026 }, {
            race = "Orc",
            noTarget = true,
            beforeLogin = observeControl(rows),
        })
        for _, kind in ipairs({ "Curse", "Poison" }) do
            H.ctl.auras.player.HARMFUL[1] = {
                name = "Harmful effect",
                spellId = 900001,
                dispelName = kind,
                duration = 10,
                expirationTime = H.ctl.now + 10,
                applications = 1,
            }
            H.Fire("UNIT_AURA", "player")
            assert.are.equal(kind == "Curse", pick(H) == "shatter_curse", kind)
            if kind == "Curse" then
                setControl(H, rows, "STUN")
                assert.is_not_equal("shatter_curse", pick(H))
                setControl(H, rows, "SILENCE")
                assert.are.equal("shatter_curse", pick(H))
                setControl(H, rows)
            end
        end
    end)

    it("recovers with Rapid Regeneration between pulls while stationary", function()
        local function heal(o)
            o.race, o.noTarget = "Troll", true
            return pick(warlock("Affliction", 10, { 1260270 }, o))
        end
        assert.are.equal("rapid_regeneration", heal({ prepull = true, health = 550 }))
        assert.is_not_equal("rapid_regeneration", heal({ prepull = true, health = 800 }))
        assert.is_not_equal("rapid_regeneration", heal({ health = 550 }))
        assert.is_not_equal("rapid_regeneration", heal({ prepull = true, health = 550, moving = true }))
    end)

    it("offers Cannibalize only with a positively identified nearby corpse when recovery is needed", function()
        local function recover(o)
            o.race, o.prepull = "Scourge", not o.combat
            local H = warlock("Affliction", 10, { 20577 }, o)
            H.ctl.creature.target = o.creature or "humanoid"
            H.ctl.usable[20577] = { not o.unusable, false }
            H.ctl.ranges[20577] = { 0, 5 }
            H.Fire("PLAYER_TARGET_CHANGED")
            return pick(H)
        end
        assert.are.equal("cannibalize", recover({ targetDead = true, health = 500, range = 3 }))
        assert.are.equal("cannibalize", recover({ targetDead = true, creature = "undead", mana = 300, range = 3 }))
        assert.are.equal(
            "cannibalize",
            recover({ targetDead = true, playerTarget = true, instanceType = "pvp", health = 500, range = 3 })
        )
        for label, options in pairs({
            living = { health = 500, range = 3 },
            beast = { targetDead = true, creature = "beast", health = 500, range = 3 },
            unknownType = { targetDead = true, creature = SECRET, health = 500, range = 3 },
            tooFar = { targetDead = true, health = 500, range = 8 },
            unknownRange = { targetDead = true, health = 500, range = SECRET },
            friendly = { targetDead = true, health = 500, range = 3, friendly = true },
            unusable = { targetDead = true, health = 500, range = 3, unusable = true },
            moving = { targetDead = true, health = 500, range = 3, moving = true },
            fighting = { targetDead = true, health = 500, range = 3, combat = true },
            healthy = { targetDead = true, range = 3 },
            disabled = { targetDead = true, health = 500, range = 3, defensives = false },
        }) do
            assert.is_not_equal("cannibalize", recover(options), label)
        end
    end)

    for _, racial in ipairs({
        { key = "cannibalize", race = "Scourge", castID = 20577, channelID = 20578, seconds = 10 },
        { key = "cannibalize", race = "Scourge", castID = 20577, channelID = 20577, seconds = 10 },
        { key = "rapid_regeneration", race = "Troll", castID = 1260270, channelID = 1260270, seconds = 6 },
    }) do
        it(racial.key .. " respects the live channel and its early stop under ID " .. racial.channelID, function()
            local H = warlock("Affliction", 8, { racial.castID, 687 }, {
                race = racial.race,
                prepull = true,
                targetDead = true,
                health = 500,
                range = 3,
            })
            local ctl, st = H.ctl, H.Hekili.State
            ctl.creature.target = "humanoid"
            ctl.usable[racial.castID] = { true, false }
            H.Fire("PLAYER_TARGET_CHANGED")
            assert.are.equal(racial.key, pick(H))
            assert.are.equal(racial.castID, H.Hekili.Engine.Output.Primary.recs[1].actionID)
            assert.are.equal(racial.castID, H.ns.VirtualState.KnownID(racial.channelID))

            local start = ctl.now
            ctl.channel = { start * 1000, (start + racial.seconds) * 1000, spell = racial.channelID }
            H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-recovery", racial.castID)
            H.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-recovery", racial.channelID)
            ctl.cooldown[racial.castID] = { isActive = true, isOnGCD = false }
            H.Fire("SPELL_UPDATE_COOLDOWN")
            local nextAction = pick(H, 1.8)
            if nextAction then
                assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time >= start + racial.seconds - ctl.now - 0.05)
            end
            st.reset("Primary", true)
            assert.is_true(st:IsChanneling(racial.key))

            -- Movement, another action, or incoming damage can cause this same client stop before the scheduled end.
            ctl.channel = nil
            H.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "Cast-recovery", racial.channelID)
            assert.are.equal("demon_skin", pick(H))
            assert.is_true(H.Hekili.Engine.Output.Primary.recs[1].time < 1)
            st.reset("Primary", true)
            assert.is_false(st:IsChanneling(racial.key))
        end)
    end

    it("requires the Cannibalize activation from the player's own race", function()
        for _, char in ipairs({ { "Scourge", { 20578 } }, { "Human", { 20577, 20578 } } }) do
            local H = warlock("Affliction", 8, char[2], { race = char[1], prepull = true })
            assert.is_false(H.Hekili.State:IsKnown("cannibalize"))
        end
    end)

    it("blocks moving starts in the shared ability even when a custom priority has no movement condition", function()
        for _, racial in ipairs({ { "Scourge", "cannibalize", 20577 }, { "Troll", "rapid_regeneration", 1260270 } }) do
            for _, moving in ipairs({ true, false }) do
                local H = warlock("Affliction", 8, { racial[3] }, { race = racial[1], prepull = true, moving = moving })
                local st = H.Hekili.State
                st.reset("Primary", true)
                assert.are.equal(not moving, st:IsUsable(racial[2]))
            end
        end
    end)
end)
