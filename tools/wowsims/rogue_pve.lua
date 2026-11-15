-- Shared WoW Forever Rogue priorities for questing and nonraid PvE. Each recipe keeps its pinned sustained rotation.
local function addPvE(recipe)
    local spec = recipe.spec
    local field = "rogue_field_damage&!rogue_reserve_kick"
    local attacking = field .. "&!stealthed.all"
    local fighting = attacking .. "&combat>0"
    local meleePvE = "combat>0&rogue_pve_target&rogue_engaged&rogue_melee"
    local casting = meleePvE .. "&debuff.casting.up"
    local canGarrote = "rogue_garrote&debuff.garrote.down"
    local ghostlyGarrote = fighting .. "&rogue_durable&buff.ghostly_strike_next.up&" .. canGarrote
    local dagger = "main_hand.dagger&rogue_behind"
    local shank = fighting .. "&off_hand.size>0&rogue_shank_room"
    local points = "combo_points.current"
    local openerRoom = "(" .. points .. "<4|" .. points .. "=4&!talent.initiative.enabled)"
    local normalOpener = "rogue_opening_attack&" .. openerRoom
    local noCheapShot = "(!action.cheap_shot.known|debuff.cheap_shot.down)"
    local noKidneyShot = "(!action.kidney_shot.known|debuff.kidney_shot.down)"
    local noGhostlyStrike = "(!action.ghostly_strike.known|buff.ghostly_strike.down)"
    local cheapShot = "rogue_stunnable&"
        .. noCheapShot
        .. "&"
        .. noKidneyShot
        .. (spec == "subtlety" and "&solo" or "&(solo|target.is_targeting_player)")

    recipe.notes = {
        "WoW Forever leveling and nonraid PvE priorities follow Icy Veins, with learned-spell and weapon fallbacks.",
        "The sustained raid damage priority follows the pinned WoWSims build.",
        "Poison reminders and each hand's preference have their own Rogue settings. Stealth is suggested for outdoor pulls with a usable opener.",
    }
    recipe.levelingFirst = {
        "will_to_survive,if=rogue_pve_context&!stealthed.all&rogue_stunned",
        "will_of_the_forsaken,if=rogue_pve_context&!stealthed.all&rogue_forsaken_control",
        "escape_artist,if=rogue_pve_context&!stealthed.all&rogue_movement_control&buff.escape_artist.down",
        "stoneform,if=rogue_pve_context&!stealthed.all&(buff.dispellable_poison.up|buff.dispellable_disease.up)&buff.stoneform.down",
        "shatter_curse,if=rogue_pve_context&!stealthed.all&buff.dispellable_curse.up&buff.shatter_curse.down",
        "rapid_regeneration,use_off_gcd=1,display_below=60,if=rogue_can_recover&buff.rapid_regeneration.down",
        "read_ley_line,display_below=80,if=toggle.defensives&rogue_can_recover&buff.energized.down",
        "instant_poison,use_off_gcd=1,label=Main Hand,if=combat=0&!rogue_opening_attack&rogue_pve_target&main_hand.size>0&buff.main_hand_enchant.down&rogue_poison_main=1",
        "deadly_poison,use_off_gcd=1,label=Main Hand,if=combat=0&!rogue_opening_attack&rogue_pve_target&main_hand.size>0&buff.main_hand_enchant.down&rogue_poison_main=2",
        "deadly_poison,use_off_gcd=1,label=Off Hand,if=combat=0&!rogue_opening_attack&rogue_pve_target&off_hand.size>0&buff.off_hand_enchant.down&rogue_poison_off=2",
        "instant_poison,use_off_gcd=1,label=Off Hand,if=combat=0&!rogue_opening_attack&rogue_pve_target&off_hand.size>0&buff.off_hand_enchant.down&(rogue_poison_off=1|rogue_poison_off=2&settings.off_hand_poison='auto')",
        "stealth,use_off_gcd=1,if=combat=0&rogue_outdoor_opener&rogue_field_damage&!stealthed.all"
            .. "&combo_points.current<4&((action.cheap_shot.known&"
            .. cheapShot
            .. ")|((action.ambush.known|action.backstab.known)&"
            .. dagger
            .. ")|(action.garrote.known&rogue_durable&"
            .. canGarrote
            .. "))",
    }
    recipe.leveling = {
        -- The pinned builder gate uses spellbook knowledge, so a weapon swap needs its own fallback.
        "sinister_strike,if=rogue_sustained&!rogue_hold_opening_stealth&"
            .. points
            .. "<5&action.mutilate.known&!rogue_mutilate",
    }

    -- Guard the generated damage lines in short-pull contexts, including the ones inside racial sequences.
    recipe.guard = {}
    for _, key in ipairs({
        "garrote",
        "vanish",
        "preparation",
        "blood_fury",
        "blade_flurry",
        "berserking",
        "shank",
        "adrenaline_rush",
        "elunes_light",
        "eureka",
        "thistle_tea",
        "premeditation",
        "death_mark",
        "rupture",
        "slice_and_dice",
        "cold_blood",
        "eviscerate",
        "ghostly_strike",
        "mutilate",
        "hemorrhage",
        "sinister_strike",
    }) do
        recipe.guard[key] = "rogue_sustained"
    end
    for _, key in ipairs({ "death_mark", "rupture", "eviscerate", "ghostly_strike", "hemorrhage", "sinister_strike" }) do
        recipe.guard[key] = "rogue_sustained&!rogue_hold_opening_stealth"
    end
    recipe.guard.shank = "rogue_sustained&off_hand.size>0&!rogue_hold_opening_stealth"
    recipe.guard.mutilate = "rogue_sustained&rogue_mutilate&!rogue_hold_opening_stealth"
    recipe.guard.garrote = "rogue_sustained&!rogue_hold_opening_stealth"
    -- Prepull cooldowns are useful for planned encounters. Don't use them on a selected idle dungeon mob.
    recipe.guard["precombat #1"] = { expect = "blade_flurry", cond = "rogue_planned_pull&!rogue_field" }
    recipe.guard["precombat #2"] = { expect = "premeditation", cond = "rogue_planned_pull&!rogue_field" }

    local extra = recipe.extra or {}
    recipe.extra = {}
    local function add(line)
        -- The original sustained Garrote stays last. Anchoring the first Garrote would move later additions ahead
        -- of our newly inserted openers and proc follow-ups, defeating the order below.
        recipe.extra[#recipe.extra + 1] = { before = "garrote", last = true, line = line }
    end

    add("kick,if=" .. casting .. "&!stealthed.all&debuff.casting.v2=0")
    add(
        "kidney_shot,if="
            .. casting
            .. "&rogue_stunnable&!stealthed.all&"
            .. noCheapShot
            .. "&debuff.kidney_shot.down"
            .. "&(!action.kick.known|cooldown.kick.remains>=debuff.casting.remains|debuff.casting.v2=1)&"
            .. points
            .. ">=2"
    )
    add("healthstone,use_off_gcd=1,display_below=30,if=combat>0&rogue_pve_target&!stealthed.all")
    add("healing_potion,use_off_gcd=1,display_below=40,if=combat>0&rogue_pve_target&!stealthed.all")
    add("stoneform,display_below=65,if=combat>0&rogue_pve_context&rogue_danger&!stealthed.all&buff.stoneform.down")
    add("evasion,use_off_gcd=1,if=rogue_pve_target&rogue_danger&!stealthed.all&solo&" .. noGhostlyStrike)
    add(
        "evasion,use_off_gcd=1,display_below=65,if=rogue_pve_target&rogue_danger&!stealthed.all&!solo&"
            .. noGhostlyStrike
    )
    add("feint,if=" .. meleePvE .. "&!solo&!stealthed.all&rogue_high_threat&debuff.casting.down")

    for _, entry in ipairs(extra) do
        if entry.before == "garrote" then
            entry.last = true
        end
        recipe.extra[#recipe.extra + 1] = entry
    end

    if spec == "subtlety" then
        add("premeditation,use_off_gcd=1,if=rogue_opening_attack&" .. points .. "<=2")
        add("ambush,focus=1,if=" .. normalOpener .. "&" .. dagger)
    end
    add("cheap_shot,if=rogue_opening_attack&" .. points .. "<4&" .. cheapShot)
    add("garrote,focus=1,if=" .. normalOpener .. "&rogue_durable&" .. canGarrote)
    if spec ~= "subtlety" then
        add("ambush,if=" .. normalOpener .. "&" .. dagger)
    end
    add("backstab,if=rogue_opening_attack&" .. points .. "<5&" .. dagger)
    -- Being stealthed at melee range expresses intent to attack, including a selected idle dungeon target.
    -- If a special opener cannot be used, offer a legal strike or finisher instead of an indefinitely empty queue.
    add("eviscerate,if=rogue_opening_attack&" .. points .. ">=4")
    add("mutilate,if=rogue_opening_attack&rogue_mutilate&" .. points .. "<5")
    add("hemorrhage,if=rogue_opening_attack&" .. points .. "<5")
    add("sinister_strike,if=rogue_opening_attack&" .. points .. "<5")
    add("auto_attack,use_off_gcd=1,if=rogue_start_attack")
    local racialBurst = fighting
        .. "&!rogue_incapacitated&(rogue_durable|rogue_melee_enemies>=2|settings.pve_continuous_combat)"
    add("blood_fury,use_off_gcd=1,if=" .. racialBurst .. "&energy.lo>=40&buff.blood_fury.down")
    add("berserking,use_off_gcd=1,if=" .. racialBurst .. "&energy.lo>=40&buff.berserking.down")
    add("elunes_light,use_off_gcd=1,if=" .. racialBurst .. "&energy.lo>=40&buff.elunes_light.down")
    add("eureka,use_off_gcd=1,if=" .. racialBurst .. "&energy.lo>=90&buff.eureka.down")
    add("garrote,focus=1,if=" .. ghostlyGarrote .. "&" .. openerRoom)
    add("ambush,focus=1,if=" .. fighting .. "&buff.ghostly_strike_next.up&" .. dagger .. "&" .. openerRoom)

    -- This recovery branch precedes waiting finishers. It cannot spend combo points or assume a hidden Energy gain.
    add("shank,if=" .. fighting .. "&rogue_shank_finisher")

    if spec == "combat" then
        add("blade_flurry,if=" .. fighting .. "&rogue_melee_enemies>=2")
        add(
            "adrenaline_rush,if="
                .. fighting
                .. "&energy.hi<=50&(!action.slice_and_dice.known|buff.slice_and_dice.up)&(rogue_melee_enemies>=2|rogue_durable)"
        )
    end
    if spec == "subtlety" then
        add(
            "rupture,focus=1,if="
                .. fighting
                .. "&rogue_durable&action.hemorrhage.known&debuff.rupture.down&"
                .. points
                .. "=5"
        )
        add("death_mark,if=" .. fighting .. "&rogue_durable&debuff.death_mark.down&" .. points .. "=5")
    end

    local sndTarget = spec == "subtlety"
            and "(rogue_durable|rogue_melee_enemies>=2|settings.pve_continuous_combat|!action.hemorrhage.known)"
        or "(rogue_durable|rogue_melee_enemies>=2|settings.pve_continuous_combat)"
    add(
        "slice_and_dice,focus=1,if="
            .. fighting
            .. "&"
            .. sndTarget
            .. "&buff.slice_and_dice.remains<=1&"
            .. points
            .. ">=2"
    )
    if spec ~= "subtlety" then
        add(
            "rupture,focus=1,if="
                .. fighting
                .. "&rogue_durable&debuff.rupture.down&(!action.slice_and_dice.known|buff.slice_and_dice.up)&"
                .. points
                .. "=5"
        )
    end
    add(
        "cold_blood,use_off_gcd=1,if="
            .. fighting
            .. "&"
            .. points
            .. "=5&(!action.eviscerate.known|energy.lo>=action.eviscerate.cost)"
    )
    local finish = spec == "assassination" and "(" .. points .. "=5|rogue_mutilate&" .. points .. "=4)"
        or points .. "=5"
    add("eviscerate,if=" .. attacking .. "&" .. finish)
    add("shank,if=" .. shank .. "&" .. points .. "<5")

    if spec == "subtlety" then
        add(
            "ghostly_strike,if="
                .. fighting
                .. "&"
                .. points
                .. "<5&buff.ghostly_strike_next.down&(!action.evasion.known|buff.evasion.down)"
        )
        add("hemorrhage,if=" .. attacking .. "&" .. points .. "<5")
    elseif spec == "assassination" then
        add("mutilate,if=" .. attacking .. "&rogue_mutilate&" .. points .. "<5")
    end
    local backstab = spec == "assassination" and "&!rogue_mutilate" or ""
    if spec ~= "subtlety" then
        local daggerBuild = spec == "combat" and "&talent.puncturing_wounds.enabled" or ""
        add("backstab,if=" .. attacking .. "&" .. dagger .. backstab .. daggerBuild .. "&" .. points .. "<5")
    end
    local fallback = spec == "subtlety" and "&!action.hemorrhage.known" or ""
    if spec == "assassination" then
        fallback = "&!rogue_mutilate"
    end
    add("sinister_strike,if=" .. attacking .. fallback .. "&" .. points .. "<5")
    return recipe
end

return addPvE
