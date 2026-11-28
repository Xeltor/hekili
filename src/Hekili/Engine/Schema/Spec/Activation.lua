-- Engine/Schema/Spec/Activation.lua
-- The spec switch: Hekili:SpecializationChanged's merge of the current spec and spec 0, the character's spec and pack
-- choice (SettleSpecChoice, SetSpecChoice, ActivatePack) and the login and zone events. Loads last in the Spec slot, as
-- the events were once the end of Spec.lua.

local addon, ns = ...
local L = ns.L
local Facade = ns.Facade
local C_SpecializationInfo, C_Spell, GetTime, UnitAttackSpeed, UnitGUID, UnitLevel = Facade.C_SpecializationInfo, Facade.C_Spell, Facade.GetTime, Facade.UnitAttackSpeed, Facade.UnitGUID, Facade.UnitLevel
local Hekili = _G[ addon ]
local class = Hekili.Class
local state = Hekili.State
local GetResourceInfo, ResetDisabledGearAndSpells, RegisterEvent, getSpecializationKey = ns.GetResourceInfo, ns.ResetDisabledGearAndSpells, ns.RegisterEvent, ns.getSpecializationKey
local insert = table.insert
local wipe = table.wipe
local GetSpecialization = C_SpecializationInfo.GetSpecialization
local GetSpecializationInfo = C_SpecializationInfo.GetSpecializationInfo
local GetSpellInfo = C_Spell.GetSpellInfo
local GetRealmName, GetTalentInfoByID, UnitName = Facade.GetRealmName, Facade.GetTalentInfoByID, Facade.UnitName

-- A RegisterTalents entry's rank: the facade answers the C_Traits walk's rank as GetTalentInfoByID's 12th return.
local function talentRank( t )
    return ( select( 12, GetTalentInfoByID( t ) ) ) or 0
end

-- Forever characters may share a given name. Cache the player's plain GUID through identity restrictions.
-- A login can start with no realm or no readable player. Resolve it without running a spec rebuild every frame.
local playerGUID, legacyKey, partialKey, retryPending
local temporaryChoices = setmetatable( {}, { __mode = "k" } )
local function readIdentity()
    local previousGUID, previousKey, previousPartial = playerGUID, legacyKey, partialKey
    if not playerGUID then
        local guid = UnitGUID( "player" )
        if guid and guid ~= "" then
            playerGUID = guid
            _G.HekiliSpecPlayerGUID = guid
        else
            -- The client restores this character's own file even on a restricted /reload.
            local saved = rawget( _G, "HekiliSpecPlayerGUID" )
            if type( saved ) == "string" and saved ~= "" then playerGUID = saved end
        end
    end
    if not legacyKey then
        local name, realm = UnitName( "player" ), GetRealmName()
        if name and name ~= "" then
            partialKey = name .. "-"
            if not Facade.issecretvalue( realm ) and realm and realm ~= "" then legacyKey = partialKey .. realm end
        end
    end
    return playerGUID ~= previousGUID or legacyKey ~= previousKey or partialKey ~= previousPartial
end

