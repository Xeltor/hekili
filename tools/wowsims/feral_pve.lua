-- Both packs import the other form's list. Put the shared decisions in both sources so
-- entering combat in Cat, Bear or caster form always reaches the same role and recovery rules.
return function(recipe)
    local first = {
        "frenzied_regeneration,display_below=25,if=toggle.defensives&feral_defense&rage.lo>=10&buff.frenzied_regeneration.down",
        "healthstone,use_off_gcd=1,display_below=30,if=toggle.defensives&feral_defense",
        "healing_potion,use_off_gcd=1,display_below=40,if=toggle.defensives&feral_defense",
        "barkskin,display_below=60,if=toggle.defensives&feral_defense&buff.barkskin.down",
        "healing_touch,display_below=40,if=toggle.defensives&feral_caster_heal",
        "rejuvenation,display_below=55,if=toggle.defensives&feral_caster_heal&buff.rejuvenation.down",
        "cancel_buff,buff_name=bear_form,display_below=75,if=toggle.defensives&feral_unshift_heal",
        "cancel_buff,buff_name=cat_form,display_below=75,if=toggle.defensives&feral_unshift_heal",
        "healing_touch,display_below=75,if=toggle.defensives&feral_prepare_heal",
        "regrowth,display_below=75,if=toggle.defensives&feral_prepare_heal",
        "rejuvenation,display_below=75,if=toggle.defensives&feral_prepare_heal&buff.rejuvenation.down",
        "remove_curse,if=buff.dispellable_curse.up&feral_self_dispel",
        "abolish_poison,if=buff.dispellable_poison.up&buff.abolish_poison.down&feral_self_dispel",
        "cure_poison,if=buff.dispellable_poison.up&(!action.abolish_poison.known|buff.abolish_poison.down)&feral_self_dispel",
        "mark_of_the_wild,if=feral_prepare_spell&feral_mark_missing",
        "thorns,if=feral_prepare_spell&buff.thorns.down",
        "regrowth,if=buff.regrowth.down&feral_prepare_elite&feral_primary",
        "bear_form,display_below=35,if=feral_emergency_bear",
        "bear_form,if=buff.bear_form.down&feral_primary&feral_wants_bear",
        "cat_form,if=buff.cat_form.down&feral_wants_cat",
        "feral_charge,use_off_gcd=1,if=combat>0&feral_interrupt&feral_spell_range",
        "bash,if=combat>0&feral_interrupt&!boss&!target.is_boss&feral_spell_range",
        "growl,use_off_gcd=1,if=combat>0&feral_loose_target&debuff.growl.down",
        "recover_threat,use_off_gcd=1,if=combat>0&feral_recover_threat",
        "faerie_fire,if=feral_pull&target.outside5&feral_spell_range&buff.feral_form.up&(!action.prowl.known|buff.prowl.down)&debuff.faerie_fire.down",
        "auto_attack,use_off_gcd=1,if=feral_pull&buff.feral_form.up",
        "moonfire,if=feral_pull&!action.bear_form.known&!action.cat_form.known&feral_spell_range&debuff.moonfire.down&(moving|combat>0)",
        "wrath,if=feral_pull&!action.bear_form.known&!action.cat_form.known&(!moving|action.wrath.cast_time=0)&feral_spell_range",
    }
    local guard = recipe.guard or {}
    local function addGuard(key, expr)
        guard[key] = guard[key] and "(" .. guard[key] .. ")&(" .. expr .. ")" or "(" .. expr .. ")"
    end

    if recipe.spec == "guardian" then
        first[#first + 1] = "bear_form,if=feral_primary&!buff.bear_form.up&(!feral_field|feral_pull|feral_wants_bear)"
        first[#first + 1] =
            "demoralizing_roar,if=feral_pull&feral_pack&feral_area_safe&toggle.defensives&debuff.demoralizing_roar.down"
        first[#first + 1] =
            "swipe_bear,if=feral_pull&feral_area_safe&feral_spell_range&(feral_pack&(!action.primal_bite.known|cooldown.primal_bite.remains>gcd.max)|!action.lacerate.known&!action.primal_bite.known)"
        for _, key in ipairs({ "primal_bite", "lacerate", "maul", "faerie_fire" }) do
            addGuard(key, "feral_sustained|feral_pull&feral_spell_range")
        end
        addGuard("maul", "!action.frenzied_regeneration.known|!feral_field|buff.frenzied_regeneration.down")
        addGuard("demoralizing_roar", "feral_sustained|feral_pull&target.within10&!target.outside10&feral_area_safe")
        -- Enrage trades armor for rage. In the field use it before contact, with room for the gain.
        addGuard("enrage", "!feral_field|feral_pull&combat=0&target.outside5&rage.lo<=20")
        addGuard("elunes_light", "!feral_field|feral_pull")
        addGuard("feral_charge", "feral_primary&toggle.movement&feral_spell_range&(feral_sustained|feral_pull)")
        recipe.leveling = {
            "maul,use_off_gcd=1,focus=2,if=!action.primal_bite.known&(feral_sustained|feral_pull&feral_spell_range&(!action.frenzied_regeneration.known|buff.frenzied_regeneration.down))",
        }
    else
        -- For short pulls use direct damage once the target is visibly low. Without a health
        -- measurement only the ordinary builder and learned-rank fallbacks change.
        first[#first + 1] = "shred,if=feral_pull&feral_prowling&!action.ravage.known&feral_spell_range"
        first[#first + 1] = "ferocious_bite,if=feral_pull&feral_dying&combo_points.current>=2&feral_spell_range"
        addGuard("cat_form", "!feral_field|feral_pull&!feral_wants_bear")
        for _, key in ipairs({ "ravage", "claw", "shred", "ferocious_bite", "faerie_fire" }) do
            addGuard(key, "feral_sustained|feral_pull&feral_spell_range")
        end
        addGuard("shred", "!feral_field|feral_behind")
        recipe.leveling[#recipe.leveling + 1] = "claw,if=feral_pull&!feral_behind&feral_spell_range"
        for _, key in ipairs({ "rake", "rip" }) do
            addGuard(key, "feral_sustained|feral_pull&feral_spell_range&!feral_dying")
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
    recipe.leveling[#recipe.leveling + 1] = "auto_attack,use_off_gcd=1,if=feral_pull&buff.form.down"
    recipe.guard, recipe.levelingFirst = guard, first
    return recipe
end
