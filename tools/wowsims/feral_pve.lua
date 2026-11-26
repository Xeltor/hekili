-- Both packs import the other form's list. Put the shared decisions in both sources so
-- entering combat in Cat, Bear or caster form always reaches the same role and recovery rules.
return function(recipe)
    local first = {
        "aquatic_form,if=combat=0&druid_form_intent",
        "travel_form,if=combat=0&druid_form_intent",
        "bear_form,if=combat=0&druid_form_intent",
        "cat_form,if=combat=0&druid_form_intent",
        "frenzied_regeneration,display_below=25,if=toggle.defensives&feral_defense&rage.lo>=10&buff.frenzied_regeneration.down",
        "frenzied_regeneration,display_below=55,if=toggle.defensives&feral_regeneration_pressure&buff.frenzied_regeneration.down",
        "healthstone,use_off_gcd=1,display_below=30,if=toggle.defensives&feral_defense",
        "healing_potion,use_off_gcd=1,display_below=40,if=toggle.defensives&feral_defense",
        "barkskin,display_below=60,if=toggle.defensives&feral_defense&buff.barkskin.down",
        "healing_touch,display_below=40,if=toggle.defensives&(feral_caster_heal|feral_prepare_heal)",
        "rejuvenation,display_below=55,if=toggle.defensives&feral_caster_heal&buff.rejuvenation.down",
        "cancel_buff,buff_name=bear_form,display_below=75,if=toggle.defensives&feral_unshift_heal&feral_resting_target",
        "cancel_buff,buff_name=cat_form,display_below=75,if=toggle.defensives&feral_unshift_heal&feral_resting_target",
        "healing_touch,display_below=75,if=toggle.defensives&feral_prepare_heal&feral_resting_target",
        "regrowth,display_below=75,if=toggle.defensives&feral_prepare_heal&feral_resting_target",
        "rejuvenation,display_below=75,if=toggle.defensives&feral_prepare_heal&(buff.form.down|feral_resting_target)&buff.rejuvenation.down",
        "remove_curse,if=buff.dispellable_curse.up&feral_self_dispel",
        "abolish_poison,if=buff.dispellable_poison.up&buff.abolish_poison.down&feral_self_dispel",
        "cure_poison,if=buff.dispellable_poison.up&(!action.abolish_poison.known|buff.abolish_poison.down)&feral_self_dispel",
        "mark_of_the_wild,if=feral_prepare_spell&feral_mark_missing",
        "thorns,if=feral_prepare_spell&buff.thorns.down",
        "regrowth,if=buff.regrowth.down&feral_prepare_elite&feral_primary",
        "bear_form,display_below=35,if=feral_emergency_bear",
        "bear_form,if=buff.bear_form.down&feral_primary&feral_wants_bear",
        "cat_form,if=buff.cat_form.down&feral_wants_cat",
        "feral_charge,use_off_gcd=1,if=feral_interrupt&feral_spell_range",
        "bash,if=feral_interrupt&!boss&!target.is_boss&feral_spell_range",
        "challenging_roar,if=toggle.defensives&feral_challenging_roar&debuff.challenging_roar.down",
        "growl,use_off_gcd=1,if=feral_loose_target&debuff.growl.down",
        "recover_threat,use_off_gcd=1,if=combat>0&feral_recover_threat",
        "enrage,use_off_gcd=1,if=feral_tank_opener&feral_enrage",
        "faerie_fire,if=(feral_tank_opener|(feral_pull|feral_group_enemy)&target.outside5)&feral_spell_range&buff.feral_form.up&(!action.prowl.known|buff.prowl.down)&debuff.faerie_fire.down",
        "auto_attack,use_off_gcd=1,if=(feral_pull|feral_group_enemy|feral_tank_opener)&buff.feral_form.up",
        "moonfire,if=!action.bear_form.known&!action.cat_form.known&(feral_pull|feral_tank_opener)&feral_spell_range&debuff.moonfire.down&(moving|combat>0)",
        "wrath,if=!action.bear_form.known&!action.cat_form.known&(feral_pull|feral_tank_opener)&(!moving|action.wrath.cast_time=0)&feral_spell_range",
    }
    local guard = recipe.guard or {}
    local function addGuard(key, expr)
        guard[key] = guard[key] and "(" .. guard[key] .. ")&(" .. expr .. ")" or "(" .. expr .. ")"
    end

    if recipe.spec == "guardian" then
        first[#first + 1] = "bear_form,if=feral_primary&!buff.bear_form.up&feral_sustained_form"
        first[#first + 1] = "demoralizing_roar,if=feral_defensive_roar&debuff.demoralizing_roar.down"
        -- Keep the Bear priority in guide order: save an established bleed just before it falls,
        -- then Bite the selected mob before spreading armor reduction or filling on a safe pack.
        local packBleed = "feral_held_pack&feral_durable&!feral_dying"
        local earlySwipe = "(!action.lacerate.known|action.lacerate.disabled)"
            .. "&(!action.primal_bite.known|action.primal_bite.disabled)"
            .. "&(!action.maul.known|action.maul.disabled|buff.maul.up&rage.lo>=action.swipe_bear.cost+action.maul.cost)"
        recipe.extra = {
            {
                before = "primal_bite",
                translated = true,
                line = "lacerate,focus=2,if=feral_bear_fight&feral_spell_range&debuff.lacerate.remains<=gcd.max"
                    .. "&((!feral_pack|!feral_area_safe)&debuff.lacerate.stack=5|"
                    .. packBleed
                    .. "&debuff.lacerate.up)",
            },
            { before = "primal_bite", translated = true, line = "berserk,use_off_gcd=1,if=feral_bear_burst" },
            {
                before = "lacerate",
                translated = true,
                line = "lacerate,focus=2,if=feral_bear_fight&feral_spell_range&debuff.lacerate.down&" .. packBleed,
            },
            { before = "lacerate", translated = true, line = "lacerate,other_target=1,if=feral_spread_target" },
            { before = "lacerate", translated = true, line = "faerie_fire,other_target=1,if=feral_spread_target" },
            {
                before = "lacerate",
                translated = true,
                line = "swipe_bear,if=feral_swipe_pack|feral_bear_contact&(" .. earlySwipe .. ")",
            },
        }
        for _, key in ipairs({ "lacerate", "maul", "faerie_fire" }) do
            addGuard(key, "feral_attack_in_range")
        end
        addGuard("maul", "feral_maul_allowed")
        addGuard("primal_bite", "buff.berserk.up&feral_bear_contact&feral_spell_range|feral_attack_in_range")
        addGuard("demoralizing_roar", "feral_roar_in_combat")
        -- Enrage trades armor for rage. In the field use it before contact, with room for the gain.
        addGuard("enrage", "feral_enrage")
        addGuard("elunes_light", "feral_sustained|feral_pull")
        addGuard(
            "feral_charge",
            "feral_primary&toggle.movement&feral_spell_range&!pve_reserve_interrupt&(feral_sustained|feral_pull)"
        )
        recipe.leveling = {
            "maul,use_off_gcd=1,focus=2,if=(!action.primal_bite.known|action.primal_bite.disabled)&feral_attack_in_range&feral_maul_allowed",
        }
    else
        -- Open from Prowl before applying bleeds. Ravage remains the preferred learned opener.
        first[#first + 1] =
            "shred,if=feral_pull&feral_prowling&(!action.ravage.known|action.ravage.disabled)&feral_behind&feral_spell_range"
        first[#first + 1] = "ferocious_bite,if=feral_pull&feral_dying&feral_spell_range"
            .. "&(combo_points.current>=4|combo_points.current>=2&target.real_ttd=3600)"
        -- Spend points where the leveling kit can use them. Keep the imported pooling
        -- and powershift windows on sustained fights.
        local fighting = "feral_pull&!feral_prowling&feral_spell_range"
        first[#first + 1] = "rip,if="
            .. fighting
            .. "&feral_bleed_worthwhile&debuff.rip.down&(combo_points.current>=5|combo_points.current>=3&feral_leveling_rip"
            .. "|combo_points.current>=4&feral_durable&target.real_ttd=3600)"
            .. "&energy.lo>=action.rip.cost"
        first[#first + 1] = "ferocious_bite,if="
            .. fighting
            .. "&combo_points.current>=4&feral_bite_fallback&energy.lo>=action.ferocious_bite.cost"
        first[#first + 1] = "rake,if="
            .. fighting
            .. "&feral_bleed_worthwhile&debuff.rake.down&energy.lo>=action.rake.cost"
        first[#first + 1] = "rake,other_target=1,if=feral_spread_target&energy.lo>=action.rake.cost"
        addGuard("cat_form", "feral_sustained_form|feral_wants_cat")
        for _, key in ipairs({ "ravage", "claw", "shred", "ferocious_bite", "faerie_fire" }) do
            addGuard(key, "feral_attack_in_range")
        end
        addGuard("ravage", "(!feral_field&!feral_damage_enemy)|feral_behind")
        addGuard("shred", "(!feral_field&!feral_damage_enemy)|feral_behind")
        recipe.leveling[#recipe.leveling + 1] =
            "shred,if=(feral_pull|feral_damage_enemy)&feral_behind&(!action.claw.known|action.claw.disabled)&feral_spell_range"
        recipe.leveling[#recipe.leveling + 1] =
            "claw,if=(feral_pull|feral_damage_enemy&!feral_behind)&feral_spell_range"
        for _, key in ipairs({ "rake", "rip" }) do
            addGuard(key, "feral_attack_in_range&(!feral_field|feral_bleed_worthwhile)")
        end
        for _, key in ipairs({ "dash", "prowl", "elunes_light" }) do
            addGuard(key, "!feral_field|feral_pull&!feral_wants_bear")
        end
        addGuard("innervate", "!feral_field|feral_pull&!feral_wants_bear")
        addGuard(
            "shifting_power",
            "!feral_field|feral_pull&(!action.bear_form.known|mana.lo>=action.shifting_power.cost+action.bear_form.cost)"
        )
    end
    -- A druid who has trained a form can still be left in caster form without the mana to shift.
    recipe.leveling[#recipe.leveling + 1] = "auto_attack,use_off_gcd=1,if=buff.form.down&(feral_pull|feral_tank_opener)"
    recipe.guard, recipe.levelingFirst = guard, first
    return recipe
end
