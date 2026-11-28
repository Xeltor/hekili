-- The field priorities share their learned-spell and recovery rules. The translated lists still own sustained raids.
local function addPvE(recipe)
    local name = recipe.name
    local destruction = recipe.spec == "destruction"
    local demonology = recipe.spec == "demonology"
    local field = "warlock_contextual&warlock_engaged"
    local short = field .. "&warlock_short_pull"
    local durable = field .. "&!warlock_short_pull"
    local dungeonTrash = field .. "&warlock_dungeon_trash"
    local dotBudget = name == "Affliction" and "&warlock_dungeon_dot_budget" or ""
    local leech = "combat>0&warlock_defensive_target&toggle.defensives&warlock_spell_in_range"
    local itemRecovery = "combat>0&warlock_alive&!warlock_hard_controlled"
    recipe.settings = recipe.settings or {}
    recipe.settings.death_coil_defensive_health = { default = 35, desc = "player health threshold, percent" }
    local finishWithDirectDamage = "warlock_short_pull&warlock_target_low"

    recipe.notes = {
        "Leveling, outdoor pulls, and dungeons use learned spells, pet care, and health-aware mana recovery.",
        "Ordinary pulls favor a small number of DoTs, while durable targets get sustained debuff and spell priorities.",
        "Raid damage follows the pinned WoWSims priority. Player combat uses learned pressure and control on the selected opponent.",
    }

    recipe.levelingFirst = {
        -- A ready instant self-heal also ends the priority scan. Record the demon's rescue before it.
        "health_funnel,display_pet_below=30,if=combat>0&warlock_funnel_available",
        "will_to_survive,if=warlock_alive&warlock_stunned",
        "will_of_the_forsaken,if=warlock_alive&warlock_forsaken_control",
        "escape_artist,if=warlock_alive&warlock_movement_control&!warlock_hard_controlled&buff.escape_artist.down",
        "shatter_curse,if=warlock_alive&!warlock_hard_controlled&buff.dispellable_curse.up&buff.shatter_curse.down",
        "healthstone,use_off_gcd=1,if=health.known&health.pct<=settings.healthstone_health&" .. itemRecovery,
        "healthstone,use_off_gcd=1,display_below=30,if=!health.known&" .. itemRecovery,
        "healing_potion,use_off_gcd=1,if=health.known&health.pct<=settings.healing_potion_health&" .. itemRecovery,
        "healing_potion,use_off_gcd=1,display_below=40,if=!health.known&" .. itemRecovery,
        "rapid_regeneration,use_off_gcd=1,display_below=60,if=warlock_can_recover&buff.rapid_regeneration.down",
        "cannibalize,if=warlock_cannibalize_corpse&buff.cannibalize.down&mana.hi<0.65*mana.max",
        "cannibalize,display_below=65,if=warlock_cannibalize_corpse&buff.cannibalize.down",
        "death_coil_defensive,if=health.known&health.pct<=settings.death_coil_defensive_health&" .. leech,
        "death_coil_defensive,display_below=40,if=!health.known&" .. leech,
        "death_coil_defensive,display_below=65,if=" .. leech .. "&(moving|warlock_pvp_pressure)",
        "shadow_ward,if=combat>0&warlock_alive&warlock_recent_shadow_damage&buff.shadow_ward.down",
        "soul_link,if=warlock_alive&(combat>0|warlock_can_prepare)&buff.soul_link.down",
        "drain_life,display_below=65,if=" .. leech .. "&warlock_drain_healing_display&!moving",
        "death_coil_defensive,display_below=65,if=" .. leech,
        "health_funnel,display_pet_below=55,if=combat=0&warlock_funnel_available",
        "life_tap,if=warlock_can_prepare&warlock_life_tap_safe&mana.hi<0.65*mana.max",
        "summon_felhunter,if=warlock_can_summon&warlock_pvp_instance&buff.fel_stamina.down",
        "summon_voidwalker,if=warlock_can_summon&warlock_outdoors&solo&buff.fel_energy.down",
        "summon_imp,if=warlock_can_summon&buff.burning_shadow.down",
        "summon_succubus,if=warlock_can_summon&talent.demonic_pact.enabled&buff.burning_shadow.up",
        "summon_incubus,if=warlock_can_summon&talent.demonic_pact.enabled&buff.burning_shadow.up",
        "create_healthstone,if=warlock_can_prepare&warlock_needs_healthstone&!action.create_healthstone.executing",
        "demon_armor,if=warlock_can_prepare&buff.demon_armor.down",
        "demon_skin,if=warlock_can_prepare&!action.demon_armor.known&buff.demon_skin.down&(!action.demon_armor.known|buff.demon_armor.down)",
    }
    local priority = {
        "shadow_bolt,focus=1,if=" .. field .. "&buff.shadow_trance.up&warlock_spell_in_range" .. dotBudget,
    }
    -- Every damage line below is for the field or an engaged player. Check that context before walking it.
    recipe.levelingFirst[#recipe.levelingFirst + 1] = {
        name = "field",
        when = "warlock_contextual|warlock_pvp_target",
        lines = priority,
    }

    local function add(action, condition)
        priority[#priority + 1] = action .. ",if=" .. condition
    end

    local function addTarget(action, condition)
        add(action, condition .. "&warlock_spell_in_range")
    end

    -- Corruption can become instant with Improved Corruption; Shadow Trance does the same for Shadow Bolt.
    local function addCast(action, condition)
        local spell = action:match("^[^,]+")
        addTarget(action, condition .. "&(!moving|action." .. spell .. ".cast=0)")
    end

    -- Keep a chosen shard finish ahead of routine DoTs. The client can render the initial cue from target health.
    local shardFinish = field
        .. "&combat>0&!moving&!boss&!target.is_boss&warlock_shard_count<2&!warlock_health_low&!action.drain_soul.executing"
        .. "&warlock_shard_target"
    add("drain_soul", shardFinish .. "&warlock_continue_drain_soul")
    add("drain_soul,display_target_below=25", shardFinish)

    if name == "Affliction" then
        -- On a dungeon pack, cover the tank's engaged mobs before spending on additional DoTs or AoE.
        local pack = dungeonTrash .. "&warlock_dungeon_corruption_targets>1"
        local fresh = "&debuff.corruption.down&!action.corruption.executing"
        addCast("corruption,focus=2", pack .. fresh)
        addCast(
            "corruption,cycle_targets=1,focus=2",
            pack .. "&active_dot.corruption<warlock_dungeon_corruption_targets" .. fresh
        )
    end

    -- Blood Fury can boost the spells applied during setup.
    local burst = "combat>0&warlock_racial_cast_window&(warlock_pvp_pressure|("
        .. field
        .. "&(!warlock_short_pull|warlock_cleave)&!warlock_target_low))"
    add("blood_fury,use_off_gcd=1", burst .. "&buff.blood_fury.down")

    -- The Gnome's Warlock mask includes Rain of Fire and Immolate, and excludes Incinerate.
    local eureka = burst .. "&buff.eureka.down"
    add("eureka,use_off_gcd=1", eureka .. "&warlock_eureka_setup")

    -- The assigned group curse is useful on durable enemies. Keep the player's choice and use a Bane as well.
    for _, curse in ipairs({ "elements", "recklessness", "weakness" }) do
        local action = "curse_of_" .. (curse == "elements" and "the_elements" or curse)
        addTarget(
            action .. ",focus=2",
            durable .. "&settings.assigned_curse='" .. curse .. "'&debuff." .. action .. ".down" .. dotBudget
        )
    end

    add("rain_of_fire", field .. "&combat>0&warlock_aoe&!moving" .. dotBudget)
    if destruction then
        add(
            "bane_of_havoc,use_off_gcd=1,other_target=1",
            durable .. "&combat>0&warlock_cleave&!(active_dot.bane_of_havoc>0)"
        )
    end
    if demonology then
        addCast(
            "searing_pain,focus=2",
            field
                .. "&warlock_pet_on_target&talent.demonic_brand.enabled&debuff.demonic_brand.remains<2.5&!action.searing_pain.executing"
        )
        if name == "Demonology" then
            addCast("soul_fire,focus=1", field .. "&buff.decimation.up&!action.soul_fire.executing")
        else
            addCast(
                "shadow_bolt,focus=1",
                field
                    .. "&talent.improved_shadow_bolt.enabled&buff.revelation.up&debuff.shadow_vulnerability.down&!action.shadow_bolt.executing"
            )
        end
    end

    if destruction then
        -- The class kit requires our Immolate for Conflagrate. Avoid consuming it while profitable ticks remain.
        addTarget(
            "conflagrate",
            field
                .. "&(talent.shadow_and_flame.rank=5|(action.immolate.known&debuff.immolate.remains<=3)|("
                .. finishWithDirectDamage
                .. "))"
        )
        addCast(
            "immolate,focus=2",
            field
                .. "&debuff.immolate.remains<=action.immolate.cast&!action.immolate.executing&!("
                .. finishWithDirectDamage
                .. ")"
        )
    end

    -- Any leveling build can learn Shadowburn. Keep a shard for a summon unless Shadow and Flame refunds it.
    addTarget(
        "shadowburn",
        field .. "&combat>0&warlock_target_low&(warlock_shard_count>=2|talent.shadow_and_flame.rank=5)"
    )
    addCast(
        "corruption,focus=2",
        durable .. "&debuff.corruption.remains<=action.corruption.cast&!action.corruption.executing"
    )
    local noBane = "&(!action.bane_of_agony.known|debuff.bane_of_agony.down)&(!action.bane_of_doom.known|debuff.bane_of_doom.down)"
        .. "&(!action.bane_of_havoc.known|debuff.bane_of_havoc.down)"
    local needsAgony = durable .. noBane
    add(
        "amplify_curse,use_off_gcd=1",
        needsAgony
            .. "&combat>0&warlock_can_amplify_agony&(!action.bane_of_agony.known|action.bane_of_agony.ready)&buff.amplify_curse.down"
    )
    addTarget("bane_of_agony,focus=2", needsAgony .. dotBudget)
    if recipe.spec == "affliction" then
        addTarget("siphon_life,focus=2", durable .. "&debuff.siphon_life.down" .. dotBudget)
    end
    if not destruction then
        addCast(
            "immolate,focus=2",
            durable .. "&debuff.immolate.remains<=action.immolate.cast&!action.immolate.executing" .. dotBudget
        )
        -- Before talents, rank-one Immolate and Corruption both pay off on healthy starter mobs.
        addCast(
            "immolate,focus=2",
            short
                .. "&(level<10|!action.corruption.known)&!warlock_target_low&debuff.immolate.down&!action.immolate.executing"
        )
    end
    -- Other field rotations keep their two-target cleave. An unknown active_dot count suppresses the cue.
    local cleave = name == "Affliction" and durable .. "&!warlock_dungeon_trash" or durable
    add(
        "corruption,cycle_targets=1,max_cycle_targets=2,focus=2",
        cleave
            .. "&combat>0&true_active_enemies=2&warlock_cleave&active_dot.corruption=1&debuff.corruption.down&!action.corruption.executing"
            .. "&(!moving|action.corruption.cast=0)"
    )
    local shortCorruption = short .. "&!warlock_target_low&debuff.corruption.down&!action.corruption.executing"
    if destruction then
        shortCorruption = shortCorruption .. "&(level<10|moving&action.corruption.cast=0)"
    end
    addCast("corruption,focus=2", shortCorruption)
    -- Save the short direct-cast buffs until field DoTs are in place.
    add("berserking,use_off_gcd=1", burst .. "&buff.berserking.down")
    local directFiller = destruction and "action.shadow_bolt.known&!action.incinerate.known"
        or "action.shadow_bolt.known"
    add("eureka,use_off_gcd=1", eureka .. "&" .. directFiller)
    if destruction then
        addTarget("shadowburn", field .. "&combat>0&talent.shadow_and_flame.rank=5")
    end
    -- Agony also fills a moving GCD when Corruption needs a cast.
    local shortAgony = name == "Affliction" and "(moving|warlock_leveling_agony)" or "moving"
    addTarget("bane_of_agony,focus=2", short .. "&" .. shortAgony .. "&!warlock_target_low" .. noBane .. dotBudget)

    -- Ordinary outdoor fights can trade Drain Life's healing for later Life Taps. Keep the opener,
    -- a dying target, and the dungeon and raid priorities on their existing paths.
    local outdoorCombat = "warlock_outdoors&warlock_short_pull&combat>0&warlock_defensive_target"
    local casterReady = ({
        Affliction = "action.wrack.known",
        Demonology = "action.searing_pain.known&talent.demonic_brand.enabled&warlock_pet_on_target",
        ["Shadow Brand"] = "talent.improved_shadow_bolt.enabled",
        ["SM Ruin"] = "talent.ruin.enabled",
        Destruction = "level>=20",
    })[name]
    add(
        "life_tap",
        outdoorCombat
            .. "&toggle.defensives&!moving&!warlock_target_low&mana.hi<0.30*mana.max&warlock_can_tap_for_drain"
            .. "&!prev_gcd.1.life_tap&!warlock_restorative_filler&warlock_life_tap_safe"
    )
    local drainWhen = name == "Demonology" and ""
        or "&(warlock_restorative_filler|mana.pct_lo<55|!(" .. casterReady .. "))"
    local drain = outdoorCombat
        .. "&warlock_damage_display&toggle.defensives&!moving&!warlock_health_low&!warlock_target_low&warlock_leveling_drain&mana.lo>=action.drain_life.cost"
        .. drainWhen
    addTarget("drain_life", drain)
    -- Only compare a delayed Shadow Bolt with the wand when Bolt would actually be the direct filler.
    local nextBolt = "action.shadow_bolt.known"
    if name == "Affliction" then
        nextBolt = nextBolt .. "&!action.wrack.known"
    elseif name == "Demonology" then
        nextBolt = nextBolt .. "&!(" .. casterReady .. ")"
    elseif destruction then
        nextBolt = nextBolt .. "&!action.incinerate.known"
    end
    local outdoorWand = nextBolt .. "&warlock_wand_over_bolt"
    if name == "Demonology" then
        -- Between Brand applications the demon keeps spending its charges while we wand or drain.
        outdoorWand = "(" .. outdoorWand .. "|debuff.demonic_brand.up&warlock_pet_on_target)"
    end
    local wand = "(warlock_short_pull&(!("
        .. casterReady
        .. ")|mana.pct_lo<55|warlock_target_low)|("
        .. outdoorCombat
        .. "&"
        .. outdoorWand
        .. "))"
    if name == "Affliction" then
        wand = "(" .. wand .. "|warlock_dungeon_trash&!action.wrack.known)"
    end
    -- Starting a wand can occupy the next spell window. Compare Shoot and spells at the same GCD boundary.
    local fieldFiller = field .. "&warlock_filler_fits"
    -- Tap after affordable DoTs and before starting or continuing a wand. Its display floor prices the learned rank.
    add("life_tap,display_below=100", fieldFiller .. "&combat>0&mana.hi<0.50*mana.max")
    add("shoot", fieldFiller .. "&" .. wand)
    local filler = fieldFiller .. "&!(warlock_wanding&" .. wand .. ")"
    if name == "Affliction" then
        addCast("wrack", filler .. dotBudget)
    elseif name == "Demonology" then
        addCast("searing_pain", filler .. "&warlock_pet_on_target&talent.demonic_brand.enabled")
    elseif destruction then
        addCast("incinerate", filler)
    end
    addCast("shadow_bolt", filler .. dotBudget)
    add("shoot", fieldFiller)
    add("auto_attack,use_off_gcd=1", field)

    -- PvP pressure pauses while Fear or Howl is observed on the current opponent.
    local pvp = "warlock_pvp_pressure&warlock_spell_in_range"
    local stationary = pvp .. "&!moving"
    add("curse_of_tongues", pvp .. "&debuff.casting.up&debuff.curse_of_tongues.down")
    add(
        "curse_of_exhaustion",
        pvp
            .. "&warlock_pvp_kiting&debuff.curse_of_exhaustion.down&(!action.curse_of_tongues.known|debuff.curse_of_tongues.down)"
    )
    add("shadow_bolt", pvp .. "&buff.shadow_trance.up")
    add("shadowburn", pvp .. "&warlock_target_low&warlock_shard_count>0")
    if destruction then
        add("conflagrate", pvp)
        add("immolate", stationary .. "&debuff.immolate.down&!warlock_target_low&!action.immolate.executing")
    end
    add(
        "corruption",
        pvp
            .. "&debuff.corruption.down&!warlock_target_low&(!moving|action.corruption.cast=0)&!action.corruption.executing"
    )
    add("siphon_life", pvp .. "&debuff.siphon_life.down&!warlock_target_low")
    add(
        "bane_of_agony",
        pvp .. "&debuff.bane_of_agony.down&!warlock_target_low&(!action.bane_of_havoc.known|debuff.bane_of_havoc.down)"
    )
    if demonology then
        add(
            "searing_pain",
            stationary .. "&warlock_pet_on_target&talent.demonic_brand.enabled&debuff.demonic_brand.down"
        )
        if name == "Demonology" then
            add("soul_fire", stationary .. "&buff.decimation.up")
        end
    elseif destruction then
        add("incinerate", stationary .. "&warlock_filler_fits")
    end
    add("shadow_bolt", stationary .. "&warlock_filler_fits")
    add("shoot", "warlock_pvp_pressure&warlock_filler_fits")

    -- Both an idle dungeon target and an exhausted field rotation must stay out of the raid damage list.
    local baseline = "warlock_sustained"
    local guard = recipe.guard or {}
    recipe.guard = guard
    for _, action in ipairs({
        "bane_of_doom",
        "major_mana_potion",
        "use_items",
    }) do
        guard[action] = baseline
    end
    for _, racial in ipairs({ "blood_fury", "berserking", "eureka" }) do
        guard[racial] = baseline .. "&!moving&!warlock_incapacitated"
    end
    guard.life_tap = baseline .. "&warlock_sustained_life_tap"
    guard.demonic_rune = baseline .. "&warlock_sustained_demonic_rune"
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
            "corruption",
            "curse_of_recklessness",
            "curse_of_the_elements",
            "curse_of_weakness",
            "shadow_bolt",
        },
    }
    for _, action in ipairs(actions[name]) do
        guard[action] = guard[action] and "(" .. guard[action] .. ")&" .. baseline or baseline
    end
    -- The upstream damage finisher belongs on a damage display. A dedicated Defensives display reserves Coil for healing.
    if guard.death_coil then
        local filler = name == "Affliction" and "shadow_bolt" or "searing_pain"
        guard.death_coil = guard.death_coil .. "&warlock_damage_display&action." .. filler .. ".known"
    end
    local extra = recipe.extra or {}
    recipe.extra = extra
    for _, entry in ipairs(extra) do
        local action, condition = entry.line:match("^(.-),if=(.+)$")
        entry.line = action and (action .. ",if=(" .. condition .. ")&" .. baseline)
            or (entry.line .. ",if=" .. baseline)
    end
    -- Give the translated instant casts first choice during a raid mechanic. A moving Warlock can spend an
    -- otherwise empty GCD on a finisher or bank mana for when hard-casting resumes.
    local moving = "combat>0&moving&" .. baseline
    if not destruction then
        extra[#extra + 1] = {
            before = "life_tap",
            last = true,
            translated = true,
            line = "shadowburn,if="
                .. moving
                .. "&warlock_target_low&warlock_spell_in_range&(warlock_shard_count>=2|talent.shadow_and_flame.rank=5)",
        }
    end
    extra[#extra + 1] = {
        before = "life_tap",
        last = true,
        translated = true,
        line = "life_tap,if=" .. moving .. "&warlock_life_tap_safe&mana.hi<0.65*mana.max",
    }
    return recipe
end

return addPvE
