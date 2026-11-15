local headless = require("Game.harness.headless")
local assert = require("luassert")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local ws = require("Forever.helpers.wowsims")
local world = require("Forever.helpers.warrior_world")
local prot = require("Forever.helpers.protection_gate")

local PACK = "Protection (wowsims.com)"
local KIT = {}
for i, key in ipairs(prot.KIT) do
    KIT[i] = key
end
KIT[#KIT + 1] = "concussion_blow"
KIT[#KIT + 1] = "disarm"
KIT[#KIT + 1] = "last_stand"

local function warrior(level, rage, options)
    options = options or {}
    local character = ws.content(world.Protection, {
        level = level,
        learn = ws.learn("WARRIOR"),
        kit = KIT,
    }).character()
    character.talents = options.talents or {}
    if not options.noAttackSpell then
        character.known[#character.known + 1] = 6603
    end
    local talentSpells = { 12809, 12975, 23922, 1310317, 1329555 }
    for _, spell in ipairs(talentSpells) do
        if character.talents[spell] then
            character.known[#character.known + 1] = spell
        end
    end
    character.form = options.form or (level >= 10 and 2 or 1)
    character.power.value = rage
    character.instanceType = options.instance
    character.ranges = {}
    for _, spell in ipairs({ 100, 6178, 11578, 1240287, 1240288, 1240289 }) do
        character.ranges[spell] = { 8, 25 }
    end
    local hasVanguard = character.talents[1310317]
    for i = #character.known, 1, -1 do
        local spell = character.known[i]
        if
            (not hasVanguard and spell >= 1240287 and spell <= 1240289)
            or (hasVanguard and (spell == 100 or spell == 6178 or spell == 11578))
        then
            table.remove(character.known, i)
        end
    end
    if options.noShield then
        character.items = world.character().items
    end
    if options.noWeapon then
        character.items = {}
    end
    local H = headless.new({
        character = character,
        pack = options.pack or PACK,
        beforeLogin = function(core)
            if options.autoAttackProbe then
                local current = core.Client.C_Spell.IsCurrentSpell
                core.Client.C_Spell.IsCurrentSpell = function(id)
                    if id == 6603 then
                        return options.autoAttackProbe()
                    end
                    return current(id)
                end
            end
        end,
    })
    local ctl = H.ctl
    assert.are.same({}, H.loadErrors)
    ctl.current[6603] = options.autoAttack ~= false
    ctl.distance.target = options.distance or 3
    ctl.guid.target = options.target or ctl.guid.target
    ctl.creature.target = options.creature
    ctl.classification = options.classification
    ctl.groupMembers = options.group or 0
    ctl.threat.target = options.threat
    -- Distinguish the player's combat state from the selected enemy's. An idle dungeon mob must not become
    -- engaged merely because the player is fighting something else; callers can also model a party's live pull.
    local engaged = options.engaged
    if options.idleTarget then
        engaged = false
    elseif engaged == nil then
        engaged = not options.prepull
    end
    local victim = options.targetVictim
    if victim == nil then
        victim = ctl.groupMembers > 1 and (options.threat == 0 or options.threat == 1) and "party1" or "player"
    end
    ctl.unitCombat.target = engaged
    ctl.exists.targettarget = engaged == true and victim ~= false
    ctl.unitIs.targettarget = engaged == true and victim or nil
    ctl.level.target = options.boss and -1 or level
    ctl.unitHealth.player = options.health or 1000
    if not options.noBattleShout then
        ctl.auras.player.HELPFUL[1] = { spellId = 6673, expirationTime = ctl.now + 100, applications = 0 }
    end
    if options.victorious then
        ctl.auras.player.HELPFUL[2] = { spellId = 402975, expirationTime = ctl.now + 20, applications = 0 }
    end
    if options.shieldBlock then
        local buffs = ctl.auras.player.HELPFUL
        buffs[#buffs + 1] = { spellId = 2565, expirationTime = ctl.now + 7, applications = 2 }
    end
    for _, rank in ipairs({ 6572, 6574, 7379, 11600, 11601, 25288 }) do
        ctl.usable[rank] = options.revenge and { true, false } or { false, false }
    end
    if options.potion then
        ctl.itemCount[118] = 1
        ctl.items[118] = { "Minor Healing Potion", icon = 134829 }
    end
    if options.bashCooldown then
        local rank = ctl.known[1671] and 1671 or 72
        local cd = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 12 }
        ctl.cooldown[72], ctl.cooldown[rank] = cd, cd
    end
    if not options.bloodrageReady then
        ctl.cooldown[2687] = { isActive = true, isOnGCD = false, startTime = ctl.now, duration = 60 }
    end
    H.Fire("UNIT_AURA", "player")
    H.Fire("PLAYER_TARGET_CHANGED")
    assert(headless.cycle(H, ctl.now + 0.2))
    if not options.prepull then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    if options.demo then
        H.Fire("UNIT_SPELLCAST_SENT", "player", "Unit", "Cast-demo", 1160)
        H.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-demo", 1160)
    end
    local VS = H.ns.VirtualState
    local power, pool = VS.Power, { est = rage, lo = rage, hi = rage, conf = 1 }
    if not options.unpinnedPower then
        VS.Power = function(pt, now)
            return pt == 1 and pool or power(pt, now)
        end
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function read(H, seconds)
    assert(headless.cycle(H, H.ctl.now + (seconds or 1.6)))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    return out.count > 0 and out.recs[1].actionName or nil
end

local function cast(H, interruptible, channel)
    H.Fire(channel and "UNIT_SPELLCAST_CHANNEL_START" or "UNIT_SPELLCAST_START", "target", SECRET, SECRET, 77)
    if interruptible then
        H.Fire("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
    else
        H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
    end
end

return { warrior = warrior, read = read, cast = cast, PACK = PACK }
