local assert = require("luassert")
local headless = require("Game.harness.headless")
local pw = require("Forever.helpers.paladin_world")
local learn = require("Forever.wowsims.learn_paladin")
local secret = require("Game.State.helpers.fake_api").SECRET

local M = { PACK = "Protection (wowsims.com)" }
local kit = pw.Protection

local function spells(level, talents)
    local known = { 6603 }
    for _, name in ipairs({
        "seal_of_righteousness",
        "judgement",
        "holy_strike",
        "seal_of_the_crusader",
        "seal_of_fury",
        "righteous_fury",
        "retribution_aura",
        "consecration",
        "exorcism",
        "holy_shield",
        "hammer_of_wrath",
    }) do
        if name ~= "holy_shield" or talents[20925] then
            for _, id in ipairs(kit.IDS[name]) do
                if learn[id] and learn[id] <= level then
                    known[#known + 1] = id
                end
            end
        end
    end
    return known
end

function M.paladin(level, mana, options)
    local o = options or {}
    mana = mana or o.maxMana or 1000
    local character = kit.character()
    local talents = o.talents or (level >= 30 and { [20925] = 1 } or {})
    character.level, character.talents = level, talents
    character.known = o.known and { unpack(o.known) } or spells(level, talents)
    for _, id in ipairs(o.extraKnown or {}) do
        character.known[#character.known + 1] = id
    end
    character.instanceType = o.instance or "none"
    character.power.max, character.power.value = o.maxMana or 1000, mana
    if o.noShield then
        character.items = { [16] = character.items[16] }
    end
    character.ranges[6603] = { 0, 5 }
    for _, id in ipairs({ 853, 5588, 5589, 10308 }) do
        character.ranges[id] = { 0, 10 }
    end

    local H =
        headless.new({ character = character, pack = M.PACK, beforeLoad = o.beforeLoad, beforeLogin = o.beforeLogin })
    assert.are.same({}, H.loadErrors)
    local ctl = H.ctl
    ctl.distance.target, ctl.level.target = o.distance or 3, o.boss and -1 or level
    ctl.classification, ctl.creature.target = o.classification or "normal", o.creature
    ctl.groupMembers, ctl.isInRaid = o.group or 0, o.instance == "raid"
    ctl.inGroup = ctl.groupMembers > 1
    ctl.groupRoles.player = o.role or "NONE"
    ctl.isPlayer.target, ctl.dead.target, ctl.friendly.target = o.playerTarget, o.targetDead, o.friendly
    ctl.exists.target, ctl.current[6603] = not o.noTarget, o.autoAttack ~= false
    ctl.unitCombat.target = o.engaged
    if o.engaged == nil then
        ctl.unitCombat.target = not o.idleTarget and not o.prepull
    end
    if ctl.unitCombat.target == true then
        local victim = o.targetVictim
        if victim == nil then
            victim = "player"
        end
        ctl.exists.targettarget, ctl.unitIs.targettarget = victim ~= false, victim or nil
        ctl.threat.target = o.threat == nil and 3 or o.threat
        if type(victim) == "string" and victim ~= "player" then
            ctl.exists[victim], ctl.isPlayer[victim] = true, true
            ctl.inParty.targettarget = victim:match("^party%d+$") ~= nil
            ctl.inRaid.targettarget = tonumber(victim:match("^raid(%d+)$"))
        end
    end
    ctl.healthPlain = o.healthPlain ~= false
    if ctl.healthPlain then
        ctl.unitHealth.player, ctl.unitHealthMax.player = o.health or 1000, 1000
    end
    ctl.unitHealth.target, ctl.unitHealthMax.target = o.targetHealth or 1000, 1000
    for _, id in ipairs(kit.IDS.hammer_of_wrath) do
        ctl.usable[id] = { type(o.targetHealth) == "number" and o.targetHealth <= 200, false }
    end
    for _, id in ipairs(o.buffs or {}) do
        local buffs = ctl.auras.player.HELPFUL
        buffs[#buffs + 1] = { spellId = id, expirationTime = ctl.now + 30, applications = 1, sourceUnit = "player" }
    end
    H.Hekili:FireToggle("defensives", o.defensives == false and "off" or "on")
    H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].cycle = o.swaps == true
    H.Fire("PLAYER_TARGET_CHANGED")
    H.Fire("UNIT_AURA", "player")
    assert(headless.cycle(H, ctl.now + 0.2))
    if not o.prepull then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    local VS, pool = H.ns.VirtualState, { est = mana, lo = mana, hi = mana, conf = 1 }
    local power = VS.Power
    VS.Power = function(pt, now)
        return pt == 0 and pool or power(pt, now)
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

function M.read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 0.2)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    return out.count > 0 and out.recs[1].actionName or nil
end

function M.cast(H, interruptible, channel)
    H.Fire(channel and "UNIT_SPELLCAST_CHANNEL_START" or "UNIT_SPELLCAST_START", "target", secret, secret, 77)
    H.Fire(interruptible and "UNIT_SPELLCAST_INTERRUPTIBLE" or "UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
end

return M
