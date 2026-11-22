-- Class packs share an event-driven view of the control effects that affect their abilities.
local Client = Hekili.Client
local class = Client.UnitClassBase("player")
if class ~= "ROGUE" and class ~= "WARLOCK" and class ~= "PALADIN" then
    return
end

local shared = Hekili:NewShared()
local melee = class == "ROGUE"
local prefix = class:lower() .. "_"
local max, min, HUGE = math.max, math.min, math.huge

local function plain(value)
    if not Client.issecretvalue(value) then
        return value
    end
end

-- Loss-of-control rows are plain on Forever, but reading each row creates a client table. Read them only when the
-- client announces a change (or when this class loads), and keep finite scalar expiries for prediction.
local lossOfControl = Client.C_LossOfControl
local control = { stun = 0, forsaken = 0, movement = 0, incapacitated = 0, silence = 0 }
local controlGroup = {
    STUN = "stun",
    STUN_MECHANIC = "stun",
    FEAR = "forsaken",
    FEAR_MECHANIC = "forsaken",
    CHARM = "forsaken",
    SLEEP = "forsaken",
    ROOT = "movement",
    SNARE = "movement",
    CONFUSE = "incapacitated",
    PACIFY = melee and "incapacitated" or nil,
    PACIFYSILENCE = "incapacitated",
    DISARM = melee and "incapacitated" or nil,
    SILENCE = not melee and "silence" or nil,
    POSSESS = "incapacitated",
}
local function refreshControl()
    control.stun, control.forsaken, control.movement, control.incapacitated = 0, 0, 0, 0
    control.silence = 0
    if not lossOfControl then
        return
    end
    local count = plain(lossOfControl.GetActiveLossOfControlDataCount())
    local time = plain(Client.GetTime())
    if type(count) ~= "number" or type(time) ~= "number" or count < 0 or count >= HUGE or time >= HUGE then
        return
    end
    for i = 1, min(32, count) do
        local row = plain(lossOfControl.GetActiveLossOfControlData(i))
        if type(row) == "table" then
            local kind = plain(row.locType)
            local group = type(kind) == "string" and controlGroup[kind]
            if class == "PALADIN" and kind == "SCHOOL_INTERRUPT" then
                local schools = plain(row.lockoutSchool)
                if type(schools) == "number" and math.floor(schools / Hekili.SCHOOL.holy) % 2 == 1 then
                    group = "silence"
                end
            end
            if group then
                local start, duration, remains = plain(row.startTime), plain(row.duration), plain(row.timeRemaining)
                local expires
                if type(start) == "number" and type(duration) == "number" and duration > 0 then
                    expires = start + duration
                elseif type(remains) == "number" and remains > 0 then
                    expires = time + remains
                end
                if expires and expires > time and expires < HUGE then
                    control[group] = max(control[group], expires)
                end
            end
        end
    end
end
local frame = Client.CreateFrame("Frame")
frame:SetScript("OnEvent", refreshControl)
frame:RegisterEvent("LOSS_OF_CONTROL_ADDED")
frame:RegisterEvent("LOSS_OF_CONTROL_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
refreshControl()

if class ~= "PALADIN" then
    shared:RegisterStateExpr(prefix .. "stunned", function()
        return control.stun > query_time
    end)
    shared:RegisterStateExpr(prefix .. "forsaken_control", function()
        return control.forsaken > query_time
    end)
end
shared:RegisterStateExpr(prefix .. "movement_control", function()
    return control.movement > query_time
end)
shared:RegisterStateExpr(prefix .. "incapacitated", function()
    return max(control.stun, control.forsaken, control.incapacitated, control.silence) > query_time
end)

if class == "WARLOCK" then
    shared:RegisterStateExpr("warlock_hard_controlled", function()
        return max(control.stun, control.forsaken, control.incapacitated) > query_time
    end)
end
