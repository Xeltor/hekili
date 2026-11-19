-- The field priorities share their learned-spell and recovery rules. The translated lists still own sustained raids.
local function addPvE(recipe)
    local name = recipe.name
    local destruction = recipe.spec == "destruction"
    local demonology = recipe.spec == "demonology"
    local field = "warlock_contextual&warlock_engaged"
    local short = field .. "&warlock_short_pull"
    local durable = field .. "&!warlock_short_pull"
    local fighting = "combat>0&warlock_pve_target&warlock_engaged"
    local finishWithDirectDamage = "level<10&warlock_target_low"

    recipe.notes = {
        "Leveling, outdoor pulls, and dungeons use learned spells, pet care, and health-aware mana recovery.",
        "Ordinary pulls favor a small number of DoTs, while durable targets get sustained debuff and spell priorities.",
        "Raid damage follows the pinned WoWSims priority.",
    }

    local priority = {
        "healthstone,use_off_gcd=1,display_below=30,if=combat>0&warlock_pve_context",
        "healing_potion,use_off_gcd=1,display_below=40,if=combat>0&warlock_pve_context",
        "health_funnel,if=warlock_funnel_safe",
        "life_tap,if=warlock_can_prepare&warlock_life_tap_safe&mana.hi<0.65*mana.max",
        "summon_voidwalker,if=warlock_can_summon&warlock_outdoors&solo",
        "summon_imp,if=warlock_can_summon",
        "demon_armor,if=warlock_can_prepare&buff.demon_armor.down",
        "demon_skin,if=warlock_can_prepare&!action.demon_armor.known&buff.demon_skin.down&buff.demon_armor.down",
        "death_coil,if=" .. fighting .. "&toggle.defensives&warlock_health_low",
        "drain_life,if=" .. fighting .. "&toggle.defensives&warlock_health_low&warlock_drain_life_in_range",
        "shadow_bolt,focus=1,if=" .. field .. "&buff.shadow_trance.up",
    }
    recipe.levelingFirst = priority

    local function add(action, condition)
        priority[#priority + 1] = action .. ",if=" .. condition
    end

    -- The assigned group curse is useful on durable enemies. Keep the player's choice and use a Bane as well.
    for _, curse in ipairs({ "elements", "recklessness", "weakness" }) do
        local action = "curse_of_" .. (curse == "elements" and "the_elements" or curse)
        add(action .. ",focus=2", durable .. "&settings.assigned_curse='" .. curse .. "'&debuff." .. action .. ".down")
    end

    add("rain_of_fire", field .. "&combat>0&warlock_aoe")
    if destruction then
        add(
            "bane_of_havoc,use_off_gcd=1,other_target=1",
            durable .. "&combat>0&warlock_cleave&!(active_dot.bane_of_havoc>0)"
        )
    end
    if demonology then
        add(
            "searing_pain,focus=2",
            field
                .. "&warlock_pet_on_target&talent.demonic_brand.enabled&debuff.demonic_brand.remains<2.5&!action.searing_pain.executing"
        )
        if name == "Demonology" then
            add("soul_fire,focus=1", field .. "&buff.decimation.up&!action.soul_fire.executing")
        else
            add(
                "shadow_bolt,focus=1",
                field
                    .. "&talent.improved_shadow_bolt.enabled&buff.revelation.up&debuff.shadow_vulnerability.down&!action.shadow_bolt.executing"
            )
        end
    end

    if destruction then
        add(
            "conflagrate",
            field
                .. "&debuff.immolate.up&(warlock_short_pull|talent.shadow_and_flame.rank=5|debuff.immolate.remains<=3)"
        )
        add(
            "immolate,focus=2",
            field
                .. "&debuff.immolate.remains<=action.immolate.cast&!action.immolate.executing&!("
                .. finishWithDirectDamage
                .. ")"
        )
    end

    add(
        "corruption,focus=2",
        durable .. "&debuff.corruption.remains<=action.corruption.cast&!action.corruption.executing"
    )
    add("bane_of_agony,focus=2", durable .. "&debuff.bane_of_agony.down&debuff.bane_of_doom.down")
    if recipe.spec == "affliction" then
        add("siphon_life,focus=2", durable .. "&debuff.siphon_life.down")
    end
    if not destruction then
        add("immolate,focus=2", durable .. "&debuff.immolate.remains<=action.immolate.cast&!action.immolate.executing")
        -- Before talents, rank-one Immolate and Corruption both pay off on healthy starter mobs.
        add(
            "immolate,focus=2",
            short
                .. "&(level<10|!action.corruption.known)&!warlock_target_low&debuff.immolate.down&!action.immolate.executing"
        )
    end
    local shortCorruption = destruction and "level<10&!warlock_target_low" or "!(" .. finishWithDirectDamage .. ")"
    add("corruption,focus=2", short .. "&debuff.corruption.down&!action.corruption.executing&" .. shortCorruption)

    -- The low-health cue requires evidence. When health is hidden, let established DoTs and a tanking pet finish.
    add(
        "drain_soul",
        short
            .. "&combat>0&warlock_outdoors&solo&warlock_shard_count<2&!warlock_wanding&!warlock_health_low"
            .. "&(warlock_shard_window|warlock_shard_target&warlock_pet_tanking&(debuff.corruption.up|debuff.immolate.up))"
    )
    local wand = destruction and "(warlock_short_pull&(level<20|mana.pct_lo<55))" or "warlock_short_pull"
    add("shoot,use_off_gcd=1", field .. "&" .. wand)
    local filler = field .. "&!(warlock_wanding&" .. wand .. ")"
    add("life_tap", filler .. "&combat>0&warlock_life_tap_safe&mana.hi<0.30*mana.max")
    if name == "Affliction" then
        add("wrack", filler)
    elseif name == "Demonology" then
        add("searing_pain", filler .. "&warlock_pet_on_target&talent.demonic_brand.enabled")
    elseif destruction then
        add("shadowburn", durable .. "&talent.shadow_and_flame.rank=5&warlock_shard_count>=2")
        add("incinerate", filler)
    end
    add("shadow_bolt", filler)
    add("shoot,use_off_gcd=1", field)
    add("auto_attack,use_off_gcd=1", field)

    -- Both an idle dungeon target and an exhausted field rotation must stay out of the raid damage list.
    local baseline = "!warlock_contextual"
    local guard = recipe.guard or {}
    recipe.guard = guard
    for _, action in ipairs({
        "bane_of_doom",
        "berserking",
        "demonic_rune",
        "life_tap",
        "major_mana_potion",
        "use_items",
    }) do
        guard[action] = baseline
    end
    local actions = {
        Affliction = {
            "cooldowns",
            "death_coil",
            "multi_target_dot_logic",
            "shadow_bolt",
            "single_multi_target_curse_logic",
            "single_target_dot_logic",
            "wrack",
        },
        Demonology = {
            "cooldowns",
            "death_coil",
            "hellfire",
            "immolate",
            "multi_target_dot_logic",
            "searing_pain",
            "single_multi_target_curse_logic",
            "single_target_dot_logic",
            "soul_fire",
        },
        Destruction = {
            "bane_of_havoc",
            "conflagrate",
            "cooldowns",
            "death_coil",
            "hellfire",
            "immolate",
            "incinerate",
            "multi_target_dot_logic",
            "searing_pain",
            "shadowburn",
            "single_multi_target_curse_logic",
            "single_target_dot_logic",
            "soul_fire",
        },
        ["Shadow Brand"] = {
            "cooldowns",
            "corruption",
            "death_coil",
            "hellfire",
            "multi_target_dot_logic",
            "searing_pain",
            "shadow_bolt",
            "single_multi_target_curse_logic",
            "single_target_dot_logic",
        },
        ["SM Ruin"] = {
            "blood_fury",
            "corruption",
            "curse_of_recklessness",
            "curse_of_the_elements",
            "curse_of_weakness",
            "eureka",
            "shadow_bolt",
        },
    }
    for _, action in ipairs(actions[name]) do
        guard[action] = guard[action] and "(" .. guard[action] .. ")&" .. baseline or baseline
    end
    local extra = recipe.extra or {}
    recipe.extra = extra
    for _, entry in ipairs(extra) do
        local action, condition = entry.line:match("^(.-),if=(.+)$")
        entry.line = action and (action .. ",if=(" .. condition .. ")&" .. baseline)
            or (entry.line .. ",if=" .. baseline)
    end
    return recipe
end

return addPvE
