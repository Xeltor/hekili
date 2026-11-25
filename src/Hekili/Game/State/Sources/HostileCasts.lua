-- Recent cast events on the selected target, focus and active nameplates. Token changes discard the old evidence.
local _, ns = ...
local I = ns.VirtualStateInternal
local S, U, Plates = I.Sources, I.Units, I.Plates
local Plain = S.Plain
local Casts = {}
I.HostileCasts = Casts

local records, victims, observed = {}, {}, 0
for index = 1, 42 do
    records[index] = {
        start = false,
        bar = false,
        channel = false,
        kickable = false,
        spell = false,
        seenLive = false,
        ended = false,
        endedBar = false,
        endedChannel = false,
        npcGuid = false,
        npcID = false,
    }
    victims[index] = U.TOKENS[index] .. "target"
end

local function positive(value)
    if type(value) == "number" and value > 0 then
        return value
    end
end

local function canInterrupt(api, value)
    value = Plain(api, value)
    if type(value) == "boolean" then
        return not value
    end
end

local function castPayload(api, channel, bar, rawBlocked, rawSpell, rawStart, rawEnd)
    local start, finish = Plain(api, rawStart), Plain(api, rawEnd)
    if type(start) ~= "number" or type(finish) ~= "number" or finish <= start then
        start, finish = nil, nil
    end
    local hiddenSpell = api.issecretvalue(rawSpell)
    return true, channel, bar, canInterrupt(api, rawBlocked), positive(Plain(api, rawSpell)), start, finish, hiddenSpell
end

-- A secret name is only evidence of a cast when the client also gives it a plain bar ID.
local function readCast(api, unit)
    local castOK, rawName, _, _, rawStart, rawEnd, _, _, rawBlocked, rawSpell, rawBar = pcall(api.UnitCastingInfo, unit) -- secret: gated below
    local bar = positive(Plain(api, rawBar))
    if castOK and (bar or type(Plain(api, rawName)) == "string") then
        return castPayload(api, false, bar, rawBlocked, rawSpell, rawStart, rawEnd)
    end

    local channelOK, rawChannel, _, _, rawChannelStart, rawChannelEnd, _, rawLocked, rawChannelSpell, _, _, rawChannelBar =
        pcall(api.UnitChannelInfo, unit) -- secret: gated below
    bar = positive(Plain(api, rawChannelBar))
    if channelOK and (bar or type(Plain(api, rawChannel)) == "string") then
        return castPayload(api, true, bar, rawLocked, rawChannelSpell, rawChannelStart, rawChannelEnd)
    end
    if castOK and channelOK and not api.issecretvalue(rawName) and not api.issecretvalue(rawChannel) then
        return false
    end
end

function Casts.Index(unit)
    local index = U.INDEX[unit]
    if index and index <= 42 and (index <= 2 or Plates.active[index - 2]) then
        return index
    end
end

function Casts.Victim(index)
    return victims[index]
end

function Casts.NpcID(index, guid)
    if type(guid) ~= "string" then
        return
    end
    local record = records[index]
    if record.npcGuid ~= guid then
        record.npcGuid = guid
        record.npcID = tonumber(guid:match("^Creature%-.+%-(%d+)%-%x+$") or guid:match("^Vehicle%-.+%-(%d+)%-%x+$"))
    end
    return record.npcID
end

local function clear(index)
    local record = records[index]
    if record.start and not record.ended then
        observed = observed - 1
    end
    record.start, record.bar, record.channel, record.kickable, record.spell, record.seenLive, record.ended =
        nil, nil, nil, nil, nil, nil, nil
    record.endedBar, record.endedChannel = nil, nil
end

local function matched(record, channel, bar)
    return bar and record.bar == bar and record.channel == channel
end

local function start(channel)
    return function(_, time, unit, _, spell, bar)
        local index = Casts.Index(unit)
        if index then
            local record = records[index]
            bar, spell = positive(bar), positive(spell)
            if Casts.Ended(index, channel, bar) then
                return
            end
            if record.start and not record.ended and matched(record, channel, bar) then
                record.spell = spell or record.spell
                return
            end
            clear(index)
            record.start, record.bar, record.channel, record.spell = time, bar, channel, spell
            observed = observed + 1
        end
    end
