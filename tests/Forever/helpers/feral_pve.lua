local assert = require("luassert")
local headless = require("Game.harness.headless")
local W = require("Forever.helpers.druid_loop_world")
local SECRET = require("Game.State.helpers.fake_api").SECRET

local function druid(o)
    local c = W.Feral.character()
    c.level, c.known, c.talents = o.level or 24, o.known, o.talents or {}
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
    ctl.isInRaid = o.instance == "raid"
    ctl.distance.target, ctl.level.target = o.distance or 3, o.boss and -1 or c.level
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
    ctl.ranges[5177] = ctl.ranges[5176]
    if o.noTarget then
        ctl.exists.target = false
    end
    -- These priority fixtures read Primary unless a separate display was requested.
    local toggles = H.Hekili.DB.profile.toggles
    toggles.defensives.separate = o.display == "Defensives"
    toggles.interrupts.separate = o.display == "Interrupts"
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
    for pt, value in pairs({ [0] = o.mana or 3000, [1] = o.rage or 30, [3] = o.energy or 100, [4] = o.points or 0 }) do
        pools[pt] = { lo = value, est = value, hi = value, conf = 1 }
    end
    H.ns.VirtualState.Power = function(pt)
        return pools[pt]
    end
    local display = o.display or "Primary"
    if not o.uiOnly then
        assert.is_true(H.Hekili.Engine.Subscribe(display, function() end))
    end
    assert(headless.cycle(H, ctl.now + 1.6))
    assert.are.same({}, H.errors)
    local out = H.Hekili.Engine.Output[display]
    return out.count > 0 and out.recs[1].actionName or nil, out, H
end

local function tank(o)
    o.spec, o.instance, o.group, o.role = "Guardian", "party", 5, o.role or "TANK"
    o.form = o.form or "bear_form"
    return druid(o)
end

return { druid = druid, tank = tank }
