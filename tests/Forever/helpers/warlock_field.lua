local assert = require("luassert")
local headless = require("Game.harness.headless")
local warlockWorld = require("Forever.helpers.warlock_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function warlock(build, level, known, options)
    local o = options or {}
    local baseline = warlockWorld[build]
    local character = baseline.character()
    character.level, character.known, character.talents = level, known, o.talents or {}
    character.instanceType = o.instanceType
    character.race = o.race or character.race
    character.power.max, character.power.value = o.maxMana or 1000, o.mana or 1000
    character.items = { [16] = o.mainHand, [18] = o.weapon }
    character.ranges[5019] = { 0, 30 }
    character.ranges[755] = { 0, 20 }
    character.ranges[19028] = { 0, 100 }
    for _, id in ipairs({ 1714, 11719, 18223 }) do
        character.ranges[id] = { 0, 30 }
    end

    local H = headless.new({
        character = character,
        pack = baseline.PACK,
        beforeLoad = function(h)
            if o.moving or o.targetSpeed then
                h.env.GetUnitSpeed = function(unit)
                    local speed = unit == "target" and o.targetSpeed or unit == "player" and o.moving and 7
                    return speed or 0, 7, 7, 4.72
                end
            end
            if o.beforeLoad then
                o.beforeLoad(h)
            end
        end,
        beforeLogin = function(h)
            if o.beforeLogin then
                o.beforeLogin(h)
            end
            if o.attacking == SECRET or o.shooting == SECRET then
                local current = h.Client.C_Spell.IsCurrentSpell
                h.Client.C_Spell.IsCurrentSpell = function(id)
                    if (id == 6603 and o.attacking == SECRET) or (id == 5019 and o.shooting == SECRET) then
                        return SECRET
                    end
                    return current(id)
                end
            end
        end,
    })
    assert.are.same({}, H.loadErrors)
    local ctl = H.ctl
    ctl.distance.target, ctl.level.target = o.range or 15, o.boss and -1 or level
    ctl.classification, ctl.groupMembers = o.classification or "normal", o.group or 0
    ctl.unitHealth.player, ctl.unitHealthMax.player = o.health or 1000, 1000
    ctl.unitHealth.target = o.targetHealth or 1000
    ctl.trivial.target = o.trivial
    ctl.isPlayer.target, ctl.friendly.target, ctl.dead.target = o.playerTarget, o.friendly, o.targetDead
    ctl.exists.target = not o.noTarget
    ctl.unitCombat.target = not o.prepull and not o.idleTarget
    if ctl.unitCombat.target then
        ctl.exists.targettarget = true
        ctl.unitIs.targettarget = o.petTanking and "pet" or o.partyAggro and "party1" or "player"
        ctl.inParty.targettarget = o.partyAggro
        ctl.threat.target = o.petTanking and 0 or o.partyAggro and 1 or 3
    end
    ctl.exists.pet, ctl.dead.pet = o.petHealth ~= nil, o.petDead
    if ctl.exists.pet then
        ctl.guid.pet = "Pet-0-0-0-0-416-000001"
        ctl.unitHealth.pet, ctl.unitHealthMax.pet = o.petHealth, 1000
        ctl.distance.pet, ctl.petPower = o.petRange or 10, 1000
        ctl.exists.pettarget, ctl.unitIs.pettarget = o.petTarget ~= nil, o.petTarget
    end
    for id, count in pairs(o.items or {}) do
        ctl.itemCount[id] = count
    end
    if o.shootUsable then
        ctl.usable[5019] = { true, false }
    end
    ctl.current[6603], ctl.current[5019] = o.attacking == true, o.shooting
    for _, id in ipairs(o.buffs or {}) do
        local rows = ctl.auras.player.HELPFUL
        rows[#rows + 1] = { spellId = id, expirationTime = ctl.now + 30, applications = 0, sourceUnit = "player" }
    end

    H.Hekili:FireToggle("defensives", o.defensives == false and "off" or "on")
    H.Fire("PLAYER_TARGET_CHANGED")
    H.Fire("UNIT_AURA", "player")
    H.Fire("UNIT_PET", "player")
    if o.moving then
        H.Fire("PLAYER_STARTED_MOVING")
    end
    assert(headless.cycle(H, ctl.now + 0.2))
    if not o.prepull then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function pick(H, delay)
    assert(headless.cycle(H, H.ctl.now + (delay or 0.2)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    local rec = out.count > 0 and out.recs[1]
    if rec then
        return rec.actionName
    end
    return nil
end

local function cast(H, spellID)
    H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-test-" .. spellID, spellID)
    return pick(H, 1.6)
end

return { warlock = warlock, pick = pick, cast = cast }