end

local function finish(channel, fifth)
    return function(_, _, unit, _, _, a4, a5)
        local index = Casts.Index(unit)
        if not index then
            return
        end
        local record = records[index]
        local bar = positive(fifth and a5 or a4)
        if bar then
            record.endedBar, record.endedChannel = bar, channel
        end
        if
            record.start
            and not record.ended
            and (channel == nil or channel == record.channel)
            and (not bar or bar == record.bar)
        then
            record.ended = true
            observed = observed - 1
        end
    end
end

local function kickable(answer)
    return function(api, time, unit)
        local index = Casts.Index(unit)
        if not index then
            return
        end
        local record = records[index]
        local up, channel, bar = readCast(api, unit)
        if up then
            if Casts.Ended(index, channel, bar) then
                return
            end
            if not matched(record, channel, bar) then
                clear(index)
                record.start, record.bar, record.channel = time, bar, channel
                observed = observed + 1
            end
            record.seenLive, record.kickable = true, answer
        elseif record.start and not record.ended and not record.seenLive then
            record.kickable = answer
        end
    end
end

S.OnAllUnits("UNIT_SPELLCAST_START", start(false))
S.OnAllUnits("UNIT_SPELLCAST_CHANNEL_START", start(true))
S.OnAllUnits("UNIT_SPELLCAST_STOP", finish(false))
S.OnAllUnits("UNIT_SPELLCAST_CHANNEL_STOP", finish(true, true))
S.OnAllUnits("UNIT_SPELLCAST_INTERRUPTED", finish(nil, true))
S.OnAllUnits("UNIT_SPELLCAST_INTERRUPTIBLE", kickable(true))
S.OnAllUnits("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", kickable(false))

S.On("PLAYER_TARGET_CHANGED", nil, function()
    clear(1)
end)
S.On("PLAYER_FOCUS_CHANGED", nil, function()
    clear(2)
end)
local function plateChanged(_, _, unit)
    local index = unit and U.INDEX[unit]
    if index and index >= 3 and index <= 42 then
        clear(index)
        records[index].npcGuid, records[index].npcID = nil, nil
    end
end
S.On("NAME_PLATE_UNIT_ADDED", nil, plateChanged)
S.On("NAME_PLATE_UNIT_REMOVED", nil, plateChanged)
S.On("PLAYER_ENTERING_WORLD", nil, function()
    for index = 1, 42 do
        clear(index)
    end
end)

function Casts.Ended(index, channel, bar)
    local record = records[index]
    return bar and record.endedBar == bar and (record.endedChannel == nil or record.endedChannel == channel)
end

--- Observed cast data. A full client read wins. The event-only window has the same bound as the target cast model.
function Casts.Facts(index, now)
    local record = records[index]
    local api = I.api
    local up, channel, bar, interrupts, spell, startMS, endMS, hiddenSpell
    if api then
        up, channel, bar, interrupts, spell, startMS, endMS, hiddenSpell = readCast(api, U.TOKENS[index])
    end
    if up then
        if Casts.Ended(index, channel, bar) then
            return false
        end
        if matched(record, channel, bar) then
            if record.ended then
                return false
            end
            record.seenLive = true
            if interrupts == nil then
                interrupts = record.kickable
            end
            if spell == nil and not hiddenSpell then
                spell = record.spell
            end
            if not startMS then
                startMS, endMS = record.start * 1000, (record.start + I.TARGET_CAST_DEFAULT) * 1000
            end
        end
        return true, interrupts, channel, bar, spell, startMS, endMS
    end
    if
        record.start
        and not record.ended
        and not record.seenLive
        and now < record.start + I.TARGET_CAST_DEFAULT + I.CAST_GRACE
    then
        return true,
            record.kickable,
            record.channel,
            record.bar,
            record.spell,
            record.start * 1000,
            (record.start + I.TARGET_CAST_DEFAULT) * 1000
    end
    return up
end

function Casts.HasEvidence(index)
    local record = records[index]
    return record.start and not record.ended
end

function Casts.HasAliasEvidence(index)
    return observed > (Casts.HasEvidence(index) and 1 or 0)
end
