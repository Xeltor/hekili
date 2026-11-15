-- Hekili_Shared/Races/WindshaperSkyborne.lua
-- Windshaper Skyborne (Horde, ChrRaces 96) can be Rogues. Skysight is a 0.5 s cast, on the GCD, with a 120 s
-- cooldown (retained Forever DB2 research and wowsims e5a9cd2a2dfc, sim/core/racials.go). It grants Elemental Blessing
-- for 15 s: +15% movement speed, or +30% while Charged (official 26 Oct development notes). The movement amount is
-- not simulated, and no convergence/Charged state is inferred. See docs/research/2026-11-14-rogue-racials.md.
-- The UnitRace token is unconfirmed; the race ID also matches. Other races receive an unknown ability.

local race = Hekili:NewRace("WindshaperSkyborne", 96)

race:RegisterAbility("skysight", {
    id = 1259686,
    cast = 0.5,
    cooldown = 120,
    gcd = "spell",
    startsCombat = false,
    toggle = "cooldowns",

    usable = function()
        if moving then
            return false, "can't cast Skysight while moving"
        end
        return true
    end,

    handler = function()
        applyBuff("elemental_blessing")
    end,
    now = function()
        applyBuff("elemental_blessing")
    end,
})

race:RegisterAura("elemental_blessing", {
    id = 1259688,
    duration = 15,
    max_stack = 1,
})