local function needsIdentity()
    if not playerGUID then return true end
    if legacyKey then return false end
    -- With a GUID the realm matters only if there is a legacy choice left to recover.
    for key, value in pairs( Hekili.Engine.settings.specChoice ) do
        if type( key ) == "string" and key ~= playerGUID and not key:match( "^Player%-%d+%-%x+$" )
            and key:match( "^[^?%-]+%-" ) and key ~= partialKey
            and ( not partialKey or key:sub( 1, #partialKey ) == partialKey ) then
            if type( value ) == "string" then return true end
            if type( value ) == "table" and ( value[ 0 ] or value[ 1 ] or value[ 2 ] or value[ 3 ] ) then return true end
        end
    end
    return false
end

local function retryIdentity()
    retryPending = nil
    if readIdentity() then Hekili.PendingSpecializationChange = true end
    if needsIdentity() then
        retryPending = true
        C_Timer.After( 5, retryIdentity )
    end
end

-- Move explicit choices for this class. A partial Name- additionally requires the player's manual pack flag.
-- A remembered tree number alone cannot identify which namesake or even which class it belonged to.
local function legacySpec( key, requireManual )
    local spec = class.kit.specs[ key ]
    if not spec or not requireManual then return spec end
    local options = rawget( Hekili.Engine.settings.specs, spec.id )
    return type( options ) == "table" and options.packManual
end

local function migrateChoice( all, choice, from, requireManual )
    local old = from and all[ from ]
    if choice.legacy then return end
    if type( old ) == "string" and legacySpec( old, requireManual ) then
        if not ( choice[ 0 ] or choice[ 1 ] or choice[ 2 ] or choice[ 3 ] ) then
            choice.legacy = old -- converted on the talent walk, as for the original scalar setting
            all[ from ] = nil
        end
    elseif type( old ) == "table" then
        for tree, key in pairs( old ) do
            if type( tree ) == "number" and not choice[ tree ] and legacySpec( key, requireManual ) then
                choice[ tree ] = key
                if tree == old.last then choice.last = choice.last or tree end
                old[ tree ] = nil
            end
        end
    end
end

local function charChoice( tree, writable )
    local all = Hekili.Engine.settings.specChoice
    readIdentity()
    local waiting = needsIdentity()
    if not retryPending and waiting then
        retryPending = true
        C_Timer.After( 1, retryIdentity )
    end
    local choice = playerGUID and all[ playerGUID ] or temporaryChoices[ all ]
    if not choice then choice = {} end
    if playerGUID then
        all[ playerGUID ] = choice
        if temporaryChoices[ all ] then
            for k, v in pairs( temporaryChoices[ all ] ) do choice[ k ] = v end
            temporaryChoices[ all ] = nil
        end
        migrateChoice( all, choice, legacyKey )
        if not waiting then migrateChoice( all, choice, partialKey, true ) end
    else
        temporaryChoices[ all ] = choice
    end
    if choice.legacy then
        if not writable then return choice.legacy end
        local slot = tree or choice.last or 0
        choice[ slot ] = choice[ slot ] or choice.legacy
        choice.legacy = nil
    end
    return choice
end

function Hekili:GetActiveSpecOption( opt )
    if not self.currentSpecOpts then return end
    return self.currentSpecOpts[ opt ]
end


function Hekili:GetActivePack()
    return self:GetActiveSpecOption( "package" )
end


Hekili.SpecChangeHistory = {}

-- (selectors) The last settle's pick, selector and dominant tree (nil: no points or a tie, so the last pack holds),
-- the spec it settled on with points (nil until then: no notice at login; a read with no points
-- keeps it: PickSpec's `held`), and the notice due.
local picked, pickedBy, pickedTree, settledID, note

function Hekili:SpecializationChanged()
    local currentSpec = GetSpecialization()
    if not currentSpec then
        self.PendingSpecializationChange = true
        return
    end
    if currentSpec == 5 then currentSpec = 1 end -- no specialization: the first
    -- Forever's one pseudo-spec per class: its id keys the legacy profile; its primary stat stays the simulation's,
    -- its role only without a class pack's spec (below).
    local clientID, clientName, _, _, clientRole, clientStat = GetSpecializationInfo( currentSpec )

    if clientID == nil then
        self.PendingSpecializationChange = true
        return
    end

    -- The class pack's spec: the one chosen for the dominant tree, else its first (Engine/Schema/Selectors.lua). The ranks
    -- may be the last walk's here; SettleSpecChoice re-picks after this pass's walk.
    local kit = class.kit
    local tree, source
    local selector
    if kit then
        tree, source, _, selector = ns.PickSpec( kit, charChoice(), talentRank, UnitLevel( "player" ), Hekili.Engine.settings.specs, settledID and class.specs[ settledID ] )
    end
    local currentID = tree and tree.id or clientID

    self.PendingSpecializationChange = false
    self:ForceUpdate( "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" )

    insert( self.SpecChangeHistory, {
        spec = currentID,
        time = GetTime(),
        bt = debugstack()
    } )

    for k, _ in pairs( state.spec ) do
        state.spec[ k ] = nil
    end

    for key in pairs( GetResourceInfo() ) do
        state[ key ] = nil
        class[ key ] = nil
    end

    class.primaryResource = nil

    wipe( state.buff )
    wipe( state.debuff )
    wipe( state.cooldown )

    wipe( class.auras )
    wipe( class.abilities )
    wipe( class.hooks )
    wipe( class.talents )
    wipe( class.pvptalents )
    wipe( class.powers )
    wipe( class.gear )
    wipe( class.setBonuses )
    wipe( class.packs )
    wipe( class.resources )
    wipe( class.resourceAuras )

    wipe( class.pets )
    wipe( class.totemSlots )
    wipe( class.windows )
    wipe( class.reactions )

    local specs = { currentID, 0 }

    state.spec.id = currentID
    state.spec.name = tree and tree.name or clientName
    state.spec.key = tree and tree.key or getSpecializationKey( currentID )
    state.spec.clientID = clientID
    state.spec.kitID = kit and kit.id or currentID
    state.spec.source = source or "client"
    state.spec.selector = selector and selector.key
    state.spec.fillWindow = tree and tree.fillWindow -- state.ForecastWindow's pool (Kits.lua NewClass)

    for k in pairs( state.role ) do
        state.role[ k ] = false
    end

    -- the active spec's role as its pack declares it (L1715: the client's pseudo-spec answers DAMAGER for a tank tree);
    -- no spec from a class pack: the client's
    local role = tree and tree.role
    if role then
        state.role[ role ] = true
    elseif clientRole == "DAMAGER" then
        state.role.attack = true
    elseif clientRole == "TANK" then
        state.role.tank = true
    else
        state.role.healer = true
    end

    if clientStat == 1 then
        state.spec.primaryStat = "strength"
    elseif clientStat == 2 then
        state.spec.primaryStat = "agility"
    else
        state.spec.primaryStat = "intellect"
    end

    state.spec[ state.spec.key ] = true


    for key in pairs( GetResourceInfo() ) do
        state[ key ] = nil
        class[ key ] = nil
    end
    if rawget( state, "rune" ) then state.rune = nil; class.rune = nil; end

    for k in pairs( class.resourceAuras ) do
        class.resourceAuras[ k ] = nil
    end

    class.primaryResource = nil

    for k in pairs( class.stateTables ) do
        rawset( state, k, nil )
        class.stateTables[ k ] = nil
    end

    for k in pairs( class.stateFuncs ) do
        rawset( state, k, nil )
        class.stateFuncs[ k ] = nil
    end

    for k in pairs( class.stateExprs ) do
        class.stateExprs[ k ] = nil
    end

    self.currentSpec = nil
    self.currentSpecOpts = nil

    for i, specID in ipairs( specs ) do
        local spec = class.specs[ specID ]

        if spec then
            if specID == currentID then
                self.currentSpec = spec
                self.currentSpecOpts = rawget( Hekili.Engine.settings.specs, specID )
                state.settings.spec = self.currentSpecOpts

                state.spec.can_dual_cast = spec.can_dual_cast
                state.spec.dual_cast = spec.dual_cast

                for res, model in pairs( spec.resources ) do
                    class.resources[ res ] = model
                    state[ res ] = model.state
                end
                if rawget( state, "runes" ) then state.rune = state.runes end

                for k,v in pairs( spec.resourceAuras ) do
                    class.resourceAuras[ k ] = v
                end

                class.primaryResource = spec.primaryResource

                for talent, id in pairs( spec.talents ) do
                    class.talents[ talent ] = id
                end

                for talent, id in pairs( spec.pvptalents ) do
                    class.pvptalents[ talent ] = id
                end

                class.variables = spec.variables

                class.potionList.default = "|T967533:0|t |cFFFFD100Default|r"
            end

            if specID == currentID or specID == 0 then
                for event, hooks in pairs( spec.hooks ) do
                    for _, hook in ipairs( hooks ) do
                        class.hooks[ event ] = class.hooks[ event ] or {}
                        insert( class.hooks[ event ], hook )
                    end
                end
            end

            for res, model in pairs( spec.resources ) do
                if not class.resources[ res ] then
                    class.resources[ res ] = model
                    state[ res ] = model.state
                end
            end

            if rawget( state, "runes" ) then state.rune = state.runes end

            for k, v in pairs( spec.auras ) do
                if not class.auras[ k ] then class.auras[ k ] = v end
            end

            for k, v in pairs( spec.powers ) do
                if not class.powers[ k ] then class.powers[ k ] = v end
            end

            for k, v in pairs( spec.abilities ) do
                if not class.abilities[ k ] then class.abilities[ k ] = v end
            end

            for k, v in pairs( spec.gear ) do
                if not class.gear[ k ] then class.gear[ k ] = v end
            end

            for k, v in pairs( spec.setBonuses ) do
                if not class.setBonuses[ k ] then class.setBonuses[ k ] = v end
            end

            for k, v in pairs( spec.pets ) do
                if not class.pets[ k ] then class.pets[ k ] = v end
            end

            for k, v in pairs( spec.windows ) do
                if not class.windows[ k ] then class.windows[ k ] = v end
            end

            for k, v in pairs( spec.reactions ) do
                if not class.reactions[ k ] then class.reactions[ k ] = v end
            end

            for k, v in pairs( spec.totems ) do
                if not class.totems[ k ] then class.totems[ k ] = v end
            end

            for k, v in pairs( spec.totemSlots ) do
                if not class.totemSlots[ k ] then class.totemSlots[ k ] = v end
            end

            for k, v in pairs( spec.packs ) do
                if not class.packs[ k ] then class.packs[ k ] = v end
            end

            for name, func in pairs( spec.stateExprs ) do
                if not class.stateExprs[ name ] then
                    if rawget( state, name ) then state[ name ] = nil end
                    class.stateExprs[ name ] = func
                end
            end

            for name, func in pairs( spec.stateFuncs ) do
                if not class.stateFuncs[ name ] then
                    if rawget( state, name ) then
                        Hekili:Error( "Cannot RegisterStateFunc for an existing expression ( " .. spec.key .. " - " .. name .. " )." )
                    else
                        class.stateFuncs[ name ] = func
                        rawset( state, name, func )
                    end
                end
            end

            for name, t in pairs( spec.stateTables ) do
                if not class.stateTables[ name ] then
                    if rawget( state, name ) then
                        Hekili:Error( "Cannot RegisterStateTable for an existing expression ( " .. spec.key .. " - " .. name .. " )." )
                    else
                        class.stateTables[ name ] = t
                        rawset( state, name, t )
                    end
                end
            end

            if spec.id > 0 then
                local s = rawget( Hekili.Engine.settings.specs, spec.id )

                if s then
                    for k, v in pairs( spec.settings ) do
                        if s.settings[ v.name ] == nil then s.settings[ v.name ] = Hekili.Engine.SettingDefault( v ) end
                    end
                end
            end
        end
    end

    -- The race pack's abilities and auras win a key clash with the class's and `all`'s (Engine/Schema/Races.lua, spec §12b).
    ns.applyRace( class )

    for k in pairs( class.abilityList ) do
        local ability = class.abilities[ k ]

        if ability and ability.id > 0 then
            if not ability.texture or not ability.name then
                local data = GetSpellInfo( ability.id )

                if data and data.name and data.iconID then
                    ability.name = ability.name or data.name
                    class.abilityList[ k ] = ns.AbilityListLabel( ability, data.iconID )
                end
            else
                class.abilityList[ k ] = ns.AbilityListLabel( ability, ability.texture )
            end
        end
    end

    state.GUID = UnitGUID( "player" )
    state.player.unit = UnitGUID( "player" )

    ns.callHook( "specializationChanged" )

    -- the belief tracks what this spec registered (Engine/Schema/Tracked.lua); its talent walk runs here, before
    -- ns.updateTalents reads the ranks.
    -- the active pack's APL windows go into def before the Build (windows design v6 §9): never the previous pack's
    local specs = Hekili.Engine.settings.specs
    local active = specs and rawget( specs, state.spec.id or 0 )
    Hekili.Scripts:ApplyWindows( active and active.package )
    Hekili.Scripts:ApplyBands( active and active.package ) -- its harvested thresholds too (Scripts.lua)
    ns.BuildTracked()
    state:BuildWindows() -- the core's window tables (Engine/Sim/State.lua), from class.windows and the APL windows

    ns.updateTalents()
    ns.TtdHintsChanged() -- the time-to-die hints read the talent ranks too (Engine/Sim/Targets.lua)
    ns.TrackedStatics() -- the records' static values, under `state` with this spec's talent ranks (Tracked.lua)
    -- the core's gear read 1 s later (Engine/Sim/Events.lua): a set-bonus aura reads the belief's records, which this
    -- build cleared (gear-aware spec §7, Q2); the belief's own full read is at the same time (Sources/Gear.lua)
    ns.queueGearUpdate() -- Events.lua (before this file in the TOC) sets it at load
    if kit then self:SettleSpecChoice( clientID ) end
    ResetDisabledGearAndSpells()

    state.swings.mh_speed, state.swings.oh_speed = UnitAttackSpeed( "player" )

    ns.EngineFrame.activeThread = nil

    -- The UI and Options read the spec from the status record: publish the change now, not at the next update.
    local status = ns.Output.status
    if status.specID ~= state.spec.id then
        status.specID, status.specKey, status.specName = state.spec.id, state.spec.key, state.spec.name
        ns.Output.Publish( "status", 1 )
    end

    self:UpdateDisplayVisibility()
    self:UpdateDamageDetectionForCLEU()
    return true
end

local function notifyPick()
    if note then
        Hekili:Notify( note, 6 )
        note = nil
    end
end

-- The picked spec's pack as its selector (or none) asks (ns.SelectPack); true when it changed.
local function selectPack()
    local settings = Hekili.Engine.settings
    -- no points or a tie (a walk before the ranks arrive, a talent wipe): keep the last pack (review I2)
    if not picked or not pickedTree or picked.unsupported or not settings.specs then return false end
    local changed, former = ns.SelectPack( rawget( settings.specs, picked.id ), settings.packs, picked, pickedBy )
    if not changed then return false end
    ns.queueGearUpdate() -- the gear re-read rebuilds the usable items for the new pack, as a spec change does
    Hekili:ForceUpdate( "SPEC_PACKAGE_CHANGED" )
    if former then return true end -- the spec's default changed under a profile that never picked: no "picked from your talents"
    local label = Hekili.Engine.Registry.PackLabel
    note = string.format( L["%s: the |cFFFFD100%s|r priority, picked from your talents."], picked.name, label( settings.specs[ picked.id ].package ) )
    C_Timer.After( 5, notifyPick )
    return true
end
ns.SelectPackForPick = selectPack -- RestoreDefaults: again once the built-in priorities exist

--- (per-spec plan) After a spec change's talent walk: share keys of imported packs resolved, the dominant tree
--- remembered (a talent swap to another tree activates that tree's spec), the selectors' pack set (Selectors.lua), and
--- one more pass when this pass's pick (made on the last walk's ranks) was not the settled one.
function Hekili:SettleSpecChoice( clientID )
    local kit, settings = class.kit, Hekili.Engine.settings
    local tree = ns.DominantTree( ns.TreePoints( kit.talents, talentRank ) )
    local choice = charChoice( tree, true )
    if tree then choice.last = tree end
    local pick, source, _, sel = ns.PickSpec( kit, choice, talentRank, UnitLevel( "player" ), settings.specs, settledID and class.specs[ settledID ] )
    if ns.MigrateTrees( settings.specs, settings.packs, settings.specMigrated, kit, clientID, pick ) then
        self:SettingsChanged() -- the migrated settings reach the belief's plain copy (Engine/Schema/Tracked.lua)
    end
    ns.ResolvePackSpecs( settings.packs, class.specByShare )
    picked, pickedBy, pickedTree = pick, sel, tree
    local packChanged = selectPack()
    if pick.id ~= state.spec.id then
        self.PendingSpecializationChange = true
        return
    end
    -- settled: the pick's source is this walk's (the pass's own pick may have been on the last walk's ranks)
    state.spec.source, state.spec.selector = source, sel and sel.key
    -- a selector's spec switch (not the first settle: a login) gets the notice a pack change has not given, on this
    -- pass or the last one (its notice, still pending, names the spec too)
    if source == "selector" and not packChanged and not note and settledID and settledID ~= pick.id then
        note = string.format( L["%s, picked from your talents."], pick.name )
        C_Timer.After( 5, notifyPick )
    end
    if tree then settledID = pick.id end
end

--- (selectors) Activates a pack, the player's: `name` (nil: the one in place) becomes spec `specID`'s package, marked
--- the player's (`packManual`: no selector replaces it), and the pack's spec this character's spec for the current
--- dominant tree (activation is at the pack level, owner 2026-11-08: a spec is active through one of its packs).
--- The spec page's Priority, a pack's Active toggle, /hekili priority and SetSpecChoice call it. Returns true when
--- it activated the pack (false: no readable profile for the spec).
function Hekili:ActivatePack( specID, name )
    local sp = Hekili.Engine.settings.specs[ specID ]
    if type( sp ) ~= "table" then return false end
    if name ~= nil then sp.package = name end
    sp.packManual, sp.packAuto = true, nil
    local kit, s = class.kit, class.specs[ specID ]
    if not kit or not s or rawget( s, "kit" ) ~= kit then return true end -- a spec outside the class kit
    local tree = ns.DominantTree( ns.TreePoints( kit.talents, talentRank ) )
    local choice = charChoice( tree, true )
    choice[ tree or choice.last or 0 ] = s.key
    self.PendingSpecializationChange = true
    return true
end

--- Activates a spec for this character's current dominant talent tree through its pack in place (ActivatePack: kept
--- until another pack is activated on that tree) and switches to it at the next frame: `key` is a spec key, or a
--- prefix of one spec's key or name (case-insensitive). Returns the spec, or nil when no spec or more than one matches.
function Hekili:SetSpecChoice( key )
    local kit = class.kit
    if not kit or type( key ) ~= "string" then return end
    key = key:lower()
    local s = kit.specs[ key ]
    if not s then
        for _, t in ipairs( kit.trees ) do
            if t.key:sub( 1, #key ) == key or t.name:lower():sub( 1, #key ) == key then
                if s then return end -- ambiguous
                s = t
            end
        end
    end
    if not s then return end
    if not self:ActivatePack( s.id ) then return end
    return s
end


do
    local SpellDisableEvents = {
        CHALLENGE_MODE_START = 1,
        CHALLENGE_MODE_RESET = 1,
        CHALLENGE_MODE_COMPLETED = 1,
        PLAYER_ALIVE = 1,
        ZONE_CHANGED_NEW_AREA = 1,
        QUEST_SESSION_CREATED = 1,
        QUEST_SESSION_DESTROYED = 1,
        QUEST_SESSION_ENABLED_STATE_CHANGED = 1,
        QUEST_SESSION_JOINED = 1,
        QUEST_SESSION_LEFT = 1
    }

    local function CheckSpellsAndGear()
        ResetDisabledGearAndSpells()
        ns.updateGear()
    end

    for k in pairs( SpellDisableEvents ) do
        RegisterEvent( k, function( event )
            C_Timer.After( 1, CheckSpellsAndGear )
        end )
    end
end
