-- Shared pull rules for the two damage packs. A dungeon target must already be fighting us or our party,
-- even when the player is in combat with a different pack. The simulator raid keeps its original ordering.
return function(recipe)
    local function guard(key, condition)
        local prior = recipe.guard[key]
        recipe.guard[key] = prior and "(" .. prior .. ")&" .. condition or condition
    end
    for _, key in ipairs({
        "bloodrage",
        "death_wish",
        "recklessness",
        "sweeping_strikes",
        "battle_stance",
        "berserker_stance",
        "cd_racials",
    }) do
        guard(key, "warrior_attack_target")
    end
    local melee = "warrior_attack_target&(!warrior_field|(target.within5&!target.outside5))"
    for _, key in ipairs({
        "sunder_armor",
        "overpower",
        "heroic_strike",
        "cleave",
        "spearing_strike",
        "execute",
        "rend",
    }) do
        guard(key, melee)
    end
    if recipe.spec == "arms" then
        guard("mortal_strike", melee)
        guard("slam", melee)
    else
        guard("bloodthirst", melee)
    end
    guard("whirlwind", "warrior_attack_target&(!warrior_field|(target.within8&!target.outside8))")
    guard("charge", "warrior_attack_target&warrior_charge_range")
    guard("intercept", "warrior_attack_target&warrior_intercept_range")
    recipe.levelingFirst = recipe.levelingFirst or {}
    table.insert(
        recipe.levelingFirst,
        1,
        "charge,use_off_gcd=1,if=combat=0&warrior_field&warrior_attack_target&warrior_charge_range"
    )
    table.insert(recipe.levelingFirst, 2, "auto_attack,use_off_gcd=1,if=combat=0&warrior_start_attack")
    -- Place the in-combat reminder after each pack's interrupt and emergency lines.
    table.insert(
        recipe.extra,
        { before = "demoralizing_shout", line = "auto_attack,use_off_gcd=1,if=combat>0&warrior_start_attack" }
    )
    return recipe
end
