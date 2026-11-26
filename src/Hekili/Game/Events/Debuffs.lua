-- Debuff recommendation gates. The cast tracker supplies the target and the landing window.
local _, ns = ...
local VS, I = ns.VirtualState, ns.VirtualStateInternal
local T, U, X = I.Tickets, I.Units, I.Expect
local A, auras = I.ab, I.auras

-- Content declares verified NPC immunities and aura-granted protection; the core only matches mechanic keys.
local permanent, protection = {}, {}
I.DebuffProtection = protection

local primary, effect, ability = {}, {}, {}
local immune, protectedUntil, protectedGUID, protectedBy = {}, {}, {}, {}
local repeatGroup, repeatDelay, repeatSetting, retryDelay = {}, {}, {}, {}
local groups, groupByKey, settings = {}, {}, {}
local NEVER, HISTORY_CAP = -math.huge, U.UNIT_CAP

-- Optional content policy: minimum spacing between our own attempts in a declared group. This is not DR: it
-- neither observes another player's casts nor promises full duration after the delay. All slots are allocated
-- at build time. An unidentified attempt or an evicted live history uses the bounded unknown slot.
local function repeatBlocked(j, guid, t)
    local group = groups[repeatGroup[j]]
    if not group then
        return
    end
    local delay = repeatSetting[j] and settings[repeatSetting[j]] or nil
    delay = type(delay) == "number" and delay >= 0 and delay < math.huge and delay or repeatDelay[j]
    if delay <= 0 then
        return
    end
    if t < group.unknown + delay then
        return "recent own control attempt; target unknown"
    end
    local known = type(guid) == "string" and guid ~= ""
    for k = 1, HISTORY_CAP do
        if t < group.at[k] + delay and (not known or group.guid[k] == guid) then
            return known and "recent own control attempt" or "recent own control attempt; target unknown"
        end
    end
end

U.OnGone(function(unit, guid, why)
    if why == U.DEAD or why == U.RESET then
        immune[unit] = nil
    end
    -- RESET releases an unbound registry slot at combat end, not proof that the mob or its control history ended.
    -- Retain the bounded history across that edge (including Vanish) and while its declared group survives rebuilds.
    if why == U.DEAD then
        for _, group in ipairs(groups) do
            for k = 1, HISTORY_CAP do
                if group.guid[k] == guid then
                    group.guid[k], group.at[k], group.ability[k] = "", NEVER, false
                end
            end
        end
    end
    protectedUntil[unit], protectedGUID[unit], protectedBy[unit] = nil, nil, nil
end)

I.OnBuild(function(def)
    settings = def.settings or settings
    local previousGroups, previousKeys = groups, groupByKey
    groups, groupByKey = {}, {}
    for key in pairs(permanent) do
        permanent[key] = nil
    end
    for key in pairs(protection) do
        protection[key] = nil
    end
    for key in pairs(ability) do
        ability[key] = nil
    end
    for j = 1, #def.auras do
        local aura = def.auras[j]
        effect[j] = aura.debuffMechanic or false
        if type(aura.debuffMechanic) == "string" and type(aura.debuffImmuneNPCs) == "table" then
            for _, npc in ipairs(aura.debuffImmuneNPCs) do
                if type(npc) == "number" and npc > 0 and npc < math.huge then
                    local rule = permanent[npc] or {}
                    rule[aura.debuffMechanic] = true
                    permanent[npc] = rule
                end
            end
        end
        if type(aura.debuffImmunities) == "table" then
            for _, id in ipairs(def.auraIds[j]) do
                local rule = protection[id] or {}
                for _, mechanic in ipairs(aura.debuffImmunities) do
                    if type(mechanic) == "string" and mechanic ~= "" then
                        rule[mechanic] = true
                    end
                end
                protection[id] = rule
            end
        end
        repeatGroup[j], repeatSetting[j] = false, false
        repeatDelay[j], retryDelay[j] = 0, 0
        local key, delay, retry = aura.debuffRepeatGroup, aura.debuffRepeatDelay, aura.debuffRetryDelay
        if type(retry) == "number" and retry > 0 and retry < math.huge then
            retryDelay[j] = retry
        end
        if type(key) == "string" and key ~= "" and type(delay) == "number" and delay > 0 and delay < math.huge then
            local g = groupByKey[key]
            if not g then
                g = #groups + 1
                groupByKey[key] = g
                local group = previousGroups[previousKeys[key]]
                if not group then
                    group = { guid = {}, at = {}, ability = {}, unknown = NEVER }
                    for k = 1, HISTORY_CAP do
                        group.guid[k], group.at[k], group.ability[k] = "", NEVER, false
                    end
                end
                groups[g] = group
            end
            repeatGroup[j], repeatDelay[j] = g, delay
            repeatSetting[j] = type(aura.debuffRepeatSetting) == "string" and aura.debuffRepeatSetting or false
        end
    end
    for a = 1, A.n do
        local obj = def.abilities[a]
        local key = obj.debuffApplication
        if not key and (obj.expects == "debuff" or obj.expects == "ticks") then
            key = obj.cycle or obj.aura or obj.key
        end
        ability[obj.key] = a
        primary[a] = key and auras.byKey[key] or false
    end
end)

I.On(VS.Obs.CastSuccess, function(o)
    local j = primary[o.a]
    local group = j and groups[repeatGroup[j]]
    if not group then
        return
    end
    local guid = o.guid
    if type(guid) ~= "string" or guid == "" then
        group.unknown = math.max(group.unknown, o.t)
        return
    end
    local slot = 1
    for k = 1, HISTORY_CAP do
        if group.at[k] < group.at[slot] then
            slot = k
        end
    end
    group.unknown = math.max(group.unknown, group.at[slot])
    group.guid[slot], group.at[slot], group.ability[slot] = guid, o.t, A.key[o.a]
end)

