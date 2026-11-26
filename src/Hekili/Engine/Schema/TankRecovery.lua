-- Live group threat observations used by tank priorities. Class packs supply their own melee probe,
-- eligible attacks and emergency policy. Forecast casts never contribute to recovery evidence.
local addon, ns = ...
local Hekili, Facade = _G[addon], ns.Facade
local C_Spell, GetTime, issecretvalue = Facade.C_Spell, Facade.GetTime, Facade.issecretvalue
local partyUnits = { "party1", "party2", "party3", "party4" }
local plateUnits, plateVictims = {}, {}
for i = 1, 40 do
    local unit = "nameplate" .. i
    plateUnits[i], plateVictims[i] = unit, unit .. "target"
end

local function plain(value)
    if not issecretvalue(value) then
        return value
    end
end

function Hekili:NewTankRecovery(spec, config)
    local state, plates = self.State, config.plates or {}
    local rangeSpell = config.rangeSpell or config.meleeSpell
    if not config.plates then
        spec:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
            unit = plain(unit)
            if type(unit) == "string" then
                plates[unit] = unit .. "target"
            end
        end)
        spec:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
            unit = plain(unit)
            if type(unit) == "string" then
                plates[unit] = nil
            end
        end)
    end
    local raidUnits, bossUnits = {}, { "boss1", "boss2", "boss3", "boss4", "boss5" }
    for i = 1, 40 do
        raidUnits[i] = "raid" .. i
    end
    local targetSample, areaSample = {}, {}

    -- Existing plates may have appeared before the class subscribed to their added events.
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, login, reload)
        if plain(login) ~= true and plain(reload) ~= true then
            return
        end
        for i, unit in ipairs(plateUnits) do
            plates[unit] = plain(Facade.UnitExists(unit)) == true and plateVictims[i] or nil
        end
        targetSample.time, areaSample.time = nil, nil
    end)

    -- A matched plate may fill a hidden answer under Map. A readable answer on the selected unit
    -- takes precedence, including a negative one (dead, idle, out of range or on the other tank).
    local function unitFact(unit, plate, read, first)
        local value
        if first ~= nil then
            value = plain(read(first, unit))
            if value == nil and plate then
                value = plain(read(first, plate))
            end
        else
            value = plain(read(unit))
            if value == nil and plate then
                value = plain(read(plate))
            end
        end
        return value
    end

    local function eligibleEnemy(unit, raid, plate, area)
        if
            unitFact(unit, plate, Facade.UnitExists) ~= true
            or unitFact(unit, plate, Facade.UnitCanAttack, "player") ~= true
            or unitFact(unit, plate, Facade.UnitIsPlayer) ~= false
            or unitFact(unit, plate, Facade.UnitIsDead) ~= false
            or unitFact(unit, plate, Facade.UnitAffectingCombat) ~= true
            or not area
                and config.avoidUnit
                and (config.avoidUnit(unit) == true or plate and config.avoidUnit(plate) == true)
        then
            return false
        end
        local level, classification =
            unitFact(unit, plate, Facade.UnitLevel), unitFact(unit, plate, Facade.UnitClassification)
        if level == -1 or classification == "worldboss" then
            return false
        end
        if raid then
            return type(level) == "number"
                and level > 0
                and (
                    classification == "elite"
                    or classification == "rareelite"
                    or classification == "normal"
                    or classification == "rare"
                    or classification == "minus"
                )
        end
        return true
    end

    local function victimIdentity(victim, raid)
        local exists = plain(Facade.UnitExists(victim))
        if exists == false then
            return false
        end
        local player = plain(Facade.UnitIsUnit(victim, "player"))
        if player == true then
            return "player"
        end
        if plain(Facade.UnitIsUnit(victim, "pet")) == true then
            return false
        end
        if raid then
            local index = Facade.UnitInRaid(victim)
            if not issecretvalue(index) then
                if type(index) == "number" then
                    return raidUnits[index]
                elseif player == false and exists == true then
                    return false
                end
            end
            return
        end
        local resolved = player == false and exists == true
        for _, party in ipairs(partyUnits) do
            local same = plain(Facade.UnitIsUnit(victim, party))
            if same == true then
                return party
            end
            resolved = resolved and same == false
        end
        if resolved then
            return false
        end
    end

    local function looseMember(member, raid)
        if
            member
            and member ~= "player"
            and plain(Facade.UnitExists(member)) == true
            and plain(Facade.UnitIsPlayer(member)) == true
            and plain(Facade.UnitIsDead(member)) ~= true
            and plain(Facade.UnitIsUnit(member, "player")) == false
        then
            local role = Facade.GroupRole(member)
            if role == "HEALER" or role == "DAMAGER" or (not raid and role == "NONE") then
                return member
            end
        end
    end

    -- Outdoor world bosses do not always have an encounter ID or a boss unit. Their engaged
    -- plate still identifies the fight when the selected enemy and the potential pickup are adds.
    local function fightingWorldBoss()
        for plate, victim in pairs(plates) do
            if
                (plain(Facade.UnitClassification(plate)) == "worldboss" or plain(Facade.UnitLevel(plate)) == -1)
                and plain(Facade.UnitExists(plate)) == true
                and plain(Facade.UnitIsDead(plate)) == false
                and plain(Facade.UnitCanAttack("player", plate)) == true
                and plain(Facade.UnitAffectingCombat(plate)) == true
            then
                local raidIndex, threat =
                    plain(Facade.UnitInRaid(victim)), plain(Facade.UnitThreatSituation("player", plate))
                if
                    plain(Facade.UnitIsUnit(victim, "player")) == true
                    or plain(Facade.UnitIsUnit(victim, "pet")) == true
                    or plain(Facade.UnitInParty(victim)) == true
                    or (type(raidIndex) == "number" and raidIndex > 0)
                    or type(threat) == "number"
                then
                    return true
                end
            end
        end
        return false
    end

    local function recoveryGroup(area)
        local size = plain(Facade.GetNumGroupMembers())
        if type(size) ~= "number" or size < 2 or (not area and config.safePack and not config.safePack()) then
            return
        end
        local _, instance = Facade.IsInInstance()
        instance = plain(instance)
        local raid = plain(Facade.IsInRaid())
        if
            raid == nil
            or (raid and instance ~= "raid" and instance ~= "none")
            or (not raid and instance ~= "party" and instance ~= "none" and instance ~= "scenario")
        then
            return
        end
        -- The encounter flag survives a reload on a boss add. A visible boss token also protects
        -- the approach to a scripted handoff, before an encounter-start event has reached the UI.
        local encounter = Facade.C_InstanceEncounter.IsEncounterInProgress()
        if encounter == true or (raid and encounter ~= false) then
            return
        end
        for _, bossUnit in ipairs(bossUnits) do
            if plain(Facade.UnitExists(bossUnit)) ~= false then
                return
            end
        end
        local role = Facade.GroupRole("player")
        if role == "TANK" or (not raid and role == "NONE") then
            if instance ~= "none" or not fightingWorldBoss() then
                return raid, role
            end
        end
    end

    -- Used for tank rotations on a mob already attacking us, including a boss. This never initiates a handoff.
    local function holdingTarget()
        local key = Facade.TargetMemoryKey()
        local plate = Facade.TargetMemoryPlate(key)
        if
            not key
            or (type(key) == "number" and not plate)
            or unitFact("target", plate, Facade.UnitExists) ~= true
            or unitFact("target", plate, Facade.UnitCanAttack, "player") ~= true
            or unitFact("target", plate, Facade.UnitIsPlayer) ~= false
            or unitFact("target", plate, Facade.UnitIsDead) ~= false
            or unitFact("target", plate, Facade.UnitAffectingCombat) ~= true
        then
            return false
        end
        local status = unitFact("target", plate, Facade.UnitThreatSituation, "player")
        if status ~= 2 and status ~= 3 then
            return false
        end
        local ours = Facade.UnitIsUnit("targettarget", "player")
        if ours == nil and plate then
            ours = Facade.UnitIsUnit(plate .. "target", "player")
        end
        return ours == true
    end

    local function currentMember(raid, plate)
        local member = victimIdentity("targettarget", raid)
        if member == nil and plate then
            member = victimIdentity(plate .. "target", raid)
        end
        return member
    end

    local function otherTank()
        local raid = plain(Facade.IsInRaid())
        if raid == nil then
            return false
        end
        local member = currentMember(raid, Facade.TargetMemoryPlate(Facade.TargetMemoryKey()))
        return member and member ~= "player" and Facade.GroupRole(member) == "TANK" or false
    end

    local function currentThreat(raid, key, spell, area)
        if raid == nil or not spell then
            return
        end
        local plate = Facade.TargetMemoryPlate(key)
        if type(key) == "number" and not plate then
            return
        end
        if
            not eligibleEnemy("target", raid, plate, area)
            or unitFact("target", plate, C_Spell.IsSpellInRange, spell) ~= true
        then
            return
        end
        return unitFact("target", plate, Facade.UnitThreatSituation, "player"), currentMember(raid, plate), plate
    end

    -- Called by the navigation engine after a real landing, before it resets the simulation for that target.
    local function safeLanding()
        local key = Facade.TargetMemoryKey()
        if not key then
            return false
        end
        local raid = recoveryGroup()
        local status, member = currentThreat(raid, key, rangeSpell())
        return (status == 2 or status == 3) and member == "player"
            or (status == 0 or status == 1) and looseMember(member, raid) ~= nil
    end

    local function liveVictim()
        local raid = recoveryGroup()
        local status, member = currentThreat(raid, Facade.TargetMemoryKey(), rangeSpell())
        return (status == 0 or status == 1) and looseMember(member, raid) or nil
    end

    local function activeSpec()
        return state.spec[config.specKey] or config.alternateSpecKey and state.spec[config.alternateSpecKey]
    end

    -- Area abilities use the same recovery witnesses without the single-target crowd-control filters.
    local function threatEvidence(area)
        if
            not activeSpec()
            or not state.settings.cycle
            or state.solo
            or state.combat == 0
            or state.max_targets == 1
            or state.toggle.mode == "single"
            or state.target.is_dummy
            or state.encounterID > 0
        then
            return
        end
        local key = Facade.TargetMemoryKey()
        if not key then
            return
        end
        local time = GetTime()
        local generation = type(key) == "number" and Facade.TargetMemoryGeneration(key)
        local sample = area and areaSample or targetSample
        if sample.time == time and sample.key == key and sample.generation == generation then
            return sample
        end
        sample.time, sample.key, sample.generation = time, key, generation
        sample.loose, sample.other, sample.builder, sample.criticalOther = false, false, false, false
        sample.looseMelee, sample.otherMelee, sample.criticalMelee, sample.otherTauntable = false, false, false, false
        local raid, role = recoveryGroup(area)
        if raid == nil then
            return sample
        end
        local spell = rangeSpell()
        local melee = config.rangeSpell and config.meleeSpell() or nil
        local status, member, plate = currentThreat(raid, key, spell, area)
        local held = status == 3 and member == "player"
        local victim = (status == 0 or status == 1) and looseMember(member, raid)
        if not held and not victim then
            return sample
        end
        if victim then
            sample.looseMelee = not config.rangeSpell
                or (melee ~= nil and unitFact("target", plate, C_Spell.IsSpellInRange, melee) == true)
        end
        -- Keep rescuing the current victim unless a different groupmate is in immediate danger.
        local seekCritical = victim and config.urgentVictim and not config.urgentVictim(victim)
        if victim and role == "TANK" then
            sample.loose = victim
            if not seekCritical then
                return sample
            end
        end
        local currentPlate = type(key) == "number" and "nameplate" .. key
        for plate, targetOfPlate in pairs(plates) do
            local guid = plain(Facade.UnitGUID(plate))
            local other = currentPlate and plate ~= currentPlate
                or type(key) == "string" and type(guid) == "string" and guid ~= key
            if
                other
                and eligibleEnemy(plate, raid, nil, area)
                and plain(C_Spell.IsSpellInRange(spell, plate)) == true
            then
                local threat = plain(Facade.UnitThreatSituation("player", plate))
                local loose = (held or seekCritical)
                    and (threat == 0 or threat == 1)
                    and looseMember(victimIdentity(targetOfPlate, raid), raid)
                local urgent = loose and config.urgentVictim and config.urgentVictim(loose)
                if loose and (held or urgent) then
                    sample.other = true
                    sample.otherTauntable = sample.otherTauntable or not config.canTaunt or config.canTaunt(guid, time)
                    local inMelee = not config.rangeSpell
                        or (melee ~= nil and plain(C_Spell.IsSpellInRange(melee, plate)) == true)
                    sample.otherMelee = sample.otherMelee or inMelee
                    sample.criticalMelee = sample.criticalMelee or urgent and inMelee or false
                    sample.builder = sample.builder or not config.usableBuilder or config.usableBuilder(guid, time)
                    sample.criticalOther = sample.criticalOther or urgent or false
                    if
                        (held or sample.loose)
                        and sample.builder
                        and sample.otherMelee
                        and sample.otherTauntable
                        and (not config.urgentVictim or sample.criticalMelee)
                    then
                        break
                    end
                elseif victim and threat == 3 and plain(Facade.UnitIsUnit(targetOfPlate, "player")) == true then
                    -- An unassigned tank must be demonstrably holding another enemy in this pull.
                    sample.loose = victim
                    if not seekCritical or sample.criticalMelee then
                        break
                    end
                end
            end
        end
        if victim and not sample.loose then
            sample.other, sample.criticalOther, sample.otherMelee, sample.builder = false, false, false, false
            sample.criticalMelee = false
        end
        return sample
    end

    local window, settle = config.window or 8, 1.5
    local key, generation, victim, first, second
    local pendingCast, pendingSpell, pendingKind

    local function reset()
        key, generation, victim, first, second, pendingCast, pendingSpell, pendingKind =
            nil, nil, nil, nil, nil, nil, nil, nil
    end

    local function observe(start)
        local targetKey = Facade.TargetMemoryKey()
        local targetGeneration = Facade.TargetMemoryGeneration(targetKey)
        local current = targetGeneration and threatEvidence()
        local member = current and current.loose
        local t = GetTime()
        if targetKey ~= key or targetGeneration ~= generation or member ~= victim or (first and t - first > window) then
            reset()
        end
        if start and member then
            key, generation, victim = targetKey, targetGeneration, member
        end
        return victim, t
    end

    -- SENT names can be hidden in an instance. When there is also a different hostile focus or
    -- mouseover with an indistinguishable name, the cast cannot prove an attempt on our current mob.
    local function couldBeOtherTarget(unit, name)
        if
            plain(Facade.UnitExists(unit)) ~= true
            or plain(Facade.UnitCanAttack("player", unit)) ~= true
            or Facade.UnitIsUnit(unit, "target") == true
        then
            return false
        end
        local alternate = Facade.UnitName(unit)
        return not name or not alternate or name == alternate
    end

    spec:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", nil, function(_, _, name, castID, spellID)
        local id = plain(spellID)
        if not id or not activeSpec() or not state.settings.cycle then
            return
        end
        name = plain(name)
        local kind = config.classifyCast(id, name)
        if not kind then
            return
        end
        pendingCast, pendingSpell, pendingKind = nil, nil, nil
        castID = plain(castID)
        local current = Facade.UnitName("target")
        if
            not castID
            or (name and current and name ~= current)
            or couldBeOtherTarget("mouseover", name)
            or couldBeOtherTarget("focus", name)
            or (kind == "builder" and not observe(true))
        then
            return
        end
        pendingCast, pendingSpell, pendingKind = castID, id, kind
    end)

    local function failed(_, _, castID)
        if pendingCast and pendingCast == plain(castID) then
            pendingCast, pendingSpell, pendingKind = nil, nil, nil
            if not first then
                reset()
            end
        end
    end
    spec:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", nil, failed)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player", nil, failed)
    spec:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", nil, failed)

    spec:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", nil, function(_, _, castID, spellID)
        local id = plain(spellID)
        if not id or not activeSpec() then
            return
        end
        local matched = pendingCast and pendingCast == plain(castID) and pendingSpell == id
        if (matched and pendingKind == "rescue") or (not matched and config.classifyCast(id) == "rescue") then
            reset()
        elseif matched then
            local member, t = observe()
            if member and pendingCast then
                if not first then
                    first = t
                elseif not second then
                    second = t
                end
            end
            pendingCast, pendingSpell, pendingKind = nil, nil, nil
        end
    end)

    -- A higher-priority interrupt or defensive can keep the Taunt expression from being evaluated.
    -- Discard its history on a live threat or victim change even during that gap.
    local function confirmPressure()
        if victim and liveVictim() ~= victim then
            reset()
        end
    end
    spec:RegisterUnitEvent("UNIT_TARGET", "target", nil, confirmPressure)
    spec:RegisterUnitEvent("UNIT_THREAT_LIST_UPDATE", "target", nil, confirmPressure)
    spec:RegisterUnitEvent("UNIT_THREAT_SITUATION_UPDATE", "player", "target", confirmPressure)
    spec:RegisterEvent("PLAYER_TARGET_CHANGED", reset)
    spec:RegisterEvent("PLAYER_REGEN_ENABLED", reset)
    spec:RegisterEvent("PLAYER_ENTERING_WORLD", reset)
    spec:RegisterEvent("GROUP_ROSTER_UPDATE", reset)

    local function lastResort()
        if not key then
            return false
        end
        local member, t = observe()
        return member and second ~= nil and t - second >= settle or false
    end
    return {
        plates = plates,
        evidence = threatEvidence,
        looseVictim = liveVictim,
        lastResort = lastResort,
        safeLanding = safeLanding,
        holdingTarget = holdingTarget,
        otherTank = otherTank,
    }
end
