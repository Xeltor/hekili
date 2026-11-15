local assert = require("luassert")
local headless = require("Game.harness.headless")
local SECRET = require("Game.State.helpers.fake_api").SECRET
local learn = require("Forever.wowsims.learn_rogue")

local kit = require("Forever.helpers.load_druid").load(nil, "src/Hekili_Rogue/Rogue.lua", "ROGUE").abilities
local BASELINE = {}
for _, key in ipairs({
    "ambush",
    "backstab",
    "cheap_shot",
    "evasion",
    "eviscerate",
    "feint",
    "garrote",
    "kick",
    "kidney_shot",
    "rupture",
    "shank",
    "sinister_strike",
    "slice_and_dice",
    "stealth",
    "vanish",
}) do
    local ability = kit[key]
    BASELINE[#BASELINE + 1] = ability.id
    for _, rank in ipairs(ability.copy or {}) do
        BASELINE[#BASELINE + 1] = rank
    end
end

local function rogue(spec, level, o)
    o = o or {}
    local known = {}
    for _, id in ipairs(BASELINE) do
        if assert(learn[id], id) <= level then
            known[#known + 1] = id
        end
    end
    for _, id in ipairs(o.spells or {}) do
        known[#known + 1] = id
    end
    local items = { [16] = { 100, "Main Hand", "INVTYPE_WEAPON", 2, o.daggers and 15 or 7 } }
    if o.noMainWeapon then
        items[16] = nil
    end
    if level >= 10 and not o.singleWeapon then
        items[17] = { 101, "Off Hand", "INVTYPE_WEAPON", 2, 15 }
    end
    local H = headless.new({
        pack = spec .. " (wowsims.com)",
        character = {
            class = "ROGUE",
            classID = 4,
            specID = 1488,
            level = level,
            race = o.race,
            known = known,
            talents = o.talents,
            power = { type = 3, token = "ENERGY", max = 100, value = o.energy or 100 },
            items = items,
            instanceType = o.instance,
        },
        beforeLogin = function(core)
            if o.secretAttack then
                local current = core.Client.C_Spell.IsCurrentSpell
                core.Client.C_Spell.IsCurrentSpell = function(id)
                    if id == 6603 then
                        return SECRET
                    end
                    return current(id)
                end
            end
            if o.beforeLogin then
                o.beforeLogin(core)
            end
        end,
    })
    local ctl = H.ctl
    for key, value in pairs(o.settings or {}) do
        H.Hekili.Engine.settings.specs[H.Hekili.State.spec.id].settings[key] = value
    end
    H.Hekili:SettingsChanged()
    assert.are.same({}, H.loadErrors)
    ctl.classification, ctl.groupMembers = o.kind, o.group or 0
    ctl.level.target, ctl.distance.target = o.boss and -1 or level, o.distance or 3
    ctl.threat.target, ctl.stealthed = o.threat, o.stealthed or false
    ctl.exists.targettarget = not o.prepull and not o.idleTarget
    ctl.unitIs.targettarget = not o.group and not o.idleTarget and "player" or nil
    ctl.unitCombat.target = not o.prepull and not o.idleTarget
    ctl.current[6603] = o.attack ~= false
    ctl.power[4], ctl.comboPoints.target = o.points or 0, o.points or 0
    ctl.unitHealth.player = o.health or 1000
    ctl.isPlayer.target = o.playerTarget
    if o.add then
        ctl.cvars.nameplateShowAll, ctl.cvars.nameplateShowEnemies = "1", "1"
        ctl.exists.nameplate1 = true
        ctl.guid.nameplate1 = "Creature-0-0-0-0-347-000003"
        ctl.distance.nameplate1 = o.add
        ctl.unitCombat.nameplate1 = true
        ctl.exists.nameplate1target, ctl.unitIs.nameplate1target = true, "player"
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    end
    for index, plate in ipairs(o.plates or {}) do
        ctl.cvars.nameplateShowAll, ctl.cvars.nameplateShowEnemies = "1", "1"
        local unit = "nameplate" .. index
        ctl.exists[unit] = plate.exists == nil and true or plate.exists
        ctl.guid[unit] = plate.guid or ("Creature-0-0-0-0-347-" .. string.format("%06d", index + 10))
        ctl.distance[unit] = plate.distance or 3
        ctl.unitCombat[unit] = plate.combat == nil and true or plate.combat
        ctl.friendly[unit], ctl.dead[unit], ctl.isPlayer[unit] =
            plate.friendly or plate.attackable == false, plate.dead, plate.player
        ctl.exists[unit .. "target"] = plate.target ~= nil
        ctl.unitIs[unit .. "target"] = plate.target
        ctl.inParty[unit .. "target"] = plate.partyTarget
            or (type(plate.target) == "string" and plate.target:match("^party") ~= nil)
        ctl.threat[unit] = plate.threat
        if plate.sameTarget then
            ctl.unitIs[unit] = "target"
        end
        H.Fire("NAME_PLATE_UNIT_ADDED", unit)
    end
    for id, duration in pairs(o.buffs or {}) do
        local rows = ctl.auras.player.HELPFUL
        rows[#rows + 1] = { spellId = id, expirationTime = ctl.now + duration, applications = 0 }
    end
    if o.snd then
        ctl.auras.player.HELPFUL[#ctl.auras.player.HELPFUL + 1] =
            { spellId = 5171, expirationTime = ctl.now + 20, applications = 0 }
    end
    if o.poison then
        ctl.itemCount[6947] = 5
        ctl.itemCount[8928] = 5
        ctl.items[6947] = { "Instant Poison", icon = 132273 }
    end
    if o.deadly then
        ctl.itemCount[2892] = 5
        ctl.items[2892] = { "Deadly Poison", icon = 132290 }
    end
    if o.potion then
        ctl.itemCount[118] = 1
        ctl.items[118] = { "Minor Healing Potion", icon = 134829 }
    end
    if o.mainPoison then
        ctl.enchants[0] = { { hasEnchant = true, enchantType = 3, timeLeft = 600000, charges = 50, enchantID = 323 } }
    end
    if not o.defensives then
        H.Hekili:FireToggle("defensives", "off")
    end
    if o.noKick then
        local cd = {
            isActive = true,
            isOnGCD = false,
            startTime = ctl.now,
            duration = type(o.noKick) == "number" and o.noKick or 10,
        }
        for _, id in ipairs({ 1766, 1767, 1768, 1769 }) do
            ctl.cooldown[id] = cd
        end
    end
    H.Fire("PLAYER_TARGET_CHANGED")
    H.Fire("UPDATE_STEALTH")
    H.Fire("UNIT_AURA", "player")
    H.Fire("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS")
    H.Fire("WEAPON_ENCHANT_CHANGED")
    assert(headless.cycle(H, ctl.now + 0.2))
    if not o.prepull then
        ctl.combat = true
        H.Fire("PLAYER_REGEN_DISABLED")
    end
    if o.cast then
        H.Fire("UNIT_SPELLCAST_CHANNEL_START", "target", SECRET, SECRET, 77)
        if o.uninterruptible then
            H.Fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
        end
    end
    assert.is_true(H.Hekili.Engine.Subscribe("Primary", function() end))
    return H
end

local function pick(H)
    assert(headless.cycle(H, H.ctl.now + 0.2))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output.Primary
    return out.count > 0 and out.recs[1] or {}
end

return { rogue = rogue, pick = pick, headless = headless, SECRET = SECRET }
