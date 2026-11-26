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
local L = ns.L -- top level: tools/locales.py reads a file's strings only with this line (the locales load first)

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

-- { key, value, option }: Shared:RegisterSetting's settings, registered on every spec of the class when its kit is
-- built (Spec/Kits.lua NewClass: the shared content loads before the class pack).
ns.sharedSettings = {}

--- (L1808) A spec setting every pack may read (a line the translator emits in every pack: the Healthstone's): kept
--- here and registered on each of the class's specs, as the kit's own RegisterSetting with no spec list.
function Shared:RegisterSetting(key, value, option)
    local s = ns.sharedSettings
    s[#s + 1] = { key, value, option }
end

--- (L1808, owner "Setting per line") A defensive line's player-health threshold setting's option (RegisterSetting's
--- `option`; spec:HealthOption and shared:HealthOption): a 1-100 slider, read by the line as `settings.<key>`; its
--- name and text name ability `ability` (the client's name, read when the options open; the key until it loads), and
--- `qualifier`, an ability key too, in parentheses after it when given (two sliders of one ability on a page: the
--- form each is for). A fresh table each call (load only). The registry is read when the options ask, not here.
--- The line fires once the health is under the setting: the reading comes in 1% steps, each read at its middle.
function ns.HealthOption(ability, qualifier)
    local function named(key)
        local a = Hekili.Class.abilities[key]
        return a and a.name or key
    end
    local function label()
        if qualifier then
            return string.format("%s (%s)", named(ability), named(qualifier))
        end
        return named(ability)
    end
    return {
        type = "range",
        min = 1,
        max = 100,
        step = 1,
        width = "full",
        name = function()
            return string.format(L["%s: once health is under (%%)"], label())
        end,
        desc = function()
            return string.format(
                L["The priority shows %s in the Defensives display once your health is under this percentage (Hekili reads it in 1%% steps), and only while Hekili can read your health in combat."],
                label()
            )
        end,
    }
end

--- ns.HealthOption, for a shared line's setting.
function Shared:HealthOption(ability, qualifier)
    return ns.HealthOption(ability, qualifier)
end

function Hekili:NewShared()
    return setmetatable({}, Shared)
end
