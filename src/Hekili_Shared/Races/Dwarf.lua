-- Hekili_Shared/Races/Dwarf.lua
-- `all` (Engine/Schema/Spec/All.lua) no longer registers this racial: the stock entry named below is what it used to register.
-- The Dwarf's Forever racial (DB2 build 70707), for every class: Stoneform (20594: -10% physical damage taken,
-- removes poison, disease and bleed effects and grants immunity to them for 8 s; 180 s, on the GCD), which replaces
-- `all`'s stock entry (120 s, off the GCD, its buff 65116 absent on Forever: the buff is 20594 itself). A class priority
-- decides whether to use it for a cleanse or physical mitigation; the spell itself requires no removable debuff.
-- A bleed carries no dispel type, so no `dispellable_bleed` aura can exist. Find Treasure, Mace Specialization and Big Game Hunter have no
-- rotation effect. No resource or cost modifier. Protection (wowsims.com) names it (its low-health line). Unknown for
-- any other race (Engine/Schema/Races.lua).

local race = Hekili:NewRace("Dwarf")

race:RegisterAbility("stoneform", {
    id = 20594,
    cast = 0,
    cooldown = 180,
    gcd = "spell",
    startsCombat = false,
    toggle = "defensives",

    handler = function()
        removeBuff("dispellable_poison")
        removeBuff("dispellable_disease")
        applyBuff("stoneform")
    end,
    -- The belief's now-state of the cast (event-facade spec §12a)
    now = function()
        removeBuff("dispellable_poison")
        removeBuff("dispellable_disease")
        applyBuff("stoneform")
    end,
})

race:RegisterAura("stoneform", {
    id = 20594,
    debuffImmunities = { "bleed", "disease" },
    duration = 8,
    max_stack = 1,
})