-- Only a settled failure attributed to this exact own cast releases its history. IMMUNE remains a bounded hold;
-- DEFLECT/EVADE observations are reactions only, not proof that this application failed (Rows.lua).
I.On(VS.Obs.Avoided, function(o)
    local kind, hit = o.c, I.HitKind
    if kind ~= hit.DODGE and kind ~= hit.PARRY and kind ~= hit.MISS and kind ~= hit.RESIST then
        return
    end
    local j = primary[o.a]
    local group = j and groups[repeatGroup[j]]
    if not group or type(o.guid) ~= "string" or o.guid == "" then
        return
    end
    for k = 1, HISTORY_CAP do
        if group.guid[k] == o.guid and group.at[k] == o.b and group.ability[k] == A.key[o.a] then
            group.guid[k], group.at[k], group.ability[k] = "", NEVER, false
        end
    end
end)

-- Called only after a readable aura walk. An incomplete walk can supply a positive read, but cannot prove removal.
function I.ObserveDebuffProtection(unit, spell, expires, complete)
    if unit == 0 then
        return
    end
    if expires then
        protectedGUID[unit], protectedUntil[unit], protectedBy[unit] = U.GUID(unit), expires, spell
    elseif complete then
        protectedGUID[unit], protectedUntil[unit], protectedBy[unit] = nil, nil, nil
    end
end

local function immunity(j, guid, t)
    if type(guid) ~= "string" or guid == "" then
        return
    end
    local unit = U.Find(guid)
    local mechanic = effect[j]
    if mechanic then
        local npc = tonumber(guid:match("^Creature%-.*%-(%d+)%-[%x]+$"))
        local rule = permanent[npc]
        if rule and rule[mechanic] then
            return "immune NPC"
        end
        local shield = protection[protectedBy[unit]]
        if shield and shield[mechanic] and protectedGUID[unit] == guid and protectedUntil[unit] > t then
            return "temporary immunity"
        end
    end
    local result = immune[unit]
    if result and result.guid == guid then
        local expiry = result[auras.id[j]]
        if expiry == true then
            return "immune target"
        elseif type(expiry) == "number" and t < expiry then
            return "temporary immunity"
        end
    end
end

function I.DebuffImmune(j, guid, t)
    return immunity(j, guid, t) ~= nil
end

function VS.DebuffImmunity(key, guid, t)
    local j = auras.byKey[key]
    return j and immunity(j, guid, t)
end

function VS.DebuffRepeatBlocked(key, guid, t)
    local j = auras.byKey[key]
    return j and repeatBlocked(j, guid, t)
end

-- A matched immune result applies to this spawn and this application. Only verified data is shared across spawns.
function I.IsDebuffRefusal(a, action)
    return primary[a] and (action == "IMMUNE" or action == "RESIST")
end

function I.DebuffRefused(a, guid, outcome, t)
    local j = primary[a]
    if not j or not guid or guid == "" or outcome ~= I.HitKind.IMMUNE then
        return
    end
    -- A new observed refusal restarts a finite retry delay, even if the previous refusal is still being held.
    if retryDelay[j] <= 0 and immunity(j, guid, t) then
        return
    end
    local unit = U.Find(guid)
    if unit == 0 or U.IsDead(unit) then
        return
    end
    local result = immune[unit]
    if not result or result.guid ~= guid then
        result = { guid = guid }
        immune[unit] = result
    end
    result[auras.id[j]] = retryDelay[j] > 0 and t + retryDelay[j] or true
end

-- The ticking ticket stays open for the entire DoT. Only its initial application window can hold a repeat.
local function deadline(i)
    if T.state[i] == T.COMMITTED then
        return T.hi[i]
    elseif T.state[i] == T.TENT then
        return T.fin[i]
    elseif T.kind[i] == X.TICKS then
        if T.done[i] == 0 and T.link[i] == 0 then
            return T.at[i] + (T.speed[i] > 0 and T.H[i] or I.Log.LandWindow(1))
        end
        return 0
    end
    return T.hi[i]
end

function VS.DebuffBlocked(key, t, guid)
    local j = primary[ability[key]]
    if not j then
        return
    end
    guid = guid or U.Bound(1)
    local repeated = repeatBlocked(j, guid, t)
    if repeated then
        return repeated
    end
    if guid == "" then
        return
    end
    local reason = immunity(j, guid, t)
    if reason then
        return reason
    end
    for i = 1, T.CAP do
        if
            T.state[i] ~= T.FREE
            and T.guid[i] == guid
            and primary[T.ab[i]] == j
            and not U.IsDead(T.uid[i])
            and t < deadline(i)
            and (T.state[i] == T.COMMITTED or not I.DebuffResolved(j, guid, T.at[i]))
        then
            return "waiting for debuff result"
        end
    end
end

-- Cycling shows a generic swap arrow. Suppress it when every visible alternative is known to be blocked.
function VS.DebuffCycleBlocked(key, t, enemyCount)
    if not primary[ability[key]] then
        return
    end
    local target = U.Bound(1)
    local seen = 0
    for k = 1, #I.Plates.active do
        local u = I.Plates.active[k] and U.Uid(k + 2) or 0
        local guid = U.GUID(u)
        if guid ~= "" and guid ~= target and U.Alive(u) then
            seen = seen + 1
            if not VS.DebuffBlocked(key, t, guid) then
                return
            end
        end
    end
    return seen > 0 and seen >= enemyCount - 1
end
