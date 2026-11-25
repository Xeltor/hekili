-- Engine/Schema/Shared.lua
-- Shared content (shared-content spec §3). `Hekili:NewShared()` returns a registration object the content files
-- (Hekili_Shared/Shared/<File>.lua) use like a race pack's (Engine/Schema/Races.lua): RegisterAbility, RegisterAura,
-- RegisterResourceMod, RegisterCostMod, RegisterRegenMod, RegisterStateExpr and RegisterTtdLines. Always live, for
-- every class and race, into the shared `all` spec, whose entries the class's own win in the merge (Engine/Schema/Spec/Activation.lua) and a race pack's replace
-- (ns.applyRace).

local addon, ns = ...
local Hekili = _G[addon]
local Client = ns.Facade
local state = Hekili.State

local function all()
    return Hekili.Class.specs[0]
end

-- [class token] = pct: Shared:RegisterTtdLines' table, read by the time-to-die hints (Engine/Sim/Targets.lua). Held
-- here, so content registers without the simulation loaded.
ns.ttdLines = {}

local Shared = {}
Shared.__index = Shared

function Shared:RegisterAbility(key, def)
    all():RegisterAbility(key, def)
end

function Shared:RegisterAura(key, def)
    all():RegisterAura(key, def)
end

function Shared:RegisterStateExpr(key, func)
    all():RegisterStateExpr(key, func)
end

--- { max = pct }: every resource the loaded class registered gets pct more maximum (the race object's signature).
function Shared:RegisterResourceMod(def)
    if type(def.max) == "number" then
        -- ns.raceMods comes from Engine\Races.lua, which Hekili.toc loads before this file (line 51 before 55).
        local m = ns.raceMods.maxMods
        m[#m + 1] = { pct = def.max }
    end
end

function Shared:RegisterCostMod(def)
    ns.RegisterCostMod(def)
end

--- A regen entry on resource `def.resource` while the player's aura `def.aura` is up, for every class that has the
--- resource (the race object's RegisterRegenMod signature: Races.lua, read by Tracked.lua).
function Shared:RegisterRegenMod(def)
    if type(def.resource) == "string" and type(def.aura) == "string" then
        local m = ns.raceMods.regenMods
        m[#m + 1] = def
    end
end

--- { [class token] = pct }: each class's default execute line, no talents (lane B8, owner L1658): the core hints the
--- highest line present in the group to the time-to-die library (Engine/Sim/Targets.lua). A later call adds or replaces.
function Shared:RegisterTtdLines(def)
    for token, pct in pairs(def) do
        if type(token) == "string" and type(pct) == "number" then
            ns.ttdLines[token] = pct
        end
    end
end

local priorityInterrupts, prioritySpells
local encounterBossUnits = { "boss1", "boss2", "boss3", "boss4", "boss5" }

local function plain(value)
    if not Client.issecretvalue(value) then
        return value
    end
end

local function inInterruptRange(ability, unit)
    local inRange = plain(Client.C_Spell.IsSpellInRange(ability.id, unit))
    if inRange ~= nil then
        return inRange == true
    end
    local bounds = ability.priorityInterruptRange
    if type(bounds) ~= "table" then
        return false
    end
    local near, far = Client.LibRangeCheck:GetRange(unit)
    near, far = plain(near), plain(far)
    return type(far) == "number"
        and far <= bounds[2]
        and (bounds[1] == 0 or type(near) == "number" and near >= bounds[1])
end

local function isEncounterBoss(unit)
    if plain(Client.UnitLevel(unit)) == -1 or plain(Client.UnitClassification(unit)) == "worldboss" then
        return true
    end
    for i = 1, #encounterBossUnits do
        if plain(Client.UnitIsUnit(unit, encounterBossUnits[i])) == true then
            return true
        end
    end
    return false
end

local function priorityCandidate(unit, npcID, engaged, casting, interruptible, _, _, spellID, ability, activeOnly)
    local spells = priorityInterrupts[npcID]
    if engaged ~= true or not spells then
        return false
    end
    local priorityCast = casting == true and spellID ~= nil and spells[spellID] == true
    local stun = ability.priorityInterruptStun == true
    local needsKickable = not stun or ability.priorityInterruptNeedsKickable == true
    if activeOnly and not priorityCast then
        return false
    end
    if priorityCast and needsKickable and (interruptible == false or activeOnly and interruptible ~= true) then
        return false
    end
    if stun and isEncounterBoss(unit) or not inInterruptRange(ability, unit) then
        return false
    end
    local blocked = ability.funcs.priorityInterruptBlocked
    return not blocked or blocked(unit) ~= true
end

local function usePriorityInterrupt()
    local ability = state.action[state.this_action]
    if not ability or type(ability.priorityInterruptRange) ~= "table" then
        return true
    end
    local npcID, engaged, casting, _, _, _, spellID = Client.InterruptUnitFacts("target")
    if engaged ~= true or casting ~= true then
        return true
    end
    local spells = priorityInterrupts[npcID]
    -- An observed exact spell can identify a priority cast even before we have cataloged its caster.
    if spellID and prioritySpells[spellID] then
        return true
    end
    if spells and spellID then
        return false
    end
    if ability.priorityInterruptTargetOnly == true then
        return true
    end

    -- A hidden spell on a known caster may be the one we are waiting for. Yield it only to a
    -- reachable, confirmed priority cast. An unlisted target yields to any reachable known caster.
    return not Client.ForEachInterruptUnit(priorityCandidate, ability, spells ~= nil, priorityInterrupts)
end

local function reservePriorityInterrupt()
    local ability = state.action[state.this_action]
    if not state.toggle.interrupts or not ability or type(ability.priorityInterruptRange) ~= "table" then
        return false
    end
    return Client.ForEachInterruptUnit(priorityCandidate, ability, false, priorityInterrupts) == true
end

--- Shared PvE catalog: [NPC ID] = { [spell ID] = true }. Each action keeps its normal eligibility checks.
function Shared:RegisterPriorityInterrupts(allowKey, reserveKey, entries)
    priorityInterrupts = entries
    prioritySpells = {}
    for _, spells in pairs(entries) do
        for spellID in pairs(spells) do
            prioritySpells[spellID] = true
        end
    end
    self:RegisterStateExpr(allowKey, usePriorityInterrupt)
    self:RegisterStateExpr(reserveKey, reservePriorityInterrupt)
end

function Hekili:NewShared()
    return setmetatable({}, Shared)
end
